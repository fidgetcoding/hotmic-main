# Spec: Hot Mic

Owner: Nate Davidovich · Brand: blue gum (always lowercase) · License: MIT

## Objective

A free macOS menu bar app that catches every hummed or sung idea during a music-making session, without the songwriter ever pressing record.

**User:** songwriters, vocalists and rappers on a Mac: anyone writing words over a loop, freestyles included.

**The promise:** you never stop writing the song to pick up a pen. You stay in the loop, spitball lines, and trust that every version is kept. When you settle on a way of singing a line, that becomes the main version and the earlier ones stay as alternates. You end on finished lyrics.

**Why:** ideas get lost because stopping to record a voice memo breaks flow. And the voice memo itself is a dead end: an hour-long recording with no transcript and no markers, so finding a good part, or hearing the other ways you sang a line, means scrubbing the whole file. Existing tools (BUFFR, killihu Capture Audio, Rewind, Audio Hijack) all need a manual grab or per-session setup, none detect *singing* specifically, none remove speaker bleed, none produce per-idea paired takes.

**User stories**
1. When I open any supported DAW, Hot Mic arms itself. I do nothing.
2. When I hum or sing, a take is created. Talking, coughs and the track itself do not create takes.
3. Each take gives me two files: my voice clean, and my voice mixed with what was playing.
4. Each take is stamped with bar/beat/tempo, so I can drop it on the right bar.
5. It works on headphones, laptop speakers, Bluetooth, and external interface monitors. It figures out which on its own.
6. Each take has a lyric transcript, a MIDI version snapped to the song's key, and a pitch-corrected audio version.
7. My takes show up on my other devices through my own cloud folder.
8. One click in the menu bar: on/off, recent takes, open folder. Nothing else required.

## Scope

**In (1.0 — ships only when ALL pass Success Criteria):**
- Menu bar app (single button + minimal menu), launch at login
- DAW auto-detect: Ableton Live, Logic Pro, FL Studio, Bitwig, Reaper, Cubase, Studio One, GarageBand (by bundle ID; list is user-editable)
- Continuous whole-session recording to disk while armed (NOT a rolling buffer)
- Singing/humming detection → per-idea take slicing with padding pulled from the continuous recording
- Output route detection (device metadata as prior + bleed-correlation as truth)
- Echo cancellation against a digital reference of session audio when on speakers
- Two sample-aligned takes per idea: `voice` and `voice+session`
- Bar/beat/tempo stamping via MIDI clock + Song Position Pointer on a virtual "Hot Mic Sync" MIDI port
- On-device lyric transcription per take
- Key detection from the session audio → voice-to-MIDI snapped to key
- Pitch-corrected ("tuned") voice take, corrected toward the detected key
- Output to a user-chosen folder (default inside iCloud Drive) = cloud sync
- Signed + notarized

**Out (1.0):** Windows, iOS/iPadOS app, own cloud backend/accounts, auto-inserting clips into the DAW, telemetry that sends audio anywhere.

**Later:** iOS companion (browse/play takes), Windows, optional JUCE "Hot Mic Sync" plugin for time-signature-accurate stamping.

## Look & Feel — invisible hover overlay

- No window, no dock icon. Surface = a floating overlay "ghost pill" (non-activating `NSPanel`, always on top, all Spaces, over full-screen DAWs). It NEVER takes focus or keystrokes from the DAW.
- Idle mode is a user setting:
  - **Ghost** (default) — tiny translucent pill (~10–15% opacity) at top-center under the notch/menu bar, so armed state is glanceable.
  - **Invisible** — 0% opacity; the overlay appears only when the mouse touches a hot zone at the pill's position (screen edge).
  - Both: click-through when not hovered.
- Hover: fades up (~150 ms) and expands into frosted glass (`NSVisualEffectView`): one big on/off button, live mic level, route badge (🎧/🔈), last 3 takes (click = play, drag = drop into DAW), open-folder.
- Take caught: one soft pulse on the pill, no sound, no notification banner. In Invisible mode the pulse briefly shows the pill, then it vanishes again (toggle: "flash on take").
- Mouse leaves: fades back to ghost after ~1 s.
- Menu bar icon stays as the fallback entry point + settings.
- Light by default; glass follows system appearance but never ships dark-by-default.
- Settings: idle mode (Ghost / Invisible), ghost opacity slider, pill position (top-center / any corner), flash on take.

## Vision — Song Notebook (scope/phase TBD)

Hot Mic grows from "idea catcher in the DAW" into a **songwriting notebook** that also works without any DAW, and later on the phone.

- **Knows where you are in the song:** every take is placed on the song's blocking (sections from DAW locators, bar position, or inferred structure).
- **Collects every variation:** each time you sing a section again, the new pass is lined up line by line with the earlier ones (lyrics transcript + melody contour + bar position), so one lyric line shows all the different versions you've sung.
- **Shows your options:** per section and per line: every variant's words and audio, what's changed between them, favorites; "comp" a version by picking a line from each pass → exports a lyric sheet + stitched audio. Pick the versions you like and it pieces them together. Built: star per line → `draft.md`. Missing: stitched audio.
- **Main version, automatically:** when you start singing a line a certain way and stick with it, Hot Mic marks it as the main version and lists everything before it as alternates. A star still overrides. Today: main = your star, else the newest version, so a one-off experiment replaces the main. Proposed rule: a wording becomes main once you sing it on 2 passes in a row; a single new pass shows as "trying" until it repeats.
- **How you sang it, not only the words:** each version keeps its rhythm on the beat grid (the flow, for rappers) and its melody, so the same words with a different flow count as a different version.
- **Chords in the map:** chords sit under the lyrics on the same timeline. Built: chords per take in jam mode, and from the session audio in DAW mode; vocabulary = major, minor, 7, maj7, m7. Missing: add9, sus2/4, 6, dim, aug.
- **The whole session, mapped:** words, flow and chords on one timeline, with cause and effect: "here you changed what you said, and that led to a chord change."
- **Send it to a collaborator:** share the mapped session, e.g. with your guitarist, who sees every version with its chords and can play each one. An async hand-off, separate from live Session join.
- **Standalone mode:** no DAW — just the mic (Mac first, then an iPhone app). The same library format syncs through the user's cloud folder, so phone ideas and studio ideas land in one notebook.

- **Live lyric lane while tracking:** also for proper recording inside the DAW. While you freestyle pass after pass onto an audio track, each pass's words appear live, stacked by bar, so you see exactly what you sang in every pass. Requires handling DAW input monitoring (voice present in the session audio) — detection built 2026-09-27.
- **A brain for your DAW + songwriting:**
  - Knows which song/project you're in (Hot Mic Link reports the Live set; Live `.als` files are gzipped XML — tempo, locators, track and clip names are readable; other DAWs via their scripting or the open file).
  - Indexes every project and every take you've ever made, so when you sing lyrics that already exist it says where they're from (song, section, take).
  - Remembers your whole lyric catalog and flags repetition across songs (phrases, rhymes, images you keep reusing).
  - All on-device.
- **Feed it anything, no DAW library needed:** a dashboard where you drop in finished songs (audio → transcribed + key/structure analysed) or paste lyrics you already wrote in notes elsewhere. They join the same lyric memory as captured takes, so recognition and repetition checks cover your whole catalog, not just what Hot Mic heard.

Builds on data 1.0 already produces (takes, bar stamps, sections, lyrics, key, MIDI). New pieces: take↔line alignment, a Notebook window, standalone capture, iOS app.

## The hub — "Splice, for your own ideas"

Hot Mic is an app, not only a menu bar item: a songwriting hub window usable with no DAW open (sessions, takes with lyrics/bar/key/section, imported songs, lyric brain with search + "you keep coming back to"). It shows itself when a DAW launches (setting, default on, never steals focus), gets a dock icon while open, and goes back to menu-bar-only when closed. Built 2026-09-27.

## Vision — Session: join from your phone (phase TBD)

The studio case: the producer plays the beat, the rapper is across the room humming ideas. The rapper's phone joins the producer's Hot Mic session; every take lands in a shared bank inside the producer's DAW, already placed on the bar it was hummed on, and he drags it in.

**Roles:** host (the Mac running the DAW), contributors (phones or Macs singing takes in), listeners (public rooms only).

**Joining:**
- **QR code** — the host's hub/overlay shows one; scan with the phone camera to join. First-class, not a fallback.
- **Nearby** — sessions on the same Wi-Fi show up automatically (Bonjour).
- **Friends** — add people by username; their live sessions appear in the app; one tap to join.
- **Invite link** — text it to anyone; opens the app or the App Store.
- Host chooses: friends auto-join, or approve each person.

**Capture on the phone:** full-quality recording on the device (same sing-only detection as the Mac), plus a low-bitrate live preview so the host hears it as it happens. The full-quality file uploads when the take closes.

**Keeping takes in time:**
- **In the room:** the phone mic hears the beat through the speakers; the host has the same beat from its digital tap. Cross-correlating the two gives the exact offset and corrects drift over a long session, with no clock setup. Ableton Link (same network) adds bar/beat phase.
- **Remote:** Link doesn't work over the internet and the phone can't hear the room, so the host streams the beat to the phone, the contributor records against it, and the take is placed from the host's playback position plus measured delay.

**Clean voice:** once aligned, the existing echo canceller removes the beat bleeding into the phone mic, using the host's digital tap as the reference (same design as Mac speaker mode).

**The shared bank (host side):** a Max for Live device + a "Session" lane in the hub. Each take shows who sang it, bar, section, lyrics, key. Drag into the arrangement → lands on its original bar. Works with several contributors at once.

**Public rooms (later):** people join a producer's room on stream. Contributor takes reach only the host, who previews and picks what enters the bank (nothing a troll sends ever reaches the stream). An OBS overlay shows who's singing, live lyrics, and a "just pulled into the song" moment. Needs rate limits, kick/ban and reporting before any public room opens.

**Transport:** same room = direct peer connection; remote = a media relay (LiveKit is the usual pick; can be self-hosted).

**Order:** 1) nearby + QR (no accounts) → 2) friends + invite links (needs accounts) → 3) public rooms (needs moderation).

**Depends on:** iOS app (required so Session works with the rest of Hot Mic); accounts + cloud (friends, invites, remote, public rooms).

**Security status: experimental, off by default.** The phone link is plain TCP on the local network: audio, the join token and the device ID are not encrypted, so anyone on the same network can read them, and a sniffed device ID can impersonate an "always let in" phone. Use it only on a network you trust. Invites carry private-range (RFC 1918) addresses only, the iPhone asks before any `hotmic://` link or scanned code joins, and a phone waiting for approval holds its slot for 60 s at most. TLS with per-device secrets is required before this leaves experimental.

**Built (step 1, 2026-09-28):** `SessionKit/` (shared package: wire format, QR invites, Bonjour, clock sync, GCC-PHAT + drift-fit aligner), `Sources/Session/` (Mac host: reference tap, per-phone aligner → echo canceller → take pipeline, room with approvals + beat streaming), hub "Phones" pane (QR, Let in / Always let in, singers with sync state), phone takes tagged `_by-<name>` + `singer` in the sidecar, `iOS/` iPhone app (Nearby, QR scan + camera link, room/headphones modes, background recording, resend after reconnect). Remote over the internet, friends, invite links and public rooms still need accounts + a relay (step 2/3). M4L "drag to original bar" bank still deferred (can't verify an .amxd without Max).

**Riskiest piece:** echo cancellation with the phone ~20 ft from loud studio speakers in a reverberant room — current tests put the mic next to a laptop. Spike: record one real phone take in a studio and run it offline through the canceller before building anything else.

## Requirement — Slang and how rappers actually talk

Rappers have to trust the transcript. It must keep slang, contractions, ad-libs and made-up words as said ("finna", "tryna", "ion", "bruh", "skrrt", nicknames, brand and place names), never "correct" them into standard English.

- **Verbatim decoding:** Whisper runs with a prompt written in slang-heavy, lowercase, contracted style (today it's only prompted with the session's own recent lyrics), so it keeps that register instead of normalizing it.
- **Slang lexicon:** a built-in list of common rap/AAVE/regional slang and ad-libs used to bias recognition and to stop the post-pass from "fixing" them.
- **Your dictionary:** every time you fix a word in edit mode (e.g. "going to" → "finna", a misheard name), Hot Mic learns it and prefers your spelling next time. Per user, on your profile.
- **Never rewrites meaning:** no autocorrect, no censoring, no standardizing. If unsure, keep what was sung.
- **Measured:** a test set of real rap and freestyle clips with hand-checked transcripts; track word accuracy on slang words specifically, not just overall.

## Vision — Profile & lyric analysis (phase TBD)

Every user has a profile that reflects their own writing back at them. **Analysis only, never suggestions**: Hot Mic describes what you write and sing; it never tells you what to write, never rewrites, never scores you as "good/bad".

- **Lyric diversity:** vocabulary size, unique words per song and over time, how often you reuse lines/phrases across songs (ties into the "brain" repetition flag).
- **Words used:** most-used words and phrases (stop-words filtered), words you've only used once, new words this month.
- **Themes:** an agent reads your lyrics and names the themes you tend to write about (e.g. night, leaving, home, money), with how often each shows up and which songs it comes from. Stated as observation ("you write about X in 9 of 14 songs"), never as advice.
- **Over time:** how the above shifts across sessions and months.
- **Source:** your own takes + imported finished songs (hub import). Only your own material, on your profile; analysis runs on-device or in your account, never shared without you turning it on.

## Architecture

```
 ┌───────────── Hot Mic.app (menu bar, Swift) ───────────────┐
 │                                                            │
 │ DAWWatcher ──arms──▶ SessionRecorder                       │
 │ (NSWorkspace)          │                                   │
 │                        ├─ MicInput (AVAudioEngine)         │
 │                        ├─ SessionTap (Core Audio process   │
 │                        │   tap on DAW pid; fallback: all   │
 │                        │   system output)                  │
 │                        ├─ ClockAligner (drift correction   │
 │                        │   mic ↔ tap)                      │
 │                        ├─ RouteDetector (speakers/phones)  │
 │                        ├─ EchoCanceller (speakers only)    │
 │                        └─ DiskWriter (AAC .m4a, continuous)│
 │                                                            │
 │ SyncListener ◀── virtual MIDI port "Hot Mic Sync"          │
 │ (MIDI clock + SPP → bar/beat/tempo timeline)               │
 │                                                            │
 │ SingingDetector (VAD + pitch) ──▶ TakeSlicer               │
 │                                      │                     │
 │                         ┌────────────┴─────────────┐       │
 │                         ▼            ▼             ▼       │
 │                  Transcriber   KeyDetector    Exporter     │
 │                  (whisper)     (session audio) (2 takes +  │
 │                                   │            sidecar)    │
 │                                   ▼                        │
 │                          MelodyToMIDI + Tuner              │
 └────────────────────────────────────────────────────────────┘
```

Bounded contexts: **Capture** (recorder, tap, AEC, route), **Timeline** (sync, bar math), **Detection** (singing detector, slicer), **Enrichment** (transcribe, key, MIDI, tune), **Library** (exporter, folder, index), **Shell** (menu bar UI, settings, permissions).

Heavy enrichment runs off the real-time thread, queued per take, at low QoS. Capture never waits on enrichment.

## Voice Isolation (how `voice` is made)

Advantage over generic vocal separators: Hot Mic has the exact digital copy of what's playing (process tap), so it subtracts a *known* signal instead of guessing.

1. **Align** — clock-drift correction + delay estimate between tap and mic.
2. **Linear echo cancel (live)** — WebRTC AEC3: adaptive filter learns the speaker→room→mic path (delay, EQ, reverb) and subtracts the predicted music. Removes the bulk.
3. **Residual suppression (live)** — AEC3's suppressor for what the linear stage can't model (laptop-speaker distortion).
4. **Neural cleanup (per take, offline)** — vocal-separation model (candidates: BS-/Mel-RoFormer, HTDemucs) run on the take only, fed the stage-3 output; removes leftover music bleed and room noise. Runs within the 60 s enrichment budget. License of model weights must be checked (Ask first).
- Headphones: stages 2–4 skipped or light (bleed gate only).
- Spike 0 tests stages 1–3 AND stage 4, and reports dB suppression per stage.

## Song Structure (sections)

Each take and each lyric line is tagged with its section.
- **Read the DAW's own labels (exact):** Ableton Live locators/cue points via an optional M4L "Hot Mic Link" device (LOM `live_set cue_points N` → `name` + `time` in beats, both observable — verified docs.cycling74.com/apiref/lom/cuepoint 2026-09-27). Reaper/Bitwig via their scripting APIs later. Other DAWs don't expose markers externally.
- **Infer from audio (fallback):** music-structure analysis on the session tap → boundaries + labels (intro/verse/chorus/bridge) from repetition and energy. Tagged as `guess` in the sidecar.
- **Output:** per-session `lyrics.md` lyric sheet grouped by section with bar numbers, plus section in every take's filename/JSON.

## Tech Stack (proposed — confirm "Ask first" items)

| Piece | Choice | License | Notes |
|---|---|---|---|
| App | Swift 6, SwiftUI `MenuBarExtra` | — | macOS 14.2+ (process taps) |
| Session audio | Core Audio process taps (`AudioHardwareCreateProcessTap`) | Apple | Ref: insidegui/AudioCap (BSD-2) |
| Echo cancel | WebRTC AEC3 (standalone build) — SpeexDSP as fallback | BSD-3 / BSD | Decided by Spike 0 |
| Voice activity | Silero VAD (ONNX) | MIT | <1 ms per 30 ms chunk |
| Pitch | SwiftF0 (ONNX) | MIT | 46.9–2,093 Hz |
| Transcription | WhisperKit (Core ML), model `large-v3-v20240930_turbo` (~1.6 GB, downloads on first use) | MIT | The compressed 626 MB build decodes nothing on short sung clips |
| Key detection | TBD (Spike 4) — candidates: own chroma+profile impl, libKeyFinder (GPL-3), Essentia (AGPL-3) | varies | License drives choice |
| Pitch correction | signalsmith-stretch (vendored) | MIT | |
| MIDI | CoreMIDI virtual source/destination | Apple | |
| Encoding | AVAudioFile AAC `.m4a` | Apple | voice 96 kbps mono, mix 192 kbps stereo |
| ML runtime | ONNX Runtime (CoreML EP) | MIT | |

## Output format

Per take, in `<Library>/<DAW set or date>/`:

```
2026-09-27_1642_bar-33_128bpm_Amin__voice.m4a
2026-09-27_1642_bar-33_128bpm_Amin__mix.m4a
2026-09-27_1642_bar-33_128bpm_Amin__tuned.m4a
2026-09-27_1642_bar-33_128bpm_Amin.mid
2026-09-27_1642_bar-33_128bpm_Amin.json   # start bar/beat, tempo, key, lyrics, confidences, source app
```

Plus one continuous `session__voice.m4a` + `session__mix.m4a` per session (for anything detection missed). Retention setting: keep full sessions N days (default 14).

## Commands

```
Build:   swift build
Test:    swift test
App:     scripts/bundle.sh            # → .build/Hot Mic.app (ad-hoc signed)
Spikes:  spikes/capture/build.sh · (cd spikes/aec && uv run bench.py <dir>)
Release: scripts/release.sh           # T5.3: sign → notarize → staple → dmg
```

## Project Structure (Swift package, no Xcode project)

```
hotmic/
  Package.swift
  Sources/
    CRingBuffer/     lock-free SPSC float ring (C)
    Capture/         arming, aggregate + tap, route detection, mixer, AAC writer, recorder
    HotMic/          menu bar shell (executable)
    (Timeline/ Detection/ Enrichment/ Library/ added as their phases start)
  Tests/CaptureTests/
  Resources/         Info.plist, entitlements
  spikes/            throwaway experiments (capture CLI, AEC bench)
  fixtures/          audio test corpus
  scripts/           bundle, release
  docs/
```

## Code Style

```swift
/// Typed boundary: every package exposes a protocol, implementations are internal.
public protocol TakeSlicing: Sendable {
    func slices(in activity: [VoiceActivity], padding: Duration) -> [TakeRange]
}

struct PaddedTakeSlicer: TakeSlicing {
    let minimumSinging: Duration = .milliseconds(800)
    func slices(in activity: [VoiceActivity], padding: Duration) -> [TakeRange] { … }
}
```

Protocol per boundary, value types, `Duration`/sample counts never raw `Double` seconds across boundaries, no work on the audio render thread beyond copying into a lock-free ring buffer. Files under 500 lines.

## Testing Strategy

- Unit: XCTest per package, mocks for every protocol boundary.
- DSP regression: a fixture corpus in `fixtures/`, recorded on an external interface with studio monitors and on a MacBook's built-in speakers:
  - 20 hum/sing phrases over 5 genres at 3 playback levels, headphones + laptop speakers + studio monitors
  - 20 min of talking, coughs, tapping, room noise (negative set)
  - 10 songs with known keys; 30 sung phrases with hand-labeled notes and lyrics
- Soak: 4-hour armed session, measure CPU, memory, disk, dropouts.
- Release check: fresh macOS VM, install signed dmg, grant mic + audio-capture permission, verify first take end-to-end.

## Success Criteria (proposed targets — confirm or change)

| Area | Target |
|---|---|
| Arming | Armed within 3 s of a supported DAW launching; disarms within 10 s of quit |
| Detection recall | ≥ 95% of sung/hummed phrases ≥ 1 s become takes |
| False takes | ≤ 1 per hour of talking/noise-only audio |
| Clipping | 0 takes missing the first syllable (padding ≥ 1.5 s) |
| Echo cancel | Music ≥ 25 dB quieter in `voice` than in raw mic on laptop speakers at normal level; no audible voice artifacts on the fixture set |
| Route detect | Correct speakers/headphones call within 3 s of playback, incl. external interfaces |
| Alignment | `voice` and `mix` sample-aligned; bar stamp within ±10 ms while transport runs; drift < 1 ms over 4 h |
| Key detection | ≥ 85% exact key on the 10-song set (relative major/minor counted separately) |
| MIDI | ≥ 90% of labeled notes correct pitch + onset within 50 ms |
| Tuned take | Every note within ±15 cents of target; no audible warble on held notes |
| Transcription | ≤ 25% word error rate on sung fixture lyrics |
| Cost | CPU ≤ 5% avg on M1 while armed (enrichment excluded); ≤ 400 MB/hour disk incl. both session files |
| Enrichment latency | Take files within 5 s; MIDI/lyrics/tuned within 60 s of the take ending |
| Overlay | Never steals focus or keystrokes from the DAW; hover-expand ≤ 150 ms; idle pill invisible in screenshots at default opacity unless looked for |
| Ship | Signed, notarized, installs clean on a fresh macOS 14.2+ machine |

## Boundaries

- **Always:** keep capture real-time-safe; run tests before committing; audio never leaves the Mac except via the user's own sync folder; respect macOS permission prompts with clear copy.
- **Ask first:** adding any dependency; choosing GPL/AGPL code (it forces the app's license); changing the output file format; anything that phones home (update checks included).
- **Never:** send audio/lyrics to a server; record while no DAW is running unless the user manually armed; commit signing certs or notarization credentials; dark mode as the default.

## Build Order

0. **Spike 0 — echo cancellation (gate).** Offline: record DAW process tap + laptop mic while humming over a loud beat; run AEC3 and SpeexDSP; measure suppression and listen. Fail → rethink speaker mode before anything else.
1. Capture + route detection + continuous recording
2. Detection + slicing + two takes + menu bar shell
3. Timeline (MIDI clock/SPP) stamping
4. Enrichment: transcription → key → MIDI → tuned take
5. Library, retention, sync folder, signing, soak, release

## Decisions

1. **License:** MIT. Key detection written in-house (no GPL/AGPL).
2. **Distribution:** brand blue gum; GitHub releases.
3. **Updates:** Sparkle, appcast hosted on GitHub.
4. **Tuned take:** natural correction (keeps slides/vibrato); hard-snap as a setting.
5. **Time signature:** 4/4 default, menu override; exact from Hot Mic Link in Live.
6. **Hot Mic Link (M4L, optional):** yes — section labels + exact time sig in Live.
