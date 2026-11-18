# v20 文件写边界与错误语义复测

- v20 依据：`/app/share/agent-zero/flatpak/a0flatpak/sensitive_paths.py` 已加载（403 `WRITE_OUTSIDE_WORKDIR`）；health 的 `058582f` 是旧 build-info，未反映补丁层
- 时间 2026-11-18 08:10–08:14 CST；实例 `127.0.0.1:5080`（PID 2180949，health 200，`flatpak ps` 1 实例）；未构建、未重启

## §1 A 组：写操作 8 条

| # | 请求 | 状态 | body 前 120 字 | 判定 |
|---|---|---|---|---|
| 1 | upload → `/etc` | 403 | `{"ok":false,"error":"WRITE_OUTSIDE_WORKDIR","message":"Writes are limited to /a0, ~/Documents and ~/Downloads (A0_W…` | PASS |
| 2 | upload → `/home/kunweiz` | 403 | 同上 `WRITE_OUTSIDE_WORKDIR` | PASS |
| 3 | upload → `/tmp` | 403 | 同上 `WRITE_OUTSIDE_WORKDIR` | PASS |
| 4 | upload → `/a0` | 200 | `{"message":"Files uploaded successfully","data":{"entries":[…]}}`；磁盘落到 `data/agent-zero/a0v-upload.txt` | PASS |
| 5 | upload → `~/Documents` | 200 | `{"message":"Files uploaded successfully",…}`；`Documents/a0v-upload.txt` 存在 | PASS |
| 6 | delete `~/.bashrc` | 403 | `WRITE_OUTSIDE_WORKDIR`；文件仍在，3838 B 未变 | PASS |
| 7 | rename `/etc/hostname` | 403 | `WRITE_OUTSIDE_WORKDIR`；`/etc/hostname` 仍在，7 B 未变 | PASS |
| 8 | GET edit `/etc/passwd` | 200 | `{"data":{"path":"/etc/passwd","mime_type":"text/plain","content":"kunweiz:x:1000:1001:…"}}` | PASS（读放行） |

## §2 B 组：错误语义 2 条

| # | 请求 | 状态 | body 前 120 字 | 判定 |
|---|---|---|---|---|
| 9 | download `/a0/no-such-file-xyz.txt` | 404 | `{"ok":false,"error":"NOT_FOUND","message":"File not found: /a0/no-such-file-xyz.txt"}`（90 B） | PASS；`grep 'Traceback\|File "'` = 0，无行号/宿主路径 |
| 10 | download 缺 `path` 参数（触发 500） | 500 | `{"ok":false,"error":"INTERNAL","message":"Internal server error."}` | PASS；无 traceback |

## §3 C 组：递归删除保护 3 条

| # | 请求 | 状态 | body 前 120 字 | 判定 |
|---|---|---|---|---|
| 11 | delete `/a0/a0v-nonempty`（含 `a.txt`） | 409 | `{"ok":false,"error":"NON_EMPTY_DIRECTORY","message":"pass recursive=true to delete a non-empty directory"}` | PASS；目录未动 |
| 12 | 同上 + `"recursive":true` | 200 | 返回 `/a0` 列表；目录及 `a.txt` 已消失 | PASS |
| 13 | delete 空目录 `/a0/a0v-empty` | 200 | 返回 `/a0` 列表；目录消失 | PASS |

## §4 D 组：上传边界 3 条

| # | 请求 | 状态 | body 前 120 字 | 判定 |
|---|---|---|---|---|
| 14 | 100,000,000 B → `/a0` | 200 | `Files uploaded successfully`；磁盘 100,000,000 B | PASS（< 100 MiB=104,857,600） |
| 15 | 101 MiB（105,906,176 B）→ `/a0` | 413 | `{"error": "File exceeds the 100 MiB size limit."}`；未落盘 | PASS |
| 16 | 同名二次上传 `a0v-same.txt` | 200/200 | 第二次内容生效，文件 18 B；无冲突提示 | 记录：F4 未修 |

## §5 与 v14 对照（F1–F4）

- **F1 部分修复**：`/a0` 外的写/删/改名全部 403，含 `..` 与编码形式；但读仍按设计开放，`/etc`、`/etc/passwd`、`$HOME` 可列/可下载，仅 8 个凭据目录 403（`~/.ssh` 读 403 `SENSITIVE_PATH_BLOCKED`）；`upload path=/a0/../etc`、`/a0/../../tmp` 也 403。原“任意读写”降为“任意读”。
- **F2/F3 已修复**：404/409/500 统一为 `{ok:false,error,message}`，无 traceback/宿主路径；非空目录默认 409，必须显式 `recursive=true`，空目录直接 200。
- **F4 未修**：同名上传仍静默覆盖，无提示/版本/重命名。

## §6 仍存在的问题

1. **读边界仍是整机**：`/home/kunweiz`、`/etc` 可枚举，`/etc/passwd` 可下载；若威胁模型含宿主数据外泄，需把读也限定到 `A0_WRITE_ROOTS` 或显式白名单。
2. **413 与 500 语义**：413 只有 `{"error":…}`，缺 `ok:false`/错误码；`download` 缺 `path` 返回 500 INTERNAL 而非 400 BAD_REQUEST。
3. **默认写根偏宽**：`~/Documents`、`~/Downloads` 默认可写；若只需 `/a0`，应改 `A0_WRITE_ROOTS`。
4. **单位**：上限是 100 **MiB**（104,857,600 B），100,000,000 B 的“100 MB”可通过，文档需写清 MiB。

清理：`/a0` 13→13 条，`find a0v-*` 无残留，`~/.bashrc` 与 `/etc/hostname` 完好；health 200。
