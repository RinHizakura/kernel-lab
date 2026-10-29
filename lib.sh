# Shared prelude for the kernel-lab scripts. Source it, do not run it:
#   source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib.sh"
#
# Messages go to stderr so a script's stdout stays free for data.

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# need_tools CMD[:PACKAGE]...: die naming the apt packages of the missing
# commands. PACKAGE defaults to CMD and may hold several packages.
need_tools() {
    local t missing=()
    for t in "$@"; do
        command -v "${t%%:*}" >/dev/null || missing+=("${t#*:}")
    done
    (( ${#missing[@]} )) || return 0
    die "missing tools. Install with:
    sudo apt update && sudo apt install -y ${missing[*]}"
}

# shallow_clone REPO REF DIR: a --depth 1 checkout of REF (branch, tag or
# commit) in DIR, updated in place when DIR already holds a clone. A full
# clone of a kernel or QEMU is huge and prone to mid-transfer disconnects;
# one ref at depth 1 is a tiny fraction of that.
shallow_clone() {
    local repo=$1 ref=$2 dir=$3
    if [[ -d $dir/.git ]]; then
        log "Updating $dir (ref $ref)"
    else
        log "Shallow-cloning $repo at $ref"
        mkdir -p "$(dirname "$dir")"
        git clone -q --depth 1 --no-checkout "$repo" "$dir" || die "clone failed"
    fi
    git -C "$dir" fetch -q --depth 1 origin "$ref" || die "fetch of $ref failed"
    git -C "$dir" checkout -q --detach FETCH_HEAD
}

# ARCH is always the vng --arch name: x86_64 arm64 riscv64 armhf ppc64el s390x.
# arch_name SCHEME ARCH gives that arch's spelling in another scheme:
#   kernel  make ARCH=              cross  toolchain prefix (empty = native)
#   deb     Debian/Ubuntu arch       qemu   qemu-system-<x>
#   go      GOARCH                   kimg   bootable image inside a kernel tree
arch_name() {
    local scheme=$1 arch=$2 row
    case $arch in
        x86_64)  row="x86_64 - amd64 x86_64 amd64 arch/x86/boot/bzImage" ;;
        arm64)   row="arm64 aarch64-linux-gnu- arm64 aarch64 arm64 arch/arm64/boot/Image" ;;
        riscv64) row="riscv riscv64-linux-gnu- riscv64 riscv64 riscv64 arch/riscv/boot/Image" ;;
        armhf)   row="arm arm-linux-gnueabihf- armhf arm arm arch/arm/boot/zImage" ;;
        ppc64el) row="powerpc powerpc64le-linux-gnu- ppc64el ppc64 ppc64le vmlinux" ;;
        s390x)   row="s390 s390x-linux-gnu- s390x s390x s390x arch/s390/boot/bzImage" ;;
        *) die "unknown arch '$arch' (one of: x86_64 arm64 riscv64 armhf ppc64el s390x)" ;;
    esac
    # shellcheck disable=SC2086
    set -- $row
    case $scheme in
        kernel) echo "$1" ;;
        cross)  [[ $2 == - ]] || echo "$2" ;;
        deb)    echo "$3" ;;
        qemu)   echo "$4" ;;
        go)     echo "$5" ;;
        kimg)   echo "$6" ;;
        *) die "arch_name: unknown scheme '$scheme'" ;;
    esac
}

# host_arch: the vng name of the machine this runs on.
host_arch() {
    case $(uname -m) in
        x86_64)  echo x86_64 ;;
        aarch64) echo arm64 ;;
        riscv64) echo riscv64 ;;
        armv7l)  echo armhf ;;
        ppc64le) echo ppc64el ;;
        s390x)   echo s390x ;;
        *) die "unsupported host architecture: $(uname -m)" ;;
    esac
}

# kernel_release KDIR: the release string of the kernel built in KDIR, empty
# if nothing has been built there yet.
kernel_release() { cat "$1/include/config/kernel.release" 2>/dev/null || true; }
