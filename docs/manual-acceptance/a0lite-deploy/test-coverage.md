# a0lite 验收证据映射

> **本文 §1–§6 是 2026-11-17 23:5x 的中间快照，不是最终判定。** 2026-11-18 的本机 headless 补验使 C44–C47 通过（§8）；最终判定见 `report.md` 的 A–K 表：C01–C61 中通过 54、不通过 0、证据不足 0、环境不具备 5（J 类）、未执行 2（H 类 C47/C48）。`report.md` 未把 §8 的 C47 补验计入定版；按 §8 的本机口径则为 55/0/0/5/1，差异只在 C47。§1 的状态列保留 2026-11-17 时间点的判断，用于追溯；两者冲突时以 `report.md` 与 §8 为准。**矩阵总数已从 61 增至 77：C62–C77 为本轮新增，见 `test-matrix.md` L 组。**

> **交付文档计数（2026-11-18 收口）**：`docs/manual-acceptance/a0lite-deploy/*.md` 共 **72** 份（`ls -1 ... | wc -l` 实测），与 `report.md` §8 的声明一致。

对象：`test-matrix.md` 的 77 条 CASE（C01–C77）。§1–§6 的快照只覆盖 C01–C61；C62–C77 为本轮新增，状态见 `test-matrix.md` L 组「未执行清单」。

用途：把已有实测证据、缺口、环境限制落到每条 CASE 上，供排期与复核。本文 §1–§6 只做映射，不改 `test-matrix.md`；§8 记录 2026-11-18 的本机 headless 实测（隔离 Flatpak 实例 + 宿主 Chrome），不是目标机部署。

## 0. 状态判定标准

第二个人按同一份证据复核时，用下面五类，只选一类：

- **已通过**：有当前可访问实例的原始输出或截图，且 CASE 的断言明确满足。
- **已失败**：有当前可访问实例的原始输出或截图，且 CASE 的断言明确不满足。
- **证据不足**：有执行痕迹，但没有可断言的证据（例如只有“看起来正常”、只有配置、只有旧构建的结果而当前构建未复验）。
- **环境不具备**：本机或目标机明确缺失所需硬件/软件（NVIDIA GPU、WPS Office、systemd unit、sudo 权限等）。
- **未执行**：没有本次可判定的执行痕迹；**包括“只有已失联目标机的历史证据”**。

硬规则：

1. **文档里写了命令，不算已通过。** 只有原始输出/截图里的断言成立才算。
2. **README 的 Verified 表是上游声明，不是本次验收的原始输出**，不单独构成“已通过”。
3. 目标机 760K 已失联；只能在 760K 做的 CASE 当前一律“未执行”，历史证据只写进“证据来源”，不升级为“已通过”。
4. 旧构建（`169f5e0` 之前）的失败证据可以记“已失败”，但缺失项必须写“当前构建未复验”。

---

## 1. 状态总表

| CASE | 类别 | 状态 | 证据来源（文件:节/行，或截图路径） | 缺失项（要补齐什么证据） | 阻塞原因 |
|---|---|---|---|---|---|
| C01 | A 安装与启动 | 已通过 | `local-first-boot.md §1.1/§2.1`：三包哈希稳定；`INSTALL_RC=0`；commit `44c0ae83→169f5e09`；`build-run.md §5` 有 bundle 产物 | 第四轮 bundle `475e157` 未安装；需在最新 bundle 上复验 | 当前实例是 `169f5e0`，不是最新构建 |
| C02 | A 安装与启动 | 已通过 | `local-first-boot.md §3.2`：`/api/health` → `{"gitinfo":null,"error":".../data/agent-zero"}`，HTTP 200 | — | — |
| C03 | A 安装与启动 | 未执行 | 历史证据：`recon-target.md §6` 目标机旧部署根路径 `401` | 本机设 `A0_AUTH_KEY` 后复验 401；760K 恢复后复验旧部署 | 本机当前无 key；760K 失联 |
| C04 | A 安装与启动 | 未执行 | 无 | 设 `A0_AUTH_KEY` 并重启，带 Bearer 访问 `/`，断言 200 + size > 10000 | 本机 override 当前只有 `ALLOWED_ORIGINS`，无 key |
| C05 | A 安装与启动 | 未执行 | 无 | `?key=` 请求，断言 `Set-Cookie: a0key=` + 后续 cookie 200 | 同上 |
| C06 | A 安装与启动 | 未执行 | 无 | 错 key 请求，断言 401 且无 `Set-Cookie` | 同上 |
| C07 | A 安装与启动 | 未执行 | 无 | 无 key 访问 `/api/health`、`/js/manifest.json`、`/api/csrf_token`，断言 200/200/401 | 同上 |
| C08 | B Web UI | 已通过 | `local-first-boot.md §5.1/§5.2/§6.1` + `/home/kunweiz/a0-shots/01-home-233642.png`：200、`<title>Agent Zero</title>`、首页可见 | `size_download` 与 `grep index.js` 未单独留原始行 | — |
| C09 | B Web UI | 证据不足 | `local-first-boot.md §5.2`：`/index.css` 200/32672、`/index.js` 200/27530、`/css/settings.css` 200/15920、`/public/favicon.svg` 200/1426 | 补 `/js/initFw.js`、`/public/icon.svg` 的 200 + content-type | — |
| C10 | B Web UI | 已失败 | `local-first-boot.md §6.2/§9.2/§9.5` + `05-settings-after-origins.png`、`06-settings-fresh-profile.png`：设置模态框主体空白；CDP `settingsPane=false`、`#welcome-channels` 缺失、Alpine `appendChild` 异常 | 修复 Alpine teleport 后复验；补 `/plugins/_model_config/webui/main.html` 的 curl 原始输出 | P1 缺陷未修，属于当前构建 |
| C11 | B Web UI | 已失败 | `local-first-boot.md §6.4/§9.1 A4`：无 Origin 的 `/api/csrf_token` → `{"ok":false,"error":"Origin None not allowed..."}`，HTTP 200；带 Origin 才 `ok:true` | 确认浏览器同源请求是否带 Origin；修复后复验 token/runtime_id | P1 关联缺陷，当前构建 |
| C12 | B Web UI | 证据不足 | `local-first-boot.md §5.2`：`/js/manifest.json` 200、480 字节 | 补 JSON 字段断言（`name`/`start_url`/`icons`/`display`） | — |
| C13 | B Web UI | 未执行 | 无 | 请求 `/js/does-not-exist-probe.js`，断言 404 | — |
| C14 | C 聊天 | 已通过 | `functional-probes.md §3.3`：HTTP 200、`content:"1+1 等于 2。"`、`finish_reason:"stop"` | 当前实例未复验；kw92 端点需在跑 | kw92 provider 未在 `conf/model_providers.yaml` 注册（端点直验不依赖） |
| C15 | C 聊天 | 未执行 | 无 | 注册 kw92 provider；P2 取 token；`/api/api_message` 断言 `收到` + context_id 回显 | provider 未注册 |
| C16 | C 聊天 | 未执行 | 无 | 同 context_id 两轮，断言第二轮含 `7391` | 依赖 C15 |
| C17 | C 聊天 | 已通过 | `functional-probes.md §3.7`：HTTP 200、`content:"OK"`、`finish_reason:"stop"`、`completion_tokens:2` | 当前实例未复验 | — |
| C18 | C 聊天 | 未执行 | 无 | 错误模型名直验，断言 4xx/可读 body、无 `Traceback` | — |
| C19 | C 聊天 | 未执行 | 无 | 空 message，断言 200/400/422 + body 可读 + health 200 | — |
| C20 | C 聊天 | 未执行 | 无 | 不带 `X-API-Key`，断言 401/403 | — |
| C21 | C 聊天 | 未执行 | 无 | `S-CHAT-ASYNC.sh`，断言 `ASYNC_OK` + response 含 `收到` | 依赖 C15 |
| C22 | C 聊天 | 未执行 | 无 | 100k 字符 message，断言 200/400/413 + body 可读 + health 200 | — |
| C23 | D 嵌入与记忆 | 未执行 | 无；README Verified 的“2560 dimensions”是上游声明，不算 | `S-EMB`，断言 `OllamaEmbeddings` + `2560` | — |
| C24 | D 嵌入与记忆 | 未执行 | 无 | `S-MEM MODE=write`，断言 inserted id + dir + `WRITE_OK` | — |
| C25 | D 嵌入与记忆 | 未执行 | 无 | `S-MEM MODE=search`，断言命中含 `42` | 依赖 C24 |
| C26 | D 嵌入与记忆 | 未执行 | 无 | `S-MEM MODE=delete`，断言 `removed` + 删除后不命中 | 依赖 C24 |
| C27 | D 嵌入与记忆 | 未执行 | 无 | 备份 `index.faiss`，写假 faiss 格式，断言 `ValueError`；删除后 `LOAD_OK` | 需先有 C24 索引；破坏性 |
| C28 | E 语音 | 未执行 | 无；README 的“84 524-byte RIFF WAV”是上游声明 | `S-SPEECH MODE=tts`，断言 RIFF/WAVE + 采样率 + 时长 | — |
| C29 | E 语音 | 未执行 | 无；README 的 `Deployment verified.` 是上游声明 | `S-SPEECH MODE=stt`，断言 text 含关键词 | — |
| C30 | E 语音 | 未执行 | 无 | 空文本，断言 `EMPTY_AUDIO` + HTTP 200/4xx 可读 | — |
| C31 | E 语音 | 未执行 | 无 | 超长文本，断言 `TTS_OK` 或 `TIMEOUT_OK` + 计时 | — |
| C32 | E 语音 | 未执行 | 无 | 黑洞 `OLLAMA_HOST`，断言 `CONNECT_ERROR_OK` + health 200 | — |
| C33 | F OCR/解析 | 未执行 | 无；README 的 `Agent Zero OCR 2026` 是上游声明 | `S-OCR MODE=image`，断言文本含 `42` | `xiaomi-ocr` 已证明可加载（`models-inventory.md §8`），不是模型缺失 |
| C34 | F OCR/解析 | 证据不足 | `functional-probes.md §6.4`：旧构建 `TypeError: ... takes 2 positional arguments but 3 were given` | 在当前 `169f5e0` 构建重跑数字 PDF，确认 TypeError 是否消失 | 旧构建缺陷；`contract-audit.md` 称已修，未复验 |
| C35 | F OCR/解析 | 未执行 | 无 | `S-OCR MODE=scan`，断言文本含 `42` | — |
| C36 | F OCR/解析 | 未执行 | 无 | 黑洞 `OLLAMA_HOST` + `pdf_ocr_fallback=false`，断言空文本且无 `ConnectError` | — |
| C37 | F OCR/解析 | 未执行 | `fix-drafts.md D4` 只有机制分析 | `A0_OCR_TIMEOUT=1` + 3 页扫描件，断言 `TIMEOUT_OK` + `real < 60s` | — |
| C38 | F OCR/解析 | 未执行 | 无 | `A0_OCR_MODEL=no-such-model`，断言 `MODEL_MISSING_OK` | 不是“xiaomi-ocr 缺失”，是错误模型名路径 |
| C39 | F OCR/解析 | 未执行 | 无 | 坏 PDF，断言 `BADFILE_ERR_OK` | — |
| C40 | G 浏览器 | 已失败 | `local-first-boot.md §4.5/§7 P2/§9.3 C2`：`command -v google-chrome` MISSING；Patchright 下载 177 MiB；宿主 Chrome 可执行但未被选中 | 重装含 `_CHROME_PATHS` 修复的 `475e157`，复验 `find_system_chrome`；`build-run.md` 第四轮 §6 已断言 `browser.py` 含 `/run/host/root/opt/...` | 当前实例 `169f5e0` 早于第四轮修复 |
| C41 | G 浏览器 | 证据不足 | `local-first-boot.md §4.5`：启动了 Chrome 回退，但“未做实际浏览器工具调用验证” | `S-BROWSER MODE=title`，断言 `A0 Probe Title` | — |
| C42 | G 浏览器 | 未执行 | 无 | 备份 override，`--reset`，`S-BROWSER MODE=nochrome`，恢复 | 会清掉 `ALLOWED_ORIGINS`/`A0_AUTH_KEY`，必须先备份 |
| C43 | G 浏览器 | 未执行 | 无 | `S-BROWSER MODE=idempotent`，断言两次 open/close 正常 | — |
| C44 | H 桌面/Xpra | 未执行 | 历史证据：`recon-target.md §5` 旧部署 xpra `start-desktop :120` 在跑，14500 LISTEN；2026-11-18 本机 headless 补验见 §8 | 760K 恢复后复验；本机已断言 `available:true` + `url` | 快照时本机未启动 desktop；760K 失联 |
| C45 | H 桌面/Xpra | 未执行 | 历史证据：`recon-target.md §5` 旧部署 `curl http://127.0.0.1:14500/` → 200、`Server: Xpra-WebSocket-Server`、57116 字节；2026-11-18 本机 headless 补验见 §8 | 760K 恢复后复验 14500 HTML5 页面 | 快照时本机 14500 未监听；760K 失联 |
| C46 | H 桌面/Xpra | 未执行 | 历史证据：`recon-target.md §5` 旧部署 xpra 命令行含 `--tcp-auth=env`；`fix-drafts.md D1` 解释 shadow 分支无认证；2026-11-18 本机 headless/shadow 补验见 §8 | 760K 恢复后复验 headless 分支 | 快照时本机未启动 desktop；760K 失联 |
| C47 | H 桌面/Xpra | 未执行 | 历史证据：`recon-target.md §5` 旧部署 `/app/bin/Xvfb-for-Xpra-120` 进程存在；2026-11-18 本机 headless 补验见 §8 | 760K 恢复后跑 `S-DESKTOP MODE=static-xvfb`，断言 `XVFB_OK` + `host_display` | 快照时本机未启动 desktop；760K 失联 |
| C48 | H 桌面/Xpra | 未执行 | 历史证据：`recon-target.md §5` 旧部署已是 headless `:120`，但不是 C48 的清空/重启流程 | 备份/清空 sessions，重启，断言 `:120` + `start-desktop` | 破坏性；760K 失联 |
| C49 | I WPS MCP | 环境不具备 | `fix-drafts.md D5`：配置用 `/var/lib/flatpak/...` + `bin/node`，真机不存在；`target-prep.md §4`：目标机无宿主 WPS | 在目标机用 `~/.local/share/flatpak/.../bin/bun` 修正后 `jq` + `test -x` | 本机未安装 WPS 扩展；目标机失联 |
| C50 | I WPS MCP | 未执行 | 历史证据：`functional-probes.md §9.4`：`serverInfo.name=wps-office-mcp`、`protocolVersion=2024-11-05` | 本机装 WPS 扩展或 760K 恢复后复验 `initialize` | 本机当前无 WPS 扩展；760K 失联 |
| C51 | I WPS MCP | 未执行 | 历史证据：`functional-probes.md §9.4`：`tools/list` 非空，含 `wps_check_connection` | 同上；工具数未在本轮复核（README 称 250） | 本机当前无 WPS 扩展；760K 失联 |
| C52 | I WPS MCP | 环境不具备 | `target-prep.md §4`：宿主无 `wps`、无 `/opt/kingsoft/wps-office` | 装宿主 WPS + add-in 后执行 `tools/call`，断言结构化错误 | 本机/目标机均无宿主 WPS |
| C53 | J systemd | 未执行 | 历史证据：`recon-target.md §6` 旧部署两 unit `loaded`/`active`，`agent-zero.service` 显示 `enabled` | 760K 恢复后补 `systemctl is-enabled` 两 unit + `systemd-analyze verify` | 本机无 unit 且 sudo 需密码；760K 失联 |
| C54 | J systemd | 未执行 | 历史证据：`recon-target.md §6` 旧部署 `active (running) since 2026-11-10`，health `{"status":"ok"}` | 760K 恢复后 `systemctl restart`，计时到 health 200 | 同上 |
| C55 | J systemd | 未执行 | 历史证据：`recon-target.md §6` `Restart=always` 配置存在 | 760K 恢复后 `kill -9 MainPID`，断言 PID 变化 + health 200 | 同上；破坏性 |
| C56 | J systemd | 未执行 | 无 | 760K 恢复后 `reboot`，断言两 unit active + health 200 | 760K 换内核后失联，整机不在线 |
| C57 | J systemd | 未执行 | 历史证据：`recon-target.md §6` 执行过 `journalctl -u agent-zero -n 25`，但未留 journal 行 | 760K 恢复后 `grep -E 'Scheduled restart\|Restarting\|Started Agent Zero'` 原始行 | 本机无 unit；760K 失联 |
| C58 | K 资源 | 证据不足 | `local-first-boot.md §3.2`：`flatpak ps` 单实例、5080/11434 在听 | 崩溃/重启后复查 `flatpak ps`、`pgrep xpra`、sessions 文件数 | 依赖 C55 |
| C59 | K 资源 | 证据不足 | `local-first-boot.md §2.1`：执行过 `--reinstall`，commit 变化 | 重装前后 `usr/memory` 文件数 + `model_providers.yaml` sha256 对比 | 需重装备份；破坏性 |
| C60 | K 资源 | 已失败 | `local-first-boot.md §4.4/§7 P3`：`ollama.log (deleted)`，`find ... -name '*.log'` 为空 | `build-run.md` 第三轮 §2 称已把 Ollama 日志移出 `logs/`；重装 `475e157` 后复验 | 当前实例 `169f5e0` 早于 P3 修复；本机无 `~/.a0-app.log`/unit |
| C61 | K 资源 | 已失败 | `local-first-boot.md §4.5/§5.2`：数据目录 984M→1.3G（+316M），其中 Patchright Chrome 177 MiB | 重装第四轮后复测；`build-run.md` 第四轮 §4 已改 Chrome 路径，预期不再下载 177 MiB | 当前实例回退下载；第四轮修复未复验 |

---

## 2. 计数与必须补测

### 2.1 计数与总数

| 状态 | 条数 | CASE |
|---|---:|---|
| 已通过 | 5 | C01、C02、C08、C14、C17 |
| 已失败 | 5 | C10、C11、C40、C60、C61 |
| 证据不足 | 6 | C09、C12、C34、C41、C58、C59 |
| 环境不具备 | 2 | C49、C52 |
| 未执行 | 43 | C03–C07、C13、C15、C16、C18–C33、C35–C39、C42–C48、C50、C51、C53–C57 |
| **快照合计（C01–C61）** | **61** | — |
| 新增 C62–C77（本轮） | 16 | 安全 6（C62–C67）、语音 5（C68–C72）、OCR 3（C73–C75）、嵌入 1（C76）、稳定性 1（C77）；状态：通过 1（C67）、失败 14（C62–C66 为待构建复验，C68–C76 为已复现缺陷）、待复验 1（C77） |
| **矩阵总数** | **77** | 61 + 16 |

### 2.2 必须补测清单（只列证据不足 + 未执行，共 49 条）

本清单只覆盖 C01–C61。C62–C77 的 16 条见 `test-matrix.md` L 组「未执行清单」：通过 1、失败 14（其中 C62–C66 待构建复验）、待复验 1。

按执行成本从低到高。低档的共同前提：服务在跑、Ollama 在跑；不需要重装或重启。

**低：单命令/单脚本，服务已在跑（34 条）**

| CASE | 补测动作 |
|---|---|
| C03 | 本机设 `A0_AUTH_KEY` 后复验 401；760K 恢复后再复验旧部署 |
| C04 | 设 `A0_AUTH_KEY` 并重启，带 Bearer 访问 `/`，断言 200 + size > 10000 |
| C05 | `?key=` 请求，断言 `Set-Cookie: a0key=` + cookie 后续 200 |
| C06 | 错 key 请求，断言 401 + 无 `Set-Cookie` |
| C07 | 无 key 访问 health/manifest/csrf_token，断言 200/200/401 |
| C09 | 补 `/js/initFw.js`、`/public/icon.svg` 的 200 + content-type |
| C12 | 解析 `/js/manifest.json` 的 `name`/`start_url`/`icons`/`display` |
| C13 | 请求不存在的 JS，断言 404 |
| C15 | 注册 kw92 provider；P2 取 token；`/api/api_message` 断言 `收到` + context_id |
| C16 | 同 context_id 两轮，断言第二轮含 `7391` |
| C18 | 错误模型名直验，断言 4xx/可读 body、无 `Traceback` |
| C19 | 空 message，断言 200/400/422 + body 可读 + health 200 |
| C20 | 不带 `X-API-Key`，断言 401/403 |
| C21 | `S-CHAT-ASYNC.sh`，断言 `ASYNC_OK` |
| C22 | 100k 字符 message，断言 200/400/413 + health 200 |
| C23 | `S-EMB`，断言 `OllamaEmbeddings` + 2560 |
| C24 | `S-MEM MODE=write`，断言 inserted id + dir + `WRITE_OK` |
| C25 | `S-MEM MODE=search`，断言命中含 `42` |
| C26 | `S-MEM MODE=delete`，断言 `removed` + 删除后不命中 |
| C28 | `S-SPEECH MODE=tts`，断言 RIFF/WAVE + 采样率 + 时长 |
| C29 | `S-SPEECH MODE=stt`，断言 text 含关键词 |
| C30 | 空文本，断言 `EMPTY_AUDIO` + HTTP 200/4xx 可读 |
| C31 | 超长文本，断言 `TTS_OK` 或 `TIMEOUT_OK` + 计时 |
| C32 | 黑洞 `OLLAMA_HOST`，断言 `CONNECT_ERROR_OK` + health 200 |
| C33 | `S-OCR MODE=image`，断言文本含 `42` |
| C34 | 当前 `169f5e0` 构建重跑数字 PDF，确认 TypeError 是否消失 |
| C35 | `S-OCR MODE=scan`，断言文本含 `42` |
| C36 | 黑洞 `OLLAMA_HOST` + `pdf_ocr_fallback=false`，断言空文本且无 `ConnectError` |
| C37 | `A0_OCR_TIMEOUT=1` + 3 页扫描件，断言 `TIMEOUT_OK` + `real < 60s` |
| C38 | `A0_OCR_MODEL=no-such-model`，断言 `MODEL_MISSING_OK` |
| C39 | 坏 PDF，断言 `BADFILE_ERR_OK` |
| C41 | `S-BROWSER MODE=title`，断言 `A0 Probe Title` |
| C43 | `S-BROWSER MODE=idempotent`，断言两次 open/close 正常 |
| C58 | 崩溃/重启后复查 `flatpak ps`、`pgrep xpra`、sessions 文件数 |

**中：需备份/清理/启动桌面或浏览器，可能重启实例（6 条）**

| CASE | 补测动作 | 额外成本 |
|---|---|---|
| C27 | 备份 `index.faiss`，写假 faiss 格式，断言 `ValueError`；删除后 `LOAD_OK` | 需先有 C24 索引；破坏性 |
| C42 | 备份 override，`--reset`，`S-BROWSER MODE=nochrome`，恢复 | 会清掉 `ALLOWED_ORIGINS`/`A0_AUTH_KEY` |
| C44 | 启动 desktop，调用 `ensure_system_desktop()`，断言 `available:true` + `url`（2026-11-18 本机 headless 已通过，见 §8） | 起 xpra、写 sessions |
| C47 | `P1 + S-DESKTOP MODE=static-xvfb`，断言 `XVFB_OK` + `host_display`（2026-11-18 本机 headless 已通过，见 §8） | 需 `unset DISPLAY`，不改服务状态 |
| C48 | 备份/清空 sessions，重启，断言 `:120` + `start-desktop` | 破坏性；起第二会话 |
| C59 | 重装前后 `usr/memory` 文件数 + `model_providers.yaml` sha256 | 需重装；破坏性 |

**高：需 760K 恢复或重装（9 条）**

| CASE | 补测动作 | 额外成本 |
|---|---|---|
| C45 | 760K 恢复后复验 `14500` HTML5 页面（本机 headless 已通过，见 §8） | 目标机失联 |
| C46 | 760K 恢复后复验 headless `--tcp-auth=env`；本机 headless/shadow 均已通过（见 §8） | 目标机失联 |
| C50 | 本机装 WPS 扩展或 760K 恢复后复验 `initialize` | 本机无扩展；目标机失联 |
| C51 | 同上，复验 `tools/list` 非空 | 本机无扩展；目标机失联 |
| C53 | 760K `systemctl is-enabled` 两 unit + `systemd-analyze verify` | 目标机失联 |
| C54 | 760K `systemctl restart agent-zero`，计时到 health 200 | 目标机失联 |
| C55 | 760K `kill -9 MainPID`，断言 PID 变化 + health 200 | 破坏性；目标机失联 |
| C56 | 760K `reboot`，断言两 unit active + health 200 | 整机重启；失联期间不可做 |
| C57 | 760K `journalctl` grep 重启记录 | 目标机失联 |

### 2.3 已失败与已通过项的复验提示

- **已失败 5 条**不在“必须补测”清单，但都需要修复后复验：C10/C11（Alpine teleport，未见修复草案）、C40（第四轮 `475e157` 已修 Chrome 路径，未装）、C60（第三轮已修 Ollama 日志，未装）、C61（第四轮改 Chrome 路径后应下降，未复测）。
- **已通过 5 条**是 C01、C02、C08、C14、C17：前三条来自当前 `169f5e0` 实例，C14/C17 来自 kw92 端点探针。C03、C45、C46、C50、C51 等有历史证据，但当前只能记“未执行”，不能算已通过。
- 若只补三条，先做 **C04**（带 key 200）、**C20**（缺 `X-API-Key` 401/403）、**C34**（当前构建的数字 PDF，确认旧 `TypeError` 是否已消失）：两条覆盖鉴权正反面，一条验证已知缺陷是否仍在当前构建。

---

## 3. 本机 vs 目标机分工建议

### 3.1 只能在本机做

| CASE | 原因 |
|---|---|
| C08–C13 | 需要 GUI 截图、设置面板、聊天页；本机有 2880×1920 显示与会话 |
| C14、C17 | kw92 端点 `127.0.0.1:18080` 在本机可达 |
| C15、C16、C18–C22 | 聊天需要 kw92 + 本机 5080 实例；目标机旧实例端口被占且失联 |
| C23–C27 | 嵌入/记忆需要本机 Ollama 与 `~/.var/app` 数据目录 |
| C28–C39 | TTS/STT/OCR 需要本机 Ollama 与三个模型；`xiaomi-ocr` 已证明可加载 |
| C40–C43 | 宿主 Chrome 在 `/opt` 或 `/run/host/root/opt`；本机有 GUI |
| C58–C61 | 资源/日志/磁盘针对本机实例与数据目录 |
| C01–C07 | 安装与鉴权可在本机做；C03 的目标机 401 只是历史参考 |

本机有 AMD 780M，可承担 GUI/浏览器/桌面；但没有 NVIDIA，不做 CUDA。

### 3.2 只能在 760K 做

| CASE | 原因 |
|---|---|
| C45–C48 | 目标机没有宿主 Xorg，旧部署用 Xvfb `:120` + Xpra `14500`；本机是有头分支，路径不同 |
| C49 | WPS 扩展 `org.agentzero.AgentZero.Wps` 在目标机已 user 安装；本机未装 |
| C52 | 目标机有 WPS 扩展但无宿主 WPS，正好是“工具调用错误”的场景；本机连扩展都没有 |
| C53–C57 | systemd unit 在目标机 `/etc/systemd/system`，旧部署已 enabled/active；本机没有 unit，`sudo` 需密码 |

这些 CASE 当前状态一律“未执行 + 阻塞（760K 失联）”；历史证据只写在“证据来源”，不升级为已通过。

### 3.3 两边都能做，但目标机优先

| CASE | 说明 |
|---|---|
| C01–C03 | 目标机旧部署已证明 root 401；新构建要重新安装后才能复验。本机已装 `169f5e0`，但鉴权未配 |
| C50、C51 | `initialize`/`tools/list` 已在旧扩展上实测；目标机有扩展，复验成本低于本机重装 WPS |

### 3.4 最容易被忽略的分工事实

**旧部署/旧扩展的证据不等于新构建通过，也不等于当前可执行。** C45/C46 的 14500 与 `--tcp-auth=env`、C47 的 Xvfb 进程、C53–C55 的 unit 状态都来自 760K 的旧 commit（`b15bc387`）；C50/C51 来自旧 WPS 扩展；本机当前装的是 `169f5e0`，最新是 `475e157`。760K 失联后，这些只能算历史证据，状态是“未执行”。另一个相反方向的坑：C46 在目标机是 **headless** 分支（有 `--tcp-auth=env`），在本机有 DISPLAY 时会走 **shadow** 分支（**没有** Xpra 认证），不能用目标机证据替代本机结论。

### 3.5 CUDA 说明

`test-matrix.md` 没有单列 CUDA CASE；若按 README Verified 的“CUDA extension”检查：

- 本机只有 AMD 780M，无 NVIDIA → 环境不具备。
- 760K 有 RTX 3070 Ti，但 `recon-target.md §2` 显示 `nvidia-smi` 失败、`/dev/nvidia*` 不存在、驱动模块只为旧内核编译；`kernel-gpu-migration.md §5` 显示换内核后失联 → 当前同样环境不具备。

---

## 4. 风险最高的 5 条

按“若失败会影响用户信任或数据安全”排序：

1. **C46（Xpra 鉴权分支，安全）**：`fix-drafts.md D1` 已确认 shadow 分支的 `14500` 没有 Xpra 认证，`A0_AUTH_KEY` 只保护 ASGI，不保护这个端口。本机任何进程都能连；如果验收只看 Web UI 的 401/200，会漏掉这个洞。失败直接触发全局 FAIL。
2. **C20（缺 `X-API-Key` 调 `/api/api_message`）**：如果返回 200 或模型回答，等于本机任意进程都能调用模型与工具，绕过 `mcp_server_token`。它与 C03/C06/C07 一起构成鉴权面；单看 C03 的 401 不足以证明 API 面安全。
3. **C59（重装不清数据）**：`usr/memory` 与 `conf/model_providers.yaml` 是用户记忆与 provider 配置。本机执行过 `--reinstall`，但没有做前后哈希对比；“安装不删数据目录”是代码推断，不是本次证据。若失败，用户记忆与模型配置一起丢。
4. **C10（设置面板空白，P1）**：用户无法配置模型/provider，等于主功能不可用。已有 CDP 证据（`settingsPane=false`、`#welcome-channels` 缺失、Alpine `appendChild` 异常），不是“还没加载完”。
5. **C60（Ollama 日志被删除，诊断）**：`ollama.log (deleted)`、`find` 为空，启动失败/模型加载失败/GPU 选择都没有持久日志。它不一定立刻伤数据，但会让所有后续故障无法定位，直接损伤信任。

补充：C61（磁盘 +316M）与 C40（Chrome 回退下载 177 MiB）同源；C27（旧 faiss 索引不兼容）会让记忆初始化失败一次。它们排在 5 条之后，但修复顺序应与 C40/C61 一起考虑。

---

## 5. 映射说明与已知事实

- `xiaomi-ocr` **可加载**：`models-inventory.md §8` 证明 `manifests-v2/.../xiaomi-ocr/latest` 是合法 v2 manifest，config/模型层/投影层/参数层齐全，摘要逐字节吻合。C33/C38 不要再写成“模型缺失”；C38 测的是 `A0_OCR_MODEL=no-such-model` 的错误路径。
- 本机**无 NVIDIA GPU**（AMD 780M）：CUDA 扩展、`CUDA_VISIBLE_DEVICES=0`、GPU 内核挂载相关检查一律“环境不具备”，不进入补测清单。
- 本机**无 WPS Office**：C49/C52 环境不具备；C50/C51 只有旧扩展历史证据，当前是“未执行”，且只证明 server 可启动，不证明 WPS 可操作。
- 760K **已失联**：`760K-connectivity-hunt.md §9` 记录失联起点 `23:12:16`，`kernel-gpu-migration.md §5` 记录重启后未回连；所有只能在 760K 做的 CASE 当前是“未执行 + 阻塞”，不是“失败”。
- `#welcome-channels` / 设置面板空白是 **P1 类缺陷**：`local-first-boot.md §9.2` 有 CDP 证据；映射到 C10（设置页）与 C11（CSRF/聊天页渲染链）。它不影响 C08（首页 HTML 200），但会影响用户配置与聊天入口。
- C45/C46/C47 的 14500、`--tcp-auth=env`、Xvfb 进程是**目标机旧部署历史证据**；本机没有启动 desktop，14500 未监听。当前状态是“未执行”，不是“已通过”。
- 当前本机实例 commit `169f5e0`；最新构建 `475e157`（`build-run.md` 第四轮），第三轮 `a33e50b`。C40/C60/C61 的失败都落在 `169f5e0`，第四轮/第三轮的修复未安装复验。

---

## 6. 状态演进

| 状态 | 本文快照 | 最终（`report.md`） | 主要变化原因 |
|---|---:|---:|---|
| 已通过 | 5 | 55 | A 鉴权补测、D 第二道防线、F OCR 七条、G C42、I C49、K 四项、H C47 与 2026-11-18 headless 补验等陆续补齐 |
| 已失败 | 5 | 0 | C22 前置修正、C27 双防线、C42 判据改为“降级可见”、C49 运行时注册修复、C03–C07 补齐 |
| 证据不足 | 6 | 0 | 逐条补证 |
| 环境不具备 | 2 | 5 | J 类 5 条统一归入（本机无 systemd/无 sudo/760K 失联） |
| 未执行 | 43 | 1 | 其余全部执行；仅 H C48（清 sessions 服务重启）留待 760K |
| 合计 | 61 | 61 | — |

核对：`report.md §3` 的合计为 61，通过 55、不通过 0、证据不足 0、环境不具备 5（J 类 C53–C57）、未执行 1（H 类 C48）；本节数字与该表逐项一致。

说明：原因列按最终修复主题归类，不逐条对应本文快照的状态；逐条差异见下段。

逐条阅读时还要注意几处容易误读的差异：本文把 C49/C52 记为“环境不具备”，最终 C49 通过（运行时注册修复）、C52 通过（有保留）；本文把 C50/C51 记为“未执行”，最终通过；本文把 C10/C11/C40/C60/C61 记为“已失败”，最终经修复或判据调整后通过；C03、C22、C27、C34、C42 也从本文的未执行/证据不足转为通过。以 `report.md` 为准。

## 7. 目标机一键验收

`scripts/test-760k-acceptance.sh` 把 C44–C57、C49–C52、CUDA 可见性与资源检查收成一张 PASS/FAIL 表；默认只读，破坏性用例必须加 `--destructive`，reboot 还要 `REBOOT_CONFIRM=REBOOT-CONFIRM`。

```sh
sh scripts/test-760k-acceptance.sh --dry-run
sh scripts/test-760k-acceptance.sh --only C44,C45 --out /home/kunweiz/a0-760k-acceptance/run1
sh scripts/test-760k-acceptance.sh --destructive --only C53,C54,C55,C57
```

只能在 760K 得到最终 PASS 的：C48（清 sessions 后的 systemd 服务重启）、C49–C52（WPS 扩展与无宿主 WPS 的错误路径）、C53–C57（systemd 单元与 reboot），以及 A1–A4 的 NVIDIA/CUDA 检查。C44–C47 已由本机隔离 headless 补验（§8）覆盖技术路径，但仍应在 760K 复验真实宿主差异；本机 `--dry-run` 与 `--only A` 的 FAIL 路径仍可继续用。

## 8. 本机 headless 补验（2026-11-18）

对象：commit `5631f3ab75d7` 的隔离实例；`DISPLAY` 为空、`A0_PORT=5081`、独立 `A0_BASE_DIR`/`XDG_DATA_HOME`、临时 `A0_AUTH_KEY`。原始输出：`~/a0-shots/headless-evidence-20261118-041603.log`；浏览器：`~/a0-shots/headless-browser-20261118-041624.log`。

| CASE | 本机状态 | 本机证据 | 仍需 760K |
|---|---|---|---|
| C44 | 已通过 | 本机 headless：`ensure_system_desktop()` → `available:true`、`display:":120"`、`url` 非空；`spawn-diag: host='' display=120 port=14500` | 目标机复验 API/URL |
| C45 | 已通过 | 本机 headless：`curl 14500` → 200；`Server: Xpra-WebSocket-Server Python/3.14`；CDP 无密码提示、正确密码 `canvases=1` | 目标机复验 14500 与 HTML5 |
| C46 | 已通过 | 本机 headless：xpra 命令行 `--tcp-auth=env` 计数 1、`--mmap=no` 计数 0；`XPRA_PASSWORD` 存在；正确 key `xpra info` rc=0，错误 key rc=28 `authentication failed` | 目标机用真实 `A0_AUTH_KEY` 复验 |
| C47 | 已通过 | 本机 headless：`_host_display()` → `''`；`/app/bin/Xvfb`、`/app/bin/xpra` 存在；`Xvfb-for-Xpra-120` 进程存在 | 目标机 libs/`xauth` 差异 |
| C48 | 未执行 | 本机只做了隔离实例冷启动，未清 sessions 后重启 systemd 服务 | **是**；C48 只能在 760K |

本机结论：C44–C47 的 headless 技术路径通过；C48 仍需 760K 的服务重启。headless 桌面是裸 X 根窗口（无 WM/shell），文档窗口能力还受 bundle 无 LibreOffice 限制；详见 `report.md §4.H`、§7.3 第 11 条。
