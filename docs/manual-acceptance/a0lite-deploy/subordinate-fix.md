# call_subordinate（子代理）不可用：可写根缺 tools/

## §1 错误原文（用户视角）

Web UI 里要求主代理“用 call_subordinate 创建下属，只回复 SUB-OK”，主代理调用工具后收到：

```
Tool call_subordinate not found. Available tools:
## available tools
### call_subordinate
delegate research or complex subtasks to a specialized agent.
```

随后主代理回复“当前环境里 call_subordinate 工具没有启用”。提示词列出该工具，调度器却说不存在。

## §2 调用链与断点

Delegation.execute（tools/call_subordinate.py）→ Agent.get_tool（agent.py）→ subagents.get_paths(self,"tools","call_subordinate.py")
→ files.get_abs_path("tools",...) → 可写根 $DATA（a0flatpak.base_dir）→ $DATA/tools/call_subordinate.py 不存在
→ classes=[] → 回退 tools/unknown.py → 读 fw.tool_not_found.md。

提示词侧走 get_paths(agent,"prompts") + agent.system.tool.*.md；launcher 每次启动合并 prompts/，所以 call_subordinate 的提示词存在。

## §3 根因（包装层 seed 遗漏；非上游 bug、非沙盒权限）

- ls -d $DATA/tools → No such file or directory；$DATA 顶层只有 agents api conf extensions knowledge plugins prompts tmp usr venv webui。
- 沙盒内：files.get_abs_path("tools","call_subordinate.py")=/var/data/agent-zero/tools/call_subordinate.py，exists=False；get_paths(...)=[]；bundle 内该文件存在。
- flatpak/agent-zero.sh 首次 seed conf agents knowledge instruments，按构建标记 seed api plugins extensions webui；base_dir.apply() 兜底只 seed conf agents knowledge instruments usr。两处都漏 tools。
- 顶层其它工具（response/document_query/parallel/skills_tool/vision_load/unknown）同样解析失败；插件工具 plugins/*/tools/ 不受影响。
- 排除项：沙盒内 import tools.call_subordinate 成功；$DATA/usr/chats 可写；无 fork/docker/socat/宿主路径依赖；与登录凭据无关；无 asyncio 报错。

## §4 修复

```diff
flatpak/agent-zero.sh（每次启动复制，与 prompts 同语义）：
+if [ -d "$APP_ROOT/tools" ]; then mkdir -p "$BASE_DIR/tools"; cp -a --no-preserve=timestamps "$APP_ROOT/tools/." "$BASE_DIR/tools/"; fi
+for name in prompts conf agents knowledge instruments tools usr api plugins extensions webui; do
flatpak/a0flatpak/base_dir.py（直启兜底）：
-for name in ("conf", "agents", "knowledge", "instruments", "usr"):
+for name in ("conf", "agents", "knowledge", "instruments", "tools", "usr"):
```

已安装 commit 的即时修复：把 bundle 的 tools/ 同步到 $DATA/tools（已执行）。

## §5 验证输出

bash -n flatpak/agent-zero.sh → SH OK；python3 -m py_compile flatpak/a0flatpak/base_dir.py → PY OK。沙盒内独立进程：

```
paths: ['/var/data/agent-zero/tools/call_subordinate.py']
tool: call_subordinate.Delegation
child: 74qcGf2C number: 1 distinct: True slot: default
```

真实子代理调用（同进程新建 context 并跑模型）：

```
child context: HFplXPHr parent: abPbB2He
User message (subordinate): 只回复 SUB-OK 四个字母，不要其他内容。
RESULT: 'SUB-OK'
```

## §6 生效方式与验收清单

- 不需要重建 v25 镜像；当前 commit 只需补齐 $DATA/tools（已完成），仓库两处 seed 修复供下次构建/全新数据目录。
- 不需要重启主服务：helpers/subagents.py 导入时执行 cache.toggle_area(PATHS_CACHE_AREA, False)，路径解析不缓存，下一次工具调用即命中。
- 验收：登录 Web UI → 新会话发“用 call_subordinate 让下属只回复 SUB-OK” → 期望 Calling Subordinate Agent 卡片，结果 SUB-OK，不再报 not found。
- 重建后检查：flatpak run --user --command=sh org.agentzero.AgentZero -c 'ls /var/data/agent-zero/tools/call_subordinate.py' 应打印路径。
