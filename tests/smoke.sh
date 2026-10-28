#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FARWARD_BIN="${FARWARD_BIN:-$ROOT_DIR/farward}"
SMOKE_DIR="${FARWARD_SMOKE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/farward-smoke.XXXXXX")}"
MOCK_BIN="$SMOKE_DIR/bin"
export FARWARD_STATE_DIR="${FARWARD_STATE_DIR:-$SMOKE_DIR/state}"

cleanup() {
    if [[ -n "${FARWARD_STATE_DIR:-}" && -d "$FARWARD_STATE_DIR" ]]; then
        FARWARD_STATE_DIR="$FARWARD_STATE_DIR" "$FARWARD_BIN" stop --all >/dev/null 2>&1 || true
    fi
    if [[ -f "$SMOKE_DIR/ssh.pid" ]]; then
        kill "$(cat "$SMOKE_DIR/ssh.pid")" 2>/dev/null || true
    fi
    if [[ -f "$SMOKE_DIR/sshd.pid" ]]; then
        kill "$(cat "$SMOKE_DIR/sshd.pid")" 2>/dev/null || true
    fi
    if [[ -f "$SMOKE_DIR/manual.pid" ]]; then
        kill "$(cat "$SMOKE_DIR/manual.pid")" 2>/dev/null || true
    fi
    if [[ -f "$SMOKE_DIR/live-target.pid" ]]; then
        kill "$(cat "$SMOKE_DIR/live-target.pid")" 2>/dev/null || true
    fi
    rm -rf "$SMOKE_DIR"
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$1" >&2
        exit 1
    }
}

free_port() {
    python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

allocated_ports="|"
unique_free_port() {
    local port

    while true; do
        port="$(free_port)"
        [[ -n "$port" ]] || {
            printf 'could not allocate a local TCP test port\n' >&2
            exit 1
        }
        if [[ "$allocated_ports" != *"|${port}|"* ]]; then
            allocated_ports+="${port}|"
            printf '%s\n' "$port"
            return 0
        fi
    done
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]] || {
        printf 'expected output to contain: %s\nactual output:\n%s\n' "$needle" "$haystack" >&2
        exit 1
    }
}

read_forward_banner() {
    local port="$1"

    python3 - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), 3) as sock:
    sock.sendall(b"ping\n")
    print(sock.recv(1024).decode().strip())
PY
}

meta_value() {
    local id="$1"
    local key="$2"

    sed -n "s/^${key}=//p" "$FARWARD_STATE_DIR/$id/meta" 2>/dev/null | head -n 1
}

status_value() {
    local id="$1"
    local key="$2"

    sed -n "s/^${key}=//p" "$FARWARD_STATE_DIR/$id/status" 2>/dev/null | head -n 1
}

wait_for_session_field() {
    local id="$1"
    local key="$2"
    local wanted="$3"
    local tries="${4:-100}"
    local i=0
    local value

    while (( i < tries )); do
        value="$(meta_value "$id" "$key")"
        if [[ -n "$value" && "$value" != "$wanted" ]] && kill -0 "$value" 2>/dev/null; then
            printf '%s\n' "$value"
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

wait_for_session_status() {
    local id="$1"
    local wanted="$2"
    local tries="${3:-100}"
    local i=0

    while (( i < tries )); do
        if [[ "$(status_value "$id" state)" == "$wanted" ]]; then
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

wait_for_banner() {
    local port="$1"
    local tries="${2:-100}"
    local i=0
    local banner

    while (( i < tries )); do
        if banner="$(read_forward_banner "$port" 2>/dev/null)"; then
            printf '%s\n' "$banner"
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

start_test_session() {
    local port="$1"
    shift

    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
        "$FARWARD_BIN" "$@" --no-docker --port "8347:$port" --background fakehost 2>&1
}

session_id_from_output() {
    printf '%s\n' "$1" | sed -n 's/^Session: //p' | head -n 1
}

find_sshd() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
    elif [[ -x /usr/sbin/sshd ]]; then
        printf '%s\n' /usr/sbin/sshd
    else
        return 1
    fi
}

require_command bash
require_command python3
require_command nc
require_command expect

bash -n "$FARWARD_BIN"
python3 - "$FARWARD_BIN" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
marker = 'python3 - "$SSH_PID" "$SSH_HOST" "${summary[@]}" <<\'PY\'\n'
start = text.index(marker) + len(marker)
end = text.index("\nPY\n}", start)
compile(text[start:end], "embedded_dashboard.py", "exec")
print("embedded dashboard python compiles")
PY

mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/ssh" <<'MOCK'
#!/usr/bin/env bash

is_tunnel=false
forward_specs=()
for arg in "$@"; do
    [[ "$arg" == "-N" ]] && is_tunnel=true
    if [[ "$arg" =~ ^([^:]+:)?[0-9]+:[^:]+:[0-9]+$ ]]; then
        forward_specs+=("$arg")
    fi
done

printf '%q ' "$@" > "$FARWARD_SMOKE_DIR/ssh-args.log"
printf '\n' >> "$FARWARD_SMOKE_DIR/ssh-args.log"

if [[ "$is_tunnel" != true ]]; then
    if [[ "$*" == *"FARWARD_SCAN_BEGIN"* ]]; then
        scan_tool="${FARWARD_MOCK_SCAN_TOOL:-ss}"
        printf '@@FARWARD_SCAN_BEGIN@@\n'
        if [[ "$scan_tool" == "none" ]]; then
            exit 127
        fi
        printf '@@FARWARD_SCAN_TOOL:%s@@\n' "$scan_tool"
        if [[ -n "${FARWARD_MOCK_SCAN_FILE:-}" && -f "${FARWARD_MOCK_SCAN_FILE}" ]]; then
            cat "$FARWARD_MOCK_SCAN_FILE"
        else
            case "$scan_tool" in
                lsof)
                    printf 'p1\ncnginx\nn*:80\np2\ncpostgres\nn127.0.0.1:5432\n'
                    ;;
                netstat)
                    printf 'Proto Recv-Q Send-Q Local Address Foreign Address State PID/Program\n'
                    printf 'tcp 0 0 0.0.0.0:80 0.0.0.0:* LISTEN 1/nginx\n'
                    printf 'tcp 0 0 127.0.0.1:5432 0.0.0.0:* LISTEN 2/postgres\n'
                    ;;
                *)
                    printf 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1,fd=6))\n'
                    printf 'LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=2,fd=7))\n'
                    ;;
            esac
        fi
        exit 0
    fi
    if [[ "$*" == *"docker ps --format"* ]]; then
        if [[ "${FARWARD_MOCK_DOCKER_FAILED:-}" == true ]]; then
            printf 'mock docker unavailable\n' >&2
            exit 1
        fi
        if [[ "${FARWARD_MOCK_DOCKER_EMPTY:-}" == true ]]; then
            exit 0
        fi
        printf 'web|10.0.0.5:%s->80/tcp\n' "${FARWARD_MOCK_DOCKER_PORT:-18080}"
        exit 0
    fi
    if [[ "${FARWARD_MOCK_DIAGNOSE_FAILED:-}" == true ]]; then
        printf 'mock diagnose failed\n' >&2
        exit 1
    fi
    exit 0
fi

if [[ "$is_tunnel" == true ]]; then
    printf '%s\n' "$$" > "$FARWARD_SMOKE_DIR/ssh.pid"
    listener_pids=()
    for forward_spec in "${forward_specs[@]}"; do
        IFS=: read -r first second third fourth extra <<< "$forward_spec"
        if [[ -n "${fourth:-}" ]]; then
            bind_host="$first"
            local_port="$second"
            target_host="$third"
            remote_port="$fourth"
        else
            bind_host="127.0.0.1"
            local_port="$first"
            target_host="$second"
            remote_port="$third"
        fi

        python3 - "$bind_host" "$local_port" "$target_host" "$remote_port" <<'PY' &
import socket
import sys
import threading

bind_host = sys.argv[1]
port = int(sys.argv[2])
target_host = sys.argv[3]
remote_port = sys.argv[4]
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind((bind_host, port))
sock.listen()

def handle(conn):
    with conn:
        try:
            conn.recv(1024)
            conn.sendall(f"farward-smoke:{target_host}:{remote_port}\n".encode())
        except OSError:
            pass

while True:
    conn, _ = sock.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY
        listener_pids+=("$!")
    done

    if [[ "${FARWARD_MOCK_OPEN_FAILED:-}" == true ]]; then
        sleep 1
        printf 'channel 1: open failed: connect failed: Connection refused\n' >&2
    fi

    trap 'for pid in "${listener_pids[@]}"; do kill "$pid" 2>/dev/null || true; done; exit 0' TERM INT EXIT
    while :; do
        sleep 1
    done
fi
MOCK
chmod +x "$MOCK_BIN/ssh"
cat >"$MOCK_BIN/fzf" <<'MOCK'
#!/usr/bin/env bash
if [[ -n "${FARWARD_SMOKE_DIR:-}" ]]; then
    cat >"$FARWARD_SMOKE_DIR/fzf-input.log"
    if [[ -n "${FARWARD_MOCK_FZF_PICK:-}" ]]; then
        grep -F -m 1 "$FARWARD_MOCK_FZF_PICK" "$FARWARD_SMOKE_DIR/fzf-input.log" ||
            head -n 1 "$FARWARD_SMOKE_DIR/fzf-input.log"
    else
        head -n 1 "$FARWARD_SMOKE_DIR/fzf-input.log"
    fi
else
    IFS= read -r first
    printf '%s\n' "$first"
fi
MOCK
chmod +x "$MOCK_BIN/fzf"

background_port="$(unique_free_port)"
foreground_port="$(unique_free_port)"
failure_port="$(unique_free_port)"
diagnose_port="$(unique_free_port)"
diagnose_failure_port="$(unique_free_port)"
docker_port="$(unique_free_port)"
non_tty_port="$(unique_free_port)"
dry_run_port="$(unique_free_port)"
default_dry_run_port="$(unique_free_port)"
docker_dry_run_port="$(unique_free_port)"
occupied_port="$(unique_free_port)"
duplicate_port="$(unique_free_port)"
live_target_port="$(unique_free_port)"
live_local_port="$(unique_free_port)"

printf 'checking diagnosis success for remote port %s\n' "$diagnose_port"
PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
    "$FARWARD_BIN" --no-docker --target-host 10.0.0.5 --port "8347:$diagnose_port" --diagnose fakehost
diagnose_args="$(cat "$SMOKE_DIR/ssh-args.log")"
assert_contains "$diagnose_args" "fakehost"
assert_contains "$diagnose_args" "host=10.0.0.5"
assert_contains "$diagnose_args" "port=8347"
assert_contains "$diagnose_args" "python3"
assert_contains "$diagnose_args" "nc"
assert_contains "$diagnose_args" "timeout"
rm -f "$SMOKE_DIR/ssh-args.log"

printf 'checking diagnosis failure for remote port %s\n' "$diagnose_failure_port"
set +e
diagnose_failure_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_DIAGNOSE_FAILED=true \
        "$FARWARD_BIN" --no-docker --port "8347:$diagnose_failure_port" --diagnose fakehost 2>&1
)"
diagnose_failure_status=$?
set -e
[[ "$diagnose_failure_status" -ne 0 ]] || {
    printf 'expected diagnosis failure test to fail\n' >&2
    exit 1
}
assert_contains "$diagnose_failure_output" "mock diagnose failed"
rm -f "$SMOKE_DIR/ssh-args.log"

printf 'checking occupied local port failure on local port %s\n' "$occupied_port"
python3 - "$occupied_port" <<'PY' &
import socket
import sys
import time

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", port))
sock.listen()
time.sleep(30)
PY
occupied_pid=$!
sleep 0.3
set +e
occupied_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
        "$FARWARD_BIN" --no-docker --port "8347:$occupied_port" --background fakehost 2>&1
)"
occupied_status=$?
set -e
kill "$occupied_pid" 2>/dev/null || true
wait "$occupied_pid" 2>/dev/null || true
[[ "$occupied_status" -ne 0 ]] || {
    printf 'expected occupied local port test to fail\n' >&2
    exit 1
}
assert_contains "$occupied_output" "Local port $occupied_port is already in use"
if [[ -f "$SMOKE_DIR/ssh-args.log" ]]; then
    printf 'occupied local port test should not start ssh\n' >&2
    cat "$SMOKE_DIR/ssh-args.log" >&2
    exit 1
fi
rm -f "$SMOKE_DIR/ssh-args.log"

printf 'checking duplicate local port failure on local port %s\n' "$duplicate_port"
set +e
duplicate_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
        "$FARWARD_BIN" --no-docker --port "8347:$duplicate_port" --port "8348:$duplicate_port" --background fakehost 2>&1
)"
duplicate_status=$?
set -e
[[ "$duplicate_status" -ne 0 ]] || {
    printf 'expected duplicate local port test to fail\n' >&2
    exit 1
}
assert_contains "$duplicate_output" "Local port $duplicate_port was selected more than once"
if [[ -f "$SMOKE_DIR/ssh-args.log" ]]; then
    printf 'duplicate local port test should not start ssh\n' >&2
    cat "$SMOKE_DIR/ssh-args.log" >&2
    exit 1
fi

printf 'checking manual dry-run on local port %s\n' "$dry_run_port"
dry_run_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
        "$FARWARD_BIN" --no-docker --target-host 10.0.0.5 --port "8347:$dry_run_port" --dry-run fakehost
)"
assert_contains "$dry_run_output" "localhost:$dry_run_port -> 10.0.0.5:8347 via fakehost"
assert_contains "$dry_run_output" "-L localhost:$dry_run_port:10.0.0.5:8347"
if [[ -f "$SMOKE_DIR/ssh.pid" ]]; then
    printf 'manual dry-run should not start ssh tunnel\n' >&2
    exit 1
fi
rm -f "$SMOKE_DIR/ssh-args.log"

printf 'checking default localhost dry-run on local port %s\n' "$default_dry_run_port"
default_dry_run_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
        "$FARWARD_BIN" --no-docker --port "4321:$default_dry_run_port" --dry-run fakehost
)"
assert_contains "$default_dry_run_output" "localhost:$default_dry_run_port -> fakehost:4321"
assert_contains "$default_dry_run_output" "-L localhost:$default_dry_run_port:localhost:4321"
if [[ -f "$SMOKE_DIR/ssh.pid" ]]; then
    printf 'default localhost dry-run should not start ssh tunnel\n' >&2
    exit 1
fi
rm -f "$SMOKE_DIR/ssh-args.log"

printf 'checking Docker dry-run bind address on local port %s\n' "$docker_dry_run_port"
docker_dry_run_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_DOCKER_PORT="$docker_dry_run_port" \
        "$FARWARD_BIN" --dry-run fakehost
)"
assert_contains "$docker_dry_run_output" "localhost:$docker_dry_run_port -> 10.0.0.5:$docker_dry_run_port via fakehost"
assert_contains "$docker_dry_run_output" "-L localhost:$docker_dry_run_port:10.0.0.5:$docker_dry_run_port"
if [[ -f "$SMOKE_DIR/ssh.pid" ]]; then
    printf 'Docker dry-run should not start ssh tunnel\n' >&2
    exit 1
fi
rm -f "$SMOKE_DIR/ssh-args.log"

printf 'checking non-TTY foreground failure on local port %s\n' "$non_tty_port"
set +e
non_tty_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
        "$FARWARD_BIN" --no-docker --port "8347:$non_tty_port" fakehost 2>&1
)"
non_tty_status=$?
set -e
[[ "$non_tty_status" -ne 0 ]] || {
    printf 'expected non-TTY foreground test to fail\n' >&2
    exit 1
}
assert_contains "$non_tty_output" "Foreground dashboard requires a terminal"
if [[ -f "$SMOKE_DIR/ssh-args.log" ]]; then
    printf 'non-TTY foreground test should not start ssh\n' >&2
    cat "$SMOKE_DIR/ssh-args.log" >&2
    exit 1
fi

printf 'checking Docker bind-address forwarding on local port %s\n' "$docker_port"
PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_DOCKER_PORT="$docker_port" \
    "$FARWARD_BIN" --background fakehost
nc -z 127.0.0.1 "$docker_port"
docker_banner="$(read_forward_banner "$docker_port")"
assert_contains "$docker_banner" "farward-smoke:10.0.0.5:$docker_port"
docker_args="$(cat "$SMOKE_DIR/ssh-args.log")"
assert_contains "$docker_args" "-L localhost:$docker_port:10.0.0.5:$docker_port fakehost"
"$FARWARD_BIN" stop --all >/dev/null
rm -f "$SMOKE_DIR/ssh.pid" "$SMOKE_DIR/ssh-args.log"

printf 'checking background forwarding success on local port %s\n' "$background_port"
PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
    "$FARWARD_BIN" --no-docker --target-host 10.0.0.5 --port "8347:$background_port" --background fakehost
nc -z 127.0.0.1 "$background_port"
background_banner="$(read_forward_banner "$background_port")"
assert_contains "$background_banner" "farward-smoke:10.0.0.5:8347"
background_args="$(cat "$SMOKE_DIR/ssh-args.log")"
assert_contains "$background_args" "-L localhost:$background_port:10.0.0.5:8347 fakehost"
"$FARWARD_BIN" stop --all >/dev/null
rm -f "$SMOKE_DIR/ssh.pid" "$SMOKE_DIR/ssh-args.log"

printf 'checking remote-side forwarding failure on local port %s\n' "$failure_port"
set +e
failure_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_OPEN_FAILED=true \
        "$FARWARD_BIN" --no-docker --port "8347:$failure_port" --background fakehost 2>&1
)"
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]] || {
    printf 'expected remote-side failure test to fail\n' >&2
    exit 1
}
assert_contains "$failure_output" "connect failed: Connection refused"
"$FARWARD_BIN" stop --all >/dev/null 2>&1 || true
rm -f "$SMOKE_DIR/ssh.pid" "$SMOKE_DIR/ssh-args.log"

printf 'checking foreground dashboard and :q on local port %s\n' "$foreground_port"
PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" expect <<EXPECT
set timeout 10
spawn "$FARWARD_BIN" --no-docker --port "8347:$foreground_port" fakehost
expect "Command:"
after 300
send -- ":q\r"
expect eof
catch wait result
puts "expect_wait=\$result"
EXPECT

foreground_args="$(cat "$SMOKE_DIR/ssh-args.log")"
assert_contains "$foreground_args" "-L localhost:$foreground_port:localhost:8347 fakehost"
if [[ -f "$SMOKE_DIR/ssh.pid" ]] && kill -0 "$(cat "$SMOKE_DIR/ssh.pid")" 2>/dev/null; then
    printf 'foreground mock ssh still alive after :q\n' >&2
    exit 1
fi

printf 'checking live OpenSSH custom-port data path with a temporary sshd when available\n'
sshd_bin="$(find_sshd || true)"
if [[ -n "$sshd_bin" ]] && command -v ssh-keygen >/dev/null 2>&1; then
    sshd_port="$(unique_free_port)"
    ssh-keygen -q -t ed25519 -N "" -f "$SMOKE_DIR/sshd_host_key"
    ssh-keygen -q -t ed25519 -N "" -f "$SMOKE_DIR/client_key"
    cp "$SMOKE_DIR/client_key.pub" "$SMOKE_DIR/authorized_keys"
    chmod 600 "$SMOKE_DIR/authorized_keys" "$SMOKE_DIR/client_key"

    cat >"$SMOKE_DIR/sshd_config" <<EOF
Port $sshd_port
ListenAddress 127.0.0.1
HostKey $SMOKE_DIR/sshd_host_key
PidFile $SMOKE_DIR/sshd.pid
AuthorizedKeysFile $SMOKE_DIR/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin no
StrictModes no
LogLevel ERROR
EOF

    "$sshd_bin" -D -e -f "$SMOKE_DIR/sshd_config" >"$SMOKE_DIR/sshd.log" 2>&1 &
    echo "$!" >"$SMOKE_DIR/sshd.pid"

    cat >"$SMOKE_DIR/ssh_config" <<EOF
Host farward-smoke-sshd
    HostName 127.0.0.1
    Port $sshd_port
    User $USER
    IdentityFile $SMOKE_DIR/client_key
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking no
    UserKnownHostsFile $SMOKE_DIR/known_hosts
    LogLevel ERROR
EOF

    ssh_ready=false
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ssh -F "$SMOKE_DIR/ssh_config" farward-smoke-sshd true >/dev/null 2>&1; then
            ssh_ready=true
            break
        fi
        sleep 0.2
    done

    if [[ "$ssh_ready" != true ]]; then
        printf 'skipping live OpenSSH custom-port data path; temporary sshd did not accept test login\n'
        sed -n '1,20p' "$SMOKE_DIR/sshd.log" || true
    else
    python3 - "$live_target_port" <<'PY' &
import socket
import sys
import threading

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", port))
sock.listen()

def handle(conn):
    with conn:
        try:
            conn.recv(1024)
            conn.sendall(b"farward-live-openssh-ok\n")
        except OSError:
            pass

while True:
    conn, _ = sock.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY
    live_target_pid=$!
    echo "$live_target_pid" >"$SMOKE_DIR/live-target.pid"
    sleep 0.3

    set +e
    live_output="$(
        FARWARD_SSH_CONFIG="$SMOKE_DIR/ssh_config" \
            "$FARWARD_BIN" --no-docker --port "$live_target_port:$live_local_port" --background farward-smoke-sshd 2>&1
    )"
    live_status=$?
    set -e
    [[ "$live_status" -eq 0 ]] || {
        printf 'expected live OpenSSH forwarding to start\n%s\n' "$live_output" >&2
        kill "$live_target_pid" 2>/dev/null || true
        exit 1
    }

    live_banner="$(read_forward_banner "$live_local_port")"
    assert_contains "$live_output" "localhost:$live_local_port"
    assert_contains "$live_banner" "farward-live-openssh-ok"

    live_id="$(printf '%s\n' "$live_output" | sed -n 's/^Session: //p' | head -n 1)"
    [[ -n "$live_id" ]] || {
        printf 'live OpenSSH session did not report an id\n%s\n' "$live_output" >&2
        exit 1
    }
    assert_contains "$("$FARWARD_BIN" list)" "$live_id"

    live_restart="$("$FARWARD_BIN" restart "$live_id" 2>&1)"
    assert_contains "$live_restart" "Session $live_id restarted on farward-smoke-sshd"
    live_banner_after_restart="$(read_forward_banner "$live_local_port")"
    assert_contains "$live_banner_after_restart" "farward-live-openssh-ok"
    "$FARWARD_BIN" stop "$live_id" >/dev/null
    [[ ! -d "$FARWARD_STATE_DIR/$live_id" ]] || {
        printf 'live OpenSSH session state was not removed by stop\n' >&2
        exit 1
    }

    printf 'live OpenSSH custom-port data path passed\n'
    kill "$live_target_pid" 2>/dev/null || true
    wait "$live_target_pid" 2>/dev/null || true
    rm -f "$SMOKE_DIR/live-target.pid"
    fi
else
    printf 'skipping live OpenSSH custom-port data path; sshd or ssh-keygen is not available\n'
fi

printf 'checking remote listener scan selector and normalisation\n'
scan_fixture="$SMOKE_DIR/scan-ss.txt"
cat >"$scan_fixture" <<'EOF'
LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1,fd=6))
LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=2,fd=7))
LISTEN 0 4096 10.0.0.5:8347 0.0.0.0:* users:(("node",pid=3,fd=8))
LISTEN 0 128 *:22 *:* users:(("sshd",pid=4,fd=3))
LISTEN 0 128 [::]:80 [::]:* users:(("nginx",pid=5,fd=6))
LISTEN 0 128 [fe80::1%eth0]:9100 [::]:* users:(("node_exporter",pid=6,fd=3))
EOF
scan_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_SCAN_FILE="$scan_fixture" \
        FARWARD_MOCK_FZF_PICK="L nginx" \
        "$FARWARD_BIN" --no-docker --scan --dry-run fakehost 2>&1
)"
scan_selector="$(cat "$SMOKE_DIR/fzf-input.log")"
assert_contains "$scan_output" "-> fakehost:80"
assert_contains "$scan_output" "Skipped 1 IPv6-only listener"
assert_contains "$scan_selector" "L nginx"
assert_contains "$scan_selector" "L postgres"
assert_contains "$scan_selector" "L sshd"
assert_contains "$scan_selector" "bind:10.0.0.5"
[[ "$(grep -c 'host:80 ' <<< "$scan_selector" || true)" -eq 1 ]] || {
    printf 'expected port 80 to appear once in the scan selector\n%s\n' "$scan_selector" >&2
    exit 1
}
if grep -q '9100' <<< "$scan_selector"; then
    printf 'IPv6-only listener should be skipped\n%s\n' "$scan_selector" >&2
    exit 1
fi

printf 'checking --exclude removes listening ports\n'
exclude_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_SCAN_FILE="$scan_fixture" \
        FARWARD_MOCK_FZF_PICK="L nginx" \
        "$FARWARD_BIN" --no-docker --scan --exclude 22 --dry-run fakehost 2>&1
)"
exclude_selector="$(cat "$SMOKE_DIR/fzf-input.log")"
assert_contains "$exclude_output" "-> fakehost:80"
if grep -q 'L sshd' <<< "$exclude_selector"; then
    printf '--exclude 22 should hide the sshd listener\n%s\n' "$exclude_selector" >&2
    exit 1
fi

printf 'checking Docker rows win over duplicate listeners\n'
scan_docker_port="$(unique_free_port)"
cat >"$SMOKE_DIR/scan-docker.txt" <<EOF
LISTEN 0 4096 10.0.0.5:$scan_docker_port 0.0.0.0:* users:(("web",pid=1,fd=6))
LISTEN 0 4096 0.0.0.0:$scan_docker_port 0.0.0.0:* users:(("web",pid=2,fd=6))
EOF
dedupe_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_DOCKER_PORT="$scan_docker_port" \
        FARWARD_MOCK_SCAN_FILE="$SMOKE_DIR/scan-docker.txt" \
        "$FARWARD_BIN" --scan --dry-run fakehost 2>&1
)"
dedupe_selector="$(cat "$SMOKE_DIR/fzf-input.log")"
assert_contains "$dedupe_output" "-L localhost:$scan_docker_port:10.0.0.5:$scan_docker_port"
assert_contains "$dedupe_selector" "D web"
[[ "$(grep -c "host:$scan_docker_port " <<< "$dedupe_selector" || true)" -eq 1 ]] || {
    printf 'expected Docker/listener duplicate to collapse to one selector row\n%s\n' "$dedupe_selector" >&2
    exit 1
}

printf 'checking automatic listener fallback when Docker publishes nothing\n'
cat >"$SMOKE_DIR/scan-single.txt" <<'EOF'
LISTEN 0 4096 127.0.0.1:8347 0.0.0.0:* users:(("app",pid=1,fd=6))
EOF
fallback_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_DOCKER_EMPTY=true \
        FARWARD_MOCK_SCAN_FILE="$SMOKE_DIR/scan-single.txt" \
        "$FARWARD_BIN" --dry-run fakehost 2>&1
)"
assert_contains "$fallback_output" "No published Docker ports found; scanning remote listeners..."
assert_contains "$fallback_output" "-> fakehost:8347"
assert_contains "$(cat "$SMOKE_DIR/fzf-input.log")" "L app"

printf 'checking lsof listener parsing\n'
lsof_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_SCAN_TOOL=lsof \
        FARWARD_MOCK_FZF_PICK="L nginx" \
        "$FARWARD_BIN" --no-docker --scan --dry-run fakehost 2>&1
)"
assert_contains "$lsof_output" "-> fakehost:80"
assert_contains "$(cat "$SMOKE_DIR/fzf-input.log")" "L nginx"

printf 'checking netstat listener parsing\n'
netstat_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_SCAN_TOOL=netstat \
        FARWARD_MOCK_FZF_PICK="L nginx" \
        "$FARWARD_BIN" --no-docker --scan --dry-run fakehost 2>&1
)"
assert_contains "$netstat_output" "-> fakehost:80"
assert_contains "$(cat "$SMOKE_DIR/fzf-input.log")" "L nginx"

printf 'checking missing scan tool degrades gracefully\n'
scan_no_tool_port="$(unique_free_port)"
no_tool_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_SCAN_TOOL=none \
        "$FARWARD_BIN" --no-docker --scan --port "8347:$scan_no_tool_port" --dry-run fakehost 2>&1
)"
assert_contains "$no_tool_output" "Remote listener scan unavailable"
assert_contains "$no_tool_output" "-L localhost:$scan_no_tool_port:localhost:8347"

printf 'checking Docker discovery failure is reported\n'
docker_failure_port="$(unique_free_port)"
docker_failure_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" FARWARD_MOCK_DOCKER_FAILED=true \
        "$FARWARD_BIN" --no-scan --port "8347:$docker_failure_port" --dry-run fakehost 2>&1
)"
assert_contains "$docker_failure_output" "Docker discovery failed on fakehost: mock docker unavailable"
assert_contains "$docker_failure_output" "-L localhost:$docker_failure_port:localhost:8347"

printf 'checking --manual conflicts with --scan\n'
set +e
manual_scan_output="$("$FARWARD_BIN" --manual --scan fakehost 2>&1)"
manual_scan_status=$?
set -e
[[ "$manual_scan_status" -ne 0 ]] || {
    printf 'expected --manual --scan to fail\n' >&2
    exit 1
}
assert_contains "$manual_scan_output" "--manual and --scan are mutually exclusive"

printf 'checking background session manager\n'
rm -rf "$FARWARD_STATE_DIR"

session_port="$(unique_free_port)"
session_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
        "$FARWARD_BIN" --no-docker --port "8347:$session_port" --background fakehost 2>&1
)"
assert_contains "$session_output" "Tunnel started in the background."
assert_contains "$session_output" "farward list"
assert_contains "$session_output" "farward stop"
if [[ "$session_output" == *pkill* ]]; then
    printf 'background output should not suggest pkill\n%s\n' "$session_output" >&2
    exit 1
fi
session_id="$(printf '%s\n' "$session_output" | sed -n 's/^Session: //p' | head -n 1)"
[[ -n "$session_id" ]] || {
    printf 'could not parse session id from background output\n%s\n' "$session_output" >&2
    exit 1
}
[[ -d "$FARWARD_STATE_DIR/$session_id" ]] || {
    printf 'expected state directory for session %s\n' "$session_id" >&2
    exit 1
}
[[ "$(meta_value "$session_id" retries)" == "3" ]] || {
    printf 'expected default retry budget of 3\n' >&2
    exit 1
}
[[ "$(status_value "$session_id" state)" == "connected" ]] || {
    printf 'expected status state=connected after startup\n' >&2
    exit 1
}

list_output="$("$FARWARD_BIN" list)"
assert_contains "$list_output" "$session_id"
assert_contains "$list_output" "fakehost"
assert_contains "$list_output" "alive"

printf 'manager-log-line\n' >>"$FARWARD_STATE_DIR/$session_id/log"
logs_output="$("$FARWARD_BIN" logs "$session_id")"
assert_contains "$logs_output" "manager-log-line"

pid_before="$(sed -n 's/^pid=//p' "$FARWARD_STATE_DIR/$session_id/meta")"
restart_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
        "$FARWARD_BIN" restart "$session_id" 2>&1
)"
assert_contains "$restart_output" "Session $session_id restarted on fakehost"
pid_after="$(sed -n 's/^pid=//p' "$FARWARD_STATE_DIR/$session_id/meta")"
[[ -n "$pid_after" && "$pid_after" != "$pid_before" ]] || {
    printf 'restart should replace the session pid\nbefore=%s after=%s\n' "$pid_before" "$pid_after" >&2
    exit 1
}
kill -0 "$pid_after" 2>/dev/null || {
    printf 'restarted session pid %s is not alive\n' "$pid_after" >&2
    exit 1
}
ssh_pid_after_restart="$(meta_value "$session_id" ssh_pid)"
[[ -n "$ssh_pid_after_restart" ]] && kill -0 "$ssh_pid_after_restart" 2>/dev/null || {
    printf 'restart should start an ssh child\n' >&2
    exit 1
}
assert_contains "$(status_value "$session_id" state)" "connected"

printf 'checking session prefix matching and stop\n'
session_prefix="${session_id:0:18}"
stop_output="$("$FARWARD_BIN" stop "$session_prefix")"
assert_contains "$stop_output" "Stopped session $session_id"
[[ ! -d "$FARWARD_STATE_DIR/$session_id" ]] || {
    printf 'stop should remove session state\n' >&2
    exit 1
}
if kill -0 "$pid_after" 2>/dev/null; then
    printf 'stopped session pid %s is still alive\n' "$pid_after" >&2
    exit 1
fi
if kill -0 "$ssh_pid_after_restart" 2>/dev/null; then
    printf 'stopped ssh child pid %s is still alive\n' "$ssh_pid_after_restart" >&2
    exit 1
fi
assert_contains "$("$FARWARD_BIN" list)" "No background sessions."

printf 'checking stop --all\n'
all_port_a="$(unique_free_port)"
all_port_b="$(unique_free_port)"
for all_port in "$all_port_a" "$all_port_b"; do
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
        "$FARWARD_BIN" --no-docker --port "8347:$all_port" --background fakehost >/dev/null
done
[[ "$(find "$FARWARD_STATE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 2 ]] || {
    printf 'expected two managed sessions before stop --all\n' >&2
    exit 1
}
all_output="$("$FARWARD_BIN" stop --all)"
assert_contains "$all_output" "Stopped session"
assert_contains "$("$FARWARD_BIN" list)" "No background sessions."
[[ -z "$(find "$FARWARD_STATE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]] || {
    printf 'stop --all should remove every session directory\n' >&2
    exit 1
}

printf 'checking stale session handling\n'
mkdir -p "$FARWARD_STATE_DIR/manual-stale"
printf 'id=manual-stale\npid=999999\nhost=ghost\nstarted=%s\nbind=localhost\nversion=1\n' "$(date +%s)" \
    >"$FARWARD_STATE_DIR/manual-stale/meta"
printf '%s\n' "-L" "localhost:12345:localhost:8347" >"$FARWARD_STATE_DIR/manual-stale/forwards"
printf '%s\n' "-o" "BatchMode=yes" >"$FARWARD_STATE_DIR/manual-stale/args"
: >"$FARWARD_STATE_DIR/manual-stale/log"
stale_list="$("$FARWARD_BIN" list)"
assert_contains "$stale_list" "manual-stale"
assert_contains "$stale_list" "stale"
stale_stop="$("$FARWARD_BIN" stop manual-stale)"
assert_contains "$stale_stop" "was not running"
[[ ! -d "$FARWARD_STATE_DIR/manual-stale" ]] || {
    printf 'stale stop should remove state\n' >&2
    exit 1
}

printf 'checking stop does not signal an unverified pid\n'
sleep 30 &
guard_pid=$!
mkdir -p "$FARWARD_STATE_DIR/guarded"
printf 'id=guarded\npid=%s\nhost=ghost\nstarted=%s\nbind=localhost\nversion=1\n' "$guard_pid" "$(date +%s)" \
    >"$FARWARD_STATE_DIR/guarded/meta"
printf '%s\n' "-L" "localhost:12346:localhost:8347" >"$FARWARD_STATE_DIR/guarded/forwards"
printf '%s\n' "-o" "BatchMode=yes" >"$FARWARD_STATE_DIR/guarded/args"
: >"$FARWARD_STATE_DIR/guarded/log"
"$FARWARD_BIN" stop guarded >/dev/null
if ! kill -0 "$guard_pid" 2>/dev/null; then
    printf 'stop killed an unverified pid\n' >&2
    exit 1
fi
kill "$guard_pid" 2>/dev/null || true
wait "$guard_pid" 2>/dev/null || true

printf 'checking session id path traversal is rejected\n'
set +e
traversal_output="$("$FARWARD_BIN" stop ../escape 2>&1)"
traversal_status=$?
set -e
[[ "$traversal_status" -ne 0 ]] || {
    printf 'expected invalid session id to fail\n' >&2
    exit 1
}
assert_contains "$traversal_output" "No unique session matches"

printf 'checking automatic reconnect after the ssh child dies\n'
reconnect_port="$(unique_free_port)"
reconnect_output="$(start_test_session "$reconnect_port")"
reconnect_id="$(session_id_from_output "$reconnect_output")"
[[ -n "$reconnect_id" ]] || {
    printf 'reconnect test could not parse session id\n%s\n' "$reconnect_output" >&2
    exit 1
}
reconnect_old_ssh="$(meta_value "$reconnect_id" ssh_pid)"
[[ -n "$reconnect_old_ssh" ]] && kill -0 "$reconnect_old_ssh" 2>/dev/null || {
    printf 'expected an ssh child for reconnect test\n' >&2
    exit 1
}
kill "$reconnect_old_ssh"
if ! reconnect_new_ssh="$(wait_for_session_field "$reconnect_id" ssh_pid "$reconnect_old_ssh" 100)"; then
    printf 'ssh child was not replaced after a drop\n' >&2
    "$FARWARD_BIN" logs "$reconnect_id" >&2 || true
    exit 1
fi
[[ "$reconnect_new_ssh" != "$reconnect_old_ssh" ]] || {
    printf 'reconnect reused the dead ssh pid\n' >&2
    exit 1
}
assert_contains "$(wait_for_banner "$reconnect_port" 50)" "farward-smoke:localhost:8347"
assert_contains "$("$FARWARD_BIN" list)" "alive"
"$FARWARD_BIN" stop "$reconnect_id" >/dev/null
[[ ! -d "$FARWARD_STATE_DIR/$reconnect_id" ]] || {
    printf 'reconnect test session was not stopped\n' >&2
    exit 1
}

printf 'checking stop cleans up an orphaned ssh after a supervisor SIGKILL\n'
orphan_port="$(unique_free_port)"
orphan_output="$(start_test_session "$orphan_port")"
orphan_id="$(session_id_from_output "$orphan_output")"
[[ -n "$orphan_id" ]] || {
    printf 'orphan test could not parse session id\n%s\n' "$orphan_output" >&2
    exit 1
}
orphan_supervisor="$(meta_value "$orphan_id" pid)"
orphan_ssh="$(meta_value "$orphan_id" ssh_pid)"
[[ -n "$orphan_supervisor" && -n "$orphan_ssh" ]] || {
    printf 'orphan test expected supervisor and ssh pids\n' >&2
    exit 1
}
kill -9 "$orphan_supervisor"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$orphan_supervisor" 2>/dev/null || break
    sleep 0.1
done
kill -0 "$orphan_ssh" 2>/dev/null || {
    printf 'orphaned ssh child exited unexpectedly\n' >&2
    exit 1
}
assert_contains "$("$FARWARD_BIN" list)" "stale"
"$FARWARD_BIN" stop "$orphan_id" >/dev/null
if kill -0 "$orphan_ssh" 2>/dev/null; then
    printf 'stop left an orphaned ssh child behind\n' >&2
    exit 1
fi
[[ ! -d "$FARWARD_STATE_DIR/$orphan_id" ]] || {
    printf 'orphan cleanup did not remove session state\n' >&2
    exit 1
}

printf 'checking deleted session state stops the supervisor\n'
watchdog_port="$(unique_free_port)"
watchdog_output="$(start_test_session "$watchdog_port")"
watchdog_id="$(session_id_from_output "$watchdog_output")"
[[ -n "$watchdog_id" ]] || {
    printf 'watchdog test could not parse session id\n%s\n' "$watchdog_output" >&2
    exit 1
}
watchdog_supervisor="$(meta_value "$watchdog_id" pid)"
watchdog_ssh="$(meta_value "$watchdog_id" ssh_pid)"
rm -rf "${FARWARD_STATE_DIR:?}/$watchdog_id"
watchdog_stopped=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 "$watchdog_supervisor" 2>/dev/null && ! kill -0 "$watchdog_ssh" 2>/dev/null; then
        watchdog_stopped=true
        break
    fi
    sleep 0.2
done
[[ "$watchdog_stopped" == true ]] || {
    printf 'supervisor kept running after its state directory was deleted\n' >&2
    kill "$watchdog_supervisor" "$watchdog_ssh" 2>/dev/null || true
    exit 1
}

printf 'checking --retry 0 disables reconnects\n'
retry_zero_port="$(unique_free_port)"
retry_zero_output="$(start_test_session "$retry_zero_port" --retry 0)"
retry_zero_id="$(session_id_from_output "$retry_zero_output")"
[[ -n "$retry_zero_id" ]] || {
    printf '--retry 0 test could not parse session id\n%s\n' "$retry_zero_output" >&2
    exit 1
}
[[ "$(meta_value "$retry_zero_id" retries)" == "0" ]] || {
    printf 'expected retries=0 in session state\n' >&2
    exit 1
}
retry_zero_ssh="$(meta_value "$retry_zero_id" ssh_pid)"
kill "$retry_zero_ssh"
wait_for_session_status "$retry_zero_id" failed 100 || {
    printf 'session with --retry 0 did not become failed\n%s\n' \
        "$(status_value "$retry_zero_id" state)" >&2
    exit 1
}
assert_contains "$("$FARWARD_BIN" list)" "failed"
[[ -d "$FARWARD_STATE_DIR/$retry_zero_id" ]] || {
    printf 'failed session state should be retained\n' >&2
    exit 1
}
printf 'checking restart of a failed session\n'
PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
    "$FARWARD_BIN" restart "$retry_zero_id" >/dev/null
assert_contains "$(status_value "$retry_zero_id" state)" "connected"
assert_contains "$(wait_for_banner "$retry_zero_port" 50)" "farward-smoke:localhost:8347"
assert_contains "$("$FARWARD_BIN" list)" "alive"
"$FARWARD_BIN" stop "$retry_zero_id" >/dev/null
[[ ! -d "$FARWARD_STATE_DIR/$retry_zero_id" ]] || {
    printf 'failed session was not cleaned up by stop\n' >&2
    exit 1
}

printf 'checking --retry 1 allows exactly one reconnect\n'
retry_one_port="$(unique_free_port)"
retry_one_output="$(start_test_session "$retry_one_port" --retry 1)"
retry_one_id="$(session_id_from_output "$retry_one_output")"
[[ -n "$retry_one_id" ]] || {
    printf '--retry 1 test could not parse session id\n%s\n' "$retry_one_output" >&2
    exit 1
}
retry_one_ssh="$(meta_value "$retry_one_id" ssh_pid)"
kill "$retry_one_ssh"
if ! retry_one_second="$(wait_for_session_field "$retry_one_id" ssh_pid "$retry_one_ssh" 100)"; then
    printf '--retry 1 did not reconnect once\n' >&2
    exit 1
fi
assert_contains "$(wait_for_banner "$retry_one_port" 50)" "farward-smoke:localhost:8347"
kill "$retry_one_second"
wait_for_session_status "$retry_one_id" failed 100 || {
    printf '--retry 1 did not exhaust its budget\n' >&2
    exit 1
}
assert_contains "$("$FARWARD_BIN" list)" "failed"
"$FARWARD_BIN" stop "$retry_one_id" >/dev/null

printf 'checking --retry-forever survives repeated drops\n'
forever_port="$(unique_free_port)"
forever_output="$(start_test_session "$forever_port" --retry-forever)"
forever_id="$(session_id_from_output "$forever_output")"
[[ -n "$forever_id" ]] || {
    printf '--retry-forever test could not parse session id\n%s\n' "$forever_output" >&2
    exit 1
}
[[ "$(meta_value "$forever_id" retries)" == "-1" ]] || {
    printf 'expected retries=-1 in session state\n' >&2
    exit 1
}
forever_first="$(meta_value "$forever_id" ssh_pid)"
kill "$forever_first"
if ! forever_second="$(wait_for_session_field "$forever_id" ssh_pid "$forever_first" 100)"; then
    printf '--retry-forever did not reconnect after the first drop\n' >&2
    exit 1
fi
assert_contains "$(wait_for_banner "$forever_port" 50)" "farward-smoke:localhost:8347"
kill "$forever_second"
if ! wait_for_session_field "$forever_id" ssh_pid "$forever_second" 100 >/dev/null; then
    printf '--retry-forever did not reconnect after the second drop\n' >&2
    exit 1
fi
assert_contains "$(wait_for_banner "$forever_port" 50)" "farward-smoke:localhost:8347"
assert_contains "$("$FARWARD_BIN" list)" "alive"
"$FARWARD_BIN" stop "$forever_id" >/dev/null

printf 'checking retry budget survives restart\n'
retry_persist_port="$(unique_free_port)"
retry_persist_output="$(start_test_session "$retry_persist_port" --retry 5)"
retry_persist_id="$(session_id_from_output "$retry_persist_output")"
[[ -n "$retry_persist_id" ]] || {
    printf 'retry persistence test could not parse session id\n%s\n' "$retry_persist_output" >&2
    exit 1
}
[[ "$(meta_value "$retry_persist_id" retries)" == "5" ]] || {
    printf 'expected retries=5 before restart\n' >&2
    exit 1
}
PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
    "$FARWARD_BIN" restart "$retry_persist_id" >/dev/null
[[ "$(meta_value "$retry_persist_id" retries)" == "5" ]] || {
    printf 'restart should preserve the retry budget\n' >&2
    exit 1
}
"$FARWARD_BIN" stop "$retry_persist_id" >/dev/null

printf 'checking invalid retry values are rejected\n'
invalid_retry_port="$(unique_free_port)"
for bad_retry in -1 abc 1.5; do
    set +e
    bad_retry_output="$(
        PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
            "$FARWARD_BIN" --retry "$bad_retry" --no-docker --port "8347:$invalid_retry_port" \
            --background fakehost 2>&1
    )"
    bad_retry_status=$?
    set -e
    [[ "$bad_retry_status" -ne 0 ]] || {
        printf 'expected --retry %s to fail\n' "$bad_retry" >&2
        exit 1
    }
    assert_contains "$bad_retry_output" "--retry"
done

printf 'checking foreground retry note\n'
note_output="$(
    PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
        "$FARWARD_BIN" --retry 2 --no-docker --port "8347:$invalid_retry_port" --dry-run fakehost 2>&1
)"
assert_contains "$note_output" "auto-reconnect applies to --background sessions"

printf 'smoke checks passed\n'
