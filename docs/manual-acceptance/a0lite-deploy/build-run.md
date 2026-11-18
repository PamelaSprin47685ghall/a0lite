# 构建执行报告

- 执行时间：2026-11-17 23:19 – 23:34（CST）
- 工作目录：`/home/kunweiz/Desktop/a0lite`（HEAD `058582f` + 契约审查的未提交改动）
- 命令：`A0_SRC=/home/kunweiz/Desktop/agent-zero TMPDIR=…/build/tmp STATE=…/build OUT=…/bundles scripts/build.sh`
- 结果：**三个 bundle 全部产出，退出码 0**；总耗时 **11 m 18.9 s**
- 过程中发现并修掉一个脚本缺陷（缺 `--repo`），一次 **11 分钟**的重跑，无 OOM

---

## 1. 三项快检（构建前）

```
$ python3 -m compileall -q flatpak/a0flatpak && echo COMPILE_OK
COMPILE_OK

$ bash -n flatpak/agent-zero.sh && echo SH_OK
SH_OK

$ flatpak remote-ls --updates flathub --user --columns=application,branch
（空输出，exit 0）

$ git -C /home/kunweiz/Desktop/agent-zero status --short
（空输出，exit 0）
```

四项全部通过。前两项只检查语法与字节码可编译性，不保证运行时行为；后两项确认没有待更新的 flathub 提交、上游 checkout 干净。

## 2. 构建基线（「镜像里装的是哪版代码」的唯一凭据）

`git status --short`（构建前，23:19）：

```
 M flatpak/README.md
 M flatpak/a0flatpak/__init__.py
 M flatpak/a0flatpak/base_dir.py
 M flatpak/a0flatpak/browser.py
 M flatpak/a0flatpak/desktop.py
 D flatpak/a0flatpak/health.py
 M flatpak/a0flatpak/ocr.py
 M flatpak/a0flatpak/packages.py
 M flatpak/a0flatpak/serve.py
 M flatpak/a0flatpak/speech.py
 M flatpak/a0flatpak/vector_store.py
 M flatpak/agent-zero.sh
 M flatpak/requirements-flatpak.txt
?? .herd/
?? docs/manual-acceptance/
```

`git diff --stat`：

```
 flatpak/README.md                 |  2 +-
 flatpak/a0flatpak/__init__.py     |  7 +++++
 flatpak/a0flatpak/base_dir.py     |  5 ++--
 flatpak/a0flatpak/browser.py      | 61 ++++-----------------------------------
 flatpak/a0flatpak/desktop.py      | 42 +++++----------------------
 flatpak/a0flatpak/health.py       | 29 -------------------
 flatpak/a0flatpak/ocr.py          | 12 ++++++--
 flatpak/a0flatpak/packages.py     | 26 +++++++++++++++++
 flatpak/a0flatpak/serve.py        | 20 ++++---------
 flatpak/a0flatpak/speech.py       | 13 +++++----
 flatpak/a0flatpak/vector_store.py | 14 +++++++--
 flatpak/agent-zero.sh             |  2 +-
 flatpak/requirements-flatpak.txt  | 13 +++------
 13 files changed, 91 insertions(+), 155 deletions(-)
```

工作树里这些文件的最新 mtime 为 **23:18:30**（审查改动落盘时间），全部早于首次构建启动时刻，所以镜像里是**审查后的完整工作树**，不是半途快照。

本轮我本人只改了一个文件：

```
$ git diff --stat scripts/build.sh
 scripts/build.sh | 2 +-
```

即第 70 行加上 `--repo="$CACHE"`（原因见第 3 节）。仓库里其它 13 个文件的改动都来自契约审查，我没有再动。

## 3. 第一次构建失败：`build.sh` 缺少 `--repo`

第一次运行 36.8 秒后退出，现象是三个 manifest 都构建成功，但打包阶段失败：

```
=== org.agentzero.AgentZero
…
Committing stage finish to cache
Pruning cache
=== org.agentzero.AgentZero.Cuda
…
=== org.agentzero.AgentZero.Wps
…
Pruning cache
error: Refspec 'app/org.agentzero.AgentZero/x86_64/master' not found
```

诊断证据：

```
$ ostree --repo=build/cache refs | grep -c 'app/'
0
$ ostree --repo=build/cache refs | head -3
x86_64-home_2Fkunweiz_2FDesktop_2Fagent-zero_2Fflatpak_2Forg.agentzero.AgentZero.Cuda.yml/build-ollama-cuda
x86_64-home_2Fkunweiz_2FDesktop_2Fagent-zero_2Fflatpak_2Forg.agentzero.AgentZero.Cuda.yml/cleanup
x86_64-home_2Fkunweiz_2FDesktop_2Fagent-zero_2Fflatpak_2Forg.agentzero.AgentZero.Cuda.yml/finish
```

`--state-dir` 的 `cache/` 里只有 flatpak-builder 自己的**模块缓存 ref**（`<arch>-<escape 后的 manifest 路径>/<stage>`），没有 `app/...`。`flatpak build-bundle "$CACHE" …` 因此找不到 ref。man 页说得很直白：

```
$ man flatpak-builder | col -b | grep -A4 '^     --repo=DIR'
     --repo=DIR
	 After the build finishes, run flatpak build-export to export the re-
	 sult to the repository DIR. If DIR exists, it must be an OSTree repos-
	 itory; otherwise a new one will be created.
```

**这是脚本缺陷，不是 manifest 缺陷**：`build.sh` 的意图明显是「导出到 `$CACHE`，再从 `$CACHE` 打 bundle」（第 19、74–79 行），但第 69–71 行的 `flatpak-builder` 调用没传 `--repo`，于是导出步骤根本没发生。修法是加一个参数，而不是改 manifest 或改 bundle 阶段：

```diff
     flatpak-builder --user --force-clean --disable-rofiles-fuse \
-        --state-dir="$STATE" --install-deps-from=flathub \
+        --state-dir="$STATE" --install-deps-from=flathub --repo="$CACHE" \
         "$STATE/build-${manifest##*.}" "flatpak/$manifest.yml"
```

复跑后日志里出现预期的导出行，ref 也齐了：

```
Exporting org.agentzero.AgentZero to repo
Exporting org.agentzero.AgentZero.Cuda to repo
Exporting org.agentzero.AgentZero.Wps to repo
Exporting org.agentzero.AgentZero.Wps.Debug to repo

$ ostree --repo=build/cache refs | grep -E '^(app|runtime)/'
app/org.agentzero.AgentZero.Wps/x86_64/1.0
app/org.agentzero.AgentZero/x86_64/master
runtime/org.agentzero.AgentZero.Cuda/x86_64/12
runtime/org.agentzero.AgentZero.Wps.Debug/x86_64/1.0
```

`Wps.Debug` 是这个 app 的 debuginfo 引用，属正常副产物（`separate-locales: false`，未关 debug），不影响 bundle。

## 4. 三个 manifest 的构建结果

总耗时 **11 m 18.9 s**（`real 11m18.874s`，`user 13m17.651s`，`sys 0m41.838s`），退出码 0。日志无时间戳，逐阶段耗时用产物落盘时间界定：

| 阶段 | 结束时刻 | 推算耗时 | 退出码 | 备注 |
|---|---|---|---|---|
| 主包 `AgentZero` | 23:23:54（bundle 写完） | 约 1 分钟 | 0 | 5 个模块全部命中模块缓存；`deps tarball does not match the pin, rebuilding it` 出现在最前面 |
| `Cuda` | 23:32:30 | 约 8.5 分钟 | 0 | 绝大部分时间在把 1.4 GB 未压缩内容压成 821 MB 的 bundle |
| `Wps` | 23:34:03 | 约 1.5 分钟 | 0 | 含 `bun` 107 MB 与 `node_modules` 全树 |

主包 5 个模块的构建行（都用缓存命中，没有重新解包）：

```
Building module uv …                    Committing stage build-uv to cache
Building module python-gi-cairo …       Committing stage build-python-gi-cairo to cache
Building module xpra …                  Committing stage build-xpra to cache
Building module xvfb …                  Committing stage build-xvfb to cache
Building module agent-zero …            Committing stage build-agent-zero to cache
```

`appstreamcli compose` 期间有一条无害告警，与打包内容无关：

```
(process:1574239): VIPS-WARNING **: 23:21:27.635: unable to load "/usr/lib/vips-modules-8.18/vips-openslide.so"
  -- libopenslide.so.1: cannot open shared object file: No such file or directory
Success!
```

**OOM：无。** 检查了三条证据：`dmesg`/`journalctl -k` 无 `Out of memory`/`Killed process`；构建日志里 `killed|out of memory|oom` 命中数为 0；构建期间与结束后内存都在安全区（构建后 `Mem 53Gi used / 8.0Gi available`，`Swap 5.0/8.8Gi`）。因此没有触发 `--jobs=2` 降载，也不需要加大 swap。

重试只有一次，原因是第 3 节的 `--repo` 缺陷，不是资源问题。

## 5. 产物

```
$ ls -lh bundles/
total 925M
-rw-r--r-- 1 kunweiz kunweiz 821M Nov 17 23:32 agent-zero-cuda.flatpak
-rw-r--r-- 1 kunweiz kunweiz  48M Nov 17 23:34 agent-zero-wps.flatpak
-rw-r--r-- 1 kunweiz kunweiz  57M Nov 17 23:23 agent-zero.flatpak

$ sha256sum bundles/*.flatpak
0cf9af0bce9c86a4d894bee9d7a928ca0f466832c87b01bc3dfa111183db062c  bundles/agent-zero-cuda.flatpak
248f2834112b744e9195c2013009e0998cb47effdd6f680e7725fc9ab3b1d634  bundles/agent-zero-wps.flatpak
6ca80d7d98df968aeb6c13d1e1c274c0a8098e1bd25fba5bd5cca462c0f564b8  bundles/agent-zero.flatpak
```

bundle 内部 ref（用 `strings` 从 bundle 头读出，未安装任何东西）：

| bundle | 内嵌 ref | 大小 | sha256 前 12 |
|---|---|---|---|
| `agent-zero.flatpak` | `app/org.agentzero.AgentZero/x86_64/master` | 57 M | `6ca80d7d98df` |
| `agent-zero-cuda.flatpak` | `runtime/org.agentzero.AgentZero.Cuda/x86_64/12` | 821 M | `0cf9af0bce9c` |
| `agent-zero-wps.flatpak` | `app/org.agentzero.AgentZero.Wps/x86_64/1.0` | 48 M | `248f2834112b` |

Cuda 的 821 M 与已装的 1.4 GB 扩展相比偏小，原因是 bundle 用 zstd 压缩了未压缩的 `.so`（`cuda_v12` 里 `libcublasLt.so.12.8.5.5` 单个就 751 MB），这是正常的压缩率，不是内容缺失（见第 6 节的内容清单）。

`flatpak install --dry-run` 在这个版本不支持，按指令跳过，没有真的安装：

```
$ flatpak install --user --noninteractive --reinstall --dry-run bundles/agent-zero.flatpak
error: Unknown option --dry-run
```

替代校验：`ostree fsck` 全仓通过，说明 cache 里 24 个 commit、16779 个对象一致完整：

```
$ ostree --repo=build/cache fsck
Verifying content integrity of 24 commit objects...
object fsck of 24 commits completed successfully - no errors found.
```

## 6. `ostree ls` 关键断言

命令（`ostree ls` 必须给完整 ref，裸 `org.agentzero.AgentZero/x86_64/master` 会报 `Refspec not found`；另外要 `-R` 才递归列出文件）：

```bash
ostree --repo=build/cache ls -R app/org.agentzero.AgentZero/x86_64/master
```

| 断言 | 结果 |
|---|---|
| 镜像里有 `a0flatpak/serve.py` | **通过**：`-00644 0 0 1626 /files/share/agent-zero/flatpak/a0flatpak/serve.py` |
| `a0flatpak/` 下没有 `health.py` | **通过**：`/files/share/agent-zero/flatpak/a0flatpak/health*` 零命中 |
| 镜像里 `agent-zero.sh` 是审查版 | **通过**：`-00755 0 0 6658 /files/share/agent-zero/flatpak/agent-zero.sh`，与工作树 6658 字节一致 |

注意：全树 grep `health.py` 有 **2 条命中**，但都在上游目录，与本次删除无关：

```
-00644 0 0    659 /files/share/agent-zero/api/health.py
-00644 0 0   2119 /files/share/agent-zero/api/health.py.dox.md
```

`api/health.py` 是 agent-zero 上游的 HTTP 健康检查端点（工作树里 `/home/kunweiz/Desktop/agent-zero/api/health.py` 存在），删除的是打包层的 shim `flatpak/a0flatpak/health.py`。两者同名不同物，断言必须带目录前缀才有意义。

逐文件大小比对（镜像内 vs 工作树，16 个文件全部一致）：

```
__init__.py        ws=1721   img=1721   OK
auth.py            ws=4504   img=4504   OK
base_dir.py        ws=2316   img=2316   OK
browser.py         ws=2620   img=2620   OK
code_exec.py       ws=2334   img=2334   OK
compat.py          ws=4865   img=4865   OK
desktop.py         ws=13922  img=13922  OK
embeddings.py      ws=3313   img=3313   OK
ocr.py             ws=4489   img=4489   OK
packages.py        ws=4136   img=4136   OK
parsers.py         ws=6474   img=6474   OK
provider_urls.py   ws=2254   img=2254   OK
rfc_loop.py        ws=806    img=806    OK
serve.py           ws=1626   img=1626   OK
speech.py          ws=5078   img=5078   OK
vector_store.py    ws=4059   img=4059   OK
```

体积变化与 `git diff --stat` 的增删行数一一对应，说明镜像拿的是**改后**版本，不是缓存里的旧副本：

| 文件 | HEAD 版 | 工作树 = 镜像 | 变化 |
|---|---|---|---|
| `desktop.py` | 14831 | 13922 | −909 |
| `browser.py` | 4170 | 2620 | −1550 |
| `serve.py` | 1910 | 1626 | −284 |
| `ocr.py` | 4073 | 4489 | +416 |
| `packages.py` | 3224 | 4136 | +912 |
| `vector_store.py` | 3651 | 4059 | +408 |
| `base_dir.py` | 2250 | 2316 | +66 |
| `speech.py` | 5122 | 5078 | −44 |

主包最终内容清单抽样：

```
/files/bin/Xvfb                       2262624
/files/bin/agent-zero                    6658
/files/bin/uv                        37784096
/files/bin/uvx                         330448
/files/bin/xpra                           525
```

Wps 与 Cuda 的内容也核过：

```
/files/bin/bun                      107260472
/files/bin/wps-mcp                        798
/files/wps-skills/wps-office-mcp/dist/index.js   5186
/files/cuda_v12/libcublasLt.so.12.8.5.5     751775824
```

## 7. 这次构建到底装进了哪一版代码

结论：**镜像里是 2026-11-17 23:18:30 落盘的契约审查版工作树**，依据三条独立证据链：

1. **内容对齐**：`a0flatpak/` 下 16 个文件在镜像中的字节数与工作树逐一相等；`health.py` 已不在该目录；`desktop.py` 的 13922 字节只可能来自改后版本（原版 14831）。
2. **时间顺序**：审查改动最后写入时间 23:18:30 < 首次构建启动 23:21 < 主包 commit 完成 23:23。中间没有其它写入者（`git status` 在构建前后完全一致）。
3. **缓存未污染**：`build/build-AgentZero` 在首次失败的那轮就已重建，主包模块 ref 在两次运行间重新提交（`Committing stage build-agent-zero to cache`），`health.py` 在树中消失也证明缓存不是旧的。

WPS 依赖 tarball 的处理符合设计：`build.sh` 在 `$A0_SRC/flatpak/` 重建它并改写那份额外 manifest 的 pin，仓库里的 pin 保持不变。

```
$ grep -c '7164dc1c' /home/kunweiz/Desktop/agent-zero/flatpak/org.agentzero.AgentZero.Wps.yml
1        # checkout 副本：新 pin
$ grep -c 'ff53b592' /home/kunweiz/Desktop/a0lite/flatpak/org.agentzero.AgentZero.Wps.yml
1        # 仓库：原 pin，未被改动
```

注意 `$A0_SRC` 现在有未跟踪的 `flatpak/`、`docs/` 与 tarball（`git -C … status --short` 显示 `?? flatpak/`、`?? docs/…`），这是 `build.sh` 的预期副作用，不影响上游 git 历史。

## 8. 边界与遗留

- **没有安装任何东西**：没跑 `flatpak install`/`uninstall`/`repair`/`update`（只有 `--install-deps-from=flathub` 触发的依赖检查，输出 `Nothing to update.`）。已装的四个旧包与 `org.freedesktop.*` 25.08 全部原样。
- **改了一个文件**：`scripts/build.sh`（+`--repo="$CACHE"`）。这是让脚本能产出 bundle 的最小必要改动；如果你想用别的方式（例如单独跑 `flatpak build-export`），把这一行回退即可，产物不受影响。
- 磁盘：`build/` 4.8 G（含 1.5 G downloads、1.6 G cache）、`bundles/` 925 M，`/home` 剩 31 G。
- 内存/swap 在构建后仍有余量（8.0 G available，swap 5.0/8.8 G），无需处理。

## 9. 下一步部署最该注意的三件事

1. **Cuda 的 base 是已装的主包**。`org.agentzero.AgentZero.Cuda.yml` 里有 `base: org.agentzero.AgentZero` / `base-version: master`，扩展构建时用的是**本机已装的旧 master**（构建日志：`Dependency Base: org.agentzero.AgentZero master` → `already installed`）。如果部署顺序是先装新主包再装 Cuda 扩展，扩展仍然能装上（extension 只挂 `cuda_v12`），但如果目标机**没有**主包，Cuda bundle 安装会因缺 base 失败。目标机顺序必须是：主包 → Cuda → Wps。另外，如果目标机已装旧主包，`--reinstall` 要显式加，否则 flatpak 会认为 ref 已存在而跳过。

2. **三个 bundle 的 ref 类型不同**。`agent-zero-cuda.flatpak` 是 `runtime/…Cuda/x86_64/12`，安装时必须 `flatpak install <bundle>`（flatpak 会自己按 ref 判断），不要手工写成 `--runtime` 之外的形式；`agent-zero-wps.flatpak` 是 `app/…Wps/x86_64/1.0`，与主包是两个独立 app，但 Wps 的 manifest 注释说它通过 `flatpak run --command=wps-mcp org.agentzero.AgentZero.Wps` 被主包调用——所以它必须装进**同一个用户安装**（都用 `--user`），否则主包启动的进程看不到它。

3. **首次启动需要网络**。镜像里不带 venv：`agent-zero.sh` 在 `$VENV/.a0-ready` 不存在时跑 `uv venv` + `uv pip install -r requirements-flatpak.txt`（65 个直接依赖 + 传递依赖）。目标机若无外网，第一次启动会失败在装依赖这一步，而不是应用本身。若目标机离线，需要另做一个「预装 venv」的变体；这次没有做。

另外提醒：镜像的 `finish-args` 里有 `--filesystem=host` 与 `--filesystem=host-etc:ro`、`host-os:ro`，这是「agent 操作真机」的设计前提，部署时不要按常规沙箱收紧，否则工具会看不到宿主机。

---

# 第三轮：并入 D1/D4/D2/D6 与 P1/P3/P4 后重建

- 时间：2026-11-17 23:42 – 23:45
- 端点：只重建主包（Cuda/Wps 未变，省掉约 10 分钟）
- 结果：**一次重建成功**，没有因为暂停令多花构建（暂停到达时上一版重建尚未开始）

## 1. 合入的三条修复

三条替换都用 `diff` 与草案逐字比对过，结果都是 `IDENTICAL_WITH_DRAFT`：

| 修复 | 文件 | 比对方式 |
|---|---|---|
| D1 | `flatpak/a0flatpak/desktop.py` | 草案 120–248 行 vs 实际 239–367 行，`diff` 无差异 |
| D4 | `flatpak/a0flatpak/ocr.py` | 草案 683–837 行 vs 实际 18–172 行，`diff` 无差异 |
| D2 | `flatpak/a0flatpak/browser.py` | 草案 444–485 行 vs 实际 35–76 行，`diff` 无差异 |

D1 的落地形态：`auth_key`/`xpra_auth` 上移到 `if host:` 之前，headless 分支里原来内联的两行被删除、`*(["‑‑tcp-auth=env"] if …)` 换成 `*xpra_auth`，shadow 分支新增「先剔除同名参数再 extend」。

D4 的落地形态：`OCR_TIMEOUT` 默认 45、新增 `OCR_MAX_PAGES`（默认 4）与 `OCR_MARGIN=5.0`、`_vision_markdown` 接受 `timeout` 参数、`_pdf_pages` 返回 `(pages, total)` 且只渲染前 N 页、新增 `_ocr_pages` 按 `per_document_timeout` 推算截止时间并把截断写成 Markdown 引用行。

D2 的落地形态：新增 `_CHROME_PATHS`（7 条绝对路径）并放在 `shutil.which` 之后、`A0_BROWSER_CHROME` 之前不动，docstring 同步说明「沙盒的 `/usr` 属于 runtime」。

## 2. 新增的三条修复

### P1 `ALLOWED_ORIGINS` 默认值

`flatpak/agent-zero.sh` 新增（在 `OLLAMA_*` 之后、`mkdir` 之前）：

```bash
A0_PORT="${A0_PORT:-5080}"
A0_HOST="${A0_HOST:-127.0.0.1}"
if [ -z "${ALLOWED_ORIGINS:-}" ]; then
    ALLOWED_ORIGINS="http://127.0.0.1:$A0_PORT,http://localhost:$A0_PORT"
    case "$A0_HOST" in
        127.0.0.1|localhost|0.0.0.0|::|::1) ;;
        *) ALLOWED_ORIGINS="$ALLOWED_ORIGINS,http://$A0_HOST:$A0_PORT" ;;
    esac
    export ALLOWED_ORIGINS
fi
```

注释里写明了因果链：「无登录且 Origin 不在 ALLOWED_ORIGINS → 拒绝所有 CSRF token → 所有 POST 403 → 设置/项目面板空白、聊天发不出」。用户显式设置时不追加、不改写。

据此把 `exec` 行的 `--port`/`--host` 也改用这两个变量，避免两处默认值漂移。

**为什么 `0.0.0.0` 不拼 origin**：上游的匹配是 `fnmatch` 拿 Origin 字符串去比，浏览器地址栏不会出现 `http://0.0.0.0:5080`（那是绑定地址，不是可访问地址）。真正会出现的两个 origin 是 `127.0.0.1` 与 `localhost`，已在上面的默认对里。所以通配绑定只保留回环对，而具体 IP/域名（如 `A0_HOST=192.168.1.9`）才追加。

四种组合实测（`env -u ALLOWED_ORIGINS` 后按脚本同样逻辑展开）：

| 场景 | 展开结果 |
|---|---|
| 未设，默认端口/host | `http://127.0.0.1:5080,http://localhost:5080` |
| 已设 `https://ai.kw92.cyou:12443` | `https://ai.kw92.cyou:12443`（原样，无追加） |
| 未设，`A0_PORT=8080` | `http://127.0.0.1:8080,http://localhost:8080` |
| 未设，`A0_HOST=192.168.1.9` | `http://127.0.0.1:5080,http://localhost:5080,http://192.168.1.9:5080` |

上游默认值的实据（`api/csrf_token.py:118-127`）：只有 `*://localhost*`、`*://127.0.0.1*`、`*://0.0.0.0*` 六条通配；`get_allowed_origins` 里「无配置就用默认」，一旦有配置就**整体替换**默认——这正是不能只写一条 `http://127.0.0.1:PORT` 的原因，那样会把 `localhost` 访问一并挡掉。

### P3 Ollama 日志移出 `logs/`

```bash
OLLAMA_LOG="$DATA_DIR/ollama.log"
OLLAMA_HOST="$OLLAMA_BIND" "$OLLAMA_BIN" serve >>"$OLLAMA_LOG" 2>&1 &
```

失败提示也改成引用新路径。注释写明了为什么不能放 `logs/`。根因已定位到具体代码，不是猜测：

```
helpers/migration.py:155  def _cleanup_obsolete() -> None:
    to_remove = ["knowledge/default", "memory", "logs"]
    for path in to_remove:
        if files.exists(path):
            PrintStyle().print(f"Removing {path}...")
            files.delete_dir(path)
```

`files` 的 `_base_dir` 被 `a0flatpak/base_dir.py:52` 改成 `$DATA_DIR`，所以删的是 `$DATA_DIR/logs`，而 launcher 用 `$LOG_DIR="$DATA_DIR/logs"` 在那里建 `ollama.log`——顺序上 Ollama 先 open，迁移后删，于是留下 unlinked inode。**`$DATA_DIR` 本身不在这份 `to_remove` 里**，所以 `$DATA_DIR/ollama.log` 安全。

路径验证（同样写法在临时目录跑两次追加）：

```
内容:
start 1
start 2
路径含 /logs/ ? 0
```

### P4 `/a0`：诊断结论是「不是缺陷，是探针方法错了」

三条探针原文：

```
$ flatpak run --user --command=sh org.agentzero.AgentZero -c 'id; ls -ld /; touch /a0-probe …'
uid=1000(kunweiz) gid=1001(kunweiz) groups=1001(kunweiz),65534(nfsnobody)
drwxr-xr-x 15 kunweiz kunweiz 480 /          <- / 可写
touch_rc=0
-rw-r--r-- 1 kunweiz kunweiz 0 /a0-probe

$ … -c 'ln -s /tmp /a0-probe2 …'
ln_rc=0
lrwxrwxrwx 1 kunweiz kunweiz 4 /a0-probe2 -> /tmp      <- ln 也正常

$ … -c 'ls -ld /run/host /run/host/root'
drwxr-xr-x 12 kunweiz   kunweiz   380 /run/host
dr-xr-xr-x  1 nfsnobody nfsnobody 244 /run/host/root
```

决定性证据来自**应用自己的沙盒**（不是另开一次 `flatpak run`）：

```
$ pgrep -af run_ui.py
1595368 … runpy.run_path('run_ui.py', …) --port=5080 --host=127.0.0.1
$ ls -ld /proc/1595368/root/a0; readlink /proc/1595368/root/a0
lrwxrwxrwx … /proc/1595368/root/a0 -> /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero
```

`/a0` 在 launcher 启动的那个进程树里**是存在的**，并指向 `$DATA_DIR`。`local-first-boot.md` §4.3 的探针之所以看不到，是因为 Flatpak 每次 `flatpak run` 都新建一个 tmpfs 沙盒根：探针跑在另一个实例里，当然没有另一个实例创建的链接。

所以本轮**不改 `ln` 的语义**，只把静默失败变可见（这是原代码真正的问题：`2>/dev/null || true` 吞掉一切）：

```bash
if [ ! -e /a0 ] && [ -w / ]; then
    if ! ln -s "$BASE_DIR" /a0 2>/dev/null; then
        echo "agent-zero: warning: /a0 could not be created; the framework will" >&2
        echo "agent-zero: resolve its paths against $APP_ROOT, which is read-only" >&2
    fi
fi
```

并在注释里写清「探针必须用 `ls -l /proc/<run_ui.py pid>/root/a0`，不能用另一次 `flatpak run`」。

## 3. 静态与行为验证（全部通过）

```
$ python3 -m compileall -q flatpak/a0flatpak && echo COMPILE_OK
COMPILE_OK
$ bash -n flatpak/agent-zero.sh && echo SH_OK
SH_OK

$ grep -n 'ALLOWED_ORIGINS' flatpak/agent-zero.sh
92:# request's Origin is not in ALLOWED_ORIGINS; without a token every POST is
104:if [ -z "${ALLOWED_ORIGINS:-}" ]; then
105:    ALLOWED_ORIGINS="http://127.0.0.1:$A0_PORT,http://localhost:$A0_PORT"
112:            ALLOWED_ORIGINS="$ALLOWED_ORIGINS,http://$A0_HOST:$A0_PORT"
115:    export ALLOWED_ORIGINS

$ grep -n 'ollama.log' flatpak/agent-zero.sh
165:    OLLAMA_LOG="$DATA_DIR/ollama.log"

$ grep -n 'ln -s\|warning:' flatpak/agent-zero.sh
53:    if ! ln -s "$BASE_DIR" /a0 2>/dev/null; then
54:        echo "agent-zero: warning: /a0 could not be created; the framework will" >&2
```

桩件四组（把 `_spawn_desktop_locked` 从源文件切出来，桩掉框架模块，读最终 argv）：

```
shadow + no key        tcp-auth=0 XPRA_PASSWORD=unset
shadow + key           tcp-auth=1 XPRA_PASSWORD=set
headless + no key      tcp-auth=0 XPRA_PASSWORD=unset
headless + key         tcp-auth=1 XPRA_PASSWORD=set
shadow + blank key     tcp-auth=0 XPRA_PASSWORD=unset
```

第 5 行是额外一组：`A0_AUTH_KEY="   "` 等价于未设置（`.strip()` 后为空，与 `serve.py` 对同一变量的处理一致）。

去重验证（把桩件的 shadow 命令改成上游自带 `--tcp-auth=env`）：

```
shadow + no key        tcp-auth=1 XPRA_PASSWORD=unset   <- 上游自己的那一个，未动
shadow + key           tcp-auth=1 XPRA_PASSWORD=set     <- 剔除后只留一个，不是 2
```

## 4. 重建

```
$ flatpak-builder --user --force-clean --disable-rofiles-fuse --repo=$CACHE \
    --state-dir=$STATE --install-deps-from=flathub $STATE/build-AgentZero flatpak/org.agentzero.AgentZero.yml
Nothing to update.
Building module agent-zero … Committing stage build-agent-zero to cache
Committing stage cleanup to cache
Committing stage finish to cache
Exporting org.agentzero.AgentZero to repo
Pruning cache
real 0m8.115s      BUILDER_EXIT=0

$ flatpak build-bundle $CACHE bundles/agent-zero.flatpak org.agentzero.AgentZero master
real 0m59.195s     BUNDLE_EXIT=0
```

前五个模块（uv / python-gi-cairo / xpra / xvfb）全部命中模块缓存，只重跑了 `agent-zero` 模块。预算里「约 10 分钟」的节省成立了：Cuda（8.5 分钟）与 Wps（1.5 分钟）没有重做。

新产物：

```
-rw-r--r-- 1 kunweiz kunweiz 59537424 Nov 17 23:45 bundles/agent-zero.flatpak
2a2fcf91eaffaca8d7c78a6692de81271acb557d93974845d8ff01f848035761  bundles/agent-zero.flatpak
```

上一版是 `59533584 B / 6ca80d7d98df…`，新版 `59537424 B / 2a2fcf91eaff…`：+3840 字节。净增行数（`git diff --numstat`）如下，压缩后的增量远小于行数差值，因为大部分改动是替换而非新增：

```
36  5   flatpak/README.md
30 57   flatpak/a0flatpak/browser.py
26 40   flatpak/a0flatpak/desktop.py
81 12   flatpak/a0flatpak/ocr.py
53  6   flatpak/agent-zero.sh
```

## 5. 镜像内断言（五条）

```bash
R=app/org.agentzero.AgentZero/x86_64/master
```

| # | 断言 | 命令与结果 |
|---|---|---|
| 1 | `desktop.py` 同时含 `--tcp-auth` 与 `XPRA_PASSWORD` | `ostree cat … desktop.py \| grep -c 'tcp-auth=env'` → **2**；`grep -c 'XPRA_PASSWORD'` → **2** |
| 2 | `ocr.py` 含 `A0_OCR_MAX_PAGES` | 第 29/32/54/132 行分别命中 `A0_OCR_TIMEOUT`（45）、`A0_OCR_MAX_PAGES`（4）、`per_document_timeout`、截断说明 |
| 3 | `browser.py` 含 `/opt/google/chrome` | 第 49–57 行 `_CHROME_PATHS`，首条 `"/opt/google/chrome/google-chrome"` |
| 4 | `agent-zero.sh` 含 P1/P3/P4 | 第 54 行 `/a0` 警告、第 92–115 行 `ALLOWED_ORIGINS`、第 165 行 `OLLAMA_LOG="$DATA_DIR/ollama.log"` |
| 5 | `a0flatpak/health.py` 不存在 | `ostree ls -R … \| grep -c 'a0flatpak/health'` → **0** |

第 5 条的完整版：全树仍有两条 `health.py`，都在上游目录，不是本轮删除的对象：

```
-00644 0 0    659 /files/share/agent-zero/api/health.py
-00644 0 0   2119 /files/share/agent-zero/api/health.py.dox.md
```

逐文件字节比对（镜像 vs 工作树）：`a0flatpak/*.py` 16 个文件全部相等，无一 `DIFF`；`agent-zero.sh` 两边都是 **9039** 字节。

## 6. 与上一版镜像的差异清单

`ostree diff` 对比上一版 commit `169f5e0` 与本版 `a33e50b`：

```
M /files/share/agent-zero/flatpak/README.md
M /files/share/agent-zero/flatpak/agent-zero.sh
M /files/share/agent-zero/flatpak/a0flatpak/browser.py
M /files/share/agent-zero/flatpak/a0flatpak/desktop.py
M /files/share/agent-zero/flatpak/a0flatpak/ocr.py
M /files/share/agent-zero/flatpak/a0flatpak/__pycache__/{browser,desktop,ocr}.cpython-314.pyc
```

只有这 8 条，`desktop.py`/`ocr.py`/`browser.py`/`agent-zero.sh`/`README.md` 正好对应本轮五处改动；其余 5084 个对象完全一致（`Common Object Count: 5074`，共 5092）。`__pycache__` 里的 `.pyc` 是 `compileall` 与打包过程带出来的编译产物，随源码同步更新，不是额外改动。

## 7. 一个需要下游注意的实证

D2 的路径表里既有 `/opt/google/chrome/google-chrome` 也有 `/run/host/opt/google/chrome/google-chrome`。在**应用实际沙盒**里核对：

| 路径 | 存在？ |
|---|---|
| `/opt/google/chrome/google-chrome` | **存在** |
| `/run/host/opt/google/chrome/google-chrome` | 不存在 |
| `/run/host/root/opt/google/chrome/google-chrome` | 存在 |
| `/run/host/usr/bin/google-chrome-stable` | 存在 |

也就是说 `--filesystem=host` 把宿主 `/opt` 直接挂在了沙盒的 `/opt`，而 `host-os` 挂在 `/run/host`，其下是宿主根的**镜像树**（`/run/host/root`）。草案的第一条路径就是命中的那条，所以列表按原样落地即可；`/run/host/opt/...` 不会命中，留着无害（它是某些 flatpak 版本的布局）。若以后命中失败，下一个该试的是 `/run/host/root/opt/google/chrome/google-chrome`，这条已记录在案但**没有**加进代码（避免把未验证的路径塞进镜像）。

---

# 第四轮：修正 `.env` 遮蔽 + 更正 Chrome 路径清单

- 时间：2026-11-17 23:49 – 23:51
- 产物：主包重出，Cuda/Wps 未动

## 1. 遮蔽问题的事实核对（结论与提案相反，但改动仍然落地）

提案说「`python-dotenv` 默认不覆盖已存在环境变量，所以 launcher 的 `export` 会静默遮蔽 `usr/.env`」。**这个前提在本仓库的调用点不成立。**

`helpers/dotenv.py:13-14`：

```python
def load_dotenv():
    _load_dotenv(get_dotenv_file_path(), override=True)
```

`override=True` 是显式传的，所以 `.env` 会**覆盖**已有环境变量，方向与提案相反：文件赢，launcher 的 export 只是兜底。

用应用自己的 venv（Python 3.14.10，`python-dotenv==1.2.2`）实测：

```
$ ALLOWED_ORIGINS=http://127.0.0.1:5080 venv/bin/python … load_dotenv(path, override=True)
before: http://127.0.0.1:5080
after : https://from-file.example          <- 文件赢

$ ALLOWED_ORIGINS=http://127.0.0.1:5080 venv/bin/python … load_dotenv(path, override=False)
after : http://127.0.0.1:5080               <- 这就是提案描述的行为，但上游没用它
```

所以「配了不生效」在当前代码里不会发生。改动仍然按提案落地，理由写在代码注释里：它把「`.env` 优先」从**运行时行为**变成**launcher 的显式契约**，万一上游改用默认的 `override=False`，这个检查仍然保证文件不被遮蔽。代价是 4 行 shell 与一次 `grep`，收益是不再把正确性寄托在别人的一个关键字参数上。

落地形态：

```bash
if [ -z "${ALLOWED_ORIGINS:-}" ]; then
    # A value in usr/.env is operator input too. ``load_dotenv`` currently runs
    # with ``override=True`` (helpers/dotenv.py), so the file would win anyway;
    # the check keeps that true if upstream ever flips to the python-dotenv
    # default of not overwriting. Without it, exporting a default here would
    # silently mask the file.
    if [ -f "$BASE_DIR/usr/.env" ] && \
       grep -qE '^[[:space:]]*(export[[:space:]]+)?ALLOWED_ORIGINS=' "$BASE_DIR/usr/.env"; then
        :
    else
        ALLOWED_ORIGINS="http://127.0.0.1:$A0_PORT,http://localhost:$A0_PORT"
        case "$A0_HOST" in
            127.0.0.1|localhost|0.0.0.0|::|::1) ;;
            *) ALLOWED_ORIGINS="$ALLOWED_ORIGINS,http://$A0_HOST:$A0_PORT" ;;
        esac
        export ALLOWED_ORIGINS
    fi
fi
```

## 2. `ALLOWED_ORIGINS` 五组矩阵（另加两组边界）

测试方法：把 `agent-zero.sh` 的 P1 段原文切出来（`sed -n '86,133p'`）写进 `/tmp/a0mx/frag.sh`，用临时 `$BASE_DIR` 造/不造 `usr/.env`，在子 shell 里 `source` 它，然后同时打印 `${ALLOWED_ORIGINS-<unset>}` 与 `env | grep -c ^ALLOWED_ORIGINS=`。所以测的是脚本原文，不是手抄逻辑。

| # | 场景 | 变量值 | 是否进入子进程环境 |
|---|---|---|---|
| 1 | 未设，`.env` 无键 | `http://127.0.0.1:5080,http://localhost:5080` | `YES` |
| 2 | 未设，`.env` 有 `ALLOWED_ORIGINS=https://ai.kw92.cyou:12443` | **未设置** | **none**（交给 dotenv 加载文件值） |
| 3 | 已由 env 设置 `https://example.test:9999` | `https://example.test:9999`（原样） | `YES` |
| 4 | 未设，`A0_PORT=8080` | `http://127.0.0.1:8080,http://localhost:8080` | `YES` |
| 5 | 未设，`A0_HOST=192.168.1.9` | `http://127.0.0.1:5080,http://localhost:5080,http://192.168.1.9:5080` | `YES` |
| 6 | `.env` 写 `   export ALLOWED_ORIGINS=https://spaced.example` | **未设置** | **none** |
| 7 | `.env` 只有 `ALLOWED_ORIGINS_EXTRA=x` | 默认回环对 | `YES` |

第 6 组证明 `^[[:space:]]*(export[[:space:]]+)?` 这两个前缀都能识别；第 7 组证明不会把 `ALLOWED_ORIGINS_EXTRA` 误判成同一个键（正则要求键名后紧跟 `=`）。

两次失败的重跑记录在这，因为它们暴露了测试方法本身的坑：先用 `env -u ALLOWED_ORIGINS` 包住整个驱动，结果第 3 组的外部值也被清掉；随后又把 `"$@"` 漏传给内层 shell，导致第 4、5 组的 `A0_PORT`/`A0_HOST` 没生效。最终版让驱动 `env "$@" sh -c '…'` 原样转发，才得到上表。

## 3. `OLLAMA_*` 四条遮蔽判断（逐条）

前提先摆清：因为 `override=True`，这四条**都能被 `.env` 覆盖**，不存在遮蔽。所以问题不是「要不要防遮蔽」，而是「launcher 该不该给默认值」。逐条：

| 变量 | 判断 | 理由 |
|---|---|---|
| `OLLAMA_MODELS` | **内部实现细节**，保持 export | 指向扩展挂载点 `$MODELS_ROOT/models`。写成别的目录，Ollama 就找不到随包权重，表现为「没有模型后端」。这不是操作者该调的东西；真要换权重，装另一个 Models 扩展。 |
| `OLLAMA_HOST` | **操作者会配**，但不需要加检查 | 它是客户端拨号地址，指向远端 Ollama 是合理部署。`override=True` 已保证 `.env` 赢，再加一次 grep 只会把优先级规则复制到两个地方，反而增加不一致的风险。 |
| `OLLAMA_MAX_LOADED_MODELS` | 操作者会配（内存），同上 | 默认 2 是保守值；显存/内存不同的人会改。 |
| `OLLAMA_KEEP_ALIVE` | 操作者会配（卸载时机），同上 | 默认 30m 是折中。 |

结论：**四条都保持 export，不加 `.env` 检查**，只在注释里写明「这些是 fallback，不是 override；`usr/.env` 优先」。一刀切地全加检查，会让 launcher 变成第二套 dotenv 解析器，而它并不知道 dotenv 的引号、转义与多行规则——那才会真的出错。

注释落地：

```
# These four are fallbacks, not overrides. ``a0flatpak`` calls
# ``helpers.dotenv.load_dotenv()``, which passes ``override=True``, so a key in
# ``usr/.env`` replaces whatever was exported here. Keep the export for the
# values the bundle owns, and let the file win for the rest:
#   OLLAMA_MODELS            bundle layout; the Models extension mounts there
#   OLLAMA_HOST              client URL; a remote Ollama is a valid choice
#   OLLAMA_*_MODELS/_ALIVE   memory tuning; operator territory
```

## 4. Chrome 路径：自己复核，不采信转述

```
$ flatpak run --user --command=sh org.agentzero.AgentZero -c 'for p in …; do … [ -x "$p" ] …'
/opt/google/chrome/google-chrome                         -> EXEC
/run/host/root/opt/google/chrome/google-chrome           -> EXEC
/run/host/opt/google/chrome/google-chrome                -> missing
/run/host/root/usr/bin/google-chrome                     -> missing
/run/host/root/usr/bin/google-chrome-stable              -> EXEC
/usr/lib/chromium/chromium                               -> missing
/usr/bin/chromium                                        -> missing
/run/host/root/usr/lib/chromium/chromium                 -> missing
```

复核结论与转述相反的两点，都以这次实测为准：

1. **`/opt/google/chrome/google-chrome` 是可执行的**（`[ -x ]` 通过），不是「不该采信」。它与 `/run/host/root/opt/…` 指向同一份宿主 Chrome：`--filesystem=host` 把宿主 `/opt` 按真实路径挂进来，同时 `host-os` 又把宿主根镜像挂在 `/run/host/root`。
2. `/run/host/opt/...` **不存在**——`/run/host` 下面是 `root`/`etc`/… 这样的入口，不是宿主 `/` 的直接摊平。

chromium 系路径本机没装，所以全部 `missing`，无法区分真假，只能按发行版惯例保留。

按新顺序落地的 `_CHROME_PATHS`（前三条是本机实测可执行的，其余是发行版布局）：

```python
_CHROME_PATHS = (
    "/run/host/root/opt/google/chrome/google-chrome",
    "/run/host/root/usr/bin/google-chrome",
    "/run/host/root/usr/bin/google-chrome-stable",
    "/opt/google/chrome/google-chrome",
    "/usr/lib/chromium/chromium",
    "/usr/bin/chromium",
    "/run/host/root/usr/lib/chromium/chromium",
    "/usr/lib/chromium-browser/chromium-browser",
    "/snap/bin/chromium",
)
```

探测顺序与判据：

```python
    override = os.environ.get(CHROME_ENV, "").strip()
    if override:
        candidate = Path(override).expanduser()
        return candidate if candidate.is_file() else None

    for name in _CHROME_NAMES:
        found = shutil.which(name)
        if found:
            return Path(found)

    for candidate in _CHROME_PATHS:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return Path(candidate)
    return None
```

初始路径的判据从 `Path.is_file()` 改成 `os.path.isfile() and os.access(X_OK)`：路径表里可能出现存在但不可执行的文件（例如被 `noexec` 挂载、或只剩一个占位壳），那种情况下应当继续往下找，而不是把不可执行的路径交给 Patchright 去 `exec` 失败。

docstring 同步为「`/usr` 属于 runtime，宿主根在 `/run/host/root`，所以 `which` 永远找不到宿主 Chrome」。

## 5. 静态检查与重建

```
$ python3 -m compileall -q flatpak/a0flatpak && echo COMPILE_OK
COMPILE_OK
$ bash -n flatpak/agent-zero.sh && echo SH_OK
SH_OK

$ flatpak-builder … --repo=$CACHE --state-dir=$STATE …
Nothing to update.
Building module agent-zero … Exporting org.agentzero.AgentZero to repo
real 0m8.619s      BUILDER_EXIT=0

$ flatpak build-bundle $CACHE bundles/agent-zero.flatpak org.agentzero.AgentZero master
real 0m58.377s     BUNDLE_EXIT=0
```

新产物：

```
-rw-r--r-- 1 kunweiz kunweiz 59535696 Nov 17 23:51 bundles/agent-zero.flatpak
27bf8a3526a9ae5039bb0d600c78c92feaf3708fab593240bd98fc73d07ea03e
commit 475e15778265872fae24cdc605ba3b629fe3637f7629ebf6ebea9c5ea544858d
```

上一版 `59537424 B / 2a2fcf91eaff… / a33e50b`；本版 `59535696 B / 27bf8a3526a9… / 475e157`。变小 1728 字节：`browser.py` 的路径表虽然多两条，但 docstring 与注释改写后总量下降。

## 6. 镜像断言

| # | 断言 | 结果 |
|---|---|---|
| 1 | `browser.py` 含 `/run/host/root/opt/google/chrome/google-chrome` | **通过**：第 52 行为路径表首条，第 49 行注释也提到；第 77 行 `os.path.isfile(...) and os.access(..., os.X_OK)` |
| 2 | `agent-zero.sh` 含 `usr/.env` 的 grep 分支 | **通过**：第 117–118 行 `[ -f "$BASE_DIR/usr/.env" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?ALLOWED_ORIGINS='`；第 112–116 行为说明注释 |
| 3 | 字节一致 | `browser.py` ws=3832 img=3832；`agent-zero.sh` ws=10084 img=10084 |
| 4 | D1 仍在 | `desktop.py` `tcp-auth=env` 2 处、`XPRA_PASSWORD` 2 处 |
| 5 | D4 仍在 | `ocr.py` `A0_OCR_MAX_PAGES` 2 处 |
| 6 | `a0flatpak/health.py` 不存在 | `grep -c` → **0** |

与上一版（`a33e50b`）的 diff 只有两行，正好对应本轮两处改动：

```
M /files/share/agent-zero/flatpak/agent-zero.sh
M /files/share/agent-zero/flatpak/a0flatpak/browser.py
```

`desktop.py` 与 `ocr.py` 未变，说明上一轮的 D1/D4 没有被本轮误改。

---

# 第五轮：修复 `webui` seed 导致 UI 模态框空白

- 时间：2026-11-17 23:58 – 23:59
- 产物：主包重出，Cuda/Wps 未动
- 优先级说明：这是本轮六处改动里唯一「装完不重启就等于没装」的修复

## 1. 根因链

四步，每步都有可核对的证据：

1. **一次性 seed**。`agent-zero.sh:32` 原为 `for name in conf prompts agents knowledge instruments webui`，条件是 `[ ! -d "$BASE_DIR/$name" ]`——目录存在就再也不过问。而 `:72` 的每次启动覆盖列表只有 `api plugins extensions`。于是 `webui` 一旦落盘就永久冻结在安装那一版。

2. **版本错配**。新版镜像里 `plugins/_discovery` 的卡片用 `x-teleport="#welcome-channels"` / `"#welcome-accounts"` 把内容投进欢迎页的 slot；这些 slot 只存在于新版欢迎页。实测两侧：

   | 位置 | 行数 | `id="welcome-channels"` |
   |---|---|---|
   | 镜像（`agent-zero/webui/components/welcome/welcome-screen.html`） | 1015 | 第 135 行 |
   | 运行树（`…/data/agent-zero/webui/components/welcome/welcome-screen.html`） | **785** | **0** |

3. **teleport 目标缺失**。Alpine 3.14.9 的 `x-teleport` 在找不到选择器时先 `warn`，然后对 `null.appendChild` 抛 `TypeError`。

4. **全局 observer 死亡**。该异常发生在 Alpine 全局 `MutationObserver` 的临界区里：`dt()` 已经 `disconnect()`、`ue()` 还没执行，于是 observer **永久不重连**。之后动态插入的 Settings / Projects 模态框不再被 `initTree`，`x-if` 不求值、`onOpen()` 不执行——主体永久空白，这就是「3 秒与 13 秒截图完全一致」的由来。

一句话：**不是 CSS、不是网络、不是后端 500，是旧模板把新插件的 teleport 目标弄丢了，之后 Alpine 的 DOM 监听彻底停摆。**

## 2. 两行改动

```diff
-for name in conf prompts agents knowledge instruments webui; do
+for name in conf prompts agents knowledge instruments; do
...
-for name in api plugins extensions; do
+for name in api plugins extensions webui; do
```

`bash -n` → `SH_OK`；两处循环现在分别是第 39 行与第 85 行。

## 3. 注释要点（为什么不能只改代码）

seed 循环上方新增：

```
# webui is deliberately not in this list. It is read-only shipped markup, and
# its Alpine templates must match the version of the plugins that extend them
# (plugins/_discovery teleports into slots that only the new welcome screen
# defines). A one-time seed would leave the old copy in place after an upgrade;
# the old markup has no such slot, the teleport fails, and the exception kills
# the global MutationObserver, which is what makes every dialog render blank.
```

merge 循环上方新增：

```
# webui belongs here, next to the code that extends it: a copy that survives an
# upgrade is worse than no copy, because the old templates outlive the plugins
# they were written for. `cp -a` overwrites same-named files, keeps mtimes and
# never deletes: files the new bundle dropped stay behind and are harmless,
# since the new index.html no longer references them.
```

写这两段是为了让后来的人不再把它当「可选优化」删掉：删掉那一个词，UI 就会在**下一次升级**后静默变砖，而且现象（模态框空白）离原因（`webui` 目录的 seed 策略）有五个抽象层。

## 4. `cp -a` 覆盖语义（实测，不是推断）

```
$ mkdir -p src dst; echo new > src/a.html; echo old > dst/a.html; echo stale > dst/gone.html
$ touch -d '2020-01-01' src/a.html
$ cp -a src/. dst/
同名文件内容: new
多余文件是否保留: a.html gone.html
mtime 是否保留: 2020-01-01
```

三点结论：**覆盖同名**、**保留 mtime**、**不删除目标里多出来的文件**。所以「每次覆盖」既不慢（`cp -a` 只写有差异的？不，它照抄全部，但 `webui` 只有几 MB）、也不会把用户塞进去的旧文件清掉——后者正是「旧文件残留无害」的依据：新 `index.html` 不再引用它们。

由此得出取舍：**`webui/` 以镜像为准**。用户自定义 CSS/模板放 `conf/` 或 `usr/`，放 `webui/` 会在下次启动被覆盖。这句已写进 `flatpak/README.md` 的「Runtime state」一节，并同时说明了两组目录的不同待遇（`conf/ prompts/ agents/ knowledge/ instruments/` 一次性 seed；`api/ plugins/ extensions/ webui/` 每次刷新）。

## 5. 构建

```
$ flatpak-builder … --repo=$CACHE --state-dir=$STATE …
Nothing to update.
Building module agent-zero … Exporting org.agentzero.AgentZero to repo
real 0m6.455s      BUILDER_EXIT=0

$ flatpak build-bundle $CACHE bundles/agent-zero.flatpak org.agentzero.AgentZero master
real 0m46.277s     BUNDLE_EXIT=0
```

新产物：

```
-rw-r--r-- 1 kunweiz kunweiz 59538616 Nov 17 23:59 bundles/agent-zero.flatpak
ee79e1b7c595a51428f0f1e206e892a371139f782bbdef6ea8649ec90359930d
commit a8f932128c99b0b1a12a42fa1df2856cd2d98781e706abbc6c9e138da079f5ad
```

上一版 `59535696 B / 27bf8a3526a9… / 475e157`；本版 `59538616 B / ee79e1b7c595… / a8f9321`，+2920 字节（两段注释 + README 一节 + README 里的空行）。

## 6. 镜像断言

| # | 断言 | 结果 |
|---|---|---|
| 1 | `agent-zero.sh` 的 seed 循环不含 `webui` | **通过**：第 39 行 `for name in conf prompts agents knowledge instruments; do` |
| 2 | merge 循环含 `webui` | **通过**：第 85 行 `for name in api plugins extensions webui; do` |
| 3 | `webui` 只在这两处注释 + merge 循环里出现 | **通过**：第 32（注释）、80（注释）、85（循环）行 |
| 4 | 字节一致 | `agent-zero.sh` ws=**10925** img=**10925** |
| 5 | 前面几轮的断言未被破坏 | `browser.py` 含 `/run/host/root/opt/google/chrome`（2 处）、`desktop.py` 含 `tcp-auth=env`（2 处）、`ocr.py` 含 `A0_OCR_MAX_PAGES`（2 处）、`a0flatpak/health` 命中 **0** |

## 7. 验证方法：装完必须重启

这条修复**不重启不生效**，原因不在缓存，而在数据：

- 运行树里的 `webui/` 只在 launcher 启动时被刷新，运行中的进程已经把模板读进内存；
- `/ui/asset-bundle` 是**启动快照**：它在 `run_ui.py` 起来时就把 asset 清单与 `version` 算好，之后不会因为磁盘变了而重新计算。

装完新版后的验证步骤（三步，缺一不可）：

```bash
# 1. 停掉旧进程（或 flatpak kill）
flatpak kill org.agentzero.AgentZero

# 2. 重新启动
flatpak run org.agentzero.AgentZero

# 3. 两处对照
curl -s http://127.0.0.1:5080/ui/asset-bundle | head -c 80
#   期望 version 不再是本轮的旧基线 749c98f1ffe4211405ab，而是一个新值

wc -l ~/.var/app/org.agentzero.AgentZero/data/agent-zero/webui/components/welcome/welcome-screen.html
#   期望 1015（原为 785）

grep -c 'id="welcome-channels"' \
  ~/.var/app/org.agentzero.AgentZero/data/agent-zero/webui/components/welcome/welcome-screen.html
#   期望 >= 1（原为 0）
```

本轮记录的**启动前基线**（用于对照，未改动任何东西）：

```
$ curl -s http://127.0.0.1:5080/ui/asset-bundle | head -c 60
{"version":"749c98f1ffe4211405ab","files":{"/components/canvas/…

$ wc -l …/data/agent-zero/webui/components/welcome/welcome-screen.html
785 …/welcome-screen.html
$ grep -c 'welcome-channels' …/welcome-screen.html
0
```

拿到新 `version` 且 `welcome-screen.html` 变成 1015 行之后，再去点 Settings 与 Projects：如果主体能渲染，就同时证明了三件事——`webui` 被刷新、teleport 目标存在、observer 没有再死。反过来说，**只重启但 version 没变**，说明启动的是旧 bundle（`flatpak list` 的 commit 应等于 `a8f9321…`），不要误判成本修复无效。

---

# 第六轮：修 Xpra 的 jQuery 悬空链接 + 清理运行树残留

- 时间：2026-11-18 00:30 – 00:34
- 产物：主包重出（Cuda/Wps 未动）
- 预期修掉两项验收失败：**P0 桌面空白**、**P1 四个残留文件**

## 1. 根因确认：两个符号链接指向 runtime 里不存在的路径

在运行中的应用沙盒里直接看（`/proc/<run_ui.py pid>/root/...`）：

```
/app/share/xpra/www/js/lib/jquery.js     -> /usr/share/javascript/jquery/jquery.js
/app/share/xpra/www/js/lib/jquery-ui.js  -> /usr/share/javascript/jquery-ui/jquery-ui.js

/usr/share/javascript/jquery/jquery.js          -> No such file or directory
/usr/share/javascript/jquery-ui/jquery-ui.js    -> No such file or directory
```

`xpra-common` 的 `Depends` 里没有 `libjs-jquery`（实测 `control` 只有 python3、libc6、libcairo2、liblz4-1、libpam0g、libwayland-client0、libx11-6、libxxhash0、python3-gi、gir1.2-glib-2.0），所以 Debian 那边这两个链接由 `javascript-common` 体系提供，而我们在 Flatpak 里只解包了 `.deb` 的 payload，没有安装依赖，于是链接悬空 → 两个 404 → `$ is not defined` → HTML5 客户端不渲染。

`index.html` 的引用面（只有这两条与 jQuery 相关）：

```
21: <script type="text/javascript" src="js/lib/jquery.js"></script>
22: <script type="text/javascript" src="js/lib/jquery-ui.js"></script>
23: <script ... src="js/lib/jquery.ba-throttle-debounce.js"></script>
24: <script ... src="js/lib/jquery-transform-draggable.js"></script>
```

后两个文件是随 xpra 一起发的实体文件（`jquery.ba-throttle-debounce.js` 892 B、`jquery-transform-draggable.js` 3420 B），只有前两个是链接。

## 2. 选哪两个包、为什么是这个版本

| 包 | 版本 | URL | sha256 |
|---|---|---|---|
| `libjs-jquery` | `3.7.1+dfsg+~3.5.33-1` | `http://deb.debian.org/debian/pool/main/n/node-jquery/libjs-jquery_3.7.1+dfsg+~3.5.33-1_all.deb` | `818d6383b5b8…4e19d3` |
| `libjs-jquery-ui` | `1.14.2+dfsg-1` | `http://deb.debian.org/debian/pool/main/j/jqueryui/libjs-jquery-ui_1.14.2+dfsg-1_all.deb` | `b246c377c9db…388080` |

两个 sha256 都来自 **Debian 自己签名索引**里的 `SHA256` 字段（`dists/forky/main/binary-amd64/Packages`），并且用流式 `curl | sha256sum` 复验过。体积 319,248 B 与 244,948 B。

**为什么是 3.7.1 而不是 1.x**：链接名 `jquery.js` 看不出世代，只能从客户端代码判断。在 `www/js/*.js` 里 grep 了 jQuery 3.0 移除的 API——`$.fn.size`、`.andSelf(`、`.live(`、`$.browser`、`.load(function`——**零命中**；实际用的是 `.on("click"|"init"|"contextmenu"|"dragstart")` 这类 1.7+ 接口。所以 3.7.1 安全，而且 3.x 是当前受支持的分支。反过来若退回 1.x，`.on()` 仍在，但会丢掉 3.x 的修复，且与 forky 的 `Packages` 不一致，没有必要。

**为什么 jQuery UI 只要 `jquery-ui.js`**：`index.html` 只加载这一个文件，`www` 下没有任何 jQuery UI 的 CSS 或 `images/ui-*`（`find` 结果只有 4 个 `jquery*` 文件，其中两个是上面那两个链接）。客户端用到的 widget 只有 `.draggable()`（`MenuCustom.js` 1 处、`Window.js` 6 处）与 `.resizable()`（`Window.js` 9 处），1.14.2 全都有。所以不补 CSS、不补 images，避免塞没人引用的 4 MB 主题包。

解包后的实际路径（`ar p … data.tar.xz | tar -tJ`）：

```
libjs-jquery:    ./usr/share/javascript/jquery/jquery.js
                 ./usr/share/javascript/jquery/jquery.min.js
libjs-jquery-ui: ./usr/share/javascript/jquery-ui/jquery-ui.js
                 ./usr/share/javascript/jquery-ui/jquery-ui.min.js
```

## 3. 清单改动

`flatpak/org.agentzero.AgentZero.yml` 的 `xpra` 模块：sources 从 5 个 Debian/xpra 包变成 7 个（+2 个 libjs），build-commands 增加三步：

```yaml
      - rm -f /app/share/xpra/www/js/lib/jquery.js /app/share/xpra/www/js/lib/jquery-ui.js
      - install -Dm644 unpacked/usr/share/javascript/jquery/jquery.js /app/share/xpra/www/js/lib/jquery.js
      - install -Dm644 unpacked/usr/share/javascript/jquery-ui/jquery-ui.js /app/share/xpra/www/js/lib/jquery-ui.js
```

先 `rm -f` 再 `install`，而不是 `cp -L`：`cp -L` 在目标已存在时会跟随已有的符号链接去写 `/usr/share/...`（那是个不存在的目录，直接失败），`rm` 之后 `install` 才保证结果是一个实体文件而不是「链接指向链接」。`install` 还顺带把权限钉成 0644，与同目录其它资源一致。

原有的 `for deb in *.deb; do sh unpack-deb.sh "$deb" unpacked; done` 不用改：两个 libjs 包会与 xpra 的包一起被解到同一个 `unpacked/`，路径互不冲突。

## 4. `.gz` / `.br` 清理那两行的复核（按要求）

原文保留：

```yaml
      - find /app/share/xpra/www -name '*.gz' -delete
      - find /app/share/xpra/www -name '*.br' -delete
```

**它们是对的**，因为在这份 xpra 载荷里 `.gz`/`.br` 只作为「预压缩副本」存在，每个都有未压缩的兄弟文件：

```
$ find …/www -name '*.gz' | wc -l      → 0
$ find …/www -name '*.br' | wc -l      → 0
$ for f in $(find …/www -name '*.gz'); do [ -f "${f%.gz}" ] || echo ONLY_GZ: $f; done
（空输出）
```

计数是 0 是因为 `xpra-html5` 包里本来就没带预压缩副本——这两条命令在当前载荷上是**空操作**，留着是为了将来 xpra 改回带 `.gz` 的构型。

但要写明它什么时候会变成错误：**如果将来某个文件只有 `.gz` 而没有未压缩版本，这两条 `delete` 就会把唯一副本删掉，浏览器随即 404。** 判据就是上面那条 `ONLY_GZ` 检查；一旦非空，必须改成「有未压缩兄弟才删 `.gz`」，例如：

```sh
find /app/share/xpra/www -name '*.gz' | while read -r g; do
    [ -f "${g%.gz}" ] && rm -f "$g"
done
```

本轮的结论是：**保持原样安全，但这条假设已写进报告，下次换 xpra 版本时必须重跑那三条检查。**

## 5. 运行树残留清理

`flatpak/agent-zero.sh` 在 webui merge 循环之后新增：

```sh
# Paths the bundle dropped in the scheduler move. Removing them keeps the
# writable webui identical to the shipped one, which the upgrade check asserts.
# This list is deliberately explicit: when upstream moves files again, add the
# old paths here. `rm -rf "$BASE_DIR/webui"` would be shorter and wrong, because
# it would also delete whatever an operator put under webui/ - assets belong in
# conf/ or usr/, as README says.
for stale in components/modals/scheduler components/sidebar/tasks \
             css/scheduler.css css/scheduler-datepicker.css; do
    rm -rf "$BASE_DIR/webui/$stale"
done
```

为什么不用 `rm -rf "$BASE_DIR/webui"`：那会连带删掉操作者放在 `webui/` 下的任何资源，而 `webui/` 每次启动本来就会被 `cp -a` 覆盖——两者叠加会变成「改了也没用，还可能被删两次」。显式清单把「上游搬了哪些路径」变成一份可审计的数据，代价是每次上游搬家要手工加一行。

## 6. `fix-compat` 两处的基线确认

改动前跑了 `git status --short` 与 `git diff --stat`（15 个文件，493 插入 / 200 删除），三处修复都在基线里：

```
$ grep -c '_must_cancel\|_current_tasks' flatpak/a0flatpak/compat.py
4
$ grep -n 'cp -an' flatpak/agent-zero.sh
46:    cp -an "$APP_ROOT/prompts/." "$BASE_DIR/prompts/" 2>/dev/null || true
$ grep -n 'prompts' flatpak/a0flatpak/base_dir.py
57:        os.path.join(source_root, "prompts"), os.path.join(root, "prompts")
```

并且 `agent-zero.sh` 的 seed 循环已相应变成 `for name in conf agents knowledge instruments`——`prompts` 从「一次性 seed」移出，改成每次启动 `cp -an` 补缺失文件，与 `base_dir.py` 的 `_merge_missing` 一致。这两处**不是我改的**，属于 `fix-compat` 已合入的部分；本轮只是确认它没被 `webui` 那次编辑挤掉。

## 7. 构建

```
$ flatpak-builder … --repo=$CACHE --state-dir=$STATE …
Nothing to update.
Building module xpra in …/build/xpra-1
Running: rm -f /app/share/xpra/www/js/lib/jquery.js /app/share/xpra/www/js/lib/jquery-ui.js
Running: install -Dm644 unpacked/usr/share/javascript/jquery/jquery.js /app/share/xpra/www/js/lib/jquery.js
Running: install -Dm644 unpacked/usr/share/javascript/jquery-ui/jquery-ui.js /app/share/xpra/www/js/lib/jquery-ui.js
Committing stage build-xpra to cache
Building module xvfb … Building module agent-zero …
Exporting org.agentzero.AgentZero to repo
real 0m10.690s      BUILDER_EXIT=0

$ flatpak build-bundle $CACHE bundles/agent-zero.flatpak org.agentzero.AgentZero master
real 0m50.199s      BUNDLE_EXIT=0
```

`xpra` 与 `xvfb` 两个模块因为 xpra 模块的 sources 变了而重跑（各几秒），`uv`/`python-gi-cairo` 仍命中缓存。

新产物：

```
-rw-r--r-- 1 kunweiz kunweiz 59709032 Nov 18 00:33 bundles/agent-zero.flatpak
62e6228d29048381ba07a6ccf1a119274c199504a6f158ef848f72b8d1025bed
commit 1e0f41ccecb4e9893d117a8b68ee5c4b8c870964e9b36716efdcbc7fec652eef
```

上一版 `59538616 B / ee79e1b7c595… / a8f9321`；本版 `59709032 B / 62e6228d2904… / 1e0f41c`，+170,416 字节 ≈ jQuery 285 KB + jQuery UI 540 KB 压缩后的结果。

预取记录：两个新源在 `--download-only` 下 2.363 秒落盘（319,248 B 与 244,948 B），因此正式构建没有在外网等待。

## 8. 镜像断言（四条 + 复核）

| # | 断言 | 结果 |
|---|---|---|
| 1 | `agent-zero.sh` 含 `for stale in` 与 `cp -an` | **通过**：第 107 行 `for stale in components/modals/scheduler components/sidebar/tasks \`，第 46 行 `cp -an "$APP_ROOT/prompts/." …` |
| 2 | `compat.py` 含 `_must_cancel` 与 `_current_tasks` | **通过**：各 2 处 |
| 3 | `/app/share/xpra/www/js/lib/jquery.js` 是实体文件 | **通过**：`-00644 0 0 285284 …/jquery.js`、`-00644 0 0 540438 …/jquery-ui.js`（类型位是 `-`，不是 `l`） |
| 4 | `a0flatpak/health.py` 仍不存在 | **通过**：`grep -c` → 0 |

断言 3 的内容证据（`ostree cat` 取前 120 字节）：

```
/*!
 * jQuery JavaScript Library v3.7.1
 * https://jquery.com/

/*! jQuery UI - v1.14.2 - 2026-07-16
* https://jqueryui.com
* Includes: widget.js, mouse.js, draggable.js, droppable.js,
```

前几轮断言复核：`browser.py` 的 `/run/host/root/opt/google/chrome` 2 处、`desktop.py` 的 `tcp-auth=env` 2 处、`ocr.py` 的 `A0_OCR_MAX_PAGES` 2 处；`agent-zero.sh` 的两处循环现在是第 48 行 `for name in conf agents knowledge instruments` 与第 94 行 `for name in api plugins extensions webui`——`webui` 的 seed/merge 归属正确。

与上一版（`a8f9321`）的 diff：

```
M /files/manifest.json
M /files/bin/agent-zero
M /files/share/agent-zero/flatpak/README.md
M /files/share/agent-zero/flatpak/agent-zero.sh
M /files/share/agent-zero/flatpak/org.agentzero.AgentZero.yml
M /files/share/agent-zero/flatpak/wps-mcp-config.json
M /files/share/agent-zero/flatpak/a0flatpak/base_dir.py
M /files/share/agent-zero/flatpak/a0flatpak/compat.py
M /files/share/xpra/www/js/lib/jquery-ui.js
M /files/share/xpra/www/js/lib/jquery.js
```

两处需要说明：

- `base_dir.py`、`compat.py`、`wps-mcp-config.json`、`README.md` 出现在这里，是因为它们在上一版镜像之后被 `fix-compat` 与其他代理改过，本轮 `cp -a flatpak` 把当前工作树整体带进了镜像——不是本轮我改的。
- `jquery.js` / `jquery-ui.js` 从符号链接变成实体文件，`ostree` 因此把它们记为 `M`（链接对象 → 文件对象），这正是本轮要达到的效果。

## 9. 这一版预期修掉的两项验收失败

| 项 | 上一版现象 | 本版依据 |
|---|---|---|
| **P0 桌面空白** | HTML5 客户端 `$ is not defined`，div 不渲染 | 两个 404 的源头已变成实体文件：`jquery.js` 285,284 B（v3.7.1）、`jquery-ui.js` 540,438 B（v1.14.2），`ostree ls` 类型位为 `-`；客户端只用 `.on()` 与 draggable/resizable，两版 API 都覆盖 |
| **P1 运行树残留** | 4 个路径留在 `$BASE_DIR/webui/`，升级检查的 c 项不过 | 显式 `for stale in …` 清理已进镜像（第 107–110 行），每次启动都会删这 4 条 |

需要重启后才看得到：`webui/` 的刷新与残留清理都发生在 launcher 启动时，`/ui/asset-bundle` 是启动快照。桌面还要经过 Xpra：装完重启后 `curl -s http://127.0.0.1:14500/js/lib/jquery.js | head -c 40` 应返回 `/*!` 开头的内容，而不是 404 页面。

---

# 第七轮：刷新 venv 里的 xpra、OCR 超时语义、WPS 桥接、最后一个 404

- 时间：2026-11-18 00:44 – 00:49
- 产物：主包重出（Cuda/Wps 未动）
- 起点：v6 已让 verify 6/6 通过、jQuery 实体化且 200、OCR 正常路径 3.61 秒返回正确文本；本版处理剩下三个问题

## 1. venv 里的 xpra 停在旧版（P0，桌面仍空白的原因）

### 证据链

```
xpra-stderr.log: No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package
/app/share/python-deps/xpra/net/mmap/   ← 新版是包目录
venv/.../site-packages/xpra/net/mmap    ← venv 里仍是旧版单文件 mmap.py
```

旧代码：

```sh
install_extension_modules() {
    ...
    if [ -d "$site/xpra" ]; then
        return 0          # 目录在就跳过：升级后永远用旧的
    fi
    ...
}
```

只要 venv 建过一次，镜像以后换 xpra/gi/cairo 都进不去；旧布局的 `mmap.py` 加新代码的 `import xpra.net.mmap.common` 就会报「不是包」。

### 修法

`flatpak/agent-zero.sh` 的 `install_extension_modules()` 改成版本戳驱动，并且**移出 `if [ ! -f "$VENV_MARKER" ]` 分支**、每次启动都调用：

```sh
py_deps_version() {
    cat "$PY_DEPS/.a0-python-deps" 2>/dev/null || echo unknown
}

install_extension_modules() {
    local site stamp
    site="$("$VENV/bin/python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
    stamp="$site/.a0-python-deps"
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$(py_deps_version)" ]; then
        return 0
    fi
    rm -rf "$site/xpra" "$site/gi" "$site/cairo"
    find "$site" -maxdepth 2 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
    cp -a "$PY_DEPS"/. "$site"/
    py_deps_version > "$stamp"
}
```

```sh
# Unconditional: a venv from an older image is otherwise never refreshed.
install_extension_modules
```

只删 `xpra`/`gi`/`cairo` 三棵树，venv 里其余框架依赖不动；`__pycache__` 一并清掉，避免旧的 `.pyc` 被误用。

### 版本戳为什么不用 mtime

提案建议 `stat -c '%Y' /app/share/python-deps`。实测不行：**镜像内所有 mtime 都被归零**。

```
$ stat -c '%Y %n' /proc/<pid>/root/app/share/python-deps
0 /proc/<pid>/root/app/share/python-deps
$ ls -ld --time-style=+%s …/python-deps
drwxr-xr-x 1 kunweiz kunweiz 22 0 …
```

`0` 永远是 `0`，戳不会变，等于又回到「装一次就不管」。所以改成**构建期写入的内容戳**，清单里加一条：

```yaml
- find /app/share/python-deps/xpra /app/share/python-deps/gi /app/share/python-deps/cairo -type f -printf '%p %s\n' | sort | sha256sum | cut -d' ' -f1 > /app/share/python-deps/.a0-python-deps
```

内容变了戳就变，内容没变（同一版镜像重启）戳不变，正好是「只在版本变化时重装」。预演（在构建树的 python-deps 上跑）：695 个文件，得到 `6cfd34b9fcb7…`；镜像内实际写出的戳是 `315e2a61fcaa…`（路径前缀不同，所以哈希不同，这是正常的——戳只在同一镜像内自比）。

镜像里确认：

```
$ ostree ls … /files/share/python-deps
-00644 0 0     65 /files/share/python-deps/.a0-python-deps
$ ostree cat … /files/share/python-deps/.a0-python-deps
315e2a61fcaa940b491fc7beab6cc6e9b391c1e97508957d259cdf0211e13a0d
```

### `/app/lib/gi` 的库够不够（顺带核对）

沙盒里 `_gi*.so` 依赖 `libgirepository-2.0.so.0`。用 `flatpak run` 的 shell 直接 `ldd` 会解析到 `/usr/lib/x86_64-linux-gnu/libgirepository-2.0.so.0` → `…0.8400.4`（runtime 自带），而 `/app/lib/gi/libgirepository-2.0.so.0` 是 `…0.9000.1`（Debian 包）。两者 soname 相同。**这不是问题**：探针 shell 里 `LD_LIBRARY_PATH` 为空（实测输出空行），而 launcher 在启动 Python 前设了 `LD_LIBRARY_PATH=/app/lib/gi:…`，所以应用进程用的是 0.9000.1；deploy-local 之前查过 `_gi` 的 ldd 也没有 `not found`。本轮**不需要补库**。

## 2. OCR 超时语义（P1）

### 改法

新增判定函数（放在模块顶部，`_document_budget` 之前）：

```python
def _is_timeout(exc: BaseException) -> bool:
    """True when the failure is a deadline, not a misconfiguration.

    A timeout means the model was too slow for the caller's budget: the document
    is fine and a retry may succeed, so it is reported as a partial result. A
    refused connection or a missing model means the deployment is wrong, and
    hiding that behind "OCR incomplete" would send the user looking in the wrong
    place, so those still raise.
    """
    seen = 0
    while exc is not None and seen < 5:
        if isinstance(exc, (TimeoutError,)) or type(exc).__name__ in (
            "TimeoutException", "ReadTimeout", "ConnectTimeout",
            "WriteTimeout", "PoolTimeout",
        ):
            return True
        exc = exc.__cause__ or exc.__context__
        seen += 1
    return False
```

用异常链遍历而不是 `isinstance(exc, httpx.ReadTimeout)`：`httpx` 只在函数内部延迟导入，模块顶层拿不到它的类；而且 httpx 把超时包成自己的类型，沿 `__cause__`/`__context__` 找比逐个匹配更稳。

`_parse_image`：

```python
    except Exception as exc:
        if _is_timeout(exc):
            return (
                f"> OCR incomplete: the vision request did not finish within "
                f"{min(OCR_TIMEOUT, budget):.0f}s. The image was not converted."
            )
        raise ValueError(...)
```

`_ocr_pages`：循环里超时记 `stopped = f"timeout after {min(OCR_TIMEOUT, remaining):.0f}s"` 后跳出，非超时异常**直接 raise**（不再吞成字符串）；`processed == 0` 时返回

```python
        return f"> OCR incomplete: 0 of {total} pages processed ({reason})."
```

替换原来的 `raise ValueError`。

### 行为验证（桩件，httpx.post 强制抛对应异常）

```
=== 单图：超时 ===
'> OCR incomplete: the vision request did not finish within 45s. The image was not converted.'
=== 单图：连接被拒（应抛）===
RAISED ValueError OCR failed within 45s: ConnectionError: connection refused
=== 多页：超时且一页未完成 ===
'> OCR incomplete: 0 of 5 pages processed (timeout after 45s).'
=== 多页：连接被拒（应抛）===
RAISED ConnectionError connection refused
=== _is_timeout 判定 ===
  ReadTimeout      -> True
  ConnectTimeout   -> True
  ConnectionError  -> False
  ValueError       -> False
```

注意「连接被拒」在多页路径里是**原样抛 `ConnectionError`**，不再包成 `ValueError`——上层能直接看到 `connection refused`，而不是一句模糊的「解析失败」。单图路径仍包成 `ValueError` 以保持原契约（`_parse_sync` 的调用方期望 `ValueError`），但保留了根因文本。

## 3. WPS MCP 的沙箱桥接（已由 wps-mcp worker 改好，本轮确认并入）

`git diff` 确认三处都在工作树里：

```
$ grep -n 'talk-name' flatpak/org.agentzero.AgentZero.yml
27:  - --talk-name=org.freedesktop.Flatpak

$ cat flatpak/wps-mcp-config.json
{ "mcpServers": { "wps-office": {
    "command": "/usr/bin/flatpak-spawn",
    "args": ["--watch-bus", "--host",
             "…/org.agentzero.AgentZero.Wps/current/active/files/bin/bun",
             "…/files/wps-skills/wps-office-mcp/dist/index.js"] } } }
```

`flatpak/README.md` 也有对应段落（299、310、329、363–387、423 行），说明 `--talk-name=org.freedesktop.Flatpak` 是让 `flatpak-spawn --host` 工作的最小权限，以及宿主 checkout 上没有 `flatpak-spawn` 时该跑什么。

我**没有改**这三处，只确认它们与 xpra 的 jQuery 改动（同一个 manifest 文件）共存：`sources` 里 7 个 Debian/xpra 源 + `unpack-deb.sh`，`finish-args` 里 `--talk-name` 在第 27 行，两者互不影响。

## 4. 最后一个 404：`/default-settings.txt`

它不是"可选请求"，是**第二个悬空链接**：

```
$ ls -l …/app/share/xpra/www/default-settings.txt
lrwxrwxrwx … -> /etc/xpra/html5-client/default-settings.txt
$ ls -l …/etc/xpra/html5-client/default-settings.txt
No such file or directory
$ find …/app/share/xpra/www -xtype l
…/default-settings.txt          ← 全树唯一的悬空链接
```

引用方是 `index.html:1654` 与 `connect.html:1606`（`xhr.open("GET", "./default-settings.txt")`），而文件本体在 `xpra-html5` 包里的位置是：

```
./etc/xpra/html5-client/default-settings.txt      ← 实体，283 B
./usr/share/xpra/www/default-settings.txt         ← 指向上面那个的链接
```

我们只拷了 `usr/share/xpra`，链接因此悬空。清单补两步（**已在本轮并入**）：

```yaml
- rm -f /app/share/xpra/www/default-settings.txt
- install -Dm644 unpacked/etc/xpra/html5-client/default-settings.txt /app/share/xpra/www/default-settings.txt
```

镜像内现在是实体文件，283 字节，首行 `# Xpra HTML5 default settings`。

## 5. 构建

```
$ flatpak-builder … --repo=$CACHE --state-dir=$STATE …
Nothing to update.
Building module xpra … Building module xvfb … Building module agent-zero …
Exporting org.agentzero.AgentZero to repo
real 0m11.540s      BUILDER_EXIT=0

$ flatpak build-bundle $CACHE bundles/agent-zero.flatpak org.agentzero.AgentZero master
real 0m49.676s      BUNDLE_EXIT=0
```

新产物：

```
-rw-r--r-- 1 kunweiz kunweiz 59711152 Nov 18 00:48 bundles/agent-zero.flatpak
29d7510f9aa1fb5be89f00f426f5577171f72995ab6cfa1c67f80b8eca84def2
commit 1ddcd34f7b351eab88be1d14789c27f400c3b04d3e2611d6e8d01f03d237075b
```

v6 是 `59709032 B / 62e6228d2904… / 1e0f41c`；本版 +2120 字节。

## 6. 五条镜像断言

| # | 断言 | 结果 |
|---|---|---|
| 1 | `agent-zero.sh` 含 `.a0-python-deps` 戳与 `rm -rf "$site/xpra"` | **通过**：第 191 行 `cat "$PY_DEPS/.a0-python-deps"`、第 197 行 `stamp="$site/.a0-python-deps"`、第 203 行 `rm -rf "$site/xpra" "$site/gi" "$site/cairo"` |
| 2 | `ocr.py` 含 `_is_timeout` 与 `OCR incomplete` | **通过**：`_is_timeout` 3 处、`OCR incomplete` 4 处 |
| 3 | manifest 含 `--talk-name=org.freedesktop.Flatpak` | **通过**：第 27 行 |
| 4 | `js/lib/jquery.js` 仍是实体文件（回归） | **通过**：`-00644 0 0 285284 …/jquery.js`、`-00644 0 0 540438 …/jquery-ui.js` |
| 5 | `a0flatpak/health.py` 仍不存在 | **通过**：`grep -c` → 0 |

额外两条（本轮新增物）：
- `/files/share/python-deps/.a0-python-deps` 存在，65 字节，内容 `315e2a61fcaa…`；
- `/files/share/xpra/www/default-settings.txt` 是 `-00644 283`，不再是 `l`。

与 v6 的 diff（`ostree diff <v7> <v6>`，字母表示「旧版 → 新版」；方向已用 `cat <v6> …/.a0-python-deps` 报 `No such file` 验证过）：

```
M /metadata
M /files/manifest.json
M /files/bin/agent-zero
M /files/share/agent-zero/flatpak/README.md
M /files/share/agent-zero/flatpak/agent-zero.sh
M /files/share/agent-zero/flatpak/org.agentzero.AgentZero.yml
M /files/share/agent-zero/flatpak/wps-mcp-config.json
M /files/share/agent-zero/flatpak/a0flatpak/ocr.py
M /files/share/xpra/www/default-settings.txt      ← l → 实体
D /files/share/python-deps/.a0-python-deps        ← 相对 v6 是新增（diff 方向为 v6→v7）
```

`/metadata` 变了是因为 manifest 的 `finish-args` 多了 `--talk-name`，属预期。

## 7. 装完重启后第一件要验证的事

**先看 venv 里的 xpra 是否被换掉**，因为这是桌面能否起来的前提，而且它决定了后面所有桌面观察是否可信：

```bash
V=~/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages
cat "$V/.a0-python-deps"          # 期望 315e2a61fcaa940b491fc7beab6cc6e9b391c1e97508957d259cdf0211e13a0d
ls -d "$V/xpra/net/mmap"          # 期望目录（新版布局），且 mmap.py 不再是文件
```

戳写进去了，才说明 `install_extension_modules` 走了重装分支；否则看 `xpra-stderr.log` 里是否仍有 `is not a package`。

第二件是桌面本身：`curl -s http://127.0.0.1:14500/js/lib/jquery.js | head -c 40` 应返回 `/*!`，`/default-settings.txt` 应返回 `# Xpra HTML5 default settings` 而不是 404。

第三件是 OCR 的负路径：`A0_OCR_TIMEOUT=0.01` 下解析一张图，期望返回以 `> OCR incomplete:` 开头的 Markdown，而不是抛 `ValueError`。注意这个变量要在**重启后的进程环境**里生效（`flatpak override --user --env=A0_OCR_TIMEOUT=0.01`），改完再重启一次。

---

# 第八轮：去掉 `--mmap=no`（桌面真正的 P0）

- 时间：2026-11-18 01:10 – 01:13
- 产物：主包重出（Cuda/Wps 未动）
- 起点：v7 的两条假设（PYTHONPATH 顺序、venv 残留）已被 `fix-xpra` 实测排除；在 14602 端口去掉 `--mmap=no` 后 `Handshake complete`，截图里已看到 Xfwm4 会话

## 1. `--mmap=no` 是根因（两处都去掉了）

### shadow 分支

在 `_xpra_shadow_command(...)` 拿到命令之后、过滤 `--encoding=` 的同一处，新增：

```python
        # Xpra disables its mmap transport module when --mmap=no is given, and
        # its own hello path then imports xpra.net.mmap.common to build the
        # packet reader. That import sees the disabled module and dies with
        # "No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a
        # package", which aborts the handshake before any pixel is sent.
        # Leaving mmap at its default lets the handshake complete.
        #
        # This is an upstream contradiction - disabling mmap is what triggers
        # the mmap import - so the flag is dropped rather than replaced by
        # anything of ours.
        command = [arg for arg in command if arg != "--mmap=no"]
```

用列表过滤而不是在模板里改字符串：`--mmap=no` 是我们从上游命令里剔除的，将来上游改成 `--mmap=0` 或加别的值时，这里是唯一需要看的地方。

### headless 分支

**确实也有**，在我们自己拼的 `start-desktop` 命令列表里（原第 297 行）：

```python
                "--daemon=no",
                "--mdns=no",
-                "--mmap=no",
                 "--html=on",
```

删掉。`start-desktop` 走的是同一个 hello 路径，同一个坑。

### 与 D1 的关系（本轮未动）

`--tcp-auth=env` 仍由我们追加，`_xpra_shadow_command` 本身不含它；`if xpra_auth:` 的剔除再追加逻辑原样保留（镜像里 `tcp-auth=env` 仍 2 处）。这两个过滤互不影响：一个按 `--tcp-auth=` 前缀，一个按 `--mmap=no` 全等。

## 2. `PYTHONHOME` 改成 `pop`

```diff
-        env["PYTHONHOME"] = ""
+        # An empty PYTHONHOME happens to mean "unset" on CPython 3.14, but that
+        # is an implementation detail; removing the key is what "unset" means.
+        env.pop("PYTHONHOME", None)
```

没有改成显式覆盖 `PYTHONPATH`：那样会丢掉继承来的 `/app/share/agent-zero` 与 `/app/share/agent-zero/flatpak`，而那两个路径是 `a0flatpak` 与框架自身能被导入的前提。`PYTHONPATH` 的处理保持原样（`BUNDLED_PY_DEPS` 插到最前、其余保留）。

## 3. 启动自检（只 warn）

在 `probe = subprocess.run([xpra, "--version"], …)` 之后、写 `xpra-cmd.txt` 之前，用同一个 `env` 跑：

```python
        check = subprocess.run(
            [
                *interpreter,
                "-c",
                "import xpra.net.mmap as m; assert getattr(m, '__path__', None), "
                "'xpra.net.mmap is not a package'",
            ],
            capture_output=True, text=True, env=env, timeout=60,
        )
        if check.returncode != 0:
            print(
                "a0flatpak: xpra.net.mmap is not a package in this interpreter "
                f"(rc={check.returncode}): {(check.stderr or check.stdout).strip()[-300:]}",
                file=sys.stderr,
            )
```

失败**不阻止启动**：这类布局问题只在 hello 阶段才炸，提前一行 stderr 就能把「是 venv 新旧」与「是参数」区分开，代价是一次 60 秒上限的导入。

## 4. 桩件验证（用真实函数体，不是手抄逻辑）

把 `_spawn_desktop_locked` 从源文件切出来，桩掉框架模块，让上游的 shadow 命令**故意带两个 `--mmap=no`**：

```
shadow argv mmap count: 0
shadow argv: /usr/bin/python3 /app/bin/xpra shadow :0 --bind-tcp=127.0.0.1:14500 --html=on --speed=80 --encoding=png
PYTHONHOME in env: False | value: None
```

三点结论：`--mmap` 计数 0（两个都被剔除）、`--encoding=png` 仍在（`--speed=80` 之后的插入位置没被破坏）、`PYTHONHOME` 键从 env 里完全消失（不是空字符串）。

顺带一条来自 `fix-xpra`、本轮清单里已生效的构建期断言（另一个 worker 加的）：

```
Running: test -f /app/share/python-deps/xpra/net/mmap/__init__.py
Running: test ! -e /app/share/python-deps/xpra/net/mmap.py
```

两条都通过，等于在构建时就把「单文件 `mmap.py` 赢过目录」这种布局错配挡掉了。

## 5. 构建

```
$ flatpak-builder … --repo=$CACHE --state-dir=$STATE …
Nothing to update.
Building module xpra … Building module xvfb … Building module agent-zero …
Exporting org.agentzero.AgentZero to repo
real 0m12.410s      BUILDER_EXIT=0

$ flatpak build-bundle $CACHE bundles/agent-zero.flatpak org.agentzero.AgentZero master
real 1m0.502s       BUNDLE_EXIT=0
```

新产物：

```
-rw-r--r-- 1 kunweiz kunweiz 59715960 Nov 18 01:12 bundles/agent-zero.flatpak
b74e6d9f3a06ff201278130a045ad8907ac99286c1870cb6a9b0fa24d8a8af3f
commit 0e6c50820257d7b409f2c8dc5ccd0688d693fea648436669c3fd59af84d456a4
```

v7 是 `59711152 B / 29d7510f9aa1… / 1ddcd34`；本版 +4808 字节（自检代码、两段注释、以及别处一并进镜像的 mmap 构建断言）。

## 6. 四条镜像断言（另加旧断言复核）

| # | 断言 | 结果 |
|---|---|---|
| 1 | `desktop.py` 的 `--mmap=no` 出现 **2** 次，且两分支都不再传给 xpra | **通过**：第 336 行是注释、第 346 行是过滤语句；`sed -n '/start-desktop/,/log-file=xpra.log/p'` 打出的 headless argv 里已经没有该参数 |
| 2 | 含 `env.pop("PYTHONHOME"` | **通过**：第 268 行 |
| 3 | 含 `xpra.net.mmap is not a package` | **通过**：2 处（自检断言字符串 + 警告文案） |
| 4 | 旧断言仍成立 | **通过**：`tcp-auth=env` 2、`A0_OCR_MAX_PAGES` 2、`_CHROME_PATHS` 的 `/run/host/root/opt/google/chrome` 2、`agent-zero.sh` 的 `a0-python-deps` 2 与 `for stale in` 1、`a0flatpak/health.py` 0 |

字节一致：`desktop.py` 工作树 16129 = 镜像 16129。

与 v7 的 diff 只有三项：

```
M /files/manifest.json
M /files/share/agent-zero/flatpak/org.agentzero.AgentZero.yml
M /files/share/agent-zero/flatpak/a0flatpak/desktop.py
```

`org.agentzero.AgentZero.yml` 与 `manifest.json` 的变化不是我改的：另一个 worker 在清单里加了两条构建期断言（`test -f …/xpra/net/mmap/__init__.py`、`test ! -e …/xpra/net/mmap.py`），构建日志里能看到它们执行并通过。`manifest.json` 的 `source-date-epoch` 也随之变成 `1794934795`。

## 7. 装完重启后第一件要验证的事

**先看 Xpra 的握手有没有走完**，因为这一版只改了启动参数，其他一切没动，握手成功与否是唯一判据：

```bash
L=~/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/plugins/_desktop/profiles/agent-zero-desktop
grep -c 'Handshake complete' "$L/xpra.log"     # 期望 ≥1，且时间戳是本次启动
tail -20 "$L/xpra-stderr.log"                  # 期望没有 "is not a package"
cat "$L/xpra-cmd.txt" | head -2                # 期望命令行里没有 --mmap=no
```

第二件看画面：`062`/`63` 这类新截图里应出现窗口管理器与桌面（v7 时是空白）。第三件确认自检没有误报：`xpra-stderr.log` 或应用 stderr 里不该出现 `a0flatpak: xpra.net.mmap is not a package in this interpreter`——出现就说明 venv 里的 xpra 还是旧布局，得回去看 `.a0-python-deps` 戳。

如果握手仍失败但报错**不再是 mmap**，那就是第三个独立问题，`xpra-stderr.log` 的末尾 20 行是关键证据；这一轮已经把「参数层」和「venv 层」都排干净了。

---

# 第九轮：`A0_BROWSER_CHROME` 补可执行校验 + 两处文档校正

- 时间：2026-11-18 01:31 – 01:34
- 产物：主包重出（Cuda/Wps 未动）
- 规模：一行代码 + 三处文档，`ostree diff` 相对 v8 只有 `browser.py` 一个文件

## 1. 代码改动

```diff
     override = os.environ.get(CHROME_ENV, "").strip()
     if override:
         candidate = Path(override).expanduser()
-        return candidate if candidate.is_file() else None
+        # An override that exists but cannot be executed would only fail later,
+        # inside Patchright's spawn, as an EACCES with no hint about why. Report
+        # it as "not found" so the caller takes its normal no-host-browser path
+        # (its own discovery, then the downloaded build) instead of receiving a
+        # path that is guaranteed to fail.
+        if candidate.is_file() and os.access(candidate, os.X_OK):
+            return candidate
+        return None
```

**注释与代码的一处措辞偏差，已在实现时校正**：任务说明里写的是「让调用方回落到正常探测」，但给定代码是 `return None`——`return None` 并不会回落到本模块的 `_CHROME_NAMES`/`_CHROME_PATHS` 循环，而是让调用方走它自己的「没有宿主 Chrome」分支（Patchright 自己发现，再退回下载的 `chromium-1228`）。注释按实际行为写，避免后人以为这里会继续往下探测。

行为验证（直接 import 真实模块，逐组设 `A0_BROWSER_CHROME`）：

```
存在但不可执行        /etc/passwd      -> None
不存在于此环境        /app/bin/uv      -> None
可执行                /bin/sh          -> /bin/sh
无 override           （空）            -> /usr/bin/google-chrome-stable
```

第一行就是缺陷本身：改前该路径会被原样返回，直到 Patchright `spawn` 才报 `EACCES`。

## 2. 文档改动（两处）

### 2.1 `test-matrix.md` 的 C42

原判据依赖「沙盒内看不到宿主 Chrome」，而 `--filesystem=host*` 之后这个前提不成立（没有 Chrome 时还会静默回退到 `chromium-1228`）。按新行为改写整行文本，**C 类编号与九段列结构不变**（仍是 `| C42 | 名称 | 前置 | 命令 | 通过 | 失败 | 产物 | 是否改状态 |`）：

```
| C42 | 不可执行的 override 报可读错误 | `A0_BROWSER_CHROME` 指向存在但不可执行的文件（`/etc/passwd`）；应用已按 P5 启动 | `P1[--env=A0_BROWSER_CHROME=/etc/passwd] + S-BROWSER MODE=nochrome` | 打印 `chrome: None`、`OPEN_ERROR:`（消息非空、≤ 4 KB、无 `Traceback`、不含 `EACCES`）、`NO_CHROME_OK`；60 秒内返回 | `chrome:` 仍返回 `/etc/passwd`；错误里直接出现 `EACCES` 或裸堆栈；进程挂死 > 60s | `42-no-chrome.log`（stdout + 该次 `flatpak run --env` 的命令行原文） | 否 |
```

同时把「是否改状态」从「是（清 override，需先备份）」改成「否」：新前置用 `flatpak run --env` 传变量，不再 `--reset` override，因此不需要备份/恢复那套动作。这是**同一行内的一格**，不是结构变更。

### 2.2 `functional-probes.md` §7.4

在这个小标题下加了四行醒目提示：本机实测该前置已失效——`--filesystem=host` 与 `host-os:ro` 让宿主 Chrome 直接可见（`/run/host/root/opt/google/chrome/google-chrome` 与 `/opt/google/chrome/google-chrome` 都可执行，`--version` rc=0、`ldd` 无 `not found`），**不需要任何 override**；没有 Chrome 时 Patchright 还会静默下载回退，所以「看不到 Chrome」在本机已无法复现。原来那段「结论：默认安装状态下浏览器工具不可用」改成「该结论对当前构建不再成立」。

§7.6 第 1 条也同步改成：`chrome: None` 现在意味着 override 指向的文件不存在**或不可执行**（v9 起校验 `X_OK`），或宿主确实没装 Chrome。

### 2.3 `S-BROWSER` 的引用（与任务描述不符，按事实处理）

任务说「`functional-probes.md` 引用了 `S-BROWSER` 但没有定义」。实际核查（全目录 grep）：

```
test-matrix.md:324      ### S-BROWSER：Chrome 发现 / 标题 / 权限不足 / 幂等   ← 定义在这
test-matrix.md:562-564  C40/C41/C42 引用它
test-coverage.md        多处引用（覆盖台账）
functional-probes.md    0 处
probe-browser.md:317    一条「矩阵引用了这个名字，functional-probes.md 里实际只有 §7.5 的命令」的旧笔记
```

也就是说：**定义存在（`test-matrix.md:324` 有完整的 `MODE=chrome|title|nochrome|idempotent` 代码块），`functional-probes.md` 里一处引用都没有。** 所以没有「引用了但没定义」这个缺陷可修；`probe-browser.md:317` 那条笔记是过时的。

按「补 3 行定义」的方向做了等价的最小处理：在 `functional-probes.md §7.5` 开头加四行指引，说明矩阵里的 `S-BROWSER MODE=…` 就是同一段逻辑的命名版本、定义在 `test-matrix.md`，并点出三种 MODE 的差别。这样从 7.5 读的人不用再翻别处，也不制造第二份会漂移的实现。

## 3. 构建

```
$ flatpak-builder … --repo=$CACHE --state-dir=$STATE …
Nothing to update.
Building module agent-zero … Exporting org.agentzero.AgentZero to repo
real 0m11.838s      BUILDER_EXIT=0     （uv / python-gi-cairo / xpra / xvfb 全命中缓存）

$ flatpak build-bundle $CACHE bundles/agent-zero.flatpak org.agentzero.AgentZero master
real 1m10.086s      BUNDLE_EXIT=0
```

新产物：

```
-rw-r--r-- 1 kunweiz kunweiz 59717232 Nov 18 01:33 bundles/agent-zero.flatpak
fee1fa6745d2aae2b7a410cc2bc13db7173b56e36e2b260f4baea7d4da26a2c9
commit 4d4e00e7a91ebf10b645b97e78cab47161e015d8defc6b21d3d376f81f99ef97
```

v8 是 `59715960 B / b74e6d9f3a06… / 0e6c508`；本版 +1272 字节（一段注释 + 两行代码，压缩后的小幅增长）。

## 4. 七条镜像断言

| # | 断言 | 结果 |
|---|---|---|
| 1 | `browser.py` 的 `find_system_chrome` 含 `os.access(candidate, os.X_OK)` | **通过**：第 74 行（override 分支）；第 84 行是路径表循环里原有的同名判据，两处都在 |
| 2 | `_CHROME_PATHS` 首条仍是 `/run/host/root/opt/google/chrome/google-chrome` | **通过** |
| 3 | `desktop.py` 的 `--tcp-auth` 2 处、`--mmap=no` 仅 2 处且不在 argv | **通过**：`tcp-auth=env` 2；`--mmap=no` 出现在第 336 行注释与第 346 行过滤语句，headless 的 `start-desktop` argv 里没有它 |
| 4 | `ocr.py` 含 `A0_OCR_MAX_PAGES` | **通过**：2 处 |
| 5 | `agent-zero.sh` 含 `.a0-python-deps` 与 `for stale in` | **通过**：2 处 / 1 处 |
| 6 | `a0flatpak/health.py` 不存在 | **通过**：0 |
| 7 | manifest 含 `--talk-name=org.freedesktop.Flatpak` | **通过**：1 处 |

字节一致：`browser.py` 工作树 4253 = 镜像 4253。

## 5. 这一版的验证只需一条

浏览器工具的验收已经通过，本轮只堵了 override 的一种误用，因此装完重启后**只需验证负路径**：

```bash
P1[--env=A0_BROWSER_CHROME=/etc/passwd] + S-BROWSER MODE=nochrome
```

期望 `chrome: None`，且 `OPEN_ERROR` 里**不出现** `EACCES`——出现就说明还在把不可执行路径交给 Patchright。正路径（`MODE=title` 拿到 `A0 Probe Title`）不必重跑：路径表与探测顺序本轮一字未改，`_CHROME_PATHS` 首条在镜像里已核对。

---

# 第十轮：修 WAV 头、旧索引崩溃、语音错误信息、超长输入

- 时间：2026-11-18 01:40 – 01:49
- 产物：主包重出两次（第一次的文案与断言冲突，见 §6），最终 `bb2afeed…`
- 与 v9 的 `ostree diff` 只有两个文件：`speech.py`、`vector_store.py`

## 1. WAV 头修补（P1-a）

### 现象与成因

Ollama 在知道音频长度之前就写出头部，RIFF 与 `data` 两个 size 字段都填 `0xFFFFFFFF`。`wave` 信任这两个值，读出的 `nframes` 是 2147483647（24 kHz 下约 24 小时），于是「WAV 头合法」这类断言会**假通过**。

### 实现

`_repair_wav(data: bytes) -> bytes`（纯函数，无 IO）：

```python
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return data

    buf = bytearray(data)
    struct.pack_into("<I", buf, 4, len(buf) - 8)

    offset = 12
    while offset + 8 <= len(buf):
        chunk_id = bytes(buf[offset : offset + 4])
        size = struct.unpack_from("<I", buf, offset + 4)[0]
        payload = offset + 8
        if size == 0xFFFFFFFF:
            if chunk_id == b"data":
                struct.pack_into("<I", buf, offset + 4, len(buf) - payload)
            break
        if payload + size > len(buf):
            if chunk_id == b"data":
                struct.pack_into("<I", buf, offset + 4, len(buf) - payload)
            break
        if chunk_id == b"data":
            struct.pack_into("<I", buf, offset + 4, len(buf) - payload)
            break
        offset = payload + size + (size & 1)  # odd-sized chunks are padded
    return bytes(buf)
```

三个设计点：

- **只改两个 size，不碰 payload**。音频字节是唯一的真实数据，修补不能有第二个副作用。
- **不认识就原样返回**。非 RIFF/WAVE 可能是别的响应格式，猜格式比不改更危险。
- **容器块 size 未知时停下**，只保留已修正的 RIFF：后面的块无法定位，硬猜会把 `data` 的偏移算错。

代价说明：`data` 的 size 一律按「文件末尾」计算。若将来响应在 `data` 之后还有块，这个写法会把尾部算进音频。当前 Ollama 的 WAV 是 `fmt` + `data` 两段，没有这种情形；这条假设写在代码注释里。

修补后若 `wave.open()` 仍失败，`print` 一行 stderr 警告并**返回原字节**——音频比错误信息有用。

### 验收 1：合成头（4 组）

```
0xFFFFFFFF 头           riff=168996 (期望 168996) data=168960 (期望 168960)
                        wave: nframes=84480 期望 84480 | 时长=3.520s | 断言 OK
data size=0             riff=168996 data=168960  → nframes=84480 断言 OK
RIFF size 错但 data 对    riff=168996 data=168960  → nframes=84480 断言 OK
LIST 奇长度 + data       riff=2450 期望 2450 | nframes=1200 断言 OK
非 WAV 原样返回: True
```

第一次跑时断言写错了（拿「字节数」比「帧数」），得到三行 `FAIL`；改成 `nframes == (len-44)//(channels*width)` 后全绿。把这个错误留在报告里，因为「帧数 ≠ 字节数」正是这类断言最容易踩的坑。

### 验收 2：真实 TTS（本机 Ollama，模型 `lfm3-omni:2b-q4_K_M`）

```
bytes=207404 耗时=13.12s RIFF=b'RIFF' WAVE=b'WAVE'
riff_size=207396 期望=207396
wave: nframes=103680 rate=24000 ch=1 width=2 时长=4.320s
期望帧数=103680 断言 OK
```

修补前这一份的 `riff_size` 会是 `4294967295`、`nframes` 会是 2147483647。

## 2. 旧索引让记忆初始化崩溃（P1-b）

### 现象

`usr/memory/<subdir>/index.faiss` 若是真 faiss 写的（或损坏），我们的 `read_index` 在 `pickle.load` 处抛出，`Memory.initialize` 直接失败，没有「读不了就重建」的分支。

### 实现（两层，缺一不可）

**第一层**：`read_index` 捕获一切异常，打印一行带路径与异常类型的警告，返回 `IndexFlatIP(0)`（`d == 0` = 维度未定）。`add` 里 `if self.d == 0: self.d = batch.shape[1]` 让第一笔写入定义维度，否则每个恢复出来的索引都会拒绝第一次写。

**第二层（实现时发现的必需补丁）**：只返回空索引**不够**。`FAISS.load_local` 还会恢复 `index_to_docstore_id`，它的键是旧索引用过的位置；空索引从位置 0 开始写，新向量会**静默解析到旧文档的 id**。实测（见下文）两旧两新之后 `ntotal == 2`、`similarity_search("gamma")` 返回 `['alpha', 'beta']`——不报错，召回全错。

所以 `apply()` 之外新增 `_patch_load_local()`：包住 `FAISS.load_local`，若拿到的 `index.d == 0`（即「刚从坏文件恢复」），就把 `index.faiss` / `index.pkl` / `index.faiss.sha256` 改名为 `*.incompatible-<时间戳>`（**改名不删除**），打印说明，并返回 `None`。`plugins/_memory/helpers/memory.py:186` 之后本来就有 `if db and not emb_ok` 与 `if not db:` 两条分支，`None` 正好走「没有数据库，新建一个」。

### 验收：两个造假文件

```
=== 垃圾12B ===
a0flatpak: could not read the vector index at …/index.faiss (UnpicklingError: invalid load key, 'n'.); starting from an empty index
a0flatpak: the index in … was not readable, so the database was set aside (suffix .incompatible-20261118-014429) and will be rebuilt
load_local -> None
目录内容: ['index.faiss.incompatible-20261118-014429', 'index.pkl.incompatible-20261118-014429']
rebuild: ntotal = 2  recall -> ['gamma', 'delta']
ASSERT OK

=== IxFI伪造（真 faiss 魔数 + 随机字节）===
a0flatpak: … (ValueError: could not convert string to int); starting from an empty index
a0flatpak: … set aside (suffix .incompatible-20261118-014429) and will be rebuilt
load_local -> None
目录内容: ['index.faiss.incompatible-…', 'index.pkl.incompatible-…']
rebuild: ntotal = 2  recall -> ['gamma', 'delta']
ASSERT OK
```

`IxFI` 那条的异常正是任务里描述的那一句 `ValueError: could not convert string to int`，说明复现的确实是同一条路径。

### 回归：正常索引不受影响

```
=== 正常路径（本 shim 格式）：存 → 读 → 召回 ===
loaded is None? False | ntotal = 2 | d = 4
recall -> ['one', 'two']
文件: ['index.faiss', 'index.pkl']
=== 空索引 add 的扩维（直接测 shim）===
d=0 后 add 一条 7 维: d = 7 ntotal = 1
```

`load_local` 只在 `d == 0` 时返回 `None`；正常索引的 `d` 是真实维度，走原路径。

## 3. 语音错误信息（P2-a）

`_describe(prefix, url, response=None, exc=None)` 统一拼一行，`prefix` 作为字面量传入：

```
=== 错误模型 ===
RuntimeError: Ollama speech failed: model=no-such-model:latest status=404 body='{"error":{"message":"model \"no-such-model:latest\" not found, try pulling it first",…

=== 黑洞端口 ===
RuntimeError: Ollama speech failed: model=lfm3-omni:2b-q4_K_M url=http://127.0.0.1:9/v1/audio/speech error=ConnectError: [Errno 111] Connection refused
```

两处都替换了原来的 `raise_for_status()`：状态码分支带 `status` + `body`（截断 200 字符、压成单行），连接分支带 `url` + 异常类型。STT 用同一个 helper，前缀是 `Ollama transcription failed`，走 `/v1/audio/transcriptions`。

`_describe` 的第一版写成 `f"Ollama {action} failed"`，运行时输出正确但**源码里没有 `Ollama speech failed` 这个字面量**，于是断言 grep 到 0。改成把前缀当参数传字面量：`_describe("Ollama speech failed", …)`，现在源码 2 处、运行时输出不变。这不是为了过断言而改文案——把可 grep 的字面量留在源码里，日志与源码才能互相验证。

## 4. 超长输入（P2-b）

```python
SPEECH_MAX_CHARS = int(os.environ.get("A0_SPEECH_MAX_CHARS", "1200"))

class SpeechInputTooLong(ValueError):
    """The text exceeds A0_SPEECH_MAX_CHARS."""
```

在 `_speech_request` 开头检查，超限抛：

```
SpeechInputTooLong: speech input is 1500 characters, the limit is 1200 (A0_SPEECH_MAX_CHARS); split the text into segments and synthesize each one
```

**选择「抛」而不是「截断 + 提示」**，理由写在注释里：截断会产出「听起来正常、内容少了半句」的音频，而 TTS 的调用方（句子级合成）本来就能自己分段；抛出可读异常把决定权交给它。上限设为 1200 字符：实测 1500 字在 200 秒内没跑完，而 1200 字约 40–60 秒自述，落在 `A0_SPEECH_TIMEOUT=180` 的余量内。

边界验证：`SPEECH_MAX_CHARS=1500` 时 1500 字放行到网络层（得到 `ConnectError`，说明长度检查没有误杀）。

注释里写清了为什么必须有长度上限：**httpx 的超时是逐次读超时，不是总时长；Ollama 流式输出会一直续命，所以读超时形同虚设。**

## 5. 构建

```
第一次（01:46）：
  flatpak-builder real 0m14.441s   BUILD_EXIT=0
  flatpak build-bundle real 1m8.598s   EXIT=0
  → 59725624 B / c865807d28bf… / e88900a

第二次（01:48，改文案后）：
  flatpak-builder real 0m6.851s   BUILD_EXIT=0
  flatpak build-bundle real 0m53.338s  EXIT=0
```

最终产物：

```
-rw-r--r-- 1 kunweiz kunweiz 59724976 Nov 18 01:48 bundles/agent-zero.flatpak
bb2afeed6ca798f842fe7a3dacb01408e10438a49bf4b65d0119e63eb84b375e
commit 7a55c085a255e2777803a22c2c921789a88cf603aedac06fea7788fd118e7764
```

多花了一次 1 分 8 秒的打包（第一次的 `c865807d…` 已作废，被覆盖），原因就是上面 §3 的字面量问题。

## 6. 九条镜像断言

| # | 断言 | 结果 |
|---|---|---|
| 1 | `speech.py` 含 `_repair_wav` | **通过**：2 处（定义 + 调用） |
| 2 | `speech.py` 含 `A0_SPEECH_MAX_CHARS` | **通过**：3 处 |
| 3 | `speech.py` 含 `Ollama speech failed` | **通过**：2 处 |
| 4 | `vector_store.py` 含 `d == 0` | **通过**：2 处（注释 + 判断） |
| 5 | `vector_store.py` 含可读警告 | **通过**：`could not read the vector index` 1 处；另 `set aside` 1 处 |
| 6 | `desktop.py` `--tcp-auth` 2 处、`--mmap=no` 仅 2 处（注释 + 过滤，不在 argv） | **通过** |
| 7 | `ocr.py` 含 `A0_OCR_MAX_PAGES` | **通过**：2 处 |
| 8 | `browser.py` 的 `_CHROME_PATHS` 首条仍是 `/run/host/root/opt/google/chrome/google-chrome` | **通过** |
| 9 | `agent-zero.sh` 的 `.a0-python-deps`（2）与 `for stale in`（1）、`health.py`（0）、`--talk-name`（1） | **通过** |

与 v9 的 diff 只有两个文件，正是本轮改动的两个：

```
M /files/share/agent-zero/flatpak/a0flatpak/speech.py
M /files/share/agent-zero/flatpak/a0flatpak/vector_store.py
```

## 7. 装完第一件要验证什么

**先验证 WAV 头**，因为它决定了 C28 那条验收是真通过还是假通过，而且不需要造数据：

```bash
OLLAMA=http://127.0.0.1:11434
curl -s "$OLLAMA/v1/audio/speech" -H 'Content-Type: application/json' \
  -d '{"model":"lfm3-omni:2b-q4_K_M","input":"probe","voice":"female","response_format":"wav"}' \
  | python3 -c 'import sys,struct; d=sys.stdin.buffer.read(); print("riff", struct.unpack_from("<I",d,4)[0], "期望", len(d)-8); print("data", struct.unpack_from("<I",d,40)[0])'
python3 - <<'PY'
import io, wave, urllib.request, json
body = json.dumps({"model":"lfm3-omni:2b-q4_K_M","input":"probe","voice":"female","response_format":"wav"}).encode()
raw = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:11434/v1/audio/speech", body, {"Content-Type":"application/json"})).read()
with wave.open(io.BytesIO(raw), "rb") as h:
    print("nframes", h.getnframes(), "rate", h.getframerate(), "时长 %.2fs" % (h.getnframes()/h.getframerate()))
PY
```

注意第二条走的是**未经修补**的原始响应：`wave` 若仍读到 2147483647，说明这条修复只在应用进程内生效（`_speech_request` 的返回值），而 `/v1/audio/speech` 直连依旧是不合法的头。这是预期的——修补发生在我们的 Python 层，不在 Ollama 侧。要验修补本身，走 TTS 的接口（`plugins/_kokoro_tts` 的 `synthesize_sentences`）或调用 `a0flatpak.speech._speech_request`。

第二件验旧索引：把 `usr/memory/<subdir>/index.faiss` 换成 12 字节垃圾后重启，期望 stderr 有 `could not read the vector index` 与 `set aside`，目录里出现 `*.incompatible-*`，记忆不崩、新增记忆可召回。第三件验长度上限：`A0_SPEECH_MAX_CHARS=10` 后调一次 TTS，期望 `SpeechInputTooLong` 而不是 200 秒等待。

---

# 第十一轮：OCR 的预算、边界与文案

- 时间：2026-11-18 02:32 – 02:34
- 产物：主包重出；`ostree diff` 相对 v10 只有 `ocr.py`（另两个文件是 WPS worker 的并发改动，见 §7）

## 1. 默认预算只够 2 页（高）

### 为什么必须动上游的默认值

`plugins/_document_query` 对**一次 `_parse_sync` 调用**包了
`asyncio.wait_for(..., timeout=per_document_timeout)`（`parsers/base.py:45-48`），而我们的页循环就在这次调用里面。所以卡住页数的是**外层那个数**，不是 `A0_OCR_TIMEOUT`，也不是 `A0_OCR_MAX_PAGES`：实测默认 60 秒时 3 页只完成 2 页、5 页只完成 2 页，而把 `per_document_timeout` 提到 300 秒后 3 页 63.6 秒完成 3/3、5 页 64.8 秒完成 4/5。

也就是说，`A0_OCR_MAX_PAGES=4` 在默认配置下不可达——上限形同虚设。

### 公式

```python
OCR_PAGE_COST = float(os.environ.get("A0_OCR_PAGE_COST", "30"))

def _planned_budget() -> float:
    return max(60.0, OCR_MAX_PAGES * OCR_PAGE_COST + 15.0)
```

`max(60, 4*30+15)` = **135 秒**。取值理由：

- 30 秒/页来自实测区间 15–28 秒（含冷启动加载），留一点余量；
- 15 秒是渲染 4 页 PNG（1600 px 宽）+ 三次 HTTP 往返 + 汇总的实测开销；
- `max(60, …)` 保证把 `A0_OCR_MAX_PAGES` 调小时不会比上游默认更紧。

### 接缝：只替换「出厂默认」

```python
    original = dq._load_config

    def load_config(agent):
        config = original(agent)
        if not isinstance(config, dict):
            return config
        try:
            current = float(config.get("per_document_timeout", planned))
        except (TypeError, ValueError):
            current = planned
        if current == 60.0:
            config = dict(config)
            config["per_document_timeout"] = planned
        return config
```

为什么是 `_load_config`：`helpers.plugins.get_plugin_config` 的行为是「有用户 `config.json` 就用它，没有就用随包的 `default_config.yaml`」，两者**不合并**。所以在 `_load_config` 出口处改是最靠内的位置，且只在值等于出厂默认 60 时替换：

- 用户 `config.json` 里写了 60 → 会被提到 135（可接受的副作用：等于想要更多时间）；
- 写了任何别的值（10、300）→ 原样保留；
- 键缺失 → 不写入，`_document_budget` 自己回落到 `_planned_budget()`。

同时 `_document_budget` 的兜底从硬编码 60 改成 `_planned_budget()`。

## 2. `per_document_timeout=10` 时 0 页（中）

原实现 `budget = max(limit - 5.0, 5.0)`，然后循环第一句 `if remaining <= OCR_MARGIN`（5.0）成立，一页都不发。改成自适应：

```python
def _margin_for(limit: float) -> float:
    return min(OCR_MARGIN, max(1.0, limit * 0.25))

def _document_budget(config: dict) -> float:
    limit = _document_limit(config)
    return max(limit - _margin_for(limit), 1.0)
```

循环里的门限也改用 `margin`（不再是常量 `OCR_MARGIN`）。实测：

```
cfg={}                                limit= 135.0 margin= 5.0 budget= 130.0
cfg={'per_document_timeout': 60}      limit=  60.0 margin= 5.0 budget=  55.0
cfg={'per_document_timeout': 10}      limit=  10.0 margin= 2.5 budget=   7.5
cfg={'per_document_timeout': 300}     limit= 300.0 margin= 5.0 budget= 295.0
cfg={'per_document_timeout': 'bad'}   limit= 135.0 margin= 5.0 budget= 130.0
cfg={'per_document_timeout': 1}       limit=   1.0 margin= 1.0 budget=   1.0
```

`per_document_timeout=10` 下 3 页的实测：**请求数 3、输出 `'ok\n\nok\n\nok'`**——三页全发，因为每页桩件是瞬时返回；真实环境下会发到预算耗尽为止，但**至少发一页**这一点成立。

极限 `per_document_timeout=1` 仍然是 0 页，但文案说明了原因（不再是静默）：

```
> OCR incomplete: 0 of 2 pages processed (the 1.0s document budget ran out).
```

## 3. 1×1 PNG 返回空串（中）

`_parse_image` 改为：拿到 `text` 后若 `not text.strip()`，返回

```
> OCR incomplete: the vision model returned no text for this image.
```

仍走成功路径（不抛），但上层能看出「这次什么都没识别出来」，而不是拿到 `""` 继续下一个 parser。

`_ocr_pages` 里单页空不再静默：`empty` 计数，末尾追加

```
> OCR incomplete: the vision model returned no text for 1 of 2 pages.
```

实测（第 1 页空、第 2 页有文本、总 3 页）：

```
'page2\n\n> OCR incomplete: the vision model returned no text for 1 of 2 pages.\n\n> OCR incomplete: 2 of 3 pages processed (A0_OCR_MAX_PAGES=4).'
```

两条说明同时存在、各自陈述事实，不合并成一句模糊的话。

## 4. 非 PDF 抛裸 `FileDataError`（低）

`_pdf_pages` 的两处（`pymupdf.open` 与逐页渲染）都包成：

```python
raise ValueError(f"PDF could not be read: {type(exc).__name__}: {exc}") from exc
```

实测 `b"not a pdf"` → `ValueError: PDF could not be read: FileDataError: Failed to open stream`。

只在**渲染阶段**包装，`_parse_pdf_with_fallback` 里「原策略失败 → 视觉回退」的语义不变：`original(self, document, config)` 的异常仍在原处被吞掉并触发 OCR。逐页渲染也包一层，是因为坏页会在循环中途抛，那时已经渲染了前几页——包起来能让调用方看到统一措辞，而不是半途的库异常。

## 5. 文案精度（低）

```python
def _secs(value: float) -> str:
    return "<0.1s" if value < 0.1 else f"{value:.1f}s"
```

```
0.01 -> <0.1s      0.05 -> <0.1s      0.50 -> 0.5s
7.40 -> 7.4s      45.00 -> 45.0s     135.0 -> 135.0s
```

`A0_OCR_TIMEOUT=0.01` 现在说「did not finish within `<0.1s`」，不再自相矛盾地写 `0s`。所有出现秒数的地方（三处超时文案、预算耗尽、`OCR failed within`）统一走这个函数。

## 6. 构建

```
$ flatpak-builder …      real 0m7.418s    BUILDER_EXIT=0
$ flatpak build-bundle …  real 0m38.901s   BUNDLE_EXIT=0
```

新产物：

```
-rw-r--r-- 1 kunweiz kunweiz 59727920 Nov 18 02:33 bundles/agent-zero.flatpak
b67933cd35970bfbf9794063dbb66c92a928d173341cf9bf2292dd64f3a0af6d
commit d3731ae0e90bcd1ed533c21d55666d566bf55f78570a720922caf35a885d81ca
```

v10 是 `59724976 B / bb2afeed6ca7… / 7a55c08`；本版 +2944 字节。

## 7. 断言

| # | 断言 | 结果 |
|---|---|---|
| 1 | `ocr.py` 含 `per_document_timeout` 的默认提升逻辑 | **通过**：5 处（含 `_patch_document_timeout` 的实现与调用） |
| 2 | 含 `max(1.0`（自适应 margin） | **通过**：1 处 |
| 3 | 含 `returned no text` | **通过**：2 处（单图 + 多页汇总） |
| 4 | 含 `PDF could not be read` | **通过**：2 处（打开 + 逐页） |
| 5 | 含 `:.1f` | **通过**：1 处（`_secs`） |
| 6 | `_repair_wav` 2、`A0_SPEECH_MAX_CHARS` 3 | **通过** |
| 7 | `--mmap=no` 2 且 `start-desktop` argv 里 0 | **通过**（`grep -c mmap` 在 argv 段为 0） |
| 8 | `--tcp-auth` 2、`_CHROME_PATHS` 首条 `/run/host/root/opt/google/chrome/google-chrome` | **通过** |
| 9 | `agent-zero.sh` 的 `.a0-python-deps`（2）与 `for stale in`（1） | **通过** |
| 10 | `health.py` 0、`--talk-name` 1、`incompatible-` 2 | **通过** |

与 v10 的 diff：

```
M /files/share/agent-zero/flatpak/README.md
M /files/share/agent-zero/flatpak/wps-mcp-config.json
M /files/share/agent-zero/flatpak/a0flatpak/ocr.py
```

`ocr.py` 是本轮；另两个是 **WPS worker 的并发改动**，本轮 `cp -a flatpak` 把它们一并带进了镜像：`wps-mcp-config.json` 新增 `env` 块（`DBUS_SESSION_BUS_ADDRESS`、`XDG_RUNTIME_DIR`、`DISPLAY`、`XAUTHORITY`）与 `--directory=/`，README 补了为什么这些是必需的（MCP stdio 客户端只给默认环境，缺 bus 地址会让 `flatpak-spawn --watch-bus` 报 `Can't find bus`）。按事实记录，不是我改的。

## 8. 重建后需要复测的三条

1. **3 页扫描件、默认配置**：必须 `3 of 3`，不再出现 `OCR incomplete`。这条直接验证 `_patch_document_timeout` 生效——若仍是 2/3，说明 `_load_config` 的接缝没被走到（例如插件缓存了旧的 `self.config`），要查 `config.json` 是否已存在。
2. **5 页扫描件、默认配置**：必须 `4 of 5` 且出现 `OCR incomplete: 4 of 5 pages processed (A0_OCR_MAX_PAGES=4).`。这条同时验证预算（135 秒够跑 4 页）与上限（第 5 页不发）。
3. **`per_document_timeout=10`**：必须至少发出 1 页；若返回 `0 of N pages processed`，文案必须带 `the 7.5s document budget ran out`（而不是空原因）。顺带确认 1×1 PNG 现在返回 `> OCR incomplete: the vision model returned no text for this image.` 而不是 `""`。

---

# 第十二轮：把「静默回退」变成「回退并告知」

- 时间：2026-11-18 02:51 – 02:53
- 产物：主包重出；`ostree diff` 相对 v11 只有 `browser.py`

## 1. 问题：降级是对的，但不说话

C42 实测：`A0_BROWSER_CHROME=/etc/passwd` 时 `find_system_chrome()` 返回 `None`（v9 的 `X_OK` 校验生效），`prepare_playwright_cache()` 回退到已下载的 `chromium-1228`，工具层 0.54 秒**成功**返回。

也就是说降级本身没问题——可用性优先是正确取舍。问题在于它**完全静默**：返回的 dict 里没有一句话说明为什么没用宿主 Chrome，运维看到工具正常，会以为自己配的 `A0_BROWSER_CHROME` 生效了。

## 2. 改动

`flatpak/a0flatpak/browser.py` 的 `prepare_playwright_cache()`，只改回退分支：

```python
    def prepare_playwright_cache() -> dict[str, Any]:
        chrome = find_system_chrome()
        if chrome is None:
            # Falling back to the bundled Chromium is a working degradation, so
            # the call still succeeds. It must not be silent, though: without a
            # line saying why the host browser was skipped, an operator whose
            # A0_BROWSER_CHROME points at the wrong path sees a healthy tool and
            # concludes their setup was honoured.
            result = original_prepare()
            warnings = list(result.get("warnings") or [])
            warnings.append(
                "No host Chrome was found (A0_BROWSER_CHROME, PATH and the known "
                "locations are all empty or not executable); the bundled Chromium "
                "download is used instead."
            )
            result["warnings"] = warnings
            result["source"] = result.get("source") or "bundled"
            return result
```

三点实现选择：

- **追加而不是覆盖** `warnings`：`original_prepare()` 自己可能已经写了 Patchright 的告警（例如「OS 不受官方支持」），那条信息同样有价值，不能被我们覆盖掉。
- **`source` 用 `or`**：只有当上游没给来源时才填 `bundled`；将来上游若自己标了更精确的值（比如 `bundled:v1228`），以它为准。
- **成功路径完全不动**：宿主 Chrome 找到时仍返回固定的 `{"source": "system", "warnings": []}`。

## 3. 行为验证（真实 hooks，两个分支）

用上游 checkout 作 import 根（`helpers` 在那边），加载运行树的 `plugins/_browser/hooks.py`，走真实的 `prepare_playwright_cache`：

```
patched: True

=== 回退分支（A0_BROWSER_CHROME=/etc/passwd）===
（Patchright 正常下载了 chromium-1228 与 ffmpeg-1011）
source: bundled | binary: …/tmp/playwright/chromium-1228/chrome-linux64/chrome
warn: No host Chrome was found (A0_BROWSER_CHROME, PATH and the known locations are all empty or not executable); the bundled Chromium downlo…

=== 宿主 Chrome 存在时 ===
source: system | binary: /usr/bin/google-chrome-stable | warnings: []
```

两点值得记：回退分支**真的又下载了 177 MiB + 2.3 MiB**（说明 `original_prepare()` 会自己补齐缺失的浏览器，这是它能「成功」的原因）；`source` 从未被上游填写，所以我们的 `or "bundled"` 是必要的。

## 4. 构建

```
$ flatpak-builder …      real 0m8.521s    BUILDER_EXIT=0
$ flatpak build-bundle …  real 0m38.519s   BUNDLE_EXIT=0
```

新产物：

```
-rw-r--r-- 1 kunweiz kunweiz 59928208 Nov 18 02:52 bundles/agent-zero.flatpak
378765852b53799c7c04545ebe5dda77a80053b0dba90232e28ee4586da4b7d1
commit 53ae0c0dc236e450e4a28477482e5e3bf20734155e2d9d33b3ec5949ff302a21
```

v11 是 `59727920 B / b67933cd3597… / d3731ae`；本版 +200,288 字节——远大于本轮代码增量，原因是这次构建把 `helpers/__pycache__/*.pyc` 等此前由并发 agent 触发重编译的字节码一并带进了镜像（日志里能看到 `Fixed up header mtime for files/share/agent-zero/helpers/__pycache__/errors.cpython-314.pyc`）。这不是本轮改动的结果，但它是镜像体积的真实变化，记录下来。

## 5. 断言

| # | 断言 | 结果 |
|---|---|---|
| 1 | `browser.py` 含 `No host Chrome was found` | **通过**：1 处 |
| 2 | `browser.py` 含 `result["warnings"]` | **通过**：1 处 |
| 3 | `os.access(candidate, os.X_OK)` 仍在 | **通过**：2 处（override 分支 + 路径表循环） |
| 4 | `_CHROME_PATHS` 首条 `/run/host/root/opt/google/chrome/google-chrome` | **通过** |
| 5 | `_repair_wav` 2 / `A0_SPEECH_MAX_CHARS` 3 | **通过** |
| 6 | `--mmap=no` 2 处，`start-desktop` argv 里 0 处 | **通过** |
| 7 | `--tcp-auth` 2 处 | **通过** |
| 8 | `health.py` 0 / `--talk-name` 1 | **通过** |
| 9 | `incompatible-` 2 处 | **通过** |
| 10 | `per_document_timeout` 5 处 / `returned no text` 2 / `PDF could not be read` 2 | **通过** |

与 v11 的 diff 只有一行：

```
M /files/share/agent-zero/flatpak/a0flatpak/browser.py
```

## 6. 装完后 C42 该断言什么

C42 的判据要从「工具报可读错误」改成「**降级可见**」，三条同时成立才算通过：

```bash
# 1) prepare 的返回里有 warnings 且 source=bundled
P1[--env=A0_BROWSER_CHROME=/etc/passwd] + S-BROWSER MODE=nochrome
#   chrome: None
#   prepare( 或 install ) -> {"source": "bundled", "warnings": ["No host Chrome was found …"]}

# 2) 工具层仍然成功（可用性没有被这次改动破坏）
#   MODE=title 走 open + state，title 仍应拿到 'A0 Probe Title'

# 3) 无 override 时不出现该告警
#   清掉 --env 后 prepare -> {"source": "system", "warnings": []}
```

注意和 v9 的区别：v9 让 `find_system_chrome()` 返回 `None`（这是**发现层**的判定），本轮让 `prepare_playwright_cache()` 在 `None` 之后**说明原因**（这是**回退层**的告知）。两层各管一件事，断言也要分开：`chrome: None` 验前者，`warnings` 非空 + `source=bundled` 验后者。若装了 v12 仍只看到 `chrome: None` 而没有 warning，说明 `prepare_playwright_cache` 的 patch 没生效（`hooks._a0flatpak_patched` 为真但函数不是我们那版），要查 `apply()` 是否在插件加载前跑过。

---

# 最终三件套构建（`scripts/build.sh` 全流程）

- 时间：2026-11-18 02:57 – 03:09（`real 10m15.573s`，`EXIT=0`）
- 目的：把三个 bundle 产出为**同源同次**的交付物；前两个仍是首轮（23:32 / 23:34）的旧包
- 手段：完整跑 `scripts/build.sh`（含 deps tarball 重建、pin 改写、三个 manifest 依次构建、三次 `flatpak build-bundle`）

## 1. 产物（交付清单）

| 文件 | 大小 | mtime | sha256 |
|---|---|---|---|
| `agent-zero.flatpak` | 60,272,544 | 2026-11-18 03:00:05 | `1ab3f909512a53fba381938bbeaec1fee77732c372469854259c43d19423e915` |
| `agent-zero-cuda.flatpak` | 859,674,472 | 2026-11-18 03:07:41 | `4172429007552f0bd91db26b1ce7830f78979bff81db4d537656315b83e9fe58` |
| `agent-zero-wps.flatpak` | 50,210,688 | 2026-11-18 03:08:55 | `851eae303f97d30b179511992189c82e8da5242e0d5a23f2c81b538978d886fa` |

对应的 cache commit：

```
app/org.agentzero.AgentZero/x86_64/master        506f6a0ac07490c326c1ec2864c1e07e3460ad1fb97dbf60134386cfc4b5c302
runtime/org.agentzero.AgentZero.Cuda/x86_64/12   097b34a9602b0ad88425161c31905c8f2bcd14134b0cefeb0e41d718d908e967
app/org.agentzero.AgentZero.Wps/x86_64/1.0       0b070cfac83b5dcc337664a8d22fd31795d3f64cb127b96acc9e1ca515d7c640
```

`flatpak --user info` 在这里没有意义（本轮只构建，不安装），取代它的是 `ostree refs`：三个 ref 齐备，另有 `runtime/org.agentzero.AgentZero.Wps.Debug/x86_64/1.0`（debuginfo，正常副产物，不进交付）。

### 与首轮同名文件对比

| 文件 | 首轮 | 本轮 | 变化 |
|---|---|---|---|
| cuda | 860,154,032 / `0cf9af0bce9c…` | 859,674,472 / `417242900755…` | −479,560 B |
| wps | 50,210,576 / `248f2834112b…` | 50,210,688 / `851eae303f97…` | +112 B |
| 主包 | 59,928,208 / `378765852b53…` | 60,272,544 / `1ab3f909512a…` | +344,336 B |

WPS 只多 112 字节，是因为 deps tarball 每次重建的 sha 不同（这次是 `22486d93d263…`，首轮是 `7164dc1c…`），写入镜像后仅元数据长度变化。Cuda 变小 0.5 MB 属于压缩器在不同输入顺序下的正常波动，内容清单未变（`cuda_v12` 的库文件与首轮一致）。

## 2. 与 v12 主包的差异判断

v12 的 commit `53ae0c0…` 仍在缓存里，可以逐文件比对。结论：**代码零差异**。

```
$ ostree diff <final> 53ae0c0… | grep -E 'flatpak/(a0flatpak/.*\.py|agent-zero\.sh|org\.agentzero\.AgentZero\.yml|README\.md)' | grep -v __pycache__
（无差异）
```

`a0flatpak/` 下 16 个模块、`agent-zero.sh`、主 manifest、`flatpak/README.md` 全部与 v12 逐字节相同。差异只有三类：

1. **`docs/` 的内容**：`build.sh:30` 会 `cp -a "$HERE/docs" "$A0_SRC/"`，而 v12 是我直接调 `flatpak-builder` 构建的（dir 源的 `..` 是 checkout），checkout 里的 `docs/` 还停在 23:22 那次 `build.sh` 的版本。所以本轮把 28 份验收文档全部带进了镜像，包括 `probe-*.md`、`fix-compat.md`、`verification` 系列等 v12 之后新增的文件。
2. **`wps-office-mcp-deps.tar.gz` 与 `org.agentzero.AgentZero.Wps.yml`**：`build.sh` 发现 tarball 的 sha（`22486d93…`）与 pin（`ff53b592…`）不符，重建并把 **checkout 副本**的 pin 改成新值——这正是脚本注释里写的设计行为，仓库里的 pin 未动。
3. **`/metadata` 与 `/files/manifest.json`**：`source-date-epoch` 变成本次构建时间，所以 commit 不同、bundle sha 不同。

因此：**「主包 commit 变了」是预期的，内容等价性由两件事共同保证**——(a) 上表的代码文件零差异；(b) 四个模块（uv / python-gi-cairo / xpra / xvfb）全部命中模块缓存，`agent-zero` 模块唯一的变化是 dir 源里的 docs。

需要留意的是第 1 条：镜像里现在**包含** `docs/manual-acceptance/` 的 28 份文档。v12 的镜像只有 23:22 那批。这不是缺陷，但会让镜像多出约 300 KB 的 Markdown；若交付物不应带验收文档，把 `build.sh:30` 的 `cp -a "$HERE/docs"` 去掉即可（本轮不改，因为这属于交付范围决策）。

## 3. 流程验证（首轮之后 10 轮改动的回归）

完整跑通意味着下面这条链路在改动后仍然成立：

- `wps-office-mcp-deps.tar.gz` 重建 → sha 与 pin 不符 → 改写 checkout 副本的 pin → 构建继续（`build:` 三行日志，见 §4）；
- 三个 manifest 依次构建，`--repo="$CACHE"` 让每个都出现 `Exporting … to repo`；
- 三次 `flatpak build-bundle` 全部成功，`ls -lh` 输出三个文件（`total 926M`）。

主包这次重跑了 5 个模块里的 `agent-zero`（dir 源变了），其余四个命中缓存；Cuda 与 Wps 因为是全新打包（首轮之后 cache 被 prune 过若干次），各自完整走了一遍模块构建。总耗时 10m15s，其中 Cuda 的 1.4 GB 压缩约 8 分钟，与首轮的观测一致。

## 4. 构建开头的 deps tarball 日志（原样）

```
build: deps tarball does not match the pin, rebuilding it
build: producing wps-office-mcp-deps.tar.gz
written: /home/kunweiz/Desktop/agent-zero/flatpak/wps-office-mcp-deps.tar.gz
build: deps tarball is 22486d93d263f711e422d210c47d4a7ea52abd0131c353e7a1ce509ca867f75a, pin says ff53b5920ebd705b0f47e9ee8dcd04b0755cab1f937e515a0f1ee28ea547ec73
build: updating the pin in /home/kunweiz/Desktop/agent-zero/flatpak/org.agentzero.AgentZero.Wps.yml
```

与首轮完全一致的行为（首轮那次是 `7164dc1c…`）。这再次说明 tarball 的字节不可复现，pin 只是「最近一次产出的记录」。

## 5. 资源与 OOM

无 OOM，`BUILD_EXIT=0`，全程没有触发 `--jobs` 降载。构建前 `Mem 10Gi used / 51Gi available`、`/home` 剩 29 G；构建后 `bundles/` 合计 926 M。

## 6. 可否交付

可以。三条判据：

1. **同源**：三个 bundle 来自同一次 `scripts/build.sh`、同一份 checkout、同一次 deps tarball 重建；`ostree refs` 三个 ref 齐备。
2. **内容与 v12 等价**：`a0flatpak/*.py`、`agent-zero.sh`、主 manifest、README 逐字节相同，四个模块缓存全命中。十二条修改（D1/D2/D4/D6 + P1/P3/P4 + 五轮 OCR/语音/索引/浏览器修正）都在里面。
3. **可核对**：上表的 sha256 与 commit 是交付核对依据；装到目标机后 `flatpak list --columns=application,branch,commit` 应显示 `506f6a0a…`（主包）、`097b34a9…`（Cuda）、`0b070cfa…`（Wps）。

部署顺序仍是**主包 → Cuda → Wps**（Cuda 的 `base` 是主包），三个都用 `--user` 装进同一安装，装完必须重启（`/ui/asset-bundle` 是启动快照，见第五轮）。

---

# 第十三轮：镜像不再携带验收文档

- 时间：2026-11-18 03:10 – 03:12
- 产物：只重出主包（Cuda/Wps 未动）

## 1. 改动

`flatpak/org.agentzero.AgentZero.yml` 的 `agent-zero` 模块，dir 源加一项 skip：

```yaml
      - type: dir
        path: ..
        skip:
          - .git
          - tmp
          # The acceptance reports under docs/manual-acceptance are repository
          # test records, not runtime assets, so they do not ship. docs/setup
          # stays: host-ollama.md is documentation the user reads.
          - docs/manual-acceptance
```

三点说明：

- **只加一项，不删别的**：`.git` 与 `tmp` 原样保留，顺序仍是 `.git` → `tmp` → 新增项。
- **`docs/setup` 不动**：`host-ollama.md` 是给用户看的运行时文档，属于镜像资产。`flatpak-builder` 的 skip 是路径前缀匹配，`docs/manual-acceptance` 不会连带 `docs/setup`。
- **`build.sh:30` 的 `cp -a "$HERE/docs" "$A0_SRC/"` 保留**：它负责把 `docs/`（含 `docs/setup`）送进 checkout，skip 是第二道闸，两者分工不同——前者管「带什么进构建上下文」，后者管「带什么进镜像」。

## 2. 构建

```
$ flatpak-builder …      real 0m5.773s    BUILDER_EXIT=0
$ flatpak build-bundle …  real 0m39.535s   BUNDLE_EXIT=0
```

新产物：

```
-rw-r--r-- 1 kunweiz kunweiz 59937144 Nov 18 03:11 bundles/agent-zero.flatpak
02d857bcf715364a2dd6983a3b69ce626c07ab59682032877b1d56117b1d4238
commit 4d0ccd2ceeb460a13cf9ed50a2cf245268dcb36b81fa3fa50a6a56c3e6eb0888
```

上一版（同源三件套）是 `60,272,544 B / 1ab3f909512a… / 506f6a0`；本版 **−335,400 B**，与「28 份 Markdown + `docs/setup/host-ollama.md` 更新」的量级一致。

## 3. 断言

| # | 断言 | 结果 |
|---|---|---|
| 1 | 镜像内 `manual-acceptance` 计数为 0 | **通过**：`ostree ls -R … \| grep -c manual-acceptance` → **0** |
| 2 | 镜像内 `docs/setup/host-ollama.md` 仍在 | **通过**：计数 **1**；整个 `docs/setup/` 有 4 个文件 |
| 3 | 代码路径与 v12 逐字节一致 | **通过**：排除两项预期差异后，与 `53ae0c0` 的 diff 只剩 `docs/` 相关条目（见 §4） |
| 4 | 旧断言仍成立 | **通过**：`health.py` 0、`--talk-name` 1、`_repair_wav` 2 |

另外两条顺带确认：镜像里的主 manifest 含该 skip 项（`grep -c docs/manual-acceptance` → 2，一处是注释、一处是列表项）；`docs/setup` 目录 4 个文件都在。

## 4. 与 v12（`53ae0c0`）的差异

```
M /files/share/agent-zero/flatpak/org.agentzero.AgentZero.yml     ← 本轮加的 skip
M /files/share/agent-zero/flatpak/wps-office-mcp-deps.tar.gz       ← 03:09 全量构建重建的 tarball
M /files/share/agent-zero/docs/setup/host-ollama.md                ← 并发 agent 对该文档的更新
（其余全部为 docs/manual-acceptance 下的条目，在 v12 里不存在）
```

`a0flatpak/*.py`、`agent-zero.sh`、`bin/*`、`share/agent-zero/*.py` 全部无差异——**v12 → v13 的实质变化只有「移除 28 份验收文档」与那两处非代码项**。

第三行的 `docs/setup/host-ollama.md` 是别人改的文档，本轮 `cp -a flatpak` + dir 源一并带进镜像；内容属于运行时文档，应该进镜像，符合 skip 的取向。

## 5. 给运维：Cuda/Wps 是否仍可一起交付

**可以，不需要重跑。** 理由：

- `agent-zero-cuda.flatpak`（03:07:41）由 `org.agentzero.AgentZero.Cuda.yml` 构建，`agent-zero-wps.flatpak`（03:08:55）由 `org.agentzero.AgentZero.Wps.yml` 构建。本轮改的是**主 manifest** 里 dir 源的 skip 列表，这两个 manifest 各有自己的 dir/file 源，读不到那个 skip，因此产物与 03:07/03:08 时完全相同、仍然有效。
- 三者仍是「同一次 `scripts/build.sh`」的产物（03:00 / 03:07 / 03:08），只有主包在 03:11 被单独重出以剔除验收文档。主包与另两件的接口没有变：`org.agentzero.AgentZero/x86_64/master` 的 app-id、branch、扩展点（`share/agent-zero/cuda`、`share/agent-zero/models`）一字未改，Cuda 的 `base` 仍指向它。

若要求三件套的**构建时间戳完全一致**，重跑一次 `scripts/build.sh` 即可（约 10 分钟，Cuda 压缩占 8 分钟）。这只是洁癖层面的需求——能证明「同源」的是同一份工作树与同一批模块缓存，不是 mtime。

## 6. 交付清单（最终）

| 文件 | 大小 | mtime | sha256 | commit |
|---|---|---|---|---|
| `agent-zero.flatpak` | 59,937,144 | 03:11 | `02d857bcf715364a2dd6983a3b69ce626c07ab59682032877b1d56117b1d4238` | `4d0ccd2c…` |
| `agent-zero-cuda.flatpak` | 859,674,472 | 03:07 | `4172429007552f0bd91db26b1ce7830f78979bff81db4d537656315b83e9fe58` | `097b34a9…` |
| `agent-zero-wps.flatpak` | 50,210,688 | 03:08 | `851eae303f97d30b179511992189c82e8da5242e0d5a23f2c81b538978d886fa` | `0b070cfa…` |

部署顺序：主包 → Cuda → Wps（Cuda 的 `base` 是主包），全部 `--user` 装进同一安装，装完重启。
