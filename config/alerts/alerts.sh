#!/usr/bin/env bash
# alerts.sh — the one notifier for this machine's unattended agents (runner-guard,
# ci-janitor). Every alarm they raise goes through here, so there is one place that
# decides how an operator hears about trouble. [LAW:one-source-of-truth]
#
# WHY THIS EXISTS
# Both agents used to carry their own copy of the same `osascript display notification`
# line, and a desktop banner is an EVENT: it shows for a few seconds and is gone. On
# 2026-09-06/07 runner-guard circuit-broke all three runners at 18:42, 02:17 and 04:30 —
# its banners fired into an empty room — and then logged `parked:` every 120s for four
# days. The guard did its job; the operator was never told. A condition that persists has
# to be represented as something that persists, so this notifier has two kinds of alarm:
#
#   notify   an EVENT — something happened once (a runner healed, a sweep failed). Banner.
#   raise    a CONDITION — something is wrong NOW and stays wrong until cleared (the fleet
#            is down). Held as an active alert that `show` reports to every new Claude
#            Code session, where this operator actually works, and re-bannered on a
#            reminder interval so it is not a one-shot either.
#   clear    the condition is over.
#   show     print the active alerts (for the SessionStart hook; exit 0 either way).
# [LAW:types-are-the-program]
#
# The caller owns the TRUTH of a condition — it recomputes it every cycle and calls raise
# or clear accordingly. This file owns only how that truth reaches a person.
#
# EXIT CODES
#   0  done
#   1  the alert could not be recorded (unwritable ALERTS_DIR) — the caller must treat the
#      alarm as NOT delivered
#   64 usage error
set -euo pipefail

ALERTS_DIR="${ALERTS_DIR:-$HOME/.local/share/alerts}"
ACTIVE="$ALERTS_DIR/active"
# How often a still-active condition re-banners. The session banner is the durable channel;
# this only keeps the desktop from going quiet on a problem that is still there.
REMIND_SECS="${ALERTS_REMIND_SECS:-21600}"   # 6h

usage() {
  cat >&2 <<'USAGE'
usage:
  alerts.sh notify TITLE MESSAGE     # one-shot desktop banner
  alerts.sh raise  ID TITLE MESSAGE  # hold an active alert (banner on raise + every reminder)
  alerts.sh clear  ID                # the condition is over
  alerts.sh show                     # print active alerts, one block each
USAGE
  exit 64
}

# The banner is best-effort: a failed osascript must never cost the caller its alert, so
# it reports on stderr and returns 0. [LAW:effects-at-boundaries]
banner() {
  local title="$1" msg="$2"
  osascript -e "display notification \"${msg//\"/\'}\" with title \"${title//\"/\'}\"" >/dev/null 2>&1 \
    || echo "alerts: desktop banner failed (osascript) — ${title}: ${msg}" >&2
}

# An ID becomes a directory name; anything that could escape $ACTIVE is refused.
valid_id() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != .* ]] || { echo "alerts: invalid id '$1'" >&2; exit 64; }; }

cmd_raise() {
  local id="$1" title="$2" msg="$3" dir now last
  valid_id "$id"
  dir="$ACTIVE/$id"; now=$(date +%s)
  mkdir -p "$dir" || { echo "alerts: cannot create $dir — alert '$id' NOT recorded" >&2; exit 1; }
  # `since` is written once, on the first raise; re-raises refresh the message (the set of
  # affected things can change) but never move the start of the outage.
  [[ -f "$dir/since" ]] || printf '%s\n' "$now" > "$dir/since" || exit 1
  printf '%s\n' "$title" > "$dir/title" || exit 1
  printf '%s\n' "$msg" > "$dir/message" || exit 1
  last=$(cat "$dir/bannered" 2>/dev/null || echo 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last >= REMIND_SECS )); then
    banner "$title" "$msg"
    printf '%s\n' "$now" > "$dir/bannered" || exit 1
  fi
}

cmd_clear() {
  valid_id "$1"
  rm -rf "${ACTIVE:?}/$1"
}

cmd_show() {
  local dir since
  [[ -d "$ACTIVE" ]] || return 0
  for dir in "$ACTIVE"/*/; do
    [[ -f "$dir/message" ]] || continue
    since=$(cat "$dir/since" 2>/dev/null || echo "")
    [[ "$since" =~ ^[0-9]+$ ]] && since=$(date -r "$since" '+%Y-%m-%d %H:%M') || since="unknown"
    printf '%s (since %s): %s\n' "$(cat "$dir/title")" "$since" "$(cat "$dir/message")"
  done
}

case "${1:-}" in
  notify) [[ $# -eq 3 ]] || usage; banner "$2" "$3" ;;
  raise)  [[ $# -eq 4 ]] || usage; cmd_raise "$2" "$3" "$4" ;;
  clear)  [[ $# -eq 2 ]] || usage; cmd_clear "$2" ;;
  show)   [[ $# -eq 1 ]] || usage; cmd_show ;;
  *) usage ;;
esac
