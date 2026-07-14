#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FARWARD_BIN="${FARWARD_BIN:-$ROOT_DIR/farward}"
SMOKE_DIR="${FARWARD_SMOKE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/farward-smoke.XXXXXX")}"
MOCK_BIN="$SMOKE_DIR/bin"

cleanup() {
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

stop_live_ssh_forward() {
    local local_port="$1"
    local target_port="$2"
    local pid command

    while IFS= read -r line; do
        pid="${line%% *}"
        command="${line#* }"
        case "$command" in
            *"ssh "*"localhost:${local_port}:localhost:${target_port}"*)
                kill "$pid" 2>/dev/null || true
                ;;
        esac
    done < <(ps -ax -o pid= -o command= 2>/dev/null || true)
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
    if [[ "$*" == *"docker ps --format"* ]]; then
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
IFS= read -r first
printf '%s\n' "$first"
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
kill "$(cat "$SMOKE_DIR/ssh.pid")" 2>/dev/null || true
rm -f "$SMOKE_DIR/ssh.pid" "$SMOKE_DIR/ssh-args.log"

printf 'checking background forwarding success on local port %s\n' "$background_port"
PATH="$MOCK_BIN:$PATH" FARWARD_SMOKE_DIR="$SMOKE_DIR" \
    "$FARWARD_BIN" --no-docker --target-host 10.0.0.5 --port "8347:$background_port" --background fakehost
nc -z 127.0.0.1 "$background_port"
background_banner="$(read_forward_banner "$background_port")"
assert_contains "$background_banner" "farward-smoke:10.0.0.5:8347"
background_args="$(cat "$SMOKE_DIR/ssh-args.log")"
assert_contains "$background_args" "-L localhost:$background_port:10.0.0.5:8347 fakehost"
kill "$(cat "$SMOKE_DIR/ssh.pid")" 2>/dev/null || true
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
[[ ! -f "$SMOKE_DIR/ssh.pid" ]] || kill "$(cat "$SMOKE_DIR/ssh.pid")" 2>/dev/null || true
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
    printf 'live OpenSSH custom-port data path passed\n'
    stop_live_ssh_forward "$live_local_port" "$live_target_port"
    kill "$live_target_pid" 2>/dev/null || true
    wait "$live_target_pid" 2>/dev/null || true
    rm -f "$SMOKE_DIR/live-target.pid"
    fi
else
    printf 'skipping live OpenSSH custom-port data path; sshd or ssh-keygen is not available\n'
fi

printf 'smoke checks passed\n'
