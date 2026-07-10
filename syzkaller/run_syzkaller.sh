#!/usr/bin/env bash
#
# Launch syz-manager, or manage the crashes it found. The web dashboard is
# served at the "http" address in config.cfg (default http://127.0.0.1:56741).
#
# Always runs as root (re-execs itself under sudo): syz-manager owns the QEMU
# VMs and writes a root-owned workdir, so we keep it consistent by forcing root.
#
# Usage:
#   ./run_syzkaller.sh                      # fuzz (use ./build/config.cfg)
#   ./run_syzkaller.sh -- -debug            # fuzz, pass extra flags to syz-manager
#   ./run_syzkaller.sh list                 # list all crashes + repro status
#   ./run_syzkaller.sh gen-repro <hash>     # minimise a crash into repro.prog/.cprog
#   ./run_syzkaller.sh run-repro <hash>     # push + run the repro on the target
#   ./run_syzkaller.sh clean [-y]           # delete ALL crashes
#   CONFIG=other.cfg ./run_syzkaller.sh ...
#
set -euo pipefail

# Force root. Re-exec under sudo (preserving CONFIG) when not already root.
if [[ $EUID -ne 0 ]]; then
    exec sudo --preserve-env=CONFIG "$(realpath "${BASH_SOURCE[0]}")" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/build/syzkaller"
CONFIG="${CONFIG:-$SCRIPT_DIR/build/config.cfg}"
QEMU_BIN_DIR="$SCRIPT_DIR/../qemu/install/bin"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$CONFIG" ]] || die "config not found: $CONFIG; run ./5-gen_config.sh"

# workdir/crashes live where config.cfg points (fallback to the default layout).
WORKDIR="$(command -v jq >/dev/null && jq -er '.workdir' "$CONFIG" 2>/dev/null || echo "$SCRIPT_DIR/build/workdir")"
CRASHES="$WORKDIR/crashes"

# --- subcommands -------------------------------------------------------------

cmd_list() {
    [[ -d "$CRASHES" ]] || die "no crashes dir yet: $CRASHES"
    shopt -s nullglob
    local d hash desc repro n=0
    printf '%-40s  %-6s  %s\n' "HASH" "REPRO" "DESCRIPTION"
    for d in "$CRASHES"/*/; do
        n=$((n + 1))
        hash="$(basename "$d")"
        desc="$(cat "$d/description" 2>/dev/null || echo '?')"
        repro="-"
        [[ -f "$d/repro.prog"  ]] && repro="syz"
        [[ -f "$d/repro.cprog" ]] && repro="syz+c"
        printf '%-40s  %-6s  %s\n' "$hash" "$repro" "$desc"
    done
    [[ $n -gt 0 ]] || echo "(no crashes)"
}

# Resolve "<hash>" (a full name or unambiguous prefix) to its crash dir.
crash_dir() {
    local want="${1:?usage: <hash>}"
    [[ -d "$CRASHES/$want" ]] && { echo "$CRASHES/$want"; return; }
    shopt -s nullglob
    local m=() d
    for d in "$CRASHES/$want"*/; do m+=("$d"); done
    [[ ${#m[@]} -eq 1 ]] || die "hash '$want' matched ${#m[@]} crashes; be more specific (try: list)"
    echo "${m[0]%/}"
}

cmd_gen_repro() {
    [[ -x "$SRC_DIR/bin/syz-repro" ]] || die "syz-repro not built"
    local d; d="$(crash_dir "${1:-}")"
    local log="${2:-log0}"
    [[ "$log" == /* ]] || log="$d/$log"
    [[ -f "$log" ]] || die "log not found: $log"
    echo "Minimising $log via the target in $CONFIG (can take many minutes)..."
    exec "$SRC_DIR/bin/syz-repro" -config "$CONFIG" \
        -output "$d/repro.prog" -crepro "$d/repro.cprog" "$log"
}

cmd_run_repro() {
    command -v jq >/dev/null || die "jq required for run-repro"
    [[ "$(jq -r '.type' "$CONFIG")" == "isolated" ]] \
        || die "run-repro only supports isolated (SSH) targets; for qemu build the C repro and run it in a VM"
    local d; d="$(crash_dir "${1:-}")"

    local prog="${2:-}"
    if [[ -z "$prog" ]]; then
        [[ -f "$d/repro.prog" ]] && prog="$d/repro.prog" || prog="$d/log0"
    elif [[ "$prog" != /* ]]; then
        prog="$d/$prog"
    fi
    [[ -f "$prog" ]] || die "prog not found: $prog (run gen-repro first, or pass a log name)"

    local arch host user key tdir
    arch="$(jq -r '.target | split("/")[1]' "$CONFIG")"
    read -r host user key tdir < <(jq -r '[.vm.targets[0], .ssh_user, .sshkey, .vm.target_dir // "/tmp/syzkaller"] | @tsv' "$CONFIG")
    local bindir="$SRC_DIR/bin/linux_$arch"
    [[ -x "$bindir/syz-execprog" && -x "$bindir/syz-executor" ]] || die "target binaries missing in $bindir"

    echo "Pushing execprog + $(basename "$prog") to $user@$host:$tdir ..."
    ssh -i "$key" -o StrictHostKeyChecking=no "$user@$host" "mkdir -p '$tdir'"
    scp -i "$key" -o StrictHostKeyChecking=no \
        "$bindir/syz-execprog" "$bindir/syz-executor" "$prog" "$user@$host:$tdir/"
    echo "Running on target (Ctrl-C to stop; watch its console for the crash)..."
    exec ssh -t -i "$key" -o StrictHostKeyChecking=no "$user@$host" \
        "cd '$tdir' && ./syz-execprog -executor=./syz-executor -repeat=0 -procs=1 '$(basename "$prog")'"
}

cmd_clean() {
    [[ -d "$CRASHES" ]] || { echo "nothing to delete: $CRASHES"; return; }
    if [[ "${1:-}" != "-y" ]]; then
        read -rp "Delete ALL crashes under $CRASHES? [y/N] " ans
        [[ "$ans" == [yY] ]] || die "aborted"
    fi
    rm -rf "${CRASHES:?}"/*
    echo "deleted all crashes in $CRASHES"
}

cmd_run() {
    [[ -x "$SRC_DIR/bin/syz-manager" ]] || die "syz-manager not built; run ./2-build_syzkaller.sh"
    [[ -d "$QEMU_BIN_DIR" ]] && export PATH="$QEMU_BIN_DIR:$PATH"

    # Preflight: for isolated targets, syz-manager silently retries when SSH
    # fails (e.g. Tailscale SSH wanting browser re-auth). Fail loudly instead.
    if command -v jq >/dev/null && [[ "$(jq -r '.type' "$CONFIG")" == "isolated" ]]; then
        read -r host user key < <(jq -r '[.vm.targets[0], .ssh_user, .sshkey] | @tsv' "$CONFIG")
        ssh -i "$key" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 \
            "$user@$host" true 2>/dev/null \
            || die "SSH to $user@$host failed; fix connectivity before fuzzing (Tailscale SSH may need ACL 'accept' instead of 'check')"
    fi
    exec "$SRC_DIR/bin/syz-manager" -config "$CONFIG" "$@"
}

# --- dispatch ----------------------------------------------------------------

case "${1:-run}" in
    list)      shift; cmd_list "$@" ;;
    gen-repro) shift; cmd_gen_repro "$@" ;;
    run-repro) shift; cmd_run_repro "$@" ;;
    clean)     shift; cmd_clean "$@" ;;
    run|--|-*) # fuzz (default). `run`/`--` are stripped; other flags pass through.
        [[ "${1:-}" == "run" || "${1:-}" == "--" ]] && shift
        cmd_run "$@" ;;
    *) die "unknown command: $1 (want: list | gen-repro | run-repro | clean, or no arg to fuzz)" ;;
esac
