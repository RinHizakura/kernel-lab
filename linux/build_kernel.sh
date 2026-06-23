#!/usr/bin/env bash
#
# Clone a Linux kernel branch and build it.
#
# Layout (relative to this script, override with BUILD_DIR):
#   build/linux/          shallow git checkout of the requested kernel branch
#
# Starts from defconfig, optionally merges each file in CONFIG_FRAGMENTS on top
# via the kernel's own merge_config.sh, then reconciles with `make olddefconfig`
# so nothing silently drops out.
#
# Usage:
#   ./build_kernel.sh                                   # stable tree, master
#   KERNEL_BRANCH=linux-6.6.y ./build_kernel.sh
#   KERNEL_REPO=https://.../torvalds/linux.git ./build_kernel.sh
#   ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ./build_kernel.sh
#   CONFIG_FRAGMENTS="/path/a.config /path/b.config" ./build_kernel.sh
#   BUILD_DIR=/somewhere/else ./build_kernel.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build}"
KERNEL="$BUILD_DIR/linux"

KERNEL_REPO="${KERNEL_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-master}"
ARCH="${ARCH:-x86_64}"
# Space-separated list of .config fragments to merge on top of defconfig.
CONFIG_FRAGMENTS="${CONFIG_FRAGMENTS:-}"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null || die "git not installed"
command -v gcc >/dev/null || die "build-essential not installed"
command -v bc  >/dev/null || die "bc not installed (sudo apt install bc)"
command -v flex >/dev/null || die "flex not installed (sudo apt install flex bison libelf-dev libssl-dev)"

# Validate fragments up front so we fail before the long clone/build.
read -ra FRAGMENTS <<< "$CONFIG_FRAGMENTS"
for frag in "${FRAGMENTS[@]}"; do
    [[ -f "$frag" ]] || die "config fragment missing: $frag"
done

# The kernel's make image target by arch.
case "$ARCH" in
    x86_64) IMG_TARGET=bzImage ;;
    arm64)  IMG_TARGET=Image ;;
    *)      IMG_TARGET=vmlinux ;;
esac

MAKE=(make -C "$KERNEL" ARCH="$ARCH" -j"$(nproc)")
[[ -n "${CROSS_COMPILE:-}" ]] && MAKE+=(CROSS_COMPILE="$CROSS_COMPILE")

sync_repo() {
    mkdir -p "$BUILD_DIR"
    if [[ -d "$KERNEL/.git" ]]; then
        msg "Updating kernel clone (branch $KERNEL_BRANCH)"
        git -C "$KERNEL" fetch --depth 1 origin "$KERNEL_BRANCH" \
            || die "fetch of $KERNEL_BRANCH failed"
        git -C "$KERNEL" checkout --detach FETCH_HEAD
    else
        msg "Shallow-cloning $KERNEL_REPO ($KERNEL_BRANCH)"
        git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL" \
            || die "clone failed"
    fi
}

main() {
    msg "Kernel repo  : $KERNEL_REPO"
    msg "Kernel branch: $KERNEL_BRANCH"
    msg "Arch         : $ARCH"
    msg "Build dir    : $BUILD_DIR"
    (( ${#FRAGMENTS[@]} )) && msg "Fragments    : ${FRAGMENTS[*]}"

    sync_repo

    msg "Generating base config (defconfig)"
    "${MAKE[@]}" defconfig

    if (( ${#FRAGMENTS[@]} )); then
        msg "Merging config fragments"
        "$KERNEL/scripts/kconfig/merge_config.sh" -m -O "$KERNEL" \
            "$KERNEL/.config" "${FRAGMENTS[@]}"
        "${MAKE[@]}" olddefconfig
    fi

    msg "Building kernel ($IMG_TARGET)"
    "${MAKE[@]}" "$IMG_TARGET"

    msg "Done."
}

main "$@"
