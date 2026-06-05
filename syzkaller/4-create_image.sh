#!/usr/bin/env bash
#
# Build a bootable, SSH-able Debian rootfs image for syzkaller's QEMU VMs.
#
# Thin wrapper around syzkaller's own tools/create-image.sh (debootstrap based)
# that drops the artifacts into build/image/ next to this script:
#   build/image/<release>.img      ext4 rootfs
#   build/image/<release>.id_rsa   SSH private key syz-manager logs in with
#
# Run 2-build_syzkaller.sh first so the upstream tool is available.
#
# Usage:
#   ./4-create_image.sh                       # bullseye, default size
#   RELEASE=bookworm ./4-create_image.sh
#
# Requires (Debian/Ubuntu): debootstrap, qemu-utils. Needs sudo for the
# loopback mount during rootfs creation.
#
# Reference:
#   https://github.com/google/syzkaller/blob/master/docs/linux/setup_ubuntu-host_qemu-vm_x86-64-kernel.md
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/build/syzkaller"
IMG_DIR="$SCRIPT_DIR/build/image"
RELEASE="${RELEASE:-bullseye}"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

check_deps() {
    local missing=()
    command -v debootstrap >/dev/null || missing+=("debootstrap")
    command -v qemu-img    >/dev/null || missing+=("qemu-utils")
    if (( ${#missing[@]} )); then
        die "missing dependencies. Install with:
    sudo apt update && sudo apt install -y ${missing[*]}"
    fi
}

main() {
    check_deps
    [[ -f "$SRC_DIR/tools/create-image.sh" ]] \
        || die "syzkaller checkout not found; run ./2-build_syzkaller.sh first"

    mkdir -p "$IMG_DIR"
    msg "Creating $RELEASE rootfs (sudo required for loopback mount)"

    # create-image.sh writes into the current directory, so run it from IMG_DIR.
    ( cd "$IMG_DIR" \
        && "$SRC_DIR/tools/create-image.sh" --distribution "$RELEASE" "$@" )

    msg "Done."
    msg "image   : $IMG_DIR/$RELEASE.img"
    msg "ssh key : $IMG_DIR/$RELEASE.id_rsa"
}

main "$@"
