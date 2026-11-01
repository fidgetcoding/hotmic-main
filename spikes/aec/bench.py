"""Spike 0 (T0.2) — how much of the playing music can we remove from the mic?

usage: uv run bench.py <capture_dir> [--music-only SECONDS] [--neural]

Fixture protocol: the first --music-only seconds (default 8) are music with NO singing.
Suppression is measured there (after a 2 s convergence window); the rest is for listening.

Writes into <capture_dir>/bench/: one WAV per stage + report.md.
"""

import argparse
import pathlib

import numpy as np
import soundfile as sf
from scipy import signal
from livekit import rtc

from pbfdaf import pbfdaf

FRAME_MS = 10
CONVERGE_S = 2.0


def load(capture: pathlib.Path):
    mic, sr = sf.read(capture / "mic0.wav", dtype="float32")
    ref, sr2 = sf.read(capture / "session0.wav", dtype="float32")
    assert sr == sr2, "mic and session sample rates differ"
    mic = mic if mic.ndim == 1 else mic.mean(axis=1)
    ref = ref if ref.ndim == 1 else ref.mean(axis=1)
    n = min(len(mic), len(ref))
    return mic[:n], ref[:n], sr


def estimate_delay_ms(mic, ref, sr, window_s):
    """Speaker→mic acoustic delay from cross-correlation over the music-only window."""
    n = int(window_s * sr)
    corr = signal.correlate(mic[:n], ref[:n], mode="full", method="fft")
    lag = int(np.argmax(np.abs(corr))) - (n - 1)
    return max(lag, 0) * 1000.0 / sr, float(np.max(np.abs(corr)))


def to_i16(x):
    return (np.clip(x, -1, 1) * 32767).astype(np.int16)


def run_apm(mic, ref, sr, delay_ms, noise_suppression):
    apm = rtc.AudioProcessingModule(echo_cancellation=True, noise_suppression=noise_suppression,
                                    high_pass_filter=True)
    apm.set_stream_delay_ms(int(round(delay_ms)))
    hop = sr * FRAME_MS // 1000
    out = np.zeros(len(mic) // hop * hop, dtype=np.int16)
    mic16, ref16 = to_i16(mic), to_i16(ref)
    for i in range(0, len(out), hop):
        far = rtc.AudioFrame(ref16[i:i + hop].tobytes(), sr, 1, hop)
        apm.process_reverse_stream(far)
        near = rtc.AudioFrame(bytearray(mic16[i:i + hop].tobytes()), sr, 1, hop)
        apm.process_stream(near)
        out[i:i + hop] = np.frombuffer(near.data, dtype=np.int16)
    return out.astype(np.float32) / 32767


def run_neural(x, sr, workdir: pathlib.Path):
    """Stage 4: vocal separation on the whole clip (per-take in the product)."""
    from audio_separator.separator import Separator  # optional dependency
    src = workdir / "_neural_in.wav"
    sf.write(src, x, sr)
    sep = Separator(output_dir=str(workdir), output_single_stem="Vocals")
    sep.load_model("model_bs_roformer_ep_317_sdr_12.9755.ckpt")
    produced = sep.separate(str(src))
    voc, _ = sf.read(workdir / produced[0], dtype="float32")
    return voc if voc.ndim == 1 else voc.mean(axis=1)


def rms_db(x):
    return 20 * np.log10(np.sqrt(np.mean(np.square(x))) + 1e-12)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture", type=pathlib.Path)
    ap.add_argument("--music-only", type=float, default=8.0)
    ap.add_argument("--neural", action="store_true")
    args = ap.parse_args()

    mic, ref, sr = load(args.capture)
    out_dir = args.capture / "bench"
    out_dir.mkdir(exist_ok=True)
    delay_ms, peak = estimate_delay_ms(mic, ref, sr, args.music_only)

    stages = {"0_raw_mic": mic}
    stages["1_aec3"] = run_apm(mic, ref, sr, delay_ms, noise_suppression=False)
    stages["2_aec3_ns"] = run_apm(mic, ref, sr, delay_ms, noise_suppression=True)
    stages["4_linear_pbfdaf"] = pbfdaf(mic, ref)
    if args.neural:
        stages["3_aec3_ns_neural"] = run_neural(stages["2_aec3_ns"], sr, out_dir)

    a, b = int(CONVERGE_S * sr), int(args.music_only * sr)
    base = rms_db(mic[a:b])
    rows = []
    for name, x in stages.items():
        sf.write(out_dir / f"{name}.wav", x, sr)
        music_db = rms_db(x[a:b])
        rows.append(f"| {name} | {music_db:6.1f} | {base - music_db:5.1f} | {rms_db(x[b:]):6.1f} |")

    truth_path = args.capture / "truth_voice.wav"  # synthetic fixtures only
    if truth_path.exists():
        truth, _ = sf.read(truth_path, dtype="float32")
        rows.append("")
        rows.append("| stage | voice SDR dB (synthetic truth, sung region) |")
        rows.append("|---|---|")
        for name, x in stages.items():
            t, y = truth[b:len(x)], x[b:len(truth)]
            n = min(len(t), len(y)); t, y = t[:n], y[:n]
            c = signal.correlate(y, t, mode="full", method="fft")
            y = np.roll(y, -(int(np.argmax(np.abs(c))) - (n - 1)))  # undo processing latency
            gain = np.dot(y, t) / (np.dot(t, t) + 1e-12)  # scale-invariant
            sdr = 10 * np.log10(np.sum((gain * t) ** 2) / (np.sum((y - gain * t) ** 2) + 1e-12))
            rows.append(f"| {name} | {sdr:5.1f} |")

    report = "\n".join([
        f"# AEC bench — {args.capture.name}",
        "",
        f"- sample rate {sr} Hz, {len(mic) / sr:.1f} s, music-only window {CONVERGE_S}–{args.music_only} s",
        f"- mic level {rms_db(mic):.1f} dBFS, session level {rms_db(ref):.1f} dBFS",
        f"- estimated speaker→mic delay {delay_ms:.1f} ms (xcorr peak {peak:.3f})",
        "",
        "| stage | music-only dBFS | suppression dB | rest dBFS |",
        "|---|---|---|---|",
        *rows,
        "",
        "Target: suppression ≥ 25 dB on laptop speakers, voice still clean (listen to the files).",
    ])
    (out_dir / "report.md").write_text(report + "\n")
    print(report)


if __name__ == "__main__":
    main()
