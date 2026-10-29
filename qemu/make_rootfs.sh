#!/usr/bin/env bash
#
# Build guest filesystems for vng_runner from Ubuntu packages, for any arch
# vng supports. No root, no chroot, no qemu-user, nothing compiled.
#
#   rootfs  minimal Ubuntu rootfs for `vng --root`: base tarball + a few debs
#           (busybox, kexec) unpacked with dpkg-deb, plus the stubs vng's
#           init expects; with KSRC also the kernel's modules
#   modules only `make modules_install` from KSRC into an existing DEST
#   initrd  busybox-static repacked as a newc cpio, used as the dump-capture
#           kernel's initrd by `vng_runner -k`
#
# Usage:
#   ./make_rootfs.sh ARCH [rootfs|modules|initrd]   # ARCH as vng --arch: arm64, riscv64, x86_64...
#   KSRC=~/linux/stable-linux/build-arm64 ./make_rootfs.sh arm64
#   KSRC=~/linux/stable-linux/build-arm64 ./make_rootfs.sh arm64 modules
#   OUT=/path/x.img ./make_rootfs.sh riscv64 initrd
#
#   REL    Ubuntu release (default 24.04); CODENAME is derived from REL
#   rootfs / modules:
#   DEST   target directory (default ./<ARCH>-rootfs, relative to the cwd)
#   KSRC   kernel tree or O= build dir to take the modules from
#   CROSS_COMPILE  toolchain prefix for modules_install (default per ARCH)
#   initrd:
#   OUT    output file (default ./kdump-initrd-<ARCH>.img, relative to the cwd)
#
set -euo pipefail

ARCH="${1:?usage: ${0##*/} ARCH [rootfs|initrd]}"
MODE="${2:-rootfs}"
REL="${REL:-24.04}"
JOBS="${JOBS:-$(nproc)}"

# shellcheck source=../lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib.sh"   # log/warn/die

# vng --arch names are Debian arch names except x86_64. amd64 lives on the
# main archive, everything else on ports. KARCH/CROSS are for modules_install.
case $ARCH in
    x86_64)  DEB_ARCH=amd64; KARCH=x86;     CROSS= ;;
    arm64)   DEB_ARCH=arm64; KARCH=arm64;   CROSS=aarch64-linux-gnu- ;;
    armhf)   DEB_ARCH=armhf; KARCH=arm;     CROSS=arm-linux-gnueabihf- ;;
    riscv64) DEB_ARCH=riscv64; KARCH=riscv; CROSS=riscv64-linux-gnu- ;;
    ppc64el) DEB_ARCH=ppc64el; KARCH=powerpc; CROSS=powerpc64le-linux-gnu- ;;
    s390x)   DEB_ARCH=s390x; KARCH=s390;    CROSS=s390x-linux-gnu- ;;
    *) die "unknown arch $ARCH" ;;
esac
if [[ $DEB_ARCH == amd64 ]]; then
    MIRROR=http://archive.ubuntu.com/ubuntu
else
    MIRROR=http://ports.ubuntu.com/ubuntu-ports
fi
case $REL in
    22.04) CODENAME=jammy ;;
    24.04) CODENAME=noble ;;
    *) die "unknown release $REL; add its codename to the case table" ;;
esac
CDIMAGE="http://cdimage.ubuntu.com/ubuntu-base/releases/$REL/release"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fetch_deb PKG DIR: download PKG for DEB_ARCH and unpack it under DIR.
fetch_deb() {
    local pkg=$1 dir=$2 file
    if [[ ! -f $TMP/Packages ]]; then
        curl -sSfL "$MIRROR/dists/$CODENAME/main/binary-$DEB_ARCH/Packages.gz" | zcat > "$TMP/Packages"
    fi
    file="$(awk -v p="$pkg" '$1=="Package:"{cur=$2} cur==p && $1=="Filename:"{print $2; exit}' "$TMP/Packages")"
    [[ -n $file ]] || die "package $pkg not found in $CODENAME $DEB_ARCH index"
    curl -sSfL -o "$TMP/$pkg.deb" "$MIRROR/$file"
    mkdir -p "$dir"
    dpkg-deb -x "$TMP/$pkg.deb" "$dir"
}

# install_modules DEST: `make modules_install` from KSRC (a tree or an O= dir).
# The rootfs serves one kernel at a time, so older module trees are dropped.
install_modules() {
    log "Installing modules from $KSRC"
    rm -rf "$1/lib/modules"
    make -C "$KSRC" ARCH="$KARCH" CROSS_COMPILE="${CROSS_COMPILE:-$CROSS}" -j"$JOBS" \
        INSTALL_MOD_PATH="$1" INSTALL_MOD_STRIP=1 modules_install
}

make_rootfs() {
    local dest tarball
    dest="$(realpath -m "${DEST:-./$ARCH-rootfs}")"
    # Packages unpacked on top of the base image.
    local debs="busybox-static kexec-tools"
    # busybox applets that vng's guest init / typical kernel testing expects.
    local applets="poweroff reboot halt ip modprobe insmod rmmod depmod lsmod deallocvt"

    log "Base image: ubuntu-base $REL $DEB_ARCH -> $dest"
    tarball="$(curl -sSf "$CDIMAGE/" | grep -oE "ubuntu-base-[0-9.]+-base-$DEB_ARCH\.tar\.gz" | sort -uV | tail -1)"
    [[ -n $tarball ]] || die "no $DEB_ARCH base tarball found under $CDIMAGE"
    curl -sSfL -o "$TMP/$tarball" "$CDIMAGE/$tarball"
    mkdir -p "$dest"
    # Base image has device nodes we cannot create unprivileged; ignore those.
    tar -xzf "$TMP/$tarball" -C "$dest" --no-same-owner --no-same-permissions \
        2> >(grep -vE 'Cannot mknod|Cannot change' >&2 || true)

    log "Unpacking debs: $debs"
    for pkg in $debs; do
        # Some debs still carry a ./bin/ directory entry; extracting that
        # straight into dest replaces the usrmerge symlink bin -> usr/bin
        # with a real dir.
        rm -rf "$TMP/x"; fetch_deb "$pkg" "$TMP/x"
        tar -C "$TMP/x" -c . | tar -C "$dest" -x --keep-directory-symlink
    done

    log "busybox applets: $applets"
    for a in $applets; do
        ln -sf /bin/busybox "$dest/usr/sbin/$a"
    done
    ln -sf /bin/busybox "$dest/usr/bin/lsmod"
    mkdir -p "$dest/etc/lvm"   # vng's init bind-mounts it; base image lacks it

    # vng's init runs udevd + a full coldplug if it finds one, then looks for
    # /dev/virtio-ports/<name> (udev's symlinks) to return the script's exit
    # code. Real udev's coldplug costs ~45 s under TCG; those symlinks are
    # all we need, so ship a stub udevd that only creates them and a no-op
    # udevadm.
    # ponytail: stub udev; unpack the udev deb instead if a test needs real udev rules.
    log "Installing stub udevd (virtio-ports symlinks only)"
    mkdir -p "$dest/usr/lib/systemd"
    cat > "$dest/usr/lib/systemd/systemd-udevd" <<'STUB'
#!/bin/sh
# Stub udevd for virtme-ng: only the /dev/virtio-ports/* symlinks.
mkdir -p /dev/virtio-ports
for d in /sys/class/virtio-ports/vport*; do
    n=$(cat "$d/name" 2>/dev/null) || continue
    [ -n "$n" ] && ln -sf "/dev/${d##*/}" "/dev/virtio-ports/$n"
done
exit 0
STUB
    printf '#!/bin/sh\nexit 0\n' > "$dest/usr/bin/udevadm"
    chmod +x "$dest/usr/lib/systemd/systemd-udevd" "$dest/usr/bin/udevadm"

    if [[ -n ${KSRC:-} ]]; then
        install_modules "$dest"
    else
        # Still boots: vng passes no initramfs for --root, so 9p/overlay must
        # be built into the kernel anyway. Only modprobe inside the guest is
        # empty.
        log "KSRC not set: no modules installed. Add them later with:"
        log "  make -C <ksrc> ARCH=$KARCH CROSS_COMPILE=${CROSS_COMPILE:-$CROSS} INSTALL_MOD_PATH=$dest modules_install"
    fi

    log "Done: $dest"
    log "Boot: vng_runner -a $ARCH -- -r ${KSRC:-<ksrc>} --root $dest"
}

make_initrd() {
    local out bb r
    out="$(realpath -m "${OUT:-./kdump-initrd-$ARCH.img}")"

    log "Fetching busybox-static ($CODENAME $DEB_ARCH)"
    fetch_deb busybox-static "$TMP/x"
    bb="$(find "$TMP/x" -type f -name busybox | head -1)"
    [[ -n $bb ]] || die "no busybox binary in the deb"

    r="$TMP/root"
    mkdir -p "$r"/{bin,sbin,dev,proc,sys,etc/init.d,mnt}
    cp "$bb" "$r/bin/busybox"
    ln -s bin/busybox "$r/init"
    # busybox --install cannot run for a foreign arch; link the applets a
    # dump session needs by hand, anything else is reachable as
    # `busybox <applet>`.
    # ponytail: fixed applet list; extend it when a capture-kernel session misses one
    for a in sh ash mount umount cat cp dd ls ln mkdir rm sync gzip dmesg hexdump grep vi; do
        ln -s busybox "$r/bin/$a"
    done
    for a in init poweroff reboot halt swapoff; do
        ln -s ../bin/busybox "$r/sbin/$a"
    done
    cat > "$r/etc/inittab" <<'INITTAB'
::sysinit:/etc/init.d/rcS
::askfirst:-/bin/sh
::restart:/sbin/init
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
::shutdown:/sbin/swapoff -a
INITTAB
    cat > "$r/etc/init.d/rcS" <<'RCS'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mount -t debugfs none /sys/kernel/debug
RCS
    chmod +x "$r/etc/init.d/rcS"

    ( cd "$r" && find . | cpio -o -H newc --quiet ) > "$out"
    log "Done: $out ($(file -b "$bb" | cut -d, -f2))"
}

case $MODE in
    rootfs) make_rootfs ;;
    modules)
        [[ -n ${KSRC:-} ]] || die "modules mode needs KSRC"
        install_modules "$(realpath -m "${DEST:-./$ARCH-rootfs}")" ;;
    initrd) make_initrd ;;
    *) die "unknown mode $MODE (rootfs|modules|initrd)" ;;
esac
