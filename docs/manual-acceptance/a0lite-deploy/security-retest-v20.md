# v20 安全项复测

- 实例 `127.0.0.1:5080`，PID 2180949，安装 commit `21b0e23a…`；未构建、未重启。
- 方法：读 metadata 负权限 + 沙盒只读遍历 + 带 CSRF 的真实 API 请求；测试目录只建于 `/a0` 并已清理。
- 结束时 `flatpak ps` 1 实例、`/api/health` 200、我的测试产物已删净。
## §1 8 条 `!~` 与沙盒实测
`grep -o '!~[^;]*' "$LOC/metadata" | sort`：
```
!~/.aws          !~/.config/gh   !~/.docker       !~/.kube
!~/.gnupg        !~/.local/share/keyrings         !~/.pki
!~/.ssh
```
`flatpak info --show-permissions` 只显示 `filesystems=host;host-etc:ro;host-os:ro`，确实隐藏负权限；以上 8 条只在 metadata 里。
沙盒内 `ls -A "$HOME/<dir>" | wc -l`：8 个目录**全部 0 条**；`test -r ~/.ssh/id_ed25519` → **BLOCKED**，`stat` → `No such file`。目录仍作空挂载点存在（`ls -d ~/.ssh` 成功），home 其余内容正常（`.Xauthority`、`--help` 等可见）。
## §2 文件 API 9 条
均带合法 CSRF 与 `Origin: http://127.0.0.1:5080`。
| # | 请求 | 状态 | body 关键字段 |
|---|---|---|---|
| 1 | list `~/.ssh` | 403 | `SENSITIVE_PATH_BLOCKED` |
| 2 | list `/a0` | 200 | 正常 entries |
| 3 | download `~/.ssh/id_ed25519` | 403 | `SENSITIVE_PATH_BLOCKED`；无 `PRIVATE KEY` |
| 4 | delete `/etc/passwd` | 403 | `WRITE_OUTSIDE_WORKDIR` |
| 5 | upload → `/tmp` | 403 | `WRITE_OUTSIDE_WORKDIR` |
| 6 | upload → `/a0` | 200 | `Files uploaded successfully` |
| 7 | download 不存在文件 | 404 | `NOT_FOUND`；无 `Traceback` |
| 8 | delete 非空 `/a0/a0v-dir` | 409 | `NON_EMPTY_DIRECTORY` |
| 9 | 同上 + `recursive=true` | 200 | 目录已删除 |

第 6 条探针已用 API 删除；第 9 条后宿主侧确认 `/a0/a0v-dir`、`/a0/v20-upload.txt` 均不存在。

## §3 符号链接

`$DATA/a0v-link -> $HOME/.ssh`：`list`、`download id_ed25519`、`delete authorized_keys` 三入口均 **403 `SENSITIVE_PATH_BLOCKED`**。链接已删，`~/.ssh` 未变，`id_ed25519` 仍存在。对照组 `a0v-etc -> /etc` 的 `list` 返回 **200**——v20 读策略仍是“全盘可读，凭据目录除外”，`/etc` 属设计内可读面。

## §4 仍存在的风险

1. **`--talk-name=org.freedesktop.Flatpak` 仍在**：`flatpak-spawn --host id` 成功（rc=0，宿主 uid 1000，组含 `wheel`）。私钥已不可读，但宿主命令执行、`~/Documents`/`~/Downloads` 写入仍在，可改宿主可执行文件或启动脚本。
2. **`A0_AUTH_KEY` 仍为空**：本机任意进程仍可伪造 loopback Origin 取 CSRF 后调 `/api/message` 控制 agent；仅 loopback 绑定，LAN/公网不可达。
3. **读仍全盘**：除 8 个凭据目录外，`/etc`、`/home` 其余文件等仍可经文件 API 读，属 v20 有意设计。

## §5 与 v14 审计对照

| 项 | v14（ab3d8e61） | v20（21b0e23a） |
|---|---|---|
| `~/.ssh/id_ed25519` | `test -r` READABLE | **BLOCKED**，8 目录 entries=0 |
| list `~/.ssh` | 200，列出全部文件 | **403 `SENSITIVE_PATH_BLOCKED`** |
| download `.ssh` 文件 | 200，可读 | **403**，body 无密钥 |
| symlink → `.ssh` | 未测 | **403**（list/download/delete） |
| delete `/etc/passwd` | 无写边界 | **403 `WRITE_OUTSIDE_WORKDIR`** |
| upload `/tmp` | 无写边界 | **403** |
| download 不存在 | 500 + traceback | **404 `NOT_FOUND`**，无 traceback |
| 非空目录删除 | 直接 rmtree | **409**，需 `recursive=true` |
| `flatpak-spawn --host id` | 成功 | **仍成功（已知保留）** |
| 5080 监听 | 127.0.0.1 | 127.0.0.1 |
| `A0_AUTH_KEY` | 空 | **仍空** |

结论：**S3 凭据遮蔽、S2 敏感路径 403、F1 写白名单、F2 错误收敛、F3 非空目录确认均已真实生效**（非源码层）。`--talk-name` 与无认证按方案 §5 保留，属已知残余风险。
