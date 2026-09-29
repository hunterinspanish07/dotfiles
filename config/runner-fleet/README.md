# runner-fleet — the single spec for this host's self-hosted CI runners

`fleet.conf` says what runners this machine has. `runner-fleet.sh` makes the machine match it.

## Why this exists

Until 2026-09-04, **no code created a runner.** Each one existed only as a `docker run`
snippet pasted into its project's `docs/CI-RUNNERS.md`. Nothing executed those snippets, so
nothing kept them true — and when all three runners died at once, the recovery procedure was
itself wrong in three different ways: the pinned digest had been replaced, `ht-runner` had
gained a per-runner work directory bind that no doc recorded, and two of the three PAT files
named in the docs had been deleted after setup, so the only surviving copy of those
credentials was inside the containers that recovery was about to delete.

Six maps of one territory, no way to tell which was lying. Now there is one map, and the
script redraws the territory from it.

## Use

```bash
runner-fleet.sh status                  # classify every runner
runner-fleet.sh up [--force] [NAME...]  # restore to the spec from the local image (default: all)
runner-fleet.sh refresh [NAME...]       # pull IMAGE, then replace every selected runner
runner-fleet.sh plan [NAME...]          # print the docker run it would issue (no secrets)
runner-fleet.sh adopt [NAME...]         # recover a live container's PAT into its pat-file
```

`up` replaces a runner that is **absent**, **looping** or **parked**. It leaves **healthy**
alone, and also leaves **settling** alone — that state means "unhealthy at one end of the
sampling window only, no verdict yet", and tearing a runner down on an unconfirmed signal
would discard the whole point of measuring twice. `--force` replaces regardless.

### Restore versus refresh

Getting a runner back and upgrading it are two different jobs, and they have two commands:

- **`up` restores.** It recreates from the copy of `IMAGE` already on this host and never
  contacts a registry (containers are created with `--pull=never`). It works with Colima's
  DNS down or `/var/lib/docker` full. runner-guard's heal runs `up --force <name>`. If the
  image isn't on the host, `up` stops with exit 2, naming the image and telling you to run
  `refresh`.
- **`refresh` upgrades.** It pulls `IMAGE` from the registry, then replaces every selected
  runner, healthy or not, so they all run the new build. It is the only command that pulls.

They used to be one command, and every restore pulled first. Both recorded heals died at
that pull while the image was sitting on the host: on 2026-09-06/07 Colima's DNS couldn't
resolve the registry, and CI was down four days; on 2026-09-28 `/var/lib/docker` was out of
inodes. See `docs/adr/0001-ci-runner-resilience.md`, decision 3.

Exit codes: `0` in the desired state · `1` at least one runner could not be brought up
(verified, not assumed) · `2` the script could not run (Docker unreachable, spec invalid,
PAT missing, image not on the host for `up`, pull failed for `refresh`) · `3` `status` only:
something is absent or broken.

## What `up` guarantees

A create is **not** done when `docker run` returns an id. `up` waits until the runner's
own log says it is listening, and fails closed naming what it looked for. A
`Conflict. Retrying until reconnected.` line is not that failure — it is a killed runner's
session still held by GitHub, and `up` keeps waiting for that session to expire. If it
never does, the error names the stale session, not the token. A runner that never logs
the retry still fails on the ordinary settle, so a bad token is not made slower. `up`
also refuses any runner that restarts inside the window.

## Adding a runner

Add a row. Four fields, no code change:

```
runner <container>  <owner/repo>  <runner-name>  <pat-file>
```

The work directory is **not** a field — it is derived as `/runner-work/<container minus its
-runner suffix>`. Two runners sharing one work directory is a bug that already bit this host
(odyssey and grounded both bound the same path, so each restart wiped the other's in-flight
`_actions` cache and jobs failed in ~23s at `actions/checkout`). Deriving it makes that
collision unrepresentable rather than merely discouraged.

The PAT file holds only a fine-grained token for that one repo with **Administration: Read &
write**, mode 600, never committed. It is read at create time and passed to docker; nothing
else touches it, and `plan` never renders it.

## Auto-update is off, deliberately

Runners are created with `DISABLE_AUTO_UPDATE=true`, so `IMAGE` in `fleet.conf` is the only
thing that moves the runner version. Take a new version with `runner-fleet.sh refresh`.

Left to itself the runner self-updates *in place*: it renames `/actions-runner/bin` to
`bin.<version>`, unpacks the new release, and swaps it back. Interrupted, that leaves **no
`bin` at all** — `./bin/Runner.Listener` exits 127 forever, and because the wreckage lives in
the container's writable layer, no restart can ever heal it. That is precisely how all three
runners on this host died on 2026-09-04 (817, 1974 and 3741 restarts), each holding
`bin.2.336.0` and `bin.2.337.0` with `bin` deleted. The image was innocent; a fresh container
from the same digest had an intact `bin`.

A container that patches itself is a second, unversioned source of truth about what is
installed. The image is the first. Keep one.

## Relationship to runner-guard

`runner-guard` watches for crash-looping runners. It used to only stop them, because it owned
none of the facts a recreate needs and guessing would have been silent-wrong. `fleet.conf` is
now that source of truth, so the guard calls `up --force <name>` — a restore from the local
image, never a pull — and verifies the result,
bounded to one attempt per runner per 6h, so a bad credential can never become a retry loop.
Measured end to end: a runner poisoned the way the real outage poisoned them was detected and
back online in **two minutes**, unattended.
