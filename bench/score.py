#!/usr/bin/env python3
"""Scores one Hot Mic bench run against the released song and the labeled stream timeline.

  score.py --session <session.json> --folder <session folder> --ref <release lyrics.txt>
           [--labels <labels.json>] [--whole <whole-song transcript.txt>] [--plan <plan.json>]
           [--verdicts <verdicts.json> --truth <lines.jsonl>] [--out <score.json>]

session.json = `hotmic-bench export`. Take kinds come from the take sidecars in the session folder.
labels.json = [{"start": s, "end": s, "label": "talk|writing|playback|beat|other"}] in stream seconds.
verdicts.json = `hotmic-bench verdicts`, truth = bench/lines.py: scores the line judge (talk precision and recall,
writing kept) over lines not marked unsure. With --plan and --labels: how much of the stitched song is talk.
Prints a markdown scorecard; --out writes the numbers as JSON.
"""
import argparse, json, os, re, sys

# Spelled-out words in a reference, as [["regex", "word"], …], kept beside the rest of the local corpus.
_spelled = os.path.join(os.path.dirname(os.path.abspath(__file__)), "local", "spelled.json")
SPELLED = json.load(open(_spelled)) if os.path.exists(_spelled) else []
NUMBERS = {"0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six",
           "7": "seven", "8": "eight", "9": "nine", "10": "ten"}

def norm(text):
    t = text.lower().replace("’", "'")
    for pat, rep in SPELLED:
        t = re.sub(pat, rep, t)
    t = re.sub(r"\s*×\d+$", "", t)
    t = re.sub(r"[^a-z0-9' ]+", " ", t)
    words = [NUMBERS.get(w, w) for w in t.split()]
    return [w.strip("'") for w in words if w.strip("'")]

def lcs(a, b):
    prev = [0] * (len(b) + 1)
    for x in a:
        cur = [0]
        for j, y in enumerate(b):
            cur.append(prev[j] + 1 if x == y else max(prev[j + 1], cur[j]))
        prev = cur
    return prev[-1]

def local_wer(ref, hyp):
    """Edit distance of ref against the best-matching stretch of hyp (free start/end in hyp), / len(ref)."""
    if not ref:
        return 0.0
    prev = [0] * (len(hyp) + 1)
    for i, r in enumerate(ref, 1):
        cur = [i]
        for j, h in enumerate(hyp, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h)))
        prev = cur
    return min(prev) / len(ref)

def wer(ref, hyp):
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i]
        for j, h in enumerate(hyp, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h)))
        prev = cur
    return prev[-1] / max(1, len(ref))

def kendall(order):
    """Kendall tau of a sequence of ranks against sorted order (1 = same order)."""
    n, s = len(order), 0
    for i in range(n):
        for j in range(i + 1, n):
            s += 1 if order[i] < order[j] else -1 if order[i] > order[j] else 0
    return s / (n * (n - 1) / 2) if n > 1 else 1.0

SKIP = ("hum-", "beat-", "chords-")

def sung(v):
    return v["text"].strip() and v.get("takeID") != "typed" and not v["id"].startswith(SKIP)

def shown(slot):
    keepers = [v for v in slot if v.get("keeper")]
    return keepers[-1] if keepers else slot[-1]

def seconds(ranges, length):
    on = bytearray(int(length) + 2)
    for a, b in ranges:
        for s in range(max(0, int(a)), min(len(on), int(b + 0.999))):
            on[s] = 1
    return on

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True); ap.add_argument("--folder", required=True)
    ap.add_argument("--ref", required=True); ap.add_argument("--labels"); ap.add_argument("--whole")
    ap.add_argument("--plan"); ap.add_argument("--out"); ap.add_argument("--name", default="run")
    ap.add_argument("--verdicts"); ap.add_argument("--truth")
    ap.add_argument("--ceiling", help="whisper transcript of the release's own vocals: the best any whisper-based run can do")
    a = ap.parse_args()

    session = json.load(open(a.session))
    ref_lines = [l.strip() for l in open(a.ref) if l.strip()]
    ref_unique, seen = [], set()
    for l in ref_lines:
        k = " ".join(norm(l))
        if k and k not in seen:
            seen.add(k); ref_unique.append(l)
    slots = [[v for v in s if sung(v)] for s in session["slots"]]
    slots = [s for s in slots if s]
    shown_lines = [shown(s) for s in slots]
    every = [v for s in slots for v in s]

    # 1-2. Coverage (any version) and the shown version, per released line.
    per_line = []
    for i, line in enumerate(ref_unique):
        r = norm(line)
        best_any = min((local_wer(r, norm(v["text"])) for v in every), default=1.0)
        best_shown, at = 1.0, None
        for k, v in enumerate(shown_lines):
            w = local_wer(r, norm(v["text"]))
            if w < best_shown:
                best_shown, at = w, k
        per_line.append({"ref": i, "any_wer": round(best_any, 3), "shown_wer": round(best_shown, 3), "slot": at})
    covered = [p for p in per_line if p["any_wer"] <= 0.4]
    shown_ok = [p for p in per_line if p["shown_wer"] <= 0.4]

    # 3. Which notebook lines belong to the song at all.
    in_song = 0
    for v in shown_lines:
        h = norm(v["text"])
        if h and any(local_wer(norm(l), h) <= 0.5 or lcs(norm(l), h) / max(1, len(norm(l))) >= 0.6 for l in ref_unique):
            in_song += 1

    # 4. Order of the released lines through the notebook.
    order = [p["slot"] for p in sorted(shown_ok, key=lambda p: p["ref"])]
    tau = kendall(order)

    # Take kinds from the sidecars.
    kinds = {}
    for name in os.listdir(a.folder):
        if name.endswith(".json") and not name.startswith("notebook"):
            try:
                d = json.load(open(os.path.join(a.folder, name)))
            except Exception:
                continue
            if isinstance(d, dict) and "kind" in d and "id" in d:
                kinds[d["id"]] = (d["kind"], d.get("sessionStartSeconds", 0), d.get("durationSeconds", 0))
    kind_seconds = {}
    for k, s, d in kinds.values():
        kind_seconds[k] = kind_seconds.get(k, 0) + d

    score = {"name": a.name, "ref_lines": len(ref_unique), "notebook_lines": len(slots),
             "versions": len(every), "takes": len(kinds), "take_seconds_by_kind": {k: round(v, 1) for k, v in kind_seconds.items()},
             "coverage": round(len(covered) / max(1, len(ref_unique)), 3),
             "shown_correct": round(len(shown_ok) / max(1, len(ref_unique)), 3),
             "shown_mean_wer": round(sum(p["shown_wer"] for p in per_line) / max(1, len(per_line)), 3),
             "notebook_in_song": round(in_song / max(1, len(shown_lines)), 3),
             "order_tau": round(tau, 3), "per_line": per_line}

    # 5. Timeline against the labels: what got kept as takes, by kind.
    if a.labels:
        labels = json.load(open(a.labels))
        length = max([l["end"] for l in labels] + [session.get("length", 0)])
        truth = {lab: seconds([(l["start"], l["end"]) for l in labels if l["label"] == lab], length)
                 for lab in ("talk", "writing", "playback", "beat", "other")}
        kept = seconds([(s, s + d) for k, s, d in kinds.values()], length)
        lyric = seconds([(s, s + d) for k, s, d in kinds.values() if k in ("singing", "rap", "whisper")], length)
        talky = seconds([(s, s + d) for k, s, d in kinds.values() if k == "talk"], length)
        n = len(kept)
        def both(x, y): return sum(1 for i in range(n) if x[i] and y[i])
        w = sum(truth["writing"])
        score["timeline"] = {
            "writing_s": w, "talk_s": sum(truth["talk"]), "playback_s": sum(truth["playback"]),
            "writing_kept": round(both(truth["writing"], kept) / max(1, w), 3),
            "writing_as_lyric_kind": round(both(truth["writing"], lyric) / max(1, w), 3),
            "talk_kept_s": both(truth["talk"], kept),
            "talk_as_lyric_kind_s": both(truth["talk"], lyric),
            "talk_judged_talk": round(both(truth["talk"], talky) / max(1, sum(truth["talk"])), 3),
            "playback_kept_s": both(truth["playback"], kept),
        }

    # 6. The stitched song.
    if a.whole:
        hyp = norm(open(a.whole).read())
        ref_all = norm(" ".join(ref_lines))
        found = sum(1 for l in ref_unique if local_wer(norm(l), hyp) <= 0.4)
        score["whole_song"] = {"wer_vs_release": round(wer(ref_all, hyp), 3),
                               "release_lines_heard": round(found / max(1, len(ref_unique)), 3),
                               "words": len(hyp)}
        if a.plan:
            clips = json.load(open(a.plan))
            score["whole_song"].update({"clips": len(clips), "seconds": round(sum(c["end"] - c["start"] for c in clips), 1)})

    if a.plan and a.labels:
        labels = json.load(open(a.labels))
        clips = json.load(open(a.plan))
        total = sum(max(0, c["end"] - c["start"]) for c in clips)
        def part(label):
            return sum(max(0, min(c["end"], l["end"]) - max(c["start"], l["start"])) for c in clips for l in labels if l["label"] == label)
        score.setdefault("whole_song", {}).update({"clips": len(clips), "seconds": round(total, 1),
            "talk_pct": round(100 * part("talk") / max(1e-6, total), 1), "writing_pct": round(100 * part("writing") / max(1e-6, total), 1),
            "playback_pct": round(100 * part("playback") / max(1e-6, total), 1)})

    if a.verdicts and a.truth:
        truth = [json.loads(l) for l in open(a.truth)]
        said = {v["id"]: v for v in json.load(open(a.verdicts))}
        lines = [t for t in truth if not t["unsure"] and t["id"] in said]
        def judged(t, verdict): return said[t["id"]]["verdict"] == verdict
        talk = [t for t in lines if t["truth"] == "talk"]
        writing = [t for t in lines if t["truth"] == "writing"]
        playback = [t for t in lines if t["truth"] == "playback"]
        called_talk = [t for t in lines if judged(t, "talk")]
        score["judge"] = {"lines": len(lines), "talk_lines": len(talk), "writing_lines": len(writing), "playback_lines": len(playback),
            "talk_called": len(called_talk), "talk_true": sum(t["truth"] == "talk" for t in called_talk),
            "writing_called_talk": sum(t["truth"] == "writing" for t in called_talk),
            "talk_precision": round(sum(t["truth"] == "talk" for t in called_talk) / max(1, len(called_talk)), 3),
            "talk_recall": round(sum(judged(t, "talk") for t in talk) / max(1, len(talk)), 3),
            "writing_kept": round(sum(judged(t, "writing") for t in writing) / max(1, len(writing)), 3),
            "playback_called": sum(judged(t, "playback") for t in playback),
            "by_source": {s: sum(1 for t in lines if said[t["id"]]["source"] == s) for s in ("rules", "model", "learner", "you")}}

    if a.ceiling:
        hyp = norm(open(a.ceiling).read())
        score["ceiling"] = {"wer_vs_release": round(wer(norm(" ".join(ref_lines)), hyp), 3),
                            "release_lines_heard": round(sum(local_wer(norm(l), hyp) <= 0.4 for l in ref_unique) / max(1, len(ref_unique)), 3)}

    if a.out:
        json.dump(score, open(a.out, "w"), indent=2)
    s = score
    print(f"## {s['name']}")
    print(f"| metric | value |\n|---|---|")
    for k in ("ref_lines", "notebook_lines", "versions", "takes", "coverage", "shown_correct", "shown_mean_wer", "notebook_in_song", "order_tau"):
        print(f"| {k} | {s[k]} |")
    print(f"| take s by kind | {s['take_seconds_by_kind']} |")
    for k, v in s.get("timeline", {}).items():
        print(f"| {k} | {v} |")
    for k, v in s.get("whole_song", {}).items():
        print(f"| song {k} | {v} |")
    for k, v in s.get("ceiling", {}).items():
        print(f"| ceiling {k} | {v} |")
    for k, v in s.get("judge", {}).items():
        print(f"| judge {k} | {v} |")

if __name__ == "__main__":
    main()
