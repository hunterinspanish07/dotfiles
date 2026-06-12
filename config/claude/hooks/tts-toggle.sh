#!/bin/bash

# Toggle on-demand TTS — the Stop hook (tts-stop-hook.sh) that speaks each
# response via macOS `say`. State is the presence of the flag file; this script
# is the only writer. [LAW:one-source-of-truth] [LAW:single-enforcer]
#
# Usage:  bash ~/.claude/hooks/tts-toggle.sh [on|off|toggle|status]
#         (no arg = toggle)

FLAG="$HOME/.claude/hooks/tts-enabled"

enable()  { : > "$FLAG"; echo "🔊 TTS on — responses will be spoken."; }
disable() { rm -f "$FLAG"; pkill -f "say -v Eddy" 2>/dev/null || true; echo "🔇 TTS off — responses will be silent."; }

case "${1:-toggle}" in
  on)     enable ;;
  off)    disable ;;
  status) [[ -f "$FLAG" ]] && echo "🔊 TTS is on." || echo "🔇 TTS is off." ;;
  toggle) [[ -f "$FLAG" ]] && disable || enable ;;
  *)      echo "usage: $(basename "$0") [on|off|toggle|status]" >&2; exit 2 ;;
esac
