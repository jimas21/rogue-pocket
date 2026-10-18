/*
 * rp_core.c - Rogue Pocket's shim over libmgba (mGBA, MPL-2.0, https://mgba.io).
 *
 * ORDER MATTERS. <mgba/flags.h> must be the first mGBA include. libmgba is built by
 * ci/build_mgba.sh, which appends to that header every ENABLE_* / USE_* / M_CORE_*
 * define the library was really compiled with. `struct mCore` (include/mgba/core/core.h)
 * changes layout with ENABLE_VFS, ENABLE_DIRECTORIES, ENABLE_DEBUGGERS and MINIMAL_CORE, so
 * a mismatch would make every function pointer in the struct point at the wrong slot and
 * crash at the first call. The #error lines below turn that into a build failure instead.
 */
#include <mgba/flags.h>

#if !defined(M_CORE_GBA)
#error "mgba/flags.h does not define M_CORE_GBA: Vendor/mgba-dist/include is stale or was not produced by ci/build_mgba.sh."
#endif
#if !defined(ENABLE_VFS) || !defined(ENABLE_DIRECTORIES)
#error "mgba/flags.h is missing ENABLE_VFS / ENABLE_DIRECTORIES, which libmgba was compiled with. Re-run ci/build_mgba.sh (it appends the real compile definitions to flags.h)."
#endif
#if defined(ENABLE_DEBUGGERS) || defined(MINIMAL_CORE) || defined(COLOR_16_BIT)
#error "libmgba must be built with ENABLE_DEBUGGERS off, MINIMAL_CORE unset and COLOR_16_BIT unset (32-bit RGBX video). See ci/build_mgba.sh."
#endif

#include <mgba/core/config.h>
#include <mgba/core/core.h>
#include <mgba/core/log.h>
#include <mgba/core/version.h>
#include <mgba/internal/gba/gba.h>
#include <mgba/internal/gba/memory.h>
#include <mgba/internal/gba/savedata.h>
#include <mgba-util/audio-buffer.h>
#include <mgba-util/image.h>
#include <mgba-util/vfs.h>

#include "rp_core.h"

_Static_assert(sizeof(mColor) == 4, "mColor must be 32-bit (COLOR_16_BIT must not be defined)");

struct RPCore {
	struct mCore* core;
	mColor* video; /* RP_VIDEO_WIDTH * RP_VIDEO_HEIGHT */
};

/* ---- log capture ------------------------------------------------------------------------
 * Without a logger mGBA printf()s to stdout, which on a phone nobody can read (and is slow).
 * Keep the last few KiB of warnings/errors so the app can show them on screen. */

static char s_log[4096];
static size_t s_logLen = 0;
static struct mLogger s_logger;
static int s_loggerInstalled = 0;

static void rp_log_cb(struct mLogger* logger, int category, enum mLogLevel level, const char* format, va_list args) {
	(void) logger;
	if (!(level & (mLOG_FATAL | mLOG_ERROR | mLOG_WARN))) { /* INFO is per-DMA spam; GAME_ERROR/STUB/DEBUG are worse */
		return;
	}
	char line[256];
	int n = snprintf(line, sizeof(line), "[%s] ", mLogCategoryName(category));
	if (n < 0) {
		n = 0;
	}
	if ((size_t) n >= sizeof(line)) {
		n = (int) sizeof(line) - 1;
	}
	vsnprintf(line + n, sizeof(line) - (size_t) n, format, args);
	size_t len = strlen(line);
	if (s_logLen + len + 1 >= sizeof(s_log)) {
		size_t keep = sizeof(s_log) / 2;
		memmove(s_log, s_log + s_logLen - keep, keep);
		s_logLen = keep;
	}
	memcpy(s_log + s_logLen, line, len);
	s_logLen += len;
	s_log[s_logLen++] = '\n';
	s_log[s_logLen] = '\0';
}

const char* rp_log_text(void) {
	return s_log;
}

const char* rp_mgba_version(void) {
	static char text[96];
	snprintf(text, sizeof(text), "%s (%s)", projectVersion ? projectVersion : "?", gitCommitShort ? gitCommitShort : "?");
	return text;
}

/* ---- lifecycle -------------------------------------------------------------------------- */

static void set_err(char* err, size_t errLen, const char* message) {
	if (err && errLen) {
		snprintf(err, errLen, "%s", message);
	}
}

RPCore* rp_open(const char* romPath, const char* savePath, char* err, size_t errLen) {
	if (!s_loggerInstalled) {
		s_logger.log = rp_log_cb;
		s_logger.filter = NULL;
		mLogSetDefaultLogger(&s_logger);
		s_loggerInstalled = 1;
	}
	s_log[0] = '\0';
	s_logLen = 0;

	if (!romPath) {
		set_err(err, errLen, "No ROM path.");
		return NULL;
	}
	struct mCore* core = mCoreFind(romPath);
	if (!core) {
		set_err(err, errLen, "mCoreFind: not a Game Boy Advance ROM (or the file could not be opened).");
		return NULL;
	}
	if (!core->init(core)) {
		set_err(err, errLen, "core->init failed.");
		return NULL;
	}
	if (core->platform(core) != mPLATFORM_GBA) {
		set_err(err, errLen, "That ROM is not for the Game Boy Advance.");
		core->deinit(core);
		return NULL;
	}

	RPCore* rp = calloc(1, sizeof(*rp));
	if (!rp) {
		set_err(err, errLen, "Out of memory.");
		core->deinit(core);
		return NULL;
	}
	rp->core = core;

	/* Configuration. A missing "volume" means silence (opts.volume would be 0). */
	mCoreInitConfig(core, "roguepocket");
	mCoreConfigSetIntValue(&core->config, "useBios", 0); /* built-in HLE BIOS; no BIOS file is needed */
	mCoreConfigSetIntValue(&core->config, "skipBios", 1);
	mCoreConfigSetIntValue(&core->config, "volume", 0x100); /* GBA_AUDIO_VOLUME_MAX */
	mCoreConfigSetIntValue(&core->config, "mute", 0);
	mCoreConfigSetIntValue(&core->config, "frameskip", 0);
	mCoreConfigSetUIntValue(&core->config, "audioBuffers", 16384); /* frames; > 1 frame even at 262144 Hz */
	mCoreConfigSetValue(&core->config, "idleOptimization", "remove");
	mCoreLoadForeignConfig(core, &core->config);

	unsigned w = 0, h = 0;
	core->baseVideoSize(core, &w, &h);
	if (w != RP_VIDEO_WIDTH || h != RP_VIDEO_HEIGHT) {
		set_err(err, errLen, "Unexpected video size from the core.");
		goto fail;
	}
	rp->video = calloc((size_t) w * h, sizeof(mColor));
	if (!rp->video) {
		set_err(err, errLen, "Out of memory.");
		goto fail;
	}
	core->setVideoBuffer(core, rp->video, w); /* stride is in pixels */

	if (!mCoreLoadFile(core, romPath)) {
		set_err(err, errLen, "mCoreLoadFile: mGBA could not load this ROM.");
		goto fail;
	}
	/* The save must be attached BEFORE reset (same order as mGBA's own headless-main.c). */
	if (savePath && !mCoreLoadSaveFile(core, savePath, false)) {
		set_err(err, errLen, "mCoreLoadSaveFile: could not open or create the save file.");
		core->unloadROM(core);
		goto fail;
	}
	core->reset(core);
	return rp;

fail:
	mCoreConfigDeinit(&core->config);
	core->deinit(core);
	free(rp->video);
	free(rp);
	return NULL;
}

void rp_close(RPCore* rp) {
	if (!rp) {
		return;
	}
	rp_flush_save(rp);
	rp->core->unloadROM(rp->core);
	mCoreConfigDeinit(&rp->core->config);
	rp->core->deinit(rp->core); /* frees the mCore itself */
	free(rp->video);
	free(rp);
}

void rp_reset(RPCore* rp) {
	rp->core->reset(rp->core);
}

void rp_run_frame(RPCore* rp) {
	rp->core->runFrame(rp->core);
}

uint32_t rp_frame_counter(const RPCore* rp) {
	return rp->core->frameCounter(rp->core);
}

void rp_set_keys(RPCore* rp, uint32_t keys) {
	rp->core->setKeys(rp->core, keys);
}

const uint32_t* rp_pixels(const RPCore* rp) {
	return (const uint32_t*) rp->video;
}

/* ---- audio ------------------------------------------------------------------------------ */

unsigned rp_audio_rate(RPCore* rp) {
	return rp->core->audioSampleRate(rp->core);
}

size_t rp_audio_read(RPCore* rp, int16_t* out, size_t maxFrames) {
	struct mAudioBuffer* buffer = rp->core->getAudioBuffer(rp->core);
	if (!buffer) {
		return 0;
	}
	return mAudioBufferRead(buffer, out, maxFrames);
}

void rp_audio_clear(RPCore* rp) {
	struct mAudioBuffer* buffer = rp->core->getAudioBuffer(rp->core);
	if (buffer) {
		mAudioBufferClear(buffer);
	}
}

/* ---- save ------------------------------------------------------------------------------- */

void rp_flush_save(RPCore* rp) {
	/* Same idea as Tinbox's flush: the save file is memory-mapped and mGBA syncs it lazily,
	 * so ask for the sync explicitly when the app is about to be suspended. */
	struct GBA* gba = (struct GBA*) rp->core->board;
	struct GBASavedata* savedata = &gba->memory.savedata;
	if (!savedata->vf || !savedata->data) {
		return;
	}
	if (savedata->maskWriteback) {
		GBASavedataUnmask(savedata);
	}
	if (savedata->mapMode & MAP_WRITE) {
		savedata->vf->sync(savedata->vf, savedata->data, GBASavedataSize(savedata));
	}
}

const char* rp_save_type_name(const RPCore* rp) {
	const struct GBA* gba = (const struct GBA*) rp->core->board;
	switch (gba->memory.savedata.type) {
	case GBA_SAVEDATA_AUTODETECT:
		return "autodetect";
	case GBA_SAVEDATA_FORCE_NONE:
		return "none";
	case GBA_SAVEDATA_SRAM:
		return "sram";
	case GBA_SAVEDATA_SRAM512:
		return "sram512";
	case GBA_SAVEDATA_FLASH512:
		return "flash512";
	case GBA_SAVEDATA_FLASH1M:
		return "flash1m";
	case GBA_SAVEDATA_EEPROM:
		return "eeprom";
	case GBA_SAVEDATA_EEPROM512:
		return "eeprom512";
	}
	return "?";
}

size_t rp_save_size(const RPCore* rp) {
	const struct GBA* gba = (const struct GBA*) rp->core->board;
	return GBASavedataSize(&gba->memory.savedata);
}

/* ---- memory ----------------------------------------------------------------------------- */

const uint8_t* rp_memory_ptr(RPCore* rp, int region, size_t* size) {
	size_t dummy = 0;
	if (!size) {
		size = &dummy;
	}
	*size = 0;
	size_t id;
	switch (region) {
	case RP_REGION_EWRAM:
		id = GBA_REGION_EWRAM;
		break;
	case RP_REGION_IWRAM:
		id = GBA_REGION_IWRAM;
		break;
	default:
		return NULL;
	}
	/* _GBACoreGetMemoryBlock (src/gba/core.c) returns gba->memory.wram / iwram: host memory
	 * allocated once in core->init and only zeroed by reset, so the pointer is stable until
	 * rp_close. It is still fetched on every call so nothing here caches it. */
	return (const uint8_t*) rp->core->getMemoryBlock(rp->core, id, size);
}

size_t rp_read_memory(RPCore* rp, uint32_t address, uint8_t* out, size_t length) {
	if (!out || length == 0) {
		return 0;
	}
	int region;
	uint64_t base;
	if (address >= GBA_BASE_EWRAM && address < GBA_BASE_EWRAM + GBA_SIZE_EWRAM) {
		region = RP_REGION_EWRAM;
		base = GBA_BASE_EWRAM;
	} else if (address >= GBA_BASE_IWRAM && address < GBA_BASE_IWRAM + GBA_SIZE_IWRAM) {
		region = RP_REGION_IWRAM;
		base = GBA_BASE_IWRAM;
	} else {
		return 0;
	}
	size_t size = 0;
	const uint8_t* block = rp_memory_ptr(rp, region, &size);
	uint64_t offset = (uint64_t) address - base;
	if (!block || offset + (uint64_t) length > (uint64_t) size) {
		return 0;
	}
	memcpy(out, block + offset, length);
	return length;
}
