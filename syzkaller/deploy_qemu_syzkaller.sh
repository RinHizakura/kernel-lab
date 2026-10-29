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
#   kernel : KSRC (else a clone under build/linux) KERNEL_REPO KERNEL_BRANCH ARCH CROSS_COMPILE
#   image  : RELEASE (debian suite, default bullseye)
#   config : TARGET HTTP WORKDIR CONFIG VMS PROCS CPU MEM CMDLINE QEMU
#
# For a real board instead of QEMU, use the isolated deploy path, not this one.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$BUILD_DIR/syzkaller"
IMG_DIR="$BUILD_DIR/image"
FRAGMENT="$SCRIPT_DIR/config/kernel-syzkaller.config"
# The kernel builder as a library: kbuild_main builds (cloning into
# $BUILD_DIR/linux unless KSRC is set), then $KOUT and kbuild_kimg say where
# the artifacts are. It also sources lib.sh.
# shellcheck source=../linux/build_kernel.sh
source "$SCRIPT_DIR/../linux/build_kernel.sh"

RELEASE="${RELEASE:-bullseye}"
TARGET="${TARGET:-linux/$(arch_name go "$ARCH")}"
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
QEMU_SYSTEM="qemu-system-$(arch_name qemu "$ARCH")"
QEMU="${QEMU:-$SCRIPT_DIR/../qemu/install_$ARCH/bin/$QEMU_SYSTEM}"

GOROOT="/usr/local/go"
export PATH="$GOROOT/bin:$PATH"

# --- kernel: merge syzkaller's fragment on top of defconfig, build ----------
stage_kernel() {
    [[ -f "$FRAGMENT" ]] || die "syzkaller config fragment missing: $FRAGMENT"
    CONFIG_FRAGMENTS="$FRAGMENT" kbuild_main
}

# --- image: debootstrap an SSH-able rootfs via syzkaller's own tool ----------
stage_image() {
    need_tools debootstrap qemu-img:qemu-utils
    [[ -f "$SRC_DIR/tools/create-image.sh" ]] || die "syzkaller checkout missing; build stage failed?"
    mkdir -p "$IMG_DIR"
    log "Creating $RELEASE rootfs (sudo required for loopback mount)"
    # create-image.sh writes into the current directory.
    ( cd "$IMG_DIR" && "$SRC_DIR/tools/create-image.sh" --distribution "$RELEASE" )
    log "image: $IMG_DIR/$RELEASE.img  ssh key: $IMG_DIR/$RELEASE.id_rsa"
}

# --- config: write syz-manager config.cfg wired to the artifacts above ------
stage_config() {
    [[ -x "$SRC_DIR/bin/syz-manager" ]] || die "syz-manager not built"
    [[ -f "$KOUT/vmlinux" ]]            || die "vmlinux not found in $KOUT"
    local bzimage; bzimage="$(kbuild_kimg)"
    [[ -f "$bzimage" ]]                 || die "kernel image not found: $bzimage"
    [[ -f "$IMG_DIR/$RELEASE.img" ]]    || die "image not found; image stage failed?"
    [[ -f "$IMG_DIR/$RELEASE.id_rsa" ]] || die "ssh key not found: $IMG_DIR/$RELEASE.id_rsa"

    # Emit the "qemu" field only when we actually have a binary to point at.
    local qemu_line=""
    if [[ -x "$QEMU" ]]; then
        qemu_line="        \"qemu\": \"$QEMU\","
    else
        warn "$QEMU not executable; relying on PATH $QEMU_SYSTEM"
    fi

    mkdir -p "$WORKDIR"
    cat > "$CONFIG" <<EOF
{
    "target": "$TARGET",
    "http": "$HTTP",
    "workdir": "$WORKDIR",
    "kernel_obj": "$KOUT",
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
    log "Wrote $CONFIG"
    cat "$CONFIG"
}

main() {
    log "starting stage: build_syzkaller"
    BUILD_DIR="$BUILD_DIR" TARGETARCH="$(arch_name go "$ARCH")" "$SCRIPT_DIR/common/build_syzkaller.sh"
    log "starting stage: kernel"
    stage_kernel
    log "starting stage: image"
    stage_image
    log "starting stage: config"
    stage_config
    log "Done. Launch the fuzzer with ./run_syzkaller.sh"
}

main "$@"
