# Farward

Farward — forwarding from afar — is an interactive SSH port-forwarding dashboard for remote services. It can discover published Docker ports, forward ordinary standalone processes, or combine both in one session.

## Features

- Discovers published Docker/Compose TCP ports with `docker ps`.
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

The smoke test uses a mock SSH process and temporary local ports to verify background forwarding, byte-level custom-port traffic, remote-side failure reporting, the foreground dashboard animation, and `:q` cleanup. When `sshd` and `ssh-keygen` are available, it also starts a temporary local SSH server and verifies a real OpenSSH custom-port tunnel end to end.

These are equivalent:

```bash
farward help
farward --help
farward -h
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
-b, --background           Run tunnels without the dashboard
-o, --open                 Open recognised web-service ports
    --diagnose             Check remote target reachability and exit
    --dry-run              Print resolved forwards and SSH arguments without tunneling
    --self-test            Run Farward's local smoke test
-h, --help                 Show usage
```

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
