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
  ssh $SSH_OPTS "$DEPLOY_TARGET" "$@"
}

# stage_copy SRC NAME [DEPLOYED]
# Put local file SRC at $REMOTE_TMP/NAME for the install step. If DEPLOYED (a path
# already on the Pi) is byte-identical (md5), reuse it with a Pi-local cp instead
# of re-uploading over the network; otherwise scp. Omit DEPLOYED to always scp.
stage_copy() {
  local src="$1" name="$2" deployed="${3:-}"
  if [ -n "$deployed" ]; then
    local lsum rsum
    lsum=$(md5sum "$src" | cut -d' ' -f1)
    rsum=$(ssh_pi "md5sum '$deployed' 2>/dev/null | cut -d' ' -f1" || true)
    if [ -n "$rsum" ] && [ "$lsum" = "$rsum" ]; then
      log "  unchanged: $name (reuse Pi copy)"
      ssh_pi "cp '$deployed' '$REMOTE_TMP/$name'"
      return
    fi
  fi
  log "  uploading: $name"
  # shellcheck disable=SC2086
  scp $SSH_OPTS "$src" "$DEPLOY_TARGET:$REMOTE_TMP/$name"
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
    #   - enable SQUASHFS_XZ: bcm2711_defconfig sets SQUASHFS=y but leaves the xz
    #     decompressor off. Ubuntu snaps are xz-compressed squashfs, so without
    #     this they fail to mount ("Filesystem uses xz compression. This is not
    #     supported") and systemd hangs at boot. SQUASHFS_XZ selects XZ_DEC,
    #     which olddefconfig pulls in.
    log "Applying config tweaks (disable LOCALVERSION_AUTO; enable SQUASHFS_XZ)"
    "$SRC_DIR/scripts/config" --file "$SRC_DIR/.config" --disable LOCALVERSION_AUTO
    "$SRC_DIR/scripts/config" --file "$SRC_DIR/.config" --enable SQUASHFS_XZ
    "${MAKE[@]}" olddefconfig
    [ "$MENUCONFIG" = 1 ] && "${MAKE[@]}" menuconfig
  else
    log "Reusing existing .config"
  fi

  # Ensure the netfilter/routing features Tailscale needs, on TOP of whatever
  # .config we ended up with (fresh defconfig OR reused).
  log "Ensuring Tailscale/netfilter kernel options (=y)"
  TS_CONFIGS="
    NF_TABLES NFT_COMPAT
    NF_CONNTRACK NF_NAT
    NETFILTER_XT_MATCH_COMMENT NETFILTER_XT_MATCH_MARK
    NETFILTER_XT_MATCH_CONNTRACK
    NETFILTER_XT_MATCH_CONNMARK NETFILTER_XT_TARGET_CONNMARK
    NETFILTER_XT_TARGET_MASQUERADE
    IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES
    WIREGUARD
  "
  for opt in $TS_CONFIGS; do
    "$SRC_DIR/scripts/config" --file "$SRC_DIR/.config" --enable "$opt"
  done
  "${MAKE[@]}" olddefconfig

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
SYSMAP_SRC="$SRC_DIR/System.map"
DTB_NAME="bcm2711-rpi-4-b.dtb"
DTB_SRC="$SRC_DIR/arch/arm64/boot/dts/broadcom/$DTB_NAME"

# Vendor overlays in config.txt (vc4-kms-v3d/disable-bt/dwc2) are written against
# downstream labels; the firmware part-applies them to the upstream DTB and the
# kernel dies before console. The upstream DTB already enables vc4 KMS in-tree, so
# replace each with a no-op overlay in the new/ slot.
NEUTRALIZE_OVERLAYS="vc4-kms-v3d disable-bt dwc2"
DTC_BIN="$(command -v dtc || echo "$SRC_DIR/scripts/dtc/dtc")"

[ -f "$IMAGE" ]      || die "Missing $IMAGE — run the build first."
[ -f "$CONFIG_SRC" ] || die "Missing $CONFIG_SRC — run the build first."
[ -f "$SYSMAP_SRC" ] || die "Missing $SYSMAP_SRC — run the build first."
[ -f "$DTB_SRC" ]    || die "Missing $DTB_SRC — build dtbs first (make dtbs)."
[ -x "$DTC_BIN" ] || command -v "$DTC_BIN" >/dev/null 2>&1 \
  || die "dtc not found — install device-tree-compiler, or build the kernel (scripts/dtc/dtc)"

# Stage the upstream DTB + a no-op overlay on the build host ($DTB_WORK also holds
# the cmdline). The no-op replaces the incompatible vendor overlays in new/.
DTB_WORK="$SRC_DIR/.deploy-dtb"
DTB_OUT="$DTB_WORK/$DTB_NAME"
NOOP_DTBO="$DTB_WORK/noop.dtbo"
rm -rf "$DTB_WORK"; mkdir -p "$DTB_WORK"
cp "$DTB_SRC" "$DTB_OUT"
printf '/dts-v1/;\n/plugin/;\n/ { };\n' | "$DTC_BIN" -@ -I dts -O dtb -o "$NOOP_DTBO" 2>/dev/null \
  || die "dtc: failed to build no-op overlay"

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

# Build new/cmdline.txt from the golden current/ one: drop whatever serial
# console it uses (console=serial0 / ttyAMA0 / ttyS0) and point it at our
# mainline mini-uart ($SERIAL_TTY) so the login getty lands on the 40-pin header.
SERIAL_TTY="ttyS1"
log "Preparing cmdline (console=$SERIAL_TTY)"
NEW_CMDLINE="$(ssh_pi "cat '$BOOT_DIR/current/cmdline.txt'" \
  | sed -E "s/console=(serial[0-9]|ttyAMA[0-9]|ttyS[0-9]),[0-9]+//g; s/  +/ /g; s/^ //; s/ *\$//")"
case "$NEW_CMDLINE" in
  *"console=$SERIAL_TTY,"*) ;;
  *) NEW_CMDLINE="$NEW_CMDLINE console=$SERIAL_TTY,115200" ;;
esac
printf '%s' "$NEW_CMDLINE" > "$DTB_WORK/cmdline.txt"
log "  -> $NEW_CMDLINE"

log "Copying artifacts to the Pi (md5-skip unchanged)"
stage_copy "$IMAGE"      vmlinuz            "$BOOT_DIR/new/vmlinuz"
stage_copy "$SYSMAP_SRC" "System.map-$KREL" "/boot/System.map-$KREL"
stage_copy "$CONFIG_SRC" "config-$KREL"     "/boot/config-$KREL"
stage_copy "$DTB_OUT"    "$DTB_NAME"        "$BOOT_DIR/new/$DTB_NAME"      # upstream DTB
stage_copy "$NOOP_DTBO"  noop.dtbo
stage_copy "$DTB_WORK/cmdline.txt" cmdline.txt

# modules tarball (~90 MB): skip upload AND reinstall if the installed set already
# matches — compare against an md5 sidecar left in /lib/modules/$KREL by the last
# deploy. (Stable across --no-build reruns; a fresh build regenerates the tarball.)
MOD_MD5=$(md5sum "$MOD_TARBALL" | cut -d' ' -f1)
MOD_REMOTE_MD5=$(ssh_pi "cat '/lib/modules/$KREL/.deploy-md5' 2>/dev/null" || true)
if [ "$MOD_MD5" = "$MOD_REMOTE_MD5" ]; then
  MODULES_FRESH=1
  log "  unchanged: modules ($KREL already installed)"
else
  MODULES_FRESH=0
  stage_copy "$MOD_TARBALL" modules.tar.gz
fi

log "Staging new/ slot on the Pi (current/ untouched)"
ssh_pi "sudo sh -euc '
  set -eu
  BOOT=\"$BOOT_DIR\"
  [ -d \"\$BOOT/current\" ] || { echo \"no \$BOOT/current slot\"; exit 1; }
  # modules first — the initramfs is built from them (skip if unchanged)
  if [ \"$MODULES_FRESH\" = 0 ]; then
    rm -rf \"/lib/modules/$KREL\"
    tar -C / -xzf \"$REMOTE_TMP/modules.tar.gz\"
    depmod \"$KREL\"
    printf %s \"$MOD_MD5\" > \"/lib/modules/$KREL/.deploy-md5\"
  fi
  # kernel config -> /boot/config-<KREL> so mkinitramfs can verify compression
  install -m644 \"$REMOTE_TMP/config-$KREL\" \"/boot/config-$KREL\"
  # System.map -> rootfs (debug aid; mode 600 to match stock)
  install -m600 \"$REMOTE_TMP/System.map-$KREL\" \"/boot/System.map-$KREL\"
  # build the new/ tryboot slot: clone golden current/ (keeps firmware blobs,
  # overlays dir, config.txt path), then apply the upstream-DTB recipe on top.
  rm -rf \"\$BOOT/new\"
  cp -r \"\$BOOT/current\" \"\$BOOT/new\"
  install -m644 \"$REMOTE_TMP/vmlinuz\"  \"\$BOOT/new/vmlinuz\"
  install -m644 \"$REMOTE_TMP/$DTB_NAME\" \"\$BOOT/new/$DTB_NAME\"
  install -m644 \"$REMOTE_TMP/cmdline.txt\" \"\$BOOT/new/cmdline.txt\"
  # neutralise vendor overlays that corrupt the upstream DTB (no-op, per-slot)
  for ov in $NEUTRALIZE_OVERLAYS; do
    [ -e \"\$BOOT/new/overlays/\$ov.dtbo\" ] && \
      install -m644 \"$REMOTE_TMP/noop.dtbo\" \"\$BOOT/new/overlays/\$ov.dtbo\"
  done
  mkinitramfs -o \"\$BOOT/new/initrd.img\" \"$KREL\"
  printf %s \"$KREL\" > \"\$BOOT/new/.deploy-krel\"
  rm -rf \"$REMOTE_TMP\"
  echo \"new/ slot ready: $KREL \"
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
