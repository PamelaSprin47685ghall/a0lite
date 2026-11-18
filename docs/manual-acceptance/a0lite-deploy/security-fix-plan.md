# 安全修复方案（S1–S3）
- 基线：`ab3d8e6150f7`（应用 `058582f-dirty`），Flatpak 1.18.4。
- 本轮只验证与改文件，**未构建、未重启 5080 实例**；`soak` 未受影响。
## §1 缺陷与修复
| 编号 | 缺陷 | 修复手段 |
|---|---|---|
| S3 | `--filesystem=host` + `--talk-name=org.freedesktop.Flatpak`，任意宿主命令 | 先遮蔽私钥类目录；`--talk-name` 保留（WPS MCP），见 §5 |
| S2 | 文件 API 根为 `/`，`/etc`、`~/.ssh` 全盘可读 | 八条 `--nofilesystem` + `a0flatpak/sensitive_paths.py` 运行时 403 |
| S1 | `A0_AUTH_KEY` 默认空，本机进程可取 CSRF 后调 `/api/message` | 本轮不改，见 §5 |
| F1 | 文件 API 写操作无边界，可删宿主 `~/.bashrc` | 写白名单：`/a0`、`~/Documents`、`~/Downloads`（`A0_WRITE_ROOTS`），越界 403 `WRITE_OUTSIDE_WORKDIR`；读保持全盘 |
| F2 | 下载不存在 500 + traceback；删除/列表失败 200 + error | 下载 404 `NOT_FOUND`；删除/列表/编辑 4xx；所有 API 500 统一 `INTERNAL`，traceback 只进日志 |
| F3 | 非空目录被无确认 rmtree | 无 `recursive=true` 时 409 `NON_EMPTY_DIRECTORY` |
## §2 `--nofilesystem` 实测（原始输出）
**组 1：遮蔽前。**
```console
$ flatpak run --command=sh org.agentzero.AgentZero -c 'test -r ~/.ssh/id_ed25519 && echo SSH_READABLE || echo SSH_BLOCKED; ls -d ~/.gnupg 2>&1'
SSH_READABLE
/home/kunweiz/.gnupg
```
**组 2：运行时加 `--nofilesystem=~/.ssh --nofilesystem=~/.gnupg --nofilesystem=~/.pki`。**
```console
$ flatpak run --nofilesystem='~/.ssh' --nofilesystem='~/.gnupg' --nofilesystem='~/.pki' --command=sh org.agentzero.AgentZero -c 'test -r ~/.ssh/id_ed25519 && echo SSH_READABLE || echo SSH_BLOCKED; ls -d ~/.ssh 2>&1; test -r ~/.gnupg && echo GPG_READABLE || echo GPG_BLOCKED'
SSH_BLOCKED
/home/kunweiz/.ssh
GPG_READABLE
# GPG_READABLE 是测试缺陷：test -r 对目录恒真；补测目录内容：
$ flatpak run --nofilesystem='~/.ssh' --nofilesystem='~/.gnupg' --nofilesystem='~/.pki' --nofilesystem='~/.local/share/keyrings' --nofilesystem='~/.config/gh' --nofilesystem='~/.aws' --nofilesystem='~/.docker' --nofilesystem='~/.kube' --command=sh org.agentzero.AgentZero -c 'ls -A ~/.ssh; ls -A ~/.gnupg; ls -A ~/.local/share/keyrings; ls -A ~/.config/gh; test -r ~/.ssh/id_ed25519 && echo SSH_KEY_READABLE || echo SSH_KEY_BLOCKED; ls -A ~ | grep -E "^(Desktop|Documents|Downloads)$"'
SSH_KEY_BLOCKED
Desktop
Documents
Downloads
```
八个敏感目录均为空；home 其余项正常可见。`--nofilesystem` 在 Flatpak 1.18.4 上**成立**。
**组 3：遮蔽不破坏正常 home。**
```console
$ flatpak run --nofilesystem='~/.ssh' --command=sh org.agentzero.AgentZero -c 'ls ~ | head -3; ls ~/Documents 2>&1 | head -3; echo HOME=$HOME'
AnyDesk
Codex
HOME=/home/kunweiz
```
## §3 manifest diff
```diff
   - --filesystem=host
+  # security-audit.md S3: mask credential directories. --nofilesystem
+  # overrides the preceding --filesystem=host for these paths.
+  - --nofilesystem=~/.ssh
+  - --nofilesystem=~/.gnupg
+  - --nofilesystem=~/.pki
+  - --nofilesystem=~/.local/share/keyrings
+  - --nofilesystem=~/.config/gh
+  - --nofilesystem=~/.aws
+  - --nofilesystem=~/.docker
+  - --nofilesystem=~/.kube
```
## §4 `sensitive_paths.py`
- `is_sensitive(path)`：`expanduser` → 按根 `/` 解析 → `realpath` 解符号链接 → `== root or startswith(root + "/")`；`.ssh2` 不误伤。
- `blocked_response()`：Flask `Response`，**403**，body `{"ok":false,"error":"SENSITIVE_PATH_BLOCKED","message":"This path holds credentials and is not available to the agent."}`。
- 拦截点（实际函数名）：`api.get_work_dir_files.GetWorkDirFiles.process`、`api.download_work_dir_file.DownloadFile.process` + 同模块 `resolve_download_path(path)`（抛 `ValueError(MARKER)` 作第二道）、`api.delete_work_dir_file.DeleteWorkDirFile.process`、`api.delete_work_dir_files.DeleteWorkDirFiles.process`、`api.edit_work_dir_file.EditWorkDirFile.process`（实际“读文件”入口；`get_work_dir_file` 不存在）、`api.file_info.FileInfoApi.process`、`api.rename_work_dir_file.RenameWorkDirFile.process`、`api.extract_work_dir_archive.ExtractWorkDirArchive.process`、`api.upload_work_dir_files.UploadWorkDirFiles.process`、`api.api_files_get.ApiFilesGet.process`。
- 独立沙盒验证：`.ssh/.gnupg/.pki/keyrings/.config/gh/.aws` 判真；`~/Documents`、`~/.config`、`/a0`、`.ssh2` 判假；`/tmp/a0-link-ssh -> ~/.ssh` 判真；三个 handler 对 `.ssh/id_ed25519` 均 403，安全路径正常进入原 handler。
- **F1 写白名单**：`is_write_allowed(path)` 先 `realpath` 解符号链接，再要求落在 `A0_WRITE_ROOTS`（默认 `/a0:~/Documents:~/Downloads`）之下；list/download/file_info/edit GET 仍只做敏感目录检查。
- **F2 错误**：`DownloadFile` 预检不存在 → 404 `NOT_FOUND`；delete/list/edit/rename/extract/upload 的 200+`error` 在 wrapper 里转 4xx；`ApiHandler.handle_request` 的 500 统一替换为 `{"ok":false,"error":"INTERNAL","message":"Internal server error."}`。
- **F3 recursive**：`delete_work_dir_file` 与 `delete_work_dir_files` 在删除前检查非空目录；未传 `recursive=true` 返回 409 `NON_EMPTY_DIRECTORY`，文案 `pass recursive=true to delete a non-empty directory`。
## §5 不修的项与理由
- **`--talk-name` 保留**：WPS MCP 用 `flatpak-spawn --host` 启动，移除即失效；私钥遮蔽只缩小可读面，不消除宿主命令执行。
- **`A0_AUTH_KEY` 默认空不改**：单机、仅 loopback、无登录是产品语义；默认强制 key 会改变首次启动及 WPS/脚本调用，需单独设计一次性 key 与 `.env` 迁移。
- **依赖 hash lock 不做**：要重做 requirements 与 uv 安装流程，成本高于本轮范围。
## §6 构建与复验清单（待构建窗口）
1. `soak` 结束后再构建；三件套同源，安装顺序主包 → Cuda → Wps。
2. 重启后 `flatpak info --show-permissions` 应有八条 `nofilesystem=...`。
3. 沙盒内 `test -r ~/.ssh/id_ed25519` 应为 `SSH_BLOCKED`，`ls -A ~/.ssh` 为空。
4. 文件 API 的 `.ssh`、`.aws`、download、edit 路径应 403 且 body 含 `SENSITIVE_PATH_BLOCKED`。
5. 正常路径回归：`/a0`、`~/Documents`、上传/下载/重命名临时文件仍 200；`verify-ui-fix.sh` 6/6。
6. WPS MCP：`wps_check_connection` 与 250 工具仍在；`flatpak-spawn --host id` 仍成功（残余风险）。
7. F1：`delete/upload/rename ?path=/etc/...` 应 403 `WRITE_OUTSIDE_WORKDIR`；`/a0` 临时文件删除应 200；`~/Documents` 临时文件上传/删除应 200。
8. F2：下载不存在文件应 404 `NOT_FOUND`，body 不含 `Traceback`；人为抛错应 500 `INTERNAL`，body 不含绝对路径。
9. F3：非空目录无 `recursive` 应 409 `NON_EMPTY_DIRECTORY`；带 `recursive=true` 应成功。
## §7 风险
- `~/.ssh` 遮蔽后 agent 内 `git`/`ssh` 不能用私钥；`~/.config/gh`、`~/.aws/.docker/.kube` 同理失去 CLI 登录态；`keyrings` 影响 Secret Service 应用。
- 目录仍作为空挂载点存在（`ls -d ~/.ssh` 成功），不是路径消失；判定要看内容与 `test -r <file>`。
- 需在 agent 内使用上述凭据时，必须显式加回单项 `--filesystem=...`，不能整体撤销遮蔽。
- 残余：`--talk-name` 仍可执行宿主命令；`settings_workdir_file_structure` 的树预览仍可能列出敏感目录**名称**（不含内容），本轮未拦。
- 写白名单会阻止 agent 修改 `/etc`、宿主 dotfiles、`/tmp` 等；这是 F1 的预期取舍。需要新写入位置时只加 `A0_WRITE_ROOTS`，不要放开读边界。
