#!/usr/bin/env bash
#
# Launch syz-manager with the generated config. The web dashboard is served at
# the "http" address in config.cfg (default http://127.0.0.1:56741).
#
# Always runs as root (re-execs itself under sudo): syz-manager owns the QEMU
# VMs and writes a root-owned workdir, so we keep it consistent by forcing root.
#
# Usage:
#   ./run_syzkaller.sh                      # use ./build/config.cfg
#   ./run_syzkaller.sh -- -debug            # pass extra flags to syz-manager
#   CONFIG=other.cfg ./run_syzkaller.sh
#
set -euo pipefail

# Force root. Re-exec under sudo (preserving CONFIG) when not already root.
if [[ $EUID -ne 0 ]]; then
    exec sudo --preserve-env=CONFIG "$(realpath "${BASH_SOURCE[0]}")" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/build/syzkaller"
CONFIG="${CONFIG:-$SCRIPT_DIR/build/config.cfg}"
QEMU_BIN_DIR="$SCRIPT_DIR/../qemu/install/bin"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -x "$SRC_DIR/bin/syz-manager" ]] || die "syz-manager not built; run ./2-build_syzkaller.sh"
[[ -f "$CONFIG" ]]                  || die "config not found: $CONFIG; run ./5-gen_config.sh"

# Make the locally built QEMU discoverable even if config.cfg relies on PATH.
[[ -d "$QEMU_BIN_DIR" ]] && export PATH="$QEMU_BIN_DIR:$PATH"

# Preflight: for isolated targets, syz-manager just retries silently when SSH
# fails (e.g. Tailscale SSH wanting a browser re-auth). Fail loudly instead.
if command -v jq >/dev/null && [[ "$(jq -r '.type' "$CONFIG")" == "isolated" ]]; then
    read -r host user key < <(jq -r '[.vm.targets[0], .ssh_user, .sshkey] | @tsv' "$CONFIG")
    ssh -i "$key" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 \
        "$user@$host" true 2>/dev/null \
        || die "SSH to $user@$host failed; fix connectivity before fuzzing (Tailscale SSH may need ACL 'accept' instead of 'check')"
fi

# Drop the leading `--` separator if present so callers can pass extra flags.
[[ "${1:-}" == "--" ]] && shift

exec "$SRC_DIR/bin/syz-manager" -config "$CONFIG" "$@"
