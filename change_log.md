# Changelog

## 2026-07-26

### Fixed

- **Bar 1 quiet / de-accented, beat 4 silent on first play** — sound now plays at full volume with correct accent from beat 1.
- **Sound stops dead after output-device switch** — same root cause, now fixed.
- **Live sound-set / time-sig / subdiv changes while playing cause double-triggered clicks (comb-filtered / varying levels)** — fixed.
- **Format drift on Stop→Play after device rate change** — player reconnects and regenerates buffers.

**How it was fixed (root cause: stale clock anchor after `player.play()`):**
- `_start()`, `_resumeAfterDeviceChange()`, and `handleConfigurationChange()` all read `player.playerTime(forNodeTime:)` synchronously within microseconds of `player.play()` — when the player clock anchor is not yet established. Logs showed `current render sample: -1024` on every start (player clock not yet running), and `-71,337,224` after a device restart (stale anchor from a previous mixer epoch → all buffers scheduled ~25 minutes "in the past" → silently dropped).
- **New clock-anchor establishment**: scheduling no longer happens synchronously after `play()`. Instead the refill timer (first tick at 50 ms) calls `ensureClockAnchor()`, which validates `playerTime` is non-nil, `≥ 0`, and `< 1 s` before accepting it (rejects both the un-started clock and the stale -71M garbage). Only then are beats scheduled.
- **Past-time clamp in `scheduleAhead()`**: when `nextSampleTime` falls behind the render head (stale-anchor cascade), it resyncs forward + restarts the bar cleanly. Self-heals in one tick.
- `_reschedule()` now calls `player.stop()` + `player.play()` + invalidates the anchor before re-scheduling, eliminating double-trigger comb filtering from live setting changes.
- Config-change handler: bails early when the format/device hasn't materially changed (avoids destructive no-op restarts).
- Else-branch in `_start()` (Stop→Play): reconnects the player and regenerates buffers when the hardware rate changed.
- `currentRenderSample()`: only caches player times after `clockAnchored` is set (pre-anchor reads no longer poison `lastKnownSampleTime`).
- Format-mismatch branch in `scheduleAhead()`: after regenerating buffers it now also reconnects the player, updates `currentFormat`, and recursively re-enters so stale-format buffers are never scheduled.

### Added

- **`--selftest`** entry — renders 4 bars offline via `AVAudioEngine` manual rendering mode and asserts 16 clicks at the correct sample offsets, accent RMS > normal RMS, and no missing/doubled beats. Run with `swift run Metronome --selftest`.
- **`METRONOME_TAP_RECORD=1`** environment variable — captures the first 5 s of player output to `/tmp/metronome-player-tap.caf` for diagnostic waveform inspection (debug builds only).

### Changed

- **Refill timer first deadline** is now 50 ms (was 200 ms) to keep beat-1 latency at ~350 ms after the clock-anchor redesign.

## 2026-07-25

### Fixed

- **Delayed / no sound after Stop → Play** — sound now starts immediately on every restart.
- **Beat flash out of sync with audio** — accent click now lands on beat 1 with the flash.
- **Missing clicks** (only ~2 of 4 beats audible) — all scheduled beats now play.

**How it was fixed:**
- Root cause: `AVAudioPlayerNode.scheduleBuffer` interprets `AVAudioTime(sampleTime:)` in the *player node's own* timeline, which rebases on `stop()`/`play()` — while the engine/mixer timeline keeps advancing. Scheduling and flash sync used different clocks.
- `currentRenderSample()` now converts mixer render time → player time via `player.playerTime(forNodeTime:)`, so scheduling and the 60 Hz flash driver always share one clock.
- Removed the stale `player.lastRenderTime` fallback (froze on `stop()`, causing past-due buffers silently dropped by AVAudioPlayerNode).
- Reset cached sample times in `_stop()` to defend against stale values from previous sessions.

### Changed

- **Volume slider** is now 0–100% (was 0–300% displayed, with a ×3 boost that saturated at full scale past 33%). 100% = full output, and the entire slider travel is now usable.
