#!/usr/bin/env bash
#
# Clone the official QEMU git repo, build, and install under this folder.
#
# Layout (relative to this script):
#   build/qemu/         git checkout of the official repo (shared by all archs)
#   build_<ARCH>/       out-of-tree build directory, e.g. build_x86_64/
#   install_<ARCH>/     install prefix, e.g. install_x86_64/bin
#
# Usage:
#   ./build_qemu.sh                       # latest stable tag, x86_64 target
#   ARCH=arm64 ./build_qemu.sh            # build_arm64/ + install_arm64/, target aarch64-softmmu
#   REF=master ./build_qemu.sh            # build the development tip
#   REF=v9.2.0 ./build_qemu.sh            # build a specific tag/branch/commit
#   TARGETS=x86_64-softmmu,aarch64-softmmu ./build_qemu.sh
#   JOBS=8 ./build_qemu.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"   # log/warn/die, need_tools, shallow_clone, arch_name

ARCH="${ARCH:-x86_64}"           # vng name; the QEMU target name comes from arch_name
SRC_DIR="$SCRIPT_DIR/build/qemu"
BUILD_DIR="$SCRIPT_DIR/build_$ARCH"
PREFIX="$SCRIPT_DIR/install_$ARCH"
REPO="${REPO:-https://gitlab.com/qemu-project/qemu.git}"

TARGETS="${TARGETS:-$(arch_name qemu "$ARCH")-softmmu}"
JOBS="${JOBS:-$(nproc)}"

# --- dependency check (Debian/Ubuntu package names) -------------------------
check_deps() {
    need_tools git gcc:build-essential python3 ninja:ninja-build pkg-config
    local lib missing=()
    for lib in glib-2.0:libglib2.0-dev pixman-1:libpixman-1-dev slirp:libslirp-dev; do
        pkg-config --exists "${lib%%:*}" 2>/dev/null || missing+=("${lib#*:}")
    done
    (( ${#missing[@]} )) || return 0
    die "missing build dependencies. Install with:
    sudo apt update && sudo apt install -y ${missing[*]}"
}

# Resolve the ref to build WITHOUT cloning first: REF env wins, otherwise the
# highest stable tag (vX.Y.Z, excluding -rc/-alpha) discovered via ls-remote.
resolve_ref() {
    if [[ -n "${REF:-}" ]]; then
        echo "$REF"
        return
    fi
    git ls-remote --tags --refs "$REPO" 'v*' \
        | awk '{print $2}' | sed 's#refs/tags/##' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V | tail -1
}

main() {
    check_deps

    local ref
    ref="$(resolve_ref)"
    [[ -n "$ref" ]] || die "could not determine a ref to build"

    log "Building ref : $ref"
    log "Targets      : $TARGETS"
    log "Build dir    : $BUILD_DIR"
    log "Prefix       : $PREFIX"
    log "Parallel jobs: $JOBS"

    shallow_clone "$REPO" "$ref" "$SRC_DIR"

    # configure/make drive submodules automatically when building from git,
    # but initialise them up front (shallow) so an offline build still works.
    log "Fetching submodules"
    git -C "$SRC_DIR" submodule update --init --recursive --depth 1 \
        || die "submodule fetch failed"

    log "Configuring"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    ( cd "$BUILD_DIR" \
        && "$SRC_DIR/configure" --prefix="$PREFIX" --target-list="$TARGETS" --enable-slirp )

    log "Building (make -j$JOBS)"
    make -C "$BUILD_DIR" -j"$JOBS"

    log "Installing to $PREFIX"
    make -C "$BUILD_DIR" install

    local qemu_bin
    qemu_bin="$(ls "$PREFIX"/bin/qemu-system-* 2>/dev/null | head -1 || true)"
    log "Done. Installed binaries in $PREFIX/bin"
}

main "$@"
