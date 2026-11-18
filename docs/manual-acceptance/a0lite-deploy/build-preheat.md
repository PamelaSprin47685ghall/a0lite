# 构建前预热与预取报告

- 执行时间：2026-11-17 22:59 – 23:14（CST）
- 工作目录：`/home/kunweiz/Desktop/a0lite`（打包层，HEAD `058582f`）
- 环境：Manjaro / flatpak 1.18.4 / flatpak-builder 1.4.12 / `org.freedesktop.Sdk/x86_64/25.08` / bun 1.4.4 / bwrap 正常
- 本轮边界：**没有运行 `scripts/build.sh`**，没有安装、卸载、repair 任何 flatpak 包，没有删除任何用户项目文件

## 结论摘要

| 问题 | 结果 |
|---|---|
| 释放了多少空间 | 本轮动作释放 **2.75 GB**（`~/.var/app/org.agentzero.AgentZero/cache`）；`/home` 可用由 8.8 G 升至 33 G，其余增量来自并发进程，不计入本轮 |
| pin 是否全对 | **20/20 已落盘的源逐字符匹配**，含 1.53 GB 的 ollama tarball；另有 3 个未预取的大文件由上游发布的摘要佐证。**无硬错误** |
| 预取是否成功 | **成功**。`build/downloads` 现有 20 个源共 1.5 G；复跑三个 manifest 的 `--download-only` 分别 0.07 s / 0.08 s / 0.10 s，零传输 |
| WPS tarball 是否可生成 | **可以**（15,794,709 B，约 6 s）。但 sha256 每次不同、与 manifest pin 不符——这是 `build.sh` 设计上会处理的情况（重建后改写 pin），不是阻塞 |
| 下一个硬风险 | `build.sh` 首步的 `--install-deps-from=flathub` 会强制 `flatpak update` SDK/Platform；本轮已把它更新到最新（现在输出 `Nothing to update`），但网络再抖动时会卡在构建最开始。另一个是 `Models.yml` 的 `ollama pull` 需要构建沙箱内有 DNS，与 `Wps.yml` 注释「沙箱无 DNS」直接矛盾 |

---

## 1. 磁盘预算

### 1.1 清理前

```
$ df -h /home
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  111G  101G  8.8G  93% /home
$ findmnt -no SOURCE,FSTYPE,OPTIONS /home
/dev/nvme0n1p2[/@home] btrfs rw,relatime,compress=zstd:1,ssd,discard=async,space_cache=v2,...
```

`~/.cache/*` 前 20 大（未删除任何一项）：

```
370M  ~/.cache/fcitx5-wetypex        700M  ~/.cache/ms-playwright
319M  ~/.cache/uv                    600M  ~/.cache/google-chrome
262M  ~/.cache/go-build              135M  ~/.cache/pnpm
 74M  ~/.cache/pip                    65M  ~/.cache/node-gyp
 58M  ~/.cache/tbt-mem080-head        57M  ~/.cache/tbtun-dirty-backups
 56M  ~/.cache/tbt-mem080-out         52M  ~/.cache/mozilla
 50M  ~/.cache/bun                    33M  ~/.cache/huggingface
 29M  ~/.cache/tbtun-worktree-archive 20M  ~/.cache/mesa_shader_cache
 18M  ~/.cache/JetBrains              16M  ~/.cache/coreyolo-appimage
 14M  ~/.cache/fontconfig             13M  ~/.cache/yay
```

`~/.var/app/org.agentzero.AgentZero/` 逐目录：

```
cache   2,749,828,345 B  (du -sh: 2.8G)   <- 删除
data    947,196,491 B    (980M)           <- 保留（用户数据）
config  4.0K                              <- 保留
```

cache 内部构成（说明它确实只是可重建缓存）：

```
944M  cache/uv          691M  cache/tw2         408M  cache/tvt
343M  cache/tvs         215M  cache/tvu          81M  cache/tvb
 76M  cache/tvp          22M  cache/tvy          16M  cache/tvk
2.9M  cache/tvx         2.7M  cache/tva         2.7M  cache/tv9
2.1M  cache/radv_builtin_shaders   2.1M  cache/mesa_shader_cache   1.2M  cache/tvj
```

flatpak 安装区（只读统计，**未动**）：

```
9.0G  ~/.local/share/flatpak/repo
4.4M  ~/.local/share/flatpak/app
 25M  ~/.local/share/flatpak/runtime
131M  ~/.local/share/flatpak/.removed     <- 本轮开始时是 64K，说明有并发进程在此期间卸载了某个包（不是本轮动作）
```

其他：

```
86M   /home/kunweiz/Desktop/agent-zero
1.3M  /home/kunweiz/Desktop/a0lite
build/    不存在
bundles/  不存在
~/.cache/flatpak-builder   不存在
```

### 1.2 清理动作

只删了两项「确定可重建」的缓存，删除前已记录体积：

```
$ rm -rf /home/kunweiz/.var/app/org.agentzero.AgentZero/cache     # 2,749,828,345 B
$ rm -rf /home/kunweiz/.cache/flatpak-builder                     # 不存在，无操作
```

**未删除**（按要求保留）：`~/.cache/pip`、`~/.cache/bun`、`~/.cache/uv`、`~/.cache/huggingface`、`~/.var/app/.../data`、任何项目文件、任何 flatpak 安装。

### 1.3 清理后

```
$ df -h /home
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  111G   83G   27G  76% /home
```

| 时点 | 可用 | 说明 |
|---|---|---|
| 22:59 本轮开始 | 8.8 G (93%) | 基准 |
| 23:02 清理前 | 18 G (85%) | **外部进程**在此期间释放了约 9 G，不属于本轮 |
| 23:03 清理后 | 27 G (76%) | 本轮释放 2.75 G + 外部持续释放 |
| 23:14 预取完成后 | 33 G (70%) | 预取占用 1.5 G，净可用仍上升 |

即：本轮实际贡献 **2.75 GB**；`df` 的总增幅里有相当一部分来自同时运行的其它代理，不能算到本轮头上。

---

## 2. 构建状态目录

```
$ cat .gitignore
build/
bundles/
*.flatpak
models-repo.tar
models-repo/
*.oci
wps-office-mcp-deps.tar.gz
__pycache__/
*.pyc

$ git check-ignore -v build bundles
.gitignore:1:build/      build
.gitignore:2:bundles/    bundles

$ git check-ignore -v build/ bundles/ build/tmp/
.gitignore:1:build/      build/
.gitignore:2:bundles/    bundles/
.gitignore:1:build/      build/tmp/

$ mkdir -p build bundles build/tmp     # 成功
```

三者都被第 1、2 行的规则覆盖（`build/tmp/` 由 `build/` 前缀规则覆盖）。`*.flatpak` 与 `wps-office-mcp-deps.tar.gz` 另有独立规则。

---

## 3. TMPDIR

构建临时目录定为 `/home/kunweiz/Desktop/a0lite/build/tmp`，实测与 `/home` 同一 btrfs 子卷，不落在 tmpfs：

```
$ df -h /home/kunweiz/Desktop/a0lite/build/tmp
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  111G   83G   27G  76% /home

$ df -T /home/kunweiz/Desktop/a0lite/build/tmp | tail -1
/dev/nvme0n1p2 btrfs 115498084 86472868 28282268 76% /home
```

同时确认了 `/tmp` 是 32 G 的 tmpfs（`tmpfs 32G 3.1G 29G 10% /tmp`），默认会把解包与中间产物吃进内存；这正是要把 `TMPDIR` 钉到磁盘上的原因（当前内存已用 55/62 G，swap 4.7/8.8 G）。

**后续构建要用的完整环境变量行**见第 9 节。

---

## 4. source 预取

### 4.1 能力探测

```
$ flatpak-builder --help | grep -nE 'download-only|no-rofiles|state-dir|install-deps-from'
21:  --download-only                    Only download sources, don't build
52:  --install-deps-from=REMOTE         Install build dependencies from this remote
57:  --state-dir=PATH                   Use this directory for state instead of .flatpak-builder

$ flatpak-builder --help | grep -i rofiles
18:  --disable-rofiles-fuse             Disable rofiles-fuse use      # 没有 --no-rofiles
$ flatpak-builder --version
flatpak-builder-1.4.12
```

`--download-only` 存在；`--no-rofiles` 不存在（1.4.12 只有 `--disable-rofiles-fuse`，`build.sh` 用的正是后者）。

### 4.2 一个必须偏离原指令的决定：state-dir 用 `build/` 而不是子目录

`scripts/build.sh` 是这样调用的：

```
18  STATE=${STATE:-$HERE/build}
19  CACHE=$STATE/cache
69  flatpak-builder --user --force-clean --disable-rofiles-fuse \
70      --state-dir="$STATE" --install-deps-from=flathub \
71      "$STATE/build-${manifest##*.}" "flatpak/$manifest.yml"
```

源代码落点是 `<state-dir>/downloads/<sha256>/<文件名>`。如果把预取放在 `build/state-main` 这类子目录，正式构建用 `--state-dir=build` 时**一个字节都命中不了**，等于白下 1.5 G。因此预取直接用 `--state-dir=/home/kunweiz/Desktop/a0lite/build`，与 `build.sh` 完全一致；三个 manifest 共用这一处 state，也正是 `build.sh` 的真实行为（它只用一个 `STATE`）。

预取在 `build/prefetch-src/`（`flatpak/` 的副本，196 K）里执行，原因：主 manifest 的 `type: dir / path: ..` 会把 manifest 的父目录整个复制进构建树；若从仓库根运行，`..` 就会包含 `build/` 自身，形成把 `build/` 复制进 `build/` 的危险。`build.sh` 之所以没这个问题，是因为它先把打包层复制进 `agent-zero` checkout，再在 checkout 里构建。

### 4.3 三个 manifest 的预取结果

| manifest | 命令要点 | 耗时 | 退出码 | 下载量 |
|---|---|---|---|---|
| `org.agentzero.AgentZero.yml` | `--download-only --state-dir=build` | **19.6 s** | 0 | 17 个源，32,754,772 B（约 31 MiB） |
| `org.agentzero.AgentZero.Cuda.yml` | 同上 | **2 m 45 s** | 0 | 1 个源，1,525,346,571 B |
| `org.agentzero.AgentZero.Wps.yml` | 同上 | 7.9 s | **1** | bun + wps-skills（见下） |
| 复跑 main | 同上 | 0.071 s | 0 | 0（`Downloading sources` 后直接退出） |
| 复跑 cuda | 同上 | 0.083 s | 0 | 0 |

主 manifest 的日志开头：

```
Downloading sources
Downloading https://github.com/astral-sh/uv/releases/download/0.13.6/uv-x86_64-unknown-linux-gnu.tar.gz
100 16.02M 100 16.02M ... 5.61M       # 16.02 MB
Downloading http://deb.debian.org/debian/pool/main/p/pygobject/python3-gi_3.58.1-1+b1_amd64.deb
100 240.6k 100 240.6k ... 519.3k
... (共 11 个 Debian deb、5 个 xpra deb、1 个 uv)
```

Cuda 的 ollama tarball：

```
Downloading https://github.com/ollama/ollama/releases/download/v0.40.13/ollama-linux-amd64.tar.zst
100  1.41G 100  1.41G ... 8.96M       # 平均约 9 MB/s
```

Wps 第一次失败，原因是 manifest 的第三个源是本地文件：

```
Failed to download sources: module wps-deps: Can't find file at wps-office-mcp-deps.tar.gz
```

这不是网络问题：`flatpak/wps-office-mcp-deps.tar.gz` **不在仓库里**（被 `.gitignore` 排除），由 `build.sh` 在构建前用 `scripts/build-wps-deps.sh` 现生成。在 staging 里用该脚本生成一份（并把 staging manifest 的 pin 改成新值，仓库 manifest 未动），再跑即通过：

```
$ sh scripts/build-wps-deps.sh /home/kunweiz/Desktop/a0lite/build/prefetch-src/flatpak
sha256 : 9feb8584a75e8c269ed80d9af19d18671edc73178bfe6831eb9549f069f4462e
$ flatpak-builder ... --download-only ... flatpak/org.agentzero.AgentZero.Wps.yml
Downloading sources
real 0m0.102s   EXIT=0
```

结论：Wps 的两个**远端**源（bun 51,794,595 B、wps-skills 293,294 B）已全部落到 `build/downloads`；第三个源是本地产物，不属于预取范围。仓库里的 pin 仍是原值 `ff53b592...`。

### 4.4 依赖更新（`--install-deps-from=flathub`）

`build.sh` 每次都带这个参数，flatpak-builder 因此会先跑 `flatpak update`。首次尝试时网络抖动，4 m 11 s 仍停在逐个 `Updating` 上，被我终止：

```
Dependency Sdk: org.freedesktop.Sdk 25.08
Updating org.freedesktop.Sdk/x86_64/25.08
Updating runtime/org.freedesktop.Platform.GL.default/x86_64/25.08
# 4m11s 后仍停在此处；实测该进程写入速率 12–24 KiB/s，机器总下行 55 KiB/s
```

终止后 SDK 完好（第 6 节冒烟通过）。网络恢复后重跑，43 秒完成：

```
Updating org.freedesktop.Sdk/x86_64/25.08
Updating runtime/org.freedesktop.Platform.GL.default/x86_64/25.08
Updating runtime/org.freedesktop.Platform.GL.default/x86_64/25.08-extra
Updating runtime/org.freedesktop.Platform.codecs-extra/x86_64/25.08-extra
Updating runtime/org.freedesktop.Sdk.Locale/x86_64/25.08
Updating runtime/org.freedesktop.Platform/x86_64/25.08
Updating runtime/org.freedesktop.Platform.Locale/x86_64/25.08
Downloading sources
real 0m43.181s   EXIT=0
```

之后再跑 Cuda / Wps 均输出 `Nothing to update.`（3.0 s / 1.0 s）。**下一轮构建不会再把时间花在这里**，前提是这期间 flathub 上没有新的 SDK 提交。

### 4.5 落盘清单

```
$ du -sh build/downloads; ls build/downloads | wc -l
1.5G
20
```

20 个目录，每个目录名就是源的 sha256，内含对应文件；最大的是 `c9490e0f…/ollama-linux-amd64.tar.zst`（1,525,346,571 B）。

### 4.6 为什么 Debian 源写的是 http

实测三条证据：

```
$ curl -sSI --max-time 20 http://deb.debian.org/debian/pool/main/p/pygobject/python3-gi_3.58.1-1+b1_amd64.deb
HTTP/1.1 200 OK
Content-Length: 246404
Server: Apache
X-Clacks-Overhead: GNU Terry Pratchett
Via: 1.1 varnish, 1.1 varnish
```

`curl -sSIL` 只输出一段 `HTTP/1.1 200 OK`，**没有 `location:`，没有 302 到 https**。对 `http://deb.debian.org/` 根路径与 `dists/stable/Release` 同样直接 200。https 版本内容逐位相同（同 `ETag`、同 `content-length`），且响应里没有 `strict-transport-security`。

所以 http 不是「被跳转到 https」的中间态，而是 Debian 自己 `sources.list` 文档里并列的一等写法（官方 wiki 先给 `http://deb.debian.org/debian`，再给 https 形式）。这个 manifest 的完整性由 `sha256:` 承担，不由 TLS 承担：镜像被换、CDN 给错内容、中间人改响应体，都会让 pin 校验当场失败。换成 https 的收益只剩「不暴露你拉的是哪个包」，代价是极少数只服务 http 的镜像/代理不可用。**结论：保持 http 是可接受的选择，pin 才是安全边界。**

顺带一个对下一轮有用的事实：这些 `.deb` 在 Debian pool 里是不可变文件。实测 sid 已推进到 `xvfb 21.1.26-1`、`libaudit1 4.2.1-1+b1`，而 manifest 钉住的 `21.1.25-2`、`4.1.2-1+b2` 仍留在 pool 并继续 200，所以旧 pin 不会突然 404。

---

## 5. pin 校验

校验分三层：(a) 抽样流式校验（不落盘）；(b) **预取落盘后再全量校验**（最强证据）；(c) 对未下载的大文件用上游发布的摘要比对。

### 5.1 落盘后的全量校验（20/20 匹配）

```
$ find build/downloads -type f -printf '%s %p\n' | sort -n | while read -r size path; do
    printf '%12s  %s  %s\n' "$size" "$(sha256sum "$path" | cut -c1-12)" "$(basename "$path")"; done
     19244  e9aa6dd94b67  libcap-ng0_0.9.6-1+b1_amd64.deb
     23404  96a4c5247489  libfontenc1_1.1.8-1+b3_amd64.deb
     39948  04c7528234a6  libbz2-1.0_1.0.8-6+b2_amd64.deb
     59056  611fd0053915  libaudit1_4.1.2-1+b2_amd64.deb
     92608  12c9fc5222e3  libselinux1_3.11-2.1+b1_amd64.deb
    117000  3e4c549683bf  python3-cairo_1.29.1-1+b1_amd64.deb
    123852  48a32d3f37df  xpra-client_6.5.5-r0-1_amd64.deb
    130704  f28ddac45ee1  libgirepository-2.0-0_2.90.1-2_amd64.deb
    136588  a8305a9c661a  libxfont2_2.0.9-1_amd64.deb
    246404  11e0a4923a88  python3-gi_3.58.1-1+b1_amd64.deb
    293294  b86b1f221952  a82533662268b3245f93d8685bc45dffede048b6.tar.gz
    305348  213f9f0119cd  libnettle8t64_3.10.2-1+b1_amd64.deb
    425788  47eba2b7c19e  xpra-server_6.5.5-r0-1_amd64.deb
    950584  4bacbd47fae7  xpra-x11_6.5.5-r0-1_amd64.deb
   2058660  64dd2cf7d8fb  xpra-html5-21-r1-1.deb
   3327208  525408bfcb83  xvfb_21.1.25-2_amd64.deb
   7899352  0ea743decede  xpra-common_6.5.5-r0-1_amd64.deb
  16799024  f29c3e94ffab  uv-x86_64-unknown-linux-gnu.tar.gz
  51794595  bf8ccbfb2b0b  bun-linux-x64.zip
1525346571  c9490e0f520b  ollama-linux-amd64.tar.zst
耗时 1s
```

### 5.2 校验表

| 源 | 期望 sha256（manifest） | 实际（落盘后实测） | 结论 |
|---|---|---|---|
| uv 0.13.6 tarball | `f29c3e94ffab…3645` | `f29c3e94ffab…` | 匹配 |
| bun v1.4.4 zip | `bf8ccbfb2b0b…395c` | `bf8ccbfb2b0b…` | 匹配 |
| wps-skills `a825336…` tar.gz | `b86b1f221952…1761` | `b86b1f221952…` | 匹配 |
| ollama v0.40.13 tar.zst（1.53 GB） | `c9490e0f520b…5bb6` | `c9490e0f520b…` | 匹配 |
| xpra-common | `0ea743decede…6bef` | `0ea743decede…` | 匹配 |
| xpra-server | `47eba2b7c19e…bbd0` | `47eba2b7c19e…` | 匹配 |
| xpra-client | `48a32d3f37df…c135` | `48a32d3f37df…` | 匹配 |
| xpra-x11 | `4bacbd47fae7…114d` | `4bacbd47fae7…` | 匹配 |
| xpra-html5 | `64dd2cf7d8fb…3b80` | `64dd2cf7d8fb…` | 匹配 |
| python3-gi | `11e0a4923a88…6cca` | `11e0a4923a88…` | 匹配 |
| python3-cairo | `3e4c549683bf…58c0` | `3e4c549683bf…` | 匹配 |
| libgirepository-2.0-0 | `f28ddac45ee1…bb37f` | `f28ddac45ee1…` | 匹配 |
| xvfb | `525408bfcb83…08bb` | `525408bfcb83…` | 匹配 |
| libselinux1 | `12c9fc5222e3…ae22` | `12c9fc5222e3…` | 匹配 |
| libnettle8t64 | `213f9f0119cd…b30e` | `213f9f0119cd…` | 匹配 |
| libxfont2 | `a8305a9c661a…5cda` | `a8305a9c661a…` | 匹配 |
| libfontenc1 | `96a4c5247489…25f2` | `96a4c5247489…` | 匹配 |
| libaudit1 | `611fd0053915…c07f` | `611fd0053915…` | 匹配 |
| libbz2-1.0 | `04c7528234a6…c61f` | `04c7528234a6…` | 匹配 |
| libcap-ng0 | `e9aa6dd94b67…2e85` | `e9aa6dd94b67…` | 匹配 |

补充证据（不是重复验证，而是第二个信源）：

- Debian 侧：这 11 个 `.deb` 的文件名在 `dists/sid` 与 `dists/forky` 的签名 `Packages` 索引里，`SHA256` 字段与 manifest 逐字符一致（9 个在 sid，2 个只在 forky，因为 sid 已把它们推进到新版本）。
- 流式抽样阶段对每个 `.deb` 同时跑了 `curl -sSL URL | wc -c`，11/11 与实际 `content-length` 相等，确认哈希覆盖的是完整响应体。
- ollama 在预取前用 GitHub API 的 asset `digest`（`sha256:c9490e0f520b…`）比对过，预取后又用本地文件复核。

### 5.3 未预取的 3 个大文件

| 源 | 期望 | 证据 | 结论 |
|---|---|---|---|
| `Xiaomi-OCR-0.Q4_K_M.gguf`（529,297,664 B） | `1e497ff06b91…30d3a` | HF CDN 返回的 `x-linked-etag` = LFS oid = 期望值 | 匹配（未下载） |
| `Xiaomi-OCR-0.mmproj-bf16.gguf`（207,346,624 B） | `634d6bc95781…c90e` | 同上 | 匹配（未下载） |
| Models manifest 复用的 ollama tarball | 同 Cuda | 已用本地 1.53 GB 文件实测 | 匹配 |

这三条属于 Models 扩展，`build.sh` 不构建它，本轮也不预取（原因见风险 3）。

**硬错误：无。**

---

## 6. SDK 冒烟

```
$ flatpak run --command=sh --filesystem=/tmp org.freedesktop.Sdk//25.08 \
    -c 'uname -m; ls /usr/bin | head -3; command -v ar tar xz; echo $PATH'
x86_64
SvtAv1EncApp
[
accessdb
ls: write error: Broken pipe
/usr/bin/ar
/usr/bin/tar
/usr/bin/xz
/app/bin:/usr/bin
EXIT=0
```

`ls: write error: Broken pipe` 是 `head -3` 提前关管道触发的 SIGPIPE，不是 SDK 故障（退出码 0）。

解包链所需的全部工具：

```
$ flatpak run --command=sh org.freedesktop.Sdk//25.08 \
    -c 'for t in zstd xz gzip bzip2 ar tar; do printf "%s -> " "$t"; command -v "$t" || echo MISSING; done'
zstd -> /usr/bin/zstd
xz -> /usr/bin/xz
gzip -> /usr/bin/gzip
bzip2 -> /usr/bin/bzip2
ar -> /usr/bin/ar
tar -> /usr/bin/tar
EXIT=0
```

`flatpak/unpack-deb.sh` 依赖 `ar`（读 deb 的 `data.tar.*` 成员）与 `tar`+ `-J/-z/--zstd/-j`，两者都在；`zstd` 的存在也让 Cuda/Models 的 `zstd -dc … | tar -xf -` 有支撑。

附带确认没有被动到的东西：`flatpak list` 里 `org.agentzero.AgentZero{,.Cuda,.Models,.Wps}` 四个旧包仍在（128.1 MB / 1.4 GB / 5.4 GB / 190.1 MB），`org.freedesktop.{Platform,Sdk}` 25.08 与 GL/codecs runtime 齐全。**未对任何包执行 uninstall / repair / update 之外的写操作**（`update` 是 `--install-deps-from=flathub` 触发的依赖更新，不改变已装 app 的版本）。

---

## 7. WPS 依赖 tarball

### 7.1 原样命令有一个路径缺陷

```
$ sh scripts/build-wps-deps.sh flatpak
...
$ tsc
tar (child): flatpak/wps-office-mcp-deps.tar.gz: Cannot open: No such file or directory
tar: Child returned status 2
EXIT_CODE=2
```

原因在脚本第 16 行与第 25 行：`OUT=${1:-$(pwd)}` 在 `cd "$WORK"` **之前**取值，之后第 45 行 `tar -czf "$OUT/…"` 就变成了 `$WORK/flatpak/…`。传相对路径必然失败。

`build.sh` 不受影响，因为它传的是绝对路径（第 49 行 `"$HERE/scripts/build-wps-deps.sh" "$A0_SRC/flatpak"`）。

### 7.2 用绝对路径可以生成，但 sha256 与 pin 不符

```
$ sh scripts/build-wps-deps.sh /home/kunweiz/Desktop/a0lite/build/prefetch-src/flatpak
wps-skills-a82533662268b3245f93d8685bc45dffede048b6.tar.gz: OK
bun install v1.4.4 (38afee6c8)
[2.10ms] migrated lockfile from package-lock.json
+ @modelcontextprotocol/sdk@1.29.0 … (427 packages installed)
$ tsc
written: …/flatpak/wps-office-mcp-deps.tar.gz
sha256 : 9feb8584a75e8c269ed80d9af19d18671edc73178bfe6831eb9549f069f4462e
pinned : ff53b5920ebd705b0f47e9ee8dcd04b0755cab1f937e515a0f1ee28ea547ec73
EXIT_CODE=0
```

三次独立生成的结果：

| 次 | 字节 | sha256 |
|---|---|---|
| 1 | 15,934,759 | `b77df78e0ed7…4b88` |
| 2 | 15,932,624 | `68a76a713545…b0fb` |
| 3 | 15,794,709 | `9feb8584a75e…462e` |

**结论：内容可生成、结构正确，但字节不可复现。** 差异来自 tar 里的成员 mtime（`2026-11-17 23:04` vs `23:05` vs `23:11`），不是代码变化。`bun install` 与 `tsc` 每次都成功，产物体积稳定在约 15.8 MB。

结构符合 manifest 的 `strip-components: 1`：

```
$ tar -tzf wps-office-mcp-deps.tar.gz | head -5
wpsdeps/
wpsdeps/dist/
wpsdeps/dist/index.d.ts
…
```

顶层唯一目录 `wpsdeps/`，第二层只有 `dist/` 与 `node_modules/`；`dist/index.js` 存在，与 `flatpak/wps-mcp.sh` 里 `…/wps-office-mcp/dist/index.js` 的入口一致。共 11,480 条目。

### 7.3 这为什么不是阻塞

`build.sh` 第 39–61 行就是为这件事写的：tarball 存在但 sha 不符 → 删掉重建；重建后仍不符 → **在 checkout 副本里**把 manifest 的 pin 改成新值，并打印出来。仓库里的 pin 留给「实际发布过的那个产物」。所以下一轮构建会在 `$A0_SRC/flatpak/` 里生成新 tarball 并改写该副本的 pin，流程自洽。

### 7.4 产物处理

按指令，记录 sha256 后**已删除**，仓库未被弄脏：

```
$ rm -f flatpak/wps-office-mcp-deps.tar.gz
$ ls flatpak/wps-office-mcp-deps.tar.gz
ls: cannot access '…': No such file or directory
$ git status --short flatpak/
（本轮开始时为空；结束时出现的改动见第 8.3 节，均非本轮写入）
$ grep -n 'ff53b592' flatpak/org.agentzero.AgentZero.Wps.yml
81:        sha256: ff53b5920ebd705b0f47e9ee8dcd04b0755cab1f937e515a0f1ee28ea547ec73
```

staging 副本（`build/prefetch-src/`，已被 gitignore）里也删掉了那份 15.8 MB 的 tarball。

### 7.5 一次无法复现的瞬态失败

首次冷缓存运行时出现过：

```
error: Script not found "build"
EXIT_CODE=1
```

之后同一份 `package.json`（`scripts.build = tsc`，安装前后哈希不变）重跑 4 次全部成功，包括手动重放 install+build。判断为 bun 在 53.9 s 冷安装 + 内存紧张下的一次性异常 `[INFERENCE]`。风险在于：脚本失败时会 `trap` 删掉 `$WORK`，现场不留任何诊断材料。构建中若再遇到，只能重跑。

### 7.6 两条可选修复（本轮不改，等你决定）

1. `OUT` 在 `cd "$WORK"` 前 realpath 化，消除相对路径陷阱。
2. 打包时固定元数据以获得可复现的 pin：`tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -czf …`（必要时 `gzip -n`），然后同步更新 manifest 的 pin。收益是 pin 从此有意义；代价是首次要重新发布一次 tarball。

---

## 8. overrides 格式

### 8.1 文件内容

```
$ cat flatpak/overrides.txt
# Overrides for the Flatpak build.
#
# langsmith caps zstandard below 0.24, but no zstandard release in that range
# has a CPython 3.14 wheel. The API used by langsmith is unchanged in 0.25.
zstandard>=0.25

# unstructured caps numpy below 2, but no numpy 1.x release has a CPython 3.14
# wheel. The partitioners used here run on numpy 2.
numpy>=2.1
```

去掉注释后的**有效约束只有两行**：`zstandard>=0.25`、`numpy>=2.1`。这完全符合 `uv pip --override` 的格式（每行 `package==version` 或 `package>=x,<y`，可带注释），且确实被这样使用：

```
$ sed -n '98,104p' flatpak/agent-zero.sh
    /app/bin/uv venv --python 3.14 "$VENV"
    /app/bin/uv pip install --python "$VENV/bin/python" \
        --override "$APP_ROOT/flatpak/overrides.txt" \
        -r "$APP_ROOT/flatpak/requirements-flatpak.txt"
```

注意使用时机：这是**首次运行**（`$VENV/.a0-ready` 不存在时）在容器内建 venv 并装依赖，不在构建期。也就是说镜像里不带 venv，第一次启动需要网络装 65 个直接依赖（`grep -vcE '^\s*(#|$)'` 计数）及其传递依赖。

### 8.2 任务里的假设需要修正

「确认它限制的包（langsmith、unstructured、numpy、zstandard）确实出现在 `requirements-flatpak.txt` 里」这个检验本身不成立，因为 override 针对的正是**传递依赖**，它们本来就不该出现在直接依赖表里：

| 包 | 在 requirements 里 | 在 overrides 里 | 事实 |
|---|---|---|---|
| `zstandard` | 无（仅注释提及其被 `langsmith` 限制） | `zstandard>=0.25` | 由 `langsmith` 传递引入 |
| `numpy` | 无（仅注释） | `numpy>=2.1` | 由 `unstructured` / 数据栈传递引入 |
| `langsmith` | **无任何出现**（`grep -ni langsmith` 零命中） | 仅注释 | 由 `langchain-core`（第 46 行）传递引入 |
| `unstructured` | `unstructured==0.16.23`（第 60 行）、`unstructured-client==0.31.0`（第 61 行） | 仅注释 | 直接依赖；它声明的 `numpy<2` 被上面那条 override 放宽 |

所以结论不是「四个包都在 requirements 里」，而是：**override 的两条约束针对两个传递依赖，requirements 里没有它们是正确状态；`unstructured` 是直接依赖并在表内；`langsmith` 只通过 `langchain-core` 间接进入。** 这个 `--override` 用对了。

### 8.3 一个文档漂移，本轮已被别的代理修掉

`flatpak/requirements-flatpak.txt` 的注释原本写着「`flatpak/numpy-override.txt` relaxes」，但**该文件在仓库里不存在**。这轮期间有并发代理改了这个文件，现在指向 `flatpak/overrides.txt`（第 26 行），与实际一致。

同时提醒：`git status` 里的这些改动**都不是我写的**。下面是 23:10 的快照；到 23:15 已扩展到 13 个文件（`flatpak/README.md`、`a0flatpak/{__init__,base_dir,packages}.py`、`agent-zero.sh` 也进了列表），所以它是一份**移动中的**清单，构建前必须自己再跑一次 `git status` 确认。`agent-zero.sh` 改动后 `uv pip install --override …/overrides.txt -r …/requirements-flatpak.txt` 这两行仍在（第 101–103 行），第 8.1 节的结论不受影响：

```
 M flatpak/a0flatpak/browser.py
 M flatpak/a0flatpak/desktop.py
 D flatpak/a0flatpak/health.py
 M flatpak/a0flatpak/ocr.py
 M flatpak/a0flatpak/serve.py
 M flatpak/a0flatpak/speech.py
 M flatpak/a0flatpak/vector_store.py
 M flatpak/requirements-flatpak.txt
?? .herd/
?? docs/manual-acceptance/
```

`requirements-flatpak.txt` 的差异要点：`faiss-cpu` 的替代说明改为 numpy shim、`unstructured` 改为「删 extras 保留 core」、删掉 `stealth-browser` 与 `nodriver` 两行。这会改变首次运行时装什么包——如果要构建的镜像应当包含它们，就得先确认。

> 本轮的全部结论只依赖 8.1 那两行 override 与依赖表的**包名集合**，不依赖上面这些并发改动是否最终定稿；但**镜像里会装进哪一版代码，取决于构建那一刻的工作树**。

---

## 9. 下一步给构建的完整命令

环境变量已全部验证可用，`STATE` 与预取的 state 是同一处，源码不会重下：

```sh
cd /home/kunweiz/Desktop/a0lite

export A0_SRC=/home/kunweiz/Desktop/agent-zero
export TMPDIR=/home/kunweiz/Desktop/a0lite/build/tmp
export STATE=/home/kunweiz/Desktop/a0lite/build
export OUT=/home/kunweiz/Desktop/a0lite/bundles

time scripts/build.sh
```

等价的一行式：

```sh
A0_SRC=/home/kunweiz/Desktop/agent-zero \
TMPDIR=/home/kunweiz/Desktop/a0lite/build/tmp \
STATE=/home/kunweiz/Desktop/a0lite/build \
OUT=/home/kunweiz/Desktop/a0lite/bundles \
  scripts/build.sh
```

变量含义与已验证的状态：

| 变量 | 值 | 状态 |
|---|---|---|
| `A0_SRC` | `/home/kunweiz/Desktop/agent-zero` | HEAD `ba9b67d`，clean；`run_ui.py` 存在（`build.sh` 的前置检查） |
| `TMPDIR` | `…/a0lite/build/tmp` | btrfs 同一子卷，非 tmpfs |
| `STATE` | `…/a0lite/build` | 已有 `downloads/` 20 个源 1.5 G，命中 `build.sh` 的 `--state-dir` |
| `OUT` | `…/a0lite/bundles` | 已创建，被 gitignore |

构建前建议的两条检查（只读，不改变任何状态）：

```sh
flatpak remote-ls --updates flathub --user --columns=application,branch   # 期望：空输出
git -C "$A0_SRC" status --short                                          # 期望：空输出
```

第一条实测为空输出（退出码 0），说明 SDK/Platform 25.08 与其 GL/codecs 扩展都没有待更新的提交；若它不是空的，先单独 `flatpak --user update -y`，别让更新混在构建里。

构建时 `build.sh` 会做四件有副作用的事，提前知情比事后排查划算：

1. `cp -a "$HERE/flatpak" "$A0_SRC/"` 与 `cp -a "$HERE/docs" "$A0_SRC/"` —— 会覆盖 checkout 里的同名目录（`docs` 是新增）。
2. 在 `$A0_SRC/flatpak/` 生成 `wps-office-mcp-deps.tar.gz`，并把该副本 Wps manifest 的 pin 改成新值。
3. 每个 manifest 前跑 `flatpak update`（当前输出 `Nothing to update.`）。
4. 构建产物落到 `$STATE/build-AgentZero` 等目录，最后 `flatpak build-bundle` 写三个 `.flatpak` 到 `$OUT`。

---

## 10. 风险清单（按发生概率排序）

1. **`--install-deps-from=flathub` 卡在构建第一步。** 本轮实测过一次 4 m 11 s 仍未完成的 `flatpak update`（网络抖动，写入速率 12–24 KiB/s）。现在依赖已全部更新，输出 `Nothing to update.`，所以下一轮大概率直接跳过；但如果 flathub 再抖动，`build.sh` 会在 `set -e` 下失败在最开始，且看起来像「构建失败」。缓解：构建前单独跑 `flatpak --user update -y`，或临时把该参数从 `build.sh` 去掉（`Sdk`/`Platform` 25.08 都已装）。

2. **`Models.yml` 需要构建沙箱内有 DNS，与 `Wps.yml` 的注释矛盾。** Wps manifest 明确写「the build sandbox has no DNS」，所以依赖预先打包；而 Models manifest 直接 `ollama serve & sleep 8` 再 `ollama pull lfm3-omni:2b-q4_K_M`、`qwen3-embedding:4b-q4_K_M`。如果沙箱真的无 DNS，这条流水线必失败；如果沙箱有网络，那 Wps 的预打包理由就不成立。这个矛盾必须在做 Models 之前用一次真实构建证实（`flatpak-builder` 默认**不**切断网络，`--sandbox` 才收窄，所以大概率能跑通；`sleep 8` 的固定等待则是另一个脆弱点——ollama 冷启动不一定 8 秒就绪）。

3. **磁盘：Models 全流程约 17–20 GB。** 构成：源 2.1 G（ollama 1.53 G + 两个 GGUF 0.74 G）+ registry 拉取 4.2 G（lfm3-omni 1.95 G、qwen3-embedding 2.38 G）+ 解压 tar 约 4 G + files/导出副本 6.5 G。当前可用 33 G，单独跑 Models 可以，与 Cuda（峰值约 7 G）并行就紧。本轮**没有**预取 Models，正是为了不提前吃掉这 2.1 G。

4. **内存紧张。** 当前 `Mem 62Gi total, 55Gi used, 6.0Gi available`，`Swap 8.8Gi used 4.7Gi`。构建期的 `bun install`/`tsc`/`zstd`/`flatpak-builder` 多进程并行会叠加；`flatpak-builder` 默认 `--jobs=NCPU`。若出现 OOM，先加 `--jobs=4` 之类的限制，而不是加大 swap。

5. **WPS deps tarball 的 pin 每次构建都不一样。** 这是设计使然（`build.sh` 会改写 checkout 副本），但它意味着「pin」对 WPS 扩展不构成可审计的安全边界：任何一次运行都会产生新 hash 并被接受。上一节 7.6 给了修复方向。

6. **并发写入。** 本轮有其它代理在改 `flatpak/a0flatpak/*.py` 并删了 `health.py`。若这些改动未收敛就构建，镜像里会装进半成品；`build.sh` 复制的是当前工作树，不区分谁写的。

---

## 附：本轮命令与输出的原始日志位置

| 文件 | 内容 |
|---|---|
| `build/logs/prefetch-main.log` | 主 manifest 首次 `--download-only`（uv + 16 个 deb 的传输进度；38 行） |
| `build/logs/prefetch-cuda.log` | Cuda manifest（ollama 1.53 GB，进度以 `\r` 覆盖写入，按换行计只有 6 行；`100  1.41G` 出现 6 次） |
| `build/logs/prefetch-wps.log` | Wps manifest **最后一次成功**运行（0.1 s，只有 `Downloading sources`）。失败那次的内容已被 `tee` 覆盖，本报告 §4.3 引的是控制台原文 |
| `build/logs/prefetch-deps-update.log` | 依赖更新 43 s 那次（含 7 个 `Updating`，12 行） |

`build/` 整个目录被 `.gitignore` 覆盖，这 4 个日志不会进仓库。
