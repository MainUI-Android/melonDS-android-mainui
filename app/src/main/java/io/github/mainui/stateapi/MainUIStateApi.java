package io.github.mainui.stateapi;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.SystemClock;
import android.util.Log;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * MainUI State API, version 1: lets MainUI (an Android frontend) save and load states in this
 * emulator directly, instead of pressing hotkeys it may not have.
 *
 * <p>MainUI sends an explicit broadcast {@link #ACTION_COMMAND} to this app with
 * {@link #EXTRA_COMMAND} "save", "load" or "status", a {@link #EXTRA_SLOT} (0-based; {@link
 * #RESUME_SLOT} is a separate state MainUI keeps for "continue where I left off", never one of the
 * user's slots), a {@link #EXTRA_REQUEST} id and {@link #EXTRA_REPLY_TO} (its package). The command
 * waits for the best moment ({@link #waitReady}): a game booted and running, not paused, not
 * loading, not in the emulator's own menu. It is carried out on a worker thread, and the answer
 * goes back as the broadcast {@link #ACTION_RESULT} to that package.
 *
 * <p>A launch intent with {@link #EXTRA_LOAD_SLOT} loads that slot once the game has booted and
 * settled ({@link #onLaunch}).
 *
 * <p>The emulator says it has the API with {@code <meta-data android:name="io.github.mainui.STATE_API"
 * android:value="1"/>} in its application, registers {@link Receiver} for {@link #ACTION_COMMAND},
 * and attaches an {@link Emulator} while a game runs.
 *
 * <p>This file is the same in every emulator; only the {@link Emulator} adapter differs.
 */
public final class MainUIStateApi {
    public static final int VERSION = 1;
    private static final String TAG = "MainUIStateApi";

    public static final String ACTION_COMMAND = "io.github.mainui.stateapi.COMMAND";
    public static final String ACTION_RESULT = "io.github.mainui.stateapi.RESULT";
    public static final String META_DATA = "io.github.mainui.STATE_API";

    public static final String EXTRA_COMMAND = "command";
    public static final String EXTRA_SLOT = "slot";
    public static final String EXTRA_REQUEST = "request";
    public static final String EXTRA_REPLY_TO = "reply_to";
    /** How long the command may wait for the game to be ready (ms). */
    public static final String EXTRA_WAIT_MS = "wait_ms";
    /** How long the game must have been ready, without a break, before the command runs (ms; 300 by default). */
    public static final String EXTRA_SETTLE_MS = "settle_ms";
    /**
     * Only a game started at or after this {@link SystemClock#uptimeMillis} counts (MainUI just
     * launched it: never the previous game still running). 0: any.
     */
    public static final String EXTRA_NOT_BEFORE = "not_before";

    public static final String EXTRA_OK = "ok";
    public static final String EXTRA_ERROR = "error";
    public static final String EXTRA_PATH = "path";
    public static final String EXTRA_VERSION = "version";
    public static final String EXTRA_RUNNING = "running";
    public static final String EXTRA_READY = "ready";
    public static final String EXTRA_SLOTS = "slots";
    /** Status: when each user slot was saved (ms since 1970, 0 = empty). */
    public static final String EXTRA_SLOT_TIMES = "slot_times";
    public static final String EXTRA_RESUME_TIME = "resume_time";

    /** Launch extra: load this slot once the game has booted. */
    public static final String EXTRA_LOAD_SLOT = "io.github.mainui.stateapi.LOAD_SLOT";

    /** MainUI's own "continue" state, kept apart from the user's slots. */
    public static final int RESUME_SLOT = -1;

    /** What MainUI needs from the emulator. Called on a worker thread, never the UI thread. */
    public interface Emulator {
        /** A game is booted (not the game list, settings, or a BIOS menu without a game). */
        boolean isRunning();

        /**
         * A state can be saved or loaded right now: the game runs, unpaused, past its boot, not
         * loading or in the emulator's own menu (whatever this emulator can tell).
         */
        boolean isReady();

        /** How many user slots there are (MainUI's slots 0 .. count-1). */
        int slotCount();

        /** Saves [slot] (or {@link #RESUME_SLOT}); returns once written, with the file's path. Throws on failure. */
        String save(int slot) throws Exception;

        /** Loads [slot] (or {@link #RESUME_SLOT}); returns once loaded. Throws on failure (no such state...). */
        void load(int slot) throws Exception;

        /** When [slot] (or {@link #RESUME_SLOT}) was saved, ms since 1970; 0 when it is empty. */
        long slotTime(int slot);
    }

    private static volatile Emulator emulator;
    /** When [emulator] was attached ({@link SystemClock#uptimeMillis}). */
    private static volatile long attachedAt;
    private static final ExecutorService worker = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "mainui-state-api");
        t.setDaemon(true);
        return t;
    });

    private MainUIStateApi() {}

    /** A game's emulator is up (call again for each new game): commands go to [e] from now on. */
    public static void attach(Emulator e) { attachedAt = SystemClock.uptimeMillis(); emulator = e; }

    /** The game ended (or its screen went away): no emulator until the next [attach]. */
    public static void detach(Emulator e) { if (emulator == e) emulator = null; }

    /**
     * Waits until a game is running and has been ready for [stableMs] without a break, at most
     * [timeoutMs]. A moment that is ready only in passing (between loading screens) doesn't count.
     */
    public static boolean waitReady(long timeoutMs, long stableMs) { return waitReady(timeoutMs, stableMs, 0); }

    /** [waitReady] for a game attached at or after [notBefore] ({@link SystemClock#uptimeMillis}). */
    public static boolean waitReady(long timeoutMs, long stableMs, long notBefore) {
        long start = SystemClock.uptimeMillis();
        long since = 0;
        while (SystemClock.uptimeMillis() - start < timeoutMs) {
            Emulator e = emulator;
            boolean ready = false;
            try { ready = e != null && attachedAt >= notBefore && e.isRunning() && e.isReady(); } catch (Throwable ignored) {}
            long now = SystemClock.uptimeMillis();
            if (ready) {
                if (since == 0) since = now;
                if (now - since >= stableMs) return true;
            } else since = 0;
            try { Thread.sleep(50); } catch (InterruptedException ie) { return false; }
        }
        return false;
    }

    /**
     * The game was started with [intent]: a {@link #EXTRA_LOAD_SLOT} in it is loaded once the
     * game has booted and run for [settleMs] (its intro past the first frames), at most 3 minutes.
     */
    public static void onLaunch(Intent intent, long settleMs) {
        if (intent == null || !intent.hasExtra(EXTRA_LOAD_SLOT)) return;
        final int slot = intent.getIntExtra(EXTRA_LOAD_SLOT, RESUME_SLOT);
        intent.removeExtra(EXTRA_LOAD_SLOT); // once, not again when the activity is recreated
        worker.execute(() -> {
            if (!waitReady(180_000, settleMs)) { Log.w(TAG, "launch load of slot " + slot + ": the game never got ready"); return; }
            Emulator e = emulator;
            try {
                if (e.slotTime(slot) == 0) { Log.i(TAG, "launch load: slot " + slot + " is empty"); return; }
                e.load(slot);
                Log.i(TAG, "launch load: slot " + slot + " loaded");
            } catch (Throwable t) {
                Log.w(TAG, "launch load of slot " + slot + " failed", t);
            }
        });
    }

    /** Carries out a command broadcast (see the class comment) and answers it. */
    public static void handle(Context context, Intent intent) {
        final Context ctx = context.getApplicationContext();
        final String command = intent.getStringExtra(EXTRA_COMMAND);
        final int slot = intent.getIntExtra(EXTRA_SLOT, 0);
        final String request = intent.getStringExtra(EXTRA_REQUEST);
        final String replyTo = intent.getStringExtra(EXTRA_REPLY_TO);
        final long waitMs = intent.getLongExtra(EXTRA_WAIT_MS, 15_000);
        final long settleMs = intent.getLongExtra(EXTRA_SETTLE_MS, 300);
        final long notBefore = intent.getLongExtra(EXTRA_NOT_BEFORE, 0);
        worker.execute(() -> {
            Intent r = new Intent(ACTION_RESULT);
            r.putExtra(EXTRA_COMMAND, command);
            r.putExtra(EXTRA_SLOT, slot);
            r.putExtra(EXTRA_REQUEST, request);
            r.putExtra(EXTRA_VERSION, VERSION);
            try {
                Emulator e = emulator;
                if ("status".equals(command)) {
                    status(r, e);
                    r.putExtra(EXTRA_OK, true);
                } else if ("save".equals(command) || "load".equals(command)) {
                    if (!waitReady(waitMs, settleMs, notBefore)) throw new IllegalStateException(emulator == null ? "no game is running" : "the game wasn't ready");
                    e = emulator;
                    if (slot != RESUME_SLOT && (slot < 0 || slot >= e.slotCount())) throw new IllegalArgumentException("no slot " + slot);
                    if ("save".equals(command)) {
                        r.putExtra(EXTRA_PATH, e.save(slot));
                    } else {
                        if (e.slotTime(slot) == 0) throw new IllegalStateException("slot " + slot + " is empty");
                        e.load(slot);
                    }
                    r.putExtra(EXTRA_OK, true);
                } else {
                    throw new IllegalArgumentException("unknown command " + command);
                }
            } catch (Throwable t) {
                Log.w(TAG, command + " " + slot + " failed", t);
                r.putExtra(EXTRA_OK, false);
                r.putExtra(EXTRA_ERROR, t.getMessage() != null ? t.getMessage() : t.getClass().getSimpleName());
            }
            if (replyTo != null) {
                r.setPackage(replyTo);
                ctx.sendBroadcast(r);
            }
        });
    }

    private static void status(Intent r, Emulator e) {
        boolean running = false, ready = false;
        try { running = e != null && e.isRunning(); ready = running && e.isReady(); } catch (Throwable ignored) {}
        r.putExtra(EXTRA_RUNNING, running);
        r.putExtra(EXTRA_READY, ready);
        if (e == null || !running) return;
        int n = e.slotCount();
        long[] times = new long[n];
        for (int i = 0; i < n; i++) {
            try { times[i] = e.slotTime(i); } catch (Throwable ignored) {}
        }
        r.putExtra(EXTRA_SLOTS, n);
        r.putExtra(EXTRA_SLOT_TIMES, times);
        try { r.putExtra(EXTRA_RESUME_TIME, e.slotTime(RESUME_SLOT)); } catch (Throwable ignored) {}
    }

    /**
     * Waits until [check] is true (the save has been written...), at most [timeoutMs]. For
     * adapters whose emulator saves asynchronously.
     */
    public static boolean await(java.util.concurrent.Callable<Boolean> check, long timeoutMs) throws Exception {
        long start = SystemClock.uptimeMillis();
        while (SystemClock.uptimeMillis() - start < timeoutMs) {
            if (Boolean.TRUE.equals(check.call())) return true;
            Thread.sleep(50);
        }
        return false;
    }

    /** The broadcast receiver to declare (exported, with an intent filter for {@link #ACTION_COMMAND}). */
    public static final class Receiver extends BroadcastReceiver {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (ACTION_COMMAND.equals(intent.getAction())) handle(context, intent);
        }
    }
}
