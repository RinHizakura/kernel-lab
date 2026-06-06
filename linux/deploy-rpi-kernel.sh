#!/usr/bin/env bash
#
# deploy-rpi-kernel.sh — Cross-build an upstream kernel tree and deploy it to a
#                 remote Raspberry Pi 4 (arm64) running Ubuntu, via the firmware
#                 A/B "tryboot" slot so a bad kernel can never brick the Pi.
#
# Boot layout (Ubuntu A/B), /boot/firmware/config.txt:
#   [all]      os_prefix=current/    <- normal boot (your active kernel)
#   [tryboot]  os_prefix=new/        <- booted ONCE on 'reboot "0 tryboot"'
#
# Flow:
#   ./deploy-rpi-kernel.sh            # build, stage new/, reboot once into it (tryboot)
#   ssh $DEPLOY_TARGET uname -r       # confirm it's your kernel
#   ./deploy-rpi-kernel.sh --promote  # make it permanent: new/ -> current/, old kept as old/
#
# If the tryboot kernel fails to boot, just power-cycle: the firmware reverts to
# current/ automatically (tryboot is one-shot). current/ is only changed by
# --promote, which refuses unless the Pi is actually running the new kernel.
#
# Recovery if a *promoted* kernel later misbehaves (from another PC with the SD
# card, or via UART): edit /boot/firmware/config.txt -> change os_prefix=current/
# to os_prefix=old/, save, reboot.
#
# The remote user needs passwordless sudo, and initramfs-tools (default on Ubuntu).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via flags or environment)
# ---------------------------------------------------------------------------
: "${DEPLOY_TARGET:=pi@CHANGE-ME}"        # ssh target, e.g. pi@192.168.1.50
: "${ARCH:=arm64}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${JOBS:=$(nproc)}"
: "${DEFCONFIG:=bcm2711_defconfig}"       # in-tree defconfig (arch/arm64/configs/)
: "${DTB:=bcm2711-rpi-4-b.dtb}"           # Pi 4 device tree (rebuilt and deployed)
: "${BOOT_DIR:=/boot/firmware}"           # Raspberry Pi boot partition mount
: "${LOCALVERSION:=-test}"                # version suffix -> KREL, e.g. 7.0.11-test
: "${SSH_OPTS:=-o ConnectTimeout=10}"
: "${KSRC:=}"                             # kernel source tree (set to your tree, absolute path)

DO_BUILD=1
DO_PROMOTE=0
DO_DEFCONFIG=auto      # auto = run defconfig only if .config is missing
MENUCONFIG=0

# SRC_DIR / STAGE_DIR are resolved from KSRC after argument parsing.

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
  --localversion STR   Version suffix appended to KREL (default: $LOCALVERSION)
  --defconfig          Force 'make \$DEFCONFIG' before building (default: $DEFCONFIG)
  --menuconfig         Run menuconfig after defconfig
  --no-build           Skip the build, (re)stage existing artifacts into new/
  --promote            Make the tryboot kernel permanent (new/ -> current/); skips build
  -h, --help           This help
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --target)       DEPLOY_TARGET="$2"; shift 2;;
    --localversion) LOCALVERSION="$2"; shift 2;;
    --defconfig)    DO_DEFCONFIG=force; shift;;
    --menuconfig)   DO_DEFCONFIG=force; MENUCONFIG=1; shift;;
    --no-build)     DO_BUILD=0; shift;;
    --promote)      DO_PROMOTE=1; shift;;
    -h|--help)      usage; exit 0;;
    *)              die "Unknown argument: $1 (try --help)";;
  esac
done

[ "$DEPLOY_TARGET" = "pi@CHANGE-ME" ] && \
  die "Set the SSH target: --target pi@HOST  (or export DEPLOY_TARGET)"

# ---------------------------------------------------------------------------
# Promote: rotate new/ -> current/ (previous current/ -> old/), no build.
# Refuses unless the Pi is actually running the kernel staged in new/.
# ---------------------------------------------------------------------------
if [ "$DO_PROMOTE" = 1 ]; then
  log "Checking connectivity to $DEPLOY_TARGET"
  ssh_pi true || die "Cannot reach $DEPLOY_TARGET over SSH"
  log "Promoting new/ -> current/ (previous current/ -> old/)"
  ssh_pi "sudo sh -euc '
    set -eu
    BOOT=\"$BOOT_DIR\"
    [ -d \"\$BOOT/new\" ] || { echo \"no \$BOOT/new to promote — deploy first\"; exit 1; }
    want=\$(cat \"\$BOOT/new/.deploy-krel\" 2>/dev/null || echo \"\")
    run=\$(uname -r)
    if [ -z \"\$want\" ] || [ \"\$want\" != \"\$run\" ]; then
      echo \"REFUSING: new/ holds \${want:-?} but the Pi is running \$run.\"
      echo \"Boot the new kernel first:  sudo reboot \\\"0 tryboot\\\"  then re-run --promote.\"
      exit 1
    fi
    rm -rf \"\$BOOT/old\"
    mv \"\$BOOT/current\" \"\$BOOT/old\"
    mv \"\$BOOT/new\"     \"\$BOOT/current\"
    echo \"promoted: current/=\$run ; old/=previous (fallback)\"
  '"
  log "Done. Normal reboots now run your kernel from current/. Fallback kept in old/."
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve kernel source tree (KSRC) + pre-flight
# ---------------------------------------------------------------------------
SRC_DIR=$(cd "$KSRC" 2>/dev/null && pwd) \
  || die "KSRC not set or not a directory: '${KSRC}'  (edit KSRC at the top, or export it)"
[ -f "$SRC_DIR/Makefile" ] && [ -d "$SRC_DIR/arch/$ARCH" ] \
  || die "KSRC does not look like a kernel tree: $SRC_DIR"
STAGE_DIR="${SRC_DIR}/.deploy-staging"
log "Kernel source: $SRC_DIR"

command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || \
  die "Cross compiler ${CROSS_COMPILE}gcc not found in PATH"

MAKE=(make -C "$SRC_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" -j"$JOBS")

# ---------------------------------------------------------------------------
# 1. Build
# ---------------------------------------------------------------------------
if [ "$DO_BUILD" = 1 ]; then
  if [ "$DO_DEFCONFIG" = force ] || { [ "$DO_DEFCONFIG" = auto ] && [ ! -f "$SRC_DIR/.config" ]; }; then
    log "Generating .config from $DEFCONFIG"
    "${MAKE[@]}" "$DEFCONFIG"
    # Deployment tweaks on top of the stock defconfig:
    #   - disable LOCALVERSION_AUTO so KREL stays a stable "X.Y.Z$LOCALVERSION"
    #     (no git hash / -dirty suffix) -> predictable module path on the Pi.
    log "Applying config tweaks (disable LOCALVERSION_AUTO)"
    "$SRC_DIR/scripts/config" --file "$SRC_DIR/.config" --disable LOCALVERSION_AUTO
    "${MAKE[@]}" olddefconfig
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
log "Kernel release: $KREL  ->  $BOOT_DIR/new/ (tryboot slot; current/ untouched)"

IMAGE="$SRC_DIR/arch/arm64/boot/Image"
CONFIG_SRC="$SRC_DIR/.config"
DTB_SRC="$SRC_DIR/arch/arm64/boot/dts/broadcom/$DTB"
SYSMAP_SRC="$SRC_DIR/System.map"
[ -f "$IMAGE" ]      || die "Missing $IMAGE — run the build first."
[ -f "$CONFIG_SRC" ] || die "Missing $CONFIG_SRC — run the build first."
[ -f "$DTB_SRC" ]    || die "Missing $DTB_SRC — run the build first (make dtbs)."
[ -f "$SYSMAP_SRC" ] || die "Missing $SYSMAP_SRC — run the build first."

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
# 3. Deploy into the new/ tryboot slot (current/ stays untouched)
# ---------------------------------------------------------------------------
log "Checking connectivity to $DEPLOY_TARGET"
ssh_pi true || die "Cannot reach $DEPLOY_TARGET over SSH"

log "Verifying A/B tryboot layout on the Pi"
ssh_pi "test -d '$BOOT_DIR/current' && grep -q 'tryboot_a_b=1' '$BOOT_DIR/autoboot.txt' && grep -q 'os_prefix=new/' '$BOOT_DIR/config.txt'" \
  || die "Pi is not using the current//new/ A/B tryboot layout — aborting to stay brick-safe."

log "Verifying initramfs tooling on the Pi"
ssh_pi "command -v mkinitramfs >/dev/null 2>&1" \
  || die "mkinitramfs missing on the Pi — run: sudo apt install initramfs-tools"

REMOTE_TMP="/tmp/kdeploy.$$"
ssh_pi "mkdir -p '$REMOTE_TMP'"

log "Copying kernel image, DTB, System.map, config and modules"
# shellcheck disable=SC2086
scp $SSH_OPTS "$IMAGE"       "$DEPLOY_TARGET:$REMOTE_TMP/vmlinuz"
# shellcheck disable=SC2086
scp $SSH_OPTS "$DTB_SRC"     "$DEPLOY_TARGET:$REMOTE_TMP/$DTB"
# shellcheck disable=SC2086
scp $SSH_OPTS "$SYSMAP_SRC"  "$DEPLOY_TARGET:$REMOTE_TMP/System.map-$KREL"
# shellcheck disable=SC2086
scp $SSH_OPTS "$CONFIG_SRC"  "$DEPLOY_TARGET:$REMOTE_TMP/config-$KREL"
# shellcheck disable=SC2086
scp $SSH_OPTS "$MOD_TARBALL" "$DEPLOY_TARGET:$REMOTE_TMP/modules.tar.gz"

log "Staging new/ slot on the Pi (current/ untouched)"
ssh_pi "sudo sh -euc '
  set -eu
  BOOT=\"$BOOT_DIR\"
  [ -d \"\$BOOT/current\" ] || { echo \"no \$BOOT/current slot\"; exit 1; }
  # modules first — the initramfs is built from them
  rm -rf \"/lib/modules/$KREL\"
  tar -C / -xzf \"$REMOTE_TMP/modules.tar.gz\"
  depmod \"$KREL\"
  # kernel config -> /boot/config-<KREL> so mkinitramfs can verify compression
  install -m644 \"$REMOTE_TMP/config-$KREL\" \"/boot/config-$KREL\"
  # System.map -> rootfs (debug aid; mode 600 to match stock)
  install -m600 \"$REMOTE_TMP/System.map-$KREL\" \"/boot/System.map-$KREL\"
  # rebuilt DTB -> rootfs dtbs dir (Ubuntu convention; not boot-critical here)
  mkdir -p \"/boot/dtbs/$KREL\"
  install -m644 \"$REMOTE_TMP/$DTB\" \"/boot/dtbs/$KREL/$DTB\"
  # build the new/ tryboot slot: clone golden current/, overlay our kernel + DTB
  rm -rf \"\$BOOT/new\"
  cp -r \"\$BOOT/current\" \"\$BOOT/new\"
  install -m644 \"$REMOTE_TMP/vmlinuz\" \"\$BOOT/new/vmlinuz\"
  install -m644 \"$REMOTE_TMP/$DTB\" \"\$BOOT/new/$DTB\"
  mkinitramfs -o \"\$BOOT/new/initrd.img\" \"$KREL\"
  printf %s \"$KREL\" > \"\$BOOT/new/.deploy-krel\"
  rm -rf \"$REMOTE_TMP\"
  echo \"new/ slot ready: $KREL  (kernel+DTB; current/ untouched)\"
'"

# ---------------------------------------------------------------------------
# 4. Tryboot: boot the new/ slot once (one-shot; auto-reverts if it fails)
# ---------------------------------------------------------------------------
log "Rebooting once into the new/ slot via tryboot"
ssh_pi "sudo reboot '0 tryboot'" || true

cat <<EOF

$(log "Tryboot issued — the Pi boots new/ exactly once.")
  After it comes back, verify:
      ssh $DEPLOY_TARGET 'uname -r'      # expect: $KREL
  If it booted and looks good, make it permanent:
      $0 --promote
  If it did NOT come back (or shows the old kernel), it failed safely — the
  firmware reverted to current/. Power-cycle if needed; nothing was promoted.
EOF
