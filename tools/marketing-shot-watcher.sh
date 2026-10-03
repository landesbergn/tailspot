#!/bin/bash
# Watches for ready_<name> flags from MarketingSnapshotTests and captures
# the booted simulator screen via simctl. Runs until killed or 15 min pass.
# Booted simulator to screenshot. Override for a different sim:
#   TAILSPOT_SIM=<udid> tools/marketing-shot-watcher.sh
SIM="${TAILSPOT_SIM:-$(xcrun simctl list devices booted -j \
  | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];\
print(next((x['udid'] for v in d.values() for x in v), ''))")}"
if [ -z "$SIM" ]; then echo "no booted simulator; boot one first" >&2; exit 1; fi
echo "watching sim $SIM"
DIR=/private/tmp/tailspot_snaps/marketing
END=$((SECONDS + 900))
while [ $SECONDS -lt $END ]; do
  for ready in "$DIR"/ready_*; do
    [ -e "$ready" ] || continue
    name=$(basename "$ready" | sed 's/^ready_//')
    sleep 0.4   # let the frame settle after the flag write
    xcrun simctl io "$SIM" screenshot "$DIR/$name.png" >/dev/null 2>&1
    # Newer simulators (seen on iOS 26.5, 2026-10) leave the Dynamic Island
    # OUT of the default screenshot, so a fresh shot sat next to older
    # slides with an island looks like a different phone. --mask=black
    # draws it back, but also blacks the screen corners — so take a second,
    # masked shot and copy over only the island (the pure-black pixels in
    # the top-centre band). Needs ImageMagick; skipped with a warning if not.
    if command -v magick >/dev/null 2>&1; then
      xcrun simctl io "$SIM" screenshot --mask=black "$DIR/.masked_$name.png" >/dev/null 2>&1
      read -r w h < <(magick identify -format '%w %h' "$DIR/$name.png")
      bx=$((w / 4)); bw=$((w / 2)); bh=$((h * 8 / 100))
      magick "$DIR/.masked_$name.png" -crop "${bw}x${bh}+${bx}+0" +repage \
        -fill white -opaque black -fill black +opaque white "$DIR/.island_$name.png"
      magick -size "${w}x${h}" xc:black "$DIR/.island_$name.png" -geometry "+${bx}+0" \
        -composite "$DIR/.islandmask_$name.png"
      magick "$DIR/$name.png" \( -size "${w}x${h}" xc:black \) "$DIR/.islandmask_$name.png" \
        -composite "$DIR/$name.png"
      rm -f "$DIR/.masked_$name.png" "$DIR/.island_$name.png" "$DIR/.islandmask_$name.png"
    else
      echo "  (no ImageMagick: $name has no Dynamic Island drawn)" >&2
    fi
    rm -f "$ready"
    touch "$DIR/done_$name"
    echo "captured $name"
  done
  sleep 0.3
done
