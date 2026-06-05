#!/usr/bin/env bash
#
# Build a syzkaller-ready Linux kernel. Layer syzkaller's required config
# fragment on top.
#
# Layout (relative to this script):
#   build/linux/          kernel checkout + build (where 5-gen_config.sh looks)
#
# All of the generic builder's knobs still apply and flow straight through:
#   KERNEL_BRANCH=linux-6.6.y ./3-build_syzkaller_kernel.sh
#   KERNEL_REPO=https://.../torvalds/linux.git ./3-build_syzkaller_kernel.sh
#   ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ./3-build_syzkaller_kernel.sh
#   JOBS=8 ./3-build_syzkaller_kernel.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="$SCRIPT_DIR/../linux/build_kernel.sh"
FRAGMENT="$SCRIPT_DIR/kernel-syzkaller.config"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -x "$BUILDER" ]]  || die "generic kernel builder not found: $BUILDER"
[[ -f "$FRAGMENT" ]] || die "syzkaller config fragment missing: $FRAGMENT"

# Build into this dir's build/ (5-gen_config.sh expects build/linux), and let the
# generic builder merge syzkaller's fragment on top of defconfig.
export BUILD_DIR="$SCRIPT_DIR/build"
export CONFIG_FRAGMENTS="$FRAGMENT"

exec "$BUILDER" "$@"
