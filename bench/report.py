#!/usr/bin/env python3
"""One local page per video: every condition's scorecard side by side, the released lines next to what
Hot Mic shows for them, and the stitched whole song to play. Lyrics stay local (bench/local is never committed).

  report.py --id <video id> [--title "Song name"]   → bench/local/report/<id>/index.html
Open: bench/local/report/<id>/index.html in a browser
"""
import argparse, html, json, os, shutil, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score import norm, local_wer, shown, sung

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "local")
ORDER = ["raw", "split", "clean", "live-raw", "live-split", "live-clean"]
ROWS = [("coverage", "Released lines caught anywhere", "%"), ("shown_correct", "Released lines right in the shown version", "%"),
        ("shown_mean_wer", "Word error of shown lines (lower is better)", "%"), ("notebook_in_song", "Notebook lines that belong to the song", "%"),
        ("order_tau", "Line order vs release (1 = same)", "n"), ("notebook_lines", "Notebook lines", "n"), ("takes", "Takes", "n")]

def fmt(v, kind):
    return "–" if v is None else f"{v * 100:.0f}%" if kind == "%" else f"{v}"

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--id", required=True); ap.add_argument("--title", default="")
    a = ap.parse_args()
    runs = os.path.join(ROOT, "runs", a.id)
    out = os.path.join(ROOT, "report", a.id); os.makedirs(out, exist_ok=True)
    # Current runs plus earlier ones kept as <cond>.<timestamp> (shown as "<cond> · before"), raw → live.
    found = [d for d in os.listdir(runs) if os.path.exists(os.path.join(runs, d, "score.json"))]
    conds = sorted(found, key=lambda d: (ORDER.index(d.split(".")[0]) if d.split(".")[0] in ORDER else 9, "." not in d, d))
    scores = {c: json.load(open(os.path.join(runs, c, "score.json"))) for c in conds}
    ref = [l.strip() for l in open(os.path.join(ROOT, "ref", f"{a.id}.txt")) if l.strip()]
    uniq = list(dict.fromkeys(ref))
    name = lambda c: c if "." not in c else c.split(".")[0] + " · before"
    head = "".join(f"<th>{name(c)}</th>" for c in conds)
    body = ""
    for key, label, kind in ROWS:
        body += f"<tr><td>{label}</td>" + "".join(f"<td>{fmt(scores[c].get(key), kind)}</td>" for c in conds) + "</tr>"
    for key, label, kind in [("wer_vs_release", "Whole song: word error vs release", "%"), ("release_lines_heard", "Whole song: released lines you can hear", "%"),
                             ("seconds", "Whole song: length (s)", "n"), ("clips", "Whole song: clips", "n")]:
        body += f"<tr><td>{label}</td>" + "".join(f"<td>{fmt(scores[c].get('whole_song', {}).get(key), kind)}</td>" for c in conds) + "</tr>"
    for key, label, kind in [("writing_kept", "Writing kept as takes", "%"), ("talk_kept_s", "Talk kept as takes (s)", "n"),
                             ("talk_judged_talk", "Talk judged as talk", "%"), ("playback_kept_s", "Playback kept as takes (s)", "n")]:
        body += f"<tr><td>{label}</td>" + "".join(f"<td>{fmt(scores[c].get('timeline', {}).get(key), kind)}</td>" for c in conds) + "</tr>"
    ceil = next((s["ceiling"] for s in scores.values() if "ceiling" in s), None)
    if ceil:
        body += f"<tr class='ceil'><td>Ceiling: Whisper on the release's own vocals</td><td colspan='{len(conds)}'>{fmt(ceil['release_lines_heard'], '%')} of lines heard · word error {fmt(ceil['wer_vs_release'], '%')}</td></tr>"
    # Released lines vs what each condition shows.
    lines_head = "<th>Released line</th>" + "".join(f"<th>{name(c)}</th>" for c in conds)
    shown_by = {}
    for c in conds:
        s = json.load(open(os.path.join(runs, c, "session.json")))
        shown_by[c] = [shown([v for v in slot if sung(v)]) for slot in s["slots"] if [v for v in slot if sung(v)]]
    lines = ""
    for l in uniq:
        r = norm(l); cells = ""
        for c in conds:
            best = min(shown_by[c], key=lambda v: local_wer(r, norm(v["text"])), default=None)
            w = local_wer(r, norm(best["text"])) if best else 1
            ok = "ok" if w <= 0.4 else "near" if w <= 0.7 else "miss"
            cells += f"<td class='{ok}'>{html.escape(best['text']) if best and w <= 0.7 else '—'}</td>"
        lines += f"<tr><td>{html.escape(l)}</td>{cells}</tr>"
    players = ""
    for c in conds:
        src = os.path.join(runs, c, "whole-song.m4a")
        if os.path.exists(src):
            shutil.copyfile(src, os.path.join(out, f"{c}.m4a"))
            players += f"<div class='p'><b>{name(c)}</b><audio controls preload='none' src='{c}.m4a'></audio></div>"
    title = html.escape(a.title or a.id)
    page = f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Bench · {title}</title><style>
:root{{--bg:#f6f5f2;--ink:#1d1d1f;--muted:#6e6e73;--line:#e3e1dc;--ok:#1f8a4c;--near:#b7791f;--miss:#b42318;--card:#fff}}
@media (prefers-color-scheme: dark){{:root:not([data-theme="light"]){{--bg:#151517;--ink:#f2f2f2;--muted:#9a9aa0;--line:#2c2c30;--ok:#4cc38a;--near:#e3a94b;--miss:#ff6b5e;--card:#1e1e21}}}}
:root[data-theme="dark"]{{--bg:#151517;--ink:#f2f2f2;--muted:#9a9aa0;--line:#2c2c30;--ok:#4cc38a;--near:#e3a94b;--miss:#ff6b5e;--card:#1e1e21}}
body{{background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,system-ui,sans-serif;margin:0 auto;padding:24px 16px;max-width:1100px}}
h1{{font-size:22px;margin:0 0 4px}} h2{{font-size:16px;margin:28px 0 8px}} p{{color:var(--muted);margin:0 0 12px}}
.wrap{{overflow-x:auto}} table{{border-collapse:collapse;width:100%;background:var(--card)}}
th,td{{border-bottom:1px solid var(--line);padding:7px 9px;text-align:left;vertical-align:top}} th{{font-weight:600}}
td.ok{{color:var(--ok)}} td.near{{color:var(--near)}} td.miss{{color:var(--miss)}} tr.ceil td{{color:var(--muted)}}
.p{{display:flex;align-items:center;gap:12px;margin:6px 0}} .p b{{width:90px}} audio{{flex:1;min-width:0}}
</style></head><body>
<h1>Hot Mic bench · {title}</h1>
<p>raw = the stream as the mic · split = vocals as the mic, beat as the tap (Beat mode) · clean = split with the DAW playback muted, as a real session cancels it · live-* = the real-time session path.</p>
<h2>Whole song (shown version of every line, in notebook order)</h2>{players}
<h2>Scorecard</h2><div class="wrap"><table><tr><th></th>{head}</tr>{body}</table></div>
<h2>Released lines vs what Hot Mic shows</h2><p>Green = right (≤40% word error) · amber = close · red dash = not shown.</p>
<div class="wrap"><table><tr>{lines_head}</tr>{lines}</table></div>
</body></html>'''
    open(os.path.join(out, "index.html"), "w").write(page)
    print(os.path.join(out, "index.html"))

if __name__ == "__main__":
    main()
