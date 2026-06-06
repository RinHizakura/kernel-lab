#!/usr/bin/env bash
#
# deploy-kernel.sh — build / deploy / switch a WSL2 custom kernel
#
# Default (build + deploy):
#   1. Compile the kernel (make -j$(nproc)); a tag is baked into LOCALVERSION
#      so it also shows up in `uname -r` (e.g. ...-WSL2-A) for easy ID
#   2. Copy bzImage to the Windows home dir, named by version (= uname -r)
#   3. Point .wslconfig kernel= at the freshly deployed image
#   4. Print the wsl --shutdown reminder to switch
#
# Usage:
#   ./deploy-kernel.sh            # build + deploy, uname = <ver>-WSL2+
#   ./deploy-kernel.sh -t A       # build + deploy, uname = <ver>-WSL2-A
#   ./deploy-kernel.sh A          # same (tag may also be a positional arg)
#   ./deploy-kernel.sh -c         # compile only, no deploy
#   ./deploy-kernel.sh -c -t A    # compile + stage (uname/name carry -A; no .wslconfig change)
#   ./deploy-kernel.sh -k NAME    # switch only: point .wslconfig at an existing image
#   ./deploy-kernel.sh -d NAME    # delete a deployed image (refuses if it's the active one)
#   ./deploy-kernel.sh -l         # list deployed images + current .wslconfig target
#
set -euo pipefail

# ── Config ───────────────────────────────────────────
KSRC=""
WIN_HOME_WSL=""          # Windows home (WSL view)
WIN_HOME_WIN=""              # same dir (Windows view, for .wslconfig)
WSLCONFIG="$WIN_HOME_WSL/.wslconfig"
# ─────────────────────────────────────────────────────

MODE="deploy"      # deploy | compile | switch | list | delete
SWITCH_TO=""
DELETE_TO=""
TAG=""             # build tag, e.g. A / B  (via -t or positional)

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,21p' "$0"; exit "${1:-0}"; }

while getopts "cd:k:lt:h" opt; do
  case "$opt" in
    c) MODE="compile" ;;
    d) MODE="delete"; DELETE_TO="$OPTARG" ;;
    k) MODE="switch"; SWITCH_TO="$OPTARG" ;;
    l) MODE="list" ;;
    t) TAG="$OPTARG" ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
TAG="${TAG:-${1:-}}"   # tag from -t, falling back to positional arg

set_kernel_line() {  # $1 = Windows-view path
  [ -f "$WSLCONFIG" ] || die ".wslconfig not found: $WSLCONFIG"
  cp "$WSLCONFIG" "$WSLCONFIG.bak"
  if grep -q '^kernel=' "$WSLCONFIG"; then
    sed -i "s|^kernel=.*|kernel=$1|" "$WSLCONFIG"
  else
    sed -i "/^\[wsl2\]/a kernel=$1" "$WSLCONFIG"
  fi
  log ".wslconfig kernel= -> $1  (backup: .wslconfig.bak)"
}

shutdown_hint() {
  echo
  log "Done. To switch to this kernel, run (from Windows or here):"
  echo "    wsl.exe --shutdown"
  echo "  Then reopen WSL and verify with: uname -r"
}

# ── list ─────────────────────────────────────────────
if [ "$MODE" = "list" ]; then
  log "Deployed kernels in $WIN_HOME_WSL:"
  ls -1t "$WIN_HOME_WSL"/bzImage* 2>/dev/null | sed 's|.*/||;s|^|  |' || echo "  (none)"
  echo
  log "Current .wslconfig target:"
  grep '^kernel=' "$WSLCONFIG" 2>/dev/null | sed 's|^|  |' || echo "  (unset)"
  exit 0
fi

# ── delete ───────────────────────────────────────────
if [ "$MODE" = "delete" ]; then
  TARGET="$WIN_HOME_WSL/$DELETE_TO"
  [ -f "$TARGET" ] || die "image not found: $TARGET  (try -l)"
  active="$(grep '^kernel=' "$WSLCONFIG" 2>/dev/null | sed 's|^kernel=.*/||')"
  if [ "$active" = "$DELETE_TO" ]; then
    die "refusing: '$DELETE_TO' is the active .wslconfig kernel — switch (-k) to another first"
  fi
  rm -f "$TARGET"
  log "deleted $TARGET"

  # Drop the matching modules dir (image is named bzImage-<VER>; modules live
  # at /lib/modules/<VER>). Only the bzImage-<ver> form maps to a module dir.
  VER="${DELETE_TO#bzImage-}"
  MODDIR="/lib/modules/$VER"
  if [ "$VER" != "$DELETE_TO" ] && [ -d "$MODDIR" ]; then
    sudo rm -rf "$MODDIR"
    log "deleted modules $MODDIR"
  fi
  exit 0
fi

# ── Step 1: compile (skipped for switch-only) ────────
if [ "$MODE" != "switch" ]; then
  cd "$KSRC"
  # Bake the tag into LOCALVERSION so it lands in `uname -r` (and the module
  # dir name). Setting LOCALVERSION also drops the trailing "+" that
  # setlocalversion adds when it's unset. Untagged builds keep the "+".
  LV=()
  [ -n "$TAG" ] && LV=("LOCALVERSION=-$TAG")
  log "make -j$(nproc) ${LV[*]:+(${LV[*]})}..."
  make -j"$(nproc)" "${LV[@]}"
  BZ="$KSRC/arch/x86/boot/bzImage"
  [ -f "$BZ" ] || die "bzImage not found after build"

  VER="$(make -s kernelrelease "${LV[@]}")"   # already includes -$TAG
  DEST_NAME="bzImage-$VER"
  log "kernel version: $VER${TAG:+  (tag: $TAG)}"

  log "installing modules -> /lib/modules/$VER ..."
  sudo make -s modules_install INSTALL_MOD_STRIP=1 "${LV[@]}"

  # compile only: stage a tagged copy (so it's switchable later) but never touch .wslconfig
  if [ "$MODE" = "compile" ]; then
    if [ -n "$TAG" ]; then
      log "staging bzImage -> $WIN_HOME_WSL/$DEST_NAME  (.wslconfig unchanged)"
      cp "$BZ" "$WIN_HOME_WSL/$DEST_NAME"
      log "switch later with: $(basename "$0") -k $DEST_NAME"
    else
      log "compile only: $BZ  (not staged)"
    fi
    exit 0
  fi
fi

# ── Step 2: stage to Windows + point .wslconfig ──────
if [ "$MODE" = "switch" ]; then
  DEST_NAME="$SWITCH_TO"
  [ -f "$WIN_HOME_WSL/$DEST_NAME" ] || die "image not found: $WIN_HOME_WSL/$DEST_NAME  (try -l)"
else
  log "copying bzImage -> $WIN_HOME_WSL/$DEST_NAME"
  cp "$BZ" "$WIN_HOME_WSL/$DEST_NAME"
fi

set_kernel_line "$WIN_HOME_WIN/$DEST_NAME"
shutdown_hint
