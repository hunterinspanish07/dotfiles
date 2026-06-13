#!/bin/bash
# Background TTS worker: turn an AI reply into a short spoken elevator pitch.
#
# Summarize the reply via xAI chat, synthesize that summary via xAI TTS (voice
# Ara), and play it with afplay. If the summarizer fails for any reason, speak
# the full-text fallback instead — logged loudly, never silent, never no speech.
# [LAW:no-silent-failure]
#
# Decomposed out of the Stop hook so it can be run and tested on its own, and so
# the hook returns immediately while this works in the background. [LAW:decomposition]
#
# Args: 1=summarizer-request.json  2=fallback-text-file  3=audio.mp3
#       4=tts-request.json         5=log-file
set -u

SUM_REQ="$1"; FALLBACK_FILE="$2"; AUDIO="$3"; TTS_REQ="$4"; LOG="$5"

# The key is the single source of truth, read here so the worker stands alone.
# [LAW:one-source-of-truth]
KEY_FILE="$HOME/.claude/hooks/.xai-api-key"
if [[ ! -s "$KEY_FILE" ]]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: no xAI key at $KEY_FILE; cannot speak" >> "$LOG"
  exit 0
fi
KEY=$(<"$KEY_FILE")

# Elevator-pitch layer: collapse the reply to its essence before speaking it.
SUMMARY=$(curl -sS --fail-with-body --max-time 20 \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -X POST https://api.x.ai/v1/chat/completions --data-binary @"$SUM_REQ" \
  2>/dev/null | jq -r '.choices[0].message.content // empty' 2>/dev/null)

if [[ -n "$SUMMARY" ]]; then
  SPEAK="$SUMMARY"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: summarizer failed; speaking full text" >> "$LOG"
  SPEAK=$(<"$FALLBACK_FILE")
fi

# xAI caps a TTS request at 15000 chars; trim the tail so it still speaks.
# speed 1.2 = a natural but brisk, fast-speaker pace (xAI allows 0.7-1.5).
jq -n --arg t "${SPEAK:0:15000}" '{text:$t, voice_id:"Ara", language:"en", speed:1.2}' > "$TTS_REQ"

http=$(curl -sS --fail-with-body \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -X POST https://api.x.ai/v1/tts \
  --data-binary @"$TTS_REQ" -o "$AUDIO" -w "%{http_code}") || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') TTS failed (http=$http): $(cat "$AUDIO")" >> "$LOG"; exit 0; }

afplay "$AUDIO"
