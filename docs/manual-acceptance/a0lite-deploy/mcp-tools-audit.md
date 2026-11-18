# WPS MCP 250 工具逐个审计（只读实测）

实例 `http://127.0.0.1:5080`，commit `ab3d8e61`，2026-11-18。方法：全量静态扫描 250 条 schema + 27 个工具动态调用（35 次）+ 3 类旁证（a0 进程内调用、server 源码、`~/.wps-office-mcp/logs`）。宿主未安装 WPS（无 `/usr/bin/wps`、`/opt/kingsoft`、`~/.local/share/Kingsoft`），58891 反向轮询桥没有加载项；因此测的是**协议层与语义层**，不是 WPS 功能本身。

## §1 工具清单概览

| 维度 | 结果 |
| --- | --- |
| 总数 | **250**（`tools/list` 与 a0 `mcp_server_get_detail` 完全一致，名称集合相同） |
| 构成 | 内置 12（`mcp-server.js`）+ 专业 238（`dist/tools/index.js`） |
| 按 category 字段 | presentation 116 / spreadsheet 85 / document 34 / common 15 |
| 按名称前缀 | `wps_ppt_*` 115、`wps_excel_*` 82、`wps_word_*` 32、`wps_common_*` 7、`wps_get_*` 5、`wps_convert_*` 2、其余 7 个单件 |
| 动词分布 | set 65、get 24、insert 20、create 16、add 13、delete 10 |

完整导出：**`mcp-tools-250.json`**（同目录，250 条 `{name, description, inputSchema}`，194 KB，取自 `/api/mcp_server_get_detail`；重建命令见 §8）。a0 接口字段名为 `input_schema`，导出时改名为 `inputSchema`，内容与 MCP `tools/list` 一致。`dist/tools/index.js` 头注释写"247 个、PPT 112"，与实际差 3。

## §2 抽样调用结果（27 个工具、35 次调用）

判定口径：`isError` 为 MCP 协议层返回值；"超时"= 我的客户端 45 s 内未收到响应（a0 实际上限 120 s，见 §3 注）。

| # | 工具 | 参数 | 耗时 | isError | 结果片段（≤100 字） |
| --- | --- | --- | ---: | --- | --- |
| 1 | `wps_check_connection` | `{}` | 30.02 s | **false** | `{"connected":false,"status":{"connected":false,...}}` |
| 2 | `wps_common_ping` | `{}` | 30.00 s | true | `WPS连接检测出错: Command timeout after 30000ms: ping` |
| 3 | `wps_common_get_app_info` | `{}` | 30.00 s | true | `获取应用信息出错: Command timeout after 30000ms: getAppInfo` |
| 4 | `wps_common_wire_check` | `{}` | 30.00 s | true | `通信线路检查出错: Command timeout after 30000ms: wireCheck` |
| 5 | `wps_common_save` | `{}` | 30.01 s | true | `保存出错: Command timeout after 30000ms: save` |
| 6 | `wps_convert_to_pdf` | `{}` | 30.00 s | true | `PDF导出出错: Command timeout after 30000ms: convertToPDF` |
| 7 | `wps_ppt_add_chart` | `{slideIndex:1,chartType:"bar",data:[{label:"A",value:1}]}` | 30.01 s | true | `插入图表出错: Command timeout after 30000ms: insertPptChart` |
| 8 | `wps_list_cache` | `{}` | 0.00 s | false | `{"success":true,"count":0,"caches":[]}` |
| 9 | `wps_clear_cache` | `{key:"probe"}` | 0.00 s | false | `{"success":true,"message":"缓存 \"probe\" 已清除"}` |
| 10 | `wps_cache_data` | `{key:"probe",data:{v:1},appType:"et"}` | 0.00 s | false | `{"success":true,...,"cacheSize":1}` |
| 11 | `wps_get_cached_data` | `{key:"probe"}`（**同进程**） | 0.00 s | false | `{"success":true,"key":"probe","data":{"v":1},"cachedAt":"..."}` |
| 12 | `wps_get_cached_data` | `{key:"p0"}`（**a0 路径，前一次 cache 已成功**） | 0.00 s | true | `{"success":false,"error":"缓存键 \"p0\" 不存在","availableKeys":[]}` |
| 13 | `wps_ppt_set_active_target` | `{clear:true}` | 0.00 s | false | `已取消目标文稿锁定，后续 PPT 操作使用当前活动文稿。` |
| 14 | `wps_cache_data` | `{key:123,data:"not-an-object"}` | 0.01 s | false | `{"success":true,"key":123,...}` ← 类型未被校验 |
| 15 | `wps_cache_data` | `{key:"onlykey"}`（缺 data） | 0.00 s | true | `Missing required parameter: data` |
| 16 | `wps_cache_data` | `{key:"ok",data:{a:1},bogusField:true}` | 0.00 s | false | 成功，未知字段静默忽略 |
| 17 | `wps_word_insert_text` | `{text:123}` | 0.00 s | true | `Tool execution failed: ... text.trim is not a function` |
| 18 | `wps_get_active_document` / `get_active_workbook` / `get_active_presentation` / `excel_get_sheet_list` / `ppt_get_slide_count` / `word_set_font` / `word_generate_toc` / `excel_write_range` / `get_cell_value` / `insert_text` | `{}` / `{font_size:14}` / `{range:"A1",data:[["x",1]]}` | >45 s | — | 十个查询与操作类全部无响应（历史 69.3 s 返回 `code 1003`） |
| 19 | `wps_ppt_create_presentation` / `excel_open_workbook` / `word_open_document` / `ppt_open_presentation` | `{}` / `{filePath:"/tmp/.../nonexistent.*"}` | >45 s | — | 四个创建与打开全部无响应；**不存在的路径未被提前拒绝**，先尝试拉起应用 |

**0 次崩溃、0 次 500、0 次协议错误**。

耗时严格三档：**0.0 s（纯内存）/ 30.0 s（无应用切换）/ ≥45 s（带 switchApp，历史 69.4 s）**。30 s = `executeCommand` 默认超时；69 s = switchApp 30 s + 命令 30 s + 退出等待。**唯一挂死观察**：不套 `flatpak-spawn` 直接跑 bun 时，`switchApp` 调用的 `wps-auto.sh` 在缺少 X/flatpak 上下文时 8 分钟不返回，`wps_get_active_document`、`wps_ppt_create_presentation` 各 1 次；a0 走 `flatpak-spawn --host`，历史日志显示 69 s 正常返回，故不判为 a0 缺陷。

## §3 三类错误语义

**A. 正常拒绝（`isError:true` + 可读中文）— 9 个**
`wps_common_ping`、`wps_common_get_app_info`、`wps_common_wire_check`、`wps_common_save`、`wps_convert_to_pdf`、`wps_ppt_add_chart`、`wps_word_insert_text`、`wps_cache_data`（缺参）、`wps_get_cached_data`（缺参/键不存在）。
消息含动作名、超时值、缺失参数名；无堆栈、无裸异常。**质量合格**，唯一缺点是必须等满 30 s 或 69 s。

**B. 语义缺陷（`isError:false` 但业务失败）— 1 个**
`wps_check_connection`。根因：`dist/server/mcp-server.js:128` 把 `success` 写死 `true`，失败只出现在文本里；MCP 层 `isError: !success`（同文件 :94）于是恒为 false。模型会把"未连接"当成功。

**C. 真缺陷 — 8 项**（§7 MT1–MT6、MT10、MT11）。核心三项：进程重启导致缓存失效、58891 端口占用静默降级、schema 类型不校验。

## §4 `wps_check_connection` 精确计时与判定

| 场景 | 耗时 | isError | 返回 |
| --- | ---: | --- | --- |
| 直连 MCP server（本次） | **30.02 s** | false | `{"connected":false,"status":{"connected":false,"error":"Connection check failed"}}` |
| a0 进程内 `call_tool`（本次） | ~30 s | false | 同上，原样透传 |
| 历史日志（`error.log`，7 次） | 30.001–30.015 s | — | `ping - FAILED` |

**判定：确认缺陷**。30 s 是 `ping` 不在 `COMMAND_APP_MAP`、跳过 switchApp 后等满 `executeCommand` 的 30000 ms。语义上应为 `isError:true`：该调用**没有**完成用户要求的检测——它只是报告"检测失败"。这是唯一一个把失败写进 `success:true` 的工具。

附带缺陷：`status.error` 只写不清（`wps-client.js:253`），先失败后成功会同时出现 `connected:true` 与旧 `error`。

## §5 schema 质量问题

| 类别 | 数量 | 明细 |
| --- | ---: | --- |
| 省略 `required` 键（应为 `[]`） | 17 | 内置 6/12 + 专业 11/238（`excel_get_sheet_list`、`word_get_document_text`、`word_set_paragraph` 等） |
| `properties` 为空 / `type`≠object / `required` 指向缺失属性 | 22 / 0 / 0 | 结构层干净，问题全在语义层 |
| 零必填却有参数（可零参调用有入参工具） | **29** | 其中 23 个是写操作：`excel_update_pivot_table`(12 参)、`excel_update_chart`(10 参)、`word_set_paragraph`、`ppt_beautify` |
| 描述 <8 字 | 3 | `excel_set_print_area`(6)、`excel_set_conditional_format`(7)、`excel_subtotal`(7) |
| 描述列枚举但 schema 无 `enum` | 1 | `ppt_add_chart.chartType`（bar/line/pie/scatter/area/doughnut，实际任意字符串） |
| **同名参数类型冲突** | 11 个工具 | `position`：3 种类型（number/object/string+enum）、7 个不同枚举域；`column`：`insert_column` 是 number、`insert_columns` 是 string；`data`：`add_chart` 是 array、`insert_ppt_chart` 是 object——后两组调的是**同一个后端方法**，必有一个传错 |
| 必填与实现自相矛盾 | 1 | `excel_hide_column`：`count` 在 `required` 里，描述写"默认1"，实现写 `count = 1` |
| 内置 vs 专业描述长度 | 中位 16 vs 63 字 | 内置工具文档几乎为空 |

最严重的一条不是"字段缺失"，而是**类型检查实际不生效**：`{key:123, data:"not-an-object"}` 被接受（声明为 string/object），错误要到 JS 运行时才以 `text.trim is not a function` 形式暴露。MCP 层没有用 `inputSchema` 校验，模型传错类型拿不到字段级提示。源码与线上 schema 250/250 逐项一致，说明这是设计选择而非部署漂移。

## §6 子进程健康

| 检查 | 结果 |
| --- | --- |
| 空闲时 MCP 子进程数 | **0**（设计如此：a0 每次操作新建 stdio 会话，`mcp_handler.py:1347-1400`） |
| 35 次调用后僵尸进程 | **0**（`ps -ef \| grep -c defunct` = 0） |
| 孤儿进程 | **0**（所有 bun 的 PPid 均为对应探测进程） |
| 5 路并发调用 | 每路 1 个 bun，1:1，无泄漏，无互相干扰崩溃 |
| 调用后子进程是否死亡 | 正常退出（`aclose()` + 5 s 清理超时） |
| 是否出现 EADDRINUSE | 是——并发 5 实例时 4 个 bind 58891 失败，**静默成功**（见 MT2） |
| 可观测性 | a0 把子进程 stderr 写入 `tempfile.TemporaryFile`（`mcp_handler.py:1573-1583`），不落盘；现场无日志可查。server 自身日志在 `~/.wps-office-mcp/logs/`（含 30 s/69 s 失败史，`SUCCESS` 出现 **0** 次） |

## §7 缺陷编号

| ID | 级别 | 现象 | 证据 |
| --- | --- | --- | --- |
| **MT1** | P0 | 每次 `call_tool` 重启 MCP 子进程 → 进程内缓存跨调用**必然丢失**。a0 路径实测：`cache_data` 成功（`cacheSize:1`）后紧接 `get_cached_data` 报"缓存键不存在、availableKeys:[]"，`list_cache` 返回 `count:0`。宣传的"跨应用数据传递"完全失效 | `mcp_handler.py:_execute_with_session`；a0 进程内实测 |
| **MT2** | P0 | 58891 `EADDRINUSE` 时 `_isRunning=true; resolve()` 静默成功 → 该会话永远收不到 WPS 加载项的 `/result`，所有工具必 30 s 超时且无任何提示。并发工具调用、上一次会话未清干净时必现 | `mac-poll-server.js:338-341`；5 实例并发观察 |
| **MT3** | P1 | `wps_check_connection` 连接失败仍 `isError:false`，模型会误判成功 | `mcp-server.js:128`；30.02 s 实测 |
| **MT4** | P1 | `inputSchema` 不做类型校验：`key:123`、`data:"string"` 均通过；未知字段静默忽略；类型错误延后为 `text.trim is not a function` | §2 行 14/16/17 |
| **MT5** | P1 | `position` 一词在 10 个工具里承载 3 种类型、7 种枚举域；内置 `wps_insert_text.position`(number) 与 `wps_word_insert_text.position`(enum) 功能重叠且不兼容 | §5 |
| **MT6** | P2 | 无 WPS 时无快速失败路径：每次调用固定 30 s 或 69 s；且新进程 `currentApp` 为空，**每次调用都重走 switchApp**（多 8–39 s） | `mac-poll-server.js:426-431`；耗时双峰 |
| **MT7** | P2 | 245/250 工具依赖 58891 桥，但描述里没有"需 WPS 正在运行"的前置条件；"打开指定路径的演示文稿"这类描述会误导模型直接调用 | 250 条描述全文 |
| **MT8** | P3 | schema 生成器不一致：17 个省略 `required`；3 个描述 <8 字；29 个全可选却实际需参数 | §5 |
| **MT9** | P3 | a0 丢弃 MCP 子进程 stderr（TemporaryFile），故障现场不可回溯 | `mcp_handler.py:1573-1583` |
| **MT10** | P1 | **19 个 WPS 方法各被 2 个工具绑定**（38 个工具、15%），其中 8 对严格重复：`insertRows`、`insertColumns`、`deleteColumns`、`setZoom`、`insertPptChart`、`duplicateSlide`、`setSlideNotes`、`generateTOC`；且 `column`/`data` 两个参数在两份工具里类型不同。模型面对重复项只能随机选，选错必失败 | `tools/*` 方法映射逐条比对；§5 |
| **MT11** | P3 | `tool-registry.ts:67-71` 遇工具重名**静默跳过**：一旦将来真出现重名，工具会无声消失，且无任何日志告警 | `tool-registry.ts:67-71` |

## §8 250 个工具的实际可用比例

| 口径 | 可用 | 说明 |
| --- | ---: | --- |
| 协议层可达（能握手、能拿到 schema、能收到结构化回包） | 250/250 = **100%** | 无崩溃、无 500、无未知工具 |
| 无 WPS 环境下功能可用 | **3/250 = 1.2%** | `wps_list_cache`、`wps_clear_cache`、`wps_ppt_set_active_target{clear}`。缓存写入 2 个工具因 MT1 形同虚设 |
| 名义"纯内存"工具 | 4/250 | 但 `cache_data`/`get_cached_data` 在 a0 路径下必失效（MT1） |
| 若装有 WPS（推断，未实测） | 名义 245，实际估 **60–80%** | 8 对重复工具只能选对一半（MT10）；MT2 的端口竞争在并发调用下静默失败；每次调用重走 switchApp 多 8–39 s；无重试、无告警 |

复现（探针目录已删）：
```sh
curl -s -c c.txt -H 'Origin: http://127.0.0.1:5080' http://127.0.0.1:5080/api/csrf_token
curl -s -b c.txt -H 'Origin: http://127.0.0.1:5080' -H "X-CSRF-Token: <token>" -H 'Content-Type: application/json' \
  -d '{"server_name":"wps_office"}' http://127.0.0.1:5080/api/mcp_server_get_detail | jq '.detail.tools|length'  # 250
B=~/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"p","version":"1"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wps_check_connection","arguments":{}}}' | timeout 40 $B/bin/bun $B/wps-skills/wps-office-mcp/dist/index.js | tail -1
```
