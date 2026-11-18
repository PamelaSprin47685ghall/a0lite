# v20 复测：MT1 / MT2 / MT9（只读，不构建不重启）

实例 v20，pid 2180949，07:52 启动，commit `058582f`。`__init__.py` 已接线（`grep -c mcp_cache` = 2），沙箱内 `mcp_cache.py` 469 行与源码树一致。测试走 `flatpak run --command=sh … python`，与主进程同一 patch 栈。装配确认：`health=True`、`tee__=True`、`call_tool__a0flatpak_mcp__=True`。

## §1 MT1 缓存跨调用：五步全通过

| 步骤 | 调用 | 耗时 | isError | 返回 |
| --- | --- | ---: | --- | --- |
| 1 | `cache_data {key:"retest-key",data:"retest-value"}` | 0.0 s | false | `{"success":true,"key":"retest-key","message":"数据已缓存…","cacheSize":1}` |
| 2 | `get_cached_data {key:"retest-key"}` | 0.0 s | false | **`{"success":true,"key":"retest-key","data":"retest-value","appType":"unknown","cachedAt":"…502Z"}`** |
| 3 | `list_cache` | 0.0 s | false | `{"success":true,"count":1,"caches":[{"key":"retest-key",…,"ageMs":0}]}` |
| 4 | `clear_cache {key:"retest-key"}` | 0.0 s | false | `{"success":true,"message":"缓存 \"retest-key\" 已清除"}` |
| 5 | `get_cached_data {key:"retest-key"}` | 0.0 s | **true** | `{"success":false,"error":"缓存键 \"retest-key\" 不存在","availableKeys":[]}` |

第 2 步是判定点：v14 同一序列得到"缓存键不存在、availableKeys:[]"，现在命中 `retest-value`。**写入与读取跨越两次独立的 MCP 会话，数据仍在。**

## §2 MT2 串行化：并发 5 个 `check_connection`

| 序号 | 墙钟（相对并发起点） | 本次耗时 | isError | 返回 |
| ---: | ---: | ---: | --- | --- |
| 0–3 | 32.32 / 64.64 / 96.95 / 129.26 s | 同左 | false | `{"connected":false,"status":{…}}` ×4 |
| 4 | **120.01 s** | 120.01 s | **true** | `{"error":"MCP_BUSY","message":"another MCP call is still running"}` |

**总墙钟 129.26 s**（v14 理论值 5×30=150 s）。5 个全部落在同一个 server 的锁上，依次执行、每个约 32 s；第 5 个在锁上等满 `LOCK_TIMEOUT_SECONDS=120` 后返回 `MCP_BUSY`，因为第 4 个要到 129 s 才释放。**没有一个静默超时，没有一个 `EADDRINUSE` 被吞掉**——v14 的"5 并发中 4 个假成功"不再出现。

注意 `check_connection` 自身的 `isError:false`（MT3）仍在，这是上游 `mcp-server.js:128` 的语义，不在本轮修复范围。

## §3 MT9 stderr 落盘：**装配成功，但本轮没有文件**

- `_TeeLog` 已装配，`fileno`/`isatty`/`writable`/`readable`/`seekable`/`encoding`/`errors`/`closed` + `__getattr__` 委托都在，D50 的 `'_TeeLog' object has no attribute 'fileno'` 在 `usr/logs/a0flatpak.log` 里 **0 次**。
- `ls $DATA/usr/logs/` 只有 `a0flatpak.log`，**没有 `mcp-wps_office.log`**。原因不是 patch 失效，而是 v20 版 `_TeeLog._disk()` 惰性打开：只有子进程真的往 stderr 写东西时才建文件，而本次 35 次调用中 bun 全程静默（`mcp_servers_status` 的 `has_log:false` 与此一致）。
- 源码树已补 `note()`：会话建立时无条件写一行 `[ISO] session start: <command> <args>` 到磁盘，**不写临时文件**（`get_log()` 仍只显示 server 自己的输出）。已在沙箱内用 `importlib` 加载新版本验证：`fileno=3`、临时文件内容 `'server stderr line\n'`、磁盘文件 92 字节且同时含 header 与 stderr。**待下次构建生效。**

## §4 回归

| 检查 | 结果 |
| --- | --- |
| `mcp_servers_status` | 200，4.4 ms，`connected:true`、`tool_count:250`、`has_log:false` |
| `MCPConfig.get_tools()` | 250（`Tools updated. Found 250 tools.`） |
| `wps_common_ping` | 32.23 s，`isError:true`，`WPS连接检测出错: Command timeout after 30000ms: ping`（+2 s 为会话启动开销） |
| 四条缓存工具 | 见 §1，全部按预期 |
| 其他异常 | 无 500、无崩溃、无 `_TeeLog` AttributeError |

## §5 结论

1. **MT1 修好**：`cache_data` → `get_cached_data` 跨两次 MCP 会话命中，`list`/`clear`/未命中三条路径文案与 server 逐字一致。
2. **MT2 修好**：5 并发串行、第 5 个明确 `MCP_BUSY`；v14 的"4 个假成功 + 30 s 静默超时"消失。
3. **MT9 装配好、落盘待构建**：`_TeeLog`/`fileno` 已在 v20 生效；"文件必然存在"等 `note()` 进下一版。
4. 遗留：`LOCK_TIMEOUT_SECONDS=120` 与单次 30–70 s 不匹配，5 并发时尾部必 BUSY。建议改为 `并发数 × 单次上限`，或在文案里加"请重试"。
