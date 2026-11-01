#!/usr/bin/env python3
"""Builds a local spot-check page for a draft timeline: you listen to sampled stretches and
confirms or fixes each label. Answers stay in the page (localStorage); "Copy answers" puts JSON on the
clipboard to paste back, and `qa.py --apply` folds them into labels.json.

  qa.py --id <video id> [--n 15]          → bench/local/qa/<id>/index.html (+ clips)
  qa.py --id <video id> --apply <answers.json>  → bench/local/labels/<id>.json
Serve: python3 -m http.server 8794 --bind 127.0.0.1 -d bench/local/qa/<id>   then open http://127.0.0.1:8794/
"""
import argparse, html, json, os, random, subprocess

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "local")
LABELS = ["writing", "talk", "playback", "beat", "other"]

def sample(labels, n):
    rng = random.Random(7)
    picks = [l for l in labels if l.get("unsure")]       # every stretch the labeler wasn't sure of
    labels = [l for l in labels if not l.get("unsure")]
    n = max(0, n - len(picks)) + len(picks)
    by = {k: [l for l in labels if l["label"] == k and l["end"] - l["start"] >= 1.5] for k in LABELS}
    share = {"writing": 0.35, "talk": 0.3, "playback": 0.2, "beat": 0.15}
    for k, f in share.items():
        pool = by.get(k, [])
        want = max(1, round((n - len([p for p in picks if p.get("unsure")])) * f))
        picks += rng.sample(pool, min(len(pool), want)) if pool else []
    return sorted(picks, key=lambda l: l["start"])[:n]

def build(vid, n):
    work = os.path.join(ROOT, "work", vid)
    labels = json.load(open(os.path.join(work, "labels.draft.json")))
    out = os.path.join(ROOT, "qa", vid)
    os.makedirs(out, exist_ok=True)
    rows = []
    for i, l in enumerate(sample(labels, n)):
        a, b = max(0, l["start"] - 1), min(l["end"] + 1, l["start"] + 25)
        clip = f"clip-{i:02d}.m4a"
        subprocess.run(["taskpolicy", "-b", "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", f"{a:.2f}", "-to", f"{b:.2f}",
                        "-i", os.path.join(work, "stream.wav"), "-c:a", "aac", "-b:a", "128k", os.path.join(out, clip)], check=True)
        buttons = "".join(f'<button data-v="{k}" class="{"draft" if k == l["label"] else ""}">{k}</button>' for k in LABELS)
        rows.append(f'''<section data-start="{l['start']}" data-end="{l['end']}" data-draft="{l['label']}">
  <div class="meta"><b>{l['start']:.0f}–{l['end']:.0f} s</b> · draft: <i>{l['label']}</i></div>
  <div class="text">{html.escape(l.get('text') or '(no words)')}</div>
  <audio controls preload="none" src="{clip}"></audio>
  <div class="choices">{buttons}</div></section>''')
    page = f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Timeline Check</title><style>
:root{{--bg:#f6f5f2;--ink:#1d1d1f;--muted:#6e6e73;--line:#e3e1dc;--pick:#4b5bd6;--card:#fff}}
@media (prefers-color-scheme: dark){{:root:not([data-theme="light"]){{--bg:#151517;--ink:#f2f2f2;--muted:#9a9aa0;--line:#2c2c30;--pick:#8f9cff;--card:#1e1e21}}}}
:root[data-theme="dark"]{{--bg:#151517;--ink:#f2f2f2;--muted:#9a9aa0;--line:#2c2c30;--pick:#8f9cff;--card:#1e1e21}}
body{{background:var(--bg);color:var(--ink);font:15px/1.45 -apple-system,system-ui,sans-serif;margin:0;padding:24px 16px;max-width:760px;margin:auto}}
h1{{font-size:20px;margin:0 0 4px}} p{{color:var(--muted);margin:0 0 20px}}
section{{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px;margin:0 0 12px}}
.meta{{color:var(--muted);font-size:13px}} .text{{margin:6px 0 10px}} audio{{width:100%}}
.choices{{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}}
button{{border:1px solid var(--line);background:transparent;color:var(--ink);border-radius:999px;padding:5px 12px;font:inherit;cursor:pointer}}
button.draft{{border-style:dashed}} button.on{{background:var(--pick);border-color:var(--pick);color:#fff}}
#copy{{position:sticky;bottom:12px;display:block;margin:20px auto 0;background:var(--pick);color:#fff;border:0;padding:10px 18px}}
</style></head><body>
<h1>Timeline check · {html.escape(vid)}</h1>
<p>Listen to each stretch and tap what it really is. The dashed button is the draft guess. Writing = singing/rapping toward the song; playback = the DAW playing a recorded take back; talk = chatting; beat = no voice.</p>
{"".join(rows)}
<button id="copy">Copy answers</button>
<script>
const KEY="hm-qa-{vid}";let ans={{}};try{{ans=JSON.parse(localStorage.getItem(KEY)||"{{}}")}}catch(e){{}}
document.querySelectorAll("section").forEach(s=>{{const k=s.dataset.start;
  const mark=v=>s.querySelectorAll("button").forEach(b=>b.classList.toggle("on",b.dataset.v===v));
  if(ans[k])mark(ans[k].label);
  s.querySelectorAll("button").forEach(b=>b.onclick=()=>{{ans[k]={{start:+s.dataset.start,end:+s.dataset.end,draft:s.dataset.draft,label:b.dataset.v}};mark(b.dataset.v);try{{localStorage.setItem(KEY,JSON.stringify(ans))}}catch(e){{}}}})}});
document.getElementById("copy").onclick=async()=>{{const t=JSON.stringify(Object.values(ans));try{{await navigator.clipboard.writeText(t);document.getElementById("copy").textContent="Copied "+Object.keys(ans).length+" answers"}}catch(e){{prompt("Copy:",t)}}}};
</script></body></html>'''
    open(os.path.join(out, "index.html"), "w").write(page)
    print(os.path.join(out, "index.html"))

def apply(vid, answers):
    work = os.path.join(ROOT, "work", vid)
    labels = json.load(open(os.path.join(work, "labels.draft.json")))
    fixes = {round(a["start"], 2): a["label"] for a in json.load(open(answers))}
    changed = 0
    for l in labels:
        new = fixes.get(round(l["start"], 2))
        if new and new != l["label"]:
            l["label"], l["checked"] = new, True; changed += 1
        elif new:
            l["checked"] = True
    os.makedirs(os.path.join(ROOT, "labels"), exist_ok=True)
    json.dump(labels, open(os.path.join(ROOT, "labels", f"{vid}.json"), "w"), indent=1)
    agree = (len(fixes) - changed) / max(1, len(fixes))
    print(f"{len(fixes)} checked, {changed} changed, draft agreement {agree:.0%}")

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--id", required=True); ap.add_argument("--n", type=int, default=15)
    ap.add_argument("--apply")
    a = ap.parse_args()
    apply(a.id, a.apply) if a.apply else build(a.id, a.n)
