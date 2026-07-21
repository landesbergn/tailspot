#!/bin/bash
# Watches for ready_<name> flags from MarketingSnapshotTests and captures
# the booted simulator screen via simctl. Runs until killed or 15 min pass.
SIM=5F0C3177-250B-4A1A-AAB3-100F925F73C1
DIR=/private/tmp/tailspot_snaps/marketing
END=$((SECONDS + 900))
while [ $SECONDS -lt $END ]; do
  for ready in "$DIR"/ready_*; do
    [ -e "$ready" ] || continue
    name=$(basename "$ready" | sed 's/^ready_//')
    sleep 0.4   # let the frame settle after the flag write
    xcrun simctl io "$SIM" screenshot "$DIR/$name.png" >/dev/null 2>&1
    rm -f "$ready"
    touch "$DIR/done_$name"
    echo "captured $name"
  done
  sleep 0.3
done
