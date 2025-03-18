#!/usr/bin/env bash

USBIMG=usb.img

function devargs() {
    D=$1
    ARGS=
    case $D in
        "usb-storage")
            if [ ! -f usb.img ]; then
                dd if=/dev/zero of=$USBIMG bs=1k count=1024
                mkfs -t ext4 $USBIMG
            fi
            ARGS="-drive if=none,id=usbstick,format=raw,file=$USBIMG \
                  -usb                                               \
                  -device usb-ehci,id=ehci                           \
                  -device usb-storage,bus=ehci.0,drive=usbstick"
         ;;
    esac

    echo $ARGS
}

OPTS=
QEMU_OPTS=
BOOTARGS=
while getopts ":kd:" opt
do
    case $opt in
        d)
            args=`devargs $OPTARG`
            if [ -z "$args" ]; then
                echo "Invalid device option $OPTARG"
                exit 1
            fi
            QEMU_OPTS+=$args
        ;;
        k)
            BOOTARGS+="crashkernel=256M"
            QEMU_OPTS+="-device vmcoreinfo"
        ;;
    esac
done

if [[ ! -z $BOOTARGS ]]; then
    OPT+=" --append='$BOOTARGS'"
fi

if [[ ! -z $QEMU_OPTS ]]; then
    OPT+=" -o='$QEMU_OPTS'"
fi


echo vng $OPT
eval "vng $OPT"
