# 浏览器工具深度测试（v14, `ab3d8e61`）

对象：Flatpak `org.agentzero.AgentZero`（commit `ab3d8e61…`，health 200）。不构建、不重启；全部探针在独立 `flatpak run` 内执行，结束即回收。

## §1 实现路径（读到的真实文件）

- `$DATA/tools/` **不存在**；内置工具在镜像 `/app/share/agent-zero/tools/`。其中 `browser._py`、`browser_open._py`、`browser_do._py` 整文件被注释（死代码）；`helpers/browser.py` 同样整文件注释。
- 真正生效：`plugins/_browser/tools/browser.py::Browser.execute(action="open")` → `plugins/_browser/helpers/runtime.py::BrowserRuntime.open`（1327）→ `_start`（1137）`from patchright.async_api import async_playwright` + `chromium.launch_persistent_context(executable_path=...)`。
- `a0flatpak/browser.py::apply()` 只替换 `hooks.prepare_playwright_cache` / `hooks.install`；v14 新增 override 的 `X_OK` 校验与 `source=bundled` 警告。
- `plugins/_code_execution/helpers/` 只有 `shell_local.py`/`shell_ssh.py`/`tty_session.py`，**没有** Playwright/Selenium；`browser_agent` 在镜像里不存在（仅 `browser` 一个工具）。任务描述里的两条路径在本构建均不成立。

## §2 A 组：页面交互

| # | 操作 | 原始关键输出 | 判读 |
|---|---|---|---|
| 1 | `open` example.com | `{"ms":2915,"title":"Example Domain","url":"https://example.com/"}`；正文首段 `This domain is for use in documentation examples without needing permission.` | 通过 |
| 2 | `open` `http://127.0.0.1:5080/` | `{"ms":240,"title":"Agent Zero","url":"http://127.0.0.1:5080/"}`；正文 `Starting Agent Zero` | 通过 |
| 3 | 3 标签 `example.com`/`httpbin.org/html`/本机 | `A3_open ids [1,2,3] titles ["Example Domain","Agent Zero",""]`；`switch → {"active":2,"title":"Agent Zero"}`；`close_browser 3 → list [[1,…],[2,…]]`；`PROCS_3TABS {"total":12,"main":1}` | 通过；第 3 页标题为空（见 §3/B7） |
| 4 | `evaluate` on example.com | `{"h1":null,"as":1,"title":"Example Domain"}` | 通过：该页当前确无 `h1`，1 个 `a` |
| 5 | `screenshot_file` | `A5.png`，`identify`：`PNG 1024x768 72336B` | 通过（>10 KB） |

## §3 B 组：异常路径

| # | 操作 | 原始关键输出 | 判读 |
|---|---|---|---|
| 6 | `https://no-such-host-xyz-051108.invalid` | `ms 2367`；stderr `warning … net::ERR_NAME_NOT_RESOLVED`；`title "no-such-host-xyz-051108.invalid"`；`now "chrome-error://chromewebdata/"`；正文 `# This site can’t be reached`（可读） | **不挂死；但 `open` 返回成功（无 error 字段）** |
| 7 | 本地 `/status/404` | `ms 105`；`title ""`；`state_keys` 无 `status`；正文仅 `status code 404` | 状态码**不透出** |
| 8 | `https://httpstat.us/500` / 本地 `/status/500` | `ms 3149`，`net::ERR_EMPTY_RESPONSE`（该服务在本机不可达）；本地 `ms 85`、正文 `status code 500` | 500 与 200 在 API 层无差别 |
| 9 | 10 MiB `text/plain` | `ms 1082`；`doc_len 10485753`；`innerText 10485700`；`transferSize 10486000` | **未截断**，全文进入上下文 |
| 10 | `/slow?delay=20` / `45` / `600` | `20085 ms` 成功；`45111 ms`（30 s 处有 `timed out waiting for domcontentloaded` 警告，但调用直到 45 s 才返回）；600 s 端点 **60 s 内不返回**（`asyncio.wait_for` 60 s 触发） | **30 s 不是有效上限**：超时只打 warning，调用继续阻塞 |

补充：6/8 的错误页正文可读；但异常信息只出现在宿主 stdout 的 `PrintStyle.warning`，工具返回值仍是 `{"id":…,"state":…}`，agent 侧无法区分成功与 DNS 失败。B10 的 600 s 用例里，取消后 `close_all`/`close_runtime` 均成功（`CLOSE_ALL_OK` / `CLOSE_RUNTIME_OK`）。

## §4 C 组：资源卫生（核心）

| 时点 | 宿主 chrome/chromium/playwright 进程 | 本探针 profile 进程 | `/tmp/playwright*`+`/tmp/.org.chromium*` |
|---|---|---|---|
| 测试前基线 | 27（均为其它探针：`a0-local-backup/chrome-v14`、`a0perf-prof-*`） | 0 | 0 |
| A/B/D/C 各轮结束后 | 12 / 22 / 14 / 32（现场其它代理在跑，不可比） | **0** | **0** |
| 沙盒内 `close_runtime` 后 1.5 s | — | `main:1`，`total:7–11` | 沙盒内 `playwright-artifacts-*` 仍在 |

- 结论：**本探针没有留下宿主 Chrome 进程，也没有留下宿主 `/tmp` 临时目录**（前后均 0）。沙盒 `/tmp` 是每次 `flatpak run` 私有的，下一次运行只剩 `.X11-unix`、`com.google.Chrome.chrome_chrome_url_fetcher_*`、`data-gym-cache`。
- 但 `close_all_browsers()` / `close_runtime()` **不结束 Chrome**：关闭后 1.5 s 主进程仍为 1，RSS 228 MB 未释放；只有解释器退出才归零。常驻 5080 实例会长期保留一个 Chrome（见 §7/B4）。
- `SingletonLock/Cookie/Socket` 在 Chrome 存活期间存在，进程退出后消失；profile 目录不会被删（`delete_profile=True` 仍被忽略）。

## §5 D 组：多页面并行

- 3 个 `BrowserRuntimeSession`（`deep-e1..e3`）**共享 1 个 core**；`asyncio.gather` 并行 `open`：`2232 ms`，`IDS [1,2,3]`，`TITLES0 ["Example Domain","","Agent Zero"]`，`DOC_LENS [962,3651,3243]`，`EVALS ["Example Domain","","Agent Zero"]`。三会话都能工作，不是"只有一个能活"。
- 内存（Chrome 主进程 RSS）：`231,780 KB`（开 3 页）→ `232,960 KB`（close_all）→ `228,824 KB`（close_runtime）。**关闭不释放**，随进程退出释放。

## §6 E 组：存储与 cookie

- profile：`$DATA/tmp/browser/sessions/shared`（沙盒内同路径）；体积 `3.0M`（基线）→ `8.9M`（A 组后）→ `40M`（全部测试后），只增不减。
- 持久化：E1 `localStorage.setItem('a0deep','v1')`，**另一个 `flatpak run`** 的 E2 读回 `"v1"`；`Default/Cookies` 20 KB 存在（example.com 无 cookie，`document.cookie` 为空）。
- 不写宿主 `~/.config`：本探针 Chrome 的 crashpad `--database=/home/kunweiz/.var/app/org.agentzero.AgentZero/config/google-chrome/Crash`（`XDG_CONFIG_HOME` 被 Flatpak 重定向）。宿主 `~/.config/google-chrome/Crash Reports/settings.dat` 的 mtime 变化与现场其它宿主侧探针（`a0perf-prof-*`）吻合，不能归因于本插件。

## §7 缺陷

| # | 严重度 | 缺陷 | 证据 |
|---|---|---|---|
| B1 | 高 | **导航无有效上限**：30 s 仅 warning，`open` 继续阻塞；45 s 站点实测 45.1 s，600 s 站点 60 s 不返回 | B10 |
| B2 | 高 | **网络/DNS 错误不冒泡**：`open` 返回成功，agent 只能从 Chrome 错误页正文猜失败 | B6、B8 |
| B3 | 中 | HTTP 状态码不透出（404/500 与 200 同形），`state` 无 `status` | B7、B8 |
| B4 | 中 | `close_all_browsers`/`close_runtime` 不结束 Chrome，228 MB 不释放；常驻实例会积留进程 | C、D |
| B5 | 低（文档） | 任务/文档预期的 `browser_agent`、code-execution 内 Playwright 均不存在；真实路径只有 `plugins/_browser` | §1 |
| B6 | 低 | `delete_profile=True` 仍被忽略；profile 无清理入口，40 MB 只增不减 | C、E |
| B7 | 低（存疑） | `httpbin.org/html` 打开后标题持续为空（2 s 后仍 `""`），正文可取 3651 字符；不排除该站被网络策略拦截 | A3、D2 |

可接受项：沙盒内 `/tmp/playwright-artifacts-*` 在单次 run 内残留，但随沙盒销毁，不污染宿主。

## §8 与既有 G 类（C40–C43）的差异

- C40/C41 只证明"能起、能取标题"；本轮证明 **标题可能为空**、`h1` 可能不存在（example.com 已改版），单看标题会误判。
- C42 把"错误可读"当作通过条件；实际错误只写到进程 stdout 的 warning，**工具响应没有 error**，比 C42 的期望更弱。
- C43 只测两次 `open`/`close_all` 不抛异常；本轮发现 `close` 不结束 Chrome、不释放内存，幂等≠生命周期正确。
- 新增覆盖：DNS 失败、30 s 超时形同虚设、10 MiB 不截断、3 会话共享 1 core、profile 40 MB 只增不减、宿主 0 残留（进程与临时目录）。

## §9 复现与清理

- 探针脚本与日志在 `~/a0-browser-probe/`（`probe_a.py`/`probe_b.py`/`probe_d.py`/`probe_d2.py`/`probe_c.py`/`probe_e*.py` 与 `A.log`/`B.log`/`B10c.log`/`D.log`），测试后删除。
- 本地 10 MiB / 慢响应 / 404/500 fixture：`/tmp/a0-browser-probe/server.py`（127.0.0.1:8799），测后停止并删除。
- 结束时：本探针 Chrome 进程 0，宿主 `/tmp` 匹配目录 0；`httpstat.us` 在本机不可达，500 用例以本地 fixture 补齐。
