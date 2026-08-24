#!/usr/bin/env bash
# make-preview.sh — assemble iPhone screen recordings into an App Store
# App Preview that passes App Store Connect validation.
#
# Output spec (App Store Connect, verified 2026-08-17):
#   886x1920 portrait, H.264 High Profile Level 4.0, <=30 fps, 10-12 Mbps VBR,
#   stereo AAC 256 kbps audio track (required even if silent), 15-30 s, <500 MB.
#   One 886x1920 file serves every iPhone display size (ASC scales down).
#
# Usage:
#   make-preview.sh -o out.mov clip1.mov clip2.mov ...
#       Concatenate whole clips in order.
#   make-preview.sh -o out.mov -e edit.txt
#       Cut per an edit list: one "path start end" per line (seconds, decimals
#       ok; blank lines and #-comments ignored). Clips may repeat.
#
# Raw material: iPhone Control Center screen recordings (HEVC .mp4/.mov),
# AirDropped to the Mac. iPhone 16 records 1179x2556 — scales to 886x1920
# with a 0.04% aspect difference, absorbed by a 1-2 px crop.
set -euo pipefail

OUT=""
EDL=""
while getopts "o:e:" opt; do
  case $opt in
    o) OUT=$OPTARG ;;
    e) EDL=$OPTARG ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

[[ -n $OUT ]] || { echo "error: -o output.mov is required" >&2; exit 2; }

# Build the (clip, start, end) list. start/end empty = whole clip.
CLIPS=() STARTS=() ENDS=()
if [[ -n $EDL ]]; then
  while read -r path start end; do
    [[ -z $path || $path == \#* ]] && continue
    [[ -f $path ]] || { echo "error: no such clip: $path" >&2; exit 1; }
    CLIPS+=("$path"); STARTS+=("${start:-}"); ENDS+=("${end:-}")
  done < "$EDL"
else
  for path in "$@"; do
    [[ -f $path ]] || { echo "error: no such clip: $path" >&2; exit 1; }
    CLIPS+=("$path"); STARTS+=(""); ENDS+=("")
  done
fi
[[ ${#CLIPS[@]} -gt 0 ]] || { echo "error: no input clips" >&2; exit 2; }

# One filtergraph: per-clip trim -> normalize (fps, scale-crop to 886x1920,
# square pixels, yuv420p) -> concat. Scale to cover, then center-crop, so any
# recording aspect (1179x2556, 1290x2796, ...) lands exactly on 886x1920.
FILTER=""
INPUTS=()
for i in "${!CLIPS[@]}"; do
  INPUTS+=(-i "${CLIPS[$i]}")
  trim=""
  [[ -n ${STARTS[$i]} ]] && trim="start=${STARTS[$i]}"
  if [[ -n ${ENDS[$i]} ]]; then
    trim="${trim:+$trim:}end=${ENDS[$i]}"
  fi
  FILTER+="[$i:v]${trim:+trim=$trim,}setpts=PTS-STARTPTS,"
  FILTER+="fps=30,scale=886:1920:force_original_aspect_ratio=increase:flags=lanczos,"
  FILTER+="crop=886:1920,setsar=1,format=yuv420p[v$i];"
done
for i in "${!CLIPS[@]}"; do FILTER+="[v$i]"; done
FILTER+="concat=n=${#CLIPS[@]}:v=1:a=0[vout]"

# Silent stereo track: ASC rejects previews with no audio stream. Screen-
# recording audio (mic bleed, UI sounds) is deliberately dropped — swap in a
# music bed later by re-running with a real audio input if wanted.
ffmpeg -hide_banner -loglevel error -y "${INPUTS[@]}" \
  -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=48000" \
  -filter_complex "$FILTER" \
  -map "[vout]" -map "${#CLIPS[@]}:a" -shortest \
  -c:v libx264 -profile:v high -level:v 4.0 -preset slow \
  -b:v 11M -maxrate 12M -bufsize 24M \
  -c:a aac -b:a 256k \
  -movflags +faststart \
  "$OUT"

# --- Validate against the ASC spec -----------------------------------------
probe() { ffprobe -v error -select_streams "$1" -show_entries "$2" -of default=nw=1:nk=1 "$OUT"; }
W=$(probe v:0 stream=width); H=$(probe v:0 stream=height)
CODEC=$(probe v:0 stream=codec_name); PROFILE=$(probe v:0 stream=profile)
FPS=$(probe v:0 stream=avg_frame_rate)
ACODEC=$(probe a:0 stream=codec_name); CHANNELS=$(probe a:0 stream=channels)
DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT")
SIZE_MB=$(( $(stat -f%z "$OUT") / 1048576 ))

echo "== $OUT =="
echo "video:    ${CODEC} ${PROFILE} ${W}x${H} @ ${FPS} fps"
echo "audio:    ${ACODEC} ${CHANNELS}ch"
echo "duration: ${DUR%.*}s   size: ${SIZE_MB} MB"

FAIL=0
[[ $W == 886 && $H == 1920 ]] || { echo "FAIL: resolution must be 886x1920"; FAIL=1; }
[[ $CODEC == h264 ]] || { echo "FAIL: codec must be h264"; FAIL=1; }
[[ $CHANNELS == 2 ]] || { echo "FAIL: audio must be stereo"; FAIL=1; }
DUR_INT=${DUR%.*}
if (( DUR_INT < 15 || DUR_INT > 30 )); then
  echo "WARN: duration ${DUR_INT}s is outside the required 15-30 s window"
  FAIL=1
fi
(( SIZE_MB < 500 )) || { echo "FAIL: over the 500 MB limit"; FAIL=1; }
(( FAIL == 0 )) && echo "OK: passes App Preview spec (poster frame defaults to t=5s — pick it in ASC)"
exit $FAIL
