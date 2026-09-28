# ci-janitor

Reclaims the disk that self-hosted CI leaks on this machine. Runs hourly as a launchd
agent. Each run measures the Docker disk's space **and inodes**, sweeps at a 7h floor
instead of 24h when either is at the high-water mark, and shouts when it can't keep up.

Sibling to [`runner-guard`](../runner-guard/README.md): that one keeps CI runners from
crash-looping, this one keeps the disk under them from filling.

## The problem it solves

Ephemeral GitHub Actions runners are ephemeral only in the runner container. Each runner
mounts the **host** Docker socket, so every service container a job starts — plus its
anonymous volume and per-job network — is created on the Colima VM's daemon, outside the
runner's lifecycle. The runner exits; its garbage stays.

`cancel-in-progress: true` (set on every HopefulTranslation workflow) makes this routine
rather than rare. Push again mid-run and GitHub kills the runner mid-job, so the job's
own cleanup step never executes and its containers are simply abandoned.

Nothing ever swept them. Measured 2026-08-15, before the first run:

| | |
|---|---|
| Orphaned anonymous volumes | 148, oldest 2026-06-23 (11.1 GB) |
| Untagged images | 14 (13.8 GB) |
| Orphaned Actions networks | 1 |
| Docker disk | 65 G used of 98 G — **70%** |

Two months of silent accumulation, surfacing as a CI failure with no obvious connection
to its cause: `tar: ./md5sums: Cannot open: No space left on device` during a Playwright
Chromium install. The first real run reclaimed **20 GB** and took the disk to 48%.

## Why it is safe: an allowlist, not a blocklist

This machine also runs a Supabase stack used for local Grounded development, ChromaDB,
actualbudget, five buildx builders, and three CI runner containers. None may be touched.

So each sweep matches a **positive signature that only CI garbage can structurally
have**, and anything unrecognized is kept. A blocklist ("delete everything except these")
fails *open* — whatever gets installed next year and isn't on the list gets deleted. An
allowlist fails *closed*.

That distinction is not academic here: `docker volume prune` reports the live, in-use
volume `supabase_edge_runtime_grounded` as dangling, so a blanket prune **would delete
it**. The 64-hex-name rule cannot match it, because Docker assigns 64-hex names only to
anonymous volumes — exactly what a CI service container creates.

| Sweep (order) | Positive signature | Why nothing of yours can match |
|---|---|---|
| 1. Actions networks + their containers | `github_network_<hex>`, aged | A namespace only the Actions runner creates |
| 2. Anonymous volumes | name is exactly 64 hex chars, dangling, aged | Docker never names a *named* volume that way |
| 3. Untagged images | `<none>:<none>`, aged | Tagged images are never touched, so nothing re-pulls |

Networks/containers run first so the volumes they pin become dangling in the same run
and high-water sees a true “every eligible object” reclaim.

**Deliberately not swept**, because the risk outweighs the space: tagged-but-unused
images (deleting them forces multi-GB re-pulls of Supabase versions Grounded pins),
stopped containers in general (runners use `--restart=always` and sit EXITED between
jobs — removing one during that window permanently kills that repo's CI), build cache
(208 MB, shared with the buildx builders), and `/runner-work` (2.2 GB, but an
actively-used repo's checkout never ages out anyway).

## How live jobs are protected

Not by polling for running jobs and not by a settle-sleep — both are races. The **age
floor is the guarantee**: below the high-water mark nothing younger than
`CI_JANITOR_AGE_HOURS` (default 24h) is touched, and under disk pressure (next section)
nothing younger than 7h is touched, in any sweep. Jobs on this host take 1–2 minutes and the platform ceiling
is 6 hours, so nothing the janitor can see could belong to a job still running.

The floor is enforced, not just documented: values below **7h** (platform ceiling + 1h
margin) are refused at startup. A free dial that accepted `1` would make sweep 1's
`docker rm -f` eligible to kill service containers still on an in-progress job.

## Disk pressure: inodes, not just bytes

On 2026-09-28 `/var/lib/docker` in the Colima VM ran out of **inodes** (6,553,600 of
6,553,600) while its space sat at 58%. Each orphaned CI volume can hold ~190k files (a
Python venv or `node_modules` per job). A 13-PR day left ~28 of them, most younger than
the 24h floor. `ht-runner` crash-looped 204 times on `No space left on device`, and the
janitor never noticed: it measured space only, once a day.

So every run now starts with a **pressure check**: one `df` inside the VM reads space
and inode use of `/var/lib/docker`. If either is at or above `CI_JANITOR_DISK_WARN_PCT`
(85%), that run sweeps at the 7h live-job floor instead of 24h, and the log names which
resource was short. Only the age moves. The three allowlist signatures above are the same
on every run, and 7h is still past the 6h job ceiling. The agent runs hourly, so the
same CI day that fills the disk also sweeps it.

## How you find out it broke

Silent accumulation is what caused the original problem, so the janitor is built to be
loud about its own failure. Every non-zero exit from a **run** both logs and raises a
desktop notification through the machine's one notifier (`../alerts`, shared with
runner-guard) (exit 64 is the deliberate exception — a mistyped flag at a
terminal, where stderr is already on screen). Two checks catch what a sweep-only
janitor would miss:

- **High-water check** — fires when space or inodes are *still* at the mark after the
  sweep, at the 7h floor if the run began over it. A full disk stays full across hourly
  runs, so it is a **held alert** (`ci-docker-disk-full` through `../alerts`), not a
  banner per run. It shows at the top of every Claude Code session and re-banners every
  6h, and the first run that measures the disk under the mark clears it. The alert names
  the resource and what is holding it: a sweep that did not finish, CI objects too young
  to sweep safely, or a source these sweeps don't cover.
- **Staleness check** — fires when the janitor itself hasn't run in over 72h. This is how
  you learn the launchd agent died, instead of reading its silence as health.

A successful run stays quiet in the notification channel (it always logs). Hourly
"cleaned up fine" alerts train you to ignore the channel that carries the alarms.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Ran clean — swept what was there, disk healthy |
| 2 | Could not run at all (Docker/Colima unreachable). **Not** "all clean" |
| 3 | Run did not fully succeed — removal/age failed, staleness clock unarmed, **or** Docker disk unmeasurable (notify names which) |
| 4 | Swept, but space or inodes are **still** at the high-water mark (at the 7h pressure floor when the run began over it). Held as the `ci-docker-disk-full` alert, naming the resource and what is holding it |
| 5 | Hadn't run for far longer than its schedule — it was silently dead (stale is also notified on exit 4 when both fire) |
| 64 | Usage error (unrecognized argument) — the one non-zero exit that deliberately does **not** notify: you can only reach it by mistyping the command at a terminal, where the stderr line is already in front of you |

This table mirrors the `EXIT CODES` block at the top of `ci-janitor.sh`; change both together.

## Usage

```bash
# Rehearse: prints exactly what it would delete, deletes nothing. Same exit 2/3 from
# classification failures; does not raise exit 4/5, arm the stamp, or shout stale recovery.
~/.config/ci-janitor/ci-janitor.sh --dry-run

# Real sweep.
~/.config/ci-janitor/ci-janitor.sh

# Behaviour tests: docker and colima are stubs, nothing real is touched.
~/.config/ci-janitor/test-ci-janitor.sh

# Install/reload the hourly agent (idempotent). Run './install' from the dotfiles
# root first so the ~/.config/ci-janitor symlink exists.
~/.config/ci-janitor/install.sh

# Watch it.
tail -f ~/.local/share/ci-janitor/janitor.log
launchctl print gui/$(id -u)/com.hhouse.ci-janitor | grep -iE 'state|program|runatload'

# Uninstall.
launchctl bootout gui/$(id -u)/com.hhouse.ci-janitor
```

## Tuning

All optional; the defaults are the tested ones.

| Variable | Default | What it controls |
|---|---|---|
| `CI_JANITOR_AGE_HOURS` | `24` | Normal age floor: below the high-water mark nothing younger is touched. At the mark the run sweeps at 7h instead, and nothing younger than 7h is ever touched. **Minimum 7** (refused below that) |
| `CI_JANITOR_DISK_WARN_PCT` | `85` | High-water mark for space and inodes: at or above it before a sweep, the run sweeps at 7h; still at it after, exit 4. **Integer 1–99** (refused outside) |
| `CI_JANITOR_STALE_HOURS` | `72` | How long silence means the agent died. **Positive integer** (refused otherwise) |
| `CI_JANITOR_LOG` | `~/.local/share/ci-janitor/janitor.log` | Log path |
| `CI_JANITOR_STATE` | `~/.local/share/ci-janitor/last-run` | Last run stamp (agent showed up — not “sweep was clean”) |
| `CI_JANITOR_DOCKER_DISK` | `/var/lib/docker` | Filesystem the pressure and high-water checks read |
| `CI_JANITOR_ALERTS` | `~/.config/alerts/alerts.sh` | The notifier alarms go through |

## The related fix

The janitor cleans up orphans. HopefulTranslation PR #211 stops one class of orphan from
mattering: the self-hosted Postgres service containers used to bind a hardcoded
`5432:5432`, so a single orphan blocked every subsequent job with
`Bind for 0.0.0.0:5432 failed: port is already allocated`. They now take an OS-assigned
port. Belt (janitor) and suspenders (ephemeral ports).
