# 浏览器缺陷修复方案（B1/B2/B3/B4/B6，不改上游）

依据 v14 `ab3d8e61` 镜像内 `plugins/_browser/helpers/runtime.py`。只改 `flatpak/a0flatpak/`。

## §1 B1 导航无有效上限

原文 `runtime.py:2849-2864`（节选），调用点 `open`(1341)、`navigate`(1676)、恢复标签(893)：

```python
2860          await page.goto(url, wait_until=wait_until, timeout=30000)
2861      except PlaywrightTimeoutError:
2862          PrintStyle.warning(f"Browser navigation timed out waiting for {wait_until}: {url}")
2863      except PlaywrightError as exc:
2864          PrintStyle.warning(f"Browser navigation showed a native error page for {url}: {exc}")
```

30 s 只是 `page.goto` 的 timeout；警告后 `open` 继续 `_state()`(2879)，其中 `page.evaluate` 等新文档 execution context，于是一路阻塞——45 s 站点实测 45.1 s，600 s 站点 >60 s。

**修复**：总预算 `A0_BROWSER_NAV_TIMEOUT`（默认 15 s），超时 `page.stop()`，`_state` 的 evaluate 限 2 s，`open` 把 `navigation` 提到顶层。

```diff
+NAV = float(os.environ.get("A0_BROWSER_NAV_TIMEOUT", "15"))
+try:
+    resp = await asyncio.wait_for(page.goto(url, wait_until=wait_until,
+        timeout=int(NAV * 1000)), timeout=NAV + 1)
+    page._a0_nav = {"url": url, "status": getattr(resp, "status", None)}
+except (asyncio.TimeoutError, PWTimeout) as exc:
+    with contextlib.suppress(Exception): await page.stop()
+    page._a0_nav = {"url": url, "error": "TIMEOUT", "detail": str(exc)[:300]}
+except PWError as exc:
+    page._a0_nav = {"url": url, "error": "NAVIGATION_FAILED", "detail": str(exc)[:300]}
```

`_state` 改为 `asyncio.wait_for(original_state(self, bid), 2.0)`，超时返回最小 dict 并附 `state["navigation"]`；`open` 再 `result.update({k: nav[k] for k in ("error","status","url") if k in nav})`。

## §2 B2/B3 异常与状态码

异常在 2861-2864 被吞掉，`_goto` 返回 `None`，`open` 照常返回 `{"id","state"}`。实测：`Error` 与 `TimeoutError` 都在 `patchright._impl._errors`，且 `TimeoutError` 继承 `Error`；DNS 失败（`net::ERR_NAME_NOT_RESOLVED`）抛 `Error`，超时抛 `TimeoutError`——**必须先 catch `TimeoutError` 再 catch `Error`**，否则超时被记成 native error。

- B2：`Error` → `{"error":"NAVIGATION_FAILED","detail":str(exc)[:300],"url":url}`，不再只打 warning。
- B3：`response = await page.goto(...)` 即 `Response`，`response.status` 为状态码；`data:`/`about:blank`/同文档导航返回 `None`，则不写 `status`。

## §3 B4/B6 资源释放

```python
3232      if runtime:          await runtime.call("close_context")
3234      elif shared_runtime: await shared_runtime.call_for(context_id, "close_context")
```

`delete_profile` 一行未用（B6）。`close_context`(2112) 只 `page.close()`；真正关 `context`/`playwright` 并 `rmtree(profile)` 的是 `_BrowserRuntimeCore.close`(2778)，只被 `close_all_runtimes` 调用，`close_runtime` 从不调用它（B4，228 MB 常驻）。

```diff
+    if shared is not None and not _runtimes:      # 最后一个会话
+        await close_all_runtimes(delete_profiles=delete_profile)
+    elif delete_profile:
+        ...   # 其它会话仍在：清本上下文 tab 恢复态，profile 留到最后一个会话
```

`close_all_runtimes` → `runtime.close(delete_profile=True)` 已含 `context.close()`、`playwright.stop()`、`rmtree(profile_dir)`；补校验：目录仍在则再删一次，失败 `PrintStyle.warning` 并返回 `profile_deleted:false`。验收：`close_runtime(delete_profile=True)` 后 `Path(profile_dir).exists() is False`。

## §4 能否落到 patch 层

- **B1/B2/B3：能（已实测）。** `a0flatpak/browser.py` 新增 `_patch_navigation()`，`setattr` 替换 `_BrowserRuntimeCore._goto/_state/open/navigate` 并标记 `_a0flatpak_nav_patched`；沙盒内 monkeypatch 后：404 返回 `status:404`（108 ms），`/slow?delay=45` 在 17.1 s 返回 `{"error":"TIMEOUT"}`。风险：私有函数换签名即失效（用 `inspect.signature` 校验，不符则跳过并 warning）；`page.stop()` 取消的导航在关闭时会抛 `TargetClosedError` 未取回，需 `suppress` 或保留 task 引用。
- **B1 兜底：能。** 替换 `BrowserRuntime.call_for`，对 `open`/`navigate` 再包 45 s `wait_for`（须大于 15 s）。
- **B4/B6：能，但有导入时绑定问题。** 替换模块级 `close_runtime`/`close_runtime_sync`；扩展 `_10_cleanup_browser_runtime.py` 用 `from ... import close_runtime_sync` 在导入时绑定，必须在它导入前打补丁（见 §6）。
- **B4 工具语义：能但需提示词。** 新增 `quit` action 要改上游 `prompts/agent.system.tool.browser.md`；不建议，先靠 `close_runtime` 自动释放。

## §5 构建与复验清单

1. 打包安装后 health 200（soak 结束后再重启）。
2. B1：`/slow?delay=45` 与 `600` 均在 `NAV+1` 内返回 `{"error":"TIMEOUT"}`。
3. B2/B3：`.invalid` 返回 `NAVIGATION_FAILED`（detail 含 `ERR_NAME_NOT_RESOLVED`）；404/500 带 `status`；`data:` 无 `status`。
4. B4/B6：close 后 1.5 s 本 profile Chrome 主进程 0、RSS 归零、`sessions/shared` 不存在。
5. 回归 A 组 5 条、C41、C43；日志无 `Traceback`。

## §6 与 M1 同源的风险

`plugins/_browser` 与 `_kokoro_tts` 同为插件；M1 根因是 `purge_namespace("plugins")` 后模块换新、补丁留在旧对象，且 `apply()` 用 `except ImportError: pass` 静默失败。本方案的 `_goto`/`close_runtime` 替换同样会在热重载后失效。

1. `a0flatpak/browser.py` 提供 `ensure()`：`getattr(core, "_a0flatpak_nav_patched", False)` 为假就重新 import 并重打；**禁止 bare except**，失败必须打印并计数。
2. 守卫挂两个核心模块（purge 不动 `helpers`）：`helpers.plugins.get_plugin_config`（`name=="_browser"` 时先 `ensure()`，`_start` 必过）与 `helpers.tool.Tool.__init__`（每次工具调用，覆盖“每次执行重新加载”）。
3. 守卫只做一次 `getattr`，热路径不额外 import。
4. 复验：`purge_namespace("plugins")` 后再开 slow URL，仍应 ≤16 s 返回 `TIMEOUT`；丢失时打印 `browser patch missing after plugin reload`。
5. 与 M1 共用入口 `a0flatpak.ensure()`，避免两套逻辑漂移。
