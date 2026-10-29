#!/usr/bin/env bash
#
# Build syzkaller from scratch: install the latest Go toolchain (if not already
# present), then clone and build syzkaller. Shared prerequisite for every deploy
# target (QEMU, isolated).
#
# Layout (relative to this script):
#   build/syzkaller/      git checkout of google/syzkaller (binaries -> bin/)
#
# Env knobs:
#   REF=master                     syzkaller tag/commit to build
#   TARGETARCH=<host>              GOARCH to build for (arm64 for a Pi board)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build}"
SRC_DIR="$BUILD_DIR/syzkaller"
GOROOT="/usr/local/go"
REPO="https://github.com/google/syzkaller.git"
REF="${REF:-master}"
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"   # log/warn/die, need_tools, shallow_clone, arch_name, host_arch
TARGETARCH="${TARGETARCH:-$(arch_name go "$(host_arch)")}"

# --- toolchain check (Debian/Ubuntu package names) --------------------------
check_deps() { need_tools curl tar git gcc:build-essential make; }

# --- install the latest stable Go into $GOROOT ------------------------------
install_go() {
    local version arch tarball url SUDO=""
    log "Querying latest stable Go version"
    version="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)" \
        || die "failed to query latest Go version"
    arch="$(arch_name go "$(host_arch)")"
    tarball="${version}.linux-${arch}.tar.gz"
    url="https://go.dev/dl/${tarball}"
    [[ -w /usr/local ]] || SUDO="sudo"

    log "Installing $version (linux/$arch) into $GOROOT"
    local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    curl -fSL --retry 3 -o "$tmp/$tarball" "$url" || die "download failed: $url"
    $SUDO rm -rf "$GOROOT"
    $SUDO tar -C /usr/local -xzf "$tmp/$tarball"
    [[ -x "$GOROOT/bin/go" ]] || die "expected go binary at $GOROOT/bin/go after extraction"
    export PATH="$GOROOT/bin:$PATH"
    log "Installed: $(go version)"
}

# --- clone + build syzkaller ------------------------------------------------
build_syzkaller() {
    shallow_clone "$REPO" "$REF" "$SRC_DIR"

    log "Building syzkaller ($REF) for linux/$TARGETARCH"
    make -C "$SRC_DIR" -j"$(nproc)" TARGETOS=linux TARGETARCH="$TARGETARCH"
    log "Done. syzkaller binaries in $SRC_DIR/bin"
    ls "$SRC_DIR/bin" 2>/dev/null || true
}

main() {
    check_deps
    if command -v go >/dev/null; then
        log "Using existing Go: $(go version)"
    else
        install_go
    fi
    build_syzkaller
}

main "$@"
