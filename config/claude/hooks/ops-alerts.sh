#!/usr/bin/env bash
# ops-alerts.sh — SessionStart hook: put this machine's active ops alarms at the top of
# every Claude Code session, which is where this operator actually spends the day.
#
# The watchdogs (runner-guard, ci-janitor) run unattended under launchd. Their banners are
# events that vanish in seconds; on 2026-09-06 the whole self-hosted runner fleet sat
# circuit-broken for four days because the one banner fired at 2 a.m. This hook is the
# durable half of the notifier: it reads the conditions held by config/alerts and shows
# them to the human (systemMessage) and to the agent (additionalContext), every session,
# until they are cleared. No alerts → no output at all, so it never becomes wallpaper.
#
# Silence here must MEAN healthy, so the hook also checks that each watchdog is actually
# alive: a dead guard raises nothing, and an empty alert list from a dead guard is the
# silent-fallback trap in its purest form. A stale heartbeat is itself an alert.
# [LAW:no-silent-failure]
#
# Always exits 0: a hook failure must not block the session it is trying to inform. Any
# failure to read state is reported IN the output instead.
set -uo pipefail

ALERTS="${OPS_ALERTS_SH:-$HOME/.config/alerts/alerts.sh}"
PERIODIC="${OPS_ALERTS_PERIODIC:-$HOME/.config/periodic/periodic.sh}"
# The watchdogs whose silence this hook vouches for: "label heartbeat-path" per line. The
# heartbeat paths are the ones their launchd plists pass to periodic.sh.
WATCHDOGS="${OPS_ALERTS_WATCHDOGS:-runner-guard $HOME/.local/share/runner-guard/heartbeat
ci-janitor $HOME/.local/share/ci-janitor/heartbeat}"

lines=()
if out=$("$ALERTS" show 2>&1); then
  while IFS= read -r l; do [[ -n "$l" ]] && lines+=("$l"); done <<< "$out"
else
  lines+=("ops alerts UNREADABLE — $ALERTS show failed: ${out:-no output}")
fi

while read -r label hb; do
  [[ -z "$label" ]] && continue
  if ! st=$("$PERIODIC" --status --heartbeat "$hb" 2>&1); then
    lines+=("${label} agent NOT RUNNING — ${st:-heartbeat check failed}. Its alarms cannot fire while it is down. Check: launchctl print gui/$(id -u)/com.hhouse.${label}")
  fi
done <<< "$WATCHDOGS"

[[ ${#lines[@]} -eq 0 ]] && exit 0

text=$(printf '⚠ %s\n' "${lines[@]}")
if command -v jq >/dev/null 2>&1; then
  jq -n --arg t "$text" '{systemMessage: $t,
    hookSpecificOutput: {hookEventName: "SessionStart",
      additionalContext: ("OPS ALERTS on this machine (tell the user before other work; these are live outages):\n" + $t)}}'
else
  # Plain stdout still reaches the agent's context; say why the human banner is missing.
  printf 'OPS ALERTS on this machine (jq not found, so the user banner could not be built — tell the user):\n%s\n' "$text"
fi
exit 0
