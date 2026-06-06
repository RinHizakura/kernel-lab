#!/usr/bin/env bash
#
# deploy-rpi-kernel.sh — Cross-build this upstream kernel tree and deploy it
#                 to a remote Raspberry Pi 4 (arm64) running Ubuntu.
#
# The remote user needs passwordless sudo, and initramfs-tools (default on
# Ubuntu).
#
# Usage:
#   ./deploy-rpi.sh --target pi@192.168.1.50
#   DEPLOY_TARGET=pi@raspberrypi.local ./deploy-rpi.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via flags or environment)
# ---------------------------------------------------------------------------
: "${DEPLOY_TARGET:=pi@CHANGE-ME}"        # ssh target, e.g. pi@192.168.1.50
: "${ARCH:=arm64}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${JOBS:=$(nproc)}"
: "${DTB:=bcm2711-rpi-4-b.dtb}"           # Pi 4 device tree
: "${BOOT_DIR:=/boot/firmware}"           # Raspberry Pi OS boot partition mount
: "${LOCALVERSION:=-test}"                # version suffix -> KREL, e.g. 7.0.11-test
: "${KERNEL_NAME:=}"                      # boot image filename; default kernel-<KREL>.img
: "${SSH_OPTS:=-o ConnectTimeout=10}"

DO_BUILD=1
DO_REBOOT=0
DO_DEFCONFIG=auto      # auto = run defconfig only if .config is missing

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_DIR="${SRC_DIR}/.deploy-staging"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

ssh_pi() {
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$DEPLOY_TARGET" "$@"
}

usage() {
  sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | sed '/^[^#]/d; s/^#//; s/^ //'
  cat <<EOF

Flags:
  --target USER@HOST   SSH target (default: \$DEPLOY_TARGET)
  -j N                 Parallel build jobs (default: nproc = $JOBS)
  --localversion STR   Version suffix appended to KREL (default: $LOCALVERSION)
  --defconfig          Force 'make defconfig' before building
  --menuconfig         Run menuconfig after defconfig
  --no-build           Skip the build, deploy existing artifacts
  --reboot             Reboot the Pi after deploying
  --kernel-name NAME   Boot image filename (default: vmlinuz-<KREL>)
  -h, --help           This help
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MENUCONFIG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target)       DEPLOY_TARGET="$2"; shift 2;;
    -j)             JOBS="$2"; shift 2;;
    --localversion) LOCALVERSION="$2"; shift 2;;
    --defconfig)    DO_DEFCONFIG=force; shift;;
    --menuconfig)   DO_DEFCONFIG=force; MENUCONFIG=1; shift;;
    --no-build)     DO_BUILD=0; shift;;
    --reboot)       DO_REBOOT=1; shift;;
    --kernel-name)  KERNEL_NAME="$2"; shift 2;;
    -h|--help)      usage; exit 0;;
    *)              die "Unknown argument: $1 (try --help)";;
  esac
done

MAKE=(make -C "$SRC_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" -j"$JOBS")

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[ "$DEPLOY_TARGET" = "pi@CHANGE-ME" ] && \
  die "Set the SSH target: --target pi@HOST  (or export DEPLOY_TARGET)"
command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || \
  die "Cross compiler ${CROSS_COMPILE}gcc not found in PATH"

# ---------------------------------------------------------------------------
# 1. Build
# ---------------------------------------------------------------------------
if [ "$DO_BUILD" = 1 ]; then
  if [ "$DO_DEFCONFIG" = force ] || { [ "$DO_DEFCONFIG" = auto ] && [ ! -f "$SRC_DIR/.config" ]; }; then
    log "Generating .config from arm64 defconfig"
    "${MAKE[@]}" defconfig
    [ "$MENUCONFIG" = 1 ] && "${MAKE[@]}" menuconfig
  else
    log "Reusing existing .config"
  fi

  log "Building Image, modules and DTBs (-j$JOBS)"
  "${MAKE[@]}" Image modules dtbs

  log "Installing modules into staging dir"
  rm -rf "$STAGE_DIR"
  "${MAKE[@]}" INSTALL_MOD_PATH="$STAGE_DIR" modules_install
fi

KREL="$("${MAKE[@]}" -s kernelrelease 2>/dev/null)"
[ -n "$KREL" ] || die "Could not determine kernel release (build first?)"
[ -n "$KERNEL_NAME" ] || KERNEL_NAME="vmlinuz-${KREL}"   # Ubuntu naming convention
INITRD_NAME="initrd.img-${KREL}"
log "Kernel release: $KREL  ->  $BOOT_DIR/$KERNEL_NAME (+ $INITRD_NAME)"

IMAGE="$SRC_DIR/arch/arm64/boot/Image"
DTB_SRC="$SRC_DIR/arch/arm64/boot/dts/broadcom/$DTB"
[ -f "$IMAGE" ]   || die "Missing $IMAGE — run the build first."
[ -f "$DTB_SRC" ] || die "Missing $DTB_SRC — run the build first."

# ---------------------------------------------------------------------------
# 2. Package modules
# ---------------------------------------------------------------------------
MOD_TARBALL="$SRC_DIR/.deploy-modules-${KREL}.tar.gz"
if [ "$DO_BUILD" = 1 ] || [ ! -f "$MOD_TARBALL" ]; then
  [ -d "$STAGE_DIR/lib/modules/$KREL" ] || die "No staged modules at $STAGE_DIR/lib/modules/$KREL"
  log "Packaging modules -> $(basename "$MOD_TARBALL")"
  tar -C "$STAGE_DIR" -czf "$MOD_TARBALL" "lib/modules/$KREL"
fi

# ---------------------------------------------------------------------------
# 3. Deploy
# ---------------------------------------------------------------------------
log "Checking connectivity to $DEPLOY_TARGET"
ssh_pi true || die "Cannot reach $DEPLOY_TARGET over SSH"

log "Verifying boot partition at $BOOT_DIR on the Pi"
ssh_pi "test -d '$BOOT_DIR' && test -f '$BOOT_DIR/config.txt'" \
  || die "$BOOT_DIR/config.txt not found on the Pi — wrong BOOT_DIR?"

log "Verifying initramfs tooling on the Pi"
ssh_pi "command -v mkinitramfs >/dev/null 2>&1" \
  || die "mkinitramfs missing on the Pi — run: sudo apt install initramfs-tools"

REMOTE_TMP="/tmp/kdeploy.$$"
ssh_pi "mkdir -p '$REMOTE_TMP'"

log "Copying kernel image, DTB and modules"
# shellcheck disable=SC2086
scp $SSH_OPTS "$IMAGE"       "$DEPLOY_TARGET:$REMOTE_TMP/$KERNEL_NAME"
# shellcheck disable=SC2086
scp $SSH_OPTS "$DTB_SRC"     "$DEPLOY_TARGET:$REMOTE_TMP/$DTB"
# shellcheck disable=SC2086
scp $SSH_OPTS "$MOD_TARBALL" "$DEPLOY_TARGET:$REMOTE_TMP/modules.tar.gz"

log "Installing on the Pi (backs up existing files with .bak)"
ssh_pi "sudo sh -euc '
  ts=\$(date +%Y%m%d-%H%M%S)
  # modules first — the initramfs is built from them
  rm -rf \"/lib/modules/$KREL\"
  tar -C / -xzf \"$REMOTE_TMP/modules.tar.gz\"
  depmod \"$KREL\"
  # kernel image
  [ -f \"$BOOT_DIR/$KERNEL_NAME\" ] && cp \"$BOOT_DIR/$KERNEL_NAME\" \"$BOOT_DIR/$KERNEL_NAME.bak-\$ts\"
  install -m644 \"$REMOTE_TMP/$KERNEL_NAME\" \"$BOOT_DIR/$KERNEL_NAME\"
  # device tree
  [ -f \"$BOOT_DIR/$DTB\" ] && cp \"$BOOT_DIR/$DTB\" \"$BOOT_DIR/$DTB.bak-\$ts\"
  install -m644 \"$REMOTE_TMP/$DTB\" \"$BOOT_DIR/$DTB\"
  # initramfs for this kernel version (Ubuntu boots via initrd)
  mkinitramfs -o \"$BOOT_DIR/$INITRD_NAME\" \"$KREL\"
  # register kernel + initrd in config.txt (idempotent, non-destructive)
  cfg=\"$BOOT_DIR/config.txt\"
  cp \"\$cfg\" \"\$cfg.bak-\$ts\"
  if ! grep -q \"^kernel=$KERNEL_NAME\$\" \"\$cfg\"; then
    sed -i \"s/^\\(kernel=.*\\)/#\\1/; s/^\\(initramfs .*\\)/#\\1/\" \"\$cfg\"
    printf \"\n# Added by deploy-rpi.sh\n[all]\narm_64bit=1\nkernel=$KERNEL_NAME\ninitramfs $INITRD_NAME followkernel\n\" >> \"\$cfg\"
  fi
  rm -rf \"$REMOTE_TMP\"
  echo \"installed kernel=$KERNEL_NAME initrd=$INITRD_NAME modules=$KREL\"
'"

# ---------------------------------------------------------------------------
# 4. Reboot
# ---------------------------------------------------------------------------
if [ "$DO_REBOOT" = 1 ]; then
  log "Rebooting the Pi"
  ssh_pi "sudo reboot" || true
  log "Reboot issued. After it comes back: ssh $DEPLOY_TARGET 'uname -r' (expect $KREL)"
else
  log "Done. Reboot the Pi to use the new kernel:"
  echo "    ssh $DEPLOY_TARGET 'sudo reboot'"
  echo "    # then verify:  ssh $DEPLOY_TARGET 'uname -r'   -> $KREL"
fi
