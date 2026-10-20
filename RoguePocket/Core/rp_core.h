/*
 * rp_core.h - the whole native surface of Rogue Pocket, in plain C.
 *
 * This is a thin shim over libmgba's C core API (mGBA, MPL-2.0, https://mgba.io).
 * It is C, not Objective-C++, on purpose: mGBA's headers are written for C, and
 * `struct mCore` has a layout that depends on build flags, so keeping every mGBA
 * type inside rp_core.c means Swift never sees them (see rp_core.c, top).
 *
 * Threading: NOT thread-safe. Call everything from one thread (the app uses the
 * main thread, driven by a CADisplayLink).
 */
#ifndef RP_CORE_H
#define RP_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RP_VIDEO_WIDTH 240
#define RP_VIDEO_HEIGHT 160

/* Key bits, same order as mGBA's enum GBAKey (include/mgba/internal/gba/input.h). */
#define RP_KEY_A (1u << 0)
#define RP_KEY_B (1u << 1)
#define RP_KEY_SELECT (1u << 2)
#define RP_KEY_START (1u << 3)
#define RP_KEY_RIGHT (1u << 4)
#define RP_KEY_LEFT (1u << 5)
#define RP_KEY_UP (1u << 6)
#define RP_KEY_DOWN (1u << 7)
#define RP_KEY_R (1u << 8)
#define RP_KEY_L (1u << 9)

/* Memory regions for rp_memory_ptr. */
#define RP_REGION_EWRAM 0 /* 0x02000000, 256 KiB */
#define RP_REGION_IWRAM 1 /* 0x03000000, 32 KiB */

typedef struct RPCore RPCore;

/* Which mGBA this binary was built from (e.g. "0.11.0-<sha>"). Static string. */
const char* rp_mgba_version(void);

/*
 * Creates a GBA core, loads the ROM at romPath, attaches the battery save at
 * savePath (created empty if missing; pass NULL for no save file), and resets.
 * On failure returns NULL and writes a message into err (if errLen > 0).
 */
RPCore* rp_open(const char* romPath, const char* savePath, char* err, size_t errLen);
/* Flushes the save, then frees everything. rp may be NULL. */
void rp_close(RPCore* rp);

void rp_reset(RPCore* rp);
void rp_run_frame(RPCore* rp);
uint32_t rp_frame_counter(const RPCore* rp);
void rp_set_keys(RPCore* rp, uint32_t keys);
/* What the core currently holds as pressed (debug: proves rp_set_keys arrived). */
uint32_t rp_get_keys(RPCore* rp);

/* RP_VIDEO_WIDTH x RP_VIDEO_HEIGHT pixels, 4 bytes each, memory order R,G,B,X. Valid until rp_close. */
const uint32_t* rp_pixels(const RPCore* rp);

/* Audio: interleaved stereo int16. The rate is the core's current rate and can change at runtime. */
unsigned rp_audio_rate(RPCore* rp);
/* Copies up to maxFrames stereo frames out of the core's audio buffer, returns frames copied. */
size_t rp_audio_read(RPCore* rp, int16_t* out, size_t maxFrames);
void rp_audio_clear(RPCore* rp);

/* Forces the battery save to disk (call when the app goes to the background). */
void rp_flush_save(RPCore* rp);
/* "autodetect", "none", "sram", "sram512", "flash512", "flash1m", "eeprom", "eeprom512". */
const char* rp_save_type_name(const RPCore* rp);
/* Size in bytes of the save as the core sees it (flash1m must be 131072). */
size_t rp_save_size(const RPCore* rp);

/*
 * Direct pointer to emulated RAM (host memory, little-endian). Writes nothing, and the caller
 * must not write through it. *size receives the region length. Returns NULL for a bad region.
 */
const uint8_t* rp_memory_ptr(RPCore* rp, int region, size_t* size);
/*
 * Copies `length` bytes of emulated RAM starting at GBA address `address` into out. Handles
 * EWRAM (0x02000000..0x0203FFFF) and IWRAM (0x03000000..0x03007FFF); the whole range must lie
 * inside one region. Returns length on success, 0 otherwise.
 */
size_t rp_read_memory(RPCore* rp, uint32_t address, uint8_t* out, size_t length);

/* Recent mGBA warnings/errors, newline separated, newest last. Never NULL. */
const char* rp_log_text(void);

#ifdef __cplusplus
}
#endif

#endif
