# 浏览器补丁复测（v20，commit `21b0e23a`）

对象：已安装 Flatpak `org.agentzero.AgentZero`（commit `21b0e23a…`），health 200，未构建、未重启。`/app/share/agent-zero/flatpak/a0flatpak/browser_guard.py` 存在（12,602 B），`__init__.py` L104-106 在 `apply()` 内调用 `browser_guard.apply()`。
前置实测：`BG_FILE=/app/share/agent-zero/flatpak/a0flatpak/browser_guard.py`、`BG_HEALTH True`、`FLAGS True True True`（`_a0flatpak_patched` / `BrowserRuntime` / 模块级均已打）。`httpstat.us` 在本机不可达（curl 000，Chrome 侧同样连不上），慢响应与 404 用本地 fixture（127.0.0.1:8799）替代，语义等价。

## §1 B1 导航上限

| 用例 | 原始输出 | 判读 |
|---|---|---|
| 慢页 | `15483 ms` / `15083 ms`，均 `{"error":"TIMEOUT",...,"detail":"Page.goto: Timeout 15000ms exceeded."}` | 15 s 预算截断；45 s 站点 **未挂死**（v14 为 45.1 s） |

## §2 B2 错误冒泡

`https://no-such-host-xyz-082706.invalid` → `{"ms":1740,"error":"NAVIGATION_FAILED","title":"no-such-host-xyz-082706.invalid","detail":"Page.goto: net::ERR_NAME_NOT_RESOLVED ..."}`。不再出现"open 成功 + 仅 stderr warning"。

## §3 B3 状态码

| 用例 | 原始输出 | 判读 |
|---|---|---|
| `/status/404` | `{"ms":92,"error":null,"status":404,"nav":{"url":"...","status":404}}` | 状态码已透出 |
| `https://example.com` | `{"ms":1277,"error":null,"status":200,"title":"Example Domain"}` | 200 正常 |

## §4 D 资源释放（3 会话）

```
D_RSS_OPEN 247748 procs 1          # 3 会话同享 1 个 Chrome
D_RSS_CLOSE_ALL 240176 procs 1     # close_all 只关标签页，Chrome 仍在（设计如此）
a0flatpak browser: browser profile kept: 2 session(s) still attached
a0flatpak browser: browser profile kept: 1 session(s) still attached
D_RSS_AFTER_TWO 240160 procs 1
D_RSS_AFTER_ALL 0 procs 0          # 最后一个 close_runtime 后 RSS 归零、进程 0
```

结论：**B4 在 `close_runtime` 处生效**（v14 为 231,780→228,824 不释放；v20 为 240,160→0）。`close_all` 的语义仍是"关标签页"，不会释放 Chrome——与上游一致，不算回归。

## §5 E profile 清理

`E_PROFILE_EXISTS False`、`du` 为空、`E_ROOT_LIST []`。`close_runtime(delete_profile=True)` 后 `$DATA/tmp/browser/sessions/shared` 真被删除（v14：3.0M→40M 只增不减）。

## §6 与 v14 对照

| 项 | v14 | v20 | 状态 |
|---|---|---|---|
| B1 慢页（45 s / 600 s） | 45.1 s / >60 s | 15.1 s 返回 `TIMEOUT`（15 s 预算） | **已修** |
| B2 DNS | open 成功 + warning | `NAVIGATION_FAILED` + detail | **已修** |
| B3 404/500 | 无 status | `status:404/200` | **已修** |
| B4 close 释放 | 228,824 KB 不回落 | `close_runtime` 后 0 / 进程 0 | **已修**（`close_all` 仍保留 Chrome，符合语义） |
| B5 文档预期 | browser_agent 不存在 | 同 | 文档问题，未变 |
| B6 profile | 只增不减 | 删除并校验 | **已修** |
| B7 httpbin 标题 | 空 | 未复测（本次不涉及） | 待定 |

## §7 结论

`browser_guard` **确实生效**：安装件里 `browser_guard.py` 被打进 `/app/share/agent-zero/flatpak/a0flatpak/`，`apply()` 内调用，健康检查与三处 `_a0flatpak_patched` 全为 True；B1/B2/B3/B4/B6 五条行为均从 v14 的旧行为切换到新行为，且 `plugin_guard` 的 purge 自愈此前已实测（purge 后仍 `source=system`、未触发 175 MB 下载）。
副作用检查：`flatpak ps` 2 条（含 1 条既有长驻，不是本次造的）、health 200；本探针 Chrome 0 个；宿主 Chrome 总数 20 = 测试前 20（均为用户桌面 Chrome，父进程 xfce4-panel）；`/tmp/playwright*` 0。测试脚本、fixture、日志已删除。
