# Security

## Reporting a vulnerability

Please report privately through this repository's Security tab ("Report a vulnerability"). Do not open a public issue. Include what you found, how to reproduce it, and the version or commit.

## Known limitations

**Phone link (off by default).** The link between the iPhone app and the Mac is encrypted with the Noise protocol (see docs/SPEC.md). It has only been tested with a simulated phone, never a real one. Joining from the Nearby list relies on you comparing the six digits on both screens. The QR code holds the session's secret, so don't share a photo of it. Invites carry private-range addresses only, and the iPhone asks before any link or scanned code joins.

**What leaves your Mac.** Audio and lyrics stay on the Mac unless you put your library in a synced folder. The first run downloads the Whisper model from Hugging Face. Release builds configured with an update feed check it through Sparkle.
