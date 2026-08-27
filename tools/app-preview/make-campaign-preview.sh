#!/usr/bin/env bash
# make-campaign-preview.sh — Tailspot's high-energy App Store campaign cut.
# A short kinetic hook leads into real app screens and lands on a loopable
# brand end card. All UI and aircraft imagery comes from Tailspot itself.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-"$ROOT/marketing/app-preview/tailspot-app-preview-campaign.mov"}
SCREENS="$ROOT/marketing/app-store-screenshots/public/screenshots/apple/iphone/en"
FONT="$ROOT/ios/Tailspot/Tailspot/B612Mono-Bold.ttf"
ICON="$ROOT/ios/Tailspot/Tailspot/Assets.xcassets/AppIcon.appiconset/icon-dark.png"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$(dirname "$OUT")"
command -v magick >/dev/null || { echo "error: ImageMagick is required" >&2; exit 1; }

for name in slide1-ar-catch.png slide2-collection-card.png slide3-guess-round.png \
            slide4-hangar-sets.png slide5-trophies.png slide6-leaderboard.png; do
  [[ -f "$SCREENS/$name" ]] || { echo "error: missing $SCREENS/$name" >&2; exit 1; }
done
[[ -f "$FONT" && -f "$ICON" ]] || { echo "error: missing Tailspot brand asset" >&2; exit 1; }

# Kinetic opening cards. They stay on one dark field so the energy comes from
# movement and typography rather than full-frame brightness changes.
magick -size 886x1920 gradient:'#050810-#0A0E1A' \
  -fill '#00D4FF' -draw 'rectangle 74,630 82,1290' \
  -font "$FONT" -pointsize 100 -fill '#E8F4FF' -gravity center -annotate +0-20 'THE SKY' \
  -font "$FONT" -pointsize 18 -fill '#7F8B98' -gravity south -annotate +0+118 '37.87 N  /  122.27 W' \
  "$WORK/hook0.png"
magick -size 886x1920 gradient:'#0A0E1A-#11182A' \
  -fill '#FF6BE6' -draw 'rectangle 160,928 726,936' \
  -font "$FONT" -pointsize 120 -fill '#E8F4FF' -gravity center -annotate +0-20 'IS A' \
  -font "$FONT" -pointsize 18 -fill '#7F8B98' -gravity south -annotate +0+118 'LIVE TRAFFIC  /  REAL CATCHES' \
  "$WORK/hook1.png"
magick -size 886x1920 gradient:'#11182A-#050810' \
  -fill '#00D4FF' -draw 'rectangle 126,1130 760,1138' \
  -font "$FONT" -pointsize 138 -fill '#00D4FF' -gravity center -annotate +0-20 'GAME.' \
  -font "$FONT" -pointsize 22 -fill '#E8F4FF' -gravity north -annotate +0+142 'TAILSPOT' \
  "$WORK/hook2.png"

# Compact floating callouts—far less real estate than the previous full-width
# editorial bars. They clear quickly, leaving each app screen to sell itself.
make_callout() {
  local file=$1 accent=$2 kicker=$3 headline=$4 detail=$5 headline_size=$6
  magick -size 886x360 xc:none \
    -fill '#050810D9' -stroke '#FFFFFF18' -strokewidth 2 \
    -draw 'roundrectangle 42,54 844,318 28,28' \
    -fill "$accent" -stroke none -draw 'roundrectangle 70,82 300,120 18,18' \
    -font "$FONT" -pointsize 14 -fill '#050810' -annotate +86+107 "$kicker" \
    -font "$FONT" -pointsize "$headline_size" -fill '#E8F4FF' -annotate +70+188 "$headline" \
    -font "$FONT" -pointsize 13 -fill '#A0B0C0' -annotate +72+244 "$detail" \
    -fill "$accent" -draw 'rectangle 70,276 774,280' \
    "$WORK/$file.png"
}

make_callout capture '#00D4FF' 'CATCH 001' 'CAPTURED. +75' 'RARE  /  FIRST OF TYPE' 38
make_callout route '#FF6BE6' 'BONUS ROUND' 'KNOW THE ROUTE?' 'DESTINATION CORRECT  /  +25%' 36
make_callout hangar '#00D4FF' 'THE HANGAR' 'BUILD THE FLEET.' 'EVERY MAKE. EVERY MODEL.' 38
make_callout trophies '#FBBF24' 'TROPHIES' 'EARN THE RARE.' 'MILESTONES THAT MEAN SOMETHING.' 37
make_callout rank '#00D4FF' 'WEEKLY BOARD' 'CHASE THE TOP.' 'YOUR SKY. YOUR SCORE.' 38

# Loopable end card: same near-black field as the first frame.
magick -size 886x1920 gradient:'#0A0E1A-#050810' \
  \( "$ICON" -resize 220x220 \) -gravity center -geometry +0-172 -composite \
  -font "$FONT" -pointsize 66 -fill '#E8F4FF' -gravity center -annotate +0+48 'LOOK UP.' \
  -font "$FONT" -pointsize 20 -fill '#00D4FF' -gravity center -annotate +0+126 'TAILSPOT' \
  -font "$FONT" -pointsize 14 -fill '#7F8B98' -gravity south -annotate +0+112 'POINT. CAPTURE. COLLECT.' \
  "$WORK/end.png"

# Original electronic score: low aviation hum, a 120 BPM pulse, cockpit ticks,
# and a rising capture chirp. It is intentionally quiet; the edit still reads
# without sound because App Store previews autoplay muted.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "aevalsrc=exprs='0.045*sin(2*PI*55*t)+0.025*sin(2*PI*110*t)*(0.55+0.45*sin(2*PI*2*t))+0.11*sin(2*PI*(70+90*exp(-18*mod(t\,0.5)))*mod(t\,0.5))*exp(-16*mod(t\,0.5))+0.014*sin(2*PI*1650*t)*lt(mod(t\,0.25)\,0.018)':s=48000:d=21.55" \
  -af "highpass=f=32,lowpass=f=7600,acompressor=threshold=0.10:ratio=3:attack=5:release=120,alimiter=limit=0.82,afade=t=in:st=0:d=0.22,afade=t=out:st=20.95:d=0.60,aformat=channel_layouts=stereo" \
  -c:a pcm_s16le "$WORK/score.wav"

ffmpeg -hide_banner -loglevel error -y \
  -loop 1 -framerate 30 -t 0.70 -i "$WORK/hook0.png" \
  -loop 1 -framerate 30 -t 0.70 -i "$WORK/hook1.png" \
  -loop 1 -framerate 30 -t 0.95 -i "$WORK/hook2.png" \
  -loop 1 -framerate 30 -t 4.40 -i "$SCREENS/slide1-ar-catch.png" \
  -loop 1 -framerate 30 -t 3.30 -i "$SCREENS/slide2-collection-card.png" \
  -loop 1 -framerate 30 -t 3.10 -i "$SCREENS/slide3-guess-round.png" \
  -loop 1 -framerate 30 -t 3.30 -i "$SCREENS/slide4-hangar-sets.png" \
  -loop 1 -framerate 30 -t 3.00 -i "$SCREENS/slide5-trophies.png" \
  -loop 1 -framerate 30 -t 3.40 -i "$SCREENS/slide6-leaderboard.png" \
  -loop 1 -framerate 30 -t 2.00 -i "$WORK/end.png" \
  -loop 1 -framerate 30 -t 3.30 -i "$WORK/capture.png" \
  -loop 1 -framerate 30 -t 3.10 -i "$WORK/route.png" \
  -loop 1 -framerate 30 -t 3.30 -i "$WORK/hangar.png" \
  -loop 1 -framerate 30 -t 3.00 -i "$WORK/trophies.png" \
  -loop 1 -framerate 30 -t 3.40 -i "$WORK/rank.png" \
  -i "$WORK/score.wav" \
  -filter_complex "
    [0:v]scale=886:1920,zoompan=z='min(zoom+0.0012,1.025)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=886x1920:fps=30,trim=duration=0.70,setpts=PTS-STARTPTS,format=yuv420p[h0];
    [1:v]scale=886:1920,zoompan=z='min(zoom+0.0012,1.025)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=886x1920:fps=30,trim=duration=0.70,setpts=PTS-STARTPTS,format=yuv420p[h1];
    [2:v]scale=886:1920,zoompan=z='min(zoom+0.0010,1.025)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=886x1920:fps=30,trim=duration=0.95,setpts=PTS-STARTPTS,format=yuv420p[h2];
    [3:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00030,1.045)':x='(iw-iw/zoom)*(0.22+0.52*on/132)':y='(ih-ih/zoom)*(0.16+0.32*on/132)':d=1:s=886x1920:fps=30,trim=duration=4.40,setpts=PTS-STARTPTS,vignette=PI/8,drawbox=x=78:y='330+240*t':w=730:h=2:color=0x00D4FF@0.34:t=fill:enable='between(t,0.3,2.4)'[ar];
    [4:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00050,1.065)':x='(iw-iw/zoom)*(0.24+0.48*on/99)':y='(ih-ih/zoom)*(0.12+0.70*on/99)':d=1:s=886x1920:fps=30,trim=duration=3.30,setpts=PTS-STARTPTS,vignette=PI/8[cb];
    [10:v]format=rgba,fade=t=in:st=0.16:d=0.24:alpha=1,fade=t=out:st=1.78:d=0.30:alpha=1[oc];
    [cb][oc]overlay=x='if(lt(t,0.38),-760+2000*t,if(gt(t,1.72),-(t-1.72)*900,0))':y=0:shortest=1,format=yuv420p[capture];
    [5:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00048,1.064)':x='(iw-iw/zoom)*(0.72-0.46*on/93)':y='(ih-ih/zoom)*(0.10+0.72*on/93)':d=1:s=886x1920:fps=30,trim=duration=3.10,setpts=PTS-STARTPTS,vignette=PI/8[gb];
    [11:v]format=rgba,fade=t=in:st=0.12:d=0.24:alpha=1,fade=t=out:st=1.65:d=0.28:alpha=1[og];
    [gb][og]overlay=x='if(lt(t,0.38),-760+2000*t,if(gt(t,1.60),-(t-1.60)*900,0))':y=0:shortest=1,format=yuv420p[guess];
    [6:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00046,1.064)':x='(iw-iw/zoom)*(0.08+0.82*on/99)':y='(ih-ih/zoom)*(0.06+0.82*on/99)':d=1:s=886x1920:fps=30,trim=duration=3.30,setpts=PTS-STARTPTS,vignette=PI/8[hb];
    [12:v]format=rgba,fade=t=in:st=0.12:d=0.24:alpha=1,fade=t=out:st=1.78:d=0.28:alpha=1[oh];
    [hb][oh]overlay=x='if(lt(t,0.38),-760+2000*t,if(gt(t,1.72),-(t-1.72)*900,0))':y=0:shortest=1,format=yuv420p[hangar];
    [7:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00050,1.064)':x='(iw-iw/zoom)*(0.78-0.64*on/90)':y='(ih-ih/zoom)*(0.08+0.82*on/90)':d=1:s=886x1920:fps=30,trim=duration=3.00,setpts=PTS-STARTPTS,vignette=PI/8[tb];
    [13:v]format=rgba,fade=t=in:st=0.12:d=0.24:alpha=1,fade=t=out:st=1.56:d=0.28:alpha=1[ot];
    [tb][ot]overlay=x='if(lt(t,0.38),-760+2000*t,if(gt(t,1.52),-(t-1.52)*900,0))':y=0:shortest=1,format=yuv420p[trophy];
    [8:v]scale=1024:2220:force_original_aspect_ratio=increase:flags=lanczos,crop=1024:2220,zoompan=z='min(zoom+0.00046,1.064)':x='(iw-iw/zoom)*(0.18+0.66*on/102)':y='(ih-ih/zoom)*(0.08+0.68*on/102)':d=1:s=886x1920:fps=30,trim=duration=3.40,setpts=PTS-STARTPTS,vignette=PI/8[lb];
    [14:v]format=rgba,fade=t=in:st=0.12:d=0.24:alpha=1,fade=t=out:st=1.84:d=0.30:alpha=1[ol];
    [lb][ol]overlay=x='if(lt(t,0.38),-760+2000*t,if(gt(t,1.78),-(t-1.78)*900,0))':y=0:shortest=1,format=yuv420p[lead];
    [9:v]scale=886:1920,zoompan=z='min(zoom+0.00045,1.025)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=886x1920:fps=30,trim=duration=2.00,setpts=PTS-STARTPTS,format=yuv420p[end];
    [h0][h1]xfade=transition=smoothup:duration=0.25:offset=0.45[x1];
    [x1][h2]xfade=transition=smoothup:duration=0.25:offset=0.90[x2];
    [x2][ar]xfade=transition=fade:duration=0.40:offset=1.45[x3];
    [x3][capture]xfade=transition=smoothup:duration=0.40:offset=5.45[x4];
    [x4][guess]xfade=transition=smoothleft:duration=0.40:offset=8.35[x5];
    [x5][hangar]xfade=transition=smoothup:duration=0.40:offset=11.05[x6];
    [x6][trophy]xfade=transition=smoothleft:duration=0.40:offset=13.95[x7];
    [x7][lead]xfade=transition=smoothup:duration=0.40:offset=16.55[x8];
    [x8][end]xfade=transition=fadeblack:duration=0.40:offset=19.55,format=yuv420p[vout]" \
  -map "[vout]" -map 15:a:0 -shortest \
  -c:v libx264 -profile:v high -level:v 4.0 -preset slow \
  -b:v 11M -minrate 10M -maxrate 12M -bufsize 24M -x264-params "nal-hrd=cbr:force-cfr=1:filler=1" \
  -c:a aac -b:a 256k -ar 48000 -movflags +faststart \
  "$OUT"

W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$OUT")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$OUT")
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")
PROFILE=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile -of csv=p=0 "$OUT")
LEVEL=$(ffprobe -v error -select_streams v:0 -show_entries stream=level -of csv=p=0 "$OUT")
CHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$OUT")

echo "== $OUT =="
echo "video: H.264 $PROFILE L$LEVEL ${W}x${H} @ 30 fps"
echo "audio: ${CHANNELS}ch AAC  /  duration: ${DUR}s"
[[ $W == 886 && $H == 1920 && $PROFILE == High && $LEVEL == 40 && $CHANNELS == 2 ]] || exit 1
