# Security

## Reporting a vulnerability

Please report privately through this repository's Security tab ("Report a vulnerability"). Do not open a public issue. Include what you found, how to reproduce it, and the version or commit.

## Known limitations

**Phone link (experimental, off by default).** The link between the iPhone app and the Mac is plain TCP on the local network. Audio, the join token and the device ID are not encrypted, so anyone on the same network can read them, and a sniffed device ID can impersonate a phone marked "Always let in". Only turn on "Let phones join" on a network you trust. Invites carry private-range addresses only, and the iPhone asks before any link or scanned code joins.

**What leaves your Mac.** Audio and lyrics stay on the Mac unless you put your library in a synced folder. The first run downloads the Whisper model from Hugging Face. Release builds configured with an update feed check it through Sparkle.
