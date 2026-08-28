#!/usr/bin/env bash
# make-hero-preview.sh — motion-led Tailspot product-film cut.
# It uses production Tailspot screens, then layers editorial copy, animated
# HUD accents, and transitions permitted for App Store app previews.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-"$ROOT/marketing/app-preview/tailspot-app-preview-hero.mov"}
ASSETS="$ROOT/marketing/app-store-screenshots/public/screenshots/apple/iphone/en"
FONT="$ROOT/ios/Tailspot/Tailspot/B612Mono-Bold.ttf"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$(dirname "$OUT")"
command -v magick >/dev/null || { echo "error: ImageMagick (magick) is required" >&2; exit 1; }

for name in \
  slide1-ar-catch.png \
  slide2-collection-card.png \
  slide3-guess-round.png \
  slide4-hangar-sets.png \
  slide5-trophies.png \
  slide6-leaderboard.png; do
  [[ -f "$ASSETS/$name" ]] || { echo "error: missing $ASSETS/$name" >&2; exit 1; }
done
[[ -f "$FONT" ]] || { echo "error: missing brand font: $FONT" >&2; exit 1; }

# Build transparent title cards from the same cockpit font Tailspot uses in
# app. They are temporary render assets, not separate product artwork.
make_title_card() {
  local name=$1 accent=$2 kicker=$3 headline=$4 subtitle=$5 headline_size=$6 line_width=$7 panel_height=$8
  magick -size 886x330 xc:none \
    -fill '#050810E8' -draw "rectangle 0,0 886,$panel_height" \
    -fill "$accent" -draw "rectangle 58,86 $((58 + line_width)),89" \
    -font "$FONT" -pointsize 17 -fill "$accent" -annotate +58+115 "$kicker" \
    -font "$FONT" -pointsize "$headline_size" -fill '#E8F4FF' -annotate +58+166 "$headline" \
    -font "$FONT" -pointsize 13 -fill '#A0B0C0' -annotate +60+219 "$subtitle" \
    "$TMPDIR/$name.png"
}

make_title_card title0 '#00D4FF' 'TAILSPOT' 'SPOT THE SKY.' 'LIVE AIRCRAFT. ONE PERFECT LOCK.' 42 526 314
make_title_card title1 '#00D4FF' 'CAPTURE SEQUENCE' 'CAPTURE IT.' 'EVERY CATCH BECOMES A COLLECTIBLE.' 42 520 267
make_title_card title2 '#FF6BE6' 'ROUTE GUESS' 'KNOW THE ROUTE.' 'TURN EVERY FLIGHT INTO A CHALLENGE.' 37 610 267
make_title_card title3 '#00D4FF' 'THE HANGAR' 'BUILD THE HANGAR.' 'COLLECT EVERY MAKE AND MODEL.' 35 610 267
make_title_card title4 '#FBBF24' 'TROPHY CASE' 'EARN THE RARE.' 'EVERY FLIGHT MOVES YOU FORWARD.' 38 470 267
make_title_card title5 '#00D4FF' 'WEEKLY RANK' 'CHASE THE TOP.' 'CLIMB THE WEEKLY LEADERBOARD.' 41 610 310

# 6.6 + 4.7 + 4.7 + 4.6 + 4.5 + 5.7 seconds bridged by five 0.55 second
# transitions = 28.05 seconds. The t=5 default poster is the unobstructed
# AR lock-on, after the opening title card has cleared.
ffmpeg -hide_banner -loglevel error -y \
  -loop 1 -framerate 30 -t 6.6 -i "$ASSETS/slide1-ar-catch.png" \
  -loop 1 -framerate 30 -t 4.7 -i "$ASSETS/slide2-collection-card.png" \
  -loop 1 -framerate 30 -t 4.7 -i "$ASSETS/slide3-guess-round.png" \
  -loop 1 -framerate 30 -t 4.6 -i "$ASSETS/slide4-hangar-sets.png" \
  -loop 1 -framerate 30 -t 4.5 -i "$ASSETS/slide5-trophies.png" \
  -loop 1 -framerate 30 -t 5.7 -i "$ASSETS/slide6-leaderboard.png" \
  -f lavfi -i "anoisesrc=color=white:amplitude=0.0001:sample_rate=48000" \
  -loop 1 -framerate 30 -t 6.6 -i "$TMPDIR/title0.png" \
  -loop 1 -framerate 30 -t 4.7 -i "$TMPDIR/title1.png" \
  -loop 1 -framerate 30 -t 4.7 -i "$TMPDIR/title2.png" \
  -loop 1 -framerate 30 -t 4.6 -i "$TMPDIR/title3.png" \
  -loop 1 -framerate 30 -t 4.5 -i "$TMPDIR/title4.png" \
  -loop 1 -framerate 30 -t 5.7 -i "$TMPDIR/title5.png" \
  -filter_complex "
    [0:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00013,1.030)':x='(iw-iw/zoom)*(0.35+0.10*sin(on/37))':y='(ih-ih/zoom)*(0.26+0.08*sin(on/43))':d=1:s=886x1920:fps=30,trim=duration=6.6,setpts=PTS-STARTPTS,vignette=PI/7,drawbox=x=72:y='380+110*t':w=742:h=2:color=0x00D4FF@0.34:t=fill:enable='between(t,0.55,2.55)'[base0];
    [7:v]format=rgba,fade=t=in:st=0.14:d=0.35:alpha=1,fade=t=out:st=3.10:d=0.42:alpha=1[card0];
    [base0][card0]overlay=x='if(lt(t,0.46),-886+1926*t,0)':y=0:shortest=1,format=yuv420p[v0];
    [1:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00019,1.040)':x='(iw-iw/zoom)*(0.52+0.10*sin(on/27))':y='(ih-ih/zoom)*(0.38+0.12*sin(on/31))':d=1:s=886x1920:fps=30,trim=duration=4.7,setpts=PTS-STARTPTS,vignette=PI/8[base1];
    [8:v]format=rgba,fade=t=in:st=0.10:d=0.30:alpha=1,fade=t=out:st=2.48:d=0.40:alpha=1[card1];
    [base1][card1]overlay=x='if(lt(t,0.42),-886+2109*t,0)':y=0:shortest=1,format=yuv420p[v1];
    [2:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00018,1.045)':x='(iw-iw/zoom)*(0.30+0.16*sin(on/35))':y='(ih-ih/zoom)*(0.42+0.12*sin(on/29))':d=1:s=886x1920:fps=30,trim=duration=4.7,setpts=PTS-STARTPTS,vignette=PI/8[base2];
    [9:v]format=rgba,fade=t=in:st=0.10:d=0.30:alpha=1,fade=t=out:st=2.48:d=0.40:alpha=1[card2];
    [base2][card2]overlay=x='if(lt(t,0.42),-886+2109*t,0)':y=0:shortest=1,format=yuv420p[v2];
    [3:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00022,1.050)':x='(iw-iw/zoom)*(0.15+0.55*on/138)':y='(ih-ih/zoom)*(0.12+0.22*on/138)':d=1:s=886x1920:fps=30,trim=duration=4.6,setpts=PTS-STARTPTS,vignette=PI/8[base3];
    [10:v]format=rgba,fade=t=in:st=0.10:d=0.30:alpha=1,fade=t=out:st=2.40:d=0.40:alpha=1[card3];
    [base3][card3]overlay=x='if(lt(t,0.42),-886+2109*t,0)':y=0:shortest=1,format=yuv420p[v3];
    [4:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00021,1.048)':x='(iw-iw/zoom)*(0.50+0.14*sin(on/27))':y='(ih-ih/zoom)*(0.27+0.16*sin(on/33))':d=1:s=886x1920:fps=30,trim=duration=4.5,setpts=PTS-STARTPTS,vignette=PI/8[base4];
    [11:v]format=rgba,fade=t=in:st=0.10:d=0.30:alpha=1,fade=t=out:st=2.32:d=0.40:alpha=1[card4];
    [base4][card4]overlay=x='if(lt(t,0.42),-886+2109*t,0)':y=0:shortest=1,format=yuv420p[v4];
    [5:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00016,1.045)':x='(iw-iw/zoom)*(0.47+0.14*sin(on/38))':y='(ih-ih/zoom)*(0.20+0.10*sin(on/31))':d=1:s=886x1920:fps=30,trim=duration=5.7,setpts=PTS-STARTPTS,vignette=PI/8[base5];
    [12:v]format=rgba,fade=t=in:st=0.12:d=0.30:alpha=1,fade=t=out:st=3.72:d=0.42:alpha=1[card5];
    [base5][card5]overlay=x='if(lt(t,0.42),-886+2109*t,0)':y=0:shortest=1,format=yuv420p[v5];
    [v0][v1]xfade=transition=fadewhite:duration=0.55:offset=6.05[x1];
    [x1][v2]xfade=transition=smoothup:duration=0.55:offset=10.20[x2];
    [x2][v3]xfade=transition=circleopen:duration=0.55:offset=14.35[x3];
    [x3][v4]xfade=transition=diagtl:duration=0.55:offset=18.40[x4];
    [x4][v5]xfade=transition=fadeblack:duration=0.55:offset=22.35,format=yuv420p[vout]" \
  -map "[vout]" -map 6:a:0 -filter:a "aformat=channel_layouts=stereo" -shortest \
  -c:v libx264 -profile:v high -level:v 4.0 -preset slow \
  -b:v 11M -minrate 10M -maxrate 12M -bufsize 24M -x264-params "nal-hrd=cbr:force-cfr=1:filler=1" \
  -c:a aac -b:a 256k -ar 48000 -movflags +faststart \
  "$OUT"

probe() { ffprobe -v error -select_streams "$1" -show_entries "$2" -of default=nw=1:nk=1 "$OUT"; }
W=$(probe v:0 stream=width); H=$(probe v:0 stream=height)
CODEC=$(probe v:0 stream=codec_name); PROFILE=$(probe v:0 stream=profile)
LEVEL=$(probe v:0 stream=level); FPS=$(probe v:0 stream=avg_frame_rate)
CHANNELS=$(probe a:0 stream=channels)
DURATION=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT")

echo "== $OUT =="
echo "video: $CODEC $PROFILE L$LEVEL ${W}x${H} @ $FPS fps"
echo "audio: ${CHANNELS}ch AAC"
echo "duration: ${DURATION}s"
[[ $W == 886 && $H == 1920 && $CODEC == h264 && $PROFILE == High && $LEVEL == 40 && $CHANNELS == 2 ]] || {
  echo "FAIL: output did not conform to the intended App Preview profile" >&2
  exit 1
}
