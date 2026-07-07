#!/usr/bin/env python3
"""Local plane-labeling utility.

Serves a click-to-label page over the catch-photo corpus: unchanged
(fallback) photos first, then the pre-composer ones. Two-stage click for
precision (full frame -> 4x magnified region -> exact point). Labels are
POSTed back and saved to labels.json after every action, so closing the
tab loses nothing.

Run: python3 labeler.py   then open http://127.0.0.1:8765
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
PHOTOS = HERE / "all-photos"
LABELS = HERE / "labels.json"

data = json.loads((HERE / "report-data.json").read_text())
pairs = {m["file"] for m in json.loads((HERE / "pairs" / "pairs.json").read_text())}
fallback = [r["file"] for r in data["records"] if r["has_bracket"] and r["file"] not in pairs]
pre = [r["file"] for r in data["records"] if not r["has_bracket"]]
ORDER = fallback + pre
GROUP = {**{f: "unchanged" for f in fallback}, **{f: "pre-composer" for f in pre}}

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Tailspot plane labeler</title>
<style>
:root { --bg:#0a0e14; --surface:#121826; --ink:#e8edf4; --ink2:#8fa0b3; --line:#243044;
        --accent:#00d4ff; --good:#3ddc84; --warn:#ffb020; --bad:#ff5470; }
* { box-sizing:border-box; }
body { background:var(--bg); color:var(--ink); margin:0; height:100vh; display:flex;
       flex-direction:column; font:15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif; }
header { display:flex; gap:14px; align-items:center; padding:10px 16px;
         border-bottom:1px solid var(--line); flex-wrap:wrap; }
header .name { font-family:ui-monospace,Menlo,monospace; font-size:.9rem; }
header .grp { color:var(--ink2); font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; }
header .prog { margin-left:auto; color:var(--ink2); font-variant-numeric:tabular-nums; }
#stage { flex:1; display:flex; align-items:center; justify-content:center; min-height:0;
         padding:10px; position:relative; }
#stage img, #stage canvas { max-height:100%; max-width:100%; cursor:crosshair;
         border:1px solid var(--line); border-radius:8px; }
#hint { position:absolute; top:16px; left:50%; transform:translateX(-50%);
        background:rgba(10,14,20,.85); border:1px solid var(--line); padding:4px 14px;
        border-radius:99px; font-size:.8rem; color:var(--ink2); pointer-events:none; }
footer { display:flex; gap:10px; padding:10px 16px; border-top:1px solid var(--line);
         flex-wrap:wrap; align-items:center; }
button { background:var(--surface); color:var(--ink); border:1px solid var(--line);
         border-radius:8px; padding:8px 16px; font-size:.9rem; cursor:pointer; }
button:hover { border-color:var(--accent); }
button.none { color:var(--warn); } button.unsure { color:var(--ink2); }
button.undo { color:var(--bad); }
#done { display:none; flex:1; align-items:center; justify-content:center;
        flex-direction:column; gap:12px; }
.key { font-family:ui-monospace,Menlo,monospace; font-size:.75rem; color:var(--ink2);
       border:1px solid var(--line); border-radius:4px; padding:0 5px; margin-left:6px; }
#toast { position:fixed; bottom:70px; left:50%; transform:translateX(-50%);
         background:var(--surface); border:1px solid var(--good); color:var(--good);
         padding:6px 18px; border-radius:99px; opacity:0; transition:opacity .2s; }
</style></head><body>
<header>
  <span class="name" id="fname">—</span><span class="grp" id="fgrp"></span>
  <span class="prog" id="prog"></span>
</header>
<div id="stage"><div id="hint">Click roughly where the plane is — you'll get a zoomed view to refine</div></div>
<div id="done"><h2>All labeled — thank you!</h2><p id="donestats"></p></div>
<footer>
  <button class="none" onclick="mark('none')">No plane visible<span class="key">N</span></button>
  <button class="unsure" onclick="mark('unsure')">Can't tell<span class="key">U</span></button>
  <button onclick="skip()">Skip for now<span class="key">S</span></button>
  <button class="undo" onclick="undo()">Back / redo previous<span class="key">B</span></button>
  <span style="color:var(--ink2);font-size:.8rem;margin-left:auto">Zoomed view: click the plane · <span class="key">Esc</span> back to full frame</span>
</footer>
<div id="toast">saved</div>
<script>
let photos = [], labels = {}, idx = 0, img = null, zoom = null;
const ZOOM_SRC = 260, ZOOM_SCALE = 3;

async function init() {
  const s = await (await fetch('/state')).json();
  photos = s.photos; labels = s.labels;
  idx = photos.findIndex(p => !(p.file in labels));
  if (idx < 0) idx = photos.length;
  show();
}
function show() {
  zoom = null;
  const stage = document.getElementById('stage');
  if (idx >= photos.length) {
    stage.style.display = 'none';
    document.querySelector('footer').style.visibility = 'hidden';
    const d = document.getElementById('done'); d.style.display = 'flex';
    const n = Object.values(labels).filter(l => l.status === 'plane').length;
    document.getElementById('donestats').textContent =
      `${Object.keys(labels).length} photos labeled, ${n} planes marked. Labels are saved to labels.json — tell Claude you're done.`;
    return;
  }
  const p = photos[idx];
  document.getElementById('fname').textContent = p.file;
  document.getElementById('fgrp').textContent = p.group;
  document.getElementById('prog').textContent = `${Object.keys(labels).length} / ${photos.length} labeled`;
  stage.innerHTML = '<div id="hint">Click roughly where the plane is — you\\'ll get a zoomed view to refine</div>';
  img = new Image();
  img.src = '/img/' + p.file;
  img.onclick = e => {
    const r = img.getBoundingClientRect();
    const x = (e.clientX - r.left) / r.width * img.naturalWidth;
    const y = (e.clientY - r.top) / r.height * img.naturalHeight;
    showZoom(x, y);
  };
  stage.appendChild(img);
}
function showZoom(cx, cy) {
  const half = ZOOM_SRC / 2;
  const sx = Math.max(0, Math.min(cx - half, img.naturalWidth - ZOOM_SRC));
  const sy = Math.max(0, Math.min(cy - half, img.naturalHeight - ZOOM_SRC));
  zoom = {sx, sy};
  const c = document.createElement('canvas');
  c.width = c.height = ZOOM_SRC * ZOOM_SCALE;
  c.getContext('2d').drawImage(img, sx, sy, ZOOM_SRC, ZOOM_SRC, 0, 0, c.width, c.height);
  c.onclick = e => {
    const r = c.getBoundingClientRect();
    const x = sx + (e.clientX - r.left) / r.width * ZOOM_SRC;
    const y = sy + (e.clientY - r.top) / r.height * ZOOM_SRC;
    save({status:'plane', x:Math.round(x), y:Math.round(y)});
  };
  const stage = document.getElementById('stage');
  stage.innerHTML = '<div id="hint">Zoomed 3× — click exactly on the plane (Esc = back to full frame)</div>';
  stage.appendChild(c);
}
async function save(label) {
  const p = photos[idx];
  labels[p.file] = label;
  await fetch('/label', {method:'POST', body: JSON.stringify({file:p.file, ...label})});
  const t = document.getElementById('toast');
  t.style.opacity = 1; setTimeout(() => t.style.opacity = 0, 500);
  idx++; show();
}
function mark(status) { save({status}); }
function skip() { idx++; show(); }
function undo() {
  if (idx > 0) { idx--; const p = photos[idx]; delete labels[p.file];
    fetch('/label', {method:'POST', body: JSON.stringify({file:p.file, status:'__delete__'})});
    show(); }
}
document.addEventListener('keydown', e => {
  if (e.key === 'n' || e.key === 'N') mark('none');
  if (e.key === 'u' || e.key === 'U') mark('unsure');
  if (e.key === 's' || e.key === 'S') skip();
  if (e.key === 'b' || e.key === 'B') undo();
  if (e.key === 'Escape' && zoom) show();
});
init();
</script></body></html>"""


def load_labels():
    return json.loads(LABELS.read_text()) if LABELS.exists() else {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _send(self, body, ctype="text/html; charset=utf-8", code=200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            self._send(PAGE.encode())
        elif self.path == "/state":
            state = {
                "photos": [{"file": f, "group": GROUP[f]} for f in ORDER],
                "labels": load_labels(),
            }
            self._send(json.dumps(state).encode(), "application/json")
        elif self.path.startswith("/img/"):
            name = Path(self.path[5:]).name  # sanitized: basename only
            f = PHOTOS / name
            if f.exists() and f.suffix == ".jpg":
                self._send(f.read_bytes(), "image/jpeg")
            else:
                self._send(b"not found", code=404)
        else:
            self._send(b"not found", code=404)

    def do_POST(self):
        if self.path != "/label":
            self._send(b"not found", code=404)
            return
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n))
        labels = load_labels()
        name = req.pop("file")
        if req.get("status") == "__delete__":
            labels.pop(name, None)
        else:
            labels[name] = req
        LABELS.write_text(json.dumps(labels, indent=1))
        self._send(b"{}", "application/json")


if __name__ == "__main__":
    print(f"{len(ORDER)} photos to label ({len(fallback)} unchanged + {len(pre)} pre-composer)")
    print("serving on http://127.0.0.1:8765")
    ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
