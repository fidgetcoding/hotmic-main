# Hot Mic: the essence

**What it is.** A macOS app by blue gum that records a whole songwriting session and turns it into a notepad: every line you sang, every version of it, one click from the moment you sang it. Swift, with a web view for the window. On your Mac only. MIT.

**Who it's for.** Songwriters, vocalists and rappers writing over a loop or a guitar on a Mac.

**Why it exists.** I'd turn on Voice Memos, go for an hour, and end up with a file I had to scrub to find anything. No transcript, no markers. Stopping to write breaks the flow that made the idea.

**What's different.**

- It records everything and sorts it out after. Ideas can't get lost to a late button press.
- Versions are the point. The same line sung five ways becomes one line with five versions.
- It's made for how rappers actually talk: slang, ad libs, mumbles, whispers.
- After you hit Stop, an on-device model sorts your writing from your chatter, and a small learner picks up from your corrections.
- Audio stays on the Mac. There's no account.

**How to try it.** You need macOS 14.2 or newer and Xcode with Swift 6. There's no download yet, so you build it:

```bash
git clone https://github.com/fidgetcoding/hotmic-main.git
cd hotmic-main
./scripts/install.sh
```

That script replaces `/Applications/Hot Mic.app`, pins it to the Dock and opens it. The [README](README.md) has the full steps, plus the checks you can run without opening the app or touching a mic.

**What works today.**

- Whole-session recording, takes, live lines, Whisper fixes line by line, versions, stars, Freestyle and Beat, drop import, typing, and chords and key from `playing` takes. I've used these on my own Mac in real sessions (October 12 to 14), and I prefer it to Voice Memos for jamming.
- CI on November 5: the build, 327 Swift tests (7 skipped, 0 failures) and 44 tests of the real window page. Of 78 lyric scenarios, the 50 I've answered all pass as test cases and 18 are still open.
- The judge after Stop, on six livestreamed songwriting sessions and 1,704 lines: talk precision 0.91, talk recall 0.91, writing kept 0.91 with the model and learner, against talk recall of 0.03 for rules alone. Those sessions also tuned it, so my own sessions will likely score lower. The numbers and method are in [docs/SPEC.md](docs/SPEC.md).
- Echo cancellation: 19.6 dB on a real song through a simulated laptop room, about 1% CPU. That's a simulation, not a measured room.
- Saving: 17 tests with damaged, unreadable and missing files, added November 4, all pass in that CI run. A damaged file gets left alone and the failed save gets reported.
- The phone link is experimental and off by default. It's encrypted with Noise and stays on your local network. It has only been tested with a simulated phone.

Of everything I've put out here, Hot Mic is the most in development, and it needs a lot more testing on real songwriting sessions. See [EVOLUTION.md](EVOLUTION.md) for how it got here.
