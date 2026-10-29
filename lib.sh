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
