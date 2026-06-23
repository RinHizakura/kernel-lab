#!/usr/bin/env bash
#
# Stand up a full QEMU-VM syzkaller setup, ready to fuzz. Runs build_syzkaller.sh,
# then builds a syzkaller-ready kernel, a debootstrap rootfs image, and writes the
# syz-manager config. Stops here; launch the fuzzer with ./run_syzkaller.sh.
#
# Stages (all inlined below):
#   build_syzkaller.sh   install Go + clone/build syzkaller
#   kernel               clone a kernel branch, merge syz config fragment, build
#   image                debootstrap an SSH-able rootfs for the QEMU VMs
#   config               write the syz-manager (qemu) config.cfg
#
# Env knobs flow through to each stage:
#   kernel : KERNEL_REPO KERNEL_BRANCH ARCH CROSS_COMPILE
#   image  : RELEASE (debian suite, default bullseye)
#   config : TARGET HTTP WORKDIR CONFIG VMS PROCS CPU MEM CMDLINE QEMU
#
# For a real board instead of QEMU, use the isolated deploy path, not this one.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$BUILD_DIR/syzkaller"
KERNEL="$BUILD_DIR/linux"
IMG_DIR="$BUILD_DIR/image"
FRAGMENT="$SCRIPT_DIR/kernel-syzkaller.config"
BUILDER="$SCRIPT_DIR/../linux/build_kernel.sh"

RELEASE="${RELEASE:-bullseye}"
TARGET="${TARGET:-linux/amd64}"
HTTP="${HTTP:-127.0.0.1:56741}"
WORKDIR="${WORKDIR:-$BUILD_DIR/workdir}"
CONFIG="${CONFIG:-$BUILD_DIR/config.cfg}"
VMS="${VMS:-2}"
PROCS="${PROCS:-4}"
CPU="${CPU:-2}"
MEM="${MEM:-2048}"
# net.ifnames=0 keeps the NIC named eth0 so the image's /etc/network/interfaces
# matches; otherwise udev renames it, ifup fails and syz-manager can't SSH in.
CMDLINE="${CMDLINE:-net.ifnames=0}"
# Prefer a locally built QEMU; fall back to PATH.
QEMU="${QEMU:-$SCRIPT_DIR/../qemu/install/bin/qemu-system-x86_64}"

GOROOT="/usr/local/go"
export PATH="$GOROOT/bin:$PATH"

msg() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- kernel: merge syzkaller's fragment on top of defconfig, build ----------
stage_kernel() {
    [[ -x "$BUILDER" ]]  || die "generic kernel builder not found: $BUILDER"
    [[ -f "$FRAGMENT" ]] || die "syzkaller config fragment missing: $FRAGMENT"
    BUILD_DIR="$BUILD_DIR" CONFIG_FRAGMENTS="$FRAGMENT" "$BUILDER"
}

# --- image: debootstrap an SSH-able rootfs via syzkaller's own tool ----------
stage_image() {
    command -v debootstrap >/dev/null || die "missing debootstrap (sudo apt install debootstrap)"
    command -v qemu-img    >/dev/null || die "missing qemu-img (sudo apt install qemu-utils)"
    [[ -f "$SRC_DIR/tools/create-image.sh" ]] || die "syzkaller checkout missing; build stage failed?"
    mkdir -p "$IMG_DIR"
    msg "Creating $RELEASE rootfs (sudo required for loopback mount)"
    # create-image.sh writes into the current directory.
    ( cd "$IMG_DIR" && "$SRC_DIR/tools/create-image.sh" --distribution "$RELEASE" )
    msg "image: $IMG_DIR/$RELEASE.img  ssh key: $IMG_DIR/$RELEASE.id_rsa"
}

# --- config: write syz-manager config.cfg wired to the artifacts above ------
stage_config() {
    [[ -x "$SRC_DIR/bin/syz-manager" ]] || die "syz-manager not built"
    [[ -f "$KERNEL/vmlinux" ]]          || die "vmlinux not found in $KERNEL"
    local bzimage="$KERNEL/arch/x86/boot/bzImage"
    [[ -f "$bzimage" ]]                 || die "bzImage not found: $bzimage"
    [[ -f "$IMG_DIR/$RELEASE.img" ]]    || die "image not found; image stage failed?"
    [[ -f "$IMG_DIR/$RELEASE.id_rsa" ]] || die "ssh key not found: $IMG_DIR/$RELEASE.id_rsa"

    # Emit the "qemu" field only when we actually have a binary to point at.
    local qemu_line=""
    if [[ -x "$QEMU" ]]; then
        qemu_line="        \"qemu\": \"$QEMU\","
    else
        msg "warning: $QEMU not executable; relying on PATH qemu-system-x86_64"
    fi

    mkdir -p "$WORKDIR"
    cat > "$CONFIG" <<EOF
{
    "target": "$TARGET",
    "http": "$HTTP",
    "workdir": "$WORKDIR",
    "kernel_obj": "$KERNEL",
    "image": "$IMG_DIR/$RELEASE.img",
    "sshkey": "$IMG_DIR/$RELEASE.id_rsa",
    "syzkaller": "$SRC_DIR",
    "procs": $PROCS,
    "type": "qemu",
    "vm": {
        "count": $VMS,
$qemu_line
        "kernel": "$bzimage",
        "cmdline": "$CMDLINE",
        "cpu": $CPU,
        "mem": $MEM
    }
}
EOF
    msg "Wrote $CONFIG"
    cat "$CONFIG"
}

main() {
    msg "starting stage: build_syzkaller"
    BUILD_DIR="$BUILD_DIR" "$SCRIPT_DIR/common/build_syzkaller.sh"
    msg "starting stage: kernel"
    stage_kernel
    msg "starting stage: image"
    stage_image
    msg "starting stage: config"
    stage_config
    msg "Done. Launch the fuzzer with ./run_syzkaller.sh"
}

main "$@"
