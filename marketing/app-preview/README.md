# Tailspot App Preview cuts

`tailspot-app-preview-campaign.mov` is the short, campaign-led master: a
three-beat kinetic hook, the real AR proof, a compact feature sprint, original
electronic sound design, and a loopable brand end card. It is the primary
creative cut.

`tailspot-app-preview-hero.mov` is the longer motion-led alternative.
It presents the current production captures as a compact product film: cockpit
HUD copy, animated scan lines, purposeful reframing, and feature-specific
transitions. `tailspot-app-preview-review-cut.mov` is the quieter reference
cut.

1. Live AR plane lock-on (real field capture)
2. Catch/collection card
3. Route guess round
4. Hangar sets
5. Trophy case
6. Leaderboard

It uses only Tailspot screens, with gentle motion and short dissolves. Its
five-second frame is the AR lock-on image, a strong poster-frame candidate.

Build the campaign cut again with:

```sh
tools/app-preview/make-campaign-preview.sh
```

The video meets the upload profile: 886x1920 portrait, 21.5 seconds, 30 fps,
H.264 High Profile 4.0, 11 Mbps target bitrate, and inaudible stereo AAC
audio. The tiny noise floor preserves a 256 kbps AAC stream; AAC otherwise
compresses perfectly silent audio to a few kilobits per second.

## Submission note

Apple asks for app previews to use footage captured on device. This review cut
is useful for creative approval and product-page planning, but is composed
from still production captures. Replace it with an edit assembled from a
physical iPhone screen recording before submitting to App Review. The final
capture and validation workflow is documented in `tools/app-preview/README.md`
and run with `tools/app-preview/make-preview.sh`.
