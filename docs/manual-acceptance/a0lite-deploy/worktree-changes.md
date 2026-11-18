# 工作树改动清单（HEAD `058582f`；36 条 = 22 M + 1 D + 13 `??`；`git diff --stat` 23 文件 +1870/−372）

| 路径 | 类型 | 对应 | 说明 |
|---|---|---|---|
| `README.md` | M | D20/D35 | 部署与 systemd 文档重写 |
| `docs/setup/host-ollama.md` | M | D20/D24 | 宿主 Ollama 配置说明更新 |
| `flatpak/README.md` | M | D20/D35 | 打包层说明、unit 行为、排障 |
| `flatpak/a0flatpak/__init__.py` | M | 汇总 | apply 顺序接入 guards/version/compat |
| `flatpak/a0flatpak/base_dir.py` | M | D02/D11 | 可写树 seed 与 base dir 解析 |
| `flatpak/a0flatpak/browser.py` | M | D09/D10/D23 | Chrome 路径探测、可执行校验、回退告警 |
| `flatpak/a0flatpak/compat.py` | M | D12 | Python 3.14 / anyio `_TaskStub` 兼容 |
| `flatpak/a0flatpak/desktop.py` | M | D05/D06/D36/D37/D40/D51/D52 | Xpra 认证、headless、resize、健康检查真实化 |
| `flatpak/a0flatpak/health.py` | D | D38 | 旧 health 实现移除 |
| `flatpak/a0flatpak/ocr.py` | M | D18/D21/D22/D56/D57 | PDF 解析签名、页/时限预算、截断判定 |
| `flatpak/a0flatpak/packages.py` | M | 依赖 | 包安装/uv 探测修正 |
| `flatpak/a0flatpak/serve.py` | M | 服务 | 启动与端口处理调整 |
| `flatpak/a0flatpak/speech.py` | M | D15/D16/D43/D63 | TTS WAV 头、错误文案、spacy/whisper、超长上限 |
| `flatpak/a0flatpak/vector_store.py` | M | D13/D14 | FAISS 删除/重建与坏索引恢复 |
| `flatpak/agent-zero.sh` | M | D02/D04/D07/D08/D11/D38/D39/D43 | 启动器：seed、日志、版本、端口、补丁加载 |
| `flatpak/org.agentzero.AgentZero.yml` | M | D03/D17/D24/D47 | 扩展点、补丁、docs 排除、权限收敛 |
| `flatpak/requirements-flatpak.txt` | M | D20 | 依赖清单与注释同步 |
| `flatpak/wps-mcp-config.json` | M | D17 | WPS MCP 启动方式与路径 |
| `scripts/build.sh` | M | D01/D24/D38/D53 | `--repo`、A0_COMMIT_TIME、docs 排除 |
| `scripts/install-services.sh` | M | D28 | unit 模板化、uid/home 探测、预检与原子写入 |
| `systemd/a0-desktop-start` | M | D26/D27/D32/D33/D34 | 端口/数据目录/cookie 探测，失败非零退出 |
| `systemd/agent-zero-desktop.service` | M | D25/D26 | tty-only 拉起、超时与重启策略 |
| `systemd/agent-zero.service` | M | D25 | 不依赖 graphical.target |
| `flatpak/a0flatpak/browser_guard.py` | A | D48/D49 | 导航上限、错误冒泡、关闭时杀 Chrome |
| `flatpak/a0flatpak/mcp_cache.py` | A | D50/D54/D55 | WPS 缓存跨调用、端口与子进程复用 |
| `flatpak/a0flatpak/plugin_guard.py` | A | D42 | 插件命名空间清理后重放补丁 |
| `flatpak/a0flatpak/sensitive_paths.py` | A | D44/D45/D46 | 写入边界、凭据路径 403、无 traceback |
| `flatpak/a0flatpak/version.py` | A | D38/D53 | `commit_time` 取提交时间，新增 `build_time` |
| `flatpak/patches/` | A | D38/D41 | `flatpak-ui.patch`（页脚版本、移动端 rail 遮挡） |
| `scripts/deploy-760k.sh` | A | 部署 | 目标机一键部署（传输/安装/验收） |
| `scripts/test-760k-acceptance.sh` | A | 验收 | 760K 一键验收，默认只读 |
| `scripts/test-760k-acceptance-selftest.sh` | A | 验收 | 上者自测 |
| `scripts/verify-security-fix.sh` | A | D44–D47 | 安全修复验收 |
| `scripts/verify-security-fix-selftest.sh` | A | D44–D47 | 上者自测 |
| `docs/manual-acceptance/` | A | 证据 | 62 份验收与根因报告（镜像已排除，D24） |
| `.herd/` | A | 工具 | 本地 agent 运行缓存，**提交前请排除**（加 `.gitignore` 或 `git add` 时跳过） |
