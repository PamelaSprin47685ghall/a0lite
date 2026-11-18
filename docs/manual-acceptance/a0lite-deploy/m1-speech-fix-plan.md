# M1–M4 语音修复方案

- 基线：`ab3d8e6150f7`，PID 1995463，启动 04:42:42。
- 本轮只验证与改文件，**未构建、未重启 5080**；验证都用独立 `flatpak run --command=sh` 进程。

## §1 复现步骤与触发点

1. 04:52:34、04:53:47 各有一次完整 `flatpak run`（第二个实例）。`agent-zero.sh` 每次启动都 `cp -a --no-preserve=timestamps` 覆盖 `api plugins extensions webui`。
2. `plugins/*.py` 的 mtime 被刷成 04:53:47.92–57，共 2,353 个文件；运行实例的插件 watchdog 把它当成代码变更。
3. 触发链：watchdog → `after_plugin_change(python_change=True)` → `refresh_plugin_modules` → `modules.purge_namespace("plugins")`。
4. purge 后 `synthesize`/`transcribe` 的 pyc 在 05:00:00 重编译；首次失败 A1 时间 **05:00:31**，`HTTP 200 / success:false / No module named 'spacy'`。
5. 05:18:07 复测同一 PID 仍失败，STT 为 `module 'whisper' has no attribute 'load_model'`；持续坏。
6. 沙盒复现：`modules.purge_namespace("plugins")` 后重导入，`runtime.synthesize_sentences.__module__` 回到 `plugins._kokoro_tts.helpers.runtime`；`ensure()` 后回到 `a0flatpak.speech`。

## §2 根因链（三层）

- **静默吞错**：旧 `speech.apply()` 用 `except ImportError: pass`，重打失败没有日志。
- **只在启动时打一次**：补丁改的是启动时的模块/类对象；purge 后新导入的对象没有补丁。
- **没有自愈**：请求路径不知道补丁已失效，handler 仍捕获异常并返回 `200 + success:false`。
- **放大器**：`agent-zero.sh` 每次启动都重刷 `plugins`，第二次 `flatpak run` 就触发 purge；这是 V2 修复引入的回归。

## §3 修复设计（A+C，加根因）

- **根因**：`cp` 按构建幂等。标记 `$DATA/.a0-seeded-<A0_BUILD_COMMIT>`，内容为 `<commit> <build-time>`；只有标记不存在或内容变化才复制。同一构建的第二次 `flatpak run` 不再改 `plugins` mtime。`refresh_dir_mtime` 保留，单独负责 V2 的顶层目录 mtime。
- **A 自愈**：`plugin_guard` 统一守卫。`ensure(name=None)` 运行注册的幂等 patcher；patcher 用 `plugin_guard.live_modules(suffix)` 扫描 `sys.modules` 与框架加载器返回的模块，按**名字后缀或文件路径后缀**找实际加载的对象，而不是按路径 `import`。
- **触发器**（`install_hooks()` 四个）：`modules.purge_namespace` 后、`helpers.plugins.get_plugin_config` 前、`helpers.tool.Tool.__init__` 前后、`helpers.modules.import_module` 返回后。
- **C 不吞错**：所有失败经 `plugin_guard.log()` 写 `$A0_BASE_DIR/usr/logs/a0flatpak.log` 和 stderr，含 traceback。
- **speech 注册**：`register("_kokoro_tts", apply_kokoro)`、`register("_whisper_stt", apply_whisper)`；再 `register_module` 按 `_kokoro_tts.helpers.runtime`、`_whisper_stt.helpers.runtime`、两个 API handler 后缀即时 patch。
- **守卫对象**：`_kokoro_tts.helpers.runtime.synthesize_sentences.__module__` 与 `_whisper_stt.helpers.runtime.transcribe.__module__` 必须等于 `a0flatpak.speech`；不是就重打。

## §4 M2 / M4

- **M2**：`Synthesize.process` 外层先检查 `len(input["text"]) > 1200`，直接返回 **413** `{"success":false,"ok":false,"error":"SPEECH_INPUT_TOO_LONG","message":...}`，不再进引擎；沙盒实测 1300 字 → 413。
- **M4**：`_pdf_pages` 在打开后与每页渲染后读取 `pymupdf.TOOLS.mupdf_warnings()`；出现 `object out of range` / `Page tree load failed` / `non-page object in page tree` 立即抛 `ValueError: PDF could not be read: damaged page tree (...)`。`_ocr_pages` 在 `processed == 0` 时改为抛错，不再返回 `0 of N` 空文档。实测 `trunc50.pdf` 0.14 s 报错，`scan5.pdf` 正常。

## §5 构建与复验清单

1. `soak` 结束、`flatpak ps` 只剩 1 行后构建；三件套同源安装。
2. TTS 连续 3 次，每次之前强制 `modules.purge_namespace("plugins")`；三次都应 `success:true` 且 RIFF/WAVE。
3. STT 一次，返回文本而非 `whisper.load_model` 错误。
4. 5,500 字 TTS → 413 `SPEECH_INPUT_TOO_LONG`；1,200 字以内仍成功。
5. `trunc50.pdf` → 可读 `damaged page tree`，耗时 < 1 s；`scan5.pdf` 正常。
6. 同构建第二次 `flatpak run` 后，`$DATA/plugins` 的 mtime 不变，TTS 仍成功。
7. 失败日志写入 `usr/logs/a0flatpak.log`，不再有 `except ImportError: pass`。

## §6 对 report.md E 类判定的影响

E 类现在**不能算 5/5 通过**：能力存在，但会在第二次 `flatpak run` 后随机失效，且 HTTP 层把内部错误包装成 200。建议改为 **「有条件通过」**（先记 3/5：TTS、STT、长文本三项中，长文本与 STT 依赖 M1 修复），修复包复验通过后再回到 5/5。评分从 88 降到 **72–76**，平均分需按 E=74 重算；在 M1 复验通过前，不把 E 写成 PASS。
