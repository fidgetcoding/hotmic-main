#!/bin/zsh
# Runs one recording from the livestream test corpus through Hot Mic and scores it.
#   bench/run.sh <video id> [prep|raw|split|clean|live-raw|live-split|live-clean|both]   (default both = raw + split)
# Needs bench/local/audio/<id>.* (yt-dlp bestaudio), bench/local/ref/<id>.txt (released lyrics, optional),
# bench/local/labels/<id>.json (stream timeline, optional). Outputs: bench/local/runs/<id>/<cond>/.
#   raw   = the stream as the mic (voice + beat + chat in one signal, Freestyle drop)
#   split = Demucs vocal stem as the mic, full stream as the mix (Beat mode: the beat comes from the tap)
#   clean = split with the labeled playback muted (a real session cancels DAW playback through the tap)
#   live-* = the same inputs through the live session path in the app, in real time (scripts/bundle.sh first)
# Nothing here plays audio or touches audio devices, except the live-* conditions, which open the app.
set -euo pipefail
id=$1; which=${2:-both}
root=${0:A:h}; L=$root/local; W=$L/work/$id; R=$L/runs/$id
WHISPER_MODEL=${WHISPER_MODEL:-$HOME/.whisper/ggml-large-v3-turbo.bin}
VAD_MODEL=${VAD_MODEL:-$HOME/.whisper/ggml-silero-v5.1.2.bin}
# No carried-over context + voice activity detection: on music, plain whisper loops one phrase for minutes.
WHISPER_FLAGS=(-l en -t 6 -mc 0 --vad -vm $VAD_MODEL)
BENCH=$root/../.build/release/hotmic-bench
# On battery, heavy jobs run on the efficiency cores.
bg() { if pmset -g batt | grep -q "Battery Power"; then taskpolicy -b nice -n 10 "$@"; else nice -n 10 "$@"; fi; }
mkdir -p $W $R
src=$(ls $L/audio/$id.* | head -1)

[[ -f $W/stream.wav ]] || bg ffmpeg -nostdin -loglevel error -i $src -ac 2 -ar 48000 $W/stream.wav
[[ -f $W/stream16.wav ]] || bg ffmpeg -nostdin -loglevel error -i $W/stream.wav -ac 1 -ar 16000 $W/stream16.wav
# Vocal stem (Demucs): the split condition's mic, and the source of the reference transcript + timeline draft.
if [[ ! -f $W/vocals48.wav ]]; then
  bg $HOME/.local/bin/demucs -d cpu -j 4 -n htdemucs --two-stems=vocals -o $W/demucs $W/stream.wav
  bg ffmpeg -nostdin -loglevel error -i $W/demucs/htdemucs/stream/vocals.wav -ac 1 -ar 48000 $W/vocals48.wav
fi
[[ -f $W/vocals16.wav ]] || bg ffmpeg -nostdin -loglevel error -i $W/vocals48.wav -ac 1 -ar 16000 $W/vocals16.wav
[[ -f $W/vocals.json ]] || bg whisper-cli -m $WHISPER_MODEL -f $W/vocals16.wav $WHISPER_FLAGS -oj -of $W/vocals >/dev/null 2>&1
# The stream's vocals in 10 s windows, each decoded on its own: the reference transcript for hand labels
# (one long pass merges minutes of nonstop singing into a word or two).
if [[ ! -f $W/windows.tsv ]]; then
  mkdir -p $W/win
  bg ffmpeg -nostdin -loglevel error -y -i $W/vocals16.wav -f segment -segment_time 10 -c copy $W/win/w%03d.wav
  local_files=(); for f in $W/win/w*.wav; do local_files+=(-f $f); done
  bg whisper-cli -m $WHISPER_MODEL "${local_files[@]}" -l en -t 6 -mc 0 -nt -otxt >/dev/null 2>&1
  for f in $W/win/w*.wav; do n=${${f:t:r}#w}; printf "%5d\t%s\n" $(( 10#$n * 10 )) "$(tr '\n' ' ' < $f.txt | sed 's/  */ /g')"; done > $W/windows.tsv
fi
[[ -f $W/labels.draft.json || ! -f $L/ref/$id.txt ]] || python3 -I $root/label.py --vocals $W/vocals16.wav --transcript $W/vocals.json \
  --ref $L/ref/$id.txt --out $W/labels.draft.json --tsv $W/labels.draft.tsv

transcribe() {  # <m4a> <out base> → <out base>.txt
  bg ffmpeg -nostdin -loglevel error -y -i $1 -ac 1 -ar 16000 $2.16k.wav
  bg whisper-cli -m $WHISPER_MODEL -f $2.16k.wav -l en -t 6 -mc 0 -otxt -of $2 >/dev/null 2>&1   # no VAD: it drops stitched vocals
  rm -f $2.16k.wav
}

run() {  # <cond>: raw | split | clean | live-raw | live-split | live-clean
  # HM_WHISPER_MODEL=<WhisperKit model> runs the import with another model, into <cond>-<model tail>/.
  local c=$1 out=$R/$1
  local model=(); [[ -n ${HM_WHISPER_MODEL:-} ]] && { model=(--model $HM_WHISPER_MODEL); out=$R/$1-${HM_WHISPER_MODEL##*_}; }
  # Keep earlier runs for before/after comparisons: <cond>.<timestamp>/
  [[ -d $out ]] && mv $out $out.$(date +%Y%m%d-%H%M%S)
  mkdir -p $out
  local voice=$W/stream.wav mix=()
  [[ $c == *split ]] && { voice=$W/vocals48.wav; mix=(--mix $W/stream.wav); }
  if [[ $c == *clean ]]; then
    # Split, with the labeled playback muted in the vocal stem: in a real Beat-mode session the DAW's
    # playback reaches Hot Mic through the tap and is cancelled, so the mic never hears it.
    local mute=$(python3 -I -c "import json,sys; print(','.join(f'volume=enable=\'between(t,{l[\"start\"]},{l[\"end\"]})\':volume=0' for l in json.load(open(sys.argv[1])) if l['label']=='playback'))" $L/labels/$id.json)
    [[ -n $mute ]] || { echo "no playback labels for $id"; return 1; }
    bg ffmpeg -nostdin -loglevel error -y -i $W/vocals48.wav -af "$mute" $W/vocals48-clean.wav
    voice=$W/vocals48-clean.wav; mix=(--mix $W/stream.wav)
  fi
  local t0=$(date +%s)
  if [[ $c == live-* ]]; then
    # The live session path runs inside the app, in real time (Apple's recognizer takes audio at speaking pace).
    pgrep -x HotMic >/dev/null && { echo "Hot Mic is open: quit it first (two live recognizers cancel each other)"; return 1; }
    local beat=(); [[ $c == live-split || $c == live-clean ]] && beat=(--beat)
    open -n -W "$root/../.build/Hot Mic.app" --args --bench-live $voice --out $out/session "${mix[@]}" "${beat[@]}"
    grep "bench-live" ~/Library/Logs/Hot\ Mic/hotmic.log | tail -400 > $out/live.log || true
  else
    bg $BENCH import $voice $out/session "${mix[@]}" "${model[@]}" > $out/import.log
  fi
  echo $(( $(date +%s) - t0 )) > $out/seconds
  $BENCH export $out/session $out/session.json
  $BENCH stitch $out/session $out/whole-song.m4a --plan $out/plan.json
  $BENCH stitch $out/session $out/whole-song__voice.m4a --voice
  transcribe $out/whole-song__voice.m4a $out/whole-song
  local extra=()
  [[ -f $L/ref/$id.txt ]] || { echo "no released lyrics for $id: skipping score"; return; }
  [[ -f $L/labels/$id.json ]] && extra+=(--labels $L/labels/$id.json)
  [[ -f $L/work/release-$id/release-vocals.txt ]] && extra+=(--ceiling $L/work/release-$id/release-vocals.txt)
  python3 -I $root/score.py --name "$id $c" --session $out/session.json --folder $out/session --ref $L/ref/$id.txt \
    --whole $out/whole-song.txt --plan $out/plan.json --out $out/score.json "${extra[@]}" | tee $out/score.md
}

case $which in
  prep) echo "prepped $W" ;;
  both) run raw; run split ;;
  *) run $which ;;
esac
