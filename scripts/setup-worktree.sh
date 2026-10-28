#!/usr/bin/env bash
#
# Prepare a Farward checkout (including each Orca worktree) for development.
#
# Orca runs this automatically when it creates a worktree; see orca.yaml.
# It is also safe to run by hand from any checkout:
#
#   scripts/setup-worktree.sh
#
# Farward is a single Bash program with no build step or package manager.
# This script therefore verifies the toolchain, restores executable bits,
# and syntax-checks the shell sources. It never installs anything globally,
# so a worktree cannot overwrite the user's ~/.local/bin/farward.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

printf 'Farward worktree setup\n'
printf '  checkout: %s\n\n' "$ROOT_DIR"

missing_required=0

check_command() {
    local cmd="$1" need="$2" why="$3"

    if command -v "$cmd" >/dev/null 2>&1; then
        printf '  ok    %-8s %s\n' "$cmd" "$why"
    elif [[ "$need" == required ]]; then
        printf '  MISS  %-8s %s\n' "$cmd" "$why" >&2
        missing_required=$((missing_required + 1))
    else
        printf '  --    %-8s %s (optional)\n' "$cmd" "$why"
    fi
}

printf 'Checking tools\n'
check_command bash required 'runs farward and the tests'
check_command git required 'worktree and version control'
check_command ssh required 'creates the tunnels'
check_command fzf optional 'interactive Docker/listener selector'
check_command docker optional 'discovers published container ports'
check_command nohup optional 'background tunnels'
check_command python3 optional 'smoke tests and local port allocation'

printf '\nPreparing shell sources\n'
for file in farward install.sh tests/smoke.sh scripts/setup-worktree.sh; do
    if [[ ! -f "$file" ]]; then
        printf '  MISS  %s\n' "$file" >&2
        missing_required=$((missing_required + 1))
        continue
    fi

    chmod +x "$file"
    if bash -n "$file"; then
        printf '  ok    %s\n' "$file"
    else
        printf '  FAIL  %s (syntax error)\n' "$file" >&2
        missing_required=$((missing_required + 1))
    fi
done

printf '\nChecking the farward entry point\n'
if ./farward --help >/dev/null 2>&1; then
    printf '  ok    ./farward --help\n'
else
    printf '  FAIL  ./farward --help\n' >&2
    missing_required=$((missing_required + 1))
fi

if [[ "${FARWARD_SETUP_SMOKE:-0}" == 1 ]]; then
    printf '\nRunning the smoke test (FARWARD_SETUP_SMOKE=1)\n'
    tests/smoke.sh
fi

if ((missing_required > 0)); then
    printf '\nSetup finished with %d problem(s). Fix them, then run scripts/setup-worktree.sh again.\n' "$missing_required" >&2
    exit 1
fi

cat <<'DONE'

Setup complete.

  Try it:      ./farward user@remote-host
  Help:        ./farward --help
  Smoke test:  tests/smoke.sh
  Install:     ./install.sh   (only if you want it on PATH)
DONE
