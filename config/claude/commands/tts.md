---
description: Toggle on-demand text-to-speech for spoken responses (macOS `say`)
argument-hint: [on|off|status]
---

Run the TTS toggle script and report the result. The argument selects the action; with no argument it flips the current state.

Execute exactly this one command (an empty `$ARGUMENTS` makes the script default to `toggle`):

```
bash ~/.claude/hooks/tts-toggle.sh $ARGUMENTS
```

Then tell the user the new state in one short line, echoing the script's output. Do not read files, search, or take any other action.

User argument, if any: $ARGUMENTS
