#!/usr/bin/env bash
#
# The guest images vng_runner boots with, built from Ubuntu packages for any
# arch vng supports: no root, no chroot, no qemu-user, nothing compiled.
#
#   rootfs  <this dir>/<ARCH>-rootfs: minimal Ubuntu rootfs for `vng --root`
#           (base tarball, busybox, kexec-tools, the stubs vng's init expects,
#           and the modules of the kernel in KDIR). Only for a cross arch; the
#           host's own arch boots the host root.
#   initrd  KDIR/kdump-initrd-<ARCH>.img: busybox-static as a newc cpio, the
#           dump-capture kernel's initrd for `vng_runner -k`.
#
# Usage:
#   ./make_rootfs.sh paths  ARCH KDIR   # print the two paths, touch nothing
#   ./make_rootfs.sh ensure ARCH KDIR   # make them exist and match KDIR's kernel, then print them
#
# Both print two lines on stdout: the rootfs dir (empty for the host's arch)
# and the initrd path. ensure is idempotent: it rebuilds the rootfs when it
# is missing, reinstalls the modules when lib/modules lacks the release of
# the kernel built in KDIR, adds kexec when an older rootfs lacks it, and
# builds the initrd when it is missing.
#
#   ARCH   vng --arch name: x86_64, arm64, riscv64, ...
#   KDIR   the kernel's O= build dir (or in-tree build)
#   ROOTFS override the rootfs dir; REL Ubuntu release (default 24.04);
#   CROSS_COMPILE toolchain prefix for modules_install (default per ARCH); JOBS
#
set -euo pipefail

MODE="${1:?usage: ${0##*/} paths|ensure ARCH KDIR}"
ARCH="${2:?usage: ${0##*/} paths|ensure ARCH KDIR}"
KDIR="${3:?usage: ${0##*/} paths|ensure ARCH KDIR}"
REL="${REL:-24.04}"
JOBS="${JOBS:-$(nproc)}"

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"   # log/warn/die, arch_name, host_arch, kernel_release

DEB_ARCH=$(arch_name deb "$ARCH")
KARCH=$(arch_name kernel "$ARCH")      # for modules_install
CROSS=$(arch_name cross "$ARCH")
# amd64 lives on the main archive, everything else on ports.
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

# Where the images live. The host's own arch needs no rootfs.
rootfs_dir() {
    if [[ $ARCH == "$(host_arch)" ]]; then echo; else echo "${ROOTFS:-$SCRIPT_DIR/$ARCH-rootfs}"; fi
}
initrd_path() { echo "$KDIR/kdump-initrd-$ARCH.img"; }

if [[ $MODE == paths ]]; then
    rootfs_dir; initrd_path
    exit 0
fi
[[ $MODE == ensure ]] || die "unknown mode $MODE (paths|ensure)"
KDIR=$(realpath "$KDIR")

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

# add_debs DEST PKG...: unpack Ubuntu packages on top of a rootfs.
add_debs() {
    local dest=$1 pkg; shift
    log "Unpacking debs: $*"
    for pkg in "$@"; do
        # Some debs still carry a ./bin/ directory entry; extracting that
        # straight into dest replaces the usrmerge symlink bin -> usr/bin
        # with a real dir.
        rm -rf "$TMP/x"; fetch_deb "$pkg" "$TMP/x"
        tar -C "$TMP/x" -c . | tar -C "$dest" -x --keep-directory-symlink
    done
}

# install_modules DEST: `make modules_install` from the build in KDIR. The
# rootfs serves one kernel at a time, so older module trees are dropped.
install_modules() {
    log "Installing modules from $KDIR"
    rm -rf "$1/lib/modules"
    make -C "$KDIR" ARCH="$KARCH" CROSS_COMPILE="${CROSS_COMPILE:-$CROSS}" -j"$JOBS" \
        INSTALL_MOD_PATH="$1" INSTALL_MOD_STRIP=1 modules_install
}

# make_rootfs DEST: the Ubuntu base rootfs from scratch, modules included
# when KDIR holds a built kernel.
make_rootfs() {
    local dest=$1 tarball
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

    add_debs "$dest" busybox-static kexec-tools

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

    if [[ -n $(kernel_release "$KDIR") ]]; then
        install_modules "$dest"
    else
        # Still boots: vng passes no initramfs for --root, so 9p/overlay must
        # be built into the kernel anyway. The next ensure installs them.
        warn "no kernel built in $KDIR yet: no modules installed"
    fi
    log "Done: $dest"
}

# make_initrd OUT: the dump-capture kernel's busybox initrd.
make_initrd() {
    local out=$1 bb r

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

# --- ensure -----------------------------------------------------------------
dest=$(rootfs_dir)
if [[ -n $dest ]]; then
    krel=$(kernel_release "$KDIR")
    if [[ ! -d $dest ]]; then
        make_rootfs "$dest"
    else
        [[ -x $dest/usr/sbin/kexec ]] || add_debs "$dest" kexec-tools
        if [[ -n $krel && ! -d $dest/lib/modules/$krel ]]; then
            install_modules "$dest"
        fi
    fi
fi
initrd=$(initrd_path)
[[ -f $initrd ]] || make_initrd "$initrd"
rootfs_dir; initrd_path
