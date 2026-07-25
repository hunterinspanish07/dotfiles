# runner-guard — circuit breaker for crash-looping self-hosted CI runners

Machine-wide. Guards **every** self-hosted GitHub Actions runner container on this
host (Odyssey, Grounded, HopefulTranslation, …), matched by image
(`myoung34/github-runner`) — not by project. That's why it lives here, in the machine
config repo, and not in any one app's repo.

## The problem it solves

Ephemeral runners **must** run with `--restart=always`: they exit 0 after every job
and rely on the restart to re-register for the next one. That policy is correct and
structurally blind — Docker can't tell "restarting to re-register after a clean job"
(exit 0) from "crash-looping on a broken image / dead PAT / OOM" (exit ≠ 0). A rogue
runner then loops forever: it delivers **zero** CI while pinning a core of the shared
Colima VM, and `docker ps` still looks fine. This actually happened — `ht-runner` sat
at 2400+ restarts on exit 127 (missing runner binary), silently starving the healthy
runners on the shared VM.

## How it decides

A runner is **rogue** iff it stays unhealthy — **last exit ≠ 0 AND not running** —
across a sampling window (default 20s, sampled at both ends). That's *persistence*,
not restart velocity: Docker's exponential backoff throttles a long crash-loop's
restart rate toward zero, so a rate signal would miss exactly the worst cases. Healthy
exit-0 cycling can never trip it.

On a rogue runner it **circuit-breaks**: `docker update --restart=no` then
`docker stop`, leaving the container **stopped, not removed** (its logs survive). It
does **not** recreate the container — the per-project PAT/repo/labels live in each
project's own `docs/CI-RUNNERS.md`, and guessing them would be silent-wrong. Fix the
root cause, then recreate from that project's Setup block.

The breaker **latches**: once stopped, the container's restart policy is `no`, so on
later cycles it's classified `parked` — logged (so it stays visible) but never
re-healed or re-notified. A breaker trips once and stays open; it does not re-alert
every 2 minutes until you recreate the runner.

Exit codes are a contract: `0` all healthy · `1` a rogue was found+stopped · `2` the
guard itself couldn't run (Docker down — never misreported as "all healthy").

## Use

```bash
# Read-only status check — classifies, never touches the fleet:
RUNNER_GUARD_CHECK_ONLY=1 ~/.config/runner-guard/runner-guard.sh

# Install as an always-on launchd agent (RunAtLoad + every 120s). Run dotbot first
# (./install from the dotfiles root) so the ~/.config link exists, then:
~/.config/runner-guard/install.sh
tail -f ~/.local/share/runner-guard/guard.log

# Uninstall:
launchctl bootout gui/$(id -u)/com.hhouse.runner-guard
```

A Claude `/loop` or a cloud routine can't do this job — the heal needs the Mac's local
Docker socket and must run with no session up. launchd is the right owner: same class
of local machine infra as the runners themselves.

## Knobs (env vars, all optional)

| Var | Default | Meaning |
|---|---|---|
| `RUNNER_IMAGE_REPO` | `myoung34/github-runner` | which image marks a container as a runner |
| `RUNNER_GUARD_WINDOW` | `20` | seconds between the two health samples |
| `RUNNER_GUARD_CHECK_ONLY` | `0` | `1` = classify + report, never stop anything |
| `RUNNER_GUARD_LOG` | `~/.local/share/runner-guard/guard.log` | log file path |
