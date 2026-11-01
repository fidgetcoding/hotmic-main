#!/usr/bin/env python3
"""Gives every line of a bench run a true label, so judges can be scored line by line.

  lines.py --session <session.json> --folder <session folder> --windows <windows.tsv> --labels <labels.json> --out <lines.jsonl>

Whisper's line times collapse (many lines stamped at one second, off by up to a decode window), so a line's
own time can't be looked up in the labels. Each take's words are aligned in order to the 10 s window
transcript of the same vocal stem (bench/run.sh writes it), whose times are reliable; the line's time is where its
words landed. session.json must be an export with no judge applied (it has to hold every line).
Output, one JSON object per line: id, take, text, at, dur, kind, truth_at, truth, unsure, matched.
"""
import argparse, difflib, glob, json, os, re


def toks(s):
    return [w.strip("'") for w in re.sub(r"[^a-z0-9' ]+", " ", s.lower().replace("’", "'")).split() if w.strip("'")]


def place(id):
    m = re.search(r"#(\d+)", id)
    return int(m.group(1)) if m else 0


def label_at(labels, t):
    for l in labels:
        if l["start"] <= t < l["end"]:
            return l["label"], bool(l.get("unsure"))
    return "none", False


def main():
    ap = argparse.ArgumentParser()
    for name in ("session", "folder", "windows", "labels", "out"):
        ap.add_argument("--" + name, required=True)
    a = ap.parse_args()
    session = json.load(open(a.session))
    labels = sorted(json.load(open(a.labels)), key=lambda l: l["start"])
    win = []
    for row in open(a.windows):
        if "\t" in row:
            start, text = row.split("\t", 1)
            ws = toks(text)
            win += [(w, int(start) + 10.0 * j / max(1, len(ws))) for j, w in enumerate(ws)]
    kinds = {}
    for f in glob.glob(os.path.join(a.folder, "*.json")):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        if isinstance(d, dict) and "kind" in d and "id" in d:
            kinds[d["id"]] = d["kind"]
    takes = {t["id"]: t for t in session["takes"]}
    by_take = {}
    for slot in session["slots"]:
        for v in slot:
            if v.get("takeID") in takes and v["text"].strip() and not v["id"].startswith(("hum-", "beat-", "chords-")):
                by_take.setdefault(v["takeID"], []).append(v)
    out = []
    for tid, vs in by_take.items():
        vs.sort(key=lambda v: place(v["id"]))
        t = takes[tid]
        ref = [(w, x) for w, x in win if t["at"] - 15 <= x <= t["at"] + t["dur"] + 15]
        hyp, owner = [], []
        for i, v in enumerate(vs):
            for w in toks(v["text"]):
                hyp.append(w); owner.append(i)
        hits = {}
        for blk in difflib.SequenceMatcher(None, hyp, [w for w, _ in ref], autojunk=False).get_matching_blocks():
            for k in range(blk.size):
                hits.setdefault(owner[blk.a + k], []).append(ref[blk.b + k][1])
        spot = []
        for i, v in enumerate(vs):
            h = sorted(hits.get(i, []))
            spot.append(h[len(h) // 2] if len(h) / max(1, len(toks(v["text"]))) >= 0.5 else None)
        for i, v in enumerate(vs):
            at, matched = spot[i], spot[i] is not None
            if at is None:   # between its neighbours
                before = next((spot[j] for j in range(i - 1, -1, -1) if spot[j] is not None), None)
                after = next((spot[j] for j in range(i + 1, len(vs)) if spot[j] is not None), None)
                at = before if after is None else after if before is None else (before + after) / 2
                at = v["at"] if at is None else at
            truth, unsure = label_at(labels, at)
            out.append({"id": v["id"], "take": tid, "text": v["text"], "at": round(v["at"], 2), "dur": round(v["end"] - v["start"], 2),
                        "kind": kinds.get(tid), "truth_at": round(at, 1), "truth": truth, "unsure": unsure, "matched": matched})
    with open(a.out, "w") as f:
        for r in out:
            f.write(json.dumps(r) + "\n")


if __name__ == "__main__":
    main()
