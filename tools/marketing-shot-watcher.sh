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
    rm -f "$ready"
    touch "$DIR/done_$name"
    echo "captured $name"
  done
  sleep 0.3
done
