#!/usr/bin/env bash
# MainUI-Android fork CI helpers (the same file in every fork, .github/mainui/ci.sh).
#
# The fork's default branch is upstream plus MainUI's patch commits. Every night it merges
# upstream; "nightly" releases are built from it. "Stable" releases are upstream's latest release
# with the patch on top, built once per upstream release and patch, so MainUI (which follows a
# repository's latest non-prerelease release) gets a new stable build whenever upstream ships one
# or the patch changes.
#
# Environment: UPSTREAM_REPO (owner/name), UPSTREAM_BRANCH (default master), STABLE_TAG_REGEX
# (tags that count as upstream releases when it has no GitHub releases), GH_TOKEN, and for signing
# MAINUI_KEYSTORE (base64), MAINUI_KEYSTORE_PASSWORD, MAINUI_KEY_ALIAS, MAINUI_KEY_PASSWORD.
set -euo pipefail

: "${UPSTREAM_REPO:?}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"
# gh acts on this fork whatever remotes a step adds (it would pick "upstream" over "origin").
if [ -n "${GITHUB_REPOSITORY:-}" ]; then export GH_REPO="$GITHUB_REPOSITORY"; fi

say() { echo "$@" >&2; }

ensure_upstream() {
  git config user.name >/dev/null 2>&1 || git config user.name "MainUI CI"
  git config user.email >/dev/null 2>&1 || git config user.email "mainui-ci@users.noreply.github.com"
  git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "https://github.com/$UPSTREAM_REPO.git"
  git fetch --no-tags --quiet upstream "$UPSTREAM_BRANCH"
}

# The patch's fingerprint at $1: its changed lines without context or CI files, so merging
# upstream changes it only where a line the patch touches changed.
patch_id() {
  ensure_upstream
  git diff -U0 "$(git merge-base "upstream/$UPSTREAM_BRANCH" "$1")" "$1" -- . ':(exclude).github' \
    | git patch-id --stable | cut -c1-12
}

# What a stable build of upstream tag $2 is made from, at $1: the patch, and the tag's own patch
# file when it has one (a new one is built again).
fingerprint() {
  local id own
  id=$(patch_id "$1")
  own=$(git rev-parse --quiet --verify "$1:.github/mainui/stable/$2.patch" 2>/dev/null | cut -c1-8 || true)
  echo "$id${own:+-$own}"
}

# Something needs a person (or the nightly Claude session): an issue when the fork has them, and
# always an error in the run's log.
problem() {
  local title="$1" body="$2"
  echo "::error title=$title::$body"
  if gh issue list --state open --search "$title in:title" --json number --jq '.[0].number' 2>/dev/null | grep -q .; then return 0; fi
  gh issue create --title "$title" --body "$body" >/dev/null 2>&1 || true
}

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
    if ! git push origin "HEAD:$(git rev-parse --abbrev-ref HEAD)"; then
      git reset --quiet --hard ORIG_HEAD
      problem "Upstream merge can't be pushed" "Merging $UPSTREAM_REPO $UPSTREAM_BRANCH went cleanly, but the push was refused (when upstream changed .github/workflows, the workflow's token may not push it). The nightly maintenance session merges it; until then builds stay on the last merge."
      echo "changed=false" >> "$OUT"; exit 0
    fi
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
    # unless its "<tag>-mainui" release has this patch already; empty otherwise.
    tag=$(gh api "repos/$UPSTREAM_REPO/releases?per_page=50" --jq '.[] | select((.draft or .prerelease) | not) | .tag_name' 2>/dev/null \
      | grep -E "${STABLE_TAG_REGEX:-.}" | head -1 || true)
    if [ -z "$tag" ] && [ -n "${STABLE_TAG_REGEX:-}" ]; then
      tag=$(git ls-remote --tags --refs "https://github.com/$UPSTREAM_REPO.git" | sed 's#.*refs/tags/##' \
        | grep -E "$STABLE_TAG_REGEX" | sort -V | tail -1 || true)
    fi
    if [ -n "$tag" ]; then
      built=$(gh release view "$tag-mainui" --json body --jq .body 2>/dev/null || true)
      case "$built" in *"MainUI patch $(fingerprint HEAD "$tag")."*) tag="" ;; esac
    fi
    say "Stable to build: ${tag:-none}"
    echo "tag=$tag" >> "$OUT"
    ;;

  prepare-stable)
    # Checks out upstream release $1 with the patch on top (branch mainui-stable): the patch's net
    # change (this branch against the upstream commit it last merged), applied in one 3-way step,
    # so the patch's history (lines moved, edits undone) doesn't matter. A release whose code the
    # patch doesn't fit (upstream changed those lines since) has one of its own,
    # .github/mainui/stable/<tag>.patch: the patch outside .github, its conflicts resolved on that
    # tag, whose first line names the patch it was made from ("MainUI patch <patch_id>"). The CI
    # files always come from this branch.
    tag="${1:?tag}"
    ensure_upstream
    git fetch --quiet upstream "refs/tags/$tag:refs/tags/$tag"
    base=$(git merge-base "upstream/$UPSTREAM_BRANCH" HEAD)
    tmp="${RUNNER_TEMP:-/tmp}"
    git diff --binary "$base" HEAD -- .github > "$tmp/mainui-ci.patch"
    own=".github/mainui/stable/$tag.patch"
    if [ -f "$own" ]; then
      # Made from an older patch: building it would ship the old code as the new.
      want="MainUI patch $(patch_id HEAD)"
      if [ "$(head -1 "$own")" != "$want" ]; then
        problem "Patch for $tag is out of date" "$own was made from another version of the MainUI patch. The nightly maintenance session makes it again from this branch's patch, first line: $want. No stable build until then."
        exit 1
      fi
      cp "$own" "$tmp/mainui.patch"; from="$own"
    else
      git diff --binary "$base" HEAD -- . ':(exclude).github' > "$tmp/mainui.patch"
      from="this branch against upstream $(git rev-parse --short "$base")"
    fi
    git checkout --quiet -B mainui-stable "$tag"
    if ! git apply --3way --index "$tmp/mainui-ci.patch" || ! git apply --3way --index "$tmp/mainui.patch"; then
      problem "Patch doesn't apply to $tag" "The MainUI patch ($from) conflicts with $UPSTREAM_REPO $tag in: $(git diff --name-only --diff-filter=U | tr '\n' ' '). The nightly maintenance session writes $own for it; no stable build until then."
      exit 1
    fi
    git commit --quiet -m "MainUI patch on $tag"
    git submodule update --init --recursive --quiet || true
    say "mainui-stable: $tag + the MainUI patch ($(git diff --shortstat "$tag" HEAD))"
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
      # The APK is $tag with the patch commits on top: a commit only this runner has, which the
      # workflow's token may not push (it changes workflow files). So the release's tag goes on
      # upstream's $tag commit (on this fork's branch once it has merged it), and the notes name
      # the patch (stable-tag reads it back).
      notes="$UPSTREAM_REPO $tag with the MainUI State API (save / load states and slots driven by MainUI), MainUI patch $(fingerprint "origin/$UPSTREAM_BRANCH" "$tag"). Installs beside the official app."
      # Built again for a new patch: it replaces the release before.
      gh release delete "$tag-mainui" --yes --cleanup-tag >/dev/null 2>&1 || true
      git push --quiet origin ":refs/tags/$tag-mainui" 2>/dev/null || true
      target=$(git rev-parse "$tag^{commit}")
      if ! gh release create "$tag-mainui" --target "$target" --latest --title "$tag (MainUI)" --notes "$notes" "$@"; then
        gh release create "$tag-mainui" --target "$(git rev-parse "origin/$UPSTREAM_BRANCH")" --latest \
          --title "$tag (MainUI)" --notes "$notes" "$@"
      fi
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
