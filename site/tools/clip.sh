#!/bin/bash
# clip.sh <recording.mov> <id> [start-seconds] [duration-seconds] [crop w:h:x:y]
# Turns a screen recording into public/clips/<id>.webm (VP9), <id>.mp4 (H.264, faststart) and <id>.jpg (poster,
# the first frame): 1280 px wide, 30 fps, silent, short. Then set `ready: true` for <id> in src/pages.js.
set -euo pipefail
in=$1 id=$2 ss=${3:-0} t=${4:-6} crop=${5:-}
out="$(dirname "$0")/../public/clips"; mkdir -p "$out"
vf="${crop:+crop=$crop,}fps=30,scale=1280:-2:flags=lanczos"
ffmpeg -loglevel error -y -ss "$ss" -t "$t" -i "$in" -an -vf "$vf" -c:v libvpx-vp9 -crf 38 -b:v 0 -row-mt 1 -deadline good "$out/$id.webm"
ffmpeg -loglevel error -y -ss "$ss" -t "$t" -i "$in" -an -vf "$vf,format=yuv420p" -c:v libx264 -preset slow -crf 26 -movflags +faststart "$out/$id.mp4"
ffmpeg -loglevel error -y -ss "$ss" -i "$in" -frames:v 1 -vf "$vf" -q:v 4 "$out/$id.jpg"
ls -la "$out/$id".*
