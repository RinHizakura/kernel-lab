#!/usr/bin/env bash
#
# Clone google/syzkaller and build it in place.
#
# Layout (relative to this script):
#   build/syzkaller/      git checkout of google/syzkaller (binaries -> bin/)
#
# Requires a Go toolchain on PATH (install it yourself, e.g. via your distro
# or https://go.dev/dl/). syzkaller tracks a fairly recent Go in its go.mod.
#
# Usage:
#   ./2-build_syzkaller.sh                          # latest master, host arch
#   REF=v0.0.1 ./2-build_syzkaller.sh               # a specific tag/commit
#   TARGETARCH=arm64 ./2-build_syzkaller.sh         # cross-build target bits
#   JOBS=8 ./2-build_syzkaller.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$BUILD_DIR/syzkaller"
REPO="${REPO:-https://github.com/google/syzkaller.git}"
REF="${REF:-master}"

# syzkaller targets: OS is linux here; ARCH uses syzkaller's naming (amd64,
# arm64, riscv64, ...). Default to the common x86_64 target.
TARGETOS="${TARGETOS:-linux}"
TARGETARCH="${TARGETARCH:-amd64}"
JOBS="${JOBS:-$(nproc)}"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- toolchain check (Debian/Ubuntu package names) --------------------------
check_deps() {
    local missing=()
    command -v git  >/dev/null || missing+=("git")
    command -v gcc  >/dev/null || missing+=("build-essential")
    command -v make >/dev/null || missing+=("make")
    if (( ${#missing[@]} )); then
        die "missing build dependencies. Install with:
    sudo apt update && sudo apt install -y ${missing[*]}"
    fi
    command -v go >/dev/null \
        || die "Go toolchain not found on PATH. Install Go (https://go.dev/dl/) first."
}

sync_repo() {
    mkdir -p "$BUILD_DIR"
    if [[ -d "$SRC_DIR/.git" ]]; then
        msg "Updating existing clone in $SRC_DIR (ref $REF)"
        git -C "$SRC_DIR" fetch --depth 1 origin "$REF" || die "fetch of $REF failed"
        git -C "$SRC_DIR" checkout --detach FETCH_HEAD
    else
        msg "Cloning $REPO at $REF"
        git clone --depth 1 --branch "$REF" "$REPO" "$SRC_DIR" 2>/dev/null \
            || git clone --depth 1 "$REPO" "$SRC_DIR" \
            || die "clone failed"
    fi
}

main() {
    check_deps

    msg "Building syzkaller : $REF"
    msg "Go                 : $(go version)"
    msg "Target             : $TARGETOS/$TARGETARCH"
    msg "Parallel jobs      : $JOBS"

    sync_repo

    msg "Running make (this also fetches Go module deps)"
    make -C "$SRC_DIR" -j"$JOBS" TARGETOS="$TARGETOS" TARGETARCH="$TARGETARCH"

    msg "Done. syzkaller binaries in $SRC_DIR/bin"
    ls "$SRC_DIR/bin" 2>/dev/null || true
}

main "$@"
