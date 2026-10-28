# Farward

[![CI](https://github.com/mdeloughry/farward/actions/workflows/ci.yml/badge.svg)](https://github.com/mdeloughry/farward/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/mdeloughry/farward)](https://github.com/mdeloughry/farward/releases/latest)

Farward — forwarding from afar — is an interactive SSH port-forwarding dashboard for remote services. It can discover published Docker ports, forward ordinary standalone processes, or combine both in one session.

## Features

- Discovers published Docker/Compose TCP ports with `docker ps`.
- Scans every listening TCP port on the remote host with `--scan`, including
  non-Docker services and their process names.
- Adds arbitrary remote TCP ports for non-Docker applications.
- Selects multiple services with `fzf`.
- Supports direct `REMOTE` and `REMOTE:LOCAL` port specifications.
- Binds local forwards explicitly to `localhost` by default.
- Supports an optional `FARWARD_SSH_CONFIG` for custom SSH identities, ports, and host aliases.
- Supports a remote-side target host when the service is not reachable at remote `localhost`.
- Preserves specific Docker bind addresses such as `10.0.0.5:8080->80/tcp` when creating forwards.
- Can diagnose whether the SSH host can reach the requested remote target before tunneling.
- Can print the resolved SSH forwards without opening a tunnel.
- Probes started forwards and reports SSH channel-open failures before showing the dashboard.
- Prompts when a local port is privileged, invalid, or already occupied.
- Shows all active forwards in a responsive full-screen dashboard.
- Registers background tunnels so they can be listed, inspected, restarted, and
  stopped safely by session id.
- Keeps background tunnels alive with a supervisor and bounded or unlimited
  automatic reconnect after a dropped SSH process.
- Type `:q` and press Enter (or type `q` and press Enter), or press Ctrl+C, to close every tunnel in the session.
- Retains the legacy `dockport` and `sail-ports` commands as aliases.

## Port range

TCP ports must be between `1` and `65535`. A value such as `83473` is not a valid network port. Use the actual listening port, for example `8347`, `8343`, or another value reported by the application.

## Install or update

```bash
./install.sh
```

This installs:

```text
~/.local/bin/farward
~/.local/bin/dockport -> farward
~/.local/bin/sail-ports -> farward
```

### From a release

Download the tarball for the latest tag from the
[releases page](https://github.com/mdeloughry/farward/releases/latest), extract
it, and run `./install.sh` from the extracted directory.

### Releasing

CI runs the smoke test on Linux (bash 5) and macOS (bash 3.2) for every push
and pull request. A `v*` tag also checks that the tag matches `FARWARD_VERSION`
in `farward`, reruns the smoke test, and publishes the script, installer,
tarball, and `SHA256SUMS` as a GitHub release.

To cut a release:

```bash
# bump FARWARD_VERSION in farward first
git commit -am "chore: release vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```

## Help and safe default

Running Farward without arguments shows the help screen and does not attempt an SSH connection:

```bash
farward
```

## Verify locally

Run the smoke test before installing:

```bash
tests/smoke.sh
```

Run the same test against the installed command:

```bash
FARWARD_BIN=~/.local/bin/farward tests/smoke.sh
```

After installation, you can also run:

```bash
farward --self-test
```

The smoke test uses a mock SSH process and temporary local ports to verify background forwarding, byte-level custom-port traffic, remote-side failure reporting, session management, supervisor reconnect budgets, orphan cleanup, the foreground dashboard animation, and `:q` cleanup. When `sshd` and `ssh-keygen` are available, it also starts a temporary local SSH server and verifies a real OpenSSH custom-port tunnel end to end, including restart and stop.

These are equivalent:

```bash
farward help
farward --help
farward -h
```

## Orca worktrees

Orca runs `scripts/setup-worktree.sh` automatically for each new worktree. The
hook is declared in `orca.yaml` at the repo root, so it is shared with everyone
who opens the repository in Orca. Orca may ask you to trust the hook once.
Commit both `orca.yaml` and `scripts/setup-worktree.sh`: a new worktree only
contains tracked files, so the setup command needs them on the branch.

The setup script checks for `bash`, `git`, `ssh`, and the optional tools
(`fzf`, `docker`, `nohup`, `python3`), makes the shell sources executable, and
runs `bash -n` over them. It deliberately does not install anything globally,
so a worktree cannot replace the `farward` in `~/.local/bin`.

Run it by hand with:

```bash
scripts/setup-worktree.sh
```

Set `FARWARD_SETUP_SMOKE=1` to run the full smoke test as part of setup:

```bash
FARWARD_SETUP_SMOKE=1 scripts/setup-worktree.sh
```

## Docker and standalone services together

```bash
farward mattbackup@mini
```

The selector contains discovered Docker mappings plus:

```text
[add custom port]  enter an arbitrary remote TCP port
```

Select it, enter the remote port, and Farward adds it to the selector as a standalone service. You can then select it with any Docker services and start them in the same dashboard.

## Discovering non-Docker services

Docker is not required. `--scan` asks the remote host for every TCP port that is
listening and adds those services to the selector next to Docker's published
ports:

```bash
farward --scan mattbackup@mini
```

The selector marks the source of each row:

```text
D web                    host:8080  container:80   tcp
L postgres               host:5432  listener       tcp
L node                   host:3000  listener       tcp bind:10.0.0.5
L sshd                   host:22    listener       tcp
[add custom port]  enter an arbitrary remote TCP port
```

`D` rows come from Docker; `L` rows are remote listeners. A listener bound to a
specific address such as `10.0.0.5:3000` keeps that address as the forward
target, exactly like a specific Docker bind.

Scan listeners without contacting Docker:

```bash
farward --no-docker --scan mattbackup@mini
```

Hide noisy ports such as SSH:

```bash
farward --scan --exclude 22 mattbackup@mini
```

If Docker publishes nothing, Farward scans listeners automatically instead of
dead-ending at `[add custom port]`. Disable that fallback with `--no-scan`.

Farward uses whichever of `ss`, `lsof`, or `netstat` exists on the remote host.
Process names may show `?` when the SSH user cannot inspect another user's
processes; the forward still works. Only IPv4 targets are currently supported,
so listeners bound exclusively to a specific IPv6 address are skipped with a
summary warning.

## Directly add a standalone service

Forward remote port `8347` and choose the local port interactively:

```bash
farward --port 8347 mattbackup@mini
```

Request remote `8347` on local `18347`:

```bash
farward --port 8347:18347 mattbackup@mini
```

Add several services:

```bash
farward \
  --port 8347 \
  --port 3000:13000 \
  --port 8025 \
  mattbackup@mini
```

Directly supplied ports appear alongside Docker ports in the selector, allowing you to deselect any you do not need.

## Manual-only mode

Skip Docker completely and enter one or more ports interactively:

```bash
farward --manual mattbackup@mini
```

Enter a blank value when you have finished adding ports. Farward then asks which local port to use for each remote service.

For scripted/manual ports without Docker discovery:

```bash
farward --no-docker --port 8347 --port 3000:13000 mattbackup@mini
```

You can also run `farward --no-docker mattbackup@mini` and use `[add custom port]` in the selector.

## Other options

```text
-p, --port REMOTE[:LOCAL]  Add a standalone remote TCP port; repeatable
-t, --target-host HOST     Remote-side host to connect to; default localhost
-m, --manual               Prompt for standalone ports and skip Docker
    --no-docker             Disable Docker discovery
    --scan                  Also list every TCP port listening on the remote host
    --listeners             Alias for --scan
    --no-scan               Never scan remote listeners, including auto-fallback
    --exclude PORT          Hide a remote port from Docker/scan rows; repeatable
    -b, --background       Run tunnels without the dashboard
    -o, --open             Open recognised web-service ports
    --retry N              Reconnect a background tunnel up to N times (default 3, 0 disables)
    --retry-forever        Reconnect a background tunnel indefinitely
    --diagnose             Check remote target reachability and exit
    --dry-run              Print resolved forwards and SSH arguments without tunneling
    --self-test            Run Farward's local smoke test
    -v, --version          Print the Farward version and exit
    -h, --help             Show usage
```

## Managing background tunnels

`--background` registers the tunnel, so it can be managed without guessing PIDs
or running `pkill`:

```bash
farward list                    # id, host, uptime, alive/stale, forward count
farward logs <id>               # SSH stderr for that tunnel
farward logs <id> -f            # follow it
farward restart <id>            # relaunch with the same forwards
farward stop <id>               # stop one tunnel
farward stop --all              # stop every tunnel Farward started
```

A completed `--background` run prints its id and these commands:

```text
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

Ids can be abbreviated to any unique prefix. State lives in
`${FARWARD_STATE_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/farward}`, one directory
per session (`meta`, `status`, `args`, `forwards`, `log`), created with mode
`0700`.

`list`, `logs`, `restart`, and `stop` are reserved command words. A host with one
of those short names is still reachable by writing it as `user@list`.

Before stopping or restarting, Farward checks that the recorded PID is still the
session's supervisor by matching its command line against `--supervise` and the
session directory. The SSH child is verified separately against the saved forward
spec and host. A recycled PID is reported as `stale` and its state can be removed
without signalling an unrelated process. `restart` also works on failed or stale
sessions, which is the recovery path after a reboot.

## Automatic reconnect

Every background session is owned by a small detached supervisor. If SSH exits,
the supervisor starts it again against the same saved arguments and forwards:

```bash
farward --background prod-tools                 # default: up to 3 reconnects
farward --retry 10 --background prod-tools      # up to 10 reconnects
farward --retry 0 --background prod-tools       # no reconnects
farward --retry-forever --background prod-tools
```

Retries back off at 1, 2, 4, 8, 16, then 30 seconds. A connection that stays up
for at least 30 seconds resets the budget, so a tunnel that drops months later
gets the full allowance again. The budget is saved in the session, so
`farward restart <id>` keeps it without repeating the flag.

`farward list` reflects the supervisor state:

| Status | Meaning |
|---|---|
| `alive` | supervisor and SSH child are running |
| `starting` | supervisor is making its first connection |
| `retry-N` | waiting to reconnect after drop N |
| `failed` | retry budget exhausted; state kept for `logs`/`restart` |
| `stale` | supervisor is gone and no failure state was recorded |

`--retry` has no effect on foreground dashboard runs; Farward prints a note and
continues normally.

## How forwarding works

A manual mapping such as:

```text
localhost:18347 -> mattbackup@mini:8347
```

uses SSH local forwarding equivalent to:

```bash
ssh -L localhost:18347:localhost:8347 mattbackup@mini
```

The remote application must therefore be reachable from the SSH host at `localhost:<remote-port>`.

For Docker-discovered ports, Farward uses the bind address reported by Docker when it is specific. For example, `10.0.0.5:8080->80/tcp` forwards to `10.0.0.5:8080` from the SSH host. Wildcard binds such as `0.0.0.0:8080->80/tcp` are treated as remote `localhost:8080`.

If the service is bound to another interface on the remote machine, provide the remote-side target explicitly:

```bash
farward --no-docker --target-host 10.0.0.5 --port 8347:18347 mattbackup@mini
```

That uses:

```bash
ssh -L localhost:18347:10.0.0.5:8347 mattbackup@mini
```

Set `FARWARD_BIND_HOST` only if you intentionally need a different local bind address. The default keeps the listener on localhost and matches Farward's startup probe.

If your SSH connection needs a custom identity, port, jump host, or host alias, put it in an SSH config file and pass it to Farward:

```bash
FARWARD_SSH_CONFIG=/path/to/ssh_config farward --no-docker --port 8347:18347 my-host-alias
```

To check reachability from the SSH host before opening a tunnel:

```bash
farward --no-docker --diagnose --target-host 10.0.0.5 --port 8347:18347 mattbackup@mini
```

To inspect the exact SSH forwards Farward would create without opening a tunnel:

```bash
farward --no-docker --dry-run --target-host 10.0.0.5 --port 8347:18347 mattbackup@mini
```
