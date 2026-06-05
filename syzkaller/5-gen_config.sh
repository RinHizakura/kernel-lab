#!/usr/bin/env bash
#
# Generate a syz-manager config (config.cfg) wired to the artifacts produced
# by the sibling scripts. Re-run any time paths or VM sizing change.
#
# Defaults assume the standard layout:
#   syzkaller bin : build/syzkaller
#   kernel        : build/linux (vmlinux + arch/x86/boot/bzImage)
#   image / key   : build/image/<release>.img, build/image/<release>.id_rsa
#   qemu binary   : ../qemu/install/bin/qemu-system-x86_64 if you built one,
#                   else whatever qemu-system-x86_64 is on PATH
#
# Usage:
#   ./5-gen_config.sh                         # write config.cfg
#   VMS=4 PROCS=8 ./5-gen_config.sh
#   RELEASE=bookworm ./5-gen_config.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/build/syzkaller"
KERNEL="$SCRIPT_DIR/build/linux"
IMG_DIR="$SCRIPT_DIR/build/image"

RELEASE="${RELEASE:-bullseye}"
TARGET="${TARGET:-linux/amd64}"
HTTP="${HTTP:-127.0.0.1:56741}"
WORKDIR="${WORKDIR:-$SCRIPT_DIR/build/workdir}"
CONFIG="${CONFIG:-$SCRIPT_DIR/build/config.cfg}"

# VM sizing.
VMS="${VMS:-2}"
PROCS="${PROCS:-4}"
CPU="${CPU:-2}"
MEM="${MEM:-2048}"

# Extra kernel cmdline. net.ifnames=0 keeps the NIC named eth0 so the image's
# /etc/network/interfaces (auto eth0) matches; otherwise udev renames it to
# enp0s4, ifup fails, the VM never gets an IP and syz-manager can't SSH in.
CMDLINE="${CMDLINE:-net.ifnames=0}"

# Prefer the locally built QEMU; fall back to PATH.
QEMU="${QEMU:-$SCRIPT_DIR/../qemu/install/bin/qemu-system-x86_64}"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -x "$SRC_DIR/bin/syz-manager" ]] || die "syz-manager not built; run ./2-build_syzkaller.sh"
[[ -f "$KERNEL/vmlinux" ]]          || die "vmlinux not found in $KERNEL; run ./3-build_syzkaller_kernel.sh"
BZIMAGE="$KERNEL/arch/x86/boot/bzImage"
[[ -f "$BZIMAGE" ]]                 || die "bzImage not found: $BZIMAGE"
[[ -f "$IMG_DIR/$RELEASE.img" ]]    || die "image not found; run ./4-create_image.sh"
[[ -f "$IMG_DIR/$RELEASE.id_rsa" ]] || die "ssh key not found: $IMG_DIR/$RELEASE.id_rsa"

# qemu line: emit the "qemu" field only when we actually have a binary to point
# at, otherwise let syzkaller use the PATH default.
if [[ -x "$QEMU" ]]; then
    QEMU_LINE="        \"qemu\": \"$QEMU\","
else
    msg "warning: $QEMU not executable; relying on PATH qemu-system-x86_64"
    QEMU_LINE=""
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
$QEMU_LINE
        "kernel": "$BZIMAGE",
        "cmdline": "$CMDLINE",
        "cpu": $CPU,
        "mem": $MEM
    }
}
EOF

msg "Wrote $CONFIG"
cat "$CONFIG"
