#!/usr/bin/env bash
#
# Build a kernel for vng_runner: build_kernel.sh plus the config/vng.config and
# config/kdump.config fragments on top of whatever .config the build dir has (or
# DEFCONFIG on the first run). Same env as build_kernel.sh, but the build dir
# is build-vng-<ARCH> so it never shares a .config with the Pi build in
# build-<ARCH>.
#
# Usage:
#   KSRC=~/linux/stable-linux ./build_vng_kernel.sh                     # x86_64 -> $KSRC/build-vng-x86_64
#   KSRC=~/linux/stable-linux ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ./build_vng_kernel.sh
#   CONFIG_FRAGMENTS=/path/extra.config KSRC=... ./build_vng_kernel.sh  # merged after ours
#
# Boot: cd $KSRC && vng_runner -r build-vng-<ARCH> -k
#
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export BUILD_NAME="build-vng-${ARCH:-x86_64}"
export CONFIG_FRAGMENTS="$SCRIPT_DIR/config/vng.config $SCRIPT_DIR/config/kdump.config${CONFIG_FRAGMENTS:+ $CONFIG_FRAGMENTS}"
exec "$SCRIPT_DIR/build_kernel.sh" "$@"
