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

echo "$(date '+%Y-%m-%d %H:%M:%S') fired, ${#CLEAN} chars" >> ~/.claude/hooks/tts-last-fired.log

pkill -f "say -v Eddy" 2>/dev/null || true

nohup say -v "Eddy (English (US))" "$CLEAN" >/dev/null 2>&1 &

exit 0
