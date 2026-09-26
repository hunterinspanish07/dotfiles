# alerts — the one notifier for this machine's unattended agents

runner-guard and ci-janitor run under launchd with nobody watching. Every alarm they raise
goes through `alerts.sh`, so there is one place that decides how an operator hears about
trouble. Before this, each agent carried its own copy of the same `osascript` line.

## Two kinds of alarm

A desktop banner is an **event**: it shows for a few seconds and is gone. That is right for
"a runner was healed" and wrong for "the runner fleet is down" — on 2026-09-06 the fleet was
circuit-broken overnight, the banners fired into an empty room, and the outage ran four days.
So there are two kinds:

| Command | Kind | What happens |
|---|---|---|
| `alerts.sh notify TITLE MESSAGE` | event | one desktop banner |
| `alerts.sh raise ID TITLE MESSAGE` | condition | held under `~/.local/share/alerts/active/ID/` until cleared; banner on first raise and again every 6h |
| `alerts.sh clear ID` | condition over | removed |
| `alerts.sh show` | — | one line per active condition, with when it started |

The caller owns the truth of a condition: it recomputes it every cycle and calls `raise` or
`clear`. Re-raising refreshes the message but keeps the original start time.

## Where a condition shows up

`config/claude/hooks/ops-alerts.sh` is a SessionStart hook that prints every active condition
at the top of each new Claude Code session — to you (`systemMessage`) and to the agent
(`additionalContext`) — and prints nothing when there are none. It also checks each
watchdog's heartbeat, because an empty list from a dead watchdog is not health: a stale or
missing heartbeat shows up as its own alert.

## Test

```bash
./test-alerts.sh                       # notifier + session hook
../runner-guard/test-runner-guard.sh   # the guard raises/clears the fleet-down condition
```

| Var | Default | Meaning |
|---|---|---|
| `ALERTS_DIR` | `~/.local/share/alerts` | where active conditions are held |
| `ALERTS_REMIND_SECS` | `21600` (6h) | how often a still-active condition re-banners |
