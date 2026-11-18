# V1–V4 修复方案（只设计，不执行）
- 基线：运行实例 `4d0ccd2c`；`scripts/build.sh` 一次构建主包 + Cuda + Wps，共用同一 `A0_SRC`，约 8–11 分钟。约束：本轮不落盘、不构建；先合并并行 worker 的 `flatpak/a0flatpak/desktop.py`。部署 commit 只有 build/install 后才产生，不能写进同一次构建。
## V1｜Version unknown unknown + 自更新 console error
**根因链**：`agent-zero.sh:263` 只设 `GIT_PYTHON_REFRESH=quiet`，沙箱无 `git`；`helpers/git.py:383-398` 的 `get_git_info()` 抛错；`helpers/ui_server.py:313-320` 回退 `"unknown"`；`helpers/self_update.py:801-804 → 160-168` 直接 `subprocess.run(["git",...])`；`self-update-store.js:499-524` 打 console error，`settings-store.js:553` 在设置打开时触发。**改动**：打包层注入版本，不改上游 Python；`a0flatpak` 对打包版直接用 build-info 替换 `get_git_info()`，自更新噪音用 webui 守卫短路（`body[data-a0-flatpak]`），不伪造更新数据。
```diff
--- a/scripts/build.sh
+++ b/scripts/build.sh
@@ -29,1 +29,2 @@
 cp -a "$HERE/flatpak" "$A0_SRC/"
+printf 'A0_BUILD_VERSION=%s\nA0_BUILD_COMMIT=%s\nA0_BUILD_TIME=%s\n' "$(git -C "$A0_SRC" describe --tags --always --dirty 2>/dev/null || echo unknown)" "$(git -C "$A0_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$A0_SRC/flatpak/build-info.env"
--- a/flatpak/org.agentzero.AgentZero.yml
+++ b/flatpak/org.agentzero.AgentZero.yml
@@ -208,1 +208,3 @@
       - cp -a . /app/share/agent-zero/
+      - install -Dm644 flatpak/build-info.env /app/share/agent-zero/.a0-build-info
+      - patch -p1 -d /app/share/agent-zero -i /app/share/agent-zero/flatpak/patches/flatpak-ui.patch
--- a/flatpak/agent-zero.sh
+++ b/flatpak/agent-zero.sh
@@ -261,2 +261,5 @@
 # The sandbox has no git binary; GitPython warns on import otherwise.
 export GIT_PYTHON_REFRESH=quiet
+if [ -r "$APP_ROOT/.a0-build-info" ]; then
+    set -a; . "$APP_ROOT/.a0-build-info"; set +a
+fi
```
新文件 `flatpak/a0flatpak/version.py`（完整内容），并在 `__init__.py` 的 `base_dir.apply()` 后调用 `version.apply()`：
```python
+import os
+def _v(n): return os.environ.get(n, "").strip()
+def apply():
+    from helpers import git
+    if getattr(git, "_a0flatpak_version_patched", False): return
+    def get_git_info():
+        return {"branch": "flatpak", "commit_hash": _v("A0_BUILD_COMMIT"), "commit_time": _v("A0_BUILD_TIME"),
+                "tag": _v("A0_BUILD_VERSION"), "short_tag": _v("A0_BUILD_VERSION"), "version": _v("A0_BUILD_VERSION")}
+    git.get_git_info = get_git_info
+    git._a0flatpak_version_patched = True
```
```diff
+    from a0flatpak import version
+    version.apply()
```
**复验**：`curl -s :5080/api/health | jq` → `gitinfo.version` 非空、`error:null`；页脚 `Version v2.15 <ISO>`；console error 0。**回滚**：删 `version.py`，反向应用 diff，重装旧 bundle。**风险**：打包版固定返回 build-info，不再查询 `.git`（bundle 已删除 `.git`）；无 build-info 时页脚隐藏。
## V2｜文件浏览器 7 行显示 1/1/70
**根因链**：flatpak-builder 把源 mtime 归一为 epoch；`agent-zero.sh:50/54/97` 的 `cp -a` 保留 epoch；`file-browser.html:414` 直接 `formatDate(file.modified)`，无 epoch 保护。**改动**：只对复制动作关闭时间戳保留（`cp -a --no-preserve=timestamps`），用户文件从未被 `cp`，mtime 不受影响；显示时间为复制时间，不再出现 1970。
```diff
--- a/flatpak/agent-zero.sh
+++ b/flatpak/agent-zero.sh
@@ -46,1 +46,1 @@
-    cp -an "$APP_ROOT/prompts/." "$BASE_DIR/prompts/" 2>/dev/null || true
+    cp -an --no-preserve=timestamps "$APP_ROOT/prompts/." "$BASE_DIR/prompts/" 2>/dev/null || true
@@ -50,1 +50,1 @@
-        cp -a "$APP_ROOT/$name" "$BASE_DIR/$name" 2>/dev/null || true
+        cp -a --no-preserve=timestamps "$APP_ROOT/$name" "$BASE_DIR/$name" 2>/dev/null || true
@@ -54,1 +54,1 @@
-    cp -a "$APP_ROOT/usr/." "$BASE_DIR/usr/" 2>/dev/null || true
+    cp -a --no-preserve=timestamps "$APP_ROOT/usr/." "$BASE_DIR/usr/" 2>/dev/null || true
@@ -97,1 +97,1 @@
-        cp -a "$APP_ROOT/$name/." "$BASE_DIR/$name/" 2>/dev/null || true
+        cp -a --no-preserve=timestamps "$APP_ROOT/$name/." "$BASE_DIR/$name/" 2>/dev/null || true
```
**复验**：文件浏览器 `/a0` 无 `1/1/70`；`find ~/.var/app/.../data/agent-zero -maxdepth 2 ! -newermt 1970-01-02` 为空；改过的 `conf`/`prompts` mtime 不变。**回滚**：改回 `cp -a`，重装旧 bundle。**风险**：单位为“复制时间”而非构建时间；每次启动 merge 会刷新 webui/api/plugins 的 mtime，但内容同样被刷新，语义一致。
## V3｜桌面 resize 返回 400（xrandr 缺失）
**根因链**：`desktop_session.py:456-467` → `helpers/virtual_desktop.py:236-252`，`shutil.which("xrandr")` 为空即 `ok:false`；`desktop-store.js:2181` 把 400 暴露为失败。
**推荐：跳过 resize，不装 xrandr。** 当前是 host-display 路径，xrandr 会改用户真实显示器分辨率；xpra 客户端可自行缩放。补丁放 `a0flatpak`。
```diff
--- a/flatpak/a0flatpak/desktop.py
+++ b/flatpak/a0flatpak/desktop.py
@@ def _patch_status_checks() -> None:
+def _patch_resize_display():
+    from helpers import virtual_desktop
+    if getattr(virtual_desktop, "_a0flatpak_resize_patched", False): return
+    original = virtual_desktop.resize_display
+    def resize_display(**kw):
+        if shutil.which("xrandr"): return original(**kw)
+        w, h = virtual_desktop.normalize_size(kw.get("width", 0), kw.get("height", 0))
+        return {"ok": True, "width": w, "height": h, "resized": False, "note": "xrandr missing"}
+    virtual_desktop.resize_display = resize_display
+    virtual_desktop._a0flatpak_resize_patched = True
@@ def apply() -> None:
     _patch_status_checks()
+    _patch_resize_display()
```
**备选（不推荐）**：manifest 的 xpra module 加 `x11-xserver-utils_7.7+11_amd64.deb`（sha256 `71819f316a8f141e2e9b69d871720b854c07b86d79923200c7eafa306bffbd36`），`install -Dm755 unpacked/usr/bin/xrandr /app/bin/xrandr`；`libXrandr.so.2` 已在 runtime。风险是改宿主分辨率。
**复验**：调整桌面面板，`/desktop/resize` 返回 200 且 body 含 `"resized":false`，无 400。**回滚**：删函数与调用。**风险**：面板尺寸变化只缩放/留边，不改真实分辨率（比改宿主屏幕安全）。
## V4｜移动端右侧 rail 压住内容
**根因/落地**：`webui/components/canvas/right-canvas.css:41-61` 的 rail 在 `≤640px` 未隐藏；`right-canvas.html:31` 只按偏好 `rightCanvasRail` 显示。仓库无 webui 覆盖机制，但 `agent-zero.sh:94-99` 每次从 bundle 整树复制，**可在构建时补 CSS**：新增 `flatpak/patches/flatpak-ui.patch`（含 `index.html` 标记、`settings-store.js` 守卫、下面的 CSS；manifest 的 `patch -p1` 行在 V1 hunk）。
```diff
--- a/webui/components/canvas/right-canvas.css
+++ b/webui/components/canvas/right-canvas.css
@@ -402,1 +402,3 @@
 }
+
+@media (max-width: 640px) { .right-canvas-rail { display: none !important; } }
--- a/webui/index.html
+++ b/webui/index.html
@@ -225,1 +225,1 @@
-<body class="dark-mode device-pointer" x-data>
+<body class="dark-mode device-pointer" x-data data-a0-flatpak="1">
--- a/webui/components/settings/settings-store.js
+++ b/webui/components/settings/settings-store.js
@@ -551,2 +551,3 @@
   refreshUpdateStatus(force = false) {
+    if (document.body.dataset.a0Flatpak) return;
     const selfUpdate = this.selfUpdate;
```
**复验**：390×844 下 `getComputedStyle(document.querySelector('.right-canvas-rail')).display === "none"`；气泡无遮挡；首页卡片右缘完整；无横向滚动。**回滚**：移除补丁与 manifest 行。**风险**：移动端失去 Files/Browser/Desktop/Editor 入口；若要保留，必须上游改成抽屉。
## 一次构建的排序
0 合并并行 `desktop.py` → 1 V1 版本注入 → 2 V2 mtime → 3 V3 resize 降级 → 4 V4 rail CSS → 5 一次 `build.sh`（主/Cuda/Wps 同源）。
四条全部在主包，不需要分两次构建；Cuda/Wps 内容不变，但仍用同一 `A0_SRC` 重打/重装，避免版本错位。安装后记下新 `flatpak info` commit，再复验 V1–V4。
