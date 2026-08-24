# App Preview pipeline

Assembles iPhone screen recordings into an App Store **App Preview** video.
Raw footage comes from a field session on the phone (the AR sky can't run in
the simulator); this tool does the cutting, scaling, and encoding.

## Spec (App Store Connect, verified 2026-08-17)

- One **886x1920 portrait** file covers every iPhone display size — ASC
  scales it down for the smaller devices.
- 15–30 s, ≤500 MB, ≤30 fps, H.264 High Profile 4.0 at 10–12 Mbps VBR.
- A **stereo audio track is required** even if silent — the script always
  adds silent 256 kbps AAC and drops any recorded audio (mic bleed).
- Up to 3 previews per localization; the first autoplays muted in the store.
- Poster frame defaults to t=5 s; pick a better one in ASC after upload.
- Content rule: pure screen capture of the real app experience — no hands,
  no device frame, no debug panel on screen.

## Usage

```
# Whole clips, in order:
tools/app-preview/make-preview.sh -o preview.mov clip1.mov clip2.mov

# Or cut from an edit list ("path start end" in seconds, # comments ok):
tools/app-preview/make-preview.sh -o preview.mov -e edit.txt
```

The script normalizes any recording size (iPhone 16's 1179x2556 scales to
886x1920 with a 0.04% aspect difference, absorbed by center-crop), conforms
to 30 fps, concatenates, encodes to spec, and then **verifies its own output**
with ffprobe — a non-zero exit means the file would fail ASC validation.

## Storyboard (~28 s target)

| Beat | Time | Footage |
|---|---|---|
| The sky, labeled | 0–5 s | AR view, 2+ plane labels drifting, slow steady aim |
| Lock on | 5–9 s | Tap a label, reticle snaps to the plane |
| The catch | 9–16 s | CAPTURE tap → flash → split-flap reveal settles: type, route, rarity, points |
| Bonus round | 16–20 s | Route guess answered, +25% lands |
| The Hangar | 20–26 s | Grid scroll, open a set (Helicopters), open one card |
| Close | 26–29 s | Back to the sky, a fresh label appears |

Beat 1 puts labeled sky at t=5 s — the default poster frame.

## Field capture notes (for the phone)

- Add **Screen Recording** to Control Center; start recording *before*
  opening the app (trimmed later). Portrait only.
- **Focus/DND on** — one notification banner kills a take.
- Record generously: 3+ takes per beat, keep rolling 5 s past the moment.
- The full catch (aim → tap → capture → reveal → bonus round) should be one
  unbroken take; the cut happens in the edit list.
- AirDrop the recordings to the Mac and run the script (or hand the folder
  to Claude with rough in/out points).
