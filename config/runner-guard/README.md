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

On a rogue runner it **heals**: it recreates the runner from the runner-fleet spec and
verifies the replacement actually registered and is listening for jobs. It used to refuse
to recreate anything — the per-project PAT/repo/labels were facts it did not own, and
guessing them would have been silent-wrong. That was never an argument against healing, only
against healing without a source of truth; `~/.config/runner-fleet/fleet.conf` is now that
source, so a recreate reads the spec instead of guessing at it.

Healing is bounded to **one attempt per runner per 6h** (`RUNNER_GUARD_HEAL_COOLDOWN`). A
recreate that does not address the cause — expired PAT, revoked repo access, a wedged VM —
would otherwise be retried every cycle, 720 registration attempts a day against GitHub, which
is a worse failure than the crash-loop it is curing. When a heal is unavailable, on cooldown,
or fails verification, the guard falls back to what it always did: **circuit-break** with
`docker update --restart=no` then `docker stop`, leaving the container **stopped, not
removed** (its logs survive) and shouting about it.

Measured end to end on 2026-09-04: a runner poisoned exactly the way the real outage poisoned
them was detected and back online in **two minutes**, unattended. Poisoned a second time
inside the cooldown, it was refused a recreate and circuit-broken instead — no retry loop.

The breaker **latches**: once stopped, the container's restart policy is `no`, so on
later cycles it's classified `parked` — logged so it stays visible, and a container
that's already stopped is never re-notified. A breaker trips once and stays open; it
does not re-alert every 2 minutes until you recreate the runner. The one exception is a
stop left *owed* by a partial heal (policy dropped but the stop failed): the parked
branch retries that stop each cycle and fires a single confirming alert on the cycle it
finally lands — then goes quiet.

Exit codes are a contract, each a distinct outcome: `0` nothing actionable (healthy,
watching, or parked) · `1` a rogue was found and handled — recreated
from the fleet spec and verified, or circuit-broken (in `CHECK_ONLY`: detected — advisory,
nothing touched) · `2` the guard itself couldn't run (Docker down — never
misreported as "all healthy") · `3` a rogue was found but the heal didn't land — it's
still live · `4` incomplete — a container couldn't be inspected this cycle, so the
assessment is partial and may be hiding a rogue (never conflated with the clean `0`).

## Use

```bash
# Read-only status check — classifies, never touches the fleet:
RUNNER_GUARD_CHECK_ONLY=1 ~/.config/runner-guard/runner-guard.sh

# Install as an always-on launchd agent (KeepAlive, cycling every 120s). Run dotbot first
# (./install from the dotfiles root) so the ~/.config link exists, then:
~/.config/runner-guard/install.sh
tail -f ~/.local/share/runner-guard/guard.log

# Uninstall:
launchctl bootout gui/$(id -u)/com.hhouse.runner-guard
```

A Claude `/loop` or a cloud routine can't do this job — the heal needs the Mac's local
Docker socket and must run with no session up. launchd is the right owner: same class
of local machine infra as the runners themselves.

## It has to actually be running

This agent was installed on 2026-07-25 and then ran **once**. For six weeks `launchctl print`
reported `runs = 1` while three runners crash-looped 3,203 times underneath it. Nothing lied;
nobody had ever established that "installed" implied "running", and a dead watchdog looks
exactly like a quiet one.

launchd's `StartInterval` does not fire on this machine — see `../periodic/README.md` for the
measurement. So the agent now runs as a long-lived process under `KeepAlive`, stamping a
heartbeat every cycle, and `install.sh` refuses to report success until that heartbeat has
advanced.

```bash
# Is the guard actually alive?  exit 0 = yes, exit 1 = it is not running
~/.config/periodic/periodic.sh --status --interval 120 \
  --heartbeat ~/.local/share/runner-guard/heartbeat
```

## Knobs (env vars, all optional)

| Var | Default | Meaning |
|---|---|---|
| `RUNNER_IMAGE_REPO` | `myoung34/github-runner` | which image marks a container as a runner |
| `RUNNER_GUARD_WINDOW` | `20` | seconds between the two health samples |
| `RUNNER_GUARD_CHECK_ONLY` | `0` | `1` = classify + report, never stop anything |
| `RUNNER_GUARD_LOG` | `~/.local/share/runner-guard/guard.log` | log file path |
| `RUNNER_FLEET_SCRIPT` | `~/.config/runner-fleet/runner-fleet.sh` | how a rogue gets recreated; if absent, the guard just circuit-breaks |
| `RUNNER_GUARD_HEAL_COOLDOWN` | `21600` (6h) | minimum seconds between recreate attempts for one runner |
| `RUNNER_GUARD_HEAL_STATE` | `~/.local/share/runner-guard/heals` | marker dir holding each runner's last heal attempt |
