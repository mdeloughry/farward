# Spec 003 — Supervised tunnels and auto-reconnect

Status: implemented
Scope: `farward` single-file CLI
Depends on: spec 002 (background session manager)

## 1. Goal

Today a managed tunnel is a bare `ssh` process. If ssh exits (wifi change,
laptop sleep, server restart, VPN flap) the tunnel stays dead until the user
notices and runs `farward restart`. SSH keepalives detect dead peers but cannot
re-establish forwards.

Introduce a detached supervisor per background session:

```
farward --supervise <session-dir>     # internal entrypoint
```

The supervisor owns the SSH child, restarts it with exponential backoff, and
publishes its state so `farward list` / `farward logs` / `farward stop` keep
working.

### Non-goals

- No change to foreground dashboard lifecycle in this version. `--retry` is a
  background-session feature; foreground runs print a note and continue.
- No external `autossh`/`systemd` dependency.
- No health checking of the remote target inside the supervisor. Reconnect is
  driven by the SSH process lifetime; channel-level failures are still surfaced
  by the existing startup probe and logs.
- No log rotation.

## 2. CLI

| Flag | Behaviour |
|---|---|
| `--retry N` | Reconnect up to `N` times after a drop. `0` disables. Default `3` for background sessions |
| `--retry-forever` | Never stop reconnecting (`N = -1`) |

- Values must be non-negative integers.
- The setting is stored in session state and reused by `farward restart`, even
  when the restart invocation does not repeat the flag.
- Explicit `--retry` on a foreground run prints:
  `Note: auto-reconnect applies to --background sessions; this run will not reconnect.`

## 3. Supervisor protocol

The supervisor is the farward script itself, detached with `nohup`:

```
<nohup> <farward> --supervise <session-dir>
```

This makes process identity trivial and robust: the command line contains
`--supervise` and the unique session directory. No environment markers or extra
SSH options are injected.

Loop:

```
attempt = 0, delay = 1s
forever:
  if any saved local port is still occupied:
      treat as a failed attempt (log the port)
  else:
      launch ssh with saved args/forwards, stderr appended to log
      record ssh_pid
      status = connecting / connected
      wait for ssh
      if the connection lasted >= 30s: attempt = 0
  clear ssh_pid
  if retries >= 0 and attempt >= retries:
      status = failed; exit 1        # state kept for farward logs/restart
  attempt += 1
  status = reconnecting, next_retry = now + delay
  sleep delay
  delay = min(delay * 2, 30)
```

- Backoff: 1, 2, 4, 8, 16, 30, 30, …
- A connection held for 30s resets the budget, so a stable tunnel that drops
  months later gets the full retry budget again.
- A local port occupied by another process counts as a failed attempt; after the
  budget is exhausted the session becomes `failed` instead of looping forever.
- If the session directory disappears (manual `rm -rf`), the supervisor kills its
  SSH child and exits within about a second, so it cannot become untracked.
- `--retry-forever` skips the budget check.

Signals: the supervisor traps `INT TERM HUP`, terminates its SSH child, writes
`state=stopped`, and exits. `SIGKILL` cannot be trapped; `stop` therefore keeps
the last `ssh_pid` in state and can terminate an orphaned ssh after the
supervisor is gone, but only after verifying its command line matches the saved
forward spec and host.

## 4. State additions

`meta` gains:

```
ssh_pid=<current ssh pid, empty between attempts>
retries=<configured budget, -1 = forever>
version=2
```

`status` (atomic write via `status.tmp` + `mv`, mode 0600):

```
state=connecting|connected|reconnecting|failed|stopped
attempt=<current retry number>
next_retry=<epoch or 0>
pid=<ssh pid or empty>
updated=<epoch>
```

`pid` in `meta` remains the **supervisor** pid. `started` is preserved across
restarts, so uptime is session age, not supervisor age.

## 5. Commands

- `farward list` maps state to STATUS:
  - supervisor alive + `connected` → `alive`
  - supervisor alive + `connecting` → `starting`
  - supervisor alive + `reconnecting` → `retry-<n>`
  - supervisor gone + `failed` → `failed`
  - otherwise → `stale`
- `farward stop` verifies and terminates the supervisor, then optionally a
  verified orphan ssh, then removes state.
- `farward restart` terminates supervisor + orphan ssh, waits for local ports,
  clears `status`, rewrites meta with the stored retry budget, launches a new
  supervisor, and re-runs the startup probe.
- `farward logs` works unchanged, now containing supervisor and ssh output.

## 6. Startup

The launcher no longer starts ssh directly. It:

1. creates state (`pid` empty, `retries`),
2. forks `--supervise`,
3. records the supervisor pid,
4. polls `status` for up to 10s until `connected` (or `failed`),
5. runs the existing per-forward local probe,
6. disowns the supervisor.

If startup fails, the EXIT trap terminates the supervisor and removes the
half-created session directory.

## 7. Tests

1. Background session state contains `retries=3`, `ssh_pid`, and
   `status state=connected`.
2. Kill the SSH child; within ~5s `list` returns to `alive` with a new
   `ssh_pid`, and the forwarded port works again.
3. `--retry 0`: kill SSH; session becomes `failed`, state is retained, `stop`
   cleans it.
4. `--retry 1`: exactly one replacement, then `failed`.
5. `--retry-forever`: two successive kills both recover.
6. `farward restart` replaces supervisor and SSH pids and stays alive.
7. `stop` terminates the supervisor and the SSH child.
8. Invalid retry values are rejected.
9. `SIGKILL` of the supervisor leaves an orphan SSH child that `stop` cleans up.
10. Deleting a session directory makes the supervisor terminate its SSH child.
11. Existing session-manager and tunnel tests pass unchanged.

## 8. Acceptance criteria

1. A managed tunnel survives a killed SSH process without user intervention.
2. Retry budgets are respected and visible as `retry-N` / `failed`.
3. `stop` never signals an unverified process.
4. `restart` works on `failed` sessions.
5. Bash 3.2 remains supported.
6. Foreground behaviour is unchanged apart from the documented note.
