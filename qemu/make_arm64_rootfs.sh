#!/usr/bin/env bash
#
# Build a minimal arm64 rootfs.
# No root, no chroot, no qemu-user: Ubuntu base tarball + a few debs
# unpacked with dpkg-deb.
#
# Usage:
#   ./make_arm64_rootfs.sh
#   DEST=/path KSRC=~/linux/stable-linux ./make_arm64_rootfs.sh
#
#   DEST   target directory (default ./arm64-rootfs, relative to the cwd)
#   KSRC   kernel tree; if set, runs `make ARCH=arm64 modules_install` into DEST
#   REL    Ubuntu release (default 24.04); CODENAME is derived from REL
#
set -euo pipefail

DEST="$(realpath -m "${DEST:-./arm64-rootfs}")"
REL="${REL:-24.04}"
KSRC="${KSRC:-}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

CDIMAGE="http://cdimage.ubuntu.com/ubuntu-base/releases/$REL/release"
PORTS="http://ports.ubuntu.com/ubuntu-ports"
# Packages unpacked on top of the base image. udev is what creates
# /dev/virtio-ports/*, which vng needs to return the script's exit code.
DEBS="busybox-static udev libkmod2"
# busybox applets that vng's guest init / typical kernel testing expects.
APPLETS="poweroff reboot halt ip modprobe insmod rmmod depmod lsmod"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

case $REL in
    22.04) CODENAME=jammy ;;
    24.04) CODENAME=noble ;;
    *) die "unknown release $REL; add its codename to the case table" ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

msg "Base image: ubuntu-base $REL arm64 -> $DEST"
tarball="$(curl -sSf "$CDIMAGE/" | grep -oE 'ubuntu-base-[0-9.]+-base-arm64\.tar\.gz' | sort -uV | tail -1)"
[[ -n $tarball ]] || die "no arm64 base tarball found under $CDIMAGE"
curl -sSfL -o "$TMP/$tarball" "$CDIMAGE/$tarball"
mkdir -p "$DEST"
# Base image has device nodes we cannot create unprivileged; ignore those.
tar -xzf "$TMP/$tarball" -C "$DEST" --no-same-owner --no-same-permissions \
    2> >(grep -vE 'Cannot mknod|Cannot change' >&2 || true)

msg "Unpacking debs: $DEBS"
curl -sSfL "$PORTS/dists/$CODENAME/main/binary-arm64/Packages.gz" | zcat > "$TMP/Packages"
for pkg in $DEBS; do
    file="$(awk -v p="$pkg" '$1=="Package:"{cur=$2} cur==p && $1=="Filename:"{print $2; exit}' "$TMP/Packages")"
    [[ -n $file ]] || die "package $pkg not found in $CODENAME arm64 index"
    curl -sSfL -o "$TMP/$pkg.deb" "$PORTS/$file"
    # Some debs still carry a ./bin/ directory entry; extracting that straight
    # into DEST replaces the usrmerge symlink bin -> usr/bin with a real dir.
    rm -rf "$TMP/x" && mkdir "$TMP/x"
    dpkg-deb -x "$TMP/$pkg.deb" "$TMP/x"
    tar -C "$TMP/x" -c . | tar -C "$DEST" -x --keep-directory-symlink
done

msg "busybox applets: $APPLETS"
for a in $APPLETS; do
    ln -sf /bin/busybox "$DEST/usr/sbin/$a"
done
ln -sf /bin/busybox "$DEST/usr/bin/lsmod"
mkdir -p "$DEST/etc/lvm"   # vng's init bind-mounts it; base image lacks it

if [[ -n $KSRC ]]; then
    msg "Installing modules from $KSRC"
    make -C "$KSRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" \
        INSTALL_MOD_PATH="$DEST" modules_install
else
    # Still boots: vng passes no initramfs for --root, so 9p/overlay must be
    # built into the kernel anyway. Only modprobe inside the guest is empty.
    msg "KSRC not set: no modules installed. Add them later with:"
    msg "  make -C <ksrc> ARCH=arm64 CROSS_COMPILE=$CROSS_COMPILE INSTALL_MOD_PATH=$DEST modules_install"
fi

msg "Done: $DEST"
msg "Boot: vng_runner -a arm64 -- -r ${KSRC:-<ksrc>} --root $DEST"
