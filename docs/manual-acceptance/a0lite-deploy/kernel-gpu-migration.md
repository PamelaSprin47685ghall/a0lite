# 内核与 NVIDIA 驱动迁移（760K）

- 执行时间：2026-11-17 23:06 → 23:11:38（变更窗口），其后为失联诊断
- 目标机：`ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -p 12022 root@127.0.0.1`
- 边界：只改内核与 GPU 驱动栈。**未触碰** `agent-zero.service` / `agent-zero-desktop.service`，未进 `/home/kunweiz/.var/app`、`/home/kunweiz/.local/share/flatpak`、`/home/kunweiz/a0-models-repo`，未执行 `pacman -Syu` 全系统滚动升级。
- 目标机存档目录：`/root/kernel-migration-20261117/`（未删除）

```bash
SSH='ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -p 12022 root@127.0.0.1'
```

**当前状态一句话**：驱动与内核都已按计划装好并通过静态校验，GPU 在**旧内核**上已被 `nvidia-smi` 证实可用；23:11:38 重启后目标机**至今未回连**，无法完成「重启后 GPU 仍可用」这一验收，第 4–7 步全部未执行。

---

## 0. 已验证 / 未验证（先看这个）

| 事项 | 状态 | 证据位置 |
| --- | --- | --- |
| 615.71.09 驱动能在 RTX 3070 Ti 上工作 | **已验证** | §3.3 `nvidia-smi` 原文、`/proc/driver/nvidia/version`、dmesg |
| 旧内核 7.3.0-rc6-1 拿到匹配模块 | **已验证** | `nvidia.ko.zst` 落位 `7.3.0-rc6-1-MANJARO/extramodules/`，`modinfo` 路径正确 |
| `linux72 7.2.9-1` 安装完成 | **已验证** | `pacman -Q` 输出、模块目录、`/boot` 文件 |
| `linux72-nvidia-open 615.71.09-7` 与 7.2.9 内核匹配 | **已验证** | `vermagic: 7.2.9-1-MANJARO` |
| `initramfs-7.2-x86_64.img` 与 `vmlinuz-7.2-x86_64` 生成 | **已验证** | `ls -lh /boot`，120M / 17M |
| GRUB 菜单中出现 7.2.9 项 | **已验证** | `grub.cfg` 行 172 |
| `saved_entry` 指向 7.2.9 | **已验证** | `grub-editenv list` |
| 7.2.9 内核**实际启动** | **未验证** | 机器未回连 |
| 7.2.9 上 nvidia 模块**实际加载** | **未验证** | 同上 |
| `nvidia-smi` 在 7.2.9 上工作 | **未验证** | 同上 |
| Vulkan / OpenCL / CUDA 在 7.2.9 上可用 | **未验证** | 未执行 |
| 卸载旧 rc 内核 | **未执行** | 按计划应在验证后做 |
| 第二次重启 | **未执行** | — |
| 目标机失联的确切原因 | **未确认** | 只有间接证据，见 §5.4 |

---

## 1. 现场与选型

### 1.1 迁移前现场

| 项目 | 事实 |
| --- | --- |
| 发行版 | Manjaro rolling，分支 `stable`，镜像 `mirror.sjtu.edu.cn/manjaro/stable` |
| 主机 | `760K`，AMD Athlon X4 760K（4 核），19 GiB 内存 |
| 根分区 | `/dev/sda2`，f2fs，933 G，435 G 可用，inode 84% |
| `/boot` | **不是独立分区**，就在根分区上（`findmnt /boot` 无输出） |
| Bootloader | **GRUB 2.14**（`bootctl status` → `systemd-boot not installed in ESP`，`Current Boot Loader: Product: GRUB 2.14`） |
| GPU | `01:00.0 NVIDIA GA104 [GeForce RTX 3070 Ti]` |
| 运行内核 | `7.3.0-rc6-1-MANJARO` |
| 内核包 | `linux73 7.3.0rc6-1`、`linux73-headers 7.3.0rc6-1` |

迁移前的 nvidia 包：

```
local/linux73-nvidia-open 610.57.04-0.2 (linux73-extramodules)
    NVIDIA open kernel modules for linux73
```

**故障链**：`linux73-nvidia-open 610.57.04-0.2` 只装了
`/usr/lib/modules/7.3.0-rc1-2-MANJARO/extramodules/nvidia.ko.zst`，运行内核却是 `7.3.0-rc6-1-MANJARO`。
后果：`modinfo nvidia` 找不到模块、`lsmod` 无 nvidia、`/dev/nvidia*` 不存在、GPU 无厂商驱动。
`/etc/modules-load.d/mhwd-gpu.conf` 写着 `nvidia` 与 `nvidia_drm`，每次开机 systemd-modules-load 都会尝试加载并失败。

### 1.2 仓库候选（`pacman -Sy` 之后）

```
core linux61   6.1.189-1
core linux612  6.12.112-1
core linux618  6.18.55-1
core linux66   6.6.158-1
core linux72   7.2.9-1
core linux73   7.3.0rc6-1 [installed]

extra linux61-nvidia-open   615.71.09-3
extra linux612-nvidia-open  615.71.09-4
extra linux618-nvidia-open  615.71.09-7
extra linux66-nvidia-open   615.71.09-3
extra linux72-nvidia-open   615.71.09-7
extra linux73-nvidia-open   615.71.09-0.8 [installed: 610.57.04-0.2]
```

### 1.3 选型结论

**`linux72 7.2.9-1` + `linux72-headers 7.2.9-1` + `linux72-nvidia-open 615.71.09-7` + `nvidia-utils 615.71.09-2`。**

1. `linux72` 是仓库里最新的**稳定**内核（7.2.9）。`linux73` 的包版本是 `7.3.0rc6-1`，即 rc/preview，按规则排除。
2. 有同名配套包 `linux72-nvidia-open`，`Depends On: linux72 nvidia-utils=615.71.09 libglvnd`，仓库 `nvidia-utils` 正是 `615.71.09-2`，可共存。
3. Manjaro stable 的 `linux-meta 7.2-1` / `linux-nvidia-open-meta 7.2-1` 指向的正是 7.2 线，与 mhwd 体系一致。
4. 独立复核了模块归属：`linux72-nvidia-open` 包内容只写入 `usr/lib/modules/7.2.9-1-MANJARO/extramodules/`，与内核包版本严格对应。

排除：`linux73`（rc）、`linux618/612/66/61`（可用但非最新稳定）、`nvidia-open-dkms`（需本地编译，与预编译体系 `Provides: NVIDIA-MODULE` 互斥）。

### 1.4 一个改变执行顺序的发现

`linux73-nvidia-open 615.71.09-0.8` 的包内容实测为：

```
usr/lib/modules/7.3.0-rc6-1-MANJARO/extramodules/nvidia.ko.zst
usr/lib/modules/7.3.0-rc6-1-MANJARO/extramodules/nvidia-drm.ko.zst
usr/lib/modules/7.3.0-rc6-1-MANJARO/extramodules/nvidia-modeset.ko.zst
usr/lib/modules/7.3.0-rc6-1-MANJARO/extramodules/nvidia-peermem.ko.zst
usr/lib/modules/7.3.0-rc6-1-MANJARO/extramodules/nvidia-uvm.ko.zst
```

模块目录正是**当前运行内核**。于是把执行顺序改为「先驱动、后内核」：

- 不重启就能证明「GPU 硬件 + 615 驱动栈」是好的，把「驱动坏」与「内核不匹配」两个故障源分离。
- 正好对应「验证 GPU 可用后重启」的要求。
- 旧 `linux73` 内核保留一套可用 nvidia 模块，成为能带 GPU 回滚的保险。

---

## 2. 变更前存档

### 2.1 命令

```bash
D=/root/kernel-migration-20261117
mkdir -p $D && cd $D
pacman -Q                 > packages-before.txt
mhwd-kernel -li           > mhwd-kernel-before.txt 2>&1
mhwd -li                  > mhwd-before.txt 2>&1
uname -r                  > uname-before.txt
ls -la /boot              > boot-before.txt
cat /etc/default/grub     > grub-default-before.txt
cat /etc/mkinitcpio.conf  > mkinitcpio-before.txt
ls /etc/mkinitcpio.d/     > mkinitcpio-d-before.txt
bootctl status            > bootctl-before.txt 2>&1
efibootmgr -v             > efibootmgr-before.txt 2>&1
ls /boot/loader/entries   > loader-entries-before.txt 2>&1
ls /boot/grub >/dev/null 2>&1 && echo grub > bootloader-type.txt || echo systemd-boot-or-other > bootloader-type.txt
pacman -Qs '^linux'       > linux-packages-before.txt 2>&1
pacman -QQs nvidia        > nvidia-packages-before.txt 2>&1   # 该写法报错，见下
grep -v '^#' /etc/pacman.d/mirrorlist | head -5 > mirrors-before.txt
grep -A2 '^\[' /etc/pacman.conf > pacman-repos-before.txt
```

`pacman -QQs nvidia` 的写法有误，实际报 `error: only one operation may be used at a time`（`-QQs` 被解析成 `-Q -Q -s`）。正确写法是 `pacman -Q | grep nvidia`。迁移前的 nvidia 包版本来自存档里的 `packages-before.txt` 与 `pacman -Si` 对照，已如实记录，未用该出错命令的产物下结论。

### 2.2 存档文件清单

```
-rw-r--r-- 1 root root   602 boot-before.txt
-rw-r--r-- 1 root root  2342 bootctl-before.txt
-rw-r--r-- 1 root root     5 bootloader-type.txt
-rw-r--r-- 1 root root   875 efibootmgr-before.txt
-rw-r--r-- 1 root root  2410 grub-default-before.txt
-rw-r--r-- 1 root root  2661 linux-packages-before.txt
-rw-r--r-- 1 root root    68 loader-entries-before.txt
-rw-r--r-- 1 root root   408 mhwd-before.txt
-rw-r--r-- 1 root root   123 mhwd-kernel-before.txt
-rw-r--r-- 1 root root    65 mirrors-before.txt
-rw-r--r-- 1 root root  3356 mkinitcpio-before.txt
-rw-r--r-- 1 root root    15 mkinitcpio-d-before.txt
-rw-r--r-- 1 root root    48 nvidia-packages-before.txt
-rw-r--r-- 1 root root 22080 packages-before.txt
-rw-r--r-- 1 root root   375 pacman-repos-before.txt
-rw-r--r-- 1 root root    20 uname-before.txt
```

### 2.3 关键结论

```
$ cat bootloader-type.txt
grub

$ cat uname-before.txt
7.3.0-rc6-1-MANJARO

$ cat loader-entries-before.txt
ls: cannot access '/boot/loader/entries': No such file or directory

$ pacman-mirrors --get-branch
stable
```

`/boot` 内容（迁移前）：

```
total 154763
-rw-r--r-- 1 root root   307200 amd-ucode.img
-rw-r--r-- 1 root root 125347438 initramfs-7.3-x86_64.img
-rw-r--r-- 1 root root  15265792 intel-ucode.img
-rw-r--r-- 1 root root         24 linux73-x86_64.kver
-rw-r--r-- 1 root root  17367552 vmlinuz-7.3-x86_64
```

`/etc/mkinitcpio.conf` 关键行：

```
MODULES=()
HOOKS=(base udev autodetect microcode kms modconf block keyboard keymap consolefont resume filesystems fsck)
```

`/etc/mkinitcpio.d/` 只有一个 preset：`linux73.preset`。

`/etc/modprobe.d/mhwd-gpu.conf`：`options nvidia_drm modeset=1`
`/etc/modules-load.d/mhwd-gpu.conf`：`nvidia` / `nvidia_drm`

`/etc/default/grub` 关键行：

```
GRUB_DEFAULT=saved
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=hidden
GRUB_SAVEDEFAULT=false
```

`GRUB_DEFAULT=saved` 是本次迁移最容易踩的坑：默认项来自 grubenv 的 `saved_entry`，而不是自动选最新内核。

---

## 3. 安装过程

### 3.1 依赖冲突定位

```
# pacman -S --needed --print linux72 linux72-headers linux72-nvidia-open
error: failed to prepare transaction (could not satisfy dependencies)
:: installing nvidia-utils (615.71.09-2) breaks dependency 'nvidia-utils=610.57.04' required by lib32-nvidia-utils
:: installing nvidia-utils (615.71.09-2) breaks dependency 'nvidia-utils=610.57.04' required by linux73-nvidia-open
```

`linux73-nvidia-open 610.57.04-0.2` 与 `lib32-nvidia-utils 610.57.04-1` 都是**精确版本依赖** `nvidia-utils=610.57.04`。
结论：`nvidia-utils` 610→615 无法绕开，唯一干净解法是同事务把这两个包一起升到 615 线。

### 3.2 最小变更集（dry-run 原文）

```
# pacman -S --needed --noconfirm --print \
    linux72 linux72-headers linux72-nvidia-open linux73-nvidia-open \
    nvidia-utils opencl-nvidia lib32-nvidia-utils nvidia-settings

Packages (8) lib32-nvidia-utils-615.71.09-1  linux72-7.2.9-1  linux72-headers-7.2.9-1
             linux72-nvidia-open-615.71.09-7  linux73-nvidia-open-615.71.09-0.8
             nvidia-settings-615.71.09-2  nvidia-utils-615.71.09-2  opencl-nvidia-615.71.09-2

Total Download Size:  751.85 MiB
```

**没有 glibc、systemd、linux-firmware 或任何其它包被牵连。** 全文未执行 `pacman -Syu`，只做这 8 个包的最小事务。

各包依赖约束（`pacman -Si` 原文摘要）：

```
linux72-nvidia-open 615.71.09-7
Depends On      : linux72  nvidia-utils=615.71.09  libglvnd
Provides        : nvidia=615.71.09  NVIDIA-MODULE
Conflicts With  : linux72-nvidia

nvidia-utils 615.71.09-2
Depends On      : libglvnd  egl-wayland  egl-wayland2  egl-gbm  egl-x11
Provides        : vulkan-driver  opengl-driver  nvidia-libgl  nvidia-utils=615.71.09

linux72 7.2.9-1
Depends On      : coreutils  initramfs  kmod
Provides        : linux=7.2.9  ...
```

### 3.3 事务一：只升级驱动栈（不碰内核）

```bash
pacman -S --needed --noconfirm linux73-nvidia-open nvidia-utils opencl-nvidia lib32-nvidia-utils nvidia-settings
```

安装输出的可见部分（`tee` 到 `/root/kernel-migration-20261117/stepA-driver-upgrade.log`，`tail -40`；**该日志留在目标机上，现在取不到**）：

```
xorg configuration symlink valid...
upgrading nvidia-settings...
:: Running post-transaction hooks...
( 1/10) Creating system user accounts...
( 2/10) Reloading system manager configuration...
( 3/10) Enqueuing marked services...
( 4/10) Reloading device manager configuration...
( 5/10) Arming ConditionNeedsUpdate...
( 6/10) Updating module dependencies...
( 7/10) Updating linux initcpios...
==> Building image from preset: /etc/mkinitcpio.d/linux73.preset: 'default'
  -> -k /boot/vmlinuz-7.3-x86_64 -g /boot/initramfs-7.3-x86_64.img
==> Starting build: '7.3.0-rc6-1-MANJARO'
  -> Running build hook: [base]
  -> Running build hook: [udev]
  -> Running build hook: [autodetect]
  -> Running build hook: [microcode]
  -> Running build hook: [kms]
  -> Running build hook: [modconf]
  -> Running build hook: [block]
  -> Running build hook: [keyboard]
  -> Running build hook: [keymap]
  -> Running build hook: [consolefont]
==> WARNING: consolefont: no font found in configuration
  -> Running build hook: [resume]
  -> Running build hook: [filesystems]
  -> Running build hook: [fsck]
==> Generating module dependencies
==> Creating zstd-compressed initcpio image: '/boot/initramfs-7.3-x86_64.img'
==> Initcpio image generation successful
  -> Running post hook: [sbctl]
Secureboot key directory doesn't exist, not signing!
(10/10) Signing EFI binaries...
=== EXIT=0 ===
```

唯一警告 `consolefont: no font found in configuration` 属既有配置问题，与 nvidia/内核无关（迁移前的构建同样存在）。

版本结果：

```
lib32-nvidia-utils  615.71.09-1
linux73             7.3.0rc6-1        (未变)
linux73-nvidia-open 615.71.09-0.8    (610.57.04-0.2 → 615.71.09-0.8)
nvidia-settings     615.71.09-2
nvidia-utils        615.71.09-2
opencl-nvidia       615.71.09-2
```

模块落位与元数据：

```
# ls -l /usr/lib/modules/7.3.0-rc6-1-MANJARO/extramodules/
-rw-r--r-- 1 root root   102911 nvidia-drm.ko.zst
-rw-r--r-- 1 root root   974527 nvidia-modeset.ko.zst
-rw-r--r-- 1 root root     2046 nvidia-peermem.ko.zst
-rw-r--r-- 1 root root   952970 nvidia-uvm.ko.zst
-rw-r--r-- 1 root root 12250882 nvidia.ko.zst

# modinfo nvidia
filename:       /lib/modules/7.3.0-rc6-1-MANJARO/extramodules/nvidia.ko.zst
import_ns:      CXL
import_ns:      DMA_BUF
alias:          char-major-195-*
description:    NVIDIA core GPU kernel module
version:        615.71.09
supported:      external
license:        Dual MIT/GPL

# depmod -a 7.3.0-rc6-1-MANJARO
depmod exit=0
```

#### 3.3.1 在旧内核上加载并验收 GPU（重启前）

```bash
modprobe nvidia      # exit=0
modprobe nvidia_uvm  # exit=0
modprobe nvidia_drm  # exit=0
```

```
# lsmod | grep -E 'nvidia|nouveau'
nvidia_drm            172032  0
nvidia_modeset       1994752  1 nvidia_drm
drm_ttm_helper         20480  1 nvidia_drm
drm_display_helper    307200  1 nvidia_drm
video                  81920  1 nvidia_modeset
nvidia_uvm           2478080  0
nvidia              18735104  2 nvidia_uvm,nvidia_modeset
```

设备节点（第一次 `ls` 只看到两个 `nvidia-uvm*`，几秒后 udev 补齐，属正常延迟）：

```
crw-rw-rw- 1 root root 237,   0 /dev/nvidia-uvm
crw-rw-rw- 1 root root 237,   1 /dev/nvidia-uvm-tools
crw-rw-rw- 1 root root 195,   0 /dev/nvidia0
crw-rw-rw- 1 root root 195, 255 /dev/nvidiactl

/dev/nvidia-caps:
cr-------- 1 root root 240, 1 nvidia-cap1
cr--r--r-- 1 root root 240, 2 nvidia-cap2
```

```
# cat /proc/driver/nvidia/version
NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  615.71.09  Release Build  (root@)  
GCC version:  gcc version 16.2.1 20260810 (GCC) 
```

`nvidia-smi` 原始输出：

```
Tue Nov 17 23:10:04 2026       
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 615.71.09              KMD Version: 615.71.09     CUDA UMD Version: 13.4     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA GeForce RTX 3070 Ti     Off |   00000000:01:00.0 Off |                  N/A |
| 47%   63C    P0             80W /  310W |       1MiB /   8192MiB |      0%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|  No running processes found                                                             |
+-----------------------------------------------------------------------------------------+
```

```
# nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
name, driver_version, memory.total [MiB]
NVIDIA GeForce RTX 3070 Ti, 615.71.09, 8192 MiB

# nvidia-smi -L
GPU 0: NVIDIA GeForce RTX 3070 Ti (UUID: GPU-2dac6597-989a-6b6d-7c52-f310cc6ba474)
```

dmesg：

```
[609918.202906] nvidia-nvlink: Nvlink Core is being initialized, major device number 239
[609918.221441] nvidia 0000:01:00.0: vgaarb: VGA decodes changed: olddecodes=io+mem,decodes=none:owns=io+mem
[609921.370689] NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  615.71.09  Release Build  (root@)  
[609921.983328] nvidia-modeset: Loading NVIDIA UNIX Open Kernel Mode Setting Driver for x86_64  615.71.09  Release Build  (root@)  
[609922.003021] [drm] [nvidia-drm] [GPU ID 0x00000100] Loading driver
[609922.067610] [drm] Initialized nvidia-drm 0.0.0 for 0000:01:00.0 on minor 1
[609922.079167] nvidia 0000:01:00.0: vgaarb: deactivate vga console
[609922.086049] nvidia 0000:01:00.0: [drm] Cannot find any crtc or sizes
```

`systemctl --failed`：`0 loaded units listed.`（此时两个 agent-zero 服务仍为 `active`，未被触碰）

**结论**：GPU 硬件、615 驱动栈、用户态工具链（nvidia-smi 615.71.09 / CUDA UMD 13.4）在旧内核上全部正常。这是本次迁移中最有价值的一条已验证事实。

### 3.4 事务二：安装稳定内核 linux72

```bash
pacman -S --needed --noconfirm linux72 linux72-headers linux72-nvidia-open
```

输出的可见部分（`tee` 到 `stepB-install-linux72.log`，`tail -45`；日志留在目标机）：

```
(2/5) Updating module dependencies...
(3/5) Updating linux initcpios...
==> Building image from preset: /etc/mkinitcpio.d/linux72.preset: 'default'
  -> -k /boot/vmlinuz-7.2-x86_64 -g /boot/initramfs-7.2-x86_64.img
==> Starting build: '7.2.9-1-MANJARO'
  -> Running build hook: [base]
  -> Running build hook: [udev]
  -> Running build hook: [autodetect]
  -> Running build hook: [microcode]
  -> Running build hook: [kms]
  -> Running build hook: [modconf]
  -> Running build hook: [block]
  -> Running build hook: [keyboard]
  -> Running build hook: [keymap]
  -> Running build hook: [consolefont]
==> WARNING: consolefont: no font found in configuration
  -> Running build hook: [resume]
  -> Running build hook: [filesystems]
  -> Running build hook: [fsck]
==> Generating module dependencies
==> Creating zstd-compressed initcpio image: '/boot/initramfs-7.2-x86_64.img'
==> Initcpio image generation successful
(4/5) Updating Grub-Bootmenu
Generating grub configuration file ...
Found theme: /usr/share/grub/themes/manjaro/theme.txt
Found linux image: /boot/vmlinuz-7.3-x86_64
Found initrd image: /boot/intel-ucode.img /boot/amd-ucode.img /boot/initramfs-7.3-x86_64.img
Found linux image: /boot/vmlinuz-7.2-x86_64
Found initrd image: /boot/intel-ucode.img /boot/amd-ucode.img /boot/initramfs-7.2-x86_64.img
Adding boot menu entry for UEFI Firmware Settings ...
Found memtest86+ image: /boot/memtest86+/memtest.bin
Found memtest86+ EFI image: /boot/memtest86+/memtest.efi
done
=== EXIT=0 ===
```

装后版本：

```
linux72             7.2.9-1
linux72-headers     7.2.9-1
linux72-nvidia-open 615.71.09-7
linux73             7.3.0rc6-1          (旧内核保留，此时未动)
linux73-headers     7.3.0rc6-1
linux73-nvidia-open 615.71.09-0.8
```

`/boot` 与空间：

```
-rw------- 1 root root 120M /boot/initramfs-7.2-x86_64.img
-rw------- 1 root root 120M /boot/initramfs-7.3-x86_64.img
-rw-r--r-- 1 root root   20 /boot/linux72-x86_64.kver
-rw-r--r-- 1 root root   24 /boot/linux73-x86_64.kver
-rw-r--r-- 1 root root   17M /boot/vmlinuz-7.2-x86_64
-rw-r--r-- 1 root root   17M /boot/vmlinuz-7.3-x86_64

Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2       933G  499G  434G  54% /
```

`/etc/mkinitcpio.d/` 现有两个 preset：`linux72.preset`、`linux73.preset`。

### 3.5 模块与目标内核匹配校验

```
# modinfo -k 7.2.9-1-MANJARO nvidia
filename:       /lib/modules/7.2.9-1-MANJARO/extramodules/nvidia.ko.zst
description:    NVIDIA core GPU kernel module
version:        615.71.09
vermagic:       7.2.9-1-MANJARO SMP preempt mod_unload

# modinfo -k 7.2.9-1-MANJARO nvidia_drm
filename:       /lib/modules/7.2.9-1-MANJARO/extramodules/nvidia-drm.ko.zst
version:        615.71.09
vermagic:       7.2.9-1-MANJARO SMP preempt mod_unload
```

`vermagic` 与目标 `uname -r` `7.2.9-1-MANJARO` 逐字符一致，这正是迁移前缺失的那一环。

---

## 4. 启动项与首次重启

### 4.1 grub.cfg 菜单结构

`grub-mkconfig` 由 pacman hook 自动执行，菜单为：

```
141:menuentry 'Manjaro Linux' --class manjaro ... $menuentry_id_option 'gnulinux-simple-/dev/sda2' {
156:submenu   'Advanced options for Manjaro Linux' ... 'gnulinux-advanced-/dev/sda2' {
157:  menuentry 'Manjaro Linux (Kernel: 7.3.0-rc6-1-MANJARO x64)' ... 'gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2' {
172:  menuentry 'Manjaro Linux (Kernel: 7.2.9-1-MANJARO x64)'    ... 'gnulinux-7.2.9-1-MANJARO x64-advanced-/dev/sda2' {
208:  menuentry 'UEFI Firmware Settings' ... 'uefi-firmware' {
233:    menuentry "Memory Tester (memtest86+)" ...
242:    menuentry "Memory Tester (memtest86+)" ...
```

顶层默认项 `Manjaro Linux`（index 0）的实测内容**仍指向旧内核**：

```
linux	/boot/vmlinuz-7.3-x86_64 root=PARTUUID=5d564ca6-936b-45b0-b3b5-6c8152fb215c rw  quiet resume=UUID=473d740f-022d-4175-8383-eb52387ae2bd udev.log_priority=3
initrd	/boot/intel-ucode.img /boot/amd-ucode.img /boot/initramfs-7.3-x86_64.img
```

什么都不做直接重启就会进 7.3.0-rc6。原因：GRUB `10_linux` 按版本排序，`7.3.0-rc6` 排在 `7.2.9` 之前；而 `GRUB_DEFAULT=saved`，默认项来自 grubenv，迁移前 grubenv 里没有 `saved_entry`（只有 `menu_auto_hide=1`、`boot_success=1`）。

### 4.2 设置默认启动项（含一个重要存疑点）

执行了两条命令：

```bash
grub-set-default 'gnulinux-7.2.9-1-MANJARO x64-advanced-/dev/sda2'
grub-reboot '1>1'
```

grubenv 结果：

```
menu_auto_hide=1
boot_success=1
saved_entry=gnulinux-7.2.9-1-MANJARO x64-advanced-/dev/sda2
next_entry=1>1
```

`grub.cfg` 头部的解析逻辑原文：

```
if [ "${next_entry}" ] ; then
   set default="${next_entry}"
   set next_entry=
   if [ "${env_block}" ] ; then
     save_env -f "${env_block}" next_entry
   else
     save_env next_entry
   fi
   set boot_once=true
else
   set default="${saved_entry}"
fi
```

**层级映射本身是对的**（有行号证据）：顶层 index 0 = `Manjaro Linux`，index 1 = `Advanced options` 子菜单；子菜单 index 0 = 7.3.0-rc6，index 1 = 7.2.9。所以 `1>1` 指向 7.2.9。

**但这里有一个未核实的假设，并且它很可能是本次失联的直接原因**：`default` 是否接受 `N>M` 形式，取决于 GRUB 对 `default` 变量的解析实现。`grub-reboot` 的 `MENU_ENTRY` 文法支持数字、标题、entry id；`N>M` 这种子菜单路径在部分 GRUB 文档里被提到，但我**没有在目标机上用 `grub-reboot --help` 或实测验证过**。
如果解析失败，`default` 变成无效值，而 `next_entry` 又已被 `set next_entry=` 清空，GRUB 可能显示菜单并**无限等待按键**，`GRUB_TIMEOUT=5` 对无效 default 是否生效我也没有实测。

这是我引入的额外风险。正确的做法本应只依赖 `saved_entry`（entry id，文法确定有效），或者把 `GRUB_DEFAULT` 直接写成 entry id 后重跑 `grub-mkconfig`。`next_entry` 本来是当"双保险"加的，反而可能成为单点故障。

### 4.3 重启前确认清单（原文）

```
time: 2026-11-17T23:11:38+08:00
target kernel pkg: linux72 7.2.9-1 (vmlinuz-7.2-x86_64)
saved_entry: saved_entry=gnulinux-7.2.9-1-MANJARO x64-advanced-/dev/sda2
next_entry : next_entry=1>1
vmlinuz    : -rw-r--r-- 1 root root 17M Nov 17 23:10 /boot/vmlinuz-7.2-x86_64
initramfs  : -rw------- 1 root root 120M Nov 17 23:10 /boot/initramfs-7.2-x86_64.img
nvidia mod : vermagic:       7.2.9-1-MANJARO SMP preempt mod_unload
space      : /dev/sda2       933G  499G  434G  54% /
agent-zero : active / active
```

（清单里 `failed` 一栏当时的 `wc -l` 计数写成 2，是把 `systemctl --failed` 的表头与空行算进去了；实际输出为 `0 loaded units listed.`。这一处是我的统计错误，不代表有失败单元。）

### 4.4 重启

```bash
nohup bash -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
```

重启时点：**2026-11-17 23:11:38**（清单时间戳），`reboot scheduled` 之后 SSH 会话随即断开。

---

## 5. 首次重启后：失联与诊断

### 5.1 结论

截至本报告写作时，目标机**未回连**。因此第 4 步的验收（`uname -r`、`nvidia-smi`、`journalctl -b -p err`、`lsmod`、`/dev/nvidia*`、`vulkaninfo`、`systemctl --failed`）**一条都没有执行**，不能记为通过。

### 5.2 回连探测（原文）

固定命令，循环重试：

```bash
for i in $(seq 1 90); do
  ssh -o BatchMode=yes -o ConnectTimeout=5 -p 12022 root@127.0.0.1 'echo up' && break
  sleep 5
done
```

```
=== attempt 1: Connection to 127.0.0.1 port 12022 timed out
=== attempt 2: Connection to 127.0.0.1 port 12022 timed out
=== attempt 3: Connection to 127.0.0.1 port 12022 timed out
=== attempt 4: Connection to 127.0.0.1 port 12022 timed out
=== attempt 5: Connection to 127.0.0.1 port 12022 timed out
=== attempt 6: Connection to 127.0.0.1 port 12022 timed out
=== still down ===
```

单独一次带错误输出的探测，能区分「连接被拒」与「banner 超时」：

```
# ssh ... root@127.0.0.1 'echo up; uname -r; uptime'
Connection timed out during banner exchange
Connection to 127.0.0.1 port 12022 timed out
```

`banner exchange` 阶段超时说明 TCP 已建立、但对端没有吐 SSH 版本串，符合「转发端接受连接但后端不可用」的形态。

### 5.3 断点定位：本机 XTCP visitor 正常，760K 侧 frp 服务端未注册

本机 `127.0.0.1:12022` 一直在 LISTEN：

```
LISTEN 0      4096                                  127.0.0.1:12022      0.0.0.0:*
```

这个 listener 是本机 frpc 里的 **XTCP visitor**（`ssh-tunnel-12022-xtcp-visitor`）在本地开的。XTCP 是 frp 的 P2P 打洞模式：visitor 侧只负责本地监听并在连接时去找**对端注册的同名 xtcp server**，真正的中继/打洞要靠 760K 上的 frpc 先把 `ssh-tunnel-12022-xtcp` 这个 proxy 注册到 frps。

本机 frpc 日志（`journalctl -u frpc`，主机名 `7940HS`）从 23:11 之后持续报：

```
Nov 17 23:23:17 7940HS frpc[277490]: [W] [visitor/xtcp.go:257] [712035e83bddb673] [ssh-tunnel-12022-xtcp-visitor] nathole precheck error: xtcp server for [ssh-tunnel-12022-xtcp] doesn't exist
Nov 17 23:23:17 7940HS frpc[277490]: [E] [visitor/xtcp.go:168] [712035e83bddb673] [ssh-tunnel-12022-xtcp-visitor] open tunnel error: open tunnel timeout
```

最近 200 行里这类 `xtcp server ... doesn't exist` 出现 **66 次**，每 10 秒一轮，从未成功。

这一条比 SSH 探测更直接：它不是"某台服务没起"，而是**对端 frpc 根本没向 frps 注册**。visitor 侧完全正常，缺的是 760K 那一侧。

同一 frps 上 760K 另外三个服务端口（agent-zero 占用的 5080/11434/14500）做了对照：

```
$ timeout 8 bash -c 'cat < /dev/null > /dev/tcp/frp.kw92.cyou/12022' && echo "TCP OPEN"
TCP OPEN

$ ssh -o BatchMode=yes -o ConnectTimeout=6 -p 12022 root@frp.kw92.cyou 'echo FRP_OK'
Connection closed by 83.136.210.113 port 12022
```

关键对照实验：同一 frp 上 760K 另外三个服务端口（agent-zero 占用 5080/11434/14500）：

```
5080 OPEN
11434 OPEN
14500 OPEN

$ curl -s -m 6 -o /dev/null -w 'http_code=%{http_code}\n' http://frp.kw92.cyou:5080/
http_code=000
$ curl -s -m 6 http://frp.kw92.cyou:11434/api/tags
(空)
$ curl -s -m 6 -o /dev/null -w 'http_code=%{http_code}\n' http://frp.kw92.cyou:14500/
http_code=000
```

判断：frps（`83.136.210.113`）在线，TCP 能被接受，但**没有任何一个端口能取到数据**（HTTP 全 `000`，SSH 立即被关闭）。这不是"某个服务没起"，而是**760K 的 frpc 客户端没有注册到 frps**，也就是整机出站链路不存在。

（这一步我先误判过一次：看到 5080/11434/14500 `OPEN` 时以为机器活着。用 HTTP 取内容才纠正过来——frps 对未注册端口同样是 accept 后立刻 close。后来本机 frpc 日志里那条 `xtcp server ... doesn't exist` 才是决定性证据。写在这里是因为这两个误判都很容易重犯。）

顺带记一条本机事实（**不是 760K 的**）：本机 `frpc.service`（`/usr/local/bin/frpc -c /etc/frp/frpc.toml`，`User=frpc`，依赖 `frpc-bypass-tun.service`）负责这条 visitor；`/etc/frp/` 目录对本用户不可读（`Permission denied`），所以配置文件内容本次未取到。760K 侧的 frpc 单元名与配置路径从未检查过。

### 5.4 局域网侧排查

本机 `192.168.123.80/24`（wlp4s0）。扫 22 端口找目标机：

```bash
seq 1 254 | xargs -P64 -I{} sh -c 'timeout 1 bash -c "exec 3<>/dev/tcp/192.168.123.{}/22" 2>/dev/null && echo 192.168.123.{}'
```

结果与逐台识别（`ssh -n ... root@IP 'hostname; uname -r'`）：

```
192.168.123.43  -> 7640HS / 7.3.0-rc6-1-MANJARO   (另一台笔记本，uptime 2026-11-08，无 nvidia-smi，不是目标)
192.168.123.97  -> lubancat / 6.1.172              (ARM 板卡)
192.168.123.253 -> Permission denied (publickey,password)
192.168.123.254 -> Permission denied (publickey,password)   (网关/网络设备)
```

再扫 12022 与 2222：**无任何主机开放**。
因此 760K 既不在本局域网可 SSH 的地址上，也没有把 sshd 暴露在局域网。它只能靠出站 frpc 回到 frps，而这条链路当前不存在。

补充事实（都是本机的，不是 760K 的）：本机有 `frpc.service`（`/usr/local/bin/frpc -c /etc/frp/frpc.toml`，Description: "frp client - SSH tunnel (22 -> frp.kw92.cyou:11022)"），还有 `frpc-bypass-tun.service`（"Bypass mihomo Meta TUN for frpc (uidrange)"），本机有 `Meta` 接口 `198.18.0.1/30` MTU 9000。**760K 上的 frpc 单元名、配置路径、以及它靠什么出站，本次从未检查过**——这是侦察缺口，见 §9。

### 5.5 可能原因（按可能性排序，均未证实）

| # | 假设 | 支持证据 | 反证 / 缺口 |
| --- | --- | --- | --- |
| A | GRUB 停在菜单等按键（`next_entry=1>1` 解析失败） | 失联时间点与重启完全吻合；`next_entry` 是我新引入的唯一可疑变量；GRUB 对无效 `default` 的处理未验证 | 无法观测，需要控制台 |
| B | 7.2.9 启动成功但出站网络未就绪（frpc 依赖的链路/TUN 在 7.2.9 下未起） | 整机表现为 frpc 未注册而非内核 panic；报文层完全无响应 | 同样无法观测 |
| C | 7.2.9 启动 panic / 卡在 emergency shell | f2fs 根分区 + 120M initramfs + `resume=UUID=...`；新内核首次启动有 fsck 可能 | 无法观测 |
| D | 硬件/固件层面未完成 POST | 无 | 无任何证据 |

已排除：本机转发失效（listener 在）、frps 宕机（TCP 可连、其它端口同样 accept）、目标机仍在旧内核运行（否则 SSH 会在）。

---

## 6. 卸载旧 rc 内核 —— 未执行

前置条件是「新内核启动并验证 GPU 可用」，该条件未达成，因此**没有卸载任何内核包**。
目标机上 `linux73`、`linux73-headers`、`linux73-nvidia-open` 全部原样保留，旧内核与它的 615 模块都是可用的回滚目标。

---

## 7. 第二次重启与最终验证 —— 未执行

未执行，因为没有完成第一次重启后的验证，也无必要把一个尚未确认可启动的系统再重启一次。

---

## 8. 人工恢复手册

目标机当前状态：整机不可达，只能靠物理/控制台介入。以下三类情形按你看到的画面选一条执行。

前提（均为迁移前存档实测，不是推测）：

- `/boot` 在根分区 `/dev/sda2`（f2fs，PARTUUID `5d564ca6-936b-45b0-b3b5-6c8152fb215c`），**没有独立 /boot 分区**。
- ESP 是 `/dev/sda1`，300 M vfat，PARTUUID `419d1db4-010d-4817-9781-8d906b5862cc`，挂在 `/boot/efi`。
- `bootctl status` 原文：`ESP: /boot/efi (/dev/disk/by-partuuid/419d1db4-...)`；`Available Boot Loaders on ESP: File: └─/boot/efi//EFI/BOOT/bootx64.efi`。
- `efibootmgr -v` 原文：`BootCurrent: 0000`，`BootOrder: 0000,0001`，`Boot0000* Manjaro → HD(1,GPT,419d1db4-...)/\EFI\Manjaro\grubx64.efi`，`Boot0001* UEFI OS → \EFI\BOOT\BOOTX64.EFI`。
- GRUB 2.14 直接读 f2fs（`grub.cfg` 里有 `insmod f2fs`）。
- `/boot/loader` 不存在（没有 systemd-boot）。

### 8.1 情形 A：停在 GRUB 菜单

**怎么让它显示**：`GRUB_TIMEOUT_STYLE=hidden`，正常开机看不到菜单。开机自检刚过、屏幕还没黑时，**反复按 `Esc`**（有的固件是按住 `Shift`）。

**该选哪一项**——回到旧内核（最稳，且旧内核现在有匹配的 615 模块，GPU 仍可用）：

```
Advanced options for Manjaro Linux
  └── Manjaro Linux (Kernel: 7.3.0-rc6-1-MANJARO x64)
```

`grub.cfg` 里的原文（行 157）：

```
menuentry 'Manjaro Linux (Kernel: 7.3.0-rc6-1-MANJARO x64)' --class manjaro --class gnu-linux --class gnu --class os $menuentry_id_option 'gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2' {
	linux	/boot/vmlinuz-7.3-x86_64 root=PARTUUID=5d564ca6-936b-45b0-b3b5-6c8152fb215c rw  quiet resume=UUID=473d740f-022d-4175-8383-eb52387ae2bd udev.log_priority=3
	initrd	/boot/intel-ucode.img /boot/amd-ucode.img /boot/initramfs-7.3-x86_64.img
```

若要继续验证新内核，则选同级另一项：

```
  └── Manjaro Linux (Kernel: 7.2.9-1-MANJARO x64)
```

**进系统后立即修好默认项**（关键：清掉那个可疑的 `next_entry`）：

```bash
# 看当前状态
grub-editenv /boot/grub/grubenv list

# 清掉一次性项，避免每次开机都踩同一个坑
grub-editenv /boot/grub/grubenv unset next_entry

# 二选一：
# (a) 回旧内核
grub-editenv /boot/grub/grubenv set saved_entry='gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2'
# (b) 继续新内核
grub-editenv /boot/grub/grubenv set saved_entry='gnulinux-7.2.9-1-MANJARO x64-advanced-/dev/sda2'

# 确认
grub-editenv /boot/grub/grubenv list
```

注意 `grub-editenv` 没有 `-` 这个占位参数，正确形式是 `grub-editenv <文件> <动作> ...`。
也可以直接用 `grub-set-default '<entry id>'`（它内部就是写 grubenv）。

**更彻底的做法**（消除 `>` 语法的全部不确定性）：把 `GRUB_DEFAULT` 直接写成 entry id，再重生成，这样 `saved_entry` 不再是唯一依赖：

```bash
cp -a /etc/default/grub /etc/default/grub.bak-$(date +%Y%m%d%H%M)
sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT='gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2'|" /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
grep -n "set default=" /boot/grub/grub.cfg | head
```

（如果要的是新内核，把上面 id 换成 7.2.9 那一条。）

### 8.2 情形 B：panic / 停在 emergency shell / 连 GRUB 都过不去

用 Manjaro live USB 启动，选「Boot with open source drivers」，进桌面后开终端。

**1) 挂载根分区（f2fs）与 ESP**

```bash
lsblk -f                      # 先确认 /dev/sda2 是 F2FS 且 UUID=7c34b5ba-93c7-4b0f-89b7-e21fe9411e4e
mkdir -p /mnt
mount -t f2fs /dev/sda2 /mnt
ls /mnt/boot                  # 应能看到 vmlinuz-7.2-x86_64 / vmlinuz-7.3-x86_64

# ESP 已确认为 /dev/sda1（300M vfat，PARTUUID 419d1db4-010d-4817-9781-8d906b5862cc）
mount /dev/sda1 /mnt/boot/efi
```

**2) chroot**

```bash
manjaro-chroot /mnt          # Manjaro live 自带；不行就手动：
# for d in dev proc sys run; do mount --bind /$d /mnt/$d; done
# chroot /mnt
```

**3) 回滚到旧内核 + 旧驱动（可用的最稳组合是 7.3.0-rc6-1 + linux73-nvidia-open 615.71.09-0.8）**

先看缓存里到底有哪些包（**不要凭记忆写文件名**）：

```bash
ls -1 /var/cache/pacman/pkg/ | grep -E '^(linux73|nvidia-utils|lib32-nvidia-utils|opencl-nvidia|nvidia-settings)'
```

若要退回迁移前的 610 驱动线（注意：这条线在 rc6 上是**坏的**，只是为了恢复包状态，不建议）：

```bash
pacman -U /var/cache/pacman/pkg/linux73-nvidia-open-610.57.04-0.2-x86_64.pkg.tar.zst \
          /var/cache/pacman/pkg/nvidia-utils-610.57.04-1-x86_64.pkg.tar.zst \
          /var/cache/pacman/pkg/opencl-nvidia-610.57.04-1-x86_64.pkg.tar.zst \
          /var/cache/pacman/pkg/lib32-nvidia-utils-610.57.04-1-x86_64.pkg.tar.zst \
          /var/cache/pacman/pkg/nvidia-settings-610.57.04-1-x86_64.pkg.tar.zst
```

**推荐**：保持在 615 线，只把默认启动项掰回旧内核 —— 这样 GPU 立刻可用：

```bash
grub-editenv /boot/grub/grubenv unset next_entry
grub-editenv /boot/grub/grubenv set saved_entry='gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2'
grub-editenv /boot/grub/grubenv list
```

**4) 若怀疑 initramfs 有问题，重建（两个内核都重建，不要只建一个）**

```bash
mkinitcpio -P
```

预期两条 `==> Building image from preset: ...`，各自的 `Initcpio image generation successful`；`consolefont: no font found` 警告可忽略。

**5) 重生成 GRUB 配置**

```bash
grub-mkconfig -o /boot/grub/grub.cfg
grep -nE "^menuentry|^\s+menuentry" /boot/grub/grub.cfg
```

**6) 若 GRUB 本体损坏（连菜单都没有）**

```bash
# ESP 已确认为 /dev/sda1 → /boot/efi；bootctl 曾报告 "systemd-boot not installed in ESP"
mount /dev/sda1 /boot/efi
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Manjaro
grub-mkconfig -o /boot/grub/grub.cfg
```

固件启动项不用重建：`efibootmgr` 里 `Boot0000* Manjaro` 仍指向 `\EFI\Manjaro\grubx64.efi`，`grub-install` 会覆盖这个文件。若启动项被弄乱，可用：

```bash
efibootmgr -v                      # 先看现有编号
efibootmgr -o 0000,0001            # 恢复成 Manjaro 优先
```

**7) 退出并重启**

```bash
exit
umount -R /mnt
reboot
```

**8) 若怀疑 f2fs 本身损坏**（正常重启不该出现，作为兜底）

```bash
fsck.f2fs -f /dev/sda2      # 必须先 umount
```

### 8.3 情形 C：能进系统（本地键盘/显示器）但没网，SSH 连不上

在 760K 本机上开终端（Ctrl+Alt+F2 或图形终端）。

**1) 先看链路**

```bash
ip -br a
ip r
nmcli device status
systemctl status NetworkManager --no-pager | head -20
```

**2) 找 frpc 单元（760K 上的名字本次没确认过，按下面方式现查）**

```bash
systemctl list-units --type=service --all | grep -iE 'frp|tunnel'
ls -la /etc/frp* 2>/dev/null
systemctl status <上面查到的单元名> --no-pager
journalctl -u <单元名> -b --no-pager | tail -40
```

**3) 手动拉起并观察**

```bash
systemctl start <单元名>
systemctl status <单元名> --no-pager
journalctl -u <单元名> -f      # 看它是否报 "connect to server error" / "login to server failed"
```

**4) 若 frpc 依赖某个 TUN/VPN 链路**（本机有 `frpc-bypass-tun.service` 这种先例，760K 可能类似）

```bash
ip tuntap show
lsmod | grep -E 'tun|wireguard'
systemctl list-units --type=service --all | grep -iE 'mihomo|clash|tun|wg|vpn'
```

小概率但重要：本机 `frpc.service` 的依赖是 `After=frpc-bypass-tun.service` + `Requires=frpc-bypass-tun.service`。若 760K 上也是这种结构，而新内核下 TUN 模块没加载，`frpc` 会被依赖拖死，表现就是「机器活着但 frp 不注册」。用 `systemctl status` 看 `Requires` 侧是否 failed 即可定位。

**5) 确认 sshd 本身**

```bash
systemctl status sshd --no-pager
ss -ltnp | grep ':22'
journalctl -u sshd -b --no-pager | tail -30
```

---

## 9. 遗留风险

1. **`next_entry=1>1` 的语义存疑**（见 §4.2）。这是本次唯一一处我没有先在目标机验证就写进 grubenv 的东西。后续任何重启操作前，先用 `grub-editenv list` 确认没有残留 `next_entry`。
2. **`mhwd-nvidia` 与 `nvidia-utils` 版本不同步**：`mhwd-nvidia 610.57.04-1` 仍在位，而 `nvidia-utils` 已是 `615.71.09-2`。`mhwd -li` 里的 `video-nvidia 2026.03.05` 在下次 mhwd 操作时可能按旧元数据判定并试图重装/调整，需要单独复核。
3. **`/etc/modules-load.d/mhwd-gpu.conf` 开机加载 `nvidia` + `nvidia_drm`**：任何一次内核更新若没同步 `linux<ver>-nvidia-open`，`systemd-modules-load.service` 会再次失败。内核与驱动必须成对升级。
4. **initramfs 可能已包含 nvidia 模块**：`initramfs-7.2` 是在 nvidia 模块已加载后由 `autodetect` 构建的，可能把 `nvidia*` 带进早期镜像；`initramfs-7.3` 构建时未加载。两者行为可能不一致，回连后应 `lsinitcpio` 核对。
5. **760K 的出站链路是黑盒**：本次从未在目标机上确认 frpc 的单元名、配置、依赖与出站方式。这是本次失联诊断最大的盲区，也是下次必须先补的侦察项。
6. **系统整体落后仓库约 6 周**：`pacman -Qu` 有 249 个待升级包（含 glibc `2.44+r24` → `2.44+r50`、grub `2:2.14-1` → `2:2.16-3.1`、systemd 等）。本次刻意只做最小事务，未滚动升级；长期不做全量升级会积累部分升级风险。
7. **GRUB 顶级默认项仍指向 rc6**：只要 `saved_entry` 被清空（例如某次 `grub-editenv` 误操作或 `boot_success` 逻辑回退），开机就会回到 `7.3.0-rc6`。卸载旧内核时必须同时重生成 grub 配置。
8. **`/boot` 与根分区共用 f2fs，inode 84%**：每个内核约 140 MB（120M initramfs + 17M vmlinuz）。多留一个内核是安全的，但不要长期保留三个以上。
9. **`consolefont: no font found in configuration`**：既有配置问题，不影响启动，但每次 `mkinitcpio -P` 都会出现，别把它当成新故障。
10. **未完成的验收**：7.2.9 的实际启动、该内核上的 nvidia 加载、`nvidia-smi`、Vulkan/OpenCL/CUDA、`systemctl --failed` 全部未验证。GPU 推理能否在 7.2.9 上跑起来，目前只有静态证据（vermagic 一致）与同版本驱动在旧内核上的成功经验，**没有直接证据**。

---

## 10. 现场一页操作卡

> 12 步，每步一行。括号里是「看到什么就算这步成功」。手机上看屏幕照样能敲。

```text
1  接显示器 + 键盘，看屏幕停在哪。
   （成功：能判断出是 GRUB 菜单 / 黑屏 / emergency shell / 登录提示 / 无信号）

2  若开机看不到菜单（黑屏或一闪而过）：强制重启，开机后连按 Esc。
   （成功：出现 GRUB 菜单；一次不成就再重启一次，Esc 要在固件 logo 刚消失时开始按）

3  GRUB 菜单里按 ↓ 选 "Advanced options for Manjaro Linux"，回车。
   （成功：子菜单里出现两条 Kernel 条目）

4  选 "Manjaro Linux (Kernel: 7.3.0-rc6-1-MANJARO x64)"，回车，等 90 秒。
   （成功：屏幕滚过内核日志，最后出现登录提示或桌面）

5  若已进系统但没网：开终端（Ctrl+Alt+F2），ip -br a
   （成功：至少一个网卡有 inet 地址）

6  nmcli device status
   （成功：对应网卡 STATE 是 connected）

7  systemctl status NetworkManager frpc --no-pager
   （成功：两个都是 active (running)）

8  journalctl -u frpc -n 40 --no-pager
   （成功：不再出现 "doesn't exist" / "open tunnel timeout"，或出现 login to server success）

9  若进不了系统：插 Manjaro live USB 启动，开终端，lsblk -f
   （成功：看到 sda2 是 f2fs、sda1 是 vfat）

10 mount -t f2fs /dev/sda2 /mnt && mkdir -p /mnt/boot/efi && mount -t vfat /dev/sda1 /mnt/boot/efi
   （成功：ls /mnt/boot 能看到 vmlinuz-7.3-x86_64 与 vmlinuz-7.2-x86_64）

11 manjaro-chroot /mnt 然后执行：
   grub-editenv /boot/grub/grubenv unset next_entry
   grub-editenv /boot/grub/grubenv set saved_entry='gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2'
   （成功：grub-editenv /boot/grub/grubenv list 的输出里只剩 menu_auto_hide / boot_success / saved_entry）

12 grub-mkconfig -o /boot/grub/grub.cfg ; exit ; umount -R /mnt ; reboot
   （成功：reboot 后进 7.3.0-rc6-1-MANJARO，GPU 仍可用）
```

替换项（只改一处，其余不动）：

```text
要继续验证新内核：把 11a 里的 saved_entry 换成
gnulinux-7.2.9-1-MANJARO x64-advanced-/dev/sda2
```

两个 entry 的完整值（从 `grub.cfg` 的 `--id` 抄的原文）：

```text
旧内核 7.3.0-rc6-1  gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2
新内核 7.2.9-1      gnulinux-7.2.9-1-MANJARO x64-advanced-/dev/sda2
```

两条菜单项标题原文（`/boot/grub/grub.cfg` 第 157、172 行）：

```text
Manjaro Linux (Kernel: 7.3.0-rc6-1-MANJARO x64)
Manjaro Linux (Kernel: 7.2.9-1-MANJARO x64)
```

一条语法提醒：`grub-editenv` 的用法是 `grub-editenv <文件> <动作> ...`，**没有** `-` 占位参数；
`grub-editenv - set saved_entry=...` 会被当成文件名，什么也不会改。

一条命令名提醒：Manjaro live 里优先用 `manjaro-chroot /mnt`；若提示 command not found，改用 `arch-chroot /mnt`。
两者都会自动 bind `/dev` `/proc` `/sys`，不需要手动挂。

---

## 11. 这次操作的可复用教训

### 11.1 事实

1. **驱动与运行内核的匹配可以先做，而且不重启就能验证。** 本轮把 `linux73-nvidia-open` 升到 615.71.09-0.8（其模块目录正好是运行中的 `7.3.0-rc6-1-MANJARO`），随后 `modprobe nvidia` + `nvidia-smi` 直接拿到 RTX 3070 Ti / 615.71.09 / 8192 MiB。这一步把「GPU 硬件 + 驱动」与「内核不匹配」两个故障源彻底分开，代价为零。
2. **内核与驱动的版本绑定是硬常量，不是一个范围。** `linux<ver>-nvidia-open` 的 `Depends On` 写的是 `nvidia-utils=615.71.09`，`-nvidia-open` 包本身又被 `nvidia-utils=610.57.04` 反向钉住。换驱动必然牵动这两个包，不能只装其中一个；`pacman -S --print` 能在动手前把整个事务摊开，本轮靠它把变更锁在 8 个包、751 MiB，没有牵连 glibc/systemd。
3. **装了新内核，GRUB 的默认项不会自动指向它。** `10_linux` 按版本排序，`7.3.0-rc6` 排在 `7.2.9` 之前，顶层默认项仍指旧内核。必须显式设默认项。
4. **`next_entry` 是一次性变量，不能当作回退依据。** GRUB 启动时会执行 `set next_entry=` 并 `save_env`，也就是说它被消费后从 grubenv 里消失。事后想从 grubenv 判断「它当时到底有没有被正确解析」是不可能的。本轮把 `next_entry=1>1` 当"双保险"加进去，结果它成了唯一无法事后验证的可疑变量。
5. **子菜单路径 `N>M` 不是当然可用的 `default` 文法。** `grub-reboot`/`grub-set-default` 明确支持「数字、标题、entry id」；`N>M` 形式在部分文档里出现，但本轮没有在目标机上实测。而 entry id（`gnulinux-...-advanced-/dev/sda2`）是确定可用的。
6. **单向 P2P 隧道没有带外能力。** 12022 是 frpc 的 XTCP visitor：本地 listener 恒在，真正的通路依赖目标机 frpc 主动向 frps 注册 `ssh-tunnel-12022-xtcp`。目标机一挂，`ncat`/`nc` 依然 `open`（那是本机 listener），但隧道永远打不通。判定「机器是否在线」不能靠 `nc` 本地端口。
7. **失联诊断要按层走，并且每层都要能区分"接受连接"与"有数据"。** 本轮顺序是：本地 listener（恒 open，无信息量）→ frps TCP（accept 但立即 close）→ HTTP 取内容（全 `000`，证明没有后端）→ frps 上其它端口对照（同样 `000`，排除单服务故障）→ 本机 frpc 日志（`xtcp server ... doesn't exist`，直接指向对端未注册）。最后一条是最快的判据，应放在第一位查。
8. **存档要存"能救命的项"。** 本轮存了 `/boot`、`/etc/default/grub`、`mkinitcpio.conf`、`bootctl`、`efibootmgr`、包清单、仓库配置；但**没有存 `grubenv` 原值**与 `/var/cache/pacman/pkg/` 的包清单。前者导致事后无法确证 `next_entry` 的初始状态，后者导致回滚手册里的 `pacman -U` 文件名只能靠包版本推断。

### 11.2 下次要怎么做才安全（具体清单）

1. 先在**当前内核**上把 GPU 打通并记录 `nvidia-smi` 原文。这一步不重启、可回退，是整条链路的基线。
2. 装新内核 + 配套 `-nvidia-open`，装完立刻校验两件事：`modinfo -k <新ver> nvidia | grep vermagic` 与 `/usr/lib/modules/<新ver>/extramodules/nvidia.ko.zst` 是否存在。
3. 设默认项**只用** `grub-set-default '<entry id>'`；禁止使用 `next_entry` 与 `N>M` 子菜单路径。
4. 重启前跑 `grub-editenv /boot/grub/grubenv list`，要求输出里**只有** `saved_entry`，没有任何 `next_entry` 残留。
5. 重启前把 `grubenv` 原文、`/boot` 的 `ls -lh` 带时间戳、`journalctl --list-boots`、`ls /var/cache/pacman/pkg/ | grep -E '^(linux|nvidia)'` 全部存档。
6. 重启前**确认带外通道**：物理键盘与显示器、或 IPMI/KVM/虚拟机控制台。没有带外通道就不远程重启——本轮唯一的失联代价就来自这一条。
7. 重启前在目标机留一个**启动打点**：一个 `oneshot` 单元，在 `network-online.target` 之后写一行时间戳到本机可观测的位置（例如再开一条独立的 frp 端口，或写进目标机上一个由外部可读的位置）。这样"机器起没起来"不依赖 SSH 本身。
8. 旧内核与旧驱动包保留到新内核**连续两次**启动验证通过为止；卸载旧内核前先重生成 GRUB 配置，并确认 `saved_entry` 已指向新内核。

---

## 12. 回连后的只读采集清单（可直接复制）

机器一回来就按这个跑。**全部只读，不装、不卸、不改、不重启。**

```bash
SSH='ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -p 12022 root@127.0.0.1'

$SSH 'bash -s' <<'EOF'
echo "## 1 uptime";                uptime
echo "## 2 uname -r";              uname -r
echo "## 3 boots";                 journalctl --list-boots --no-pager | tail -3
echo "## 4 上一次启动的错误";      journalctl -b -1 -p err --no-pager | tail -30
echo "## 5 GRUB 三行";             grep -E 'GRUB_(DEFAULT|SAVEDEFAULT|TIMEOUT)' /etc/default/grub
echo "## 6 grubenv";               grub-editenv /boot/grub/grubenv list
echo "## 7 本次启动的错误";        journalctl -b -p err --no-pager | tail -20
echo "## 8 模块";                  lsmod | grep -E 'nvidia|nouveau'
echo "## 9 设备";                  ls -l /dev/nvidia* 2>&1 | head
echo "## 10 驱动版本";             cat /proc/driver/nvidia/version 2>&1
echo "## 11 GPU";                  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv 2>&1
echo "## 12 failed";               systemctl --failed --no-pager
EOF
```

只在这两条正常之后，才谈下一步：

```text
uname -r 输出 7.2.9-1-MANJARO
nvidia-smi --query-gpu 输出 NVIDIA GeForce RTX 3070 Ti, 615.71.09, 8192 MiB
```

### 12.1 证据可得性（哪些东西没在这份报告里）

| 证据 | 在哪 |
| --- | --- |
| 本报告里所有命令与输出 | 就是本文件，逐段可查 |
| `pacman -S` 的**完整**事务输出（含 `Packages (8)` 下载明细、逐包安装行） | 只在目标机 `/root/kernel-migration-20261117/stepA-driver-upgrade.log`、`stepB-install-linux72.log`，目标机离线期间取不到 |
| 迁移前存档 17 个文件 | 在目标机 `/root/kernel-migration-20261117/`，同上 |
| 7.2.9 内核的实际启动日志 | 尚不存在，要等回连后 `journalctl -b -1 -p err` 才有 |
| 本机 frpc 的完整访客日志 | 本机 `journalctl -u frpc`，可用 `journalctl -u frpc --since "2026-11-17 23:05" --no-pager` 复核 |

因此本报告对 §3.3、§3.4 的 pacman 输出是**当时屏幕上可见的那部分**（`tee ... | tail -40/45`），不是完整事务日志；凡本报告没写出来的行，不作任何推断。
