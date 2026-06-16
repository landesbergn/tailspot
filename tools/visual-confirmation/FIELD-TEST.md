# Visual confirmation — field go/no-go loop

The detector + pipeline are merged and live, but feature-flagged: **Debug ON,
Release OFF** (`tailspot.debug.visualConfirm` in UserDefaults; default set by
`#if DEBUG` in `VisualConfirmationPipeline.swift`). Before flipping it on for
Release/TestFlight we need one thing the simulator can't give us: proof that the
CV box lands on real planes in the sky. This is that loop.

## 1. Record a session (Noah, on the phone)

The Debug build already on the phone has visual confirmation **on** by default.

1. Open Tailspot, tap the **wrench** (debug), confirm the **visual-confirm row**
   shows it's *available* and *on* (toggle on if not).
2. Tap **Record session** on.
3. Go outside and point at planes. For each: get it **locked** (tap it so the
   bracket acquires), then hold it roughly centered for several seconds. Do a few
   — near and far, clear sky and hazy — including at least one you can clearly see
   with your eye.
4. Tap **Record session** off.

While recording, the app saves ~1 crop/sec to
`Documents/replays/frames/` (a `crop-*.jpg` per sample + a `frames.jsonl` sidecar
with the predicted position and the detector's boxes).

## 2. Pull + score (Claude, offline)

```sh
udid=$(xcrun devicectl list devices | awk '/iPhone/{print $3; exit}')   # or from tools/deploy/config.sh
xcrun devicectl device copy from --device "$udid" \
  --domain-type appDataContainer --domain-identifier com.landesberg.Tailspot \
  --source Documents/replays/frames --destination ./frames

python3 tools/visual-confirmation/score_field_session.py ./frames
```

`score_field_session.py` writes `./frames/scored/`:
- `annotated/annotated-*.jpg` — each crop with the detector boxes drawn
  (top-confidence box green, others amber) and a cyan crosshair at the crop
  centre (≈ the geometry-predicted position).
- `montage.jpg` — a contact sheet of every annotated crop.
- `summary.txt` — recall (% of frames with a detection), confidence
  distribution, and **correction magnitude** (how far the chosen box sits from
  the predicted centre — small means geometry was already on target; large +
  box-on-plane means CV is adding real value).

## 3. Decide

Open `montage.jpg`. **GO** = the green box lands on the actual plane in most
frames where a plane is visible. Then flip the flag: change the `#if DEBUG`
default in `VisualConfirmationPipeline.swift` (or ship + toggle at runtime) and
release.

**NO-GO** = boxes miss the plane, or recall is low. That's tuning, not shipping —
likely levers: confidence threshold (decode, currently 0.30), crop side
(currently 640px native), or the model itself. Re-record and re-score; the tool
is re-runnable on the same frames as the detector changes.
