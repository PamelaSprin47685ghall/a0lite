# 提交与 push 方案（HEAD `058582f`，36 项未提交；只做计划，不执行）

## §1 git 现状
- 分支 `main`，HEAD `058582f`；upstream `origin/main`，本地与远端同点（0 ahead / 0 behind）。
- remote 仅 origin：`git@github.com:PamelaSprin47685ghall/a0lite.git`（SSH）；身份 Kunwei Zhang <kunweiz92@gmail.com>；stash 空。
- 36 项 = 22 M + 1 D（`flatpak/a0flatpak/health.py`）+ 13 `??`，与 `worktree-changes.md` 表格 36 行逐路径一致。

## §2 push 可行性：**可以 push**
- `~/.ssh/id_ed25519(.pub)` 存在；`ssh -T git@github.com` → `Hi PamelaSprin47685ghall! You've successfully authenticated`。
- `git ls-remote --heads origin` → `058582f… refs/heads/main`，远端可读且与本地一致，push 前不需 pull。
- `credential.helper` 未配、无 `~/.git-credentials`、无 `~/.config/git/credentials`；SSH 传输不需要，非阻塞。

## §3 36 项分组
| 组 | 路径 | 项数 |
|---|---|---|
| A 打包/代码 | `flatpak/` 全部：15 M + 1 D + 5 个新模块（guards/version）+ `patches/`，含 manifest、`agent-zero.sh`、requirements、WPS 配置、README | 22 |
| B 脚本 | `scripts/build.sh`、`install-services.sh`；新增 `deploy-760k.sh`、`test-760k-acceptance{,-selftest}.sh`、`verify-security-fix{,-selftest}.sh` | 7 |
| C 文档 | `docs/setup/host-ollama.md`；`docs/manual-acceptance/`（84 文件 / 2.0 MB，含 png 与 250 工具 json） | 2 |
| D 根文件 | `README.md` | 1 |
| S 单元 | `systemd/a0-desktop-start`、`agent-zero-desktop.service`、`agent-zero.service`（原分组未列，单列） | 3 |
| E+F 排除 | `bundles/` 0 项（已忽略）；`.herd/` 1 项，未忽略，提交前排除 | 1 |
| 合计 | | **36** |

## §4 .gitignore 检查
- `build/`（5.0 GB）命中 `.gitignore:1`，`bundles/`（927 MB CUDA 包）命中 `:2`；`git ls-files bundles build` = 0，`git status` 未出现。
- `.herd/` 未命中（`git check-ignore` 无输出），在 `??` 列表 → 先追加 `.herd/` 到 `.gitignore`，且只按路径 `git add`，禁用 `git add -A` / `git add .`。

## §5 拟用 commit message
```
Give the Flatpak real AMD Vulkan, hard boundaries, and self-healing patches

The v22 packaging line: the bundle runs on the host GPU, refuses to write
past the data tree, and puts its patches back after a plugin reload.

* seed the writable tree from the base dir and resolve it in one place
* discover Chrome by executable check and warn on fallback; carry 3.14/anyio
* make the desktop health check report what it probed
* budget PDF pages and time, and say when OCR output was truncated
* rebuild a FAISS index that fails to load; write a correct WAV header
* browser_guard: cap navigation and kill Chrome when the app closes
* sensitive_paths: refuse credential paths with 403, no traceback
* plugin_guard: replay flatpak/patches after namespace cleanup
* mcp_cache: reuse the WPS port and child across calls
* systemd: tty-only desktop start, no graphical.target dependency
* scripts: --repo, A0_COMMIT_TIME, templated units, 760K acceptance

Verified: health 200 / verify-security-fix 12/12 / verify-ui-fix 6/6 /
Vulkan 1.81x (Radeon 780M, size_vram 1.82/7.25 GiB, tps 32.27 -> 58.36)
```
首行 67 字符。`verify-ui-fix` 6/6 只存在于 `report.md` 的验收记录，仓库内无该脚本；`# Conflicts:` 无内容，不写。

## §6 执行顺序（待放行）
1. `printf '\n.herd/\n' >> .gitignore`
2. `git add README.md docs/setup/host-ollama.md docs/manual-acceptance/ flatpak/ scripts/ systemd/`
3. `git status --short` 复核：无 `??`，无 `.herd/`、`bundles/`、`build/`
4. 将 §5 正文存为 `/tmp/a0lite-commit.txt`，`git commit -F /tmp/a0lite-commit.txt`
5. `git push origin main`，再核对 `git rev-parse HEAD @{u}` 相等
