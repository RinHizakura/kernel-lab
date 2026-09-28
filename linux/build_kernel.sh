#!/usr/bin/env bash
#
# Build a Linux kernel. Runs standalone, or `source` it for the kbuild_* helpers.
#
# Standalone: clone KERNEL_BRANCH into BUILD_DIR/linux (or use KSRC as-is),
# reuse .config if present (else DEFCONFIG), merge CONFIG_FRAGMENTS via
# merge_config.sh, reconcile with `make olddefconfig`, build the arch image.
#
# Usage:
#   ./build_kernel.sh                                   # stable tree, master
#   KSRC=/path/to/linux ./build_kernel.sh               # existing tree, no clone
#   KERNEL_BRANCH=linux-6.6.y ./build_kernel.sh
#   KERNEL_REPO=https://.../torvalds/linux.git ./build_kernel.sh
#   ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ./build_kernel.sh
#   LLVM=1 ./build_kernel.sh                            # clang/lld
#   CONFIG_FRAGMENTS="/path/a.config /path/b.config" ./build_kernel.sh
#   BUILD_DIR=/somewhere/else ./build_kernel.sh
#
# Library (set your own defaults BEFORE sourcing, they win):
#   source build_kernel.sh
#   kbuild_check_tools; kbuild_check_tree
#   kbuild_make defconfig            # make -C $KSRC ARCH=.. CROSS_COMPILE=.. LLVM=.. LOCALVERSION=.. -jN
#   kbuild_enable FOO BAR; kbuild_disable BAZ   # scripts/config on $KSRC/.config
#   kbuild_merge_fragments           # $CONFIG_FRAGMENTS on top of .config (no olddefconfig)
#   kbuild_make olddefconfig bzImage
#   KBUILD_SUDO=sudo kbuild_make modules_install
#
set -euo pipefail

: "${KSRC:=}"                     # existing kernel tree; empty = clone into BUILD_DIR/linux
: "${BUILD_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build}"
: "${KERNEL_REPO:=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
: "${KERNEL_BRANCH:=master}"
: "${ARCH:=x86_64}"
: "${CROSS_COMPILE:=}"
: "${LLVM:=}"                     # LLVM=1 -> clang, LLVM=-15 -> clang-15
: "${JOBS:=$(nproc)}"
: "${DEFCONFIG:=defconfig}"
: "${CONFIG_FRAGMENTS:=}"         # space-separated .config fragments
# LOCALVERSION is passed to make only if set (even empty): set-but-empty drops
# setlocalversion's trailing "+", unset keeps it.

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

kbuild_check_tools() {
    command -v bc   >/dev/null || die "bc not installed (sudo apt install bc)"
    command -v flex >/dev/null || die "flex not installed (sudo apt install flex bison libelf-dev libssl-dev)"
    if [[ -n "$LLVM" ]]; then
        local clang=clang; [[ "$LLVM" == -* ]] && clang="clang$LLVM"
        command -v "$clang" >/dev/null || die "LLVM=$LLVM set but $clang not found in PATH"
    else
        command -v "${CROSS_COMPILE}gcc" >/dev/null || die "compiler ${CROSS_COMPILE}gcc not found in PATH"
    fi
}

kbuild_check_tree() {
    [[ -n "$KSRC" && -f "$KSRC/Kbuild" ]] || die "KSRC does not look like a kernel tree: '$KSRC'"
}

# make in $KSRC with the arch/toolchain/version vars. KBUILD_SUDO=sudo to escalate.
kbuild_make() {
    local args=(-C "$KSRC" ARCH="$ARCH" -j"$JOBS")
    [[ -n "$CROSS_COMPILE" ]] && args+=(CROSS_COMPILE="$CROSS_COMPILE")
    [[ -n "$LLVM" ]] && args+=(LLVM="$LLVM")
    [[ -n "${LOCALVERSION+x}" ]] && args+=(LOCALVERSION="$LOCALVERSION")
    ${KBUILD_SUDO:-} make "${args[@]}" "$@"
}

# .config setters (scripts/config). Run `kbuild_make olddefconfig` afterwards so
# dependencies resolve.
kbuild_cfg()     { "$KSRC/scripts/config" --file "$KSRC/.config" "$@"; }
kbuild_enable()  { local o; for o in "$@"; do kbuild_cfg --enable  "$o"; done; }
kbuild_disable() { local o; for o in "$@"; do kbuild_cfg --disable "$o"; done; }

kbuild_check_fragments() {
    local frag
    for frag in $CONFIG_FRAGMENTS; do
        [[ -f "$frag" ]] || die "config fragment missing: $frag"
    done
}

# Merge $CONFIG_FRAGMENTS on top of .config. Caller runs olddefconfig after.
kbuild_merge_fragments() {
    [[ -n "$CONFIG_FRAGMENTS" ]] || return 0
    kbuild_check_fragments
    log "Merging config fragments: $CONFIG_FRAGMENTS"
    # shellcheck disable=SC2086
    "$KSRC/scripts/kconfig/merge_config.sh" -m -O "$KSRC" "$KSRC/.config" $CONFIG_FRAGMENTS
}

kbuild_clone() {
    command -v git >/dev/null || die "git not installed"
    mkdir -p "$BUILD_DIR"
    if [[ -d "$KSRC/.git" ]]; then
        log "Updating kernel clone (branch $KERNEL_BRANCH)"
        git -C "$KSRC" fetch --depth 1 origin "$KERNEL_BRANCH" || die "fetch of $KERNEL_BRANCH failed"
        git -C "$KSRC" checkout --detach FETCH_HEAD
    else
        log "Shallow-cloning $KERNEL_REPO ($KERNEL_BRANCH)"
        git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KSRC" || die "clone failed"
    fi
}

main() {
    case "$ARCH" in
        x86_64) IMG_TARGET=bzImage ;;
        arm64)  IMG_TARGET=Image ;;
        *)      IMG_TARGET=vmlinux ;;
    esac

    kbuild_check_tools
    kbuild_check_fragments   # fail before the long clone/build

    if [[ -n "$KSRC" ]]; then
        kbuild_check_tree
        log "Kernel source: $KSRC (existing tree, not touching git)"
    else
        KSRC="$BUILD_DIR/linux"
        log "Kernel repo  : $KERNEL_REPO"
        log "Kernel branch: $KERNEL_BRANCH"
        kbuild_clone
    fi
    log "Arch         : $ARCH"
    [[ -n "$CONFIG_FRAGMENTS" ]] && log "Fragments    : $CONFIG_FRAGMENTS"

    if [[ -f "$KSRC/.config" ]]; then
        log "Reusing existing .config"
    else
        log "Generating base config ($DEFCONFIG)"
        kbuild_make "$DEFCONFIG"
    fi
    kbuild_merge_fragments
    kbuild_make olddefconfig

    log "Building kernel ($IMG_TARGET)"
    kbuild_make "$IMG_TARGET"
    log "Done."
}

# Sourced: expose the helpers only.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0
main "$@"
