# ADR 0001 — CI runner resilience: extend runner-guard, adopt no new platform

- Status: accepted
- Date: 2026-09-28
- Ticket: dotfiles-ci-runners-h9j.1 (epic dotfiles-ci-runners-h9j)

## Context

Every self-hosted GitHub Actions runner on this Mac is a `myoung34/github-runner`
container on one shared Colima VM, declared in `config/runner-fleet/fleet.conf` and
created by `runner-fleet.sh`. `runner-guard` checks them every 120s under `periodic.sh`.
Alarms go through `config/alerts/alerts.sh`. The `ops-alerts` SessionStart hook shows
active alarms, and stale watchdog heartbeats, at the top of every Claude Code session.

The goal: a dead, deaf or zombie runner never goes unnoticed. It recovers by itself, or
recovery is one obvious command. Checked against that goal, each failure mode seen so
far stands like this today:

| Mode | Seen | Detected today? | Recovered today? |
|---|---|---|---|
| Crash loop (exit ≠ 0, restarting) | 2026-09-04: self-update wreck on all three runners (817, 1,974 and 3,741 restarts) | Yes. The guard's two-sample check marks it rogue within one cycle | Yes when the cause is the container. The guard recreates from the fleet spec, once per 6h |
| Crash loop while the disk is full | 2026-09-28: inode exhaustion, ht-runner exit 134 | Yes. ROGUE at 09:25 and `runner-fleet-down` raised | **No.** The heal runs `docker pull` to resolve a digest, and the pull needs the disk that had run out. The fallback park failed on ENOSPC too, so restart policy stayed `always`. A human ran `runner-fleet.sh up` |
| Parked runner (the circuit breaker latched) | 2026-09-06/07: all three runners crash-looped (exit 1). Each heal's `docker pull` failed because Colima's DNS could not resolve the Docker registry, so the guard parked them. They stayed down four days | Yes, since 2026-09-26: `runner-fleet-down` is held and shown at every session start | **No.** The park latches (`restart=no`) and only a human `up` clears it |
| Online but deaf (container running, not polling GitHub) | 2026-07-25: odyssey-runner lost DNS to the broker; ~10 queued runs went stale | **No.** The guard treats `status == running` as healthy | No |
| Docker unreachable (VM wedged or stopped) | Colima wedge, all runners down at once | **No alarm.** The guard exits 2, `periodic.sh` records `exit=2` in the heartbeat, and the session hook checks only whether the heartbeat is fresh, not its exit code | No, and it should not be automatic: `colima restart` kills every container on the VM (Grounded's Supabase, buildx builders, all runners) |

Disk and inode pressure, the cause behind the second row, is prevented separately in
ci-janitor (ticket dotfiles-ci-janitor-1ts). It is not part of this decision.

## Decision

Keep the current stack (fleet spec + runner-guard + alerts + periodic) and close the
gaps above inside it:

1. **Docker unreachable is an alarm.** A cycle that cannot reach Docker raises a held
   condition through `alerts.sh`. The message names the diagnosis (`colima status`) and
   the fix, including the blast radius of `colima restart`. A cycle that reaches Docker
   clears it. The VM is never restarted automatically.
2. **Deafness is judged by GitHub's view, not the container's.** A runner whose
   container is running while GitHub has reported it offline or missing for a sustained
   window is deaf. It goes through the same bounded heal as a crash loop. The GitHub
   check reads each runner's own PAT, so it belongs in `runner-fleet.sh`, which already
   owns those credentials. The guard consumes the verdict and never reads a PAT.
   Ephemeral runners drop off GitHub briefly between jobs, so one sample is never a
   verdict. If the GitHub API itself is unreachable, the cycle is incomplete, not every
   runner deaf.
3. **A heal restores; it does not upgrade.** A heal recreates the runner from the
   runner image already on the host and needs no registry or free disk for a pull.
   Pulling a new image stays an explicit refresh by an operator. (As built: `up`,
   forced or not, restores and never pulls, and the new `runner-fleet.sh refresh`
   is the only command that pulls. Manual recovery through `up` then works without
   the registry too.)
   Restoring and upgrading are different intents and today share one code path. That
   path failed at the pull in both recorded heal attempts: on 2026-09-06/07 the
   registry lookup failed, and on 2026-09-28 the disk was full. Both times the image
   the failing container ran was still on the host, since a container keeps its image
   from being removed.
4. **The breaker gets a half-open state.** A runner the guard itself parked gets a
   bounded automatic trial recreate on a backoff. It returns by itself once the cause
   clears (disk freed, DNS back, token fixed). A runner stopped by an operator is never
   touched. The trial count per period stays bounded, so a permanent cause, such as a
   revoked PAT, cannot become a registration loop against GitHub. This is the standard
   circuit-breaker pattern (closed → open → half-open). The current guard stops at
   open.

The fleet can stay small, and every piece is already shell under `periodic.sh` with a
heartbeat that the session hook watches. Adding a platform would add moving parts
without covering a mode that these four changes miss.

## Alternatives rejected

- **actions-runner-controller (ARC).** GitHub's standard supervisor, but it runs on
  Kubernetes. On this Mac that means k3s inside Colima: a second orchestration layer
  over a few runners, replacing fleet.conf, the guard and their tests. ARC also cannot
  see a wedged VM, because it would be inside it.
- **Docker HEALTHCHECK + `willfarrell/autoheal`.** Autoheal restarts containers that
  fail their healthcheck. From inside the container, a healthcheck cannot know GitHub's
  view without a PAT or brittle log and DNS probing. A restart does not fix
  writable-layer damage (that needs a recreate), and autoheal has no circuit breaker,
  so a permanent cause restarts forever. It would also need the Docker socket, and it
  dies with the VM it is supposed to watch.
- **Just-in-time (JIT) runner registration.** It changes how a runner registers, not
  whether a dead one is noticed. The ephemeral runners already take one job per
  registration.
- **External dead-man's switch (healthchecks.io-style).** It would reach the operator
  even with the Mac off. Today the guard's heartbeat is already checked at every
  session start, and held alarms re-banner every 6h. Adding it means an account, a
  secret and a network dependency for a small gain. Revisit if an outage goes unnoticed
  despite the session banner.
- **Colima autostart (`brew services start colima`).** It is the standard way to bring
  the VM up at login. It is deferred: its KeepAlive would have to coexist with a
  manually started Colima, and testing it means stopping the whole VM. With decision 1
  in place, a Colima that is down after a reboot is announced with its one-line fix.
  Revisit if reboot outages recur.
- **Retire runner-guard.** Nothing standard covers what it does for this fleet shape:
  its two-sample crash-loop verdict, its bounded heal from the declared spec, and its
  held alarms. It stays and grows.

## Consequences

- `runner-fleet.sh` becomes the only component that talks to the GitHub API about
  runners, as it is already the only one that reads PATs.
- An operator who wants a runner down for good must remove it (`docker rm`), or stop it
  in a way the guard can tell apart from its own park. A guard-parked runner will be
  retried.
- The build work is filed as ranked issues under epic dotfiles-ci-runners-h9j.
