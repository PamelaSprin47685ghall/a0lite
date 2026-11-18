# 浏览器工具（G 类）实机探针报告

对象：Flatpak `org.agentzero.AgentZero`（user 安装，commit `0e6c5082…d456a4`），运行中的 5080 实例未重启、未改仓库源码、未改 `conf/`。
目的：确认沙盒内 Agent Zero 的浏览器插件能否真正驱动**宿主 Chrome**，并逐条核对 `test-matrix.md` 的 G 类（C40–C43）。

## 1. 环境与前置

| 项 | 值 | 确认方式 |
|---|---|---|
| Flatpak 权限 | `shared=ipc;network;`、`sockets=pulseaudio;x11;`、`devices=dri;`、`filesystems=host-etc:ro;host-os:ro;/run/udev:ro;host;` | `flatpak info --show-permissions --user org.agentzero.AgentZero` |
| 沙盒内 `HOME` | `/home/kunweiz`（不是 `~/.var/app/...`；宿主机家目录整体可见） | 沙盒内 `os.environ["HOME"]` |
| 宿主 Chrome | `/run/host/root/opt/google/chrome/google-chrome`（1034 B wrapper，属主 `nfsnobody`；真二进制 `/opt/google/chrome/chrome`） | `ls -l`、`--version` → `Google Chrome 156.0.8078.79` |
| `/opt/google/chrome/google-chrome` | 沙盒内同样可见且 `X_OK`（来自 `--filesystem=host`，**无需** `/opt` override） | `Path(...).exists()` / `os.access(..., X_OK)` |
| 解释器 | `$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/bin/python`，Python 3.14.10 | `python -V` |
| Patchright | 1.61.2（`patchright.__version__` 不存在，读 `importlib.metadata.version`） | 见用例 1 |
| DISPLAY | `:0.0`；沙盒内 `/app/bin/Xvfb` 存在 | 沙盒内 `echo $DISPLAY`、`shutil.which("Xvfb")` |
| `/dev/shm` | 32 G tmpfs（`df -h /dev/shm` 报 `tmpfs 32G … /dev`） | 沙盒内 `df` |
| legacy Chromium | `…/data/agent-zero/tmp/playwright/chromium-1228/chrome-linux64/chrome` 存在 | 见用例 5 |

统一执行骨架（下称 `P`）：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -c '
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
export A0_BASE_DIR="$B" GIT_PYTHON_REFRESH=quiet
export PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps
cd /app/share/agent-zero
"$B/venv/bin/python" /home/kunweiz/a0-shots/<script>.py
'
```

> 现场另有 4 组其它探针遗留的 Chrome（`--user-data-dir=~/.cache/a0-shots-chrome{,2,3,4}`，运行 ~1.8 h）。它们不属于本次探针，未触碰；本次所有 Chrome 均使用 `~/a0-shots/chrome-profile-*` 或插件自己的 `tmp/browser/sessions/shared`，结束后 0 残留。

---

## 2. 用例 1：静态确认

- **目的**：确认 `find_system_chrome()`、被补丁替换的 `hooks.prepare_playwright_cache()`、Patchright 版本。
- **代码**：`a0flatpak.apply()` → `find_system_chrome()` → `hooks.prepare_playwright_cache()` / `hooks.install()` → `importlib.metadata.version("patchright")`。
- **原始输出**：

```
== find_system_chrome ==
PosixPath('/run/host/root/opt/google/chrome/google-chrome')
== prepare_playwright_cache ==
{
  "binary": "/run/host/root/opt/google/chrome/google-chrome",
  "errors": [],
  "warnings": [],
  "removed": [],
  "backup": "",
  "source": "system"
}
patched: True
install(): {"binary": "/run/host/root/opt/google/chrome/google-chrome", "errors": [], "warnings": [], "removed": [], "backup": "", "source": "system"}
== patchright ==
__version__: n/a
dist version: 1.61.2
module: /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/patchright/__init__.py
== env ==
A0_BROWSER_CHROME = None
PLAYWRIGHT_BROWSERS_PATH = None
DISPLAY = :0.0
HOME = /home/kunweiz
```

- **期望**：返回宿主 Chrome 绝对路径；`source == "system"`、`errors == []`；Patchright 可导入。
- **实际**：一致；且**不设** `A0_BROWSER_CHROME` 也能命中（走 `_CHROME_PATHS` 的 `/run/host/root/...`）。
- **结论**：**通过**。

---

## 3. 用例 2：最小启动（不经插件）

- **目的**：用 Patchright 直接启动宿主 Chrome，验证 `launch_persistent_context` 能拿到 context、`new_page()`、`goto(data:)`、`title()`。
- **代码**（每组独立 `--user-data-dir`，结束 `ctx.close()`）：

```python
ctx = await pw.chromium.launch_persistent_context(
    user_data_dir=PROFILE, headless=HEADLESS,
    executable_path="/run/host/root/opt/google/chrome/google-chrome",
    # 组 B/C 额外: args=["--no-sandbox","--disable-dev-shm-usage"]
)
page = await ctx.new_page()
await page.goto("data:text/html,<title>probe</title><h1>ok</h1>")
assert await page.title() == "probe"
```

- **原始输出（组 A，默认参数 + `executable_path`）**：

```
LAUNCH_KWARGS: {"user_data_dir": "/home/kunweiz/a0-shots/chrome-profile-A", "headless": false, "executable_path": "/run/host/root/opt/google/chrome/google-chrome"}
CONTEXT_OK: BrowserContext elapsed=0.7s
BROWSER_VERSION: 156.0.8078.79
NEW_PAGE_OK pages=1
TITLE: 'probe'
H1: 'ok'
URL_NOW: data:text/html,<title>probe</title><h1>ok</h1>
CLOSED_OK
TOTAL 0.9s
RC=0
```

```
# 显式 new_page() 复核
CONTEXT_OK BrowserContext
NEW_PAGE_OK True
TITLE: 'probe'
H1: 'ok'
CLOSED_OK
```

- **原始输出（组 B，加 `--no-sandbox --disable-dev-shm-usage`）**：

```
CONTEXT_OK: BrowserContext elapsed=0.7s
BROWSER_VERSION: 156.0.8078.79
NEW_PAGE_OK pages=1
TITLE: 'probe'
H1: 'ok'
CLOSED_OK
TOTAL 0.9s
RC=0
```

- **原始输出（组 C1，`headless=True` + 同上 args）**：

```
CONTEXT_OK: BrowserContext elapsed=0.5s
BROWSER_VERSION: 156.0.8078.79
NEW_PAGE_OK pages=1
TITLE: 'probe'
H1: 'ok'
CLOSED_OK
TOTAL 0.7s
RC=0
```

- **期望**：拿到 browser/context 对象，`new_page()` 成功，`title() == "probe"`。
- **实际**：三组全部满足；`headless=False` 在有头模式（`DISPLAY=:0.0`）下也正常。
- **结论**：**通过**，且第三种（headless）不需要作为回退。

### 3.1 三组 launch 选项对比

| 组 | launch 参数 | 结果 | 耗时 | 说明 |
|---|---|---|---|---|
| A | `user_data_dir` + `headless=False` + `executable_path` | 成功 | 0.9 s | Patchright 默认 `chromiumSandbox=False`，自动注入 `--no-sandbox`、`--disable-dev-shm-usage`（`DEBUG=pw:browser` 的 `<launching>` 行可见）。Flatpak 内 Chrome 自身 user-namespace sandbox 被绕过，因此能起。 |
| B | A + `args=["--no-sandbox","--disable-dev-shm-usage"]` | 成功 | 0.9 s | 与 A 完全等价，参数重复；**无额外收益**。`/dev/shm` 为 32 G，也不缺。 |
| C1 | B + `headless=True` | 成功 | 0.7 s | 不依赖 X；适合无显示环境。 |

结论：**A 就够**（插件真实路径也只加 `--hide-crash-restore-bubble` 等业务参数，不显式加 `--no-sandbox`）。B 只是把 Playwright 的默认值再写一遍。C1 作为无显示环境的备选，不需要在正常安装里启用。

---

## 4. 用例 3：走插件路径

- **目的**：用插件真实入口打开 `data:` 与 `https://example.com`，断言返回内容。
- **入口**：`plugins/_browser/tools/browser.py:103` 的 `Browser.execute(action="open")` → `plugins/_browser/helpers/runtime.py:1327 BrowserRuntime.open`。本次直接调 `get_runtime(ctx).call("open", url)`（与 `functional-probes.md §7.5` 同一条路径），属于公开最小单元，不是私有 `_launch`。
- **代码**：

```python
rt = await runtime.get_runtime("probe-browser-tool")
r  = await rt.call("open", "data:text/html,<title>A0 Probe Title</title><h1>plugin-ok</h1>")
c  = await rt.call("content", r["id"])
r2 = await rt.call("open", "https://example.com")
c2 = await rt.call("content", r2["id"])
await rt.call("close_all_browsers"); await runtime.close_runtime("probe-browser-tool")
```

- **原始输出**：

```
RUNTIME: BrowserRuntimeSession
-- open(data:): {"id": 1, "state": {"id": 1, "context_id": "probe-browser-tool", "currentUrl": "data:text/html,<title>A0 Probe Title</title><h1>plugin-ok</h1>", "title": "A0 Probe Title", "canGoBack": true, "canGoForward": false, "loading": false, "zoom": 100, "zoom_available": false}}
STATE_TITLE: A0 Probe Title
CONTENT_HAS_plugin-ok: True | len 114
-- content(sample): "{\"document\": \"---\\nurl: ...\\n---\\n\\n# plugin\\\\-ok\"}"
-- screenshot_file: {"browser_id": 1, ... "path": "/home/kunweiz/a0-shots/80-browser-tool.png", ... "vision_load": {...}}
-- open(example.com): {"id": 2, "state": {"id": 2, "context_id": "probe-browser-tool", "currentUrl": "https://example.com/", "title": "Example Domain", ...}}
CONTENT_HAS_Example_Domain: False | len 996
STATE2_TITLE: Example Domain
```

二次运行（只为截图与进程核对，输出同构）：

```
PROFILE_DIR: /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/tmp/browser/sessions/shared
OPEN: {"id": 1, "state": {..., "currentUrl": "https://example.com/", "title": "Example Domain", ...}}
DOC_LEN: 962
DOC_SAMPLE: '---\nurl: "https://example.com/"\n---\n\nThis domain is for use in documentation examples without needing permission. This is not a service; avoid relying on it for testing and monitoring purposes.\n\nهذا النطاق …'
```

- **期望**：`data:` 页标题 `A0 Probe Title`、内容含 `plugin-ok`；`example.com` 标题 `Example Domain`、正文含预期文本。
- **实际**：
  - `data:` 断言全部成立（标题、正文 `# plugin\-ok`）。
  - `example.com` 标题正确，正文 962 字符含 `This domain is for use in documentation examples…`；但**不含**字符串 `Example Domain`。原因是当前 example.com 页面本身已改为多语言说明页，没有 `<h1>Example Domain</h1>`（截图核验，见 §5），标题只存在于 `document.title`。这不是插件缺陷。
- **结论**：**通过**（断言改为正文特征串后成立）。

---

## 5. 用例 4：截图

- **目的**：从插件打开的页面截图，记录尺寸与统计量。
- **代码**：`await rt.call("screenshot_file", bid, path="/home/kunweiz/a0-shots/80-browser-tool.png")`（未传 `browser_id` 之外的参数，走 PNG 分支）。
- **原始输出**：

```
SHOT: /home/kunweiz/a0-shots/80-browser-tool.png image/png
$ identify 80-browser-tool.png
80-browser-tool.png PNG 1024x768 1024x768+0+0 8-bit sRGB 72336B
  Colorspace: sRGB
      mean: 234.038 (0.917797)
      standard deviation: 22.215 (0.0871175)
  Filesize: 72336B
```

- **判读**：1024×768、白底居中栏，六个语言段（英/阿/中/法/俄/西），与 example.com 当前正文一致；页面无 URL 栏（`page.screenshot` 只截内容区，不含浏览器 chrome）。
- **结论**：**通过**。截图可作为 C41 的可见证据；`sd ≈ 22.2` 说明不是纯白空图（有文字纹理）。

---

## 6. 用例 5：无宿主 Chrome 的降级

- **目的**：`A0_BROWSER_CHROME=/nonexistent` 时，`find_system_chrome()` 返回 `None`，`prepare_playwright_cache()` 回落到原始实现且不崩。
- **代码**：同用例 1，沙盒命令前置 `A0_BROWSER_CHROME=/nonexistent`。
- **原始输出**：

```
A0_BROWSER_CHROME = /nonexistent
find_system_chrome() -> None
prepare_playwright_cache() ->
{
  "primary": "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/tmp/playwright",
  "migrated": "",
  "removed": [],
  "errors": [],
  "binary": "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/tmp/playwright/chromium-1228/chrome-linux64/chrome"
}
binary exists: True
RC5=0
```

- **期望**：`None`；不抛异常；返回 dict 且 `errors` 可读。
- **实际**：一致。原始实现发现已有 `chromium-1228` 缓存，直接返回它，**未触发下载**、未报错。
- **结论**：**通过**（"不崩"成立）。但注意：这不是"报错降级"，而是**静默切换到下载版 Chromium**，用户不会被告知当前没有使用宿主 Chrome。

---

## 7. 用例 6：与已下载 Chrome for Testing 的关系

- **目的**：确认当前启动没有用 `chromium-1228`。
- **证据 1**：`DEBUG=pw:browser` 的启动行：

```
2026-11-17T17:25:33.507Z pw:browser <launching> /run/host/root/opt/google/chrome/google-chrome --disable-field-trial-config … --no-sandbox --hide-crash-restore-bubble --user-data-dir=…/tmp/browser/sessions/shared --remote-debugging-pipe about:blank
2026-11-17T17:25:33.510Z pw:browser <launched> pid=37
```

- **证据 2**：进程 args 扫描（本 profile 主进程 + 子进程；同时会扫到现场其它探针的 Chrome 实例，`ANY_1228_IN_ARGS` 是对全部匹配进程取并集）：

```
MAIN_PROC_ARGS: /run/host/root/opt/google/chrome/chrome --disable-field-trial-config … --no-sandbox --hide-crash-restore-bubble --user-data-dir=…/tmp/browser/sessions/shared
ANY_1228_IN_ARGS: False
ANY_1228_IN_ARGS_MAIN: False
BROWSERS_PATH_ENV: None
```

- **期望**：启动行与进程 args 指向宿主 Chrome；不出现 `chromium-1228`。
- **实际**：一致。`chromium-1228` 只在"无宿主 Chrome"的降级路径（用例 5、7）里被使用。
- **结论**：**通过**。记录：`tmp/playwright/chromium-1228` 与 `ffmpeg-1011` 属遗留可清理，但**本次不动**。

---

## 8. 用例 7：错误可读性

- **目的**：把 `A0_BROWSER_CHROME` 指向"存在但不可执行"的文件，检查 `find_system_chrome()` 与插件报错。
- **环境修正**：任务给的是 `/etc/hostname`，但**沙盒内不存在该文件**（`FileNotFoundError`）；`/etc/passwd` 存在且 `X_OK=False`，用它替代：

```
/etc/hostname is_file= False X_OK= False
/etc/passwd   is_file= True  X_OK= False
/etc/os-release is_file= True X_OK= True
```

- **代码**：`A0_BROWSER_CHROME=/etc/passwd` → `find_system_chrome()` → `hooks.prepare_playwright_cache()` → 真实 `Browser.execute(action="open", url="data:…")`（最小 stub agent，只为拿到 `agent.context.id`；`activate_browser_model` 因 stub 缺 `set_data` 打了一条 warning，不影响错误路径）。
- **原始输出**：

```
A0_BROWSER_CHROME = /etc/passwd
find_system_chrome() -> PosixPath('/etc/passwd')
prepare -> {"binary": "/etc/passwd", "errors": [], "warnings": [], "removed": [], "backup": "", "source": "system"}

Warning: Browser model preset could not be activated: 'StubAgent' object has no attribute 'set_data'
TOOL_MESSAGE_LEN: 1626
TOOL_MESSAGE_HEAD: 'Browser open failed: BrowserType.launch_persistent_context: Failed to launch: Error: spawn /etc/passwd EACCES\nCall log:\n  - <launching> /etc/passwd --disable-field-trial-config …'
TOOL_MESSAGE_TAIL: '… --user-data-dir=…/tmp/browser/sessions/shared --remote-debugging-pipe about:blank\n  - [pid=N/A] starting temporary directories cleanup\n  - [pid=N/A] finished temporary directories cleanup\n'
HAS_TRACEBACK: False
SAYS_NOT_EXECUTABLE_OR_PERMISSION: True
```

- **期望**（按任务）：`find_system_chrome()` 返回 `None`（`os.access(X_OK)` 为假），插件给出可读错误。
- **实际**：
  - `find_system_chrome()` **返回了 `/etc/passwd`**，没有做 `X_OK` 校验——`a0flatpak/browser.py` 的 override 分支只查 `candidate.is_file()`。这是与期望的偏差（见问题 P2）。
  - 报错本身**可读**：1626 字符，含 `spawn /etc/passwd EACCES`，无 `Traceback (most recent call last)`，工具层前缀 `Browser open failed:`。
- **结论**：**部分通过**。错误可读性成立；`find_system_chrome()` 的"不可执行即视为缺失"不成立。

---

## 9. 发现的问题（按严重度）

| # | 严重度 | 问题 | 证据 | 建议 |
|---|---|---|---|---|
| P1 | 高（判据失效） | **C42 在当前权限模型下无法按原样判定**：`host-os:ro` 始终暴露 `/run/host/root/opt/google/chrome`，`--reset` 掉 `/opt` override 也回不到"无 Chrome"状态；即便真的没有宿主 Chrome，原始实现会静默回退到 `chromium-1228`，`open` 照样成功，`OPEN_ERROR` 分支不出现 | 用例 5、6；`flatpak info --show-permissions` 的 filesystems 行 | 把 C42 改为"指向不可执行文件"的错误分支（本报告 §8 已验证），或明确"C42 仅适用于移除 `host-os` 权限的构建" |
| P2 | 中 | `find_system_chrome()` 的 `A0_BROWSER_CHROME` 分支只查 `is_file()`，不查 `os.access(X_OK)`；非可执行文件被当成可用二进制，错误延后到 launch，报 `EACCES` | 用例 7：`/etc/passwd` → `PosixPath('/etc/passwd')` | 改为 `candidate.is_file() and os.access(candidate, os.X_OK)`，与 `_CHROME_PATHS` 分支一致 |
| P3 | 中 | `close_runtime(context_id, delete_profile=True)` 的 `delete_profile` 参数**未被使用**（只调 `close_context`），profile 不会删除；`delete_profile=True` 后 `tmp/browser/sessions/shared` 仍在 | `helpers/runtime.py:3222-3237`；实测 `PROFILE_EXISTS: True` | 实现删除，或删除该参数并修正调用点 |
| P4 | 低 | `close_all_browsers()` 只关标签页，不关 context/Chrome；实测 `close_all_browsers()` 后 1.5 s 宿主 Chrome 主进程仍为 1，`close_runtime()` 后 1.5 s 仍为 1，解释器退出后才归 0 | p10：`MAIN_PROCS_AFTER_OPEN: 1` → `AFTER_CLOSE_ALL: 1` → `AFTER_CLOSE_RUNTIME: 1` → 宿主 `ps` 0 | 明确语义：要么真关 context，要么在文档里写清"仅关标签页" |
| P5 | 低（文档） | `functional-probes.md §7.4` 称"默认安装状态下浏览器工具不可用，必须先做 `/opt` override"——当前构建无需 override 即可命中 `/run/host/root/opt/...`；`test-matrix.md` C40 的前置（`/opt/google/chrome:ro` override）也不再必要 | 用例 1、2（§2、§3） | 更新 §7.4 与 C40 前置；同时补上 `S-BROWSER` 片段的定义（矩阵引用了这个名字，`functional-probes.md` 里实际只有 §7.5 的命令） |
| P6 | 观察（安全） | Playwright 默认 `chromiumSandbox=False`，实际命令行带 `--no-sandbox`；沙盒内 Chrome 渲染进程不使用自身 sandbox。本地桌面自动化可接受，但应知情 | `DEBUG=pw:browser` 启动行 | 如需启用，可设 `chromium_sandbox=True` 并验证 Flatpak 下是否可用 |
| P7 | 观察 | `/run/host/root/opt/google/chrome/google-chrome` 是 1034 B wrapper（属主 `nfsnobody`），不是 ELF；Patchright 用 wrapper 启动成功 | `ls -l`、`--version` | 无需处理；不要用 `file` 结果判断"不是 Chrome" |

---

## 10. 对照 `test-matrix.md` G 类

| CASE | 期望要点 | 本次实测 | 判定 |
|---|---|---|---|
| **C40** 发现宿主 Chrome | 打印 `chrome: <路径>`，`CHROME_OK` | `find_system_chrome()` → `/run/host/root/opt/google/chrome/google-chrome`；`A0_BROWSER_CHROME=/opt/google/chrome/google-chrome` → 同一路径（沙盒内 `/opt/...` 可见、`X_OK=True`）；`prepare` 返回 `source: "system"` | **通过**（路径与矩阵写法不同，但断言等价；且无需 override） |
| **C41** 打开 data: URL 取标题 | `title: 'A0 Probe Title'`，`BROWSER_OK`，不得退回下载 Patchright | `open` 返回 id=1、`title="A0 Probe Title"`；`content` 含 `plugin-ok`；启动行是宿主 Chrome，`ANY_1228_IN_ARGS=False` | **通过** |
| **C42** 权限不足时报错可读 | `chrome: None`、`OPEN_ERROR:` 非空 ≤4 KB 无裸 Traceback、`NO_CHROME_OK` | 清 override 也仍能看到宿主 Chrome（`host-os:ro`）；无宿主 Chrome 时静默回退 `chromium-1228` 并 `open` 成功。改用不可执行文件（`/etc/passwd`）时：`find_system_chrome()` 返回该路径而非 `None`，工具报 `Browser open failed: … spawn /etc/passwd EACCES`（1626 B，无裸堆栈） | **不通过（判据前置失效）**：错误可读性成立，但"无 Chrome → 报错"这条路径在产品里不存在 |
| **C43** 打开/关闭幂等 | 两次 `open` 均返回 id；`close_all` 两次不抛异常；无残留标签页 | `OPEN1_ID: 1 OPEN2_ID: 2 DISTINCT: True`；`LIST_COUNT: 2`；`CLOSE1/CLOSE2` 均返回 `{"browsers": [], …}`；`LIST_AFTER` 空；`CLOSE_RUNTIME_TWICE_OK`；本 profile 的 Chrome 进程 0 残留 | **通过** |

**可判通过的 G 类条目**：C40、C41、C43。C42 需按 §9-P1 改写判据后才能判；其"错误可读"子项已在 §8 实测成立。

---

## 11. 证据文件

| 文件 | 内容 |
|---|---|
| `~/a0-shots/80-browser-tool.png` | 插件路径打开的 example.com 截图（1024×768，mean 234.038，sd 22.215） |
| `~/a0-shots/p4.out` | 用例 3/6 的 stdout（open/内容/进程 args） |
| `~/a0-shots/pw-browser.log`、`pw-A.log` | `DEBUG=pw:browser` 启动行（宿主 Chrome、`--no-sandbox`） |

复现注意：
- 插件路径用 `runtime.get_runtime(ctx).call("open", url)`（等价于 `Browser.execute(action="open")`，见 `tools/browser.py:103`），不是 `_launch` 私有函数。
- 起 Chrome 一律独立 `--user-data-dir`；脚本结束 `ctx.close()` / `close_runtime()`；实测本 profile 无残留进程。
- 本次未重启 5080 实例、未改源码与 `conf/`。
