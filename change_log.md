# Changelog

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
