# a0lite 部署目标机侦察报告

- 侦察时间：2026-11-17 22:57 起 CST（目标机本地时间）
- 侦察方式：SSH 远程只读命令；共 8 次连接；未在目标机安装、启动、停止或修改任何东西
- 目标机：`root@127.0.0.1:12022`（hostname `760K`，Manjaro Linux）
- 报告中的所有输出均为命令原始输出片段，未做改写；省略处用 `...` 标出

## 0. 连接方式与拓扑

**事实**

统一前缀如下，`BatchMode=yes` 直接成功，不需要密码、不需要显式 `-i` 密钥：

```bash
ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -p 12022 root@127.0.0.1 '<命令>'
```

批量采集时使用：

```bash
ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -p 12022 root@127.0.0.1 'bash -s' <<'REMOTE'
...
REMOTE
```

两个关键身份事实：

```text
$ whoami; id
root
uid=0(root) gid=0(root) groups=0(root)
```

```text
$ hostnamectl | head -8
 Static hostname: 760K
       Icon name: computer-desktop
         Chassis: desktop 🖥️
      Machine ID: 010b5686956247a589eeb523b6174633
         Boot ID: b6ed0d5863ac439e989140298eba6348
    Product UUID: 03de0294-0480-05be-0006-220700080009
Operating System: Manjaro Linux
          Kernel: Linux 7.3.0-rc6-1-MANJARO
```

目标机上没有本仓库的源码目录：

```bash
find /home/kunweiz /root /opt /srv -maxdepth 4 -name 'a0lite*' -not -path '*/.cache/*' 2>/dev/null
# （无输出）
ls -la /home/kunweiz/Desktop
# assetrack  atomic-llama-cpp-turboquant  vibe
```

`12022` 不在目标机自己的监听表里：

```bash
ss -ltnp | grep 12022
# （无输出）
```

**判断**：SSH 免密 root 登录可用；目标机是宿主 `760K`，而 12022 的监听在目标机自己的 `ss` 输出中不存在，只能位于本地侧的端口转发/网络命名空间（推断），本地 `/home/kunweiz/Desktop/a0lite` 是独立副本，目标机上不存在同名目录，部署时必须显式传输源码或构建产物。

## 1. 系统与硬件

**原始命令**

```bash
uname -a; cat /etc/os-release; nproc; free -h; df -h /; df -h /home; lsblk -f
```

**输出片段**

```text
Linux 760K 7.3.0-rc6-1-MANJARO #1 SMP PREEMPT_DYNAMIC Mon, 05 Oct 2026 00:15:36 +0000 x86_64 GNU/Linux
NAME="Manjaro Linux"
PRETTY_NAME="Manjaro Linux"
ID=manjaro
ID_LIKE=arch
BUILD_ID=rolling
```

```text
4
               total        used        free      shared  buff/cache   available
Mem:            19Gi       1.5Gi       231Mi       3.6Mi        18Gi        17Gi
Swap:           21Gi       120Mi        21Gi
```

```text
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2       933G  498G  435G  54% /
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda2       933G  498G  435G  54% /
```

```text
NAME   FSTYPE FSVER LABEL UUID                                 FSAVAIL FSUSE% MOUNTPOINTS
sda
|-sda1 vfat   FAT32       0707-ACDD                             299.1M     0% /boot/efi
|-sda2 f2fs   1.16        7c34b5ba-93c7-4b0f-89b7-e21fe9411e4e  434.9G    53% /
`-sda3 swap   1     swap  473d740f-022d-4175-8383-eb52387ae2bd                [SWAP]
```

```text
$ lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Core|Socket|Virtualization'
CPU(s):                                  4
Model name:                              AMD Athlon(tm) X4 760K Quad Core Processor
Thread(s) per core:                      1
Core(s) per socket:                      4
Socket(s):                               1
CPU(s) scaling MHz:                      100%
Virtualization:                          AMD-V
```

```text
$ df -i /
Filesystem       Inodes   IUsed    IFree IUse% Mounted on
/dev/sda2      10017277 8319639 1697638   84% /
```

**判断**：4 核老 Athlon、19 GiB 内存、根分区 435 GiB 可用，磁盘和内存都够；但 inode 已用 84%，且 CPU 无 SIMD 优势，任何本地大模型推理都会很慢。

## 2. GPU

**原始命令**

```bash
lspci | grep -Ei 'vga|3d|display'
nvidia-smi
ls -l /dev/dri /dev/nvidia*
lsmod | grep -Ei '^nvidia|nouveau'
lspci -k -s 01:00.0
pacman -Q | grep -iE 'nvidia|vulkan|mesa'
pacman -Ql linux73-nvidia-open | grep -E '\.ko'
modinfo nvidia
```

**输出片段**

```text
01:00.0 VGA compatible controller: NVIDIA Corporation GA104 [GeForce RTX 3070 Ti] (rev a1)
```

```text
$ nvidia-smi
NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver. Make sure that the latest NVIDIA driver is installed and running.
```

```text
$ ls -l /dev/dri /dev/nvidia*
crw-rw---- 1 root video 226, 0 Nov 11 19:20 /dev/dri/card0
ls: cannot access '/dev/nvidia*': No such file or directory
```

```text
$ lspci -k -s 01:00.0
01:00.0 VGA compatible controller: NVIDIA Corporation GA104 [GeForce RTX 3070 Ti] (rev a1)
        Subsystem: Gigabyte Technology Co., Ltd Device 408d
        Kernel modules: nouveau
```

```text
$ lsmod | grep -Ei '^nvidia|nouveau'
# （无输出）
$ modinfo nvidia
modinfo: ERROR: Module nvidia not found.
```

```text
$ pacman -Q | grep -iE 'nvidia|vulkan|mesa'
lib32-nvidia-utils 610.57.04-1
linux73-nvidia-open 610.57.04-0.2
nvidia-utils 610.57.04-1
opencl-nvidia 610.57.04-1
vulkan-icd-loader 1.4.357.0-1
...
$ pacman -Ql linux73-nvidia-open | grep -E '\.ko'
linux73-nvidia-open /usr/lib/modules/7.3.0-rc1-2-MANJARO/extramodules/nvidia.ko.zst
...
```

**判断**：GPU 是 RTX 3070 Ti，但驱动模块只为 `7.3.0-rc1-2-MANJARO` 编译，运行内核是 `7.3.0-rc6-1-MANJARO`，模块未加载、`/dev/nvidia*` 不存在，因此当前没有 CUDA，Ollama 只能走 CPU。

## 3. flatpak

**原始命令**

```bash
flatpak --version
flatpak list --all --columns=application,branch,origin,installation
flatpak remotes -d
command -v flatpak-builder; flatpak-builder --version
flatpak list --runtime | grep -i freedesktop
# 用户安装（应用实际所在处）
sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user list --all --columns=application,branch,origin,installation
sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user remotes -d
sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user info org.agentzero.AgentZero
```

**输出片段**

```text
$ flatpak --version
Flatpak 1.18.4
$ command -v flatpak-builder; flatpak-builder --version
/usr/bin/flatpak-builder
flatpak-builder-1.4.12
```

系统安装为空，系统 remote 只有 flathub：

```text
$ flatpak list --all --columns=application,branch,origin,installation
# （无输出）
$ flatpak remotes -d
flathub  Flathub  https://dl.flathub.org/repo/  - - - 1  system  Central repository of Flatpak applications ...

$ flatpak list --runtime | grep -i freedesktop
# （系统域无输出）
$ ls -la /root/.local/share/flatpak
drwx------ 3 root root 3488 Nov  2 07:47 .
-rw-r--r-- 1 root root    0 Nov  2 07:47 .changed
drwxr-xr-x 7 root root 3488 Nov  2 07:47 repo
```

用户安装（`kunweiz`，9.6 G）才是应用所在处：

```text
$ sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user list --all --columns=application,branch,origin,installation
org.agentzero.AgentZero       master      agentzero-origin  user
org.agentzero.AgentZero.Cuda  12          cuda-origin       user
org.agentzero.AgentZero.Models 1.0        models-local      user
org.agentzero.AgentZero.Wps   1.0         wps-origin        user
org.freedesktop.Platform      25.08       flathub           user
org.freedesktop.Platform.GL.default 25.08-extra flathub     user
org.freedesktop.Platform.GL.nvidia-610-57-04 1.4 flathub    user
org.freedesktop.Platform.VAAPI.nvidia 25.08 flathub         user
org.freedesktop.Sdk           25.08       flathub           user
org.gtk.Gtk3theme.Matcha-light-sea 3.22 flathub            user
...
```

```text
$ sudo -u kunweiz ... flatpak --user remotes -d
flathub        Flathub  https://dl.flathub.org/repo/  ... 1  ...
models-local   -        file:///home/kunweiz/a0-models-repo  ... 1  no-gpg-verify
```

```text
$ sudo -u kunweiz ... flatpak --user info org.agentzero.AgentZero
            ID: org.agentzero.AgentZero
           Ref: app/org.agentzero.AgentZero/x86_64/master
        Branch: master
       Version: 1.0
        Origin: agentzero-origin
  Installation: user
Installed Size: 128.0 MB
       Runtime: org.freedesktop.Platform/x86_64/25.08
           Sdk: org.freedesktop.Sdk/x86_64/25.08
        Commit: b15bc3875ed0fbbb6c842e863259d19ac0dd7a3f3b72fc7019f6b620b190ad1d
          Date: 2026-11-02 18:53:45 +0000
```

```text
$ ls /home/kunweiz/.local/share/flatpak/runtime
org.agentzero.AgentZero.Cuda
org.agentzero.AgentZero.Models
org.freedesktop.Platform
org.freedesktop.Platform.GL.default
org.freedesktop.Platform.GL.nvidia-610-57-04
org.freedesktop.Platform.Locale
org.freedesktop.Platform.VAAPI.nvidia
org.freedesktop.Platform.codecs-extra
org.freedesktop.Sdk
org.freedesktop.Sdk.Locale
org.gtk.Gtk3theme.Matcha-light-sea
$ du -sh /home/kunweiz/.local/share/flatpak
9.6G
```

**判断**：flatpak 与 flatpak-builder 都齐全，Sdk/Platform 25.08 已装，具备本地构建条件；但应用是 **user 安装**，任何 `root` 身份下的 `flatpak list`/`flatpak info` 都会显示"未安装"，部署脚本必须以 `kunweiz` + `--user` 运行。

## 4. Ollama

**原始命令**

```bash
command -v ollama; ollama --version
systemctl status ollama --no-pager
curl -sS --max-time 5 http://127.0.0.1:11434/api/tags
curl -sS --max-time 5 http://127.0.0.1:11434/api/version
curl -sS --max-time 5 http://127.0.0.1:11434/api/ps
du -sh /proc/808/root/app/share/agent-zero/models
tr '\0' '\n' < /proc/808/environ | grep -i -E 'OLLAMA|MODEL'
ss -ltnp | grep 11434
```

**输出片段**

```text
$ command -v ollama; ollama --version
bash: line 15: ollama: command not found
$ systemctl status ollama --no-pager
Unit ollama.service could not be found.
```

但有一个由 Flatpak 应用拉起的 bundled Ollama：

```text
$ curl -sS http://127.0.0.1:11434/api/version
{"version":"0.40.13"}
$ ps -o pid,etime,%cpu,%mem,rss,args -p 808
  808  7-01:14:13  0.0  0.1 33380 /app/share/agent-zero/models/bin/ollama serve
$ ss -ltnp | grep 11434
LISTEN 0 4096 127.0.0.1:11434 0.0.0.0:* users:(("ollama",pid=808,fd=3))
```

模型清单（3 个，合计 4.92 GiB）：

```text
lfm3-omni:2b-q4_K_M
qwen3-embedding:4b-q4_K_M
xiaomi-ocr:latest
```

```text
$ curl -sS http://127.0.0.1:11434/api/ps
{"models":[]}
```

```text
$ tr '\0' '\n' < /proc/808/environ | grep -i -E 'OLLAMA|MODEL'
OLLAMA_HOST=127.0.0.1:11434
OLLAMA_MODELS=/app/share/agent-zero/models/models
OLLAMA_MAX_LOADED_MODELS=2
OLLAMA_KEEP_ALIVE=30m
LD_LIBRARY_PATH=/app/lib/gi:/app/share/agent-zero/cuda/cuda_v12:/app/share/agent-zero/cuda/cuda_v13:/app/share/agent-zero/models/lib/ollama
$ du -sh /proc/808/root/app/share/agent-zero/models
5.1G
```

**判断**：Ollama 不是系统服务、也没有 CLI，而是应用自带的 `0.40.13` 二进制由 Flatpak 沙盒内启动，监听 `127.0.0.1:11434`，模型目录 5.1 GB 且三个模型可用；它随旧实例存活，不由 systemd 直接管理。

## 5. 显示环境

**原始命令**

```bash
echo "DISPLAY=[$DISPLAY]"; ls -la /tmp/.X11-unix/
ps -eo pid,comm,args | grep -Ei 'Xorg|Xvfb|Xpra|wayland|weston' | grep -v grep
systemctl get-default
systemctl list-units --type=service --all | grep -i -E 'display-manager|gdm|lightdm|sddm|greetd'
loginctl list-sessions
sshd -T | grep -Ei 'x11forwarding|allowtcpforwarding|x11uselocalhost'
```

**输出片段**

```text
DISPLAY=[]
total 20
drwxrwxrwt  2 root root  3488 Nov 10 21:45 .
drwxrwxrwt 39 root root 512000 Nov 17 22:57 ..
```

```text
$ ps -eo pid,comm,args | grep -Ei 'Xorg|Xvfb|Xpra|wayland|weston' | grep -v grep
    972 python          /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/bin/python /app/bin/xpra start-desktop :120 --xvfb=/app/bin/Xvfb -screen 0 1920x1080x24 -nolisten tcp ... --html=on --bind-tcp=127.0.0.1:14500 --tcp-auth=env --log-dir=...
    985 Xvfb            /app/bin/Xvfb-for-Xpra-120 -screen 0 1920x1080x24 -nolisten tcp -noreset :120
```

```text
$ systemctl get-default
graphical.target
$ systemctl list-units --type=service --all | grep -i -E 'display-manager|gdm|lightdm|sddm|greetd'
  lightdm.service  loaded inactive dead  Light Display Manager
```

```text
$ loginctl list-sessions
SESSION  UID USER    SEAT LEADER CLASS         TTY IDLE SINCE
      1    0 root    -    476    manager-early -   no   -
  ...
      2 1000 kunweiz -    506    manager       -   no   -
      3  958 flatpak -    507    manager-early -   no   -
```

```text
$ loginctl show-session 2 -p Type -p Class -p Active -p Display -p Seat
Seat=
Display=
Active=yes
Type=unspecified
Class=manager
```

```text
$ ss -ltnp | grep 14500
LISTEN 0 5 127.0.0.1:14500 0.0.0.0:* users:(("python",pid=972,fd=4))
$ curl -sS -D- -o /dev/null --max-time 5 http://127.0.0.1:14500/
HTTP/1.0 200 OK
Server: Xpra-WebSocket-Server Python/3.14
Content-type: text/html
Content-Length: 57116
```

**判断**：目标机没有宿主 Xorg 会话，`/tmp/.X11-unix` 为空、lightdm 未运行；唯一可用的图形路径是旧部署中 `agent-zero-desktop.service` 拉起的 Xvfb `:120` + Xpra TCP/HTML `14500`，不是系统桌面，SSH X11 转发也被关闭。

## 6. 现有部署痕迹

**原始命令**

```bash
cat /etc/systemd/system/agent-zero.service
cat /etc/systemd/system/agent-zero-desktop.service
systemctl status agent-zero --no-pager
systemctl status agent-zero-desktop --no-pager
ls -la /home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero/current/active/files/share/agent-zero/flatpak
cat /home/kunweiz/.local/share/flatpak/overrides/org.agentzero.AgentZero
pgrep -af 'agentzero|agent-zero|a0lite'
curl -sS http://127.0.0.1:5080/api/health
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5080/
journalctl -u agent-zero -n 25 --no-pager
du -sh /home/kunweiz/.var/app/org.agentzero.AgentZero
du -sh /home/kunweiz/a0-models-repo
ls -la /root; ls -la /tmp/*.flatpak /tmp/*.log
mount | grep -E 'private-mm|public-mm'
```

**输出片段**

`/etc/systemd/system/agent-zero.service`（节选，省略 `Documentation` 与 `RequiresMountsFor`）：

```ini
[Unit]
Description=Agent Zero, Flatpak build, all inference through the bundled Ollama
After=display-manager.service network-online.target
Wants=display-manager.service network-online.target
[Service]
Type=simple
User=kunweiz
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/kunweiz/.Xauthority
WorkingDirectory=/home/kunweiz
ExecStart=/usr/bin/flatpak run --user org.agentzero.AgentZero
Restart=always
RestartSec=5
[Install]
WantedBy=graphical.target
```

`/etc/systemd/system/agent-zero-desktop.service`（节选，省略部分 `Environment` 与 `Wants`）：

```ini
[Service]
Type=oneshot
User=kunweiz
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/kunweiz/.Xauthority
ExecStart=/usr/local/bin/a0-desktop-start
RemainAfterExit=yes
Restart=on-failure
```

运行状态：

```text
● agent-zero.service - Agent Zero, Flatpak build, all inference through the bundled Ollama
     Loaded: loaded (/etc/systemd/system/agent-zero.service; enabled; preset: disabled)
     Active: active (running) since Tue 2026-11-10 21:45:08 CST; 1 week 0 days ago
   Main PID: 595 (bwrap)
Nov 10 21:45:09 760K flatpak[595]: F: X11 socket /tmp/.X11-unix/X0 does not exist in filesystem, trying to use abstract socket instead.

● agent-zero-desktop.service - Agent Zero desktop session (Xpra on the host display)
     Active: active (exited) since Tue 2026-11-10 21:45:56 CST
```

进程与端口：

```text
595 bwrap --args 71 -- agent-zero
764 bwrap --args 71 -- agent-zero
782 .../venv/bin/python -c import a0flatpak; a0flatpak.apply(); import runpy; runpy.run_path('run_ui.py', ...) --port=5080 --host=127.0.0.1
808 /app/share/agent-zero/models/bin/ollama serve
972 .../python /app/bin/xpra start-desktop :120 --xvfb=/app/bin/Xvfb ... --bind-tcp=127.0.0.1:14500
```

```text
$ curl -sS http://127.0.0.1:5080/api/health
{"status":"ok"}
$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5080/
401
```

Flatpak override（含既有认证配置）：

```ini
[Context]
filesystems=host-etc:ro;host-os:ro;host;

[Environment]
A0_AUTH_KEY=<已设置，5 位，值见目标机该文件>
ALLOWED_ORIGINS=https://ai.kw92.cyou:12443,http://127.0.0.1:5080
A0_OLLAMA_BIND=127.0.0.1:11434
```

占用与残留：

```text
$ du -sh /home/kunweiz/.var/app/org.agentzero.AgentZero
1.5G    /home/kunweiz/.var/app/org.agentzero.AgentZero
$ du -sh /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero
1.3G
$ du -sh /home/kunweiz/a0-models-repo
4.7G
$ du -sh /home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero
133M
```

```text
$ mount | grep -E 'private-mm|public-mm'
syncmount-mm on /home/kunweiz/public-mm type fuse.syncmount-mm (rw,...,allow_other)
syncmount-mm on /home/kunweiz/private-mm type fuse.syncmount-mm (rw,...,allow_other)
$ ls /home/kunweiz/private-mm
ls: cannot access '/home/kunweiz/private-mm': Transport endpoint is not connected
```

```text
$ ls -la /root
-rwxr-xr-x  1 root    root    62079102 Oct 22 17:12 mihomo
drwxr-xr-x  2 root    root        3488 Nov 11 19:30 tbt-cc-probe
drwxr-xr-x 14 kunweiz kunweiz    3488 Nov 11 19:56 tbt-earlyfin-f0575c3
drwxr-xr-x  2 root    root        3488 Nov 12 06:23 tbtun-uninstall-20261112T062352Z
-rwxr-xr-x  1 root    root       31070 Nov 11 05:00 verify-adapt-073.sh
...（其余 40+ 条历史试验目录与日志）

$ ls -la /tmp/*.flatpak /tmp/*.log 2>/dev/null
ls: cannot access '/tmp/*.flatpak': No such file or directory
-rw-r--r-- 1 root root 0 Nov 17 15:18 /tmp/c.log
-rw-r--r-- 1 root root 0 Nov 17 15:19 /tmp/c2.log
...（共 60+ 行日志文件）
$ du -sh /tmp
1.9G    /tmp
$ ls -la /tmp/tbt-client-7da.log
-rw-r--r-- 1 root root 76490506 Nov 11 18:18 /tmp/tbt-client-7da.log

$ systemctl list-units --all | grep -i agent
  agent-zero-desktop.service   loaded active exited   ...
  agent-zero.service           loaded active running  ...
● hermes-gateway-yuexin.service loaded activating auto-restart Hermes Agent Gateway ...
```

**判断**：目标机上已有一套完整且已运行一周的旧部署（user 安装 + 两个 systemd unit），新部署会直接与它抢 `5080/11434/14500`，必须先停旧 unit 或改端口，并明确保留还是重建 `~/.var/app` 数据目录与 4.7 GB 模型仓库。

## 7. 网络

**原始命令**

```bash
curl -sS -o /dev/null -w 'github=%{http_code} time=%{time_total}\n' --max-time 8 https://github.com
curl -sS -o /dev/null -w 'flathub=%{http_code} time=%{time_total}\n' --max-time 8 https://dl.flathub.org
getent hosts github.com; getent hosts dl.flathub.org; cat /etc/resolv.conf
env | grep -iE 'proxy|http_'
grep -rEi 'proxy' /etc/environment /etc/profile.d/*.sh
ss -ltnp | grep -E '7890|7899'
```

**输出片段**

```text
github=200 time=3.975151
flathub=200 time=1.546175
```

```text
140.82.121.4    github.com
2a04:4e42::347  dualstack.n.sni.global.fastly.net dl.flathub.org
...
$ getent ahostsv4 dl.flathub.org | head -5
151.101.129.91  STREAM dualstack.n.sni.global.fastly.net
151.101.193.91  STREAM dualstack.n.sni.global.fastly.net
```

```text
# /etc/resolv.conf
nameserver 114.114.114.114
nameserver fe80::1%enp2s0
```

```text
$ env | grep -iE 'proxy|http_'
# （无输出）
$ ss -ltnp | grep -E '7890|7899'
LISTEN ... 127.0.0.1:7899 ... users:(("mihomo-090",pid=309449,fd=6))
LISTEN ... 127.0.0.1:7890 ... users:(("mihomo",pid=502786,fd=3))
```

**判断**：GitHub 与 Flathub 均可达（200），IPv4 DNS 正常，但 GitHub 单次约 4 秒；本机有 mihomo 代理监听 7890/7899，却没有 `http_proxy` 环境变量，首次拉取大 runtime 可能偏慢。

## 8. SSH、shell 与身份

**原始命令**

```bash
whoami; id; echo "SHELL=$SHELL"; command -v bash sh zsh fish
sshd -T | grep -Ei '^(x11forwarding|allowtcpforwarding|x11uselocalhost|permitrootlogin|passwordauthentication|pubkeyauthentication)'
cat /etc/ssh/sshd_config.d/99-kw92-mesh.conf
```

**输出片段**

```text
root
uid=0(root) gid=0(root) groups=0(root)
SHELL=/usr/bin/bash
/usr/bin/bash
/usr/bin/sh
/usr/bin/zsh
```

```text
permitrootlogin yes
pubkeyauthentication yes
passwordauthentication yes
x11forwarding no
x11uselocalhost yes
allowtcpforwarding yes
```

```text
$ cat /etc/ssh/sshd_config.d/99-kw92-mesh.conf
PubkeyAuthentication yes
```

**判断**：root 免密登录成功，bash/sh/zsh 可用，TCP 转发允许；`X11Forwarding no` 是硬限制，不能靠 `ssh -X` 做图形验收。

## 9. 中文字体

**原始命令**

```bash
ls /usr/share/fonts
fc-list :lang=zh | head
fc-list :lang=zh | wc -l
locale -a | grep -i zh
locale
```

**输出片段**

```text
Adwaita  TTF  adobe-source-sans  encodings  gsfonts  misc  noto  noto-cjk  sarasa-gothic
/usr/share/fonts/noto-cjk/NotoSansCJK-Light.ttc: Noto Sans CJK JP,Noto Sans CJK JP Light:style=Light,Regular
/usr/share/fonts/sarasa-gothic/Sarasa-Bold.ttc: Sarasa Term Slab HC:style=Bold
count=560
```

```text
$ locale -a | grep -i zh
zh_CN
zh_CN.gb18030
zh_CN.gbk
zh_CN.utf8
zh_TW.utf8
...
$ locale
LANG=
LC_CTYPE="POSIX"
```

**判断**：中文字体充足（Noto CJK + 更纱黑体，560 条），`zh_CN.utf8` locale 已生成；但默认 `LANG` 为空，图形验收启动应用时需显式设置 `LANG=zh_CN.UTF-8`。

## 10. 端口占用

**原始命令**

```bash
ss -ltnp | grep -E ':(5080|11434|14500|6080)\b'
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 3 http://127.0.0.1:6080/
ss -ltnp | head -40
```

**输出片段**

```text
LISTEN 0 2048 127.0.0.1:5080  0.0.0.0:* users:(("python",pid=782,fd=27))
LISTEN 0 5    127.0.0.1:14500 0.0.0.0:* users:(("python",pid=972,fd=4))
LISTEN 0 4096 127.0.0.1:11434 0.0.0.0:* users:(("ollama",pid=808,fd=3))
$ curl -sS --max-time 3 http://127.0.0.1:6080/
curl: (7) Failed to connect to 127.0.0.1:6080 after 0 ms: Could not connect to server
000
```

其它监听（节选）：`22 sshd`、`7676/18081 node`、`7890/7899 mihomo`、`5201 python3`、`19000 tbt_client`、`18080 zproxy`、`10022/11022/13022/14022/15022 frpc`、`198.18.0.1:33647 mihomo`。

**判断**：`5080`、`11434`、`14500` 已被旧部署占满，`6080` 空闲；新实例若沿用默认端口会直接绑定失败。

## 阻塞项

### 会直接阻断部署或验收

1. **GPU 不可用（驱动与内核不匹配）**：`nvidia-smi` 失败，`/dev/nvidia*` 不存在，`linux73-nvidia-open 610.57.04-0.2` 只为 `7.3.0-rc1-2-MANJARO` 提供 `nvidia.ko.zst`，运行内核是 `7.3.0-rc6-1-MANJARO`。若验收要求 GPU 推理，必须先安装匹配 `7.3.0-rc6` 的 nvidia-open 模块并重启；否则只能接受 CPU 推理（4 核 Athlon）。

2. **没有宿主 X 会话，且 SSH 禁止 X11 转发**：`X11Forwarding no`，`/tmp/.X11-unix` 为空，lightdm inactive，`loginctl` 无图形 seat。图形界面只能通过旧实例的 Xpra HTML `127.0.0.1:14500`（或另起 VNC/Xpra）验证，不能按"本机桌面 + ssh -X"的方式验收。

3. **默认端口全部被旧部署占用**：`5080`（Web UI）、`11434`（Ollama）、`14500`（Xpra）都由 2026-11-10 起运行的旧实例持有。新部署必须先 `systemctl stop agent-zero-desktop agent-zero`（或用 `6080` 等替代端口），否则无法启动。

4. **目标机没有源码或构建产物**：`find /home/kunweiz /root /opt /srv -maxdepth 4 -name 'a0lite*'` 无结果，`/home/kunweiz/Desktop` 下没有本仓库；必须先把源码/`.flatpak` 传到目标机（GitHub 可达，也可 `git clone`），本地未提交改动不会自动同步。

5. **flatpak 应用是 user 安装，root 视角为空**：`flatpak list --all` 作为 root 无输出、`flatpak info` 报 "not installed"，真实安装在 `/home/kunweiz/.local/share/flatpak`，必须用 `sudo -u kunweiz` + `flatpak --user`；用 root 直接 `flatpak install/uninstall` 会操作错安装域。

6. **`/home/kunweiz` 有两个坏掉的 FUSE 挂载**：`syncmount-mm on /home/kunweiz/{public,private}-mm` 均返回 `Transport endpoint is not connected`；任何递归扫描、打包或 `du` home 的脚本会报错或卡住，部署前应 `fusermount -u` 清理（属修改操作，侦察阶段未执行）。

### 需在部署计划中显式处理的约束

7. **既有部署数据需要明确处置**：`~/.var/app/org.agentzero.AgentZero` 1.5 GB、user flatpak 9.6 GB、本地模型仓库 `a0-models-repo` 4.7 GB、`~/.local/share/flatpak/app` 内旧 app 133 MB。重建还是复用决定部署步骤与磁盘占用，不能默认覆盖。

8. **缺 `jq` 与 `patchelf`**：`command -v jq patchelf` 无输出（仅有 ostree/git/python3/node/npm）。若构建或验收脚本依赖它们，需要先安装。

9. **网络可用但 GitHub 偏慢**：`github=200 time=3.975151`；无 `http_proxy` 环境变量（mihomo 仅在 7890/7899 监听）。首次拉取 runtime/SDK 可能需要几分钟，不应按超时判失败。

10. **inode 使用率 84%**：`/dev/sda2 10017277 inodes, IUsed 8319639, IFree 1697638`；空间剩 435 GB，但大量小文件构建（flatpak-builder 缓存、ostree 对象）仍可能撞 inode 上限。

## 附：可直接复用的连接与检查命令

```bash
SSH='ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -p 12022 root@127.0.0.1'

# 旧部署状态
$SSH 'systemctl status agent-zero agent-zero-desktop --no-pager | head -30'
$SSH 'curl -sS http://127.0.0.1:5080/api/health'
$SSH 'curl -sS http://127.0.0.1:11434/api/tags'

# 用户域 flatpak（必须）
$SSH 'sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user list --all'

# 图形入口
$SSH 'curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:14500/'
```
