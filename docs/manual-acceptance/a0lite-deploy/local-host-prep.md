# 本机部署前准备（7940HS）

- 采集时间：2026-11-17 23:2x–23:27 CST（本机时钟）
- 对象：本机宿主，用户 `kunweiz`，Manjaro rolling，内核 `7.2.9-1-MANJARO`
- 仓库：`/home/kunweiz/Desktop/a0lite`
- 本轮边界：**只读勘察 + 写本文档**。未执行任何 `flatpak install/uninstall/update/repair`，未停止任何服务或进程，未删除任何用户数据，未修改仓库源码，未把大文件写入 `/tmp`。唯一的“执行”是 X11 截图测试，写入管道后计数，未落盘。
- 快照状态：另一名工程师的 `scripts/build.sh` **仍在运行**，正在把 CUDA 扩展封成 bundle；`bundles/` 当前只有主包。本文所有“当前”均指上述采集时刻，构建完成后必须重新核对。

---

## 0. 结论摘要

| 问题 | 结论 |
|---|---|
| 本机是否已有 Agent Zero 实例在跑 | **没有**。`flatpak ps` 为空，5080/11434/14500/58891 全部没有监听，`curl` 均为 connection refused；systemd 系统级与 user 级都没有 agent-zero 单元。唯一匹配进程是 `flatpak build-bundle`（构建，不是应用）。 |
| GPU 与 Ollama 该走什么 | **只能走 CPU**。本机只有 AMD Radeon 780M 集显（Phoenix1），没有 NVIDIA 设备、没有 `nvidia-smi`、没有 `/dev/nvidia*`、没有 nvidia 内核模块。Cuda 扩展是 NVIDIA CUDA 专用，本机装了也无法验证，**不要装**。Ollama 走 CPU；聊天走 kw92 端点，不依赖本地大模型。 |
| kw92 端点是否可用 | **可用**。`127.0.0.1:18080` 返回 HTTP 200，模型回答 `1+1 等于 2。`，`finish_reason=stop`，usage 17/9/26。7890 也在监听；7899 没有监听。 |
| 截图方案是否可行 | **可行**。X11/XFCE 真实会话，`DISPLAY=:0.0`，`XAUTHORITY` 可读；`import -window root png:-` 实测输出 3840×2160 PNG，786,396 字节，mean=0.0503、sd=0.1851（非纯黑）。Chrome 156、ImageMagick、ffmpeg、xdotool 可用；无 scrot/wmctrl。 |
| bundles 是否已出现 | 采集时只有主包 `agent-zero.flatpak` 59,533,584 字节（23:23:54）；23:33 复核时 CUDA bundle 已出现（`agent-zero-cuda.flatpak` 860,154,032 字节），WPS bundle 正在生成。构建进程仍在跑，**现在不能安装**。 |
| 部署执行单里最容易失败的一步 | **第 c 步 `flatpak install --reinstall` 主包**。原因：主包是唯一已知可回滚 commit 的载体，而 `agentzero-origin` 远端指向的旧仓库路径已经不存在，`flatpak update --commit` 退路不可靠；如果 bundle 不完整或 `--reinstall` 先卸载后失败，会暂时没有可用应用。必须先在 Gate 0 等构建完成、校验三包，并预先生成旧 commit 的 rollback bundle，否则不要执行第 c 步。 |

---

## 1. 本机身份与图形环境

### 命令与原始输出

```console
$ hostname
7940HS
```

```console
$ uname -r
7.2.9-1-MANJARO
```

```console
$ nproc
16
```

```console
$ free -h
               total        used        free      shared  buff/cache   available
Mem:            62Gi        55Gi       1.7Gi        70Mi       5.5Gi       6.5Gi
Swap:          8.8Gi       4.9Gi       3.9Gi
```

```console
$ df -h /home /tmp
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  111G   78G   32G  71% /home
tmpfs            32G  834M   31G   3% /tmp
```

```console
$ echo $DISPLAY
:0.0
```

补充会话环境：

```console
$ echo "DISPLAY=${DISPLAY:-<unset>}"; echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"; echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-<unset>}"; echo "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-<unset>}"; echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"
DISPLAY=:0.0
WAYLAND_DISPLAY=<unset>
XDG_SESSION_TYPE=x11
XDG_CURRENT_DESKTOP=XFCE
XDG_RUNTIME_DIR=/run/user/1000
```

```console
$ loginctl list-sessions
SESSION  UID USER    SEAT  LEADER CLASS   TTY IDLE SINCE
      1 1000 kunweiz -     705    manager -   no   -
      2 1000 kunweiz seat0 760    user    -   no   -

2 sessions listed.
```

```console
$ loginctl session-status
2 - kunweiz (1000)
  Since: Sun 2026-11-15 22:41:38 CST; 2 days ago
  State: active
 Leader: 760 (lightdm)
   Seat: seat0; vc7
Display: :0
 Remote: no
Service: lightdm-autologin
   Type: x11
  Class: user
Desktop: xfce
   Idle: no
   Unit: session-2.scope
         ├─    760 lightdm --session-child 13 16
         ├─    772 xfce4-session
         ├─    865 /usr/bin/ssh-agent -s
         ├─    875 xfwm4
         ├─    931 xfce4-panel
         ├─    937 Thunar --daemon
         ├─    944 xfdesktop
         ...
```

```console
$ ps -eo pid,user,comm,args | grep -Ei 'Xorg|wayland|gnome-shell|kwin|xfce|lightdm|sddm' | grep -v grep
    704 root             lightdm                                   /usr/bin/lightdm
    727 root             Xorg                                      /usr/lib/Xorg :0 -seat seat0 -auth /run/lightdm/root/:0 -nolisten tcp vt7 -novtswitch
    760 root             lightdm                                   lightdm --session-child 13 16
    772 kunweiz          xfce4-session                             xfce4-session
    931 kunweiz          xfce4-panel                               xfce4-panel
    945 kunweiz          wrapper-2.0                               /usr/lib/xfce4/panel/wrapper-2.0 /usr/lib/xfce4/panel/plugins/libwhiskermenu.so 8 14680071 whiskermenu "Whisker Menu" "Show a menu to easily access installed applications"
    982 kunweiz          wrapper-2.0                               /usr/lib/xfce4/panel/wrapper-2.0 /usr/lib/xfce4/panel/plugins/libsystray.so 6 14680073 systray "Status Tray Plugin" "Provides status notifier items (application indicators) and legacy systray items"
    989 kunweiz          wrapper-2.0                               /usr/lib/xfce4/panel/wrapper-2.0 /usr/lib/xfce4/panel/plugins/libpulseaudio-plugin.so 9 14680074 pulseaudio "PulseAudio Plugin" "Adjust the audio volume of the PulseAudio sound system"
   1083 kunweiz          xfce4-notifyd                             /usr/lib/xfce4/notifyd/xfce4-notifyd
   1265 kunweiz          xfce4-screensav                           xfce4-screensaver
   1267 kunweiz          xfce4-power-man                           /usr/lib/xfce4/panel/wrapper-2.0 /usr/lib/xfce4/panel/plugins/libxfce4power.so 8 14680075 power "Power Manager Plugin" "Show battery status and control power settings"
```

```console
$ ls -la /tmp/.X11-unix/
total 0
drwxrwxrwt     2 root root      60 Nov 15 22:41 .
drwxrwxrwt 25655 root root 528080 Nov 17 23:24 ..
srwxrwxrwx     1 root root       0 Nov 15 22:41 X0
```

补充：`XAUTHORITY=/home/kunweiz/.Xauthority`，文件存在且属主为 `kunweiz`，权限 `-rw-------`（156 字节）。

### 判断

- 这是**真实 X11 会话**，不是 Wayland，也不是无头 Xvfb。`lightdm` 自动登录 `kunweiz`，`xfce4-session` 和 `Xorg :0` 都在。
- 屏幕分辨率 3840×2160（见第 6 节 `xrandr`），有完整 XFCE 桌面，可做真实窗口级验收和肉眼检查。
- 当前 shell 能直接连 `:0`，`xset q` 返回 0；截图路径已实测可用。

---

## 2. 现有部署

### 2.1 已安装的 Flatpak

```console
$ flatpak --user list --all --columns=application,branch,origin,size
org.agentzero.AgentZero	master	agentzero-origin	128.1 MB
org.agentzero.AgentZero.Cuda	12	cuda-origin	1.4 GB
org.agentzero.AgentZero.Models	1.0	models-local	5.4 GB
org.agentzero.AgentZero.Wps	1.0	wps-origin	190.1 MB
org.agentzero.AgentZero.Wps.Debug	1.0	debug1-origin	56.3 kB
org.freedesktop.Platform	25.08	flathub	670.9 MB
org.freedesktop.Platform.GL.default	25.08	flathub	462.0 MB
org.freedesktop.Platform.GL.default	25.08-extra	flathub	462.1 MB
org.freedesktop.Platform.Locale	25.08	flathub	512 bytes
org.freedesktop.Platform.codecs-extra	25.08-extra	flathub	43.4 MB
org.freedesktop.Sdk	25.08	flathub	1.7 GB
org.freedesktop.Sdk.Locale	25.08	flathub	512 bytes
org.gtk.Gtk3theme.Matcha-light-sea	3.22	flathub	554.0 kB
org.test.PyProbe	master	pyprobe-origin	99.8 MB
org.test.PyProbe.Debug	master	debug-origin	5.4 MB
```

说明：`org.test.PyProbe`、`PyProbe.Debug`、`Wps.Debug` 是测试/调试残留，不属于 Agent Zero 运行必需；本轮不清理。

### 2.2 主包信息（回滚基线）

```console
$ flatpak --user info org.agentzero.AgentZero

Agent Zero - Agentic framework with a bundled local model backend

            ID: org.agentzero.AgentZero
           Ref: app/org.agentzero.AgentZero/x86_64/master
          Arch: x86_64
        Branch: master
       Version: 1.0
       License: MIT
        Origin: agentzero-origin
    Collection:
  Installation: user
Installed Size: 128.1 MB
       Runtime: org.freedesktop.Platform/x86_64/25.08
           Sdk: org.freedesktop.Sdk/x86_64/25.08

        Commit: 44c0ae8315893f0ee43b867d3cc1d31219c29e24a7a9b8e0666501d9563bf96b
        Parent: 18c6e778a542a0424e4a85099054c0bad4b9ec83379827c929cfe1148e180051
       Subject: Export org.agentzero.AgentZero
          Date: 2026-11-01 11:30:12 +0000
```

**旧 commit（回滚必须记录）**：

```
44c0ae8315893f0ee43b867d3cc1d31219c29e24a7a9b8e0666501d9563bf96b
```

扩展组件的 commit 基线：

| 组件 | Branch | Commit | Date |
|---|---|---|---|
| `org.agentzero.AgentZero.Cuda` | 12 | `8d1b15a300628db7f043cc545fb1aac3372039da5252d9e2e44e2ca9f20b7a84` | 2026-11-01 09:53:44 +0000 |
| `org.agentzero.AgentZero.Wps` | 1.0 | `184cc3776f17b1fd5883cdbf0a3316c04f7e9535004b1c2067785fac37a23380` | 2026-11-01 09:57:04 +0000 |
| `org.agentzero.AgentZero.Models` | 1.0 | `f011ae9bf72cb9fe0414820ae621c18a275511beb626791a3f14a23c30dc8b27` | 2026-11-01 10:12:43 +0000 |

### 2.3 远端

```console
$ flatpak --user remotes -d
flathub	Flathub	https://dl.flathub.org/repo/	-	-	-	1		Central repository of Flatpak applications	Central repository of Flatpak applications	https://flathub.org/	https://dl.flathub.org/repo/logo.svg
models-local	-	file:///home/kunweiz/a0build/modelsext/repo2	-	-	-	1	no-gpg-verify	-	-	-	-
agentzero-origin	Local repo	file:///home/kunweiz/a0build/fbbuild/state/cache	-	-	-	0	no-enumerate,no-gpg-verify	-	-	-	-
cuda-origin	Local repo	file:///home/kunweiz/a0build/fbbuild/state/cache	-	-	-	0	no-enumerate,no-gpg-verify	-	-	-	-
debug-origin	Local repo	file:///tmp/fbbuild/state/cache	-	-	-	0	no-enumerate,no-gpg-verify	-	-	-	-
debug1-origin	Local repo	file:///home/kunweiz/a0build/fbbuild/state/cache	-	-	-	0	no-enumerate,no-gpg-verify	-	-	-	-
pyprobe-origin	Local repo	file:///tmp/fbbuild/state/cache	-	-	-	0	no-enumerate,no-gpg-verify	-	-	-	-
wps-origin	Local repo	file:///home/kunweiz/a0build/fbbuild/state/cache	-	-	-	0	no-enumerate,no-gpg-verify	-	-	-	-
```

**关键事实**：`agentzero-origin` 指向的 `/home/kunweiz/a0build/fbbuild/state/cache` **已经不存在**。`flatpak remote-info --user agentzero-origin org.agentzero.AgentZero` 返回：

```console
error: Unable to load summary from remote agentzero-origin: Remote listing for agentzero-origin not available; server has no summary file. Check the URL passed to remote-add was valid.
```

因此 **`flatpak update --commit=44c0ae83…` 不能作为唯一回滚路径**。回滚必须先预生成旧 bundle（见第 9 节 h）。

### 2.4 Override

```console
$ flatpak --user override --show org.agentzero.AgentZero
(空)
```

```console
$ ls -la ~/.local/share/flatpak/overrides/
total 0
drwxr-xr-x 1 kunweiz kunweiz   0 Nov 17 23:21 .
drwxr-xr-x 1 kunweiz kunweiz 114 Nov 17 23:15 ..
```

说明：override 目录为空，没有 `org.agentzero.AgentZero` 文件；当前**没有 `A0_AUTH_KEY`**，也没有额外文件系统权限。应用权限完全来自 manifest。当前安装的旧 commit 权限是：

```console
$ flatpak --user info --show-permissions org.agentzero.AgentZero
[Context]
shared=ipc;network;
sockets=pulseaudio;x11;
devices=dri;
filesystems=home;/run/udev:ro;

[Environment]
OLLAMA_HOST=http://127.0.0.1:11434
```

新 manifest 已改为 `--filesystem=host`、`--filesystem=host-etc:ro`、`--filesystem=host-os:ro`，安装新包后权限会明显变宽（见第 9 节 c 的验证）。

### 2.5 用户数据目录

```console
$ ls -la ~/.var/app/org.agentzero.AgentZero
total 0
drwxr-xr-x 1 kunweiz kunweiz  54 Nov 17 23:05 .
drwxr-xr-x 1 kunweiz kunweiz 132 Nov  1 17:57 ..
drwxr-xr-x 1 kunweiz kunweiz 140 Nov 17 23:14 .ld.so
drwxr-xr-x 1 kunweiz kunweiz  10 Nov  1 16:32 .local
drwxr-xr-x 1 kunweiz kunweiz  26 Nov 17 23:05 cache
drwxr-xr-x 1 kunweiz kunweiz  44 Nov  1 17:19 config
drwxr-xr-x 1 kunweiz kunweiz  24 Nov  1 16:51 data
```

```console
$ du -sh ~/.var/app/org.agentzero.AgentZero/*
0	/home/kunweiz/.var/app/org.agentzero.AgentZero/cache
4.0K	/home/kunweiz/.var/app/org.agentzero.AgentZero/config
984M	/home/kunweiz/.var/app/org.agentzero.AgentZero/data
```

```console
$ du -sh ~/.var/app/org.agentzero.AgentZero/data/*
867M	/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero
117M	/home/kunweiz/.var/app/org.agentzero.AgentZero/data/uv
```

说明：用户提到的“约 1.5G”在当前机器上实际是 **984M**（`data`），其中 `agent-zero` 867M、`uv` 117M；`cache` 为空。数据目录不是符号链接，指向真实目录。

`data/agent-zero` 内有 `agents/conf/knowledge/plugins/prompts/usr/venv/webui`；`venv` 848M，`.a0-ready` 标记存在（Nov 1 16:51）。`conf/model_providers.yaml` 当前**没有 kw92 条目**，需要验收时在 UI 或配置里添加（见第 9 节 f 后的提醒）。

---

## 3. 是否已有实例在跑

### 3.1 进程

```console
$ pgrep -af 'agentzero|agent-zero|run_ui|xpra|Xvfb'
1578334 flatpak build-bundle --runtime /home/kunweiz/Desktop/a0lite/build/cache /home/kunweiz/Desktop/a0lite/bundles/agent-zero-cuda.flatpak org.agentzero.AgentZero.Cuda 12
```

说明：唯一匹配是构建进程，不是应用实例。另一个相关进程是 `scripts/build.sh`（PID 1575008）。**两者都不能停**，否则 CUDA/WPS bundle 会残缺。

```console
$ flatpak ps
(空)
```

### 3.2 端口

```console
$ ss -ltnp | grep -E ':(5080|11434|14500|58891)\b'
(空)
```

5080、11434、14500、58891 全部没有监听。

### 3.3 健康检查

```console
$ curl -sS --max-time 3 http://127.0.0.1:5080/api/health
curl: (7) Failed to connect to 127.0.0.1:5080 after 0 ms: Could not connect to server
```

```console
$ curl -sS -o /dev/null -w '%{http_code}\n' --max-time 3 http://127.0.0.1:5080/
curl: (7) Failed to connect to 127.0.0.1:5080 after 0 ms: Could not connect to server
000
```

### 3.4 systemd

```console
$ systemctl list-units --all | grep -iE 'agent|a0'
  dev-disk-by\x2dpartuuid-85a7110b\x2d110f\x2d4d93\x2da8a8\x2d60fe716d8a05.device  loaded active plugged YMTC YMSS1ED02B21MC root
  dev-disk-by\x2dpath-pci\x2d0000:01:00.0\x2dnvme\x2d1\x2dpart-by\x2dpartuuid-85a7110b\x2d110f\x2d4d93\x2da8a8\x2d60fe716d8a05.device loaded active plugged YMTC YMSS1ED02B21MC root
  gpg-agent@etc-pacman.d-gnupg.service  loaded inactive dead GnuPG cryptographic agent and passphrase cache
  system-gpg\x2dagent.slice  loaded active active Slice /system/gpg-agent
  system-gpg\x2dagent\x2dbrowser.slice  loaded active active Slice /system/gpg-agent-browser
  system-gpg\x2dagent\x2dextra.slice  loaded active active Slice /system/gpg-agent-extra
  system-gpg\x2dagent\x2dssh.slice  loaded active active Slice /system/gpg-agent-ssh
  system-polkit\x2dagent\x2dhelper.slice  loaded active active Slice /system/polkit-agent-helper
  gpg-agent-browser@etc-pacman.d-gnupg.socket  loaded active listening GnuPG ...
  gpg-agent-extra@etc-pacman.d-gnupg.socket    loaded active listening GnuPG ...
  gpg-agent-ssh@etc-pacman.d-gnupg.socket      loaded active listening GnuPG ...
  gpg-agent@etc-pacman.d-gnupg.socket          loaded active listening GnuPG ...
  polkit-agent-helper.socket                   loaded active listening Authorization Manager Agent Helper socket
```

说明：匹配到的全部是 `gpg-agent`/`polkit-agent`，**没有 `agent-zero` 或 `a0` 单元**。

```console
$ systemctl --user list-units --all | grep -iE 'agent|a0'
  dev-disk-by\x2dpartuuid-...device  loaded active plugged ...
  gpg-agent.service                  loaded active running GnuPG cryptographic agent and passphrase cache
  gpg-agent-browser.socket           loaded active running GnuPG ...
  gpg-agent-extra.socket             loaded active running GnuPG ...
  gpg-agent-ssh.socket               loaded active running GnuPG ...
  gpg-agent.socket                   loaded active running GnuPG ...
```

```console
$ ls /etc/systemd/system | grep -iE 'agent|a0'
(空)
```

```console
$ flatpak list --system --columns=application,branch,origin
(空)
```

### 判断：当前没有实例，不需要停；如果以后有人在跑，停它会打断谁

- **当前状态**：无实例，5080/11434/14500/58891 全空，`flatpak ps` 空，systemd 无单元。因此第 9 节 b 步在本机是**空操作**。
- **如果执行部署时有人启动了旧实例**，停止它会打断：
  - 5080 的 Web UI：用户可能正在浏览器里对话，停下会断开页面和进行中的请求；
  - 11434 的内嵌 Ollama：嵌入、TTS、STT、OCR 全部中断，正在加载的模型会被卸载；
  - 14500+ 的 Xpra 桌面：正在被 Agent Zero 操作的桌面会话会断开；
  - 正在执行的 Agent 任务/工具调用：会随主进程退出而丢失运行态（落盘数据仍在）。
- **不要停** `scripts/build.sh`、`flatpak build-bundle`；它们不是服务，是构建。停它们会留下不完整的 bundle。
- 本机没有 systemd 单元；如果以后安装 `systemd/agent-zero.service`，它是 `Restart=always`，必须先 `systemctl stop agent-zero-desktop agent-zero`，否则安装期间会被重新拉起。该操作需要 sudo，本轮不做。

---

## 4. GPU 与推理能力

### 命令与原始输出

```console
$ lspci | grep -Ei 'vga|3d|display'
65:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Phoenix1 (rev c1)
```

```console
$ nvidia-smi
bash: line 1: nvidia-smi: command not found
```

```console
$ ls -l /dev/nvidia* /dev/dri
ls: cannot access '/dev/nvidia*': No such file or directory
/dev/dri:
total 0
drwxr-xr-x  2 root root         80 Nov 15 22:41 by-path
crw-rw----+ 1 root video  226,   1 Nov 17 17:07 card1
crw-rw-rw- 1 root render 226, 128 Nov 15 22:41 renderD128
```

```console
$ lsmod | grep -E 'nvidia|nouveau'
(空)
```

```console
$ nproc
16
```

```console
$ grep -m1 'model name' /proc/cpuinfo
model name	: AMD Ryzen 9 7940H  w/ Radeon 780M Graphics
```

```console
$ grep -o -m1 -E 'avx512[a-z_]*|avx2|avx' /proc/cpuinfo | sort -u
avx
avx2
avx512_bf
avx512_bitalg
avx512_vbmi
avx512_vnni
avx512_vpopcntdq
avx512bw
avx512cd
avx512dq
avx512f
avx512ifma
avx512vbmi
avx512vl
```

说明：上面 `avx512_bf`、`avx512_vbmi` 是命令正则 `[a-z_]*` 截断后的结果，实际 CPU 还带数字后缀（如 `avx512_bf16`、`avx512_vbmi2`）；这不影响“支持 AVX-512”的结论。

### 判断：Ollama 该走 CPU

- 本机**没有 NVIDIA GPU**：`lspci` 只有 AMD Phoenix1 集显；`nvidia-smi` 不存在；`/dev/nvidia*` 不存在；`lsmod` 没有 nvidia/nouveau。AMD 集显不能跑 CUDA。
- Cuda 扩展只包含 Ollama 的 `cuda_v12` 内核（`flatpak/org.agentzero.AgentZero.Cuda.yml`），是 **NVIDIA CUDA 专用**；本机装了也无法加载，只会多占 1.4 GB。
- 启动脚本在启动 Ollama 前设置：
  ```sh
  export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:--1}"
  ```
  默认 `-1` 就是 **CPU**；只有显式传 `0` 才尝试 GPU。本机应保持默认。
- CPU 为 16 逻辑核 Zen 4（7940H），有 AVX-512；CPU 推理可行，但内存是瓶颈（见下）。
- **推荐分工**：
  - 聊天/推理：走 `127.0.0.1:18080` 的 kw92，不占本地模型内存；
  - 嵌入：`qwen3-embedding:4b-q4_K_M`（2.50 GB）；
  - TTS/STT：`lfm3-omni:2b-q4_K_M`（2.00 GB）；
  - OCR：`xiaomi-ocr`（0.74 GB）。
- **内存约束**：当前 `free -h` 只有 6.2–6.5 GiB available，swap 已用 4.9 GiB；三模型权重合计 5.24 GB，默认 `OLLAMA_MAX_LOADED_MODELS=2` 很可能触发换页或 OOM。验收启动时应显式：
  ```sh
  --env=OLLAMA_MAX_LOADED_MODELS=1 --env=OLLAMA_KEEP_ALIVE=5m
  ```
  并且不要同时跑 OCR + 语音 + 嵌入的重负载用例。
- 当前最大的内存占用是 `omp` 主进程（RSS 约 52 GB），不是 Agent Zero；它是本轮编排器，不能停。验收时要预留这部分的压力，必要时分批做模型相关用例。

---

## 5. zproxy / kw92 端点

### 命令与原始输出

```console
$ ss -ltnp | grep -E ':(18080|7890|7899)\b'
LISTEN 0      4096                                  127.0.0.1:7890       0.0.0.0:*
LISTEN 0      512                                   127.0.0.1:18080      0.0.0.0:*
```

说明：7899 没有监听；`ss` 没有给出进程名/PID（当前权限下未显示 `users:` 字段），但端口确实在听。

```console
$ curl -sS -m 20 -w '\nHTTP=%{http_code}\n' -H 'Content-Type: application/json' -d '{"model":"mistral/deepseek-v4-1-flash-1017","messages":[{"role":"user","content":"用一句简体中文回答：1+1 等于几？"}],"max_tokens":64}' http://127.0.0.1:18080/v1/chat/completions
{"id":"chatcmpl-5e4679ac-5d0a-4305-8d8f-ac10178850dd","object":"chat.completion","created":1794929083,"model":"mistral/deepseek-v4-1-flash-1017","system_fingerprint":null,"choices":[{"index":0,"message":{"role":"assistant","content":"1+1 等于 2。","refusal":null},"finish_reason":"stop","logprobs":null}],"usage":{"prompt_tokens":17,"completion_tokens":9,"total_tokens":26,"prompt_tokens_details":{"cached_tokens":0}}}
HTTP=200
```

### 判断

- **端点可用**：HTTP 200，`choices[0].message.content` 非空，内容为 `1+1 等于 2。`，`finish_reason=stop`，没有被截断。
- 该端点没有鉴权；客户端填任意非空 key 即可（若客户端强制要求）。
- 注意路径：模型名是 `mistral/deepseek-v4-1-flash-1017`，服务端实际在 18080 的 OpenAI 兼容接口上工作；`GET /v1/models` 可能不可用，连通性以一次最小 chat 为准。
- 本机 7890 是代理端口，7899 未监听；不要让验收脚本误以为 7899 是必需端口。

---

## 6. 浏览器与截图工具链

### 6.1 工具存在性

```console
$ command -v google-chrome google-chrome-stable chromium scrot import convert ffmpeg python3 xdotool wmctrl
/usr/bin/google-chrome
/usr/bin/google-chrome-stable
/usr/bin/import
/usr/bin/convert
/usr/bin/ffmpeg
/usr/bin/python3
/usr/bin/xdotool
```

补充逐个确认（避免 `command -v` 多参数只看最后一个退出码的歧义）：

```console
$ for t in google-chrome google-chrome-stable chromium chromium-browser scrot import convert ffmpeg python3 xdotool wmctrl grim spectacle gnome-screenshot flameshot xwd; do printf '%-20s -> ' "$t"; command -v "$t" || echo '(not found)'; done
google-chrome        -> /usr/bin/google-chrome
google-chrome-stable -> /usr/bin/google-chrome-stable
chromium             -> (not found)
chromium-browser     -> (not found)
scrot                -> (not found)
import               -> /usr/bin/import
convert              -> /usr/bin/convert
ffmpeg               -> /usr/bin/ffmpeg
python3              -> /usr/bin/python3
xdotool              -> /usr/bin/xdotool
wmctrl               -> (not found)
grim                 -> (not found)
spectacle            -> (not found)
gnome-screenshot     -> (not found)
flameshot            -> (not found)
xwd                  -> (not found)
```

```console
$ google-chrome --version
Google Chrome 156.0.8078.79
```

```console
$ xdotool --version
xdotool version 4.20260303.1
```

### 6.2 X11 截图通道实测

```console
$ export DISPLAY=:0.0 XAUTHORITY=/home/kunweiz/.Xauthority
$ xset q >/dev/null 2>&1; echo $?
0
```

```console
$ xrandr --query
Screen 0: minimum 320 x 200, current 3840 x 2160, maximum 16384 x 16384
DisplayPort-0 connected 3840x2160+0+0 (normal left inverted right x axis y axis) 598mm x 336mm
   3840x2160     60.00*+ 100.00    60.00    59.94
   3840x2160_84.96  84.96
   3840x2160_85  85.00
   3840x2160_75  75.00
   2560x1440    120.00    60.00
   1920x1080    120.00   119.88    60.00    60.00    50.00    59.94
   ...
```

```console
$ import -window root png:- | wc -c
786396
```

```console
$ import -window root png:- | identify -format "size=%wx%h mean=%[fx:mean] sd=%[fx:standard_deviation]\n" -
size=3840x2160 mean=0.0503158 sd=0.185078
```

说明：截图测试只写入管道，没有落盘；`mean=0.0503`、`sd=0.1851` 说明不是纯黑/纯白画面，X11 读取真实桌面内容成功。`import` 会截取整个 root window；如果要窗口级，用 `xdotool` 找窗口 id 后再 `import -window <id>`。

### 6.3 可行截图方案

**方案 A：有头 Chrome + 窗口级截图（验收首选，真实渲染）**

```sh
mkdir -p "$HOME/a0-shots"
google-chrome --user-data-dir="$HOME/.cache/a0-shots-chrome" \
  --new-window --window-size=1440,960 --window-position=0,0 \
  http://127.0.0.1:5080/ &
sleep 4

# 优先按页面标题找窗口；找不到再按 Chrome 窗口类找
WID=$(xdotool search --onlyvisible --name 'Agent Zero' | head -1)
[ -n "$WID" ] || WID=$(xdotool search --onlyvisible --class 'google-chrome' | tail -1)
[ -n "$WID" ] || { echo 'window not found'; exit 1; }

import -window "$WID" "$HOME/a0-shots/ui-$(date +%H%M%S).png"
identify "$HOME/a0-shots/ui-"*.png | tail -1
```

如果窗口 id 找不到，退回整屏裁剪（仍比 headless 真实）：

```sh
import -window root -crop 1440x960+0+0 +repage \
  "$HOME/a0-shots/ui-root-crop-$(date +%H%M%S).png"
```

**方案 B：Chrome headless 截图（确定性高，但渲染不等价）**

```sh
mkdir -p "$HOME/a0-shots"
google-chrome --headless=new --disable-gpu --hide-scrollbars \
  --window-size=1440,960 \
  --screenshot="$HOME/a0-shots/ui-headless.png" \
  http://127.0.0.1:5080/
identify "$HOME/a0-shots/ui-headless.png"
```

当前没有 `A0_AUTH_KEY`，所以 URL 不需要 key。如果以后启用鉴权，headless 不能简单用 URL 传 header；需要先拿 cookie 或临时使用带 session 的 profile，不能把“401 页面”当 UI 截图。

**方案 C：Xpra 桌面截图**

先让 Agent Zero 打开 desktop（UI 里的 Desktop 入口，或 `/desktop` 路由），等 Xpra HTML5 页面加载后，用方案 A 的窗口截图；也可以用 `import -window root` 截整个屏幕。不要直接截 14500 的 TCP 协议端口，那不是给人看的 HTML。

### 6.4 headless 与真实浏览器渲染的差异（会漏掉什么）

- **GPU/合成**：headless 常用 SwiftShader/软件渲染，`--disable-gpu` 下没有真实 GPU 合成；WebGL、canvas 加速、视频解码、CSS 3D/滤镜可能不同，甚至直接失败。
- **窗口系统**：headless 没有 X11/XFCE 窗口管理器，没有标题栏、边框、阴影、任务栏、多窗口层叠、焦点/激活态；这些在验收里可能正是问题所在。
- **DPI/缩放**：headless 的 `--window-size` 是逻辑尺寸，和设备像素比、Xft DPI、字体 hinting 不完全一致；真实 3840×2160 屏幕上的缩放/模糊/截断会漏掉。
- **字体**：虽然系统字体相同，但 headless 的 fontconfig 环境和 Chrome 的字体回退可能不同；中文缺字、字体替换、行高问题可能漏掉。
- **可见性/焦点 API**：`document.visibilityState`、`requestAnimationFrame` 节流、自动聚焦、剪贴板、拖放、文件选择器、下载提示、权限弹窗在 headless 下行为不同或不存在。
- **Xpra/桌面**：headless 无法验证 Xpra HTML5 canvas 的实际交互、键鼠映射、剪贴板、音频和窗口缩放；这些必须用有头会话。
- **认证/Cookie**：headless 用独立 profile，可能没有真实会话；带鉴权的页面容易被截成 401/登录页。
- **结论**：headless 适合快速检查 DOM/静态布局/回归对比；**验收证据应以方案 A 的有头窗口截图为主**，headless 只作补充。

---

## 7. 中文字体与 locale

### 命令与原始输出

```console
$ fc-list :lang=zh | wc -l
562
```

```console
$ fc-list :lang=zh | head -20
/usr/share/fonts/noto-cjk/NotoSansCJK-Light.ttc: Noto Sans CJK JP,Noto Sans CJK JP Light:style=Light,Regular
/usr/share/fonts/sarasa-gothic/Sarasa-ExtraLightItalic.ttc: Sarasa Fixed K,Sarasa Fixed K XLight:style=ExtraLight Italic,Italic
/usr/share/fonts/sarasa-gothic/Sarasa-ExtraLightItalic.ttc: Sarasa Fixed Slab TC,Sarasa Fixed Slab TC XLight:style=ExtraLight Italic,Italic
/usr/share/fonts/sarasa-gothic/Sarasa-Bold.ttc: Sarasa Term Slab HC:style=Bold
/usr/share/fonts/sarasa-gothic/Sarasa-SemiBoldItalic.ttc: Sarasa Term Slab TC,Sarasa Term Slab TC SemiBold:style=SemiBold Italic,Italic
/usr/share/fonts/sarasa-gothic/Sarasa-SemiBold.ttc: Sarasa Mono J,更紗等幅ゴシック J,Sarasa Mono J SemiBold,更紗等幅ゴシック J SemiBold:style=SemiBold,Regular
/usr/share/fonts/sarasa-gothic/Sarasa-ExtraLightItalic.ttc: Sarasa Gothic SC,更纱黑体 SC,Sarasa Gothic SC XLight,更纱黑体 SC XLight:style=ExtraLight Italic,Italic
/usr/share/fonts/sarasa-gothic/Sarasa-Italic.ttc: Sarasa Term HC:style=Italic
/usr/share/fonts/sarasa-gothic/Sarasa-Bold.ttc: Sarasa Term Slab SC:style=Bold
/usr/share/fonts/sarasa-gothic/Sarasa-SemiBold.ttc: Sarasa Fixed SC,Sarasa Fixed SC SemiBold:style=SemiBold,Regular
...
```

```console
$ locale
LANG=C.UTF-8
LC_CTYPE="C.UTF-8"
LC_NUMERIC="C.UTF-8"
LC_TIME="C.UTF-8"
LC_COLLATE="C.UTF-8"
LC_MONETARY="C.UTF-8"
LC_MESSAGES="C.UTF-8"
LC_PAPER="C.UTF-8"
LC_NAME="C.UTF-8"
LC_ADDRESS="C.UTF-8"
LC_TELEPHONE="C.UTF-8"
LC_MEASUREMENT="C.UTF-8"
LC_IDENTIFICATION="C.UTF-8"
LC_ALL=C.UTF-8
```

```console
$ locale -a | grep -i zh
lzh_TW
zh_CN
zh_CN.gb18030
zh_CN.gbk
zh_CN.utf8
zh_HK
zh_HK.utf8
zh_SG
zh_SG.gbk
zh_SG.utf8
zh_TW
zh_TW.euctw
zh_TW.utf8
```

### 判断

- 中文字体充足：562 条，包含 Noto Sans/Serif CJK 与 Sarasa Gothic 的 SC/TC/HK/JP/K 及等宽变体。中文界面和中文文档渲染没有字体缺口。
- 当前 locale 是 `C.UTF-8`，不是 `zh_CN.UTF-8`。这不会影响字体显示，但应用/浏览器可能按英文环境启动，语言选择、日期格式、排序可能与中文验收预期不同。
- 需要中文 UI 验收时，用环境变量显式指定：
  ```sh
  LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 google-chrome ...
  flatpak run --user --env=LANG=zh_CN.UTF-8 --env=LC_ALL=zh_CN.UTF-8 org.agentzero.AgentZero
  ```
  注意：`LC_ALL` 会覆盖其他 `LC_*`；如果只想改语言，用 `LANG` 即可。
- 不建议为了验收修改系统全局 locale；只在启动命令里传，避免影响其他会话。

---

## 8. 磁盘预算

### 命令与原始输出

```console
$ df -h /home
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  111G   78G   32G  71% /home
```

```console
$ df -i /home
Filesystem     Inodes IUsed IFree IUse% Mounted on
/dev/nvme0n1p2      0     0     0     - /home
```

说明：btrfs 不按 inode 计数，`0/0/0` 是正常表现，不是采集错误；本机不存在 inode 耗尽风险。

```console
$ du -sh ~/.local/share/flatpak ~/.cache/pip ~/.cache/uv 2>/dev/null
9.0G	/home/kunweiz/.local/share/flatpak
```

```console
$ du -sh ~/.cache/pip ~/.cache/uv
du: cannot access '/home/kunweiz/.cache/pip': No such file or directory
du: cannot access '/home/kunweiz/.cache/uv': No such file or directory
```

```console
$ df -h /tmp
Filesystem      Size  Used Avail Use% Mounted on
tmpfs            32G  834M   31G   3% /tmp
```

```console
$ ls -la /home/kunweiz/Desktop/a0lite/bundles/
total 58140
drwxr-xr-x 1 kunweiz kunweiz       36 Nov 17 23:23 .
drwxr-xr-x 1 kunweiz kunweiz      144 Nov 17 23:02 ..
-rw-r--r-- 1 kunweiz kunweiz 59533584 Nov 17 23:23 agent-zero.flatpak
```

### 预算判断

- `/home` 可用 **32 GB**（71% 已用）；`/tmp` 是 **32 GB tmpfs**，已用 835 MB，但它是内存盘，**不能放大文件**。
- 现有用户级 Flatpak 占 **9.0 GB**（含 Models 5.4 GB、Cuda 1.4 GB、主包 128 MB、SDK 1.7 GB 等）。
- 只装主包：bundle 59.5 MB，安装后新 deployment 约 128 MB；旧 commit 会保留一段时间，合计约 300 MB 以内，**完全够**。
- WPS：安装后约 190 MB；如果宿主没有 WPS Office，也不应装（见第 9 节 e）。
- CUDA：bundle/安装约 1.4 GB；本机无 NVIDIA，**不装**。装了不仅浪费 1.4 GB，还会让验收误以为 GPU 路径被覆盖。
- 截图：1440×960 PNG 通常 0.2–1 MB；整屏 3840×2160 PNG 约 0.8–3 MB。放 `~/a0-shots`，不要放 `/tmp`。
- 回滚 bundle：完整包 60,334,712 字节（约 58 MiB）；放 `~/a0-local-backup`。
- 结论：**主包 + 截图 + 回滚备份的磁盘预算 < 500 MB**，32 GB 余量充足；真正的约束是内存，不是磁盘。

---

## 9. 本机部署执行单

> 前提：等 `bundles/*.flatpak` 就位后再执行。当前构建未结束，**不要提前安装**。
> 本文只给命令与判据；本轮不执行安装、不停服务、不改源码。

### Gate 0：构建完成与回滚门禁（不通过不许进入第 c 步）

```sh
cd /home/kunweiz/Desktop/a0lite

# 1) 三个 bundle 必须都存在，且大小稳定
ls -l bundles/agent-zero.flatpak bundles/agent-zero-cuda.flatpak bundles/agent-zero-wps.flatpak

# 2) 构建进程必须已经退出
pgrep -af 'flatpak build-bundle|scripts/build.sh' || echo 'build finished'

# 3) 记录哈希；60 秒后再算一次，两次必须一致（放 $HOME，不占 /tmp）
sha256sum bundles/*.flatpak | tee "$HOME/a0-bundles.sha256"
sleep 60
sha256sum -c "$HOME/a0-bundles.sha256"

# 4) 确认没有应用实例
flatpak ps
ss -ltnp | grep -E ':(5080|11434|14500|58891)\b' || echo 'ports free'

# 5) 确认可用内存（至少 8 GiB available 再启动 Ollama 三模型；不足则分批）
free -h
```

**预期**：

- 三个文件都存在；主包约 59.5 MB，CUDA 约 1.4 GB，WPS 约 190 MB（以实际为准）。
- `pgrep` 输出 `build finished`。
- `sha256sum -c` 全部 `OK`。
- `flatpak ps` 为空，端口空。
- `free -h` 的 `available` ≥ 8 GiB；如果只有 6 GiB 左右，启动时只能 `OLLAMA_MAX_LOADED_MODELS=1`，并优先跑不加载大模型的用例。

**失败判据**：

- 任一 bundle 缺失、大小为 0、或 60 秒内哈希变化 → **停止**，等构建完成。
- `pgrep` 仍有 `flatpak build-bundle`/`build.sh` → **停止**，不要装半成品。
- `flatpak ps` 非空或端口被占 → 先按第 b 步停实例；不要强装。
- `available` < 8 GiB → 不要同时跑三模型；仍可装主包和做 UI 验收，但模型用例要分批。

> 当前快照：Gate 0 **未通过**。23:33 复核时 `bundles/` 有主包 59,533,584 字节、CUDA bundle 860,154,032 字节；WPS bundle 正在生成（`flatpak build-bundle ... agent-zero-wps.flatpak ...` 进程仍在跑）。构建未结束前不能安装。

---

### 第 a 步：记录当前 commit 与 override 备份

```sh
set -eu
STAMP=$(date +%Y%m%d-%H%M%S)
B="$HOME/a0-local-backup/$STAMP"
mkdir -p "$B/appdata"

# 1) 记录当前部署状态
flatpak --user info org.agentzero.AgentZero | tee "$B/flatpak-info-before.txt"
flatpak --user list --all --columns=application,branch,origin,size \
  | tee "$B/flatpak-list-before.txt"
flatpak --user override --show org.agentzero.AgentZero \
  | tee "$B/override-before.txt" 2>&1 || true

# 2) 备份 override；当前不存在，缺失是预期，不要中断
if [ -f "$HOME/.local/share/flatpak/overrides/org.agentzero.AgentZero" ]; then
  cp -a "$HOME/.local/share/flatpak/overrides/org.agentzero.AgentZero" "$B/"
else
  echo "no override file" > "$B/override-absent.txt"
fi

# 3) 备份小体积用户配置（不复制 848M venv，也不复制 984M 数据目录）
cp -a "$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/conf" "$B/appdata/conf"
cp -a "$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/.env" "$B/appdata/env.agent-zero"

# 4) 关键：从本地安装仓库生成旧 commit 的“完整” rollback bundle
#    不要加 --from-commit：那会生成约 9.6 KB 的增量包，不能独立回滚
flatpak build-bundle \
  "$HOME/.local/share/flatpak/repo" \
  "$B/agent-zero-44c0ae83-full.flatpak" \
  org.agentzero.AgentZero master

# 5) 校验备份与哈希
ls -lh "$B" "$B/appdata"
find "$B" -type f ! -name SHA256SUMS -print0 | sort -z \
  | xargs -0 sha256sum > "$B/SHA256SUMS"
sha256sum -c "$B/SHA256SUMS"
echo "BACKUP=$B"
```

**预期**：

- `flatpak-info-before.txt` 里有 `Commit: 44c0ae83…bf96b`、`Date: 2026-11-01 11:30:12 +0000`。
- `override-before.txt` 为空；`override-absent.txt` 内容 `no override file`。
- `appdata/conf` 有 5 个文件（`AGENTS.md`、`model_providers.yaml`、三个 `.gitignore`）；`appdata/env.agent-zero` 存在。
- `agent-zero-44c0ae83-full.flatpak` 生成成功，**60,334,712 字节（约 58 MiB）**；本次 sha256 为 `7879a4b08ba035ccf48ce0671edbc412762334af2363caf4b366c34c4443f0ba`。
- `SHA256SUMS` 打印所有备份文件的哈希。

**失败判据**：

- `flatpak build-bundle` 返回非 0，或没有生成旧 bundle → **停止，不要执行第 c 步**。没有旧 bundle，就没有可靠回滚路径。
- 生成物只有约 9.6 KB（`9,780` 字节）→ 这是 `--from-commit` 的**增量包**，不是完整包；去掉 `--from-commit` 重新生成，直到大小约 60 MB。
- `flatpak-info` 读不到 commit → 停止，先查明安装状态。
- `cp` 报 `conf` 或 `.env` 不存在 → 记录并继续（用户可能已改过数据布局），但要先确认不是路径变更。
- `cp` 报 override 不存在 → **正常**，不是失败；当前 override 目录本来就是空的。

**说明**：`flatpak build-bundle`（不带 `--from-commit`）读取的是 `~/.local/share/flatpak/repo` 里仍然可达的旧 commit；`ostree refs` 已确认 `agentzero-origin:app/…` 和 `deploy/app/…` 都指向 `44c0ae83…`。这是当前唯一可靠的回滚材料来源，因为 `agentzero-origin` 的远端 URL 已失效。

`--from-commit` 的语义是“从指定 commit 生成 **delta bundle**”，不是“指定要导出的 commit”。本轮实测：加 `--from-commit` 只生成 9,780 字节的增量包（已改名为 `delta-not-for-rollback.flatpak`），不能单独用于回滚；去掉该参数后生成 60,334,712 字节的完整包。执行时必须以“约 60 MB + `sha256sum -c` 全部 OK”为准。

---

### 第 b 步：停实例（若在跑）

```sh
# 先看有没有实例
flatpak ps
pgrep -af 'org[.]agentzero' || true

# 只有确实在跑才停；当前是空操作
if flatpak ps | grep -q 'org.agentzero.AgentZero'; then
  flatpak kill org.agentzero.AgentZero
fi

# 等待退出（最多 30 秒）
for i in $(seq 1 30); do
  flatpak ps | grep -q 'org.agentzero.AgentZero' || break
  sleep 1
done

# 确认端口已释放
ss -ltnp | grep -E ':(5080|11434|14500|58891)\b' || echo 'ports free'
```

**预期**：

- `flatpak ps` 空；`pgrep` 无应用命中（只会看到构建进程，若构建还没结束，Gate 0 本来就不通过）。
- `ports free`。
- 当前采集时刻已经是这个状态，所以本步跳过。

**失败判据**：

- `flatpak ps` 仍有 `org.agentzero.AgentZero`，或 5080/11434 仍被占 → 不要继续安装；先查 `flatpak ps`、`ss -ltnp`、日志。
- **不要**把 `scripts/build.sh` 或 `flatpak build-bundle` 当成实例杀掉；它们不是服务。
- 如果以后装了 `systemd/agent-zero.service`（`Restart=always`），停止顺序是先 `agent-zero-desktop` 再 `agent-zero`：
  ```sh
  sudo systemctl stop agent-zero-desktop agent-zero
  ```
  本机当前没有这些单元，且本轮不做。

**会打断谁**：见第 3 节。当前没有实例，所以不会打断任何人；部署时若有人打开 5080 页面、跑 agent 任务或看 Xpra 桌面，会中断他们的会话。

---

### 第 c 步：安装主包

```sh
cd /home/kunweiz/Desktop/a0lite
flatpak install --user -y --noninteractive --reinstall \
  bundles/agent-zero.flatpak

# 验证 commit、日期、运行时
flatpak --user info org.agentzero.AgentZero | grep -E 'Commit|Date|Installed Size|Runtime'

# 验证新权限（应与新 manifest 一致）
flatpak --user info --show-permissions org.agentzero.AgentZero
```

**预期**：

- `flatpak install` 退出码 0；输出包含 `Installing app/org.agentzero.AgentZero/x86_64/master`，最后显示安装完成。
- `flatpak info` 的 `Commit` **不再是** `44c0ae83…`，`Date` 是本次构建时间（2026-11-17 之后）。
- 权限包含：
  ```
  filesystems=host;host-etc:ro;host-os:ro;/run/udev:ro;
  ```
  以及 `OLLAMA_HOST=http://127.0.0.1:11434`。
- 旧 commit 目录仍可能在 `~/.local/share/flatpak/app/.../master/` 下并存，`active` 指向新 commit。

**失败判据**：

- 退出码非 0；输出含 `error:`（缺 bundle、缺 runtime、磁盘满、权限错误）。
- `Commit` 仍是 `44c0ae83…`，或 `Date` 没变 → 说明没有真正替换。
- `--show-permissions` 仍是旧的 `filesystems=home;/run/udev:ro;` → manifest 没生效，检查 bundle 是否为新包。
- 安装后 `flatpak info` 直接报应用不存在 → 说明 `--reinstall` 先卸载后安装失败；**立即执行第 h 步旧 bundle 回滚**，不要重试同一个包。
- 这一条是整套执行单**最容易失败的一步**：`--reinstall` 的语义是先卸载再安装，且本机 `agentzero-origin` 已失效；没有第 a 步的旧 bundle，失败后很难回到旧状态。

---

### 第 d 步：Cuda 扩展（本机判定：不装）

```sh
# 本机不要执行这一条：
# flatpak install --user -y --noninteractive --reinstall bundles/agent-zero-cuda.flatpak
```

**本机为什么不装**：

- 本机没有 NVIDIA GPU：`nvidia-smi` 不存在、`/dev/nvidia*` 不存在、`lsmod` 无 nvidia；只有 AMD Radeon 780M 集显。
- Cuda 扩展只包含 Ollama 的 `cuda_v12` 内核，是 NVIDIA CUDA 专用；AMD 集显不能用。
- 启动脚本默认 `CUDA_VISIBLE_DEVICES=-1`（CPU）；装 Cuda 也不会自动启用 GPU。
- 安装会多占约 1.4 GB，并让“Cuda 已安装”被误读成“GPU 已验证”。

**如果以后在 NVIDIA 机器上验收**：

```sh
flatpak install --user -y --noninteractive --reinstall bundles/agent-zero-cuda.flatpak

# 仅证明环境变量传入，不等于 GPU 真的可用
flatpak run --user --command=sh --env=CUDA_VISIBLE_DEVICES=0 \
  org.agentzero.AgentZero -c \
  'echo CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES; ls -l /app/share/agent-zero/cuda/cuda_v12 | head'
```

**预期（NVIDIA 机器）**：

- 安装的是 runtime `org.agentzero.AgentZero.Cuda/x86_64/12`，退出码 0。
- 沙盒内 `CUDA_VISIBLE_DEVICES=0`，`/app/share/agent-zero/cuda/cuda_v12` 存在。
- 还需要 `nvidia-smi` 可用、`/dev/nvidia*` 可见、Ollama 日志出现 CUDA 设备；三者缺一，不能判 “CUDA 通过”。

**失败判据**：

- 安装报 “not an application” → 该 bundle 是 runtime，必要时加 `--runtime`（当前 `flatpak install` 一般能按元数据识别；这只是兜底）。
- 沙盒内没有 `cuda_v12` → 扩展没挂载。
- `nvidia-smi` 失败或没有 `/dev/nvidia*` → 驱动/设备不可用，不能继续做 GPU 验收。
- 主 manifest 只有 `--device=dri`，没有 `--device=all`；NVIDIA 设备节点是否进沙盒需要在真机验证，不能仅凭 `CUDA_VISIBLE_DEVICES=0` 认定成功。
- 本机结论：**Cuda 用例“环境不具备”，不是“通过”**。

---

### 第 e 步：Wps 扩展（本机判定：不装）

```sh
# 本机不要执行这一条：
# flatpak install --user -y --noninteractive --reinstall bundles/agent-zero-wps.flatpak
```

**本机为什么不装**：

- 宿主没有 WPS Office：`command -v wps et wpp` 全部缺失；`/opt/kingsoft/wps-office` 不存在；`~/.local/share/Kingsoft` 不存在。
- Wps bundle 只提供 MCP server（Bun + `wps-skills`），**不包含 WPS Office**；add-in 需要 `flatpak/install-wps-addon.sh` 写进宿主 WPS profile，而该脚本在检测不到 WPS 时会以 `error: WPS Office is not installed on this host` 退出 1。
- 没有 add-in 时，`127.0.0.1:58891` 不会监听；装了也只能证明“MCP server 能启动”，不能证明 WPS 文档操作可用。
- 结论：WPS 用例整体标记 **“环境不具备，不可验收”**，不要用安装成功冒充通过。

**如果以后补装 WPS Office**：

```sh
# 先确认宿主 WPS 可用
command -v wps et wpp
ls -d /opt/kingsoft/wps-office

# 安装扩展
flatpak install --user -y --noninteractive --reinstall bundles/agent-zero-wps.flatpak

# 安装 add-in（需要宿主 WPS）
flatpak/install-wps-addon.sh

# 验证 MCP server（stdio，会阻塞；用 timeout 观察启动）
timeout 5 flatpak run --user --command=wps-mcp org.agentzero.AgentZero.Wps
```

**预期**：

- 扩展安装为 app `org.agentzero.AgentZero.Wps/x86_64/1.0`，退出码 0。
- `install-wps-addon.sh` 成功复制 add-in 到 `~/.local/share/Kingsoft/wps/jsaddons/`。
- WPS 运行并加载 add-in 后，58891 才可能监听；`timeout 5` 返回 124（被 timeout 杀掉）说明 server 已启动并等待 stdio，不是失败。

**失败判据**：

- `install-wps-addon.sh` 报 WPS 未安装 → 停止，标记环境不具备。
- `flatpak run --command=wps-mcp` 立即报 `bun`/`dist/index.js` 不存在 → 扩展载荷不完整。
- 58891 始终不监听 → add-in 没加载或 WPS 没运行；不能判 MCP 通过。
- 注意 `flatpak/wps-mcp-config.json` 里的 `command` 指向 `/var/lib/flatpak/.../bin/node`，与实际 user 安装路径和 `bun` 不符；以后配置时要用 `~/.local/share/flatpak/.../files/bin/bun` 或 `.../files/bin/wps-mcp`，不要照抄。

---

### 第 f 步：启动并等待 `/api/health`

```sh
LOG="$HOME/a0-local-backup/run-$(date +%Y%m%d-%H%M%S).log"

# 内存紧张：只允许 1 个 Ollama 模型常驻，5 分钟无请求就释放
setsid flatpak run --user \
  --env=OLLAMA_MAX_LOADED_MODELS=1 \
  --env=OLLAMA_KEEP_ALIVE=5m \
  org.agentzero.AgentZero >"$LOG" 2>&1 < /dev/null &

echo "log=$LOG"

# 最多等 240 秒
for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
    http://127.0.0.1:5080/api/health || true)
  [ "$code" = 200 ] && break
  sleep 2
done

curl -sS -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/health
flatpak ps
ss -ltnp | grep -E ':(5080|11434|14500|58891)\b' || true
```

**预期**：

- `curl` 输出 `{"status":"ok"}`，`HTTP=200`。
- `flatpak ps` 显示 `org.agentzero.AgentZero` 的 PID。
- `ss` 显示 `127.0.0.1:5080` 和 `127.0.0.1:11434`；14500 只有在打开 Desktop 后才出现；58891 只有 WPS add-in 才出现。
- 日志文件在 `~/a0-local-backup/run-*.log`；Ollama 日志在 `~/.var/app/org.agentzero.AgentZero/data/agent-zero/logs/ollama.log`。

**失败判据**：

- 240 秒后仍 `000`/超时 → `tail -80 "$LOG"` 看启动错误；常见是 5080 被占、Python 依赖缺失、venv 损坏、模型后端启动失败。
- `11434` 被别的进程占用 → 日志出现 `ollama exited during startup; another process may already own 127.0.0.1:11434`；先查 `ss -ltnp`，不要盲目杀。
- 进程被 OOM kill → `dmesg`/`journalctl` 有 oom 记录；降低模型常驻数、关闭其他大内存进程，或分批验收。
- `health` 返回 401 → 说明有人加了 `A0_AUTH_KEY` override；这不是启动失败，但后续 curl 需要带 `Authorization: Bearer`。当前 override 为空，预期是 200。
- `flatpak ps` 没有实例但 5080 有响应 → 可能是别的进程占了端口；查 `ss -ltnp`，不要继续。

**启动后的第一轮检查**：

```sh
# UI 根路径（当前无 A0_AUTH_KEY，应为 200；有 key 则为 401）
curl -sS -o /dev/null -w 'root=%{http_code}\n' --max-time 5 http://127.0.0.1:5080/

# Ollama 模型清单
curl -sS --max-time 10 http://127.0.0.1:11434/api/tags | head -c 800

# 应用日志尾部
tail -40 "$LOG"

# kw92 仍然可用
curl -sS -m 20 -w '\nHTTP=%{http_code}\n' \
  -H 'Content-Type: application/json' \
  -d '{"model":"mistral/deepseek-v4-1-flash-1017","messages":[{"role":"user","content":"只回答两个字：收到"}],"max_tokens":16}' \
  http://127.0.0.1:18080/v1/chat/completions
```

**提醒**：现有 `conf/model_providers.yaml` **没有 kw92 条目**。如果验收要测 Agent Zero 的聊天，需要在 UI 的 Models 设置里添加 provider（`litellm_provider: openai`、`api_base: http://127.0.0.1:18080/v1`、模型名 `mistral/deepseek-v4-1-flash-1017`），或按既有探针文档修改配置。这个动作会写用户配置，属于验收阶段的操作，不在本轮执行。

---

### 第 g 步：保留 `~/.var/app`，说明重装不会删它

```sh
readlink -f "$HOME/.var/app/org.agentzero.AgentZero"
ls -ld "$HOME/.var/app/org.agentzero.AgentZero"
du -sh "$HOME/.var/app/org.agentzero.AgentZero/data"
flatpak --user info --show-location org.agentzero.AgentZero
```

**预期**：

- `readlink -f` 输出 `/home/kunweiz/.var/app/org.agentzero.AgentZero`；它是真实目录，不是指向应用安装目录的符号链接。
- `du -sh` 仍是约 984M（或用户后续增长后的值）。
- `flatpak --show-location` 指向 `~/.local/share/flatpak/app/org.agentzero.AgentZero/x86_64/master/<commit>`，与 `~/.var/app` 是两棵树。

**为什么重装不会删它**：

- Flatpak 的应用部署在 `~/.local/share/flatpak/app/<app-id>/...`；用户数据在 `~/.var/app/<app-id>`。`flatpak install --reinstall` 只替换前者，不会删除后者。
- 当前 `~/.var/app/org.agentzero.AgentZero` 是真实目录（不是符号链接），没有指进应用部署目录。
- 旧 commit 与新 commit 可以并存，用户数据不随 commit 改变。
- **但是**：“不删”不等于“新代码不会写坏”。第 a 步已备份 `conf` 和 `usr/.env`；如果新版本做数据迁移，仍可能出现配置变化。验收前不要执行 `flatpak uninstall --unused`，否则可能清掉旧 commit 和回滚材料。

**venv 注意点（重要）**：

- `data/agent-zero/venv` 848M，`.a0-ready` 标记存在。启动脚本只在 `.a0-ready` 不存在时重建 venv；`--reinstall` 不会刷新依赖。
- 当前仓库的 `requirements-flatpak.txt` 与旧安装的哈希不同：
  - repo：`f4be8bd7eb268eac7719be1f6075f7fee3fd7252b88ddeb71e1840e5ef5aed31`
  - 旧安装：`cd7ad3e2883376d3593163e449c35a010ac0d102fd5045fad1a0801933e546fa`
- 差异内容主要是**删包/改注释**（移除 `stealth-browser`、`nodriver`，注释改为 numpy shim / unstructured 说明），没有看到新增必需依赖；旧 venv 是超集，默认可以先保留。
- 如果启动日志出现 `ModuleNotFoundError` 或版本冲突，再走“重命名 venv（不是删除）+ 重启”的路径：
  ```sh
  mv "$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/venv" \
     "$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/venv.bak-$(date +%Y%m%d-%H%M%S)"
  # 重启应用，launcher 会重新 uv venv + 安装依赖；需要网络和额外约 848M 磁盘
  ```
  这一步会改动用户数据目录，属于部署决策；本轮不执行，验收前需明确同意。

---

### 第 h 步：回滚

**首选：重新安装第 a 步预生成的旧 bundle**

```sh
B=$(ls -dt "$HOME"/a0-local-backup/* | head -1)
ls -lh "$B/agent-zero-44c0ae83-full.flatpak"

flatpak install --user -y --noninteractive --reinstall \
  "$B/agent-zero-44c0ae83-full.flatpak"

flatpak --user info org.agentzero.AgentZero | grep -E 'Commit|Date'
```

**预期**：

- 安装退出码 0。
- `Commit` 回到 `44c0ae8315893f0ee43b867d3cc1d31219c29e24a7a9b8e0666501d9563bf96b`。
- `Date` 回到 `2026-11-01 11:30:12 +0000`。
- 重新启动后 `/api/health` 仍为 `{"status":"ok"}`。

**次选：从本地仓库按 commit 回退（不保证可用）**

```sh
flatpak update --user -y --noninteractive --no-pull \
  --commit=44c0ae8315893f0ee43b867d3cc1d31219c29e24a7a9b8e0666501d9563bf96b \
  org.agentzero.AgentZero
```

**为什么不能把它当主路径**：

- `agentzero-origin` 的远端目录 `/home/kunweiz/a0build/fbbuild/state/cache` 已不存在；`flatpak remote-info` 明确报 “server has no summary file”。
- `flatpak update --commit` 通常需要从 app 的 origin 远端取 commit；`--no-pull` 只保证不联网，但 origin 元数据仍可能让命令失败。
- 如果它失败，报错通常是 `Commit ... not found` / `No such ref` / `Unable to load summary`；这**不代表旧 bundle 回滚失败**，直接走首选路径。

**回滚后的检查**：

```sh
flatpak --user info org.agentzero.AgentZero | grep -E 'Commit|Date'
flatpak --user info --show-permissions org.agentzero.AgentZero
curl -sS -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/health
flatpak ps
```

**失败判据**：

- 旧 bundle 安装报错 → 检查文件是否完整（`sha256sum -c "$B/SHA256SUMS"`）、磁盘是否满、runtime 25.08 是否还在。
- commit 没有回到旧值 → 不要反复重试；先看 `flatpak info` 与安装输出。
- 回滚后 health 仍失败 → 检查 5080 是否被占、旧 venv/数据是否被新版本改坏；必要时用第 a 步的 `appdata` 恢复 `conf` 和 `.env`（只恢复配置，不动 venv）。
- 回滚窗口关闭前不要执行 `flatpak uninstall --unused`。

---

### 第 9 节附：安装后验收清单（建议顺序）

| 顺序 | 检查 | 命令 | 通过标准 |
|---|---|---|---|
| 1 | 新 commit | `flatpak --user info org.agentzero.AgentZero \| grep -E 'Commit\|Date'` | commit 非 `44c0ae83…`，Date 为本次构建 |
| 2 | 新权限 | `flatpak --user info --show-permissions org.agentzero.AgentZero` | `filesystems=host;host-etc:ro;host-os:ro;/run/udev:ro;` |
| 3 | 实例 | `flatpak ps` | 有 `org.agentzero.AgentZero` |
| 4 | health | `curl -sS -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/health` | `{"status":"ok"}`，HTTP 200 |
| 5 | UI 根路径 | `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5080/` | 200（当前无 key；有 key 则 401 属预期） |
| 6 | 端口 | `ss -ltnp \| grep -E ':(5080\|11434\|14500\|58891)\b'` | 5080、11434 在听；14500/58891 按需 |
| 7 | Ollama 模型 | `curl -sS http://127.0.0.1:11434/api/tags` | 三个模型可见（若 Models 已装） |
| 8 | kw92 | 第 5 节的 curl | HTTP 200，中文回答非空 |
| 9 | 截图 | 第 6 节方案 A | 生成非空 PNG，肉眼可见 UI |
| 10 | 数据 | `du -sh ~/.var/app/org.agentzero.AgentZero/data` | 仍存在，大小合理 |
| 11 | 日志 | `tail -40 "$LOG"`、`ollama.log` | 无 traceback、无 OOM、无端口冲突 |

**明确不做的验收项（本机）**：

- CUDA / `CUDA_VISIBLE_DEVICES=0` 的真实 GPU 推理：无 NVIDIA，环境不具备。
- WPS 文档操作 / 58891：无 WPS Office，环境不具备。
- systemd 开机自启 / `Restart=always`：本机没有安装 unit；仓库里有 unit，但需要 sudo 安装，本轮不做。
- 三模型同时常驻：内存不足，默认只允许 1 个。

---

## 10. 本机验收的优势与限制

### 优势

1. **真实图形会话**：X11 + XFCE + lightdm，3840×2160，`DISPLAY=:0.0`，不是无头 Xvfb。可以肉眼检查 Web UI、Chrome 渲染、窗口装饰、滚动、中文断行，也可以截取真实窗口。
2. **截图链路已实测**：`import -window root png:-` 输出 786,396 字节、mean 0.0503、sd 0.1851，说明能读到真实桌面；`xdotool` 可用于窗口定位；Chrome 156 可用。
3. **CPU 足够**：16 核 Zen 4（7940H）+ AVX-512，CPU 推理可行；Ollama 的 CPU 内核与 Models 扩展已存在。
4. **聊天后端可用**：kw92 `127.0.0.1:18080` 实测 HTTP 200、中文回答正常，聊天验收不必依赖本地大模型，能把“聊天”和“本地推理”解耦。
5. **真实 Flatpak 用户安装**：已有旧 commit 44c0ae83、runtime 25.08、Models/Cuda/Wps 扩展；可以直接验证 `--reinstall` 的替换语义、数据保留和权限变化。
6. **中文字体齐全**：562 条中文字体，Noto CJK + Sarasa；中文 UI 不会因缺字误判。
7. **磁盘够主包验收**：32 GB 可用；主包 + 截图 + 回滚 bundle < 500 MB，不需要把大文件放 `/tmp`。

### 限制

1. **没有 NVIDIA CUDA**：只有 AMD Radeon 780M 集显；`nvidia-smi` 缺失、`/dev/nvidia*` 缺失、无 nvidia 模块。Cuda 扩展无法验证，**不能把“安装成功”当作 CUDA 通过**。本机 Ollama 只能 CPU。
2. **内存紧张**：62 GiB 总量，但 `available` 只有 6.2–6.5 GiB，swap 已用 4.9 GiB；`omp` 主进程 RSS 约 52 GB。三模型权重 5.24 GB，默认 `OLLAMA_MAX_LOADED_MODELS=2` 容易换页/OOM。验收时应 `OLLAMA_MAX_LOADED_MODELS=1`、`OLLAMA_KEEP_ALIVE=5m`，并避免同时跑 OCR + 语音 + 嵌入重负载。
3. **`/tmp` 是 32 GB tmpfs**：已用 835 MB，但它是内存盘，**绝不能把 bundle/模型/截图批量放进去**；安装直接从 `/home/kunweiz/Desktop/a0lite/bundles/` 读取，截图放 `~/a0-shots`。
4. **WPS Office 缺失**：`wps/et/wpp`、`/opt/kingsoft/wps-office`、`~/.local/share/Kingsoft` 全部不存在；Wps 扩展只是 MCP server，没有 add-in，58891 不会监听。WPS 用例应标记“环境不具备”。
5. **没有 systemd 单元**：本机 `/etc/systemd/system` 无 agent-zero 单元，user 级也没有；只能手工 `flatpak run`。开机自启、`Restart=always`、`RequiresMountsFor=/home/kunweiz` 等行为无法在本机验证。
6. **回滚远端已失效**：`agentzero-origin` 指向的 `/home/kunweiz/a0build/fbbuild/state/cache` 不存在，`flatpak update --commit=44c0ae83…` 不可靠；必须预生成旧 bundle。若第 a 步的 `flatpak build-bundle` 失败，**不要安装新包**。
7. **`--reinstall` 是先卸载再安装**：主包是唯一已知可回滚 commit 的载体；bundle 不完整或安装中断，可能暂时没有应用。必须等 Gate 0 三包齐全、哈希稳定，且旧 bundle 已生成。
8. **旧 venv 不会自动刷新**：`venv/.a0-ready` 存在，`--reinstall` 不删它；当前 `requirements-flatpak.txt` 与旧安装哈希不同，但差异主要是删包/注释，旧 venv 是超集，默认可保留。若启动报缺依赖，需要重命名 venv 重建（会改动 `~/.var/app`，需要明确同意）。
9. **权限变宽**：新 manifest 用 `--filesystem=host`、`host-etc:ro`、`host-os:ro`，应用能读写整个宿主；这是 Agent Zero “在机器上工作”的设计，但验收时要意识到安全边界变化。
10. **headless 截图不等价**：headless 没有 GPU 合成、窗口管理器、真实 DPI、焦点/剪贴板/下载弹窗；只能做 DOM/静态布局补充，验收证据应以有头窗口截图为主。
11. **构建仍在进行**：本报告采集时 CUDA bundle 正在写、WPS bundle 未出现；任何“安装”动作都必须等构建结束。报告中的大小、commit、端口状态都是快照，执行前要重新核对。
12. **没有 `wmctrl`/`scrot`**：窗口管理/截图脚本要基于 `xdotool` + `import`；不要照抄依赖 `wmctrl`/`scrot` 的验收脚本。

---

## 附：本轮未做与未改

- 未执行 `flatpak install/uninstall/update/repair`。
- 未停止任何服务或进程；未杀构建。
- 未删除/移动任何用户数据；未改 `~/.var/app`。
- 未修改 override；`override --show` 保持空。
- 未修改仓库源码；只新增本文档与 `~/a0-local-backup/20261117-233001/` 下的备份材料。
- 未把大文件写入 `/tmp`；截图测试使用管道，未落盘。
- 未在本轮启动 Agent Zero、Ollama、Chrome 或 Xpra。

---

## 11. 回滚材料已就绪（2026-11-17 23:30 CST）

### 11.1 路径与校验值

```console
$ B=/home/kunweiz/a0-local-backup/20261117-233001
$ ls -lh "$B"
total 58M
-rw-r--r-- 1 kunweiz kunweiz  58M Nov 17 23:31 agent-zero-44c0ae83-full.flatpak
drwxr-xr-x 1 kunweiz kunweiz   36 Nov 17 23:30 appdata
-rw-r--r-- 1 kunweiz kunweiz 9.6K Nov 17 23:30 delta-not-for-rollback.flatpak
-rw-r--r-- 1 kunweiz kunweiz  704 Nov 17 23:30 flatpak-info-before.txt
-rw-r--r-- 1 kunweiz kunweiz 1.1K Nov 17 23:30 flatpak-list-before.txt
-rw-r--r-- 1 kunweiz kunweiz  145 Nov 17 23:31 rollback-full.sha256
```

| 项 | 值 |
|---|---|
| 完整回滚 bundle | `~/a0-local-backup/20261117-233001/agent-zero-44c0ae83-full.flatpak` |
| 大小 | **60,334,712 字节**（约 58 MiB） |
| sha256 | **`7879a4b08ba035ccf48ce0671edbc412762334af2363caf4b366c34c4443f0ba`** |
| 来源命令 | `flatpak build-bundle "$HOME/.local/share/flatpak/repo" "$B/agent-zero-44c0ae83-full.flatpak" org.agentzero.AgentZero master` |
| 旧 commit | `44c0ae8315893f0ee43b867d3cc1d31219c29e24a7a9b8e0666501d9563bf96b` |
| 旧 Date | `2026-11-01 11:30:12 +0000` |

`sha256sum -c` 结果（全部文件）：

```console
$ sha256sum -c "$B/SHA256SUMS"
.../agent-zero-44c0ae83-full.flatpak: OK
.../appdata/conf/AGENTS.md: OK
.../appdata/conf/model_providers.yaml: OK
.../appdata/conf/projects.default.gitignore: OK
.../appdata/conf/skill.default.gitignore: OK
.../appdata/conf/workdir.gitignore: OK
.../appdata/env.agent-zero: OK
.../delta-not-for-rollback.flatpak: OK
.../flatpak-info-before.txt: OK
.../flatpak-list-before.txt: OK
.../rollback-full.sha256: OK
.../rollback.sha256: OK
```

### 11.2 同时备份的元数据与配置

- `flatpak-info-before.txt`：704 字节，含 `ID: org.agentzero.AgentZero`、`Commit: 44c0ae83…`、`Date: 2026-11-01 11:30:12 +0000`、`Installed Size: 128.1 MB`。
- `flatpak-list-before.txt`：1,037 字节，`flatpak --user list --all` 的完整列表。
- `appdata/conf/`：5 个文件（`AGENTS.md`、`model_providers.yaml`、`projects.default.gitignore`、`skill.default.gitignore`、`workdir.gitignore`）。
- `appdata/env.agent-zero`：94 字节；只备份了 `.env`，**没有复制 848M 的 venv，也没有复制 984M 的数据目录**。
- `SHA256SUMS`：上述所有文件的逐文件哈希；`sha256sum -c` 全部 `OK`。

### 11.3 两个必须说清楚的细节

1. **完整包和增量包不要混用**。`--from-commit` 生成的是 delta bundle，本轮产物只有 9,780 字节（已改名为 `delta-not-for-rollback.flatpak`），不能单独用于回滚。可用的回滚材料是 **不带 `--from-commit`** 生成的 `agent-zero-44c0ae83-full.flatpak`（60,334,712 字节）。
2. **没有安装、没有导入**。`flatpak info --user --runtime-repo= "$B/agent-zero-44c0ae83-full.flatpak"` 返回 `error: Unknown option --runtime-repo=`；去掉该选项后 `flatpak info --user <bundle>` 返回 `error: Invalid id : Name can't be empty`（rc=1），说明该版本的 `flatpak info` 不直接解析 bundle 文件。按约定跳过，未执行 `flatpak install`，也未用 `flatpak build-import-bundle` 导入任何仓库。回滚包的可解析性由 `flatpak build-bundle` 退出码 0、文件大小 60,334,712 字节和 `sha256sum` 记录共同保证；真正安装前仍建议先用第 h 步的 `flatpak install --reinstall` 做一次回滚演练（本轮不做）。

---

## 12. 新镜像静态断言结果（不安装）

### 12.1 对象与来源

| 项 | 值 |
|---|---|
| 新主包文件 | `bundles/agent-zero.flatpak` |
| 新主包大小 | 59,533,584 字节 |
| 新主包 sha256 | `6ca80d7d98df968aeb6c13d1e1c274c0a8098e1bd25fba5bd5cca462c0f564b8` |
| `build/cache` 主 ref | `app/org.agentzero.AgentZero/x86_64/master` |
| 源 commit | `169f5e09e525a00ea4c901eedcdd4606dfb29d8b442e1e4af10d8ae2da0d471d` |
| 直接镜像目录 | `build/build-AgentZero/files/share/agent-zero/flatpak/` |
| OSTree 只读路径 | `build/cache` 的 `/files/share/agent-zero/flatpak/` |

说明：`flatpak info` 不直接解析 bundle 文件（见 11.3），因此下面的断言使用**构建脚本实际导出的镜像树** `build/build-AgentZero/files/`，并用 `build/cache` 中同一 commit 的 OSTree 对象做交叉核对。bundle 由 `scripts/build.sh` 在 23:23:54 从该 cache 导出；源 ref 当前指向 `169f5e09…`。

### 12.2 四条断言

| # | 断言 | 结果 | 证据 |
|---|---|---|---|
| 1 | 新镜像存在 `files/share/agent-zero/flatpak/a0flatpak/serve.py` | **通过** | 直接文件 `serve.py PRESENT`；OSTree `-00644 0 0 1626 .../serve.py` |
| 2 | 新镜像**不存在** `files/share/agent-zero/flatpak/a0flatpak/health.py` | **通过** | 直接测试 `health.py ABSENT`；OSTree 报 `No such file or directory` |
| 3 | `requirements-flatpak.txt` 不含 `stealth-browser` | **通过** | 直接 `grep -c` = `0`；OSTree `ostree cat ... \| grep -c` = `0` |
| 4 | `agent-zero.sh` 含 `usr/.gitkeep`（而不是 `usr/.env`） | **通过** | 直接 `grep -c 'usr/\.gitkeep'` = `1`，`grep -c 'usr/\.env'` = `0`；OSTree 同样为 `1` / `0` |

原始输出（直接镜像树）：

```console
$ test -f build/build-AgentZero/files/share/agent-zero/flatpak/a0flatpak/serve.py && echo 'serve.py PRESENT'
serve.py PRESENT

$ test -e build/build-AgentZero/files/share/agent-zero/flatpak/a0flatpak/health.py && echo 'health.py PRESENT' || echo 'health.py ABSENT'
health.py ABSENT

$ grep -c 'stealth-browser' build/build-AgentZero/files/share/agent-zero/flatpak/requirements-flatpak.txt
0

$ grep -c 'usr/\.gitkeep' build/build-AgentZero/files/share/agent-zero/flatpak/agent-zero.sh
1
```

原始输出（OSTree cache，commit `169f5e09…`）：

```console
$ ostree --repo=build/cache ls 169f5e09e525a00ea4c901eedcdd4606dfb29d8b442e1e4af10d8ae2da0d471d \
    /files/share/agent-zero/flatpak/a0flatpak/serve.py
-00644 0 0   1626 /files/share/agent-zero/flatpak/a0flatpak/serve.py

$ ostree --repo=build/cache ls 169f5e09e525a00ea4c901eedcdd4606dfb29d8b442e1e4af10d8ae2da0d471d \
    /files/share/agent-zero/flatpak/a0flatpak/health.py
error: Inspecting path '/files/share/agent-zero/flatpak/a0flatpak/health.py':
No such file or directory: /files/share/agent-zero/flatpak/a0flatpak/health.py

$ ostree --repo=build/cache cat 169f5e09e525a00ea4c901eedcdd4606dfb29d8b442e1e4af10d8ae2da0d471d \
    /files/share/agent-zero/flatpak/requirements-flatpak.txt | grep -c 'stealth-browser'
0

$ ostree --repo=build/cache cat 169f5e09e525a00ea4c901eedcdd4606dfb29d8b442e1e4af10d8ae2da0d471d \
    /files/share/agent-zero/flatpak/agent-zero.sh | grep -c 'usr/\.gitkeep'
1
```

补充：`build/cache` 的树根是 `/files`、`/export`、`/metadata`；第一次按 `/share/...` 访问会报 `No such file or directory: /share`，改用 `/files/share/...` 后得到上述结果。这是路径前缀问题，不是断言失败。

### 12.3 新 manifest 声明权限 vs 当前安装实际权限

当前安装（`flatpak --user info --show-permissions org.agentzero.AgentZero`）：

```console
[Context]
shared=ipc;network;
sockets=pulseaudio;x11;
devices=dri;
filesystems=home;/run/udev:ro;

[Environment]
OLLAMA_HOST=http://127.0.0.1:11434
```

新 manifest 的 `finish-args`（`flatpak/org.agentzero.AgentZero.yml:7-22`）：

```yaml
finish-args:
  - --share=ipc
  - --share=network
  - --socket=x11
  - --socket=pulseaudio
  - --device=dri
  - --filesystem=host
  - --filesystem=host-etc:ro
  - --filesystem=host-os:ro
  - --filesystem=/run/udev:ro
  - --env=OLLAMA_HOST=http://127.0.0.1:11434
```

| 维度 | 当前安装（旧 commit 44c0ae83） | 新 manifest 声明 | 变化 |
|---|---|---|---|
| 共享 | `shared=ipc;network;` | `--share=ipc`、`--share=network` | 不变 |
| X11 / 音频 | `sockets=pulseaudio;x11;` | `--socket=x11`、`--socket=pulseaudio` | 不变 |
| 设备 | `devices=dri;` | `--device=dri` | 不变；**没有 `--device=all`** |
| 文件系统 | `filesystems=home;/run/udev:ro;` | `filesystems=host;host-etc:ro;host-os:ro;/run/udev:ro;`（预期合并结果） | **新增 `host`、`host-etc:ro`、`host-os:ro`**；`home` 被更宽的 `host` 覆盖 |
| 环境 | `OLLAMA_HOST=http://127.0.0.1:11434` | 同 | 不变 |
| Wayland | 无 | 无 | 不变 |

注意：右侧是**新 manifest 声明**，不是当前实际权限；当前没有安装新 commit，所以 `--show-permissions` 仍显示旧的 `filesystems=home;...`。安装后应以第 c 步的 `--show-permissions` 实测为准。

### 12.4 结论与停手点

- 回滚材料：**通过**。完整包 60,334,712 字节，sha256 `7879a4…f0ba`，`SHA256SUMS` 全部 OK；9,780 字节的 delta 已标注不可用。
- 四条静态断言：**全部通过**，且直接镜像树与 `build/cache` OSTree 对象双向一致。
- 当前仍未安装新包，未停服务，未改 `~/.var/app`，未把大文件写 `/tmp`。
- **Gate 0 仍未通过**：23:33 复核时主包与 CUDA bundle 已出现（CUDA 为 860,154,032 字节），WPS bundle 正在生成，`scripts/build.sh` 与 `flatpak build-bundle ... agent-zero-wps.flatpak ...` 仍在跑。按用户要求，停在这里等安装指令；不自行安装。
