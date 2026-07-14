#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/farward"

mkdir -p "$INSTALL_DIR"
mkdir -p "$DATA_DIR"
install -m 0755 "$SOURCE_DIR/farward" "$INSTALL_DIR/farward"
install -m 0755 "$SOURCE_DIR/tests/smoke.sh" "$DATA_DIR/smoke.sh"
ln -sf "$INSTALL_DIR/farward" "$INSTALL_DIR/dockport"
ln -sf "$INSTALL_DIR/farward" "$INSTALL_DIR/sail-ports"

printf 'Installed Farward to %s\n' "$INSTALL_DIR/farward"
printf 'Installed smoke test to %s\n' "$DATA_DIR/smoke.sh"
printf 'Installed compatibility aliases:\n'
printf '  dockport   -> farward\n'
printf '  sail-ports -> farward\n'

case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *)
        printf '\nAdd this to your shell configuration:\n'
        printf '  export PATH="$HOME/.local/bin:$PATH"\n'
        ;;
esac

printf '\nRun it with:\n  farward user@remote-host\n'
printf '\nVerify it with:\n  farward --self-test\n'
printf '\nDashboard controls:\n  :q + Enter  stop tunnels and exit\n  Ctrl+C      stop tunnels and exit\n'
