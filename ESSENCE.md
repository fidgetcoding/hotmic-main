# Hot Mic, on one page

**What it is.** A macOS app by blue gum that records a whole songwriting session and turns it into a notepad: every line you sang, every version of it, one click from the moment you sang it. Swift and a web-view window. On-device. MIT.

**Who it's for.** Songwriters, vocalists and rappers writing over a loop or a guitar on a Mac.

**Why it exists.** I'd turn on Voice Memos, go for an hour, and end up with a file I had to scrub to find anything. No transcript, no markers. Stopping to write breaks the flow that made the idea.

**What's different.**
- It records everything and sorts it out after. Ideas can't get lost to a late button press.
- Versions are the point. The same line sung five ways is one line with five versions, not five notes.
- It's made for how rappers actually talk: slang, ad-libs, mumbles, whispers.
- Audio stays on the Mac. There's no account.

**How to try it.** macOS 14.2+, Xcode with Swift 6. `git clone https://github.com/fidgetcoding/hotmic && cd hotmic && ./scripts/install.sh`. That script replaces `/Applications/Hot Mic.app` and pins it to the Dock.

## What works today

- Whole-session recording, takes, live lines, per-line Whisper fixes, versions, stars, Freestyle and Beat, drop import, typing, chords and key from `playing` takes. I've used these on my own Mac in real sessions (October 12 to 14), and I prefer it to Voice Memos for jamming.
- 303 Swift tests run, 7 skipped, 0 failures, plus 41 tests of the real window page (November 2). 78 lyric scenarios hold my answers as test cases.
- The judge after Stop, on six livestreamed writing sessions and 1,704 lines: talk precision 0.91, talk recall 0.91, writing kept 0.91 with the model and learner, against recall of 0.03 for rules alone. Those sessions also tuned it, so real sessions will likely score lower.
- Echo cancellation: 19.6 dB on a real song through a simulated laptop room, about 1% CPU. That's a simulation, not a measured room.

## Where it's at

Of everything I've put out here, Hot Mic is the most in development, and it needs a lot more testing on real songwriting sessions. I started testing it against songs being written live on Twitch, and I've started bringing it into my own rehearsals.

See [EVOLUTION.md](EVOLUTION.md) for how it got here.
