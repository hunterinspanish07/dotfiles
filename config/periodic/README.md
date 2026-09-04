# periodic — the scheduling primitive the launchd agents run under

`periodic.sh` runs a command on an interval, forever, as a process launchd keeps alive.
Both machine agents use it: `com.hhouse.runner-guard` and `com.hhouse.ci-janitor`.

## Why this exists

**launchd's `StartInterval` does not fire on this machine.** That is not a guess:

| agent | schedule | should have run | actually ran |
|---|---|---|---|
| `com.hhouse.runner-guard` | `StartInterval 120` | ~30,000× since 2026-07-25 | **once**, on install day |
| `com.hhouse.ci-janitor` | `StartInterval 86400` | 17× since 2026-08-18 | **once**, on install day |

Both showed `runs = 1` with a permanently `pended nondemand spawn`. A controlled A/B probe
on 2026-09-04 settled the cause: a throwaway agent with `StartInterval 10` sat at `runs = 0`
for three minutes without firing once, while an otherwise identical agent with `KeepAlive`
ran continuously and ticked every 10s. launchd in this `gui/501` domain honours a *demand*
spawn (`launchctl kickstart`) and never executes the pended *nondemand* spawns an interval
needs.

The cost was not theoretical. runner-guard exists to catch crash-looping CI runners; while
it sat dead, three runners crash-looped 3,203 times and delivered zero CI for six weeks.
ci-janitor exists to reclaim the disk self-hosted CI leaks; while it sat dead, the leak it
sweeps is the one that previously drove this host to ENOSPC.

So an agent no longer asks launchd to start it 720 times a day. It asks launchd to start it
**once** and keep it alive — the job launchd actually does — and `periodic.sh` owns the clock
from there.

## The heartbeat

The failure was never that the timer died. It was that **a dead timer looks exactly like a
quiet one.** Nothing on this machine could distinguish "no crash-looping runners today" from
"no runner-guard today", and for six weeks nobody could tell.

So every cycle stamps a heartbeat file, unconditionally — whatever the supervised job did.
Liveness becomes a timestamped fact on disk instead of an assumption. The job's own exit code
rides along as data in the same line, so a persistently failing job never reads as a dead
agent and a dead agent never hides behind a succeeding one.

```bash
# Is an agent actually alive?  exit 0 = fresh, exit 1 = stale (it is not running)
~/.config/periodic/periodic.sh --status --interval 120 \
  --heartbeat ~/.local/share/runner-guard/heartbeat
```

`install-agent.sh` uses the same signal, which is the point: it captures the heartbeat, boots
the agent, and **refuses to report success until that heartbeat has advanced.** "Installed"
now implies "observed running" — exactly what it did not imply the last two times.

## A hung cycle

`KeepAlive` guarantees a process exists. It cannot tell you that process is doing anything —
a cycle wedged on an unresponsive Docker socket leaves launchd perfectly satisfied while
nothing happens and the heartbeat quietly stops. So each cycle has an explicit deadline
(`--timeout`, default = the interval); an overrun is killed, reaped, and recorded as
`exit=timeout`.

## Use

```
periodic.sh --label L --interval SECS --heartbeat PATH [--timeout SECS] -- COMMAND [ARG...]
periodic.sh --status --heartbeat PATH --interval SECS

install-agent.sh <plist> [required-binary...]     # load an agent and prove it runs
```

`install-agent.sh` reads the label, supervisor, interval, heartbeat, supervised command and
`PATH` **out of the plist** — the authority launchd itself obeys — so there is no second copy
to drift. runner-guard and ci-janitor are two instances of it, differing only in which plist
and which binaries must be present.

Exit codes — `periodic.sh`: `0` fresh (`--status`) · `1` stale (`--status`) · `2` bad
invocation or missing command. `install-agent.sh`: `0` loaded **and** verified running · `1`
precondition failed or launchd refused · `3` loaded but no cycle completed in the window —
*not* success, because unverified is not the same as working.

## Tests

```bash
./test-periodic.sh      # 15 behaviour tests; asserts the contract, not the implementation
```

They cover the bug that started this: that cycles keep happening. Also that a failing job is
reported as a failing job rather than a dead agent, that a hung cycle cannot stall the loop,
and that the staleness check tells the truth in both directions.
