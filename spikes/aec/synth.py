"""Synthetic Spike 0 fixture — no speakers, no mic needed.

mic = music through a fake room (delay + decaying reverb + tilt EQ + mild speaker distortion)
      + a hummed melody starting at 8 s + room noise.
Validates bench.py end to end and gives an optimistic upper bound, NOT a real result.

usage: uv run synth.py <music_file> <out_dir> [--seconds 20]
"""

import argparse
import json
import pathlib

import numpy as np
import soundfile as sf
from scipy import signal

SR = 48000


def fake_room(x, rng):
    delay = int(0.012 * SR)  # ~4 m speaker→mic path
    t = np.arange(int(0.35 * SR)) / SR
    ir = rng.standard_normal(len(t)) * np.exp(-t / 0.08) * 0.25
    ir[0] = 1.0
    wet = signal.fftconvolve(x, ir)[: len(x)]
    b, a = signal.butter(2, [120, 9000], btype="band", fs=SR)  # laptop speaker band
    wet = signal.lfilter(b, a, wet)
    wet = np.tanh(2.0 * wet) / 2.0  # speaker nonlinearity
    return np.concatenate([np.zeros(delay), wet])[: len(x)] * 0.5


def hum(n, start_s):
    notes = [57, 60, 64, 62, 60, 57, 55, 57]  # A minor-ish phrase
    out = np.zeros(n)
    seg = int(0.5 * SR)
    pos = int(start_s * SR)
    for midi in notes * 4:
        if pos + seg > n:
            break
        f = 440 * 2 ** ((midi - 69) / 12)
        tt = np.arange(seg) / SR
        vib = 1 + 0.004 * np.sin(2 * np.pi * 5.5 * tt)
        phase = 2 * np.pi * np.cumsum(f * vib) / SR
        tone = np.sin(phase) + 0.4 * np.sin(2 * phase) + 0.2 * np.sin(3 * phase)
        env = np.minimum(1, np.minimum(tt / 0.04, (tt[-1] - tt) / 0.06))
        out[pos:pos + seg] += 0.12 * tone * env
        pos += seg
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("music", type=pathlib.Path)
    ap.add_argument("out", type=pathlib.Path)
    ap.add_argument("--seconds", type=float, default=20)
    args = ap.parse_args()

    music, sr = sf.read(args.music, dtype="float64", always_2d=True)
    if sr != SR:
        music = signal.resample_poly(music, SR, sr, axis=0)
    music = music[int(30 * SR): int((30 + args.seconds) * SR)]  # skip intros
    music = 0.5 * music / (np.max(np.abs(music)) + 1e-9)
    rng = np.random.default_rng(7)
    mono = music.mean(axis=1)
    mic = fake_room(mono, rng) + hum(len(mono), 8.0) + rng.standard_normal(len(mono)) * 0.001

    args.out.mkdir(parents=True, exist_ok=True)
    sf.write(args.out / "session0.wav", music.astype(np.float32), SR)
    sf.write(args.out / "mic0.wav", mic.astype(np.float32), SR)
    sf.write(args.out / "truth_voice.wav", hum(len(mono), 8.0).astype(np.float32), SR)
    (args.out / "meta.json").write_text(json.dumps({"synthetic": True, "sample_rate": SR}))
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
