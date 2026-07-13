# Farward

Farward — forwarding from afar — is an interactive SSH port-forwarding dashboard for remote services. It can discover published Docker ports, forward ordinary standalone processes, or combine both in one session.

## Features

- Discovers published Docker/Compose TCP ports with `docker ps`.
- Adds arbitrary remote TCP ports for non-Docker applications.
- Selects multiple services with `fzf`.
- Supports direct `REMOTE` and `REMOTE:LOCAL` port specifications.
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
[manual port]  enter an arbitrary remote TCP port
```

Select it, enter the remote port, and Farward adds it to the same dashboard as the Docker services.

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

## Other options

```text
-p, --port REMOTE[:LOCAL]  Add a standalone remote TCP port; repeatable
-m, --manual               Prompt for standalone ports and skip Docker
    --no-docker             Disable Docker discovery
-b, --background           Run tunnels without the dashboard
-o, --open                 Open recognised web-service ports
-h, --help                 Show usage
```

## How forwarding works

A manual mapping such as:

```text
localhost:18347 -> mattbackup@mini:8347
```

uses SSH local forwarding equivalent to:

```bash
ssh -L 18347:127.0.0.1:8347 mattbackup@mini
```

The remote application must therefore be reachable from the SSH host at `127.0.0.1:<remote-port>`.
