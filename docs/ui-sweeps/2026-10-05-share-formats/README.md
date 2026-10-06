# Share by destination mockups (2026-10-05, PR #317)

HTML approximations of the share sheet (`sheet.png`), the Instagram Post
image (`share-post.png`, 4:5) and the Instagram Story composition
(`share-story.png`, 9:16: card sticker over the blurred catch photo),
rendered at 3× in headless Chromium. Not app renders: the branch was
authored without Xcode, and fonts are DejaVu Sans Mono instead of SF Mono.
The Cessna photo is cropped from a real share card. For real pixels, run
`ShareCardSnapshotTests` (writes `format_*.png` to `/private/tmp/tailspot_snaps`).
