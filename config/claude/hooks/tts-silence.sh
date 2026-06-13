#!/bin/bash
# Kill button: silence the CURRENT spoken reply immediately, without turning the
# feature off. The next reply still speaks. This is deliberately distinct from
# tts-toggle.sh (which disables TTS) so you never get stuck muted by accident.
#
# Stops, in one shot: the playback, the in-flight synthesis/summarizer calls, and
# the background worker that drives them.
pkill -f "tts-speak.sh"               2>/dev/null
pkill -f "afplay /tmp/claude-tts.mp3" 2>/dev/null
pkill -f "api.x.ai"                   2>/dev/null
exit 0
