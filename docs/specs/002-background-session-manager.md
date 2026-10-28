# Spec 002 — Background session manager

Status: implemented
Scope: `farward` single-file CLI
Depends on: none (works with the existing `--background` mode)
Extended by: spec 003 (supervised tunnels) — `meta` is now version 2 and `pid`
identifies the supervisor; `stop`/`restart` also terminate verified SSH children.

## 1. Goal

`--background` currently starts a tunnel and forgets it. The only teardown advice
is `pkill -f "ssh.*HOST"`, which kills unrelated SSH sessions to that host, and
there is no way to see, inspect, restart, or safely stop a running tunnel.

Add a small session registry so background tunnels become manageable objects:

```bash
farward list                 # what is running, on which host, for how long
farward logs <id> [-f]       # SSH stderr for that session
farward restart <id>         # stop and relaunch with the same forwards
farward stop <id>            # stop one session
farward stop --all           # stop everything farward started
```

Session IDs are accepted in full or as a unique prefix.

### Non-goals

- No daemon or supervisor loop (auto-reconnect remains a separate feature).
- No systemd/launchd integration.
- No encryption of state: it contains hosts, ports and PIDs, no secrets.
- Foreground dashboard sessions are not registered; they already own their
  terminal and exit cleanly on `:q`.

## 2. State layout

Root:

```
${FARWARD_STATE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/farward}
```

Created with mode `0700`; every session is one directory:

```
<root>/<id>/
  meta       key=value: id, pid, host, started (epoch), bind, version
  args       one ssh client argument per line (includes -F and keepalives)
  forwards   one argument per line: -L, <bind>:<local>:<target>:<remote>, ...
  log        SSH stderr, kept after exit for farward logs
```

Flat files, no `jq`, no arrays on disk, readable and writable from Bash 3.2.
`meta` and `args` are mode `0600`.

Session ID:

```
YYYYmmdd-HHMMSS-<shell pid>-<4 hex random>
```

Lexical order is chronological, which makes `list` ordering free.

## 3. PID safety

A PID alone is not enough to `kill -9` later. Before signalling, Farward checks:

1. `kill -0 <pid>` succeeds,
2. `ps -p <pid> -o command=` contains `ssh`,
3. the command line contains the session's first saved `-L` spec followed by
   the saved host (e.g. `-L localhost:8347:localhost:8347 mini`).

The forward spec is part of the tunnel identity: a recycled PID would have to be
an SSH process forwarding the same ports to the same host to pass. No extra
arguments or environment markers are injected, so password auth, `ssh_config`
options, and old OpenSSH versions behave exactly as before.

If any check fails the session is `stale`: it is listed, and `stop` cleans up
the state directory without touching the PID. This prevents killing an unrelated
process that inherited a recycled PID.

## 4. Commands

### `farward list`

```
ID                          HOST             UPTIME     STATUS  FORWARDS
20261027-143012-4412-a1b2   mini             1h 12m     alive   3
20261027-140005-4388-77ff   mini             3h 04m     stale   2
```

- `alive` = PID + marker verified.
- `stale` = state exists, process does not (or marker mismatch).
- `FORWARDS` = number of `-L` entries.
- No sessions: `No background sessions.` exit 0.

### `farward stop <id|--all>`

- Verifies the marker, sends `SIGTERM`, waits up to 3s, then `SIGKILL` if the
  verified process is still alive.
- Removes the state directory (including the log).
- Stale sessions: prints `was not running; cleaning up state` and removes the
  directory.
- Prefix matching: exactly one match required; zero or multiple matches fail
  with `No unique session matches '<input>'`.
- IDs are validated against `^[A-Za-z0-9._-]+$` and cannot be `.`/`..`, so a
  path traversal attempt can never be resolved.

### `farward logs <id> [-f|--follow]`

Prints the stored SSH stderr, or follows it with `tail -f`. Useful for
`ExitOnForwardFailure` / channel-open messages after the fact.

### `farward restart <id>`

1. Terminate the tunnel if alive (marker checked).
2. Re-read `args` and `forwards` from state.
3. Wait up to 2s for each local port to become free; fail if still occupied.
4. Append a `--- restarted <date> ---` marker to the log.
5. Relaunch with the same SSH options, forwards, host and session ID.
6. Re-run the existing local probe for every forward.
7. Rewrite `pid` and `started`.

Restart works on stale sessions too (e.g. after a reboot), which is the main
recovery path.

## 5. Background output

Replaces the `pkill` advice:

```
Tunnel started in the background.
Session: 20261027-143012-4412-a1b2
Host: mini
  localhost:8347 → mini:8347

Manage it with:
  farward list
  farward logs 20261027-143012-4412-a1b2
  farward restart 20261027-143012-4412-a1b2
  farward stop 20261027-143012-4412-a1b2
```

## 6. Adjacent fixes included

- `-o/--open` now works with `--background`; previously the background branch
  exited before the open loop.
- The session log is persistent, so post-mortem channel errors are available.
- Failed startup removes its half-created state directory via the EXIT trap.
- Foreground behaviour is unchanged; its log stays a temporary file.

## 7. Failure handling

| Situation | Behaviour |
|---|---|
| State directory cannot be created | Fail before starting SSH |
| SSH dies during startup | Existing error message, pending session dir removed |
| Probe fails | Existing error message, pending session dir removed |
| `stop` on unknown/stale id | Fail or clean stale state, never signal unverified PID |
| `restart` port still occupied | Fail and leave state for a later retry |
| `logs` with no log file | Fail with a clear message |

## 8. Tests

Add to `tests/smoke.sh` with `FARWARD_STATE_DIR` pointed inside `SMOKE_DIR`:

1. Background start prints a parseable `Session:` line and creates state.
2. `list` shows id, host, `alive`, and the forward count.
3. `logs` prints an appended marker line.
4. `restart` gets a new PID, stays `alive`, and keeps the same id.
5. Prefix matching stops a session.
6. `stop <id>` kills the tunnel and removes state.
7. `stop --all` clears multiple sessions and `list` then reports none.
8. A hand-written stale session is listed as `stale` and cleaned by `stop`.
9. A session whose PID belongs to an unmarked process (e.g. `sleep`) is **not**
   killed by `stop`; the process survives.
10. Path-traversal id (`../x`) is rejected.

## 9. Acceptance criteria

1. No code path suggests `pkill` for cleanup.
2. Every background tunnel can be listed, logged, restarted and stopped by ID.
3. Stopping a session never signals a PID whose command line lacks the session
   marker.
4. State survives across shell invocations and is cleaned up on stop.
5. Bash 3.2 remains supported (no `mapfile`, no associative arrays).
6. Existing smoke checks pass unchanged.
