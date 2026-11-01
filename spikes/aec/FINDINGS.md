# Spike 0 findings (synthetic only — real fixtures pending)

2026-09-27. Synthetic fixture = real instrumental + fake room (delay, reverb, speaker band-pass, tanh distortion) + hummed melody from 8 s. Not a substitute for Nate's recordings.

| stage | music removed | voice kept (SI-SDR, time-aligned) |
|---|---|---|
| raw mic | 0 dB | −1.1 dB |
| WebRTC AEC3 (livekit APM) | 28.6 dB | −2.6 dB |
| AEC3 + noise suppression | 41.1 dB | −4.1 dB |
| linear PBFDAF (ours), heavy distortion | ~7 dB | +0.3 dB |
| linear PBFDAF, clean speaker path | 20–23 dB | — |
| linear PBFDAF, mild distortion | 19–22 dB | — |

**Read**
- AEC3 hits the dB target but damages the voice. Its residual suppressor is built for calls; constant music = permanent double-talk, so it gates/smears the singer. Voice kept got WORSE than raw.
- Linear-only cancellation keeps the voice intact and removes ~20 dB when the speaker isn't distorting. Speaker distortion is the limit.
- AEC3 adds 10–16 ms latency + polarity flip; irrelevant for takes, relevant for sample alignment → alignment must be measured, not assumed.

**Direction (pending real fixtures)**
Stage 2 = linear adaptive filter (no suppressor), **stereo reference** (L and R reach the mic by different paths; mono sum loses cancellation). Stage 4 = neural vocal separation per take to clean the nonlinear residual. AEC3's suppressor only as an optional "aggressive" mode.

Next: Nate's three real fixtures → rerun `bench.py` (add `--neural`).
