#!/usr/bin/env bash
#
# Clone the official QEMU git repo, build, and install under this folder.
#
# Layout (relative to this script):
#   build/qemu/         git checkout of the official repo
#   build/qemu/build/   out-of-tree build directory
#   install/            install prefix (binaries land in install/bin)
#
# Usage:
#   ./build_qemu.sh                       # latest stable tag, x86_64 target
#   REF=master ./build_qemu.sh            # build the development tip
#   REF=v9.2.0 ./build_qemu.sh            # build a specific tag/branch/commit
#   TARGETS=x86_64-softmmu,aarch64-softmmu ./build_qemu.sh
#   JOBS=8 ./build_qemu.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$BUILD_DIR/qemu"
PREFIX="$SCRIPT_DIR/install"
REPO="${REPO:-https://gitlab.com/qemu-project/qemu.git}"

TARGETS="${TARGETS:-x86_64-softmmu}"
JOBS="${JOBS:-$(nproc)}"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- dependency check (Debian/Ubuntu package names) -------------------------
check_deps() {
    local missing=()
    command -v git        >/dev/null || missing+=("git")
    command -v gcc        >/dev/null || missing+=("build-essential")
    command -v python3    >/dev/null || missing+=("python3")
    command -v ninja      >/dev/null || missing+=("ninja-build")
    command -v pkg-config >/dev/null || missing+=("pkg-config")
    pkg-config --exists glib-2.0 2>/dev/null || missing+=("libglib2.0-dev")
    pkg-config --exists pixman-1 2>/dev/null || missing+=("libpixman-1-dev")
    if (( ${#missing[@]} )); then
        die "missing build dependencies. Install with:
    sudo apt update && sudo apt install -y ${missing[*]}"
    fi
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

# Shallow-clone just the requested ref. A full-history clone of QEMU is huge
# (~500k objects) and prone to mid-transfer disconnects; --depth 1 of one tag
# is a tiny fraction of that and survives flaky links far better.
sync_repo() {
    local ref=$1
    mkdir -p "$BUILD_DIR"
    if [[ -d "$SRC_DIR/.git" ]]; then
        msg "Updating existing clone in $SRC_DIR (ref $ref)"
        git -C "$SRC_DIR" fetch --depth 1 origin \
            "+refs/tags/$ref:refs/tags/$ref" "+$ref:$ref" 2>/dev/null \
            || git -C "$SRC_DIR" fetch --depth 1 origin "$ref" \
            || die "fetch of $ref failed"
        git -C "$SRC_DIR" checkout --detach FETCH_HEAD
    else
        msg "Shallow-cloning $REPO at $ref"
        git clone --depth 1 --branch "$ref" "$REPO" "$SRC_DIR" \
            || die "clone failed"
    fi
}

main() {
    check_deps

    local ref
    ref="$(resolve_ref)"
    [[ -n "$ref" ]] || die "could not determine a ref to build"

    msg "Building ref : $ref"
    msg "Targets      : $TARGETS"
    msg "Prefix       : $PREFIX"
    msg "Parallel jobs: $JOBS"

    sync_repo "$ref"

    # configure/make drive submodules automatically when building from git,
    # but initialise them up front (shallow) so an offline build still works.
    msg "Fetching submodules"
    git -C "$SRC_DIR" submodule update --init --recursive --depth 1 \
        || die "submodule fetch failed"

    msg "Configuring"
    rm -rf "$SRC_DIR/build"
    mkdir -p "$SRC_DIR/build"
    ( cd "$SRC_DIR/build" \
        && ../configure --prefix="$PREFIX" --target-list="$TARGETS" )

    msg "Building (make -j$JOBS)"
    make -C "$SRC_DIR/build" -j"$JOBS"

    msg "Installing to $PREFIX"
    make -C "$SRC_DIR/build" install

    local qemu_bin
    qemu_bin="$(ls "$PREFIX"/bin/qemu-system-* 2>/dev/null | head -1 || true)"
    msg "Done. Installed binaries in $PREFIX/bin"
}

main "$@"
