#!/usr/bin/env bash
#
# Orchestrator: run the syzkaller *setup* scripts one by one, in order. This
# stops after the config is written; launch the fuzzer yourself with
# ./6-run_syzkaller.sh once you're ready.
#
# Stages (each is its own script, runnable standalone):
#   1-install_go.sh              install the latest Go toolchain from go.dev
#   2-build_syzkaller.sh         clone + build syzkaller
#   3-build_syzkaller_kernel.sh  clone a kernel branch, merge syzkaller config, build
#   4-create_image.sh            debootstrap an SSH-able rootfs image
#   5-gen_config.sh              write syz-manager config.cfg
#
# Each stage reads its own env vars (REF, KERNEL_BRANCH, RELEASE, VMS, ...);
# export them before invoking this script and they flow straight through.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ordered stage list: name -> script.
STAGES=(go syzkaller kernel image config)
declare -A STAGE_SCRIPT=(
    [go]="1-install_go.sh"
    [syzkaller]="2-build_syzkaller.sh"
    [kernel]="3-build_syzkaller_kernel.sh"
    [image]="4-create_image.sh"
    [config]="5-gen_config.sh"
)

# Where 1-install_go.sh drops the toolchain; make it visible to later stages.
GOROOT="${GOROOT:-/usr/local/go}"
export PATH="$GOROOT/bin:$PATH"

msg()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

main() {
    for name in "${STAGES[@]}"; do
        STAGE_SCRIPT_PATH="$SCRIPT_DIR/${STAGE_SCRIPT[$name]}"
        msg "starting stage: $name"
        "$STAGE_SCRIPT_PATH"
    done
}

main "$@"
