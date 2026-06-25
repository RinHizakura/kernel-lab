# syzkaller setup scripts

Stand up [syzkaller](https://github.com/google/syzkaller) and fuzz a Linux
kernel in a QEMU VM.

## Qemu

```bash
# 1. One command does build + kernel + image + config:
./deploy_qemu_syzkaller.sh

# 2. Fuzz. Dashboard at http://127.0.0.1:56741
./run_syzkaller.sh
```

## Raspberry Pi 4 (real board, arm64)

Fuzz a physical Pi over SSH via syzkaller's "isolated" VM type. Reuses the
brick-safe tryboot kernel deploy in `../linux/deploy-rpi-kernel.sh`.

```bash
# 1. Build syzkaller (arm64) + cross-build an instrumented kernel + deploy it
#    to the Pi's tryboot slot + write the isolated config:
DEPLOY_TARGET=ubuntu@PI-IP KSRC=/path/to/arm64/linux ./deploy_rpi_syzkaller.sh

# 2. Verify, then PROMOTE the kernel (required — a panic otherwise reverts the
#    Pi to its old non-instrumented kernel):
ssh ubuntu@PI-IP uname -r
../linux/deploy-rpi-kernel.sh --promote --target ubuntu@PI-IP

# 3. Fuzz. Dashboard at http://127.0.0.1:56741
./run_syzkaller.sh
```

Coverage needs read access to `/sys/kernel/debug/kcov` on the Pi — usually root.
If the login user can't read it, set `SSH_USER=root` (with key auth enabled).

