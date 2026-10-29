# kernel-lab

Scripts for building, booting and crash-testing Linux kernels: out-of-tree
builds, a virtme-ng/QEMU runner with kdump, cross-arch guest rootfs,
Raspberry Pi tryboot deploy, WSL2 deploy and syzkaller.

```
lib.sh      shared prelude: log/die, tool checks, shallow clones, the arch table
linux/      build + deploy
qemu/       boot under virtme-ng (vng), kdump, local QEMU build
syzkaller/  fuzzing on QEMU or on a Pi
```

`ARCH` is always the vng name (`x86_64`, `arm64`, `riscv64`, `armhf`,
`ppc64el`, `s390x`); `arch_name` in `lib.sh` turns it into the kernel,
toolchain, Debian, QEMU and Go spellings, so nothing else keeps a table.

One kernel source tree serves every target: builds are out-of-tree
(`make O=`), one build dir per purpose, and the source tree stays clean.

```
~/linux/stable-linux/           source (KSRC)
├── build-vng-x86_64/           build_vng_kernel.sh, boots under KVM
├── build-vng-arm64/            build_vng_kernel.sh, boots under TCG
└── build-arm64/                deploy-rpi-kernel.sh, goes to the Pi
```

## Build

`linux/build_kernel.sh` is the engine: defconfig or an existing `.config`,
kconfig fragments merged on top, `olddefconfig`, build. The others wrap it.

```bash
cd linux
KSRC=~/linux/stable-linux ./build_vng_kernel.sh                    # x86_64 -> build-vng-x86_64
KSRC=~/linux/stable-linux ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ./build_vng_kernel.sh
KSRC=~/linux/stable-linux DEPLOY_TARGET=pi@HOST ./deploy-rpi-kernel.sh --debug
KSRC=~/linux/stable-linux ./deploy-wsl-kernel.sh -t A              # WSL2 kernel tagged -A
```

| Script | Build dir | Fragments | Then |
|---|---|---|---|
| `build_vng_kernel.sh` | `build-vng-<ARCH>` | `config/vng.config` + `config/kdump.config` | boot with `vng_runner` |
| `deploy-rpi-kernel.sh` | `build-<ARCH>` | `config/kdump.config` | stage to the Pi's tryboot slot, `--promote` once verified |
| `deploy-wsl-kernel.sh` | `build-x86_64` | none | copy bzImage to Windows, point `.wslconfig` at it |

Environment knobs shared by all of them: `KSRC`, `ARCH`, `BUILD_NAME` (the
O= dir name under KSRC) or `KOUT` (an O= dir anywhere), `CROSS_COMPILE`
(defaults per ARCH), `LLVM=1`, `JOBS`, `CONFIG_FRAGMENTS` (your own
fragments, merged after the built-in ones).

A tree that still has an in-tree build is refused; save its `.config`,
`make mrproper`, drop the `.config` into the build dir.

## Boot and kdump

`qemu/vng_runner` wraps `vng`: `-r` picks the build dir (default: cwd),
`-a` the arch, `-d` attaches a disk, `-k` turns on kdump.

```bash
cd ~/linux/stable-linux
vng_runner -r build-vng-x86_64 -k                     # KVM, host root
vng_runner -a arm64 -r build-arm64 -k -d usb-storage  # TCG, own rootfs, /dev/sda for the vmcore
```

What `-k` does:

- reserves `crashkernel=512M`, gives the guest 4G, adds `-device vmcoreinfo`
- builds `kdump-initrd-<ARCH>.img` next to the kernel image on first use
  (`make_rootfs.sh <ARCH> initrd`: Ubuntu's static busybox as a newc cpio)
- replaces the guest shell with `kdump-shell.sh`, which `kexec -p` loads
  the running kernel as the dump-capture kernel and then drops you into
  your normal shell

Inside the guest:

```bash
sudo sh -c 'echo c > /proc/sysrq-trigger'   # capture kernel boots into a busybox shell
mount /dev/sda /mnt && cp /proc/vmcore /mnt/   # with -d usb-storage
```

A cross arch (`-a arm64`, `-a riscv64`, ...) needs its own root: `vng_runner`
builds `qemu/<ARCH>-rootfs` on first use (`make_rootfs.sh <ARCH>`: Ubuntu
base tarball, busybox, kexec-tools, stub udev) and reinstalls the modules
whenever they do not match the kernel being booted. The script dir and the
build dir are shared into the guest read-only so `kdump-shell.sh`, the
image and the initrd are reachable at their host paths.

`qemu/build_qemu.sh` builds QEMU from source into `qemu/install_<ARCH>/`;
`vng_runner` prefers that binary when present (`ARCH=arm64 ./build_qemu.sh`).

Boot time under TCG with a KASAN kernel is dominated by vng's bash init,
several minutes; use the x86_64 build under KVM to iterate on the kdump
flow itself.

## syzkaller

See [`syzkaller/README.md`](syzkaller/README.md). Short version:

```bash
cd syzkaller
./deploy_qemu_syzkaller.sh      # syzkaller + instrumented kernel + image + config
./run_syzkaller.sh              # fuzz; dashboard at http://127.0.0.1:56741
./run_syzkaller.sh list         # crashes found, repro status
```

The Pi variant (`deploy_rpi_syzkaller.sh`) reuses `linux/deploy-rpi-kernel.sh`
and syzkaller's isolated VM type.

## Requirements

- virtme-ng (`vng`), kexec-tools, `dpkg-deb`, `cpio`, `curl`
- cross toolchains for the archs you target (`aarch64-linux-gnu-gcc`, ...)
- QEMU: system packages, or `qemu/build_qemu.sh`
- for the Pi: SSH with passwordless sudo on the board, Ubuntu's tryboot layout
