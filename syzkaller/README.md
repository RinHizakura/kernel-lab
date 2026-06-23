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
