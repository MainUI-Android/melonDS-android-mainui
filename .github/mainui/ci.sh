#!/usr/bin/env bash
# MainUI-Android fork CI helpers (the same file in every fork, .github/mainui/ci.sh).
#
# The fork's default branch is upstream plus MainUI's patch commits. Every night it merges
# upstream; "nightly" releases are built from it. "Stable" releases are upstream's latest release
# with the patch commits on top, built once per upstream release, so MainUI (which follows a
# repository's latest non-prerelease release) gets a new stable build whenever upstream ships one.
#
# Environment: UPSTREAM_REPO (owner/name), UPSTREAM_BRANCH (default master), STABLE_TAG_REGEX
# (tags that count as upstream releases when it has no GitHub releases), GH_TOKEN, and for signing
# MAINUI_KEYSTORE (base64), MAINUI_KEYSTORE_PASSWORD, MAINUI_KEY_ALIAS, MAINUI_KEY_PASSWORD.
set -euo pipefail

: "${UPSTREAM_REPO:?}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

say() { echo "$@" >&2; }

ensure_upstream() {
  git config user.name >/dev/null 2>&1 || git config user.name "MainUI CI"
  git config user.email >/dev/null 2>&1 || git config user.email "mainui-ci@users.noreply.github.com"
  git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "https://github.com/$UPSTREAM_REPO.git"
  git fetch --no-tags --quiet upstream "$UPSTREAM_BRANCH"
}

# Something needs a person (or the nightly Claude session): an issue when the fork has them, and
# always an error in the run's log.
problem() {
  local title="$1" body="$2"
  echo "::error title=$title::$body"
  if gh issue list --state open --search "$title in:title" --json number --jq '.[0].number' 2>/dev/null | grep -q .; then return 0; fi
  gh issue create --title "$title" --body "$body" >/dev/null 2>&1 || true
}

# The patch: commits on our branch that upstream doesn't have, merges left out.
patch_commits() { git rev-list --reverse --no-merges "upstream/$UPSTREAM_BRANCH..HEAD"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  sync)
    # Merges upstream into the checked-out branch and pushes it. changed=true when it moved.
    ensure_upstream
    if git merge-base --is-ancestor "upstream/$UPSTREAM_BRANCH" HEAD; then
      say "Up to date with $UPSTREAM_REPO"; echo "changed=false" >> "$OUT"; exit 0
    fi
    if ! git merge --no-edit -m "Merge $UPSTREAM_REPO $UPSTREAM_BRANCH" "upstream/$UPSTREAM_BRANCH"; then
      files=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
      git merge --abort
      problem "Upstream merge conflict" "Merging $UPSTREAM_REPO $UPSTREAM_BRANCH into $(git rev-parse --abbrev-ref HEAD) conflicts in: $files. The nightly maintenance session resolves it; until then builds stay on the last merge."
      echo "changed=false" >> "$OUT"; exit 0
    fi
    git push origin "HEAD:$(git rev-parse --abbrev-ref HEAD)"
    echo "changed=true" >> "$OUT"
    ;;

  quiet-upstream-ci)
    # Upstream's own workflows build and publish upstream's way, with secrets this fork doesn't
    # have: they are switched off here (new ones too, the next night). Only MainUI's runs.
    gh workflow list --all --json id,path,state --jq '.[] | select(.state == "active") | "\(.id) \(.path)"' 2>/dev/null \
      | while read -r id path; do
          [ "$path" = ".github/workflows/mainui.yml" ] && continue
          if gh workflow disable "$id" >/dev/null 2>&1; then say "Disabled upstream workflow $path"; fi
        done || true
    ;;

  stable-tag)
    # Upstream's latest release (its newest published GitHub release whose tag matches
    # STABLE_TAG_REGEX: not another platform's; else, with no releases, the newest matching tag),
    # when we have no "<tag>-mainui" release of it yet; empty otherwise.
    tag=$(gh api "repos/$UPSTREAM_REPO/releases?per_page=50" --jq '.[] | select((.draft or .prerelease) | not) | .tag_name' 2>/dev/null \
      | grep -E "${STABLE_TAG_REGEX:-.}" | head -1 || true)
    if [ -z "$tag" ] && [ -n "${STABLE_TAG_REGEX:-}" ]; then
      tag=$(git ls-remote --tags --refs "https://github.com/$UPSTREAM_REPO.git" | sed 's#.*refs/tags/##' \
        | grep -E "$STABLE_TAG_REGEX" | sort -V | tail -1 || true)
    fi
    if [ -n "$tag" ] && gh release view "$tag-mainui" >/dev/null 2>&1; then tag=""; fi
    say "Stable to build: ${tag:-none}"
    echo "tag=$tag" >> "$OUT"
    ;;

  prepare-stable)
    # Checks out upstream release $1 with the patch commits on top (branch mainui-stable).
    tag="${1:?tag}"
    ensure_upstream
    git fetch --quiet upstream "refs/tags/$tag:refs/tags/$tag"
    commits=$(patch_commits)
    git checkout --quiet -B mainui-stable "$tag"
    for c in $commits; do
      if ! git cherry-pick -x "$c" >/dev/null; then
        git cherry-pick --abort || true
        problem "Patch doesn't apply to $tag" "Cherry-picking $(git log -1 --format='%h %s' "$c") onto $UPSTREAM_REPO $tag conflicts. The nightly maintenance session adapts it; no stable build until then."
        exit 1
      fi
    done
    git submodule update --init --recursive --quiet || true
    say "mainui-stable: $tag + $(echo "$commits" | grep -c . || true) patch commits"
    ;;

  version)
    # MAINUI_VERSION_CODE (one number rising for every build: minutes since 2020) and
    # MAINUI_VERSION_NAME for channel $1 (nightly / stable) and upstream tag $2.
    code=$(( ( $(date -u +%s) - 1577836800 ) / 60 ))
    if [ "${1:-nightly}" = stable ]; then name="${2:?tag}-mainui"; else name="nightly-$(date -u +%Y%m%d)-$(git rev-parse --short HEAD)"; fi
    echo "MAINUI_VERSION_CODE=$code" >> "${GITHUB_ENV:-/dev/stdout}"
    echo "MAINUI_VERSION_NAME=$name" >> "${GITHUB_ENV:-/dev/stdout}"
    say "version $name ($code)"
    ;;

  sign)
    # Signs APK $1 into $2 with the MainUI-Android key. Exit 2 (and a warning) without the key.
    in="${1:?apk}"; out="${2:?out}"
    if [ -z "${MAINUI_KEYSTORE:-}" ]; then
      echo "::warning::The MAINUI_KEYSTORE secret is not set (organization MainUI-Android > Settings > Secrets > Actions): built, but not released."
      exit 2
    fi
    ks="${RUNNER_TEMP:-/tmp}/mainui.keystore"
    printf '%s' "$MAINUI_KEYSTORE" | base64 -d > "$ks"
    bt=$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)
    "$bt/zipalign" -f -p 4 "$in" "$out.aligned"
    MAINUI_KEYSTORE_PASSWORD="${MAINUI_KEYSTORE_PASSWORD:-android}" MAINUI_KEY_PASSWORD="${MAINUI_KEY_PASSWORD:-${MAINUI_KEYSTORE_PASSWORD:-android}}" \
      "$bt/apksigner" sign --ks "$ks" --ks-pass env:MAINUI_KEYSTORE_PASSWORD --ks-key-alias "${MAINUI_KEY_ALIAS:-mainui}" \
      --key-pass env:MAINUI_KEY_PASSWORD --out "$out" "$out.aligned"
    rm -f "$ks" "$out.aligned" "$out.idsig"
    "$bt/apksigner" verify "$out"
    ;;

  release)
    # Publishes the files after $3 as channel $1 (nightly / stable) for upstream tag $2.
    channel="${1:?channel}"; tag="${2:-}"; shift 2 || shift $#
    sha=$(git rev-parse HEAD)
    if [ "$channel" = stable ]; then
      # (Its commit exists only here: a tag takes it to GitHub.)
      git tag -f "$tag-mainui" "$sha"
      git push --quiet -f origin "refs/tags/$tag-mainui"
      gh release create "$tag-mainui" --verify-tag --latest \
        --title "$tag (MainUI)" \
        --notes "$UPSTREAM_REPO $tag with the MainUI State API (save / load states and slots driven by MainUI). Installs beside the official app." \
        "$@"
    else
      gh release delete nightly --yes --cleanup-tag >/dev/null 2>&1 || true
      git push --quiet origin ":refs/tags/nightly" 2>/dev/null || true
      gh release create nightly --target "$sha" --prerelease --latest=false \
        --title "Nightly $(date -u +%Y-%m-%d) ($(git rev-parse --short HEAD))" \
        --notes "$UPSTREAM_REPO $UPSTREAM_BRANCH, merged nightly, with the MainUI State API. Test builds: MainUI installs the stable releases." \
        "$@"
    fi
    ;;

  *)
    echo "usage: ci.sh sync | quiet-upstream-ci | stable-tag | prepare-stable <tag> | version <channel> [tag] | sign <in> <out> | release <channel> <tag> <files...>" >&2
    exit 64
    ;;
esac
