#!/bin/bash
# Records the narrated demo video.
#   1. Makes one narration clip per scene with ElevenLabs (cached by text).
#   2. Sets each scene's length from its clip and writes timeline.json.
#   3. Runs the app in --demo mode and records the stage with screencapture.
#   4. Trims the black lead-in and mixes the clips over the video with ffmpeg.
# Needs ~/.config/elevenlabs/api_key (or ELEVENLABS_API_KEY), jq and ffmpeg.
# DEMO_TTS=say uses the macOS voice instead, for a quick preview.
set -euo pipefail
cd "$(dirname "$0")/.."

narration=demo/narration.json
out=demo/out
audio=$out/audio
mkdir -p "$audio"

tts=${DEMO_TTS:-elevenlabs}
key=${ELEVENLABS_API_KEY:-$(cat ~/.config/elevenlabs/api_key 2>/dev/null || true)}
if [ "$tts" = elevenlabs ] && [ -z "$key" ]; then
  echo "No ElevenLabs key. Set ELEVENLABS_API_KEY or write ~/.config/elevenlabs/api_key." >&2
  exit 1
fi

voice=${VOICE_ID:-$(jq -r .voice_id "$narration")}
[ "$tts" = say ] && voice=say
model=$(jq -r .model_id "$narration")
lead=$(jq -r .lead "$narration")
tail=$(jq -r .tail "$narration")

echo "== Narration"
for id in $(jq -r '.scenes[].id' "$narration"); do
  text=$(jq -r --arg id "$id" '.scenes[] | select(.id == $id) | .text' "$narration")
  hash=$(printf '%s|%s|%s' "$voice" "$model" "$text" | shasum | cut -c1-12)
  clip=$audio/$id.mp3
  if [ -f "$clip" ] && [ "$(cat "$audio/$id.hash" 2>/dev/null)" = "$hash" ]; then
    echo "  $id (cached)"
    continue
  fi
  echo "  $id"
  if [ "$tts" = say ]; then
    say -o "$audio/$id.aiff" "$text"
    ffmpeg -y -loglevel error -i "$audio/$id.aiff" "$clip" && rm "$audio/$id.aiff"
    echo "$hash" > "$audio/$id.hash"
    continue
  fi
  jq -n --arg text "$text" --arg model "$model" \
    '{text: $text, model_id: $model, voice_settings: {stability: 0.45, similarity_boost: 0.8, style: 0.2}}' |
    curl -sS --fail-with-body -X POST "https://api.elevenlabs.io/v1/text-to-speech/$voice?output_format=mp3_44100_128" \
      -H "xi-api-key: $key" -H "Content-Type: application/json" --data @- -o "$clip"
  echo "$hash" > "$audio/$id.hash"
done

echo "== Timeline"
start=0
scenes=()
for id in $(jq -r '.scenes[].id' "$narration"); do
  min=$(jq -r --arg id "$id" '.scenes[] | select(.id == $id) | .min' "$narration")
  length=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$audio/$id.mp3")
  duration=$(awk -v a="$lead" -v b="$length" -v c="$tail" -v m="$min" 'BEGIN { d = a + b + c; if (d < m) d = m; printf "%.3f", d }')
  printf '  %-11s start %6.2f  length %5.2f\n' "$id" "$start" "$duration"
  scenes+=("{\"id\":\"$id\",\"start\":$start,\"duration\":$duration}")
  start=$(awk -v a="$start" -v b="$duration" 'BEGIN { printf "%.3f", a + b }')
done
total=$start
(IFS=,; echo "{\"scenes\":[${scenes[*]}]}") | jq . > $out/timeline.json

echo "== Build"
swift build -c release 2>&1 | tail -1

echo "== Record ($(printf '%.0f' "$total")s)"
rm -f $out/go $out/done $out/stage-rect.txt $out/raw.mov
.build/release/GhosttySessions --demo "$PWD/$out" &
app=$!
until [ -f $out/stage-rect.txt ]; do sleep 0.1; done
sleep 1
seconds=$(awk -v t="$total" 'BEGIN { printf "%d", t + 5 }')
screencapture -x -v -V "$seconds" -R "$(cat $out/stage-rect.txt)" $out/raw.mov &
recorder=$!
sleep 1
touch $out/go
wait $app || true
wait $recorder || true

echo "== Mix"
# The stage stays black until the first scene starts; that frame is t=0.
begin=$(ffmpeg -hide_banner -i $out/raw.mov -vf "blackdetect=d=0.2:pix_th=0.05" -an -f null - 2>&1 |
  sed -n 's/.*black_end:\([0-9.]*\).*/\1/p' | head -1)
begin=${begin:-0}
echo "  video starts at ${begin}s"

inputs=()
filters=""
labels=""
i=1
for id in $(jq -r '.scenes[].id' $out/timeline.json); do
  at=$(jq -r --arg id "$id" '.scenes[] | select(.id == $id) | .start' $out/timeline.json)
  ms=$(awk -v a="$at" -v l="$lead" 'BEGIN { printf "%d", (a + l) * 1000 }')
  inputs+=(-i "$audio/$id.mp3")
  filters+="[$i:a]adelay=${ms}|${ms}[a$i];"
  labels+="[a$i]"
  i=$((i + 1))
done
count=$((i - 1))

ffmpeg -y -hide_banner -loglevel error \
  -ss "$begin" -i $out/raw.mov "${inputs[@]}" \
  -filter_complex "${filters}${labels}amix=inputs=${count}:normalize=0,apad[aout];[0:v]fps=60,format=yuv420p[vout]" \
  -map "[vout]" -map "[aout]" -t "$total" \
  -c:v libx264 -preset slow -crf 18 -c:a aac -b:a 192k -movflags +faststart \
  $out/ghostty-sessions-demo.mp4

echo "== Done: $out/ghostty-sessions-demo.mp4"
