package io.github.mainui.stateapi

import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.runBlocking
import me.magnum.melonds.common.uridelegates.UriHandler
import me.magnum.melonds.domain.model.SaveStateSlot
import me.magnum.melonds.domain.model.rom.Rom
import me.magnum.melonds.domain.repositories.SaveStatesRepository
import me.magnum.melonds.domain.repositories.SettingsRepository
import me.magnum.melonds.domain.services.EmulatorManager
import me.magnum.melonds.extensions.nameWithoutExtension

/**
 * melonDS's side of the MainUI State API ([MainUIStateApi]). MainUI's slots 0-8 are melonDS's own
 * (0 is its quick save slot); MainUI's resume state is "<rom>.mainui" in the same folder. States
 * are saved and loaded the way the pause menu does it: emulation paused meanwhile.
 */
class MelonStates(
    /** The game running now (null: none, or the firmware without a game). */
    private val rom: () -> Rom?,
    /** RetroAchievements hardcore mode forbids loading states. */
    private val loadsAllowed: () -> Boolean,
    private val emulator: EmulatorManager,
    private val saveStates: SaveStatesRepository,
    private val settings: SettingsRepository,
    private val uris: UriHandler,
    /** The emulator screen's own save / load of a slot (screenshot, achievements reset). */
    private val saveSlot: suspend (Rom, SaveStateSlot) -> Boolean,
    private val loadSlot: suspend (Rom, SaveStateSlot) -> Boolean,
    /** After the resume state was loaded (what loading a slot does besides). */
    private val afterLoad: suspend () -> Unit,
) : MainUIStateApi.Emulator {

    companion object {
        /** Emulation is paused (pause menu, a dialog, the screen in the background): AndroidEmulatorManager keeps it. */
        @Volatile
        var paused = false

        private const val SLOTS = 9
    }

    override fun isRunning() = rom() != null

    override fun isReady() = rom() != null && !paused

    override fun slotCount() = SLOTS

    override fun save(slot: Int): String = runBlocking {
        val rom = rom() ?: throw IllegalStateException("no game is running")
        whilePaused {
            if (slot == MainUIStateApi.RESUME_SLOT) {
                val file = resumeFile(rom, create = true) ?: throw IllegalStateException("melonDS has no save state folder for this game")
                if (!emulator.saveState(file.uri)) throw IllegalStateException("melonDS couldn't save the state")
                file.uri.toString()
            } else {
                val s = SaveStateSlot(slot, true, null, null)
                if (!saveSlot(rom, s)) throw IllegalStateException("melonDS couldn't save the state")
                saveStates.getRomSaveStateUri(rom, s).toString()
            }
        }
    }

    override fun load(slot: Int): Unit = runBlocking<Unit> {
        val rom = rom() ?: throw IllegalStateException("no game is running")
        if (!loadsAllowed()) throw IllegalStateException("RetroAchievements hardcore mode doesn't allow loading states")
        whilePaused {
            if (slot == MainUIStateApi.RESUME_SLOT) {
                val file = resumeFile(rom, create = false)?.takeIf { it.length() > 0 } ?: throw IllegalStateException("there is no resume state")
                if (!emulator.loadState(file.uri)) throw IllegalStateException("melonDS couldn't load the state")
                afterLoad()
            } else {
                val s = saveStates.getRomSaveStates(rom).getOrNull(slot)?.takeIf { it.exists } ?: throw IllegalStateException("slot $slot is empty")
                if (!loadSlot(rom, s)) throw IllegalStateException("melonDS couldn't load the state")
            }
        }
    }

    override fun slotTime(slot: Int): Long {
        val rom = rom() ?: return 0
        return if (slot == MainUIStateApi.RESUME_SLOT) {
            resumeFile(rom, create = false)?.takeIf { it.length() > 0 }?.lastModified() ?: 0
        } else {
            saveStates.getRomSaveStates(rom).getOrNull(slot)?.takeIf { it.exists }?.lastUsedDate?.time ?: 0
        }
    }

    /** Runs [block] with emulation paused, like the pause menu does (the game was running: it runs again after). */
    private suspend fun <T> whilePaused(block: suspend () -> T): T {
        emulator.pauseEmulator()
        try {
            return block()
        } finally {
            emulator.resumeEmulator()
        }
    }

    /** MainUI's resume state for [rom], beside its slots ("<rom name>.mainui"). */
    private fun resumeFile(rom: Rom, create: Boolean): DocumentFile? {
        val dir = settings.getSaveStateDirectory(rom)?.let { uris.getUriTreeDocument(it) } ?: return null
        val name = (uris.getUriDocument(rom.uri)?.nameWithoutExtension ?: return null) + ".mainui"
        return dir.findFile(name) ?: if (create) dir.createFile("*/*", name) else null
    }
}
