#!/usr/bin/env bash
#
# Install the latest stable Go toolchain from https://go.dev/dl/.
#
# Layout:
#   GOROOT (default /usr/local/go)   extracted Go toolchain
#
# The Go binaries live in $GOROOT/bin; add it to your PATH:
#   export PATH="/usr/local/go/bin:$PATH"
#
# Usage:
#   ./1-install_go.sh                       # latest stable, host arch
#   GO_VERSION=go1.22.5 ./1-install_go.sh   # pin a specific version
#   GOROOT=$HOME/go-sdk ./1-install_go.sh   # install somewhere without sudo
#
set -euo pipefail

GOROOT="${GOROOT:-/usr/local/go}"
GO_VERSION="${GO_VERSION:-}"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- toolchain check --------------------------------------------------------
check_deps() {
    local missing=()
    command -v curl >/dev/null || missing+=("curl")
    command -v tar  >/dev/null || missing+=("tar")
    if (( ${#missing[@]} )); then
        die "missing dependencies. Install with:
    sudo apt update && sudo apt install -y ${missing[*]}"
    fi
}

# Map `uname -m` onto Go's release arch naming.
go_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo amd64  ;;
        aarch64|arm64)  echo arm64  ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

main() {
    check_deps

    local arch
    arch="$(go_arch)"

    # Resolve the latest stable version if not pinned.
    if [[ -z "$GO_VERSION" ]]; then
        msg "Querying latest stable Go version"
        GO_VERSION="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)" \
            || die "failed to query latest Go version"
    fi
    [[ "$GO_VERSION" == go* ]] || die "GO_VERSION should look like 'go1.22.5', got '$GO_VERSION'"

    local tarball="${GO_VERSION}.linux-${arch}.tar.gz"
    local url="https://go.dev/dl/${tarball}"

    msg "Installing $GO_VERSION (linux/$arch) into $GOROOT"

    # Pick a sudo prefix only when we lack write access to the parent dir.
    local parent SUDO=""
    parent="$(dirname "$GOROOT")"
    if [[ ! -w "$parent" ]]; then
        command -v sudo >/dev/null || die "no write access to $parent and sudo not found"
        SUDO="sudo"
    fi

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    msg "Downloading $url"
    curl -fSL --retry 3 -o "$tmp/$tarball" "$url" \
        || die "download failed: $url"

    msg "Removing any previous toolchain at $GOROOT"
    $SUDO rm -rf "$GOROOT"

    msg "Extracting"
    $SUDO mkdir -p "$parent"
    $SUDO tar -C "$parent" -xzf "$tmp/$tarball"

    local go_bin="$GOROOT/bin/go"
    [[ -x "$go_bin" ]] || die "expected go binary at $go_bin after extraction"

    msg "Installed: $("$go_bin" version)"
    msg "Add to PATH (e.g. in ~/.profile):  export PATH=\"$GOROOT/bin:\$PATH\""
}

main "$@"
