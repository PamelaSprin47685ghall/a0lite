# fix-compat：Python 3.14 + anyio 流式收尾与 `msg_output_limit` seed

- 执行时间：2026-11-18 00:15 — 00:45（Asia/Shanghai）
- 对象：`/home/kunweiz/Desktop/a0lite`（打包层）；上游只读参考 `/home/kunweiz/Desktop/agent-zero`（HEAD `ba9b67d`）
- 运行实例：`org.agentzero.AgentZero`（Flatpak user），`http://127.0.0.1:5080`
- 本轮状态：**缺陷 1 的静态根因、补丁、最小复现均完成；缺陷 2 的静态根因、补丁、merge 单测完成。**
  **5080 上的 3 条消息与坏模型 UI 行为验证尚未执行**，按现场控制者 deploy-local 的要求停在这里，等待独占窗口。
- 运行树写入：**本 worker 未写入**。`~/.var/app/org.agentzero.AgentZero/data/agent-zero/` 下没有复制 `compat.py`，没有创建 `flatpak/` 目录，没有改 `conf/`、`usr/.env`。见第 5 节的时间线说明。

---

## 1. 缺陷 1：`_TaskStub` 缺成员导致 anyio TaskGroup 收尾崩溃

### 1.1 复现入口

在沙盒内用应用 venv 跑，导入顺序与 launcher 一致（先 `a0flatpak.apply()`，再 `nest_asyncio.apply()`）：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -c '
  export GIT_PYTHON_REFRESH=quiet
  export PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps
  /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/bin/python -
' <<'PY'
import a0flatpak
a0flatpak.apply()
import asyncio, anyio, traceback
import nest_asyncio
nest_asyncio.apply()

async def boom():
    async with anyio.create_task_group() as tg:
        tg.start_soon(asyncio.sleep, 0)
        await asyncio.sleep(0)

try:
    asyncio.get_event_loop().run_until_complete(boom())
    print("NO-EXCEPTION")
except BaseException:
    traceback.print_exc()
PY
```

原始日志：`~/a0-local-backup/fix-compat/repro1-before.log`

### 1.2 完整 traceback（修复前）

首行是：

```text
Exception in callback TaskGroup._spawn.<locals>.task_done() at
/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py:870
```

完整原文：

```text
python-ready
Exception in callback TaskGroup._spawn.<locals>.task_done() at /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py:870
handle: <Handle TaskGroup._spawn.<locals>.task_done() at /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py:870>
Traceback (most recent call last):
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/uv/python/cpython-3.14.10-linux-x86_64-gnu/lib/python3.14/asyncio/events.py", line 94, in _run
    self._context.run(self._callback, *self._args)
    ~~~~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 909, in task_done
    self.cancel_scope.cancel()
    ~~~~~~~~~~~~~~~~~~~~~~~~^^
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 685, in cancel
    self._deliver_cancellation(self)
    ~~~~~~~~~~~~~~~~~~~~~~~~~~^^^^^^
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 618, in _deliver_cancellation
    should_retry = scope._deliver_cancellation(origin) or should_retry
                   ~~~~~~~~~~~~~~~~~~~~~~~~~~~^^^^^^^^
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 618, in _deliver_cancellation
    should_retry = scope._deliver_cancellation(origin) or should_retry
                   ~~~~~~~~~~~~~~~~~~~~~~~~~~~^^^^^^^^
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 600, in _deliver_cancellation
    if task._must_cancel:  # type: ignore[attr-defined]
       ^^^^^^^^^^^^^^^^^
AttributeError: '_TaskStub' object has no attribute '_must_cancel'
Traceback (most recent call last):
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 815, in __aexit__
    with CancelScope() as wait_scope:
         ~~~~~~~~~~~^^
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 492, in __exit__
    self._restart_cancellation_in_parent()
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^^
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 640, in _restart_cancellation_in_parent
    scope._deliver_cancellation(scope)
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~^^^^^^^
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 618, in _deliver_cancellation
    should_retry = scope._deliver_cancellation(origin) or should_retry
                   ~~~~~~~~~~~~~~~~~~~~~~~~~~~^^^^^^^^
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 600, in _deliver_cancellation
    if task._must_cancel:  # type: ignore[attr-defined]
       ^^^^^^^^^^^^^^^^^
AttributeError: '_TaskStub' object has no attribute '_must_cancel'

During handling of the above exception, another exception occurred:

Traceback (most recent call last):
EXCEPTION-RAISED
  File "<stdin>", line 15, in <module>
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/nest_asyncio.py", line 98, in run_until_complete
    return f.result()
           ~~~~~~~~^^
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/uv/python/cpython-3.14.10-linux-x86_64-gnu/lib/python3.14/asyncio/futures.py", line 208, in result
    raise self._exception.with_traceback(self._exception_tb)
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/uv/python/cpython-3.14.10-linux-x86_64-gnu/lib/python3.14/asyncio/tasks.py", line 289, in __step_run_and_handle_result
    result = coro.send(None)
  File "<stdin>", line 9, in boom
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 853, in __aexit__
    if self.cancel_scope.__exit__(type(exc), exc, exc.__traceback__):
       ~~~~~~~~~~~~~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py", line 472, in __exit__
    raise RuntimeError(
    ...<2 lines>...
    )
RuntimeError: Attempted to exit a cancel scope that isn't the current tasks's current cancel scope
```

生产日志里还出现过一条更早的 `AttributeError: 'TaskGroup' object has no attribute '_exceptions'`
（`~/a0-local-backup/run-probe-chat-20261117-234927.log:39-48`，anyio `_asyncio.py:906`）：

```text
File ".../anyio/_backends/_asyncio.py", line 906, in task_done
    self._exceptions.append(exc)
AttributeError: 'TaskGroup' object has no attribute '_exceptions'
```

它不是“第一个缺失成员”，而是同一个收尾期状态被拆掉后的下游症状：`_must_cancel` 让
`TaskGroup.__aexit__` 提前退出，`finally: del self._exceptions` 已经执行，延迟到达的
`task_done` 再去 append 就找不到属性。修好 `current_task`/stub 后，本文的两个 TaskGroup
变体都不再出现这条错误；没有直接 patch anyio 的 `_exceptions` 赛跑。

### 1.3 根因：不只缺成员，`current_task` 在真实任务里也返回 None

这一步是本次修复的关键，不能只给 `_TaskStub` 补方法。

1. `nest_asyncio.apply()` 在 Python 3.14 上把 `asyncio.Task` 换成纯 Python 的 `_PyTask`
   （`nest_asyncio.py:48-53`）。
2. `_PyTask.__step` 用 `_py_enter_task` 把当前任务写进 **`asyncio.tasks._current_tasks`**
   （`asyncio/tasks.py:276-280`、`:1071`、`:1084-1097`）。
3. `asyncio.tasks.current_task` 在模块导入时已经被
   `from _asyncio import (... current_task ...)` 覆盖成 C 版
   （`asyncio/tasks.py:1132-1143`）。C 版读的是 C 模块自己的注册表，看不到 `_PyTask`
   写的那一份。
4. 结果：`asyncio.current_task()` 在 `_PyTask` 里也返回 `None`。原来的 compat 把每个
   `None` 都换成单例 `_TaskStub`，anyio 的 `CancelScope.__enter__`
   （`_asyncio.py:428-432`）就把 stub 记成 `_host_task` 并放进 `_tasks`。
5. 一旦这个 scope 被 cancel（子任务失败、Starlette/SSE 收尾、litellm 的
   `with anyio.CancelScope(shield=True)`），`_deliver_cancellation`
   （`_asyncio.py:593-613`）对 stub 先读 `task.done()`，再读 `task._must_cancel`
   （`:600`），于是 AttributeError。随后 `__aexit__` 里的身份/状态检查还会抛
   `RuntimeError: Attempted to exit a cancel scope...`。
6. stub 是单例，所有“无 task”上下文共享同一条 `_task_states[stub]` 取消链，所以错误
   会在不同 TaskGroup 之间串扰，最终把 `context.running` 留在 true。

修复分两层：

- 主修复：`current_task` 先走原函数；返回 `None` 时，再从
  `asyncio.tasks._current_tasks.get(loop)` 取回 `_PyTask` 真正发布的任务。这样真实协程里
  永远拿到真 `Task`，anyio 的 scope 不再把 stub 当 host。
- 兜底：确实没有 task 的回调上下文里才返回 `_TaskStub`；把 anyio/asyncio 实际会访问的
  成员补齐，避免第二次同类 AttributeError。

复现用的诊断（修复前）证明“真 task 里也是 stub”：

```text
in boom task: _TaskStub
tg host: _TaskStub tasks: [('_TaskStub', ...)]
after sleep task: _TaskStub
```

原始输出：`~/a0-local-backup/fix-compat/diag.log`。

### 1.4 `_TaskStub` 缺失/被访问成员清单（anyio 4.15.1 + Python 3.14.10）

anyio 路径：
`~/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages/anyio/_backends/_asyncio.py`

| 成员 | 访问者（文件:行号） | “没有 task”时的语义 | 本补丁实现 |
|---|---|---|---|
| `_must_cancel` | anyio `_asyncio.py:600` `_deliver_cancellation` | 没有协程可被打断，取 False | 类属性 `False` |
| `_fut_waiter` | anyio `:605`；`:2307-2309` `has_pending_cancellation` | 没有在等的 Future，取 None | 类属性 `None` |
| `done()` | anyio `:596`；stdlib `taskgroups.py:248` | 不是“已完成”，而是“从未开始”；不能因此拒绝 TaskGroup | `False` |
| `cancel(msg)` | anyio `:607`；stdlib `timeouts.py:128`、`taskgroups.py:172/280` | 接受调用、返回 False、不抛 | `return False` |
| `cancelling()` | stdlib `timeouts.py:92`；`taskgroups.py:170` | 没有挂起的取消，返回 0 | `return 0` |
| `uncancel()` | anyio `:500`；stdlib `timeouts.py:111`、`taskgroups.py:147` | 计数不能变成负数，返回 0 | `return 0` |
| `cancelled()` | Task 协议 / 测试 | 没有 task 被取消 | `False` |
| `get_coro()` | anyio `:355` `_task_started`；`:2297` `AsyncIOTaskInfo` | stub 没跑过协程 | `None` |
| `get_name()` | anyio `:2299` `AsyncIOTaskInfo` | 固定名，日志可读 | `"a0flatpak-stub"` |
| `set_name(value)` | anyio `:2527` `AsyncIOBackend.run` | 单例不能累积状态 | 空实现 |
| `_loop` | anyio `:1061` `WorkerThread.__init__` (`root_task._loop`) | stub 没有自己的 loop，返回当前运行 loop | `asyncio.get_running_loop()` |
| `get_loop()` | 与 `_loop` 同一语义 | 同上 | 返回 `self._loop` |
| `add_done_callback(cb, *, context=None)` | anyio `:2678`、`:2838` | stub 永不完成；立即回调会谎报生命周期，存储会永久持有 | 静默忽略 |
| `remove_done_callback(cb)` | anyio `:2693` | 没有注册过 | `return 0` |
| `parent` / `get_parent()` | Python 3.14 Task 元数据；无父任务 | None | `None` / `None` |
| `get_stack(limit)` | Task 协议（调试） | 没有栈 | `[]` |
| `__repr__` | anyio `:679` 把 current task 写进取消原因 | 日志可读 | `"a0flatpak-stub"` |
| 可哈希/可弱引用/set 成员 | anyio `:428-432`、`:479-480` | 需要作 `_tasks` 的 set 元素和 `_task_states` 的 key | 默认对象身份（不覆写 `__eq__`/`__hash__`） |

明确没有使用 `__getattr__` 返回假值：缺失成员会继续暴露，而不是变成 MagicMock 式静默。

### 1.5 改后代码（`flatpak/a0flatpak/compat.py`）

关键片段（完整文件见仓库）：

```python
class _TaskStub:
    # anyio reads these two attributes directly.
    _must_cancel = False
    _fut_waiter = None
    parent = None

    def cancelling(self) -> int: return 0
    def uncancel(self) -> int: return 0
    def cancel(self, msg=None) -> bool: return False
    def cancelled(self) -> bool: return False

    def done(self) -> bool:
        # A stdlib TaskGroup treats a done parent as finished
        # (asyncio/taskgroups.py:248). "No task" is not "finished".
        return False

    def get_name(self) -> str: return "a0flatpak-stub"
    def set_name(self, value) -> None: ...

    @property
    def _loop(self):
        # anyio WorkerThread reads root_task._loop (line 1061).
        return asyncio.get_running_loop()

    def get_loop(self): return self._loop
    def get_coro(self): return None
    def get_parent(self): return None
    def get_stack(self, limit=None) -> list: return []

    def add_done_callback(self, callback, *, context=None) -> None:
        # Never completes; firing now would lie, storing would leak.
        ...

    def remove_done_callback(self, callback) -> int: return 0
    def __repr__(self) -> str: return "a0flatpak-stub"


def _patch_current_task() -> None:
    import asyncio.tasks as tasks_module
    ...
    original = tasks_module.current_task
    def current_task(loop=None):
        task = original(loop)
        if task is not None:
            return task
        if loop is None:
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                return _STUB
        current_tasks = getattr(tasks_module, "_current_tasks", None)
        task = current_tasks.get(loop) if current_tasks is not None else None
        return task if task is not None else _STUB
```

### 1.6 最小复现前后对比

| 场景 | 旧包（已装镜像） | 改后包（`PYTHONPATH` 前置临时目录） |
|---|---|---|
| `TaskGroup` + `start_soon(asyncio.sleep, 0)` | `AttributeError: '_TaskStub' object has no attribute '_must_cancel'`，再 `RuntimeError: Attempted to exit a cancel scope...` | `NO-EXCEPTION` |
| `TaskGroup` 子任务抛 `ValueError` | `AttributeError: ... _must_cancel` | 正常的 `ExceptionGroup: unhandled errors in a TaskGroup (1 sub-exception)` |
| `TaskGroup` + `anyio.to_thread.run_sync`（litellm `asyncify` 的路径） | 两次 `task_done` callback 的 `_must_cancel` AttributeError，再 `RuntimeError` | `NO-EXCEPTION` |

证据：

- `~/a0-local-backup/fix-compat/repro1-before.log` / `repro1-after2.log`
- `~/a0-local-backup/fix-compat/repro_variants-old.log` / `repro_variants-new.log`

改后包验证方式（没有碰运行树）：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -c '
  export GIT_PYTHON_REFRESH=quiet
  export PYTHONPATH=/home/kunweiz/a0-local-backup/fix-compat/patched:/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps
  /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/bin/python -
' < ~/a0-local-backup/fix-compat/repro1.py
```

### 1.7 证明真 task 仍返回真 task

`verify_stub2.py` 的结果：

```text
callback_is_stub: True
stub_members: 0 0 False False False None a0flatpak-stub [] None None False None True True a0flatpak-stub
add_remove: None 0
in_task_type: Task is_stub: False
inner_type: Task is_stub: False
timeout_ok
callback_after_nested_is_stub: True
callback_scope_exited
scope_exited
VERIFY_OK
```

解释：

- 协程里 `asyncio.current_task()` 是真正的 `Task`，不是 stub。
- 在回调里再次 `run_until_complete(inner())`，`inner` 里也拿到真 `Task`；回调返回后
  又回到 stub，符合“回调没有 task”的语义。
- `asyncio.timeout(1)` 在真 task 里正常完成。
- 只有在 `call_soon` 这类没有 task 的回调里才返回 stub。

### 1.8 连续 3 条消息（待独占窗口）

本轮**没有**在 5080 上执行。原因：现场由 deploy-local 独占，00:21–00:26 期间它多次重启
实例（`~/a0-local-backup/run-d1-*.log`、`run-v5-*.log`），我的一次正常请求在切换窗口里
得到 `curl: (52) Empty reply from server`。按用户指示，不抢重启、不 kill、不改运行树里的
框架包。

窗口内要执行的步骤：

1. 备份当前 `usr/plugins/_model_config/presets.yaml`（只读备份到
   `~/a0-local-backup/fix-compat/`）。
2. 用应用 venv 算 `create_auth_token()`，或用现场提供的 token。
3. 同一 context 连续发 3 条：
   ```sh
   curl -sS -m 120 http://127.0.0.1:5080/api/api_message \
     -H 'Content-Type: application/json' \
     -H "X-API-Key: $TOKEN" \
     -d '{"message":"只回答两个字：收到"}'
   ```
   第 2/3 条带第 1 条返回的 `context_id`。
4. 预期：3 条都在 120 s 内返回 200；第 2/3 条不出现 `Queued Messages`；每轮结束后
   `context.running` 为 false；日志里没有 `_TaskStub`/`_must_cancel`/`Attempted to exit
   a cancel scope`。
5. 证据：`usr/chats/<context_id>/chat.json`、服务端 stderr、UI 截图（若窗口内可用浏览器）。

---

## 2. 缺陷 2：异常处理依赖缺失的 `fw.msg_output_limit.md`

### 2.1 搜索证据

```text
rg -n 'msg_output_limit' /home/kunweiz/Desktop/agent-zero
```

命中（与运行路径相关）：

| 文件:行 | 内容 | 作用 |
|---|---|---|
| `extensions/python/message_loop_result/_05_truncated_response.py:47` | `warning = self.agent.read_prompt("fw.msg_output_limit.md")` | 截断响应时读警告 |
| 同上 `:50` | `"fw.msg_output_limit_response.md", finish_reason=...` | 用户可见的截断说明 |
| `extensions/python/_functions/agent/Agent/hist_add_warning/end/_90_stop_unusable_response_loop.py:27` | `self.agent.read_prompt("fw.msg_output_limit.md"),` | 5 元 set 字面量的一员；任何 `hist_add_warning` 都会求值 |
| `tests/test_leaked_tool_call_integration.py:736` | `agent.read_prompt("fw.msg_output_limit.md")` | 测试断言 |
| `prompts/AGENTS.md:37` | 文档声明 | 说明这是上游正式 prompt |

决定性细节：`_90_stop_unusable_response_loop.py:23-28` 是一个 **set 字面量**，五个
`read_prompt` 会全部求值。缺任何一个，**每次** `hist_add_warning` 都抛
`FileNotFoundError`，不只是截断路径。同文件 `:30-36` 对
`fw.msg_thoughts_fallback.md` 有 `try/except FileNotFoundError`，但这五个没有。

### 2.2 读取链与期望目录

```text
Agent.read_prompt                      agent.py:708-711
  -> subagents.get_paths(self, "prompts")   agent.py:709
  -> files.read_prompt_file(...)            helpers/files.py:124-139
  -> files.find_file_in_dirs(...)           helpers/files.py:384-397
  -> raise FileNotFoundError                helpers/files.py:397
```

- `read_prompt_file` 在 `helpers/files.py:139` 直接 `open()`，**没有回退**。
- `subagents.get_paths` 的默认目录最后一项是 `files.get_abs_path("prompts")`
  （`helpers/subagents.py:437-441`），即 `<BASE_DIR>/prompts`。
- 本安装的实际解析链只剩 `<BASE_DIR>/prompts`：`usr/prompts` 不存在，
  `usr/agents` 只有 `.gitkeep`，`agents/default/agent.yaml` 没有 `profile` 字段。
- `<BASE_DIR>` 由 launcher 设为
  `/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero`
  （`agent-zero.sh:24-27`、`base_dir.py:41-52`）。

### 2.3 运行树与 bundle 的存在性

上游 checkout：

```text
/home/kunweiz/Desktop/agent-zero/prompts/fw.msg_output_limit.md           291 B
/home/kunweiz/Desktop/agent-zero/prompts/fw.msg_output_limit_response.md  155 B
```

已装 bundle（`find -L`，因为 `current` 是符号链接；第一次不用 `-L` 的 `find` 是假阴性）：

```text
~/.local/share/flatpak/app/org.agentzero.AgentZero/current/active/files/share/agent-zero/prompts/fw.msg_output_limit.md           291 B
.../fw.msg_output_limit_response.md                                                                                              155 B
```

运行树（故障发生时，00:15 快照）：

```sh
find ~/.var/app/org.agentzero.AgentZero -name 'msg_output_limit*'
# 无输出
ls ~/.var/app/org.agentzero.AgentZero/data/agent-zero/prompts | wc -l
# 83（含 __pycache__，没有这两个文件）
```

与 bundle 的差异：运行树缺 2 个新文件，另有 13 个上游已删除的旧 prompt 残留
（`agent.system.behaviour*.md`、`behaviour.*.md`、若干 `agent.system.tool.*.md`、
`fw.notify_user.notification_sent.md`、`fw.wait_complete.md`）。这证明运行树是**更早一版
bundle 的一次性副本**，不是“上游没有这个文件”。

时间线说明：00:23–00:26 deploy-local 做 v5 安装/重启后，运行树里出现了这两个文件
（00:26 再次 `ls` 为 85 项，`fw.msg_output_limit.md` 291 B、`_response.md` 155 B）。
**这不是本 worker 写入的**；本 worker 没有对 `~/.var/app/.../data/agent-zero/` 做任何写入。
缺陷 2 的“缺失”证据以 00:15 快照和 `probe-chat.md` 的失败日志为准。

### 2.4 根因判定

**根因是打包层 seed 策略的“升级不刷新”，不是漏子目录，也不是上游缺文件。**

- 旧 `agent-zero.sh:39-42`：
  ```sh
  for name in conf prompts agents knowledge instruments; do
      if [ -d "$APP_ROOT/$name" ] && [ ! -d "$BASE_DIR/$name" ]; then
          cp -a "$APP_ROOT/$name" "$BASE_DIR/$name" 2>/dev/null || true
      fi
  done
  ```
  目录一旦存在，后续启动对 `prompts/` 完全不过问。
- 旧 `base_dir.py:46-50` 同样是 `not os.path.isdir(target)` 才 `_copy_tree`。
- 每次启动刷新的是 `api plugins extensions webui`（`agent-zero.sh:85-89`），`prompts`
  不在其中。
- `cp -a` 和 `shutil.copytree` 都是递归复制，`prompts/` 也没有子目录，所以不是
  “只复制顶层/漏子目录”。
- 上游 `prompts/fw.msg_output_limit.md` 存在，bundle 也存在，运行树没有 → 运行树是
  旧副本，升级后没有补新文件。

### 2.5 修法

选择**修 seed**，不 patch 上游读取方。理由：

1. `extensions/` 每次启动都被 bundle 覆盖（`agent-zero.sh:85-89`），对
   `_05_truncated_response.py` 打补丁会在下次启动被冲掉。
2. 上游会持续新增 prompt；只堵 `msg_output_limit` 是治标，下一个新增 prompt 会复现。
3. 缺失发生在文件解析层，任何 `read_prompt` 调用方都会踩同一个坑。

#### `flatpak/agent-zero.sh`

```sh
mkdir -p "$BASE_DIR/usr/plugins" "$BASE_DIR/prompts"
if [ -d "$APP_ROOT/prompts" ]; then
    cp -an "$APP_ROOT/prompts/." "$BASE_DIR/prompts/" 2>/dev/null || true
fi
for name in conf agents knowledge instruments; do
    if [ -d "$APP_ROOT/$name" ] && [ ! -d "$BASE_DIR/$name" ]; then
        cp -a "$APP_ROOT/$name" "$BASE_DIR/$name" 2>/dev/null || true
    fi
done
```

`cp -an` = archive + no-clobber：缺失文件补进来，用户改过的同名文件不动；每次启动都执行，
所以升级后新增的 prompt 一定会到位。`prompts` 从“一次性 seed”名单移除；`conf/ agents/
knowledge/ instruments/` 仍然只 seed 一次。

#### `flatpak/a0flatpak/base_dir.py`

```python
source_root = "/app/share/agent-zero"
for name in ("conf", "agents", "knowledge", "instruments", "usr"):
    source = os.path.join(source_root, name)
    target = os.path.join(root, name)
    if os.path.isdir(source) and not os.path.isdir(target):
        _copy_tree(source, target)
# prompts is merged, not seeded once.
_merge_missing(
    os.path.join(source_root, "prompts"), os.path.join(root, "prompts")
)
```

`_merge_missing` 逐文件遍历：目标不存在才复制；保留符号链接；`OSError` 跳过。它覆盖
“直接启动、跳过 launcher”的路径，和 shell 的 `cp -an` 语义一致。

#### `flatpak/README.md`

把 “`conf/ prompts/ agents/ knowledge/ instruments/` are seeded once” 改成两组：
`conf/ agents/ knowledge/ instruments/` 一次性 seed；`prompts/` 每次启动 no-clobber
合并，并写明 `FileNotFoundError` 的后果。

### 2.6 静态验证（已做）

| 验证 | 结果 |
|---|---|
| `python3 -m compileall -q flatpak/a0flatpak` | `COMPILE_OK` |
| `bash -n flatpak/agent-zero.sh` | `BASH_OK` |
| Python `_merge_missing`（目标已有用户 prompt + 旧文件） | 补进两个 msg prompt（291/155），用户文件 `USER EDIT KEEP ME` 不变，旧文件保留；共 72 项 |
| Shell `cp -an` 同场景 | 补进两个 msg prompt，用户文件不变，共 71 项；第二次 `cp -an` 后用户改动仍是 `SECOND USER EDIT` |
| `base_dir.apply()` 全路径（临时 `A0_BASE_DIR`） | `base_dir` 指向临时树；`patched=True`；prompts 71 项含两个 msg prompt；用户 prompt 和 `conf/model_providers.yaml` 均未被覆盖 |
| 最小复现旧/新 | 见 1.6；旧包 3 种失败路径，新包 `NO-EXCEPTION` / 正常 `ExceptionGroup` |
| 真 task 身份 | 见 1.7；协程内 `Task`，`is_stub=False` |

证据：`~/a0-local-backup/fix-compat/apply_test.log`、`merge-test/`、`shell-test/`。

### 2.7 坏模型名的 UI 行为（待独占窗口）

**修复前（已有证据）**：`probe-chat.md` 的坏模型、黑洞端点、`max_tokens=16` 三条路径都
出现：

```text
Critical error occurred, retrying...
litellm.exceptions.BadRequestError: ...
Traceback (most recent call last): ...
FileNotFoundError: File 'fw.msg_output_limit.md' not found in any of the provided directories.
```

原始日志：`~/a0-local-backup/run-probe-chat-20261117-234927.log:74,164,183`、
`run-probe-chat-20261118-000508.log:67,164,183`。

**修复后（窗口内要验证）**：prompt 到位后，
`_90_stop_unusable_response_loop.py:23-28` 的 set 能求值，`hist_add_warning` 不再抛
`FileNotFoundError`；`_80_retry_critical_exception` 会正常把
`fw.msg_critical_error.md`（含 `error_message`）加入历史。预期：

- UI/聊天日志里**不再出现** `FileNotFoundError: File 'fw.msg_output_limit.md' ...`；
- 不再出现由它引起的第二条 traceback；
- 仍会出现上游 `errors.format_error()` 生成的原始 `BadRequestError` traceback
  （`helpers/errors.py:17-80` 会保留 traceback）。这是 `probe-chat.md` 的问题 3，
  不在本单范围；本单只消除 `FileNotFoundError` 二次异常。

窗口内会故意把 `usr/plugins/_model_config/presets.yaml` 的 `chat.name` 改成
`definitely-not-a-model-xyz`（备份后），发一条消息，抓 `usr/chats/<id>/chat.json` 和
服务端 stderr，然后恢复 presets；不改 `conf/`。

---

## 3. 已改动文件（只列本 worker 的 hunk）

### 3.1 `flatpak/a0flatpak/compat.py`

| before | after |
|---|---|
| `_TaskStub` 只有 `cancelling/uncancel/cancel/cancelled/done/get_name` | 增加 `_must_cancel`、`_fut_waiter`、`parent`、`set_name`、`_loop`、`get_loop`、`get_coro`、`get_parent`、`get_stack`、`add_done_callback`、`remove_done_callback`、`__repr__`；所有成员有明确注释 |
| `current_task` 只返回 `original(loop)` 或 `_STUB` | 原函数返回 `None` 时，再从 `asyncio.tasks._current_tasks.get(loop)` 取 `_PyTask` 发布的真 task；只有仍为 `None` 才返回 `_STUB` |
| 无 `_loop` 支持 | `_loop` 返回 `asyncio.get_running_loop()`，覆盖 anyio `WorkerThread.__init__` 的 `root_task._loop` |

### 3.2 `flatpak/a0flatpak/base_dir.py`

| before | after |
|---|---|
| `prompts` 与 `conf/agents/...` 一起，目标目录不存在才整棵复制 | `prompts` 单独走 `_merge_missing`，每次 `apply()` 都补缺失文件 |
| 无逐文件 no-clobber 合并 | 新增 `_merge_missing(source, target)`：`os.walk` + `lexists` 跳过已有文件 + `copy2`/`symlink`，`OSError` 跳过 |
| docstring 只说“launcher seeds” | 说明 `apply` 还会补升级新增的 prompt |

### 3.3 `flatpak/agent-zero.sh`

| before | after |
|---|---|
| `for name in conf prompts agents knowledge instruments; do` 一次性 seed | `prompts` 移出循环，改为每次启动 `cp -an "$APP_ROOT/prompts/." "$BASE_DIR/prompts/"` |
| 没有单独的 prompts 合并 | `mkdir -p "$BASE_DIR/usr/plugins" "$BASE_DIR/prompts"`；注释写明 `fw.msg_output_limit.md` 的教训和 `cp -n` 的用户编辑保护 |

### 3.4 `flatpak/README.md`

| before | after |
|---|---|
| `conf/ prompts/ agents/ knowledge/ instruments/` 全部“seeded once” | `conf/ agents/ knowledge/ instruments/` 一次性 seed；`prompts/` 每次 no-clobber 合并；解释 `FileNotFoundError` 的后果 |

> 说明：`agent-zero.sh` 与 `README.md` 的 `git diff` 里还包含本单之前已存在的未提交改动
> （`webui` 移到每次刷新、`ALLOWED_ORIGINS` 默认值、`ollama.log` 路径、`usr` 哨兵、
> `/a0` 警告等）。本 worker 没有改这些区域，也没有改 P1/P3/D2 三处。

---

## 4. 风险与副作用

1. **stub 扩展是否会掩盖真实 task 生命周期问题。**
   不会在“有 task”的路径上生效：`current_task` 先返回真 `Task`，只有在原函数和
   `asyncio.tasks._current_tasks` 都没有任务时才返回 stub。1.7 的 `verify_stub2`
   证明了协程内、嵌套 `run_until_complete` 内都是真 `Task`。真正没有 task 的回调里，
   stub 只是让 anyio/asyncio 的“无任务”分支不崩，不会伪造出一个可运行的任务。
2. **`done()` 返回 False 的取舍。**
   anyio `_deliver_cancellation` 用 `done()` 决定是否继续投递取消；如果 stub 成为某个
   活动 CancelScope 的 host，`done() = False` 会让它每个 loop turn 重试一次，直到 scope
   退出。主修复让异步代码里的 scope host 都是真 task，所以这条只对“在回调里进入并长期
   持有 CancelScope”的极端路径成立；本单未观察到。若未来出现该路径，应把 stub 的
   `done()` 改成 True，或在 `CancelScope.__enter__` 处把 stub 排除。
3. **`get_coro() = None`。**
   anyio `AsyncIOTaskInfo.__init__` 有 `assert coro is not None`。只有在“无 task 回调”
   里调用 `anyio.get_current_task()` 这类任务内省 API 才会命中；正常的协程路径拿真 task。
   本次复现/变体均未命中。
4. **`add_done_callback` 静默忽略。**
   stub 永不完成，立即回调会谎报生命周期（anyio 用它停止共享线程池），存储会永久持有。
   在无 task 上下文里注册的 worker-pool stop 回调不会执行；这是“没有 task”语义下的
   可接受降级。
5. **`_exceptions` 竞态没有直接 patch。**
   anyio 4.15.1 `TaskGroup.__aexit__` 的 `finally: del self._exceptions` 与延迟
   `task_done` 的 append 有理论赛跑。生产日志里它出现在 `_must_cancel` 之后/之间，属于
   同一收尾崩溃族；修复后的两个 TaskGroup 变体不再出现。若后续长对话仍看到
   `'TaskGroup' object has no attribute '_exceptions'`，需要单独 patch anyio 的
   `TaskGroup.__aexit__`，不能把它归因于本单。
6. **缺陷 2 的 merge 语义。**
   - 只补缺失文件，**不覆盖**已有文件：用户改过的 prompt 会保留；上游对同名 prompt 的
     内容更新不会自动覆盖（这是 README 一直承诺的“用户可编辑”语义）。需要更新时删除
     本地文件，下次启动会补回 bundle 版本。
   - 只补不删：上游删除的旧 prompt 会留在运行树（与现有 `cp -a` 的“never deletes”一致），
     不影响解析，因为新代码不再引用它们。
   - `_merge_missing` 和 `cp -an` 都吞掉复制错误；如果文件因权限/磁盘失败，下一次启动会
     重试，但读取方仍会失败。这是有意的“不因一个文件阻塞启动”。

---

## 5. 验证状态与独占窗口请求

### 已完成

- 缺陷 1：完整 traceback、根因、成员清单、补丁、3 种最小复现（旧/新）、真 task 身份证明。
- 缺陷 2：上游/运行树/bundle 存在性、读取链、根因、两处补丁、4 组 merge 单测、
  `compileall`、`bash -n`。
- 未对运行树写入；未复制 `compat.py` 到 `~/.var/app/.../data/agent-zero/`；未改 `conf/`；
  未 kill/重启 5080（本 worker 没有执行 `flatpak kill` 或 `flatpak run org.agentzero.AgentZero`）。

### 待独占窗口

需要 deploy-local 完成 v5 回归并交还现场后，给我：

- **窗口长度：5 分钟**（最低 3 分钟）。其中两次重启（进入 patched 包、恢复普通启动）
  约 1 分钟，3 条消息约 2 分钟，坏模型一条约 10–30 秒，健康检查/日志抓取约 1 分钟。
- **前置条件**：
  1. 5080 上应用在跑，`/api/health` 200；
  2. 没有其他 worker 在重启/安装；
  3. `A0_AUTH_KEY` 为空（或把该 key 给我），这样 `X-API-Key: <mcp_server_token>`
     能同时过 ASGI 门和 handler 门；
  4. 允许我用 `PYTHONPATH` 前置 `~/a0-local-backup/fix-compat/patched`（或
     `sitecustomize` 注入）启动一次应用，验证后恢复普通启动；
  5. 运行树 `prompts/` 里已有 `fw.msg_output_limit.md`（00:26 已在），或者允许我在窗口内
     临时复制并在结束后删除。当前不需要我写运行树。
- 窗口内会做：
  1. 3 条连续消息（同一 context）→ 检查 200、无排队、`context.running=false`；
  2. 坏模型名 → 检查不再出现 `FileNotFoundError`，并抓 `chat.json`/stderr；
  3. 恢复 presets、恢复普通启动、健康检查；
  4. 全程日志写 `~/a0-local-backup/fix-compat/window-*.log`。

---

## 6. 证据文件

| 文件 | 内容 |
|---|---|
| `~/a0-local-backup/fix-compat/repro1-before.log` | 旧包最小复现完整 traceback |
| `~/a0-local-backup/fix-compat/repro1-after2.log` | 改后包 `NO-EXCEPTION` |
| `~/a0-local-backup/fix-compat/repro_variants-old.log` | 旧包 child_error / to_thread 失败 |
| `~/a0-local-backup/fix-compat/repro_variants-new.log` | 改后包正常 `ExceptionGroup` / `NO-EXCEPTION` |
| `~/a0-local-backup/fix-compat/verify_stub2.log` | 真 task 与 stub 成员证明 |
| `~/a0-local-backup/fix-compat/apply_test.log` | `base_dir.apply()` 全路径 merge |
| `~/a0-local-backup/fix-compat/merge-test/`、`shell-test/` | Python/shell no-clobber 结果 |
| `~/a0-local-backup/run-probe-chat-20261117-234927.log` | 生产 `_must_cancel` / `_exceptions` / `FileNotFoundError` |
| `~/a0-local-backup/run-probe-chat-20261118-000508.log` | 重启后的 `FileNotFoundError` |
| `~/a0-local-backup/fix-compat/diag.log`、`diag3.log` | 修复前 stub host / 修复后真 Task |
