#!/bin/bash

# On-demand gate: speak only when explicitly enabled. The presence of this flag
# file is the single source of truth for TTS state; absent = off (the default).
# Flip it with tts-toggle.sh. [LAW:one-source-of-truth]
[[ -f "$HOME/.claude/hooks/tts-enabled" ]] || exit 0

HOOK_INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)

[[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]] && exit 0

LAST_TEXT=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 100 | \
  jq -rs 'map(.message.content[]? | select(.type == "text") | .text) | last // ""' 2>/dev/null)

[[ -z "$LAST_TEXT" ]] && exit 0

CLEAN=$(echo "$LAST_TEXT" | perl -0777 -pe '
  s/```.*?```//gs;
  s/`[^`]+`//g;
  s/\*\*([^*]+)\*\*/$1/g;
  s/\*([^*]+)\*/$1/g;
  s/^#{1,6}\s+//gm;
  s/^>\s+//gm;
  s/\[([^\]]+)\]\([^)]+\)/$1/g;
  s/^[-*]\s+//gm;
  s/^---+$\n?//gm;
  s/\s+/ /g;
  s/^\s+|\s+$//g;
')

[[ -z "$CLEAN" ]] && exit 0

LOG="$HOME/.claude/hooks/tts-last-fired.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') fired, ${#CLEAN} chars" >> "$LOG"

# Voice via xAI Grok TTS instead of macOS `say`. The key is a real file kept out
# of the dotfiles repo; its presence is required to speak. Absent/empty key is a
# loud log line, never silent. [LAW:no-silent-failure] [LAW:one-source-of-truth]
KEY_FILE="$HOME/.claude/hooks/.xai-api-key"
if [[ ! -s "$KEY_FILE" ]]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: no xAI key at $KEY_FILE; cannot speak" >> "$LOG"
  exit 0
fi

AUDIO="/tmp/claude-tts.mp3"
TTS_REQ="/tmp/claude-tts-req.json"
SUM_REQ="/tmp/claude-tts-sum.json"
FALLBACK_FILE="/tmp/claude-tts-fallback.txt"

# Elevator-pitch layer: faithfully distill the reply to its essence, then speak
# that. The summarizer is a narrator, never a participant — temperature 0 plus a
# strict prompt keep it from inventing questions or next steps that change the
# reply's intent. The raw reply (markdown intact) is the better input: code
# fences tell it what implementation detail to drop. The cleaned full text is
# stashed as the fallback the worker speaks if summarizing fails.
SUM_SYS='You distill a reply from an AI coding assistant into a short spoken version. You are a faithful narrator, not a participant.

RULES:
- Distill only. Never add, invent, infer, or imply anything not explicitly in the reply.
- Never introduce a question, request, suggestion, or next step the reply does not itself contain. If the reply asks the user nothing, your summary asks nothing.
- Preserve the reply intent and stance exactly. Do not soften, escalate, editorialize, or add sign-offs.
- Drop code, file paths, commands, and step-by-step detail; keep what was done, found, asked, or decided.
- 1 to 3 sentences. Output only the spoken text.
- Only if the reply itself contains a decision the user must make, a risk, or a question awaiting their answer, end with exactly: You will want to read this one in full.

Bad (invents a question the reply never asked): "...TTS is on. What would you like to build first?"
Good (says only what the reply said): "...The summarizer runs on every spoken reply; this message is the first live test."'
jq -n --arg m "grok-4.20-0309-non-reasoning" --arg s "$SUM_SYS" --arg u "${LAST_TEXT:0:12000}" \
  '{model:$m, temperature:0, messages:[{role:"system",content:$s},{role:"user",content:$u}]}' > "$SUM_REQ"
printf '%s' "$CLEAN" > "$FALLBACK_FILE"

# Barge-in: stop the previous reply's worker, playback, and any in-flight xAI
# calls before starting this one.
pkill -f "tts-speak.sh"  2>/dev/null || true
pkill -f "afplay $AUDIO" 2>/dev/null || true
pkill -f "api.x.ai"      2>/dev/null || true

# Hand off to the background worker so the hook returns immediately.
nohup bash "$HOME/.claude/hooks/tts-speak.sh" \
  "$SUM_REQ" "$FALLBACK_FILE" "$AUDIO" "$TTS_REQ" "$LOG" >/dev/null 2>&1 &

exit 0
