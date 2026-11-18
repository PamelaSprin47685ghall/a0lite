# 构建机事实侦察

对象：本机（构建机）能否按 README 的方式构建本仓库的三个 Flatpak 包。
范围：只读侦察，未执行任何构建，未 clone，未安装任何包。
时间：2026-11-17 22:50–23:05（本机时区）。

结论先行：按 README 的流程（`A0_SRC=<checkout> scripts/build.sh`）在本机可以构建，工具链、SDK、网络、上游源码、基础应用全部就位，没有硬性缺失。真正的限制是资源：`/home` 只剩 8.8 GB（93% 已用），可用内存只剩约 1.4 GB 且 swap 已用 8.6/9.0 GB。构建能跑，但属于"贴着上限跑"。

---

## 1. 主机基线与磁盘

```
$ uname -a
Linux 7940HS 7.2.9-1-MANJARO #1 SMP PREEMPT_DYNAMIC Sat, 03 Oct 2026 15:02:22 +0000 x86_64 GNU/Linux
```

```
$ cat /etc/os-release
NAME="Manjaro Linux"
PRETTY_NAME="Manjaro Linux"
ID=manjaro
ID_LIKE=arch
BUILD_ID=rolling
```

```
$ nproc
16

$ free -h
               total        used        free      shared  buff/cache   available
Mem:            62Gi        57Gi       1.3Gi       163Mi       4.1Gi       4.6Gi
Swap:          8.8Gi       7.2Gi       1.6Gi

$ df -h /home
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  111G  101G  8.8G  93% /home

$ du -sh .
1.2M	.
```

补充（同一时段的压力指标）：

```
$ uptime
 22:57:52  up 2 days  0:16,  2 users,  load average: 3.47, 3.44, 3.25

$ ps aux --sort=-%mem | head -3
kunweiz 886851 210.2 79.3 ... /home/kunweiz/.local/bin/omp --model mistral/deepseek-v4-1-flash-1017

$ cat /proc/pressure/memory
some avg10=1.45 avg60=1.93 avg300=0.62 total=63732672
full avg10=1.40 avg60=1.88 avg300=0.60 total=61966879

$ free -m | tail -2
Mem:           63496       58044         608         132        5681        5452
Swap:           9011        8616         395
```

```
$ findmnt -no FSTYPE,OPTIONS /home
btrfs rw,relatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvolid=257,subvol=/@home
```

判断：

- 16 核，足够。flatpak-builder 的这几份 manifest 全是 `buildsystem: simple`，不解源码、不编译，主要开销是解包、拷贝、压缩，16 核用不满。
- 内存是短板。62 GiB 里 57 GiB 已被占用，最大占用者就是当前的 agent 宿主进程（RSS 约 51.5 GiB）。swap 只剩 395 MB 余量，`/proc/pressure/memory` 的 full avg10 已到 1.40。构建本身不重，但当机器处在换页边缘时，任何一次大的 `cp -a` 或 `tar` 都会把等待时间放大，也有触发 OOM 的可能。
- 磁盘是硬约束。`/home` 是 btrfs 子卷 `/@home`，8.71 GiB 可用（`btrfs filesystem usage` 报 Free estimated 8.71 GiB，与 df 一致，metadata ratio 2.0）。这不是"充裕"，是"刚好够一次构建"。
- `/tmp` 是 tmpfs（32 GiB，用 3.1 GiB，剩 29 GiB）。它由内存支撑，不是磁盘。往 `/tmp` 写大文件等于消耗 RAM。

---

## 2. Flatpak 运行时与构建器

```
$ flatpak --version
Flatpak 1.18.4

$ flatpak-builder --version
flatpak-builder-1.4.12
```

```
$ flatpak list --runtime --columns=application,branch,origin,size | grep -i freedesktop
org.freedesktop.Platform	25.08	flathub	670.7 MB
org.freedesktop.Platform.GL.default	25.08	flathub	462.3 MB
org.freedesktop.Platform.GL.default	25.08-extra	flathub	462.3 MB
org.freedesktop.Platform.codecs-extra	25.08-extra	flathub	43.4 MB
org.freedesktop.Sdk	25.08	flathub	1.7 GB
```

```
$ flatpak info org.freedesktop.Sdk//25.08 | head -12
            ID: org.freedesktop.Sdk
           Ref: runtime/org.freedesktop.Sdk/x86_64/25.08
          Arch: x86_64
        Branch: 25.08
       Version: freedesktop-sdk-25.08.19
        Origin: flathub
    Collection: org.flathub.Stable
  Installation: user
```

```
$ flatpak remotes -d
flathub	Flathub	https://dl.flathub.org/repo/	...	system
flathub	Flathub	https://dl.flathub.org/repo/	...	user
models-local	-	file:///home/kunweiz/a0build/modelsext/repo2	...	user,no-gpg-verify
agentzero-origin	Local repo	file:///home/kunweiz/a0build/fbbuild/state/cache	...	user,no-enumerate,no-gpg-verify
cuda-origin	Local repo	file:///home/kunweiz/a0build/fbbuild/state/cache	...	user,no-enumerate,no-gpg-verify
debug-origin	Local repo	file:///tmp/fbbuild/state/cache	...	user,no-enumerate,no-gpg-verify
debug1-origin	Local repo	file:///home/kunweiz/a0build/fbbuild/state/cache	...	user,no-enumerate,no-gpg-verify
pyprobe-origin	Local repo	file:///tmp/fbbuild/state/cache	...	user,no-enumerate,no-gpg-verify
wps-origin	Local repo	file:///home/kunweiz/a0build/fbbuild/state/cache	...	user,no-enumerate,no-gpg-verify
```

```
$ flatpak list --app --columns=application,branch,origin,size
org.agentzero.AgentZero	master	agentzero-origin	128.1 MB
org.agentzero.AgentZero.Wps	1.0	wps-origin	190.1 MB
org.test.PyProbe	master	pyprobe-origin	99.8 MB

$ flatpak list --runtime --columns=ref,origin,size
org.agentzero.AgentZero.Cuda/x86_64/12	cuda-origin	1.4 GB
org.agentzero.AgentZero.Models/x86_64/1.0	models-local	5.4 GB
org.freedesktop.Platform/x86_64/25.08	flathub	670.7 MB
org.freedesktop.Platform.GL.default/x86_64/25.08	flathub	462.3 MB
org.freedesktop.Platform.GL.default/x86_64/25.08-extra	flathub	462.3 MB
org.freedesktop.Platform.codecs-extra/x86_64/25.08-extra	flathub	43.4 MB
org.freedesktop.Sdk/x86_64/25.08	flathub	1.7 GB
org.gtk.Gtk3theme.Matcha-light-sea/x86_64/3.22	flathub	554.0 kB
```

```
$ cat ~/.local/share/flatpak/repo/config
[core]
repo_version=1
mode=bare-user-only
min-free-space-size=500MB
xa.pinned=runtime/org.agentzero.AgentZero.Cuda/x86_64/12;...
```

判断：

- 版本匹配：flatpak 1.18.4 + flatpak-builder 1.4.12，`--disable-rofiles-fuse`、`--install-deps-from`、`--state-dir`、`--force-clean` 全部支持（见第 3 节 help 摘录）。README 声称的"在 flatpak 1.18.4 上验证过"与本机一致。
- `org.freedesktop.Sdk/x86_64/25.08` 已安装（freedesktop-sdk-25.08.19，1.7 GB，用户级安装）。manifest 需要的正好是这一个，不需要下载 SDK。
- flathub 远端在 system 和 user 各有一份；`build.sh` 用 `--user`，走的是用户级那份，无需 root。
- 一批历史本地远端指向已不存在的目录：`/home/kunweiz/a0build/...` 和 `/tmp/fbbuild/...`。`ls /home/kunweiz/a0build` 返回 No such file or directory。这些远端是上一次构建留下的残影，`flatpak update` 之类会报错，但不影响本次构建。
- 已安装的 `org.agentzero.AgentZero`（commit 44c0ae83…，2026-11-01 11:30 UTC，128.1 MB）是本机的**基础应用**：Cuda manifest 的 `base:` 就需要它。它现在的 origin 指向已删除的目录，但仍然可用。不要卸载或 repair 掉它，否则 Cuda 构建会缺少 base。
- 仓库对象在 `~/.local/share/flatpak/repo/objects`，8.5 GB；其中很大一部分是 5.4 GB 模型扩展的 GGUF（content-addressed blob）。仓库模式 `bare-user-only`，即对象不压缩存储。

---

## 3. 构建工具链

```
$ command -v bun && bun --version
/home/kunweiz/.bun/bin/bun
1.4.4

$ command -v dpkg-deb
/usr/bin/dpkg-deb

$ for t in tar gzip zstd curl git sed awk ostree; do printf '%s: ' "$t"; command -v $t; done
tar: tar
gzip: /usr/bin/gzip
zstd: /usr/bin/zstd
curl: /usr/bin/curl
git: /usr/bin/git
sed: sed
awk: awk
ostree: /usr/bin/ostree

$ command -v python3 node npm jq make gcc ar xz
python3: /usr/bin/python3
node: /usr/bin/node
npm: /usr/bin/npm
jq: jq
make: /usr/bin/make
gcc: /usr/bin/gcc
ar: /usr/bin/ar
xz: /usr/bin/xz

$ flatpak build-update-repo --help >/dev/null && echo ok
ok

$ flatpak build-bundle --help >/dev/null && echo ok
build-bundle-ok

$ git --version; curl --version | head -1
git version 2.56.0
curl 8.22.0 (x86_64-pc-linux-gnu) libcurl/8.22.0
```

宿主没有的东西无关紧要，因为构建在 SDK 沙箱里跑。沙箱内实测：

```
$ flatpak run --command=sh org.freedesktop.Sdk//25.08 -c 'command -v ar tar zstd xz gzip sha256sum; command -v dpkg-deb || echo no-dpkg-deb; python3 --version'
/usr/bin/ar
/usr/bin/tar
/usr/bin/zstd
/usr/bin/xz
/usr/bin/gzip
/usr/bin/sha256sum
no-dpkg-deb
Python 3.13.16
```

```
$ bwrap --ro-bind / / --dev /dev --proc /proc --unshare-pid true && echo bwrap-ok
bwrap-ok

$ bwrap --version
bubblewrap 0.13.0

$ cat /proc/sys/user/max_user_namespaces; sysctl kernel.unprivileged_userns_clone
253715
kernel.unprivileged_userns_clone = 1

$ ls -l /dev/fuse
crw-rw-rw- 1 root root 10, 229 Nov 15 22:41 /dev/fuse
```

判断：

- 构建用的每个外部工具都在：bun 1.4.4（与 WPS manifest 里 `bun-v1.4.4` 的 pin 完全一致）、tar/gzip/zstd/xz/curl/git/sed/awk/ostree、sha256sum、ar。
- SDK 沙箱可正常启动，`ar`/`tar`/`zstd`/`xz` 齐备，`dpkg-deb` 如 manifest 注释所说确实不存在——这正是 `flatpak/unpack-deb.sh` 用 `ar p | tar` 替代的原因，该替代所需的两件工具都在。
- bubblewrap 可用、`/dev/fuse` 存在、user namespace 上限 253715，沙箱不是障碍。`--disable-rofiles-fuse` 让 rofiles-fuse 不参与，进一步降低对 fuse 的依赖。
- `dpkg-deb` 在宿主存在与否都不影响构建；它在 manifest 里从未被调用。

---

## 4. 已有上游源码

```
$ find /home/kunweiz -xdev \( -path '*/.local/share/flatpak' -o -path '*/.cache' \) -prune -o -name run_ui.py -print -o -name 'agent-zero' -type d -print
/home/kunweiz/Desktop/agent-zero
/home/kunweiz/Desktop/agent-zero/run_ui.py
/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero
```

（第三条是应用运行数据目录，不是源码。）

```
$ cd /home/kunweiz/Desktop/agent-zero
$ git log -1 --format='%H %ad %s'
ba9b67df0f54ac78106ae85c552ef5d2458f7c9a Sun Nov 1 22:10:32 2026 +0100 docs: refresh Launcher screenshot in README

$ git branch --show-current
main

$ git status --short          # 无输出
$ git remote -v
origin	https://github.com/agent0ai/agent-zero (fetch)
origin	https://github.com/agent0ai/agent-zero (push)

$ du -sh .; du -sh .git; du -sh --exclude=.git .
86M	.
29M	/home/kunweiz/Desktop/agent-zero/.git
57M	/home/kunweiz/Desktop/agent-zero

$ ls -d flatpak
ls: cannot access 'flatpak': No such file or directory
```

判断：

- 已有可用 checkout：`/home/kunweiz/Desktop/agent-zero`，干净（working tree 无改动），浅克隆，HEAD = `ba9b67df…`，与 `git ls-remote` 得到的远端 HEAD（见第 7 节）**完全一致**。不需要重新 clone。
- checkout 里没有 `flatpak/` 目录，所以 `build.sh` 的 `cp -a "$HERE/flatpak" "$A0_SRC/"` 会新建它，不会与旧文件混在一起。这是干净的一次落地。
- **路径注意**：README 写 `A0_SRC=$PWD/agent-zero`，即假定 checkout 位于 a0lite 仓库内部。实际 checkout 在 `/home/kunweiz/Desktop/agent-zero`，与 a0lite 平级。因此必须写成 `A0_SRC=/home/kunweiz/Desktop/agent-zero scripts/build.sh`。若照抄 README，`build.sh` 会在 `$A0_SRC/run_ui.py` 检查处退出：
  `build: /home/kunweiz/Desktop/a0lite/agent-zero does not look like an agent-zero checkout`。
- 目录可写（实测 `touch` 后删除成功），`cp -a` 不会因权限失败。
- 没有找到任何已暂存的 Ollama 目录（`bin/ollama` + `lib/` + `models/blobs`）；唯一的现成模型树是已安装的 Models 扩展部署（见第 9 节）。

---

## 5. 本仓库状态

```
$ git status --short
?? .herd/

$ git log -1 --oneline
058582f Make terminal timeouts and the agent workdir real

$ ls -la bundles build
（无输出；两个目录都不存在）
```

```
$ ls -l scripts
-rwxr-xr-x 1 kunweiz kunweiz 2035 build-wps-deps.sh
-rwxr-xr-x 1 kunweiz kunweiz 3128 build.sh
-rwxr-xr-x 1 kunweiz kunweiz 2343 deploy.sh
-rwxr-xr-x 1 kunweiz kunweiz 1537 install-services.sh
-rwxr-xr-x 1 kunweiz kunweiz 2459 package-models.sh

$ sh -n scripts/build.sh && echo build-sh-ok
build-sh-ok
$ sh -n scripts/build-wps-deps.sh && echo wps-sh-ok
wps-sh-ok
$ sh -n scripts/package-models.sh && echo models-sh-ok
models-sh-ok

$ git check-ignore -v build/ bundles/
.gitignore:1:build/	build/
.gitignore:2:bundles/	bundles/
```

判断：

- 工作树只有一处未跟踪目录 `.herd/`（本机 agent 运行时产生的，748 KB），与构建无关。
- `bundles/`、`build/` 都不存在，也没有任何 `*.flatpak` 文件。上一次构建的产物已被清空（历史远端指向的 `/home/kunweiz/a0build` 整个目录都不在了）。本次是从零构建，没有可复用的状态目录或缓存。
- 三个构建脚本语法检查通过（`sh -n`），均带执行位。
- 本仓库 `du -sh .` = 1.2 MB，对磁盘预算可忽略。

---

## 6. Manifest 逐份事实

四份 manifest 都能被 YAML 解析。汇总：

| manifest | app-id | runtime | sdk | command | 形态 |
| --- | --- | --- | --- | --- | --- |
| `org.agentzero.AgentZero.yml` | org.agentzero.AgentZero | org.freedesktop.Platform 25.08 | org.freedesktop.Sdk（→25.08） | agent-zero | 应用 |
| `org.agentzero.AgentZero.Cuda.yml` | …Cuda | org.agentzero.AgentZero master | org.freedesktop.Sdk/x86_64/25.08 | 无 | build-extension，branch 12 |
| `org.agentzero.AgentZero.Models.yml` | …Models | org.agentzero.AgentZero master | org.freedesktop.Sdk/x86_64/25.08 | 无 | build-extension，branch 1.0 |
| `org.agentzero.AgentZero.Wps.yml` | …Wps | org.freedesktop.Platform 25.08 | org.freedesktop.Sdk（→25.08） | wps-mcp | 独立应用 |

### 6.1 主包 `flatpak/org.agentzero.AgentZero.yml`

```
app-id: org.agentzero.AgentZero
runtime: org.freedesktop.Platform
runtime-version: '25.08'
sdk: org.freedesktop.Sdk
command: agent-zero
```

权限（finish-args，manifest 内的授权声明）：

```
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

扩展点：

```
add-extensions:
  org.agentzero.AgentZero.Models:
    directory: share/agent-zero/models
    version: '1.0'
    autodelete: false
    no-autodownload: true
  org.agentzero.AgentZero.Cuda:
    directory: share/agent-zero/cuda
    version: '12'
    autodelete: false
    no-autodownload: true
```

模块与外部输入：`uv`（archive 0.13.6，sha256 `f29c3e94…`）、`python-gi-cairo`（Debian forky 三个 .deb：python3-gi 3.58.1-1+b1、python3-cairo 1.29.1-1+b1、libgirepository-2.0-0 2.90.1-2）、`xpra`（xpra.org 五个 .deb，6.5.5-r0-1 + html5-21-r1）、`xvfb`（八个 .deb，含 libselinux/libnettle/libXfont2/libfontenc/libaudit/libbz2/libcap-ng）、`agent-zero`（`type: dir`，`path: ..`，`skip: [.git, tmp]`）。

### 6.2 CUDA 扩展 `flatpak/org.agentzero.AgentZero.Cuda.yml`

```
runtime: org.agentzero.AgentZero
runtime-version: master
branch: '12'
sdk: org.freedesktop.Sdk/x86_64/25.08
build-extension: true
base: org.agentzero.AgentZero
base-version: master
inherit-extensions:
  - org.agentzero.AgentZero.Models
  - org.agentzero.AgentZero.Cuda
```

权限：`--device=dri`。扩展点：`org.agentzero.AgentZero.Cuda` → `share/agent-zero/cuda`，version `12`，`autodelete: false`，`no-autodownload: true`。
模块：`ollama-cuda`，源为 `ollama-linux-amd64.tar.zst` v0.40.13（sha256 `c9490e0f…`），只取 `lib/ollama/cuda_v12` 到扩展根。

### 6.3 模型扩展 `flatpak/org.agentzero.AgentZero.Models.yml`

```
runtime: org.agentzero.AgentZero
runtime-version: master
branch: '1.0'
sdk: org.freedesktop.Sdk/x86_64/25.08
build-extension: true
base: org.agentzero.AgentZero
base-version: master
```

权限：`--share=network`。扩展点：`org.agentzero.AgentZero.Models` → `share/agent-zero/models`，version `1.0`，不自动下载、不自动删除。
模块：`ollama`（同一 tarball v0.40.13，装 `bin/ollama` + `lib/ollama`，删掉 cuda_v12/v13）、`models`（`ollama serve` 后 `pull lfm3-omni:2b-q4_K_M`、`pull qwen3-embedding:4b-q4_K_M`，再用两个 HuggingFace GGUF 建 `xiaomi-ocr`；两个 GGUF 分别 pin `1e497ff0…`、`634d6bc9…`）。
**`scripts/build.sh` 的循环里没有这份 manifest**，它只由 `package-models.sh` 走另一条路径打包。

### 6.4 WPS `flatpak/org.agentzero.AgentZero.Wps.yml`

```
runtime: org.freedesktop.Platform
runtime-version: '25.08'
branch: '1.0'
sdk: org.freedesktop.Sdk
command: wps-mcp
```

权限：`--share=network`、`--filesystem=~/.local/share/Kingsoft/wps/jsaddons:ro`。
模块：`bun`（`bun-v1.4.4` zip，sha256 `bf8ccbfb…`，strip-components 1）、`wps-skills`（`lc2panda/wps-skills` 固定提交 `a8253366…` 的 tar.gz，sha256 `b86b1f22…`，加 `wps-mcp.sh`）、`wps-deps`（本地 `wps-office-mcp-deps.tar.gz`，sha256 `ff53b592…`，strip-components 1）。
无 `base`、无 `build-extension`，因此产物是 `app/org.agentzero.AgentZero.Wps/x86_64/1.0`（`flatpak list --app` 里确实以应用身份出现）。

补充不一致（不影响构建，仅记录）：

- Models manifest 的 `models` 模块在**构建期**联网 `ollama pull`，而 README 与 `package-models.sh` 都声称"权重从不在构建时下载、沙箱没有 DNS"。两处说法互相矛盾。
- Wps manifest 的注释写"这是一个 runtime"，实际构建和安装的是 app ref（`build-bundle` 不带 `--runtime` 也印证了这一点）。

---

## 7. 网络

```
$ curl -sS -o /dev/null -w '%{http_code}\n' --max-time 8 https://github.com
200
$ curl -sS -o /dev/null -w '%{http_code}\n' --max-time 8 https://dl.flathub.org
200
$ curl -sS -o /dev/null -w '%{http_code}\n' --max-time 8 https://registry.npmjs.org
200
$ curl -sS -o /dev/null -w '%{http_code}\n' --max-time 8 http://deb.debian.org/debian/
200
$ curl -sS -o /dev/null -w '%{http_code}\n' --max-time 8 https://huggingface.co
200
```

```
$ git ls-remote https://github.com/agent0ai/agent-zero HEAD
ba9b67df0f54ac78106ae85c552ef5d2458f7c9a	HEAD
```

```
$ curl -sSL -o /dev/null -w '%{http_code}\n' -r 0-1023 https://xpra.org/dists/forky/main/binary-amd64/xpra-common_6.5.5-r0-1_amd64.deb
206
$ curl -sSL -o /dev/null -w '%{http_code}\n' -r 0-1023 http://deb.debian.org/debian/pool/main/p/pygobject/python3-gi_3.58.1-1+b1_amd64.deb
206
$ curl -sSL -o /dev/null -w '%{http_code}\n' -r 0-1023 http://deb.debian.org/debian/pool/main/x/xorg-server/xvfb_21.1.25-2_amd64.deb
206
$ curl -sSL -o /dev/null -w '%{http_code}\n' -L https://github.com/astral-sh/uv/releases/download/0.13.6/uv-x86_64-unknown-linux-gnu.tar.gz
200
```

WPS 上游归档实测并核对校验和：

```
$ curl -sSL -o /tmp/wps-pin.tar.gz -w '%{http_code} %{size_download}\n' \
    https://github.com/lc2panda/wps-skills/archive/a82533662268b3245f93d8685bc45dffede048b6.tar.gz
200 293294

$ sha256sum /tmp/wps-pin.tar.gz
b86b1f221952ef8fcdcac028e24b4ce472163c0079487264ec1a649c0cbf1761  /tmp/wps-pin.tar.gz
（与 manifest pin 一致）
```

Ollama 发行包（1.5 GB）在 8 秒超时内已传出 71 MB 后中断，HTTP 状态为 200，说明可达、限速约 9 MB/s 量级；完整下载预计 3 分钟出头。

判断：所有 manifest 里钉住的外部 URL 都可访问，WPS 归档的 sha256 与 pin 逐字节吻合。网络不是障碍。唯一的量级问题是 Ollama tarball 1.5 GB、HuggingFace GGUF 合计约 3 GB，下载慢但只在构建 Models 时才需要。

---

## 8. 安装位置与权限

```
$ flatpak --user remotes -d
flathub	Flathub	https://dl.flathub.org/repo/	...
models-local	...
（其余为 a0build/fbbuild 残影）

$ flatpak --system remotes -d
flathub	Flathub	https://dl.flathub.org/repo/	...

$ ls -ld /var/lib/flatpak
drwxr-xr-x 1 root root 42 Nov  8 15:39 /var/lib/flatpak

$ ls -ld ~/.local/share/flatpak
drwxr-xr-x 1 kunweiz kunweiz 96 Nov  8 15:40 /home/kunweiz/.local/share/flatpak
$ du -sh ~/.local/share/flatpak /var/lib/flatpak
9.0G	/home/kunweiz/.local/share/flatpak
110M	/var/lib/flatpak
```

```
$ sudo -n true && echo sudo-ok || echo sudo-NO
sudo: a password is required
sudo-NO

$ id
uid=1000(kunweiz) gid=1001(kunweiz) groups=1001(kunweiz),3(sys),90(network),98(power),989(lp),998(wheel),1000(autologin)
```

判断：

- 用户安装在 `~/.local/share/flatpak`（9.0 GB，归 kunweiz 所有，可写）；系统安装 `/var/lib/flatpak` 只有 110 MB，仅含 system 级 flathub 的 appstream 与 repo。
- `build.sh` 全程 `--user`，写用户安装，**不需要 root**。
- 当前会话没有免密 sudo（`sudo -n` 要求密码），用户在 `wheel` 组。任何写 `/etc/systemd/system`、`systemctl enable` 的动作（`scripts/install-services.sh`）都必须由用户在交互终端输入密码，agent 无法代劳。
- 用户级 flathub 远端存在，`--install-deps-from=flathub` 不需要 root 也不会去动 system 安装。

---

## 9. 脚本前置依赖，逐条

### 9.1 `scripts/build.sh`

| 前置 | 要求 | 本机实际 | 结果 |
| --- | --- | --- | --- |
| `A0_SRC` | 含 `run_ui.py` 的 checkout | `/home/kunweiz/Desktop/agent-zero`，HEAD ba9b67d，干净 | 满足（须显式传这个路径） |
| `flatpak-builder` | 存在且支持 `--disable-rofiles-fuse` 等 | 1.4.12，参数全支持 | 满足 |
| `flatpak` | 存在 | 1.18.4 | 满足 |
| SDK | `org.freedesktop.Sdk/x86_64/25.08` | 已装（用户级） | 满足 |
| 基础应用 | Cuda 需要 `base: org.agentzero.AgentZero` master | 已装，commit 44c0ae83… | 满足 |
| 网络 | flathub + 各 pin URL | 全部 200/206 | 满足 |
| 核心工具 | cp、sha256sum、awk、sed、mkdir | 均在 | 满足 |
| WPS 依赖 tarball | `wps-office-mcp-deps.tar.gz` | 不存在（全盘无副本） | 会触发 `build-wps-deps.sh`，见 9.2 |
| 输出目录 | `bundles/`、`build/` 可写 | 仓库目录可写，两者都未创建（gitignore 已覆盖） | 满足 |
| 磁盘 | 估计 4.5–5.5 GB（见第 10 节） | 8.71 GB 可用 | 勉强满足 |

### 9.2 `scripts/build-wps-deps.sh`

| 前置 | 本机实际 | 结果 |
| --- | --- | --- |
| `curl` | 8.22.0 | 满足 |
| `tar` | 在 | 满足 |
| `bun` | 1.4.4（与 manifest 的 bun pin 相同） | 满足 |
| GitHub 归档可达且校验通过 | 已实测，sha256 与 pin 一致 | 满足 |
| npm registry（`bun install`） | 200 | 满足 |
| 锁文件形态 | 归档里只有 `package-lock.json`（206 KB），没有 `bun.lock` | bun 1.4.4 会自动迁移；见下方实测 |
| 构建脚本 | `package.json` 的 `build` = `tsc`，devDependencies 含 typescript/jest/eslint | 由 `bun install` 默认安装 devDeps，`bun run build` 可用 |

锁文件语义实测（隔离目录，只用一个 5 KB 包验证行为，不触碰本仓库）：

```
$ cat package.json
{"name":"probe","version":"1.0.0","dependencies":{"is-number":"7.0.0"}}
$ bun install --frozen-lockfile
bun install v1.4.4 (38afee6c8)
[0.20ms] migrated lockfile from package-lock.json
+ is-number@7.0.0
1 package installed [872.00ms]
exit=0
```

判断：`--frozen-lockfile` 在没有 `bun.lock`、只有 `package-lock.json` 时不会失败，bun 会先迁移锁文件再安装。这条前置不是阻塞。

唯一需要留意的：脚本用 `mktemp -d`，默认落在 `/tmp`，而 `/tmp` 是 tmpfs（内存）。`wps-office-mcp` 的 devDependencies 含 jest/tsc/eslint，`node_modules` 体量约数百 MB（[推断]，未实际安装），这部分会写进内存。在只剩 1.4 GB 空闲内存、swap 只剩 395 MB 的当下，建议 `TMPDIR=/home/kunweiz/...` 再跑，避免把内存压垮。

### 9.3 `scripts/package-models.sh`

| 前置 | 本机实际 | 结果 |
| --- | --- | --- |
| 暂存目录含 `bin/ollama`、`lib/`、`models/blobs` | 已安装的 Models 部署本身就是这棵树：`.../Models/x86_64/1.0/active/files/{bin,lib,models}`，bin 42M、lib 73M、models 5.0G，`ollama --version` = 0.40.13 | 满足（可直接把该 `files` 目录当 `<ollama-dir>`） |
| 三个模型齐全 | `models/blobs` 5.0G，含 505 MB 的 OCR GGUF 与 2.4 GB 主权重 | 满足 |
| `flatpak build-init --type=extension --base=org.agentzero.AgentZero` | 基础应用已装；SDK 25.08 已装 | 满足 |
| 磁盘 | 需要 `cp -a` 一份 5.4 GB + `build-export` 再一份 5.4 GB + `tar` 5.4 GB ≈ 16 GB 以上 | **不满足（仅 8.71 GB）** |
| 是否有必要重打 | 现有 Models 扩展已安装（branch 1.0，commit f011ae9b…） | 无必要 |

判断：重打 Models **当前磁盘不可能**，需要在做之前先释放约 8–10 GB；而 `build.sh` 本身不构建 Models，所以这不阻塞 README 的三包流程。

### 9.4 其余脚本

- `scripts/deploy.sh`：需要 `ssh`/`scp` 与非交互可达的目标主机（`BatchMode=yes`）。本机是构建机，任务不含部署，未验证目标主机。
- `scripts/install-services.sh`：写 `/etc/systemd/system`、`systemctl daemon-reload/enable/restart`，**需要 root**。本会话 `sudo -n` 失败，只能在用户交互终端执行。

---

## 10. 磁盘预算

现状：

```
$ df -h /home /var /tmp
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  111G  101G  8.8G  93% /home
/dev/nvme0n1p2  111G  101G  8.8G  93% /
tmpfs            32G  3.1G   29G  10% /tmp

$ btrfs filesystem usage /home
    Device size:		 110.15GiB
    Free (estimated):		   8.71GiB	(min: 8.71GiB)
    Free (statfs, df):		   8.71GiB
    Data ratio:			      1.00
    Metadata ratio:		      2.00
```

可释放空间（只读统计，未删除）：

```
$ du -sh ~/.local/share/flatpak/.removed ~/.var/app/org.agentzero.AgentZero ~/.cache
131M	/home/kunweiz/.local/share/flatpak/.removed
3.7G	/home/kunweiz/.var/app/org.agentzero.AgentZero
5.9G	/home/kunweiz/.cache

$ du -sh ~/.var/app/org.agentzero.AgentZero/*
980M	.../data
2.8G	.../cache
```

构建所需（[推断]，依据已安装产物的实测体积：主包 files 131 MB、Wps 200 MB、Cuda 1.3 GB）：

| 项目 | 估计 |
| --- | --- |
| `build/build-AgentZero`（源码副本 + 解包的 16 个 .deb + uv） | 0.4–0.6 GB |
| `build/build-Cuda`、`build/build-Wps` | 1.5–1.8 GB |
| `build/cache` 里的 ostree 对象（bare-user-only，不压缩） | 1.6 GB |
| `bundles/` 三个 .flatpak（build-bundle 默认 gzip） | 1.6–1.7 GB |
| 合计 | **约 4.5–5.5 GB** |

判断：8.71 GB 可用对 4.5–5.5 GB 需求，余量约 3 GB。可以跑完，但没有第二次重试的空间——第一次失败后不清目录，第二次会撞 ENOSPC。btrfs 的 metadata 双份（ratio 2.0）让"接近满"的状态比 ext4 更早出问题；flatpak 仓库自身还设了 `min-free-space-size=500MB`，可用空间低于 500 MB 时 flatpak 会直接拒绝写入。

如果要腾挪，最干净的是 `~/.cache`（5.9 GB）与应用缓存 `~/.var/app/org.agentzero.AgentZero/cache`（2.8 GB），它们都是可重建的缓存，不动代码、不动已安装的应用；`flatpak/.removed` 里那 131 MB 是上一次部署的残留。删任何东西都不在本报告的授权范围内，这里只记录可选项。

---

## 阻塞项

**硬性障碍：无。** 按 `A0_SRC=/home/kunweiz/Desktop/agent-zero scripts/build.sh` 的路径，工具链、SDK 25.08、flathub 远端、网络、上游 checkout、Cuda 所需的基础应用全部就位，且 WPS 依赖 tarball 可由 `build-wps-deps.sh` 在本机生成（bun 1.4.4、npm registry、上游校验和均已验证）。

需要留意的边界条件，按严重度排列：

1. **磁盘余量只有 3 GB 左右。** 需求约 4.5–5.5 GB，可用 8.71 GB。第一次构建能过，失败重试需要先清 `build/`、`bundles/`。低于 flatpak 的 500 MB 水位线时写入会被直接拒绝。可选释放：`~/.cache`（5.9 GB）、`~/.var/app/org.agentzero.AgentZero/cache`（2.8 GB）。
2. **内存处于换页边缘。** 可用 1.4 GB、swap 8.6/9.0 GB 已用，占用主体是 agent 宿主进程（RSS 51.5 GB）。构建本身不重，但任何大拷贝都可能被拖慢或触发 OOM。建议构建时不要再跑其他重负载，并把 `TMPDIR` 指到磁盘（`/home`），不要用默认的 tmpfs。
3. **Models 扩展无法在当前磁盘上重打**（需 16 GB 以上，只有 8.71 GB）。它不在 `build.sh` 的三包流程里，不影响本次构建目标；现有 5.4 GB 的 Models 部署可直接作为 `package-models.sh` 的输入源。
4. **需要 root 的动作**：`scripts/install-services.sh`（写 `/etc/systemd/system`、`systemctl enable`）。本会话 `sudo -n` 要求密码，必须由用户在终端交互执行。构建本身不需要 root。
5. **路径必须显式给。** README 的 `A0_SRC=$PWD/agent-zero` 在本机不成立（checkout 与 a0lite 平级，不在其内部）。照抄会立即在 `run_ui.py` 检查处退出。
6. **不要清理已安装的 `org.agentzero.AgentZero`（commit 44c0ae83…）。** 它是 Cuda manifest 的 `base`，虽然 origin 远端已失效，但部署本身完好；卸载或 repair 掉会让 Cuda 构建缺少 base。
