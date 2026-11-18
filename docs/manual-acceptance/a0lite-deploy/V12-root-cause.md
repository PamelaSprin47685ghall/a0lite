# V12 根因与修复（desktop session NameError）
## 根因
v16 重构后 `_apply_desktop_session` 接收活模块，但其闭包 `_spawn_desktop_locked` 在 `flatpak/a0flatpak/desktop.py:287` 使用 `virtual_desktop.XPRA_START_ENV`；旧版 `_patch_status_checks`/`_patch_resize_display` 各自的函数内导入没有带进来，`virtual_desktop` 既非参数也非闭包变量 → `NameError`。
health/status 不经过 `_spawn_desktop_locked`，所以 `healthy:true` 与 `action=session` 的 `ok:false` 同时出现。
## 同类遗漏扫描
逐个核对 `_patch_launcher_setup`、`_patch_desktop_status`、`_patch_status_checks`、`_patch_resize_display`、`_apply_desktop_session` 及闭包：仅 `_spawn_desktop_locked` 缺 `virtual_desktop`。
其余 `desktop_session`、`manager`、`os/sys/shutil/subprocess/time`、`BUNDLED_*`、`_host_display`、`_display_number` 均有参数/导入/常量；`libreoffice` 已是函数内导入。共 1 处遗漏。
## 修复 diff
```diff
@@ def _apply_desktop_session(desktop_session) -> None:
     """Patch one live copy of the desktop plugin module."""
+    try:
+        from helpers import virtual_desktop
+    except ImportError as exc:
+        print(f"a0flatpak: desktop session patch skipped: {exc}", file=sys.stderr)
+        return
+
     _patch_desktop_status(desktop_session)
     _patch_launcher_setup(desktop_session)
```
延迟导入而非模块顶部裸导入：`plugin_guard` 会在 helpers 未就绪时重跑；`ImportError` 记录后下一轮可重试。
## 沙盒验证（未构建）
`PYTHONPATH=/home/kunweiz/Desktop/a0lite/flatpak:/app/share/agent-zero venv/bin/python` + `a0flatpak.apply()`：`healthy=True`、`manager_patched=True`、`closure_has_virtual_desktop=True`、`closure=('desktop_session','original_spawn','virtual_desktop')`；不再 NameError，未启动 Xpra。`py_compile` 通过。
## 为什么 purge 自愈没发现
`plugin_guard.ensure()` 只看补丁标记/健康函数，或重放 patcher；它不执行“真正建会话”的路径。`_apply_desktop_session` 已设 `manager._a0flatpak_patched=True` 且 status 健康，自愈便停止；缺失名只在 `_spawn_desktop_locked` 求值。故需构建后 smoke：`action=session` 一次。
