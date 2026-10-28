# Spec 001 — Remote listener discovery (`--scan`)

Status: implemented
Scope: `farward` single-file CLI

## 1. Goal

Farward can only enumerate remote services that Docker publishes. Any non-Docker
service must be typed in by hand via `--manual` or `--port`, even though the
remote host can enumerate its own listening TCP sockets. `--scan` closes that gap
by querying the remote host for all listening TCP ports and merging them into the
existing `fzf` selector.

### Non-goals

- No UDP discovery (SSH cannot forward UDP anyway).
- No `sudo` escalation: scan as the SSH user, accept partial process names.
- No process-name filtering or query language.
- No specific-IPv6 targets (blocked by `validate_target_host`; separate item).
- No container-to-listener correlation beyond deduplication.
- No new local dependency. Remote uses whichever of `ss`, `lsof`, `netstat`
  exists.

## 2. UX

```bash
farward --scan mini                  # Docker ports + all remote listeners
farward --no-docker --scan mini      # listeners only, no Docker round trip
farward --scan --exclude 22 mini     # hide SSH and other noise
```

Selector:

```
D web                          host:8080   container:80   tcp
L postgres                     host:5432   listener       tcp
L node                         host:3000   listener       tcp bind:10.0.0.5
L sshd                         host:22     listener       tcp
[add custom port]
```

- `D` = Docker-published, `L` = remote listener.
- `--with-nth=1` shows only the display column, so process name and bind note
  live there.
- Header: `TAB selects multiple ports · D = Docker published · L = remote listener`.

### Flags

| Flag | Behaviour |
|---|---|
| `--scan`, `--listeners` | Enable listener discovery alongside whatever else is enabled |
| `--no-scan` | Never scan, including the automatic fallback |
| `--exclude PORT` | Repeatable; drop that remote port from Docker and scan results |

Rules:

- `--manual` + `--scan` is an error: `--manual and --scan are mutually
  exclusive; use --no-docker --scan.`
- `--no-docker --scan` means listeners only, with the selector; it must not fall
  through to the manual prompt when listeners were found.
- `--target-host` still overrides the per-row bind address exactly as it does
  today.

### Automatic fallback

If Docker discovery is enabled, returned zero rows, and neither `--no-scan` nor
`--manual` is set, run the scan automatically and print:

```
No published Docker ports found; scanning remote listeners...
```

This removes the dead end where the selector only offers `[add custom port]` and
is read-only. `--no-scan` restores strict legacy behaviour.

## 3. Remote collection

One extra SSH invocation with the same options as Docker discovery
(`BatchMode=yes`, `ConnectTimeout=8`):

```bash
ssh_command -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" '
  printf "@@FARWARD_SCAN_BEGIN@@\n"
  if command -v ss >/dev/null 2>&1; then
    printf "@@FARWARD_SCAN_TOOL:ss@@\n"
    ss -ltnp 2>/dev/null || ss -ltn
  elif command -v lsof >/dev/null 2>&1; then
    printf "@@FARWARD_SCAN_TOOL:lsof@@\n"
    lsof -nP -iTCP -sTCP:LISTEN -F pcn 2>/dev/null
  elif command -v netstat >/dev/null 2>&1; then
    printf "@@FARWARD_SCAN_TOOL:netstat@@\n"
    netstat -ltnp 2>/dev/null || netstat -ltn
  else
    exit 127
  fi
'
```

The sentinels give the local side a reliable tool detector and give the
smoke-test mock a stable string to match instead of coupling tests to `ss`'s
exact command line.

Failure handling:

| Situation | Behaviour |
|---|---|
| No `ss`/`lsof`/`netstat` remotely (exit 127) | One warning, continue with other sources |
| SSH auth failure / non-zero | Warning with first output line, continue |
| Zero listeners | `No remote listeners found.`, continue |
| Malformed line | Ignored |
| IPv6-specific binds | Skipped, one summary line |

Scanning never aborts the session.

## 4. Normalisation

All three formats reduce to `process<TAB>bind<TAB>port`, then one shared
normaliser implemented as a POSIX awk program.

**ss** — `State Recv-Q Send-Q Local Peer Process`; local address is field 4,
process extracted from `users:(("<name>"` via `index`/`substr`/`split` (no
gawk-only `match` array). Missing process info becomes `?`.

**lsof** — machine-readable `-F pcn`: `p<pid>`, `c<name>`, `n<addr:port>`; emit on
each `n` line using the current command name.

**netstat** — skip header/non-`LISTEN`; local address is field 4, program is
field 7 (`1234/nginx` → `nginx`, `-` → `?`). Linux `addr:port` only; macOS
`addr.port` remote hosts are best-effort.

Target mapping:

| bind | target |
|---|---|
| `""`, `*`, `0.0.0.0`, `::`, `:::` | `localhost` |
| `127.0.0.1`, `::1` | `localhost` |
| other IPv4 | that address |
| other IPv6 | skip, counted |

Port must be `1..65535`; port 0 and unparseable lines are dropped. `--exclude`
is applied here.

## 5. Merge and dedupe

- Docker rows keep precedence; build them first, append scan rows.
- Cross-source dedupe compares the **remote port only**: a Docker published
  mapping and its `docker-proxy` listener (usually `0.0.0.0`) describe the same
  service but normalise to different target hosts. Docker wins.
- Within scan results, dedupe key is `<target>:<port>`, a named process beats
  `?`, and `127.0.0.1`/`[::1]` collapse.
- Order: Docker rows (name, numeric port), then scan rows by port, then name.

No schema change to the 6-field row contract
(`display, remote, container, protocol, local_override, target_override`):

- Scan rows set `container = remote port`, so browser auto-detection works.
- `protocol = tcp`, `local_override = __AUTO__`,
  `target_override = normalised bind`.
- Do **not** add a 7th field: the reader at `farward:996` would fold it into
  `target_override`.
- Cross-source dedupe uses a `|host:port|` string accumulator, not associative
  arrays, because macOS ships Bash 3.2.

## 6. Row format

```
printf 'L %-28s host:%-6s listener     %s%s\t%s\t%s\t%s\t__AUTO__\t%s\n',
       proc, port, proto, target_note, port, port, proto, target
```

Docker rows keep their existing format with a `D ` prefix. `target_note` is
` bind:<ip>` when the target is not `localhost`.

## 7. Tests

`tests/smoke.sh` extends the mock SSH with a scan branch matching
`FARWARD_SCAN_BEGIN`, tool-specific fixtures, `FARWARD_MOCK_SCAN_FILE`,
`FARWARD_MOCK_SCAN_TOOL=none`, `FARWARD_MOCK_DOCKER_EMPTY`, and
`FARWARD_MOCK_DOCKER_FAILED`. The fzf mock logs its input to
`fzf-input.log` so selector contents can be asserted.

Covered: ss/lsof/netstat parsing, wildcard/loopback/site-IPv4 mapping, IPv6 skip,
duplicate elimination, Docker precedence, `--exclude`, `--no-docker --scan`,
auto-fallback, missing scan tool, Docker failure reporting, and the
`--manual`/`--scan` conflict.

## 8. Acceptance criteria

1. `farward --scan host` lists Docker-published and remotely-listening TCP ports
   in one selector, visually distinguishable.
2. Selecting a listener produces a correct `-L` forward with its bind address as
   target; `--dry-run` shows it.
3. No duplicate rows for a port that is both Docker-published and listening.
4. A host with no scan tool still runs, with one clear warning.
5. A host with no Docker and no `--port` no longer dead-ends at
   `[add custom port]`.
6. Bash 3.2 remains supported.
7. Existing smoke checks pass unchanged.
