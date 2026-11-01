#!/usr/bin/env python3
"""Drafts a stream timeline for the bench: talk / writing / playback / beat, from the vocal stem.

  label.py --vocals <vocals 16 kHz mono wav> --transcript <whisper-cli -oj json> --ref <release lyrics.txt>
           --out <labels.draft.json> [--tsv <review.tsv>]

Draft rules (a human reviews every draft before it scores anything):
- voiced stretches come from the vocal stem's energy; whisper segments give their words
- a segment whose words match a released line is singing toward the song (writing)
- a later segment whose AUDIO is a near-copy of an earlier one is the DAW playing a take back (playback)
- other voiced segments are talk; unvoiced stretches are beat
"""
import argparse, json, sys, wave
import numpy as np
sys.path.insert(0, __import__("os").path.dirname(__file__))
from score import norm, local_wer

RATE, HOP, WIN = 16000, 512, 1024

def load(path):
    with wave.open(path) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1, "need 16 kHz mono"
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768

def bands(x):
    """Log energy in 32 bands per 32 ms frame: enough to tell an exact replay from a new take."""
    n = 1 + (len(x) - WIN) // HOP
    frames = np.lib.stride_tricks.sliding_window_view(x, WIN)[::HOP][:n] * np.hanning(WIN)
    spec = np.abs(np.fft.rfft(frames, axis=1)) ** 2
    edges = np.unique(np.geomspace(4, spec.shape[1] - 1, 33).astype(int))
    out = np.stack([spec[:, a:b].sum(axis=1) for a, b in zip(edges[:-1], edges[1:])], axis=1)
    return np.log(out + 1e-9)

def replay_score(F, a, b, dur):
    """Best correlation of the band sequence at a vs b (±1 s lag): ~1 for the same audio played again."""
    fa = F[int(a * RATE / HOP): int((a + dur) * RATE / HOP)]
    best = 0.0
    for lag in range(-int(RATE / HOP), int(RATE / HOP) + 1, 2):
        s = int(b * RATE / HOP) + lag
        fb = F[max(0, s): max(0, s) + len(fa)]
        if len(fb) != len(fa) or len(fa) < 10:
            continue
        x, y = fa - fa.mean(axis=0), fb - fb.mean(axis=0)
        c = (x * y).sum() / (np.sqrt((x * x).sum() * (y * y).sum()) + 1e-9)
        best = max(best, float(c))
    return best

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vocals", required=True); ap.add_argument("--transcript", required=True)
    ap.add_argument("--ref", required=True); ap.add_argument("--out", required=True); ap.add_argument("--tsv")
    a = ap.parse_args()
    x = load(a.vocals)
    F = bands(x)
    energy = np.array([np.sqrt(np.mean(x[i:i + RATE] ** 2)) for i in range(0, len(x), RATE)])
    voiced = energy > max(0.01, np.percentile(energy, 30) * 2)
    ref = [norm(l) for l in open(a.ref) if l.strip()]
    segs = []
    for s in json.load(open(a.transcript))["transcription"]:
        t0, t1 = s["offsets"]["from"] / 1000, s["offsets"]["to"] / 1000
        words = norm(s["text"])
        if not words:
            continue
        song = min((local_wer(r, words) for r in ref if r), default=1) <= 0.5 or \
               any(local_wer(words, r) <= 0.4 for r in ref if len(words) >= 3)
        segs.append({"start": round(t0, 2), "end": round(t1, 2), "text": s["text"].strip(), "song": song})
    # Replays: a song segment whose audio repeats an earlier song segment with similar words.
    for j, b in enumerate(segs):
        b["label"] = "writing" if b["song"] else "talk"
        if not b["song"]:
            continue
        for i in range(j):
            p = segs[i]
            if not p["song"] or p["end"] > b["start"]:
                continue
            if local_wer(norm(p["text"]), norm(b["text"])) > 0.4:
                continue
            c = replay_score(F, p["start"], b["start"], min(p["end"] - p["start"], b["end"] - b["start"], 8))
            if c >= 0.85:
                b["label"], b["replay_of"], b["replay_corr"] = "playback", p["start"], round(c, 3)
                break
    # Beat = unvoiced seconds not covered by any segment.
    labels, covered = [], np.zeros(len(voiced), bool)
    for s in segs:
        labels.append({k: s[k] for k in ("start", "end", "label", "text") } | ({"replay_of": s["replay_of"]} if "replay_of" in s else {}))
        covered[int(s["start"]):int(np.ceil(s["end"]))] = True
    run = None
    for i, v in enumerate(covered):
        if not v and run is None:
            run = i
        if (v or i == len(covered) - 1) and run is not None:
            if i - run >= 3:
                labels.append({"start": run, "end": i, "label": "beat", "text": ""})
            run = None
    labels.sort(key=lambda l: l["start"])
    json.dump(labels, open(a.out, "w"), indent=1)
    if a.tsv:
        with open(a.tsv, "w") as f:
            for l in labels:
                f.write(f"{l['start']:7.1f}\t{l['end']:7.1f}\t{l['label']}\t{l.get('replay_of', '')}\t{l['text']}\n")
    counts = {}
    for l in labels:
        counts[l["label"]] = counts.get(l["label"], 0) + l["end"] - l["start"]
    print({k: round(v) for k, v in counts.items()})

if __name__ == "__main__":
    main()
