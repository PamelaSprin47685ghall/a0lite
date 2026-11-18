# v15–v18 修复运行记录

- 基线：v14 `ab3d8e61`；最终安装 v18 `be957363ef7e`。
- 本轮只改打包层，未改上游 checkout，未 commit。

## §1 v15 与 v16/v17/v18 的差异与原因

- **v15（72842c7a，744 s）**：M1 根因修复（`cp` 按构建幂等）、`plugin_guard` 自愈、F1/F2/F3 首版、M2/M4。安装后 `verify-security-fix.sh` 只有 9/12：`sensitive_paths` 的 guard 打在 `/app` handler 上，运行实例的 `$DATA/api/*` handler 是另一份对象。
- **v16（0eda9fe1，715 s）**：`sensitive_paths` 改为按 live 模块 patch（`plugin_guard.register_module` + 路径后缀扫描），`verify-security-fix.sh` 12/12；TTS/STT/purge 通过。
- **v17（d8c5b96a，628 s）**：先加入 `_TeeLog` 的 `fileno` 修复与 `A0_COMMIT_TIME`；但 `visual-audit` 的 V12（desktop 延迟 import）在 06:10:47 才落盘，v17 主包 06:09 已出，未包含 V12。
- **v18（be957363，648 s）**：用 `scripts/build.sh` 重新 `cp -a` 当前 `flatpak/`，同时包含 `_TeeLog`、四键 build-info、V12。v18 为最终基线。

## §2 `__init__.py` 最终行序

`base_dir.apply()` → `plugin_guard.install_hooks()` → `version.apply()` → `sensitive_paths.apply()` → `speech.apply()` → `desktop.apply()` → `mcp_cache.apply()` → `browser_guard.apply()` → `serve.apply()` → `_APPLIED=True`。

## §3 三件套 hash（v18 为当前）

| 包 | mtime | size | sha256 |
|---|---|---:|---|
| main | 06:20:08 | 60,318,144 | `cad5083175319481b8c104e0bc9062675dcc7aeb4f93f1de4521a6f2f4f8a8be` |
| cuda | 06:27:57 | 860,274,832 | `5a1b5c41da3f1d4b6ff2d479e9e09d40ee3f5f931e5d5ec80b68b5f0f3a9b7e3` |
| wps | 06:29:36 | 50,210,360 | `e84bbed03b97c3aadf8b4945e60db810658b3d21e6a1f935da4dac1719a41dfe` |

- v16 当时：main 60,536,280 / `4d88526b80d2…`；cuda 860,279,952 / `6dd2ef682dcc…`；wps 50,211,368 / `818feb212e07…`。v17 main 60,475,072 / `d8c5b96a`。

## §4 六条复验原始输出

1. `flatpak info --show-permissions | grep -c nofilesystem` = **0**；安装 metadata 的 `filesystems=` 实际有 8 条 `!~/.ssh`、`!~/.gnupg`、`!~/.pki`、`!~/.local/share/keyrings`、`!~/.config/gh`、`!~/.aws`、`!~/.docker`、`!~/.kube`。
2. `scripts/verify-security-fix.sh --expect new`：**12/12 PASS，0 FAIL，0 SKIP**。
3. TTS：`TTS_HTTP=200`，`{"success":true,"error":null,"audio_len":286780}`；WAV 215,084 B，`ffprobe` 4.48 s。
4. STT（同一 WAV，连跑 3 次）：三次均 `success:true`，`text` 均为 `"Nihau. Zhi shi yan shou tan zhen. Qing he cheng yu yin."`（拼音，不是汉字）。
5. purge 自愈：`touch $DATA/plugins/_kokoro_tts/helpers/runtime.py` 与 `_whisper_stt` 同名文件后，TTS 仍 200/`success:true`（audio_len=297020）；随后 STT 200，`text="你好,这是验收探针,请合成语音。"`。
6. `/api/health`：200；`gitinfo.version=058582f-dirty`、`commit_time=2026-11-02T18:56:58Z`、`build_time=2026-11-17T22:18:48Z`、`error=null`。

- `/app/share/agent-zero/.a0-build-info` 四行：`A0_BUILD_VERSION=058582f-dirty`、`A0_BUILD_COMMIT=058582f`、`A0_COMMIT_TIME=2026-11-02T18:56:58Z`、`A0_BUILD_TIME=2026-11-17T22:18:48Z`。
- WPS：`mcp_servers_status` → `{"name":"wps_office","connected":true,"tool_count":250,"error":""}`。
- desktop：`desktop_session {action:"session"}` → 200、`available:true`、`display:":0"`、`session_id:"agent-zero-desktop"`，无 NameError。

## §5 T1：`_TeeLog` 缺 `fileno`

- 现象：WPS MCP 初始化报 `AttributeError: '_TeeLog' object has no attribute 'fileno'`；`tool_count=0`；`run-v18.log` 中 `_TeeLog` 计数 0（修复后）。
- 修复：`_TeeLog` 增加 `fileno()`（返回被 tee 的临时文件 fd，失败抛 `io.UnsupportedOperation`）、`isatty()`、`writable()`、`readable()`、`seekable()`、`encoding`、`errors`、`closed`；`__getattr__` 委托原对象；`write`/`flush`/`close` 保持幂等，close 后 write 抛 `ValueError`。
- 自测：`fileno` 返回 `int`；`isatty` 返回 `bool`；`subprocess.Popen(stderr=tee)` 把 `SUBPROCESS_STDERR` 写入临时文件；`StringIO` 的 `fileno` 抛 `UnsupportedOperation`；`__getattr__('mode')` 返回原对象属性。
- 结果：WPS `connected:true`、250 工具，`_TeeLog` 错误消失。v17 已含，v18 继续保留。

## §6 遗留问题（4 条）

1. `--talk-name=org.freedesktop.Flatpak` 仍允许宿主命令；本轮只遮蔽私钥类目录与写白名单。
2. `A0_AUTH_KEY` 默认空，本机任意进程仍可取 CSRF 后调 `/api/message`。
3. STT 连续 3 次均返回拼音而非汉字；能力可用但语言输出不稳定，属模型行为，非 M1。
4. `scripts/build.sh` 每次重建会改写 `$A0_SRC/flatpak/org.agentzero.AgentZero.Wps.yml` 的 deps pin；仓库 pin 不跟随，需在发布时决定是否提交新 pin。

## §7 已知口径问题

- `flatpak info --show-permissions` **不显示** `!` 负权限，因此 `grep -c nofilesystem` 为 0；应读 `flatpak info --show-location` 下的 `metadata`。
- `/a0` 由 launcher 在应用进程内创建；独立 `flatpak run --command=sh` 看不到它。检查应读 `/proc/<run_ui pid>/root/a0` 或走文件 API。
- 验证脚本已按上述两条修正；`--expect new` 的 12 项仍分别检查真实行为，未放宽断言。
