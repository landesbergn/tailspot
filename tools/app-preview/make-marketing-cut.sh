#!/usr/bin/env bash
# make-marketing-cut.sh — create a review cut from Tailspot's approved
# marketing captures. This is intentionally only a bridge while a physical
# iPhone field session is being captured; make-preview.sh remains the path for
# the final all-device-footage App Store submission.
#
# The output is exactly 886x1920, 28 seconds, H.264 High Profile 4.0 at
# 11 Mbps, 30 fps, and includes an inaudible stereo AAC track. The slight motion
# is a presentation treatment of the app screens, not a simulation of UI.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-"$ROOT/marketing/app-preview/tailspot-app-preview-review-cut.mov"}
ASSETS="$ROOT/marketing/app-store-screenshots/public/screenshots/apple/iphone/en"

mkdir -p "$(dirname "$OUT")"

for name in \
  slide1-ar-catch.png \
  slide2-collection-card.png \
  slide3-guess-round.png \
  slide4-hangar-sets.png \
  slide5-trophies.png \
  slide6-leaderboard.png; do
  [[ -f "$ASSETS/$name" ]] || { echo "error: missing $ASSETS/$name" >&2; exit 1; }
done

# 6.9 + 4.8 + 4.8 + 4.8 + 4.8 + 4.4, with five 0.5 s dissolves = 28.0 s.
# Scene one stays on the AR image through t=5, producing a strong default
# poster frame if the upload's poster frame is not manually changed.
ffmpeg -hide_banner -loglevel error -y \
  -loop 1 -framerate 30 -t 6.9 -i "$ASSETS/slide1-ar-catch.png" \
  -loop 1 -framerate 30 -t 4.8 -i "$ASSETS/slide2-collection-card.png" \
  -loop 1 -framerate 30 -t 4.8 -i "$ASSETS/slide3-guess-round.png" \
  -loop 1 -framerate 30 -t 4.8 -i "$ASSETS/slide4-hangar-sets.png" \
  -loop 1 -framerate 30 -t 4.8 -i "$ASSETS/slide5-trophies.png" \
  -loop 1 -framerate 30 -t 4.4 -i "$ASSETS/slide6-leaderboard.png" \
  -f lavfi -i "anoisesrc=color=white:amplitude=0.0001:sample_rate=48000" \
  -filter_complex "
    [0:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00010,1.020)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=886x1920:fps=30,trim=duration=6.9,setpts=PTS-STARTPTS,format=yuv420p[v0];
    [1:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00014,1.020)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=886x1920:fps=30,trim=duration=4.8,setpts=PTS-STARTPTS,format=yuv420p[v1];
    [2:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00014,1.020)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=886x1920:fps=30,trim=duration=4.8,setpts=PTS-STARTPTS,format=yuv420p[v2];
    [3:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00014,1.020)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=886x1920:fps=30,trim=duration=4.8,setpts=PTS-STARTPTS,format=yuv420p[v3];
    [4:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00014,1.020)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=886x1920:fps=30,trim=duration=4.8,setpts=PTS-STARTPTS,format=yuv420p[v4];
    [5:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00014,1.020)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=886x1920:fps=30,trim=duration=4.4,setpts=PTS-STARTPTS,format=yuv420p[v5];
    [v0][v1]xfade=transition=fade:duration=0.5:offset=6.4[x1];
    [x1][v2]xfade=transition=fade:duration=0.5:offset=10.7[x2];
    [x2][v3]xfade=transition=fade:duration=0.5:offset=15.0[x3];
    [x3][v4]xfade=transition=fade:duration=0.5:offset=19.3[x4];
    [x4][v5]xfade=transition=fade:duration=0.5:offset=23.6,format=yuv420p[vout]" \
  -map "[vout]" -map 6:a:0 -filter:a "aformat=channel_layouts=stereo" -shortest \
  -c:v libx264 -profile:v high -level:v 4.0 -preset slow \
  -b:v 11M -minrate 10M -maxrate 12M -bufsize 24M -x264-params "nal-hrd=cbr:force-cfr=1:filler=1" \
  -c:a aac -b:a 256k -ar 48000 -movflags +faststart \
  "$OUT"

probe() { ffprobe -v error -select_streams "$1" -show_entries "$2" -of default=nw=1:nk=1 "$OUT"; }
W=$(probe v:0 stream=width)
H=$(probe v:0 stream=height)
CODEC=$(probe v:0 stream=codec_name)
PROFILE=$(probe v:0 stream=profile)
FPS=$(probe v:0 stream=avg_frame_rate)
CHANNELS=$(probe a:0 stream=channels)
DURATION=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT")

echo "== $OUT =="
echo "video: $CODEC $PROFILE ${W}x${H} @ $FPS fps"
echo "audio: ${CHANNELS}ch AAC"
echo "duration: ${DURATION}s"
[[ $W == 886 && $H == 1920 && $CODEC == h264 && $CHANNELS == 2 ]] || {
  echo "FAIL: output did not conform to the intended App Preview profile" >&2
  exit 1
}
