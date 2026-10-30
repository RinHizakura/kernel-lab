#!/usr/bin/env bash
# Guest-side shell for `vng_runner -k`: kexec -p the running kernel as
# dump-capture kernel, then drop into the usual interactive shell. Runs as
# whoever vng runs the shell as; vng's generated sudoers gives that user
# passwordless sudo, which the load (CAP_SYS_BOOT) and later the trigger and
# /proc/vmcore need. The host filesystem is visible in the guest at the same
# paths.

karg() { grep -oE "(^| )$1=[^ ]+" /proc/cmdline | cut -d= -f2-; }
# kexec lives in sbin, and sudo's secure_path lacks /usr/local/sbin: resolve
# the binary here and pass the full path.
PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin
KEXEC=$(command -v kexec)
SUDO=
[[ $EUID -eq 0 ]] || SUDO="sudo -n"

IMG=$(karg kdump_kernel)
INITRD=$(karg kdump_initrd)
KDIR=$(karg kdump_dir)
# Reuse the console= the running kernel got from vng (ttyS0/ttyAMA0/hvc0...).
CONSOLE=$(grep -oE 'console=[^ ]+' /proc/cmdline | sort -u | tr '\n' ' ')
# The 9p tag vng mounted KDIR with; the capture kernel's initrd mounts the
# same share on /mnt, which is where the dump should go.
TAG=$(awk -v d="$KDIR" '$2 == d && $3 == "9p" { t = $1 } END { print t }' /proc/mounts)

if [[ -z $KEXEC ]]; then
    echo "kdump: kexec not found (kexec-tools missing in the guest root?)" >&2
elif $SUDO "$KEXEC" -p "$IMG" --initrd="$INITRD" \
        --append="$CONSOLE irqpoll nr_cpus=1 reset_devices${TAG:+ kdump_tag=$TAG}"; then
    echo "kdump: capture kernel loaded ($IMG)"
    echo "kdump: trigger with: ${SUDO:+sudo }sh -c 'echo c > /proc/sysrq-trigger'"
    if [[ -n $TAG ]]; then
        echo "kdump: in the capture kernel $KDIR is on /mnt: cp /proc/vmcore /mnt/"
    else
        echo "kdump: $KDIR is not a 9p mount here; the capture kernel will have nowhere to save to" >&2
    fi
else
    echo "kdump: kexec -p $IMG --initrd=$INITRD failed" >&2
fi

exec bash
