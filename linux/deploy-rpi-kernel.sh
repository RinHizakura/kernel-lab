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
: "${DEPLOY_TARGET:=pi@CHANGE-ME}"  # ssh target, e.g. pi@192.168.1.50
: "${ARCH:=arm64}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${JOBS:=$(nproc)}"
: "${DEFCONFIG:=bcm2711_defconfig}"       # in-tree defconfig (arch/arm64/configs/)
: "${BOOT_DIR:=/boot/firmware}"           # Raspberry Pi boot partition mount
LOCALVERSION_USER="${LOCALVERSION+set}"
: "${LOCALVERSION:=}"
: "${SSH_OPTS:=-o ConnectTimeout=10}"
: "${KSRC:=}"  # kernel source tree (absolute path)
: "${CONFIG_FRAGMENTS:=}"  # space-separated .config fragments merged on top (e.g. syzkaller KCOV/KASAN)

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

# require_space DF_PATH OVERWRITE_PATH NEEDED_KB LABEL
# Fail unless the Pi filesystem holding DF_PATH can fit NEEDED_KB. Space already
# used by OVERWRITE_PATH is credited back — it's replaced, not added, on deploy.
require_space() {
  local df_path="$1" owr_path="$2" need="$3" label="$4" avail used budget
  avail=$(ssh_pi "df -Pk '$df_path' | awk 'NR==2{print \$4}'") \
    || die "could not check free space on the Pi ($df_path)"
  used=$(ssh_pi "du -sk '$owr_path' 2>/dev/null | cut -f1" || true)
  budget=$(( avail + ${used:-0} ))
  (( need <= budget )) || die "Not enough space on the Pi for $label: need ${need}KB, have ${budget}KB at $df_path (free ${avail} + reclaimable ${used:-0}). Free up space and retry."
  log "  space OK ($label): need ${need}KB <= ${budget}KB at $df_path"
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
    --localversion) LOCALVERSION="$2"; LOCALVERSION_USER=set; shift 2;;
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

finalize_localversion() {
  if [ -n "$LOCALVERSION_USER" ]; then return; fi
  [ -f "$SRC_DIR/.config" ] || die "no .config yet — cannot derive version hash"
  local head tok
  head="$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo nogit)"
  tok="$( { printf '%s\n' "$head"; cat "$SRC_DIR/.config"; } | sha1sum | cut -c1-8 )"
  LOCALVERSION="-g${tok}"
  MAKE=(make -C "$SRC_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" -j"$JOBS")
  log "Auto version suffix: $LOCALVERSION (hash of source HEAD + .config)"
}

# ---------------------------------------------------------------------------
# 1. Build
# ---------------------------------------------------------------------------
if [ "$DO_BUILD" = 1 ]; then
  # Force-apply the tryboot patch before building (idempotent). Without it,
  # `reboot "0 tryboot"` is a no-op on mainline and the A/B deploy silently
  # never boots new/. Skip if already applied; die if it no longer applies
  # (after a rebase) rather than building a half-patched kernel.
  KERNEL_PATCH="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/0001-firmware-rpi-tryboot-reboot.patch"
  if [ -f "$KERNEL_PATCH" ]; then
    if git -C "$SRC_DIR" apply --reverse --check "$KERNEL_PATCH" 2>/dev/null; then
      log "tryboot patch already applied"
    elif git -C "$SRC_DIR" apply "$KERNEL_PATCH" 2>/dev/null; then
      log "Applied tryboot patch"
    else
      die "tryboot patch does not apply (and is not already applied): $KERNEL_PATCH"
    fi
  else
    die "tryboot patch not found: $KERNEL_PATCH"
  fi

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

  # Firmware in /lib/firmware/brcm on the Pi is untouched by the kernel build.
  # The distro ships brcmfmac firmware ZSTD-compressed (.zst); without the
  # compressed-firmware loader the kernel only looks for the uncompressed names,
  # gets -ENOENT, and wlan0 never appears. FW_LOADER_COMPRESS_ZSTD lets it
  # decompress them in place.
  log "Ensuring Pi onboard wifi (brcmfmac) + ZSTD firmware loader are built"
  WIFI_CONFIGS="
    CFG80211 MAC80211
    BRCMUTIL BRCMFMAC
    FW_LOADER_COMPRESS FW_LOADER_COMPRESS_ZSTD
  "
  for opt in $WIFI_CONFIGS; do
    "$SRC_DIR/scripts/config" --file "$SRC_DIR/.config" --enable "$opt"
  done

  # Extra fragments (e.g. syzkaller's KCOV/KASAN) merged on TOP of whatever
  # .config we have, using the kernel's own merge tool so dependencies resolve.
  if [ -n "$CONFIG_FRAGMENTS" ]; then
    for frag in $CONFIG_FRAGMENTS; do
      [ -f "$frag" ] || die "config fragment not found: $frag"
    done
    log "Merging extra config fragments: $CONFIG_FRAGMENTS"
    # shellcheck disable=SC2086
    ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
      "$SRC_DIR/scripts/kconfig/merge_config.sh" -m -O "$SRC_DIR" \
      "$SRC_DIR/.config" $CONFIG_FRAGMENTS
  fi

  "${MAKE[@]}" olddefconfig

  finalize_localversion

  log "Building Image, modules and DTBs (-j$JOBS)"
  "${MAKE[@]}" Image modules dtbs

  log "Installing modules into staging dir"
  rm -rf "$STAGE_DIR"
  "${MAKE[@]}" INSTALL_MOD_PATH="$STAGE_DIR" modules_install
else
  finalize_localversion
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

# Sanity-check the staging dir exists here.
[ -d "$STAGE_DIR/lib/modules/$KREL" ] || die "No staged modules at $STAGE_DIR/lib/modules/$KREL"

# ---------------------------------------------------------------------------
# 2. Deploy into the new/ tryboot slot (current/ stays untouched)
# ---------------------------------------------------------------------------
log "Checking connectivity to $DEPLOY_TARGET"
ssh_pi true || die "Cannot reach $DEPLOY_TARGET over SSH"

log "Verifying A/B tryboot layout on the Pi"
ssh_pi "test -d '$BOOT_DIR/current' && grep -q 'tryboot_a_b=1' '$BOOT_DIR/autoboot.txt' && grep -q 'os_prefix=new/' '$BOOT_DIR/config.txt'" \
  || die "Pi is not using the current//new/ A/B tryboot layout — aborting to stay brick-safe."

log "Verifying initramfs tooling on the Pi"
ssh_pi "command -v mkinitramfs >/dev/null 2>&1" \
  || die "mkinitramfs missing on the Pi — run: sudo apt install initramfs-tools"

command -v rsync >/dev/null 2>&1 || die "rsync not found locally"
ssh_pi "command -v rsync >/dev/null 2>&1" \
  || die "rsync missing on the Pi — run: sudo apt install rsync"

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

# Bail out before sending anything if the Pi can't hold the payload.
#   rootfs (ext4): modules + System.map + config install here; vmlinuz also transits
#     REMOTE_TMP (/tmp) en route to the FAT slot — so sum all four.
#   boot (FAT32): the new/ slot is a full clone of current/ (vfat can't share via
#     symlink/hardlink) plus the new vmlinuz that replaces the stock one.
log "Checking free space on the Pi"
ROOTFS_KB=$(du -skc "$STAGE_DIR/lib/modules/$KREL" "$IMAGE" "$SYSMAP_SRC" "$CONFIG_SRC" | tail -1 | cut -f1)
require_space "/lib/modules" "/lib/modules/$KREL" "$ROOTFS_KB" "modules + System.map + vmlinuz"

CURRENT_KB=$(ssh_pi "du -sk '$BOOT_DIR/current' | cut -f1")
VMLINUZ_KB=$(du -sk "$IMAGE" | cut -f1)
require_space "$BOOT_DIR" "$BOOT_DIR/new" "$(( CURRENT_KB + VMLINUZ_KB ))" "boot new/ slot"

log "Copying artifacts to the Pi (md5-skip unchanged)"
stage_copy "$IMAGE"      vmlinuz            "$BOOT_DIR/new/vmlinuz"
stage_copy "$SYSMAP_SRC" "System.map-$KREL" "/boot/System.map-$KREL"
stage_copy "$CONFIG_SRC" "config-$KREL"     "/boot/config-$KREL"
stage_copy "$DTB_OUT"    "$DTB_NAME"        "$BOOT_DIR/new/$DTB_NAME"      # upstream DTB
stage_copy "$NOOP_DTBO"  noop.dtbo
stage_copy "$DTB_WORK/cmdline.txt" cmdline.txt

# rsync delta straight into /lib/modules on the Pi
# --rsync-path runs the remote side as root so it can write under /lib.
log "Syncing modules -> /lib/modules/$KREL (rsync delta)"
# shellcheck disable=SC2086
rsync -a --delete -e "ssh $SSH_OPTS" --rsync-path="sudo rsync" \
  "$STAGE_DIR/lib/modules/$KREL/" "$DEPLOY_TARGET:/lib/modules/$KREL/"

log "Staging new/ slot on the Pi (current/ untouched)"
ssh_pi "sudo sh -euc '
  set -eu
  BOOT=\"$BOOT_DIR\"
  [ -d \"\$BOOT/current\" ] || { echo \"no \$BOOT/current slot\"; exit 1; }
  # modules were rsync'd into /lib/modules/$KREL already; refresh dep metadata
  # before the initramfs is built from them.
  depmod \"$KREL\"
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
# 3. Tryboot: boot the new/ slot once (one-shot; auto-reverts if it fails)
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
