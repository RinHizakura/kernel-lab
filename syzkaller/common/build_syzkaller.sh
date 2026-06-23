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
#   TARGETARCH=amd64               target bits (arm64 for a Pi board)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build}"
SRC_DIR="$BUILD_DIR/syzkaller"
GOROOT="/usr/local/go"
REPO="https://github.com/google/syzkaller.git"
REF="${REF:-master}"
TARGETARCH="${TARGETARCH:-amd64}"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Map `uname -m` onto Go's release arch naming.
go_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo amd64 ;;
        aarch64|arm64)  echo arm64 ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

# --- toolchain check (Debian/Ubuntu package names) --------------------------
check_deps() {
    local missing=()
    command -v curl >/dev/null || missing+=("curl")
    command -v tar  >/dev/null || missing+=("tar")
    command -v git  >/dev/null || missing+=("git")
    command -v gcc  >/dev/null || missing+=("build-essential")
    command -v make >/dev/null || missing+=("make")
    if (( ${#missing[@]} )); then
        die "missing dependencies. Install with:
    sudo apt update && sudo apt install -y ${missing[*]}"
    fi
}

# --- install the latest stable Go into $GOROOT ------------------------------
install_go() {
    local version arch tarball url SUDO=""
    msg "Querying latest stable Go version"
    version="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)" \
        || die "failed to query latest Go version"
    arch="$(go_arch)"
    tarball="${version}.linux-${arch}.tar.gz"
    url="https://go.dev/dl/${tarball}"
    [[ -w /usr/local ]] || SUDO="sudo"

    msg "Installing $version (linux/$arch) into $GOROOT"
    local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    curl -fSL --retry 3 -o "$tmp/$tarball" "$url" || die "download failed: $url"
    $SUDO rm -rf "$GOROOT"
    $SUDO tar -C /usr/local -xzf "$tmp/$tarball"
    [[ -x "$GOROOT/bin/go" ]] || die "expected go binary at $GOROOT/bin/go after extraction"
    export PATH="$GOROOT/bin:$PATH"
    msg "Installed: $(go version)"
}

# --- clone + build syzkaller ------------------------------------------------
build_syzkaller() {
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

    msg "Building syzkaller ($REF) for linux/$TARGETARCH"
    make -C "$SRC_DIR" -j"$(nproc)" TARGETOS=linux TARGETARCH="$TARGETARCH"
    msg "Done. syzkaller binaries in $SRC_DIR/bin"
    ls "$SRC_DIR/bin" 2>/dev/null || true
}

main() {
    check_deps
    if command -v go >/dev/null; then
        msg "Using existing Go: $(go version)"
    else
        install_go
    fi
    build_syzkaller
}

main "$@"
