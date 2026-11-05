# How Hot Mic got built

My words are quoted as I wrote or said them, typos fixed, nothing else. **Hashes up to October 28 are from the private development repo.** The public repo starts fresh at `93c94a1` on November 1, because the old history holds private notes and test material. "Private note" means a dated record I keep offline. Times are Eastern until November 1, which is Gulf time.

## 1. The short version

On September 27, 2026 I pitched a menu bar app that catches every sung idea, and said "all at once". That day became a full 1.0 in code: capture, echo cancel, takes, MIDI, Whisper, an audit, a song notebook. I launched it that night. It looked broken to me, and it mostly was invisible.

Two weeks later I came back with a clear brief, found the design in a browser lab, and moved it into the real app in an evening. Then came the first real testing night: every recording was 557 bytes. That got fixed, and I kept testing until the lyric logic started working.

On October 28 I graded it on a livestream test corpus, and the scores were humbling: the live path caught 0 of 21 lines. Nothing in Hot Mic learned anything at that point. On November 1 it went public with a clean history, and a judge pass with a small on-device learner went in. It took talk recall from 0.03 to 0.91 on that corpus.

On November 4 and 5 I went after the boring stuff that loses work: saves that failed quietly, updates that stepped on each other, a Settings panel that opened off screen. None of it touched a mic. Then the release went into this repo, and CI passed 327 Swift tests and 44 window tests.

## 2. Origin, in my words

The pitch (private note, September 27):

> "A menu bar app... as soon as you're in your Ableton session... always on... only picks up your voice when you're singing... has both takes so you can place it in the right spot."

The correction that defined it:

> "It's not supposed to be recording the last few minutes. Once it's on, it's on."

The scope:

> "Given away from day 1, let's make sure it's perfect."

> "All at once."

Why, two weeks in (call, October 8):

> "Anytime I'm about to start jamming on a song, instead of using voice memo, I now prefer to use that."

> "Because when I do a voice memo, I don't have an organized transcript of what I've come up with."

## 3. Timeline

| Date (2026) | What happened | Evidence |
|---|---|---|
| Sep 27 | Recon says crowded market, wedge is sing-only detection. Spec, capture, singing detection, takes, overlay in the first half hour | `9154b38`, `ee194bc`, `5118ebb`, `d964c77` |
| Sep 27 | Bar stamps, key and MIDI, sections, beatbox, lyrics, hub, tuner, licensing, updates | `596042d`, `db6db96`, `b71029c`, `b8189b0`, `d2c77b7`, `89e065f`, `7b0aad6`, `5649d13` |
| Sep 27 | Multi-agent audit: 43 findings fixed, then 27 follow-ups | `3635a43`, `5f676d9`, `ebbd272` |
| Sep 27 | Jam mode (no DAW), Basic Pitch, Song Notebook | `76ed8a5`, `374111e`, `4ccdae7` |
| Sep 28 | First live launch. Icons, whispers, AirPods crash fix | `684d1af`, `9ba3ee3`, `69b6ea1` |
| Sep 28 | Phones join a session over Wi-Fi | `8b18bb4`, `4fbede4` |
| Oct 8 | Call with a collaborator, where I say I'm using it instead of Voice Memos. Spec direction changes | Private note |
| Oct 12 | Design lab, then the real window. Testing night: 49 commits | `2bf5083`, `164b43e` |
| Oct 12 | 557-byte bug found and fixed | `6791a50` |
| Oct 12 | One version, everything on. License tab gone | `e87e1f8` |
| Oct 12 | Lyric rules rebuilt, line-level Whisper, repeats vs versions | `c83efce`, `5a409ca` |
| Oct 12 to 13 | Scenario tests and QA page. Auto-listen built and removed | `1359189`, `9a24b30`, `3baabcd` |
| Oct 13 | Live tests: clipped words, hums, rap read as "playing", chord rows | `edbb842`, `5398523`, `77d7728`, `50a806a` |
| Oct 14 | Notes-style notepad, retake alignment, takes as chunks, brand shipped | `fe9db09`, `1ecb962`, `a1baa2b`, `1a74163` |
| Oct 23 | Idea: log raw, format after Stop. Not built yet | Private note |
| Oct 28 | Benchmark built, model switch, livestream test corpus scored | Private repo, private note |
| Nov 1 | Clean public tree, MIT, security fixes | `93c94a1` |
| Nov 1 | Judge pass after Stop, per-user learner, window controls | `aa475ce`, `8d3aa64` |
| Nov 1 | Encrypted phone link, exact bar stamps, window tests, clean-clone proof | `f1c8951`, `7c4740e`, `b5d9f9a`, `cc81bf2` |
| Nov 1 | Host crash when a phone sings first, fixed. The whole room tested with a simulated phone | `b99e022` |
| Nov 1 | Clean-Mac path: the Whisper model moves out of Documents, install waits for the app to quit | `f070be5` |
| Nov 1 | Long sessions keep everything, stray rewrites stopped, Whisper repairs | `e4a22cc`, `a241eb5`, `b4c72bd` |
| Nov 2 | README, one-pager, build history, banner. The scenario fixture swaps real session words for invented lines | `6704e71`, `75776d7` |
| Nov 4 | Reliability pass: failed saves stop overwriting, judge and window updates stop losing changes | `a8c8a66` |
| Nov 4 | Settings stays inside the window | `b959c88` |
| Nov 5 | First CI run fails 4 checks in the phone test. The fix waits for every frame. CI passes | `5bf41bc` |

Private repo: 121 commits on the main line and 128 in all, with 29 on September 27, 49 on October 12 and 28 on October 14.

## 4. Round by round

### Round 1: everything, at once (September 27)
- **Built:** capture with process taps, a linear echo canceller, singing detection, takes, stamps, MIDI, tuning, lyrics, notebook.
- **Tested:** 122 tests, then 151. End to end on a real song over a simulated laptop room: right takes, talk dropped, 19.6 dB, about 1% CPU. A whisper at about -40 dB came out word-perfect.
- **Broke in review:** WebRTC AEC3 damaged the voice by 32 dB, so it got replaced before it shipped.
- **Wanted next:** "I really want to test the non-Ableton version of it first... jamming... my guitar." So: jam mode, in the same sitting.

### Round 2: first launch (September 28)
- **Built:** icons, whispers as their own take type, an installer.
- **Tested:** me, live. "It didn't detect Ableton or visibly show it's running. The UI is not what we described at all... you missed a lot."
- **Broke:** it had caught Ableton and was recording, but the menu bar icon hid behind the notch, the pill was 10 px at 15% opacity, and the window opened behind Ableton. Also: every session on AirPods died, since at 24 kHz the encoder rejects the bit rate.
- **Fixed:** a readable REC pill, a step-down bit rate, a real error when a start fails.
- **Wanted next:** a rapper humming away from the computer, joining from a phone. Built that night, never run on a phone.

### Round 3: an actual design (October 8 to 12)
- **Built:** a browser lab. Solo and Beat modes, one strip on top, a notepad below. Round one of looks got called bleak, and more rounds followed before a look landed.
- **Tested:** me clicking through variants.
- **Wanted next:** to put it in the real app and sing into it.

### Round 4: testing night (October 12)
- **Built:** the lab as the real window, then fixes in a loop of test, screenshot, fix.
- **Tested:** about four hours of me singing into it.
- **Broke:** every session was a 557-byte file. First suspect was the mic permission race, which was real. The actual cause: `kAudioAggregateDeviceTapAutoStartKey: true` made the device wait for some app to play sound. Then: lines vanishing, "*sad music*" as lyrics, recognizers stalling at 7 to 18 seconds, a lone word as a line.
- **Fixed:** the auto-start flag (`6791a50`), then "what you see is what you keep", where live lines commit on a pause and never clear (`c83efce`), and line-level Whisper (`5a409ca`). Self-tests got built so this class of bug shows up without me.
- **Wanted next:** stop patching by feel.

### Round 5: the QA rig (October 12 to 13)
- **Built:** 63 scenarios, then 78, each with candidate sheets on a page I answer. "This test has to have all variables and hella edge cases."
- **Tested:** I answered 43 of 63. Every pick became a test.
- **Broke:** the rules I wanted conflicted in Freestyle, and round 3 went unanswered. "We might need to rethink how it happens tomorrow."
- **Fixed:** chorus sung twice is two lines, a reworked line is a version, ad-libs get commas, a false start drops.
- **Wanted next:** real sessions again.

### Round 6: live tests (October 13 to 14)
- **Tested:** real sessions on AirPods and on the laptop mic.
- **Broke:**
  - First words got clipped, because words arrive 0.35 to 0.95 s late. Whisper returned nothing on 3 of 7 lines.
  - Hums vanished through AirPods.
  - Rap alone was labeled "playing".
  - An install during a session cut it off at 103 s.
  - The always-typeable board pushed the live line off screen.
- **Fixed:** a 1.4 s clip lead (6 of 7 lines improved), a Bluetooth warning and wordless rows, an instrument score rule, a retake aligner, a watchdog on the recognizer.
- **Also:** the logo took more rounds than the echo canceller. Fire note, flame curls, all flame takes rejected, then the flame-frame H from FLORA.
- **Wanted next:** an objective score. I asked if my feedback trains anything. It didn't: every rule was code.

### Round 7: the benchmark (October 28)
- **Built:** a benchmark on a livestream test corpus: six public streams of songs being written live, graded against reference lyrics and a labeled timeline. A whole-song stitch. A `--model` switch.
- **Tested:** see section 6.
- **Broke:** the app's Whisper build decoded nothing on short sung clips. Turbo fixed it, 0 words to 56. The live path scored 0 of 21, because Apple's recognizer can't hear singing ("No speech detected" over 1,000 times). Talk was never judged as talk, so 56 to 85% of the stitched songs was chatter. Whisper's word timings collapsed on 35 to 80% of versions.
- **Wanted next:** real judgment instead of more rules, plus something that learns.

### Round 8: public, with a judge (November 1)
- **Built:**
  - A clean tree without private test material, a neutral test corpus label, a README, MIT and fixes for the audit's items.
  - `LineJudge`, `ModelPass` (Apple's on-device model reads each line in context after Stop, and fails safe to the rules) and `LineLearner` (a small logistic regression trained on your corrections, on your Mac).
  - Guards: the learner has no say until 12 corrections, only speaks at 0.98 confidence, and backs off if it loses to the verdicts it would override.
- **Tested:** six corpus sessions, 1,704 lines, offline. Rules alone: talk precision 0.67, recall 0.03, writing kept 0.93, whole-song talk 71%. On-device model: 0.93, 0.88, 0.89, 30%. Model plus learner, leave-one-out with up to 30 simulated corrections from the other sessions: 0.91, 0.91, 0.91, 25%. Thresholds were tuned on the same corpus, and a later prompt change (`b4c72bd`) came after this table. Apple's default guardrails refused 80% of one session, so explicit words are masked in what the model reads, and only there: 8 of 1,704 lines refused, 1 timed out. A 1.7B local model through MLX kept 4% of writing, so there's nothing to download.
- **Wanted next:** everything I could still test without singing into it.

### Round 9: the rest of the list (November 1)
- **Built:** the phone link encrypted with Noise, checked against a public vector. Bar stamps from a line through the last beat of clocks. The real window page running in jsdom with no audio. `scripts/verify-clean.sh`.
- **Tested:** a simulated phone through the encrypted link to a take on disk. Bar stamps on simulated clock streams: within 10 ms apart from a tempo jump and a clock that arrives 60 ms late.
- **Broke:** a host crash when a phone sang at the start of a session. Takes clamped to 12 minutes of scratch audio, which lost 507 of 507 seconds of writing on one song. Unrelated lines paired as rewrites, so the newest hid the real line. Typed lines got lowercased.
- **Fixed:** all four. Takes now close at 5 minutes. One song went from 0 of 21 released lines shown to 8. Whisper's line times went from a median 14 s off to 2.4 s on a tuning song.
- **Wanted next:** me, singing into this build.

### Round 10: stop losing work (November 4)
- **Built:** nothing new to sing into. This round was about not losing what's already there. Pasting a verse now writes the live-lines file once instead of once per line.
- **Tested:** all of it offline. Nothing in this round opened the app, a real audio device or a real model. The debug app compiled, and 100 selected offline Swift tests and 42 window tests passed. Six new Swift tests and one new window test each failed on the old code before the fix. The lyric scenarios: 50 answered cases pass, 18 are still open, 10 are page only. A 300-line paste took 915 ms before and 5 to 7 ms after, in debug builds on one Mac.
- **Broke:**
  - A judge checkpoint could write over corrections I'd just made.
  - Learner, profile and live-line updates running at the same time could lose changes.
  - A cancelled or timed-out model pass didn't clean up after itself, and a refusal could be read as a verdict.
  - A routine refresh restarted Beat playback.
  - An old session that finished loading late could replace the one I'd just picked.
  - A malformed drag rectangle crashed the bridge between the window and the app.
  - A second review found two worse ones: a fallback read could write defaults over a damaged file, and a failed write could still report a correction as learned. Four fixture tests reproduced that with seven failed checks.
  - A native WebKit run of the window showed Settings opening off screen, because app mode hides the gear it hangs from.
- **Fixed:** all of it (`a8c8a66`, `b959c88`). Damaged and unreadable files stay where they are. Failed reads, encodes and writes get reported. A judge checkpoint or final save that fails stops there, and a paste that didn't save goes back in the box. Settings falls back to opening inside the window. After the fixes, 83 Swift and 43 window tests passed, then 17 of 17 save tests including permission-denied reads, then 44 window tests and 11 native WebKit checks.
- **Wanted next:** get it into this repo cleanly. Also still on the list: the compiler's concurrency warnings, and measuring all of this on real hardware.

### Round 11: the release (November 5)
- **Built:** the release commit, `5bf41bc`, pushed as a normal commit on the clean history.
- **Tested:** CI on every push. See section 6.
- **Broke:** the first CI run on `b959c88` failed 4 checks, all in one test: a simulated phone joins with the QR code, sings, and should end up as a take on disk. The test hung up after a fixed half second while its sped-up stream was still being processed, so no take landed. A stream with no pacing reproduced all four failures locally.
- **Fixed:** the singer's snapshot now shows how many frames arrived, and the test waits for every one of them before Stop. The fixture is 10 seconds at 16 kHz and still carries the whole melody. No timeout went up, no check got skipped, and nothing about detection or the link changed (`5bf41bc`). Three focused tests passed locally, then CI passed: 327 Swift tests (7 skipped, 0 failures) and 44 window tests. The phone-to-take test took 3.984 s.
- **Wanted next:** same as round 9. Me, singing into this build.

## 5. Feature family tree

```
Voice Memos pain
└─ whole-session recording → takes → voice + mix files
   ├─ speakers → echo canceller → DAW monitoring detection
   ├─ DAW clock → bar stamps → MIDI per line and per 4 bars
   ├─ Whisper → lyric sheet → Song Notebook → versions, stars
   │  └─ live lines → per-line Whisper → LyricArranger → QA scenarios (78)
   │     └─ benchmark → turbo fix, 0 to 56 words → judge after Stop → learner
   │        └─ corrections worth keeping → saves that refuse to write over a damaged file
   ├─ jam mode → tempo, chords, Basic Pitch → chord shapes
   └─ Beat mode → beat runs → looped playback in sync
   hub → design lab → the real window → notes-style notepad → typing
   "rapper away from the computer" → phone join (paused) → encrypted link → simulated phone to a take
   "log raw, format after Stop" (Oct 23) → the judge runs after Stop
```

## 6. Test log

| When | What | Result | Where |
|---|---|---|---|
| Sep 27 | Unit tests | 122, then 137, then 151 | Private notes |
| Sep 27 | AEC on a simulated room | 19.6 dB settled, 1.1% CPU. **Simulated** | Private note |
| Sep 27 | Strummed C-Am-F-G at 100 BPM | 100 BPM, all 8 chords, key C | Private note |
| Sep 27 | Whisper voice at about -40 dB | Word-perfect | Private note. Synthetic voice |
| Oct 12 | App self-tests after the fix | 6 of 6 record | Private note |
| Oct 13 | Per-line Whisper on my rap | 3 of 7 lines empty before, 6 of 7 improved after | Private note |
| Oct 12 to 13 | Lyric scenarios | 63, then 78. I answered 43 of 63 | Private note |
| Oct 28 | Unit tests | 192 run, 7 skipped, 0 failures | Private note |
| Oct 28 | First song, import, 21 reference lines | 3 caught. With turbo, 5 caught, 3 shown right | Private note |
| Oct 28 | First song, live path, 21 lines | 0 caught. With turbo, 1 caught, 0 shown right | Private note |
| Oct 28 | Other five songs, split input, turbo | Caught 12/21, 5/18, 6/19, 2/6, 8/20 | Private note. Two references are stand-ins |
| Oct 28 | Talk judged as talk | 0% in every condition | Private note |
| Nov 1 | Rules vs model vs model + learner | Talk recall 0.03, 0.88, 0.91. Writing kept 0.93, 0.89, 0.91 | `docs/SPEC.md` |
| Nov 2 | Unit tests and window tests | 303 run, 7 skipped, 0 failures; 41 window tests pass | This repo |
| Nov 4 | Selected offline Swift tests and window tests | 100 Swift and 42 window pass. 7 new regression tests fail on the old code first | Private note |
| Nov 4 | Save safety | 4 fixture tests, 7 failed checks before. After: 83 Swift and 43 window pass, then 17 of 17 save tests | Private note |
| Nov 4 | Native WebKit window check | Settings off screen before. After: 44 window tests and 11 native checks pass | Private note |
| Nov 4 | 300-line paste, debug build, one Mac | 915 ms before, 5 to 7 ms after | Private note |
| Nov 5 | CI on `b959c88` | 327 run, 7 skipped, 4 failures, all in the phone-to-take test | CI run 41970152825 |
| Nov 5 | CI on `5bf41bc` | 327 run, 7 skipped, 0 failures; 44 window tests pass | CI run 41972009240 |

These are harsh tests: stream audio, not a close mic, and one song's six "caught" lines came from playback, not writing. There is no scored benchmark of my own sessions.

## 7. Roads not taken

- **A rolling buffer.** Rejected in the first hour. Once it's on, it's on.
- **WebRTC AEC3.** Damaged the voice.
- **Beatbox to drums in V1.** Built and pulled: "It seems a bit overkill." Beatbox rows came back later.
- **A free vs Pro split with license keys.** Built, then removed. One version, everything on.
- **Auto-listen.** Built, merged, removed. It started recording when the window opened.
- **Thesaurus.** Out. Tuning presets dropped. Flame icons, all rejected.
- **The floating overlay.** Retired for a small REC pill once there was a real window.
- **A rhyme panel and a blank-page mode.** Built on a branch, not in this repo.
- **YouTube to file inside the app.** Advised against. Dropping an audio file covers beats.

## 8. My method

1. **"All at once", then test it for real.** Build the whole idea, then let live use tear it apart.
2. **Labs before the app.** One browser page, flip through variants, pick, then port.
3. **Debug with self-tests and the system's own logs.** The 557-byte bug fell once the logs got read.
4. **Turn judgment into tests.** Every answer on the QA page becomes a test, so rules stop drifting.
5. **Grade it somewhere harsh.** A public bench full of bad news beats a private feeling that it's fine.

## 9. What's next

- Sing into this build and score the judge on my own sessions.
- Make line-cutting not depend on Apple's live recognizer.
- A scored test on my own sessions.
- A signed, notarized download so people don't need Xcode.
- A cypher mode that spots beat switches. Whole-song stitching that sounds like a song.

## 10. Sources

- Public: this repo, starting at `93c94a1`. `docs/SPEC.md`, `SECURITY.md`, `Sources/Library/LineJudge.swift`, `LineLearner.swift`, `ModelPass.swift`, `Sources/Library/PersistenceFile.swift`, `bench/`. CI runs 41970152825 and 41972009240 (November 5).
- Private, kept by me: the private development repo log. Session captures dated September 27 to October 28, 2026. A call recording, October 8. Benchmark reports, kept local and never published. Maintenance and release reports with their test logs, November 4 and 5, 2026.
