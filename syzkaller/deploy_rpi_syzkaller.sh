#!/usr/bin/env bash
#
# Stand up syzkaller against a REAL Raspberry Pi 4 (arm64) board, fuzzed over SSH
# via syzkaller's "isolated" VM type (no QEMU — syz-manager just talks to the Pi
# that's already running your instrumented kernel).
#
# Stages (all reuse existing scripts):
#   build_syzkaller.sh    install Go + clone/build syzkaller for arm64
#   kernel (deploy)       ../linux/deploy-rpi-kernel.sh, with the syzkaller
#                         KCOV/KASAN fragment merged in, cross-built and pushed
#                         to the Pi's brick-safe tryboot slot
#   config                write the syz-manager (isolated) config.cfg
#
# Required env:
#   DEPLOY_TARGET=user@host   ssh target of the Pi (e.g. ubuntu@100.x.y.z)
#   KSRC=/path/to/linux       arm64 kernel source tree (also used as kernel_obj
#                             for vmlinux symbolization)
#
# Optional env:
#   SSHKEY=~/.ssh/id_ecdsa    private key syz-manager uses to reach the Pi
#   SSH_USER=<from target>    SSH user syzkaller logs in as. NOTE: coverage needs
#                             read access to /sys/kernel/debug/kcov, which usually
#                             means root. Set SSH_USER=root (with key auth enabled)
#                             if the default user can't read kcov.
#   TARGET_DIR=/tmp/syzkaller writable scratch dir on the Pi
#   HTTP WORKDIR CONFIG PROCS REBOOT
#
# After this finishes, the Pi has tryboot-ed into the instrumented kernel once.
# VERIFY it, then make it PERMANENT before fuzzing (a single panic otherwise
# reverts the Pi to the old non-instrumented kernel):
#   ssh $DEPLOY_TARGET uname -r          # confirm it's the new kernel
#   ../linux/deploy-rpi-kernel.sh --promote --target $DEPLOY_TARGET
#   ./run_syzkaller.sh                   # dashboard at the "http" address
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$BUILD_DIR/syzkaller"
FRAGMENT="$SCRIPT_DIR/kernel-syzkaller.config"
RPI_DEPLOY="$SCRIPT_DIR/../linux/deploy-rpi-kernel.sh"

DEPLOY_TARGET="${DEPLOY_TARGET:-}"
KSRC="${KSRC:-}"
SSHKEY="${SSHKEY:-$HOME/.ssh/id_ecdsa}"
TARGET_DIR="${TARGET_DIR:-/tmp/syzkaller}"
HTTP="${HTTP:-127.0.0.1:56741}"
WORKDIR="${WORKDIR:-$BUILD_DIR/workdir}"
CONFIG="${CONFIG:-$BUILD_DIR/config.cfg}"
PROCS="${PROCS:-4}"
# Let syz-manager hard-reboot the Pi to recover from a hang? Off by default so a
# crash leaves the board for you to inspect; flip to true for unattended runs.
REBOOT="${REBOOT:-false}"

msg() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "$DEPLOY_TARGET" ]] || die "set DEPLOY_TARGET=user@host (the Pi)"
[[ -n "$KSRC" ]]          || die "set KSRC=/path/to/arm64/linux tree"
[[ -f "$SSHKEY" ]]        || die "ssh key not found: $SSHKEY (set SSHKEY=...)"
[[ -x "$RPI_DEPLOY" ]]    || die "rpi kernel deploy script missing: $RPI_DEPLOY"
[[ -f "$FRAGMENT" ]]      || die "syzkaller config fragment missing: $FRAGMENT"

HOST="${DEPLOY_TARGET#*@}"
SSH_USER="${SSH_USER:-${DEPLOY_TARGET%@*}}"

# --- build syzkaller for arm64 (shared with the QEMU path) ------------------
stage_build() {
    BUILD_DIR="$BUILD_DIR" TARGETARCH=arm64 "$SCRIPT_DIR/common/build_syzkaller.sh"
}

# --- kernel: cross-build with KCOV/KASAN merged, deploy to the Pi -----------
# Delegates entirely to the brick-safe tryboot deploy; we only add the fragment.
stage_kernel() {
    CONFIG_FRAGMENTS="$FRAGMENT" KSRC="$KSRC" ARCH=arm64 \
        CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}" \
        "$RPI_DEPLOY" --target "$DEPLOY_TARGET"
}

# --- config: write the isolated syz-manager config wired to the Pi ----------
stage_config() {
    [[ -x "$SRC_DIR/bin/syz-manager" ]] || die "syz-manager not built"
    [[ -f "$KSRC/vmlinux" ]]            || die "vmlinux not found in $KSRC (build first?)"

    mkdir -p "$WORKDIR"
    cat > "$CONFIG" <<EOF
{
    "target": "linux/arm64",
    "http": "$HTTP",
    "workdir": "$WORKDIR",
    "kernel_obj": "$KSRC",
    "sshkey": "$SSHKEY",
    "ssh_user": "$SSH_USER",
    "syzkaller": "$SRC_DIR",
    "procs": $PROCS,
    "type": "isolated",
    "vm": {
        "targets": ["$HOST"],
        "pstore": false,
        "target_dir": "$TARGET_DIR",
        "target_reboot": $REBOOT
    }
}
EOF
    msg "Wrote $CONFIG"
    cat "$CONFIG"
}

main() {
    msg "starting stage: build_syzkaller (arm64)"
    stage_build
    msg "starting stage: kernel (cross-build + tryboot deploy to $DEPLOY_TARGET)"
    stage_kernel
    msg "starting stage: config (isolated)"
    stage_config
    cat <<EOF

$(msg "Done — the Pi tryboot-ed into the instrumented kernel once.")
  1. Verify:   ssh $DEPLOY_TARGET 'uname -r'
  2. Promote (make permanent — REQUIRED before fuzzing; a panic else reverts it):
       $RPI_DEPLOY --promote --target $DEPLOY_TARGET
  3. Fuzz:     ./run_syzkaller.sh        # dashboard at http://$HTTP
EOF
}

main "$@"
