#!/usr/bin/env bash
# Guest-side shell for `vng_runner -k INITRD`: kexec -p the running kernel as
# dump-capture kernel, then drop into the usual interactive shell. The host
# filesystem is visible in the guest at the same paths.

karg() { grep -oE "(^| )$1=[^ ]+" /proc/cmdline | cut -d= -f2-; }

case $(uname -m) in
    x86_64)  REL=arch/x86/boot/bzImage ;;
    aarch64) REL=arch/arm64/boot/Image ;;
esac
KVER=$(uname -r)
KDIR=$(readlink -f "/lib/modules/$KVER")   # vng -r: <kdir>/.virtme_mods/lib/modules/<kver>
IMG=${KDIR%%/.virtme_mods/*}/$REL
INITRD=$(karg kdump_initrd)
# Reuse the console= the running kernel got from vng (ttyS0/ttyAMA0/hvc0...).
CONSOLE=$(grep -oE 'console=[^ ]+' /proc/cmdline | tr '\n' ' ')

if kexec -p "$IMG" --initrd="$INITRD" \
        --append="$CONSOLE 1 irqpoll nr_cpus=1 reset_devices"; then
    echo "kdump: capture kernel loaded ($IMG)"
    echo "kdump: trigger with: echo c > /proc/sysrq-trigger"
else
    echo "kdump: kexec -p $IMG --initrd=$INITRD failed" >&2
fi

exec bash --login
