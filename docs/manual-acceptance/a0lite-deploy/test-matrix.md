# a0lite 实机验收用例矩阵

对象：Flatpak 打包的 Agent Zero（`org.agentzero.AgentZero`，user 安装，UI 端口 5080）。

来源：`functional-probes.md` 的触发方式与命令、`contract-audit.md` 的契约存疑项、`README.md` 的 Verified 表。

> **总数 77（C01–C77）。** C01–C61 为原矩阵；**C62 起为本轮安全审计与边界测试新增，尚未在 v14 上执行完毕**，状态见第 4 节「未执行清单」。新增条目沿用原 8 列格式；原编号（S01–S06、E06–E10、F08–F10、D06、K05）写在「目的」列开头，C 序列连续，不再另起一套编号。

本文件只写用例、期望与判据，**不写执行结论**。探针文档里的「已实测」是探针作者的观察，不是本次验收的结果。执行结论写入同目录 `report.md`。

用法：

1. 先确定下面 6 个变量，再执行任何用例。
2. 每条用例复制「执行命令/操作」列。`P0`–`P5` 与 `S-*` 是可复用的片段，定义在第 2、3 节；把脚本填进 `P1` 的 `<<'PY'` 位置即得到完整命令。
3. 把原始输出或截图存入 `evidence/<CASE>/`，命名见「证据目录约定」。
4. 按「评分规则」打分。本表列固定为 8 项，不设结论列；如团队模板要求结论列，追加第 9 列并填 `—`，实际结果只写入 `report.md`。

---

## 1. 环境变量与前置

### 1.1 执行前必须确定的 6 个变量

| 变量 | 取值 | 用途 | 确认方式 |
|---|---|---|---|
| `A0_AUTH_KEY` | `<从 override 或 unit 环境读取>` | 通过 ASGI 门；只在 shell 中导出，不写入日志或截图 | `flatpak override --user --show org.agentzero.AgentZero` 或 `systemctl cat agent-zero.service` 中的 `A0_AUTH_KEY=` 之后的值；`export A0_AUTH_KEY=...` |
| `A0_OCR_MODEL` | `<从 override 读取；未设置时为 xiaomi-ocr>` | 图片与扫描件走 `/api/chat` 的视觉模型 | `flatpak override --user --show org.agentzero.AgentZero`；`curl -s http://127.0.0.1:11434/api/tags` 确认模型存在 |
| `A0_SPEECH_MODEL` | `<从 override 读取；未设置时为 lfm3-omni:2b-q4_K_M>` | TTS 与 STT | 同上 |
| `A0_EMBEDDING_MODEL` | `<从 override 读取；未设置时为 qwen3-embedding:4b-q4_K_M>` | 嵌入维度 | 同上 |
| 聊天模型 id | `mistral/deepseek-v4-1-flash-1017` | kw92 主模型 | `curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"mistral/deepseek-v4-1-flash-1017","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'` 返回 200 |
| 目标机/本机命令前缀 | `RUN='ssh <user>@<target> sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 HOME=/home/kunweiz bash -s'`；本机执行时 `RUN=''` | 远端执行；本机执行留空 | `eval "$RUN" <<'EOF'` 后 `whoami; echo $HOME` 输出 `kunweiz` 与 `/home/kunweiz` |

### 1.2 固定量

| 名称 | 值 |
|---|---|
| `UI` | `http://127.0.0.1:5080` |
| `OLLAMA` | `http://127.0.0.1:11434` |
| `APP` | `org.agentzero.AgentZero` |
| `DATA` | `$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero` |
| `BUNDLE` | `$HOME/a0-bundles/agent-zero.flatpak` |
| `PROBE_DIR` | `$HOME/a0-probe` |
| `TOKEN` | `$HOME/.a0-probe-token`（由 P2 生成，16 字符） |

执行前先展开并导出固定量，后续命令才可直接复制：

```sh
export UI=http://127.0.0.1:5080
export OLLAMA=http://127.0.0.1:11434
export APP=org.agentzero.AgentZero
export DATA="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
export BUNDLE="$HOME/a0-bundles/agent-zero.flatpak"
export PROBE_DIR="$HOME/a0-probe"
```

所有命令默认在目标机的 `kunweiz` shell 中执行。远端执行时把整段包进 `RUN` 的 heredoc。命令中出现 `$A0_AUTH_KEY` 的地方，只允许展开，不允许 `echo` 其值。

### 1.3 前置状态

- `flatpak info --user org.agentzero.AgentZero` 可读，branch 为 `master`。
- 沙盒入口可用：P0 能打印 `HOME`、`PWD`，且 `/app/share/agent-zero`、`/app/share/python-deps`、`/app/bin/uv` 都存在。
- 服务已由 `flatpak run --user org.agentzero.AgentZero` 或 `agent-zero.service` 启动；`curl $UI/api/health` 返回 200。
- Ollama 已由应用拉起：`curl -s $OLLAMA/api/tags` 返回 JSON。
- 若走 systemd，先 `sudo systemctl is-active agent-zero.service`；手工启动与 systemd 不要同时持有同一实例。

---

## 2. 可复用片段

### P0：进入沙盒 shell（不含 Python）

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
echo "HOME=$HOME PWD=$PWD"
ls -d /app/share/agent-zero /app/share/python-deps /app/bin/uv
INNER
```

### P1：在沙盒内跑框架 Python

把 `S-*` 脚本原文填入 `<<'PY'` 与 `PY` 之间。方括号内的 `--env=K=V` 按用例添加。`MODE`、`EXPECT`、`PDF_NAME`、`MID` 是**沙盒内**的脚本变量，必须写进 `INNER` heredoc，例如在 `"$B/venv/bin/python"` 之前加一行 `export MODE=scan EXPECT=timeout PDF_NAME=a0_scan3.pdf`；它们不会从宿主自动传入。

```sh
flatpak run --user --command=sh [--env=K=V ...] org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero || exit 1
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" - <<'PY'
# S-* 脚本原文
PY
INNER
```

### P2：取 `X-API-Key`（`mcp_server_token`）

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" -c 'from helpers.settings import create_auth_token; print(create_auth_token())' > "$HOME/.a0-probe-token"
INNER
T=$(cat "$HOME/.a0-probe-token"); test ${#T} -ge 8 && echo "TOKEN_OK"
```

### P3：取 session + CSRF

```sh
curl -sS -c "$HOME/.a0-cookies" -H "Authorization: Bearer $A0_AUTH_KEY" \
  "$UI/api/csrf_token" -o "$HOME/.a0-csrf.json"
CSRF=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.a0-csrf.json")))["token"])')
RID=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.a0-csrf.json")))["runtime_id"])')
echo "CSRF_LEN=${#CSRF} RID=$RID"
```

### P4：生成探针输入（宿主，需 Pillow）

```sh
python3 - <<'PY'
import os
from PIL import Image, ImageDraw, ImageFont
out = os.path.expanduser("~/a0-probe"); os.makedirs(out, exist_ok=True)
def font(size=48):
    try: return ImageFont.load_default(size=size)
    except Exception: return None
def png(path, text, size=(600, 200)):
    img = Image.new("RGB", size, "white")
    ImageDraw.Draw(img).text((20, 80), text, fill="black", font=font())
    img.save(path)
png(out + "/a0_probe.png", "A0 PROBE 42")
objs = [
 b"<< /Type /Catalog /Pages 2 0 R >>",
 b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
 b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
 None,
 b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
stream = b"BT /F1 24 Tf 72 700 Td (A0 PDF PROBE 42) Tj ET"
objs[3] = b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream"
buf = bytearray(b"%PDF-1.4\n"); offs = [0]
for i, o in enumerate(objs, 1):
    offs.append(len(buf)); buf += f"{i} 0 obj\n".encode() + o + b"\nendobj\n"
xref = len(buf)
buf += f"xref\n0 {len(objs)+1}\n".encode() + b"0000000000 65535 f \n"
for off in offs[1:]:
    buf += f"{off:010d} 00000 n \n".encode()
buf += f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
open(out + "/a0_probe.pdf", "wb").write(buf)
for n in (1, 3):
    pages = []
    for i in range(n):
        img = Image.new("RGB", (1240, 1754), "white")
        ImageDraw.Draw(img).text((80, 200), f"A0 SCAN PROBE 42 page {i+1}", fill="black", font=font())
        pages.append(img)
    pages[0].save(f"{out}/a0_scan{n}.pdf" if n > 1 else f"{out}/a0_scan.pdf",
                  save_all=True, append_images=pages[1:], resolution=150)
print("wrote", sorted(os.listdir(out)))
PY
```

### P5：手工重启并等 health

仅用于非 systemd 的手工实例。systemd 管理时改用 `sudo systemctl restart agent-zero`。

```sh
flatpak kill org.agentzero.AgentZero 2>/dev/null || true
nohup flatpak run --user org.agentzero.AgentZero >"$HOME/.a0-app.log" 2>&1 &
for i in $(seq 1 120); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 $UI/api/health)" = 200 ] && break
  sleep 1
done
curl -s -o /dev/null -w 'HTTP=%{http_code}\n' $UI/api/health
```

---

## 3. 可复用脚本

### S-EMB：嵌入维度

```python
from a0flatpak import embeddings
embeddings.apply()
import models
m = models.get_embedding_model("huggingface", "sentence-transformers/all-mpnet-base-v2")
print("class:", type(m).__name__, "model:", m.model_name)
v = m.embed_query("a0 probe")
print("dimensions:", len(v), "first3:", v[:3])
assert type(m).__name__ == "OllamaEmbeddings", type(m).__name__
assert m.model_name == "qwen3-embedding:4b-q4_K_M", m.model_name
assert len(v) == 2560, len(v)
print("EMB_OK")
```

### S-MEM：记忆写入 / 检索 / 删除 / 加载

`MODE=write|search|delete|load`；删除时传 `MID=<C24 输出的 id>`。

```python
import asyncio, os
from a0flatpak import embeddings, vector_store
embeddings.apply(); vector_store.apply()
from plugins._memory.helpers.memory import Memory, abs_db_dir
mode = os.environ.get("MODE", "write")
async def main():
    if mode == "load":
        db = await Memory.get_by_subdir("default", preload_knowledge=False)
        print("loaded ok; dir:", abs_db_dir("default")); print("LOAD_OK"); return
    db = await Memory.get_by_subdir("default", preload_knowledge=False)
    if mode == "write":
        mid = await db.insert_text("a0 probe memory: the probe token is 42",
                                   {"area": Memory.Area.MAIN.value, "source": "probe"})
        print("inserted:", mid); print("dir:", abs_db_dir("default")); print("WRITE_OK")
    elif mode == "search":
        hits = await db.search_similarity_threshold("what is the probe token", limit=5, threshold=0.0)
        print("hits:", len(hits))
        for d in hits[:5]: print(" -", str(d.page_content)[:120], d.metadata.get("area"))
        assert any("42" in str(d.page_content) for d in hits), "42 not found"
        print("SEARCH_OK")
    elif mode == "delete":
        mid = os.environ["MID"]
        removed = await db.delete_documents_by_ids([mid])
        print("removed:", len(removed))
        hits = await db.search_similarity_threshold("probe token", limit=5, threshold=0.0)
        print("hit42_after:", any("42" in str(d.page_content) for d in hits))
        assert not any("42" in str(d.page_content) for d in hits)
        print("DELETE_OK")
asyncio.run(main())
```

### S-SPEECH：TTS / STT / 空文本 / 超长 / 连接失败

`MODE=tts|stt|empty|long`；`EXPECT=connect|timeout` 时把对应异常判为预期结果。

```python
import asyncio, base64, io, os, wave
from a0flatpak import speech
speech.apply()
from plugins._kokoro_tts.helpers import runtime as tts
from plugins._whisper_stt.helpers import runtime as stt
mode = os.environ.get("MODE", "tts"); expect = os.environ.get("EXPECT", "")
TEXT = {"tts": "你好，这是验收探针。", "empty": "", "long": "验收探针" * 500, "stt": "验收探针 往返测试"}
async def main():
    try:
        if mode == "stt":
            b64 = await tts.synthesize_sentences([TEXT["stt"]])
            res = await stt.transcribe(b64)
            print("keys:", sorted(res.keys())); print("text:", repr(res.get("text"))[:200]); print("language:", res.get("language"))
            assert isinstance(res, dict) and res.get("text", "").strip()
            assert any(k in res["text"] for k in ("验收", "探针", "往返", "probe"))
            print("STT_OK"); return
        b64 = await tts.synthesize_sentences([TEXT[mode]])
        print("b64_len:", len(b64))
        if not b64:
            print("EMPTY_AUDIO"); assert mode == "empty"; print("EMPTY_OK"); return
        raw = base64.b64decode(b64)
        print("bytes:", len(raw), "magic:", raw[:4], raw[8:12])
        assert raw[:4] == b"RIFF" and raw[8:12] == b"WAVE"
        with wave.open(io.BytesIO(raw)) as w:
            sr, ch, sw, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        print("sample_rate:", sr, "channels:", ch, "bits:", sw * 8, "seconds:", round(n / sr, 3))
        assert len(raw) > 1000 and n / sr > 0.5
        print("TTS_OK")
    except Exception as e:
        msg = f"{type(e).__name__}: {e}"
        print("EXC:", msg[:400])
        if expect == "connect" and ("connect" in msg.lower() or "refused" in msg.lower()):
            print("CONNECT_ERROR_OK"); return
        if expect == "timeout" and "timeout" in msg.lower():
            print("TIMEOUT_OK"); return
        raise
asyncio.run(main())
```

### S-OCR：图片 / 数字 PDF / 扫描 PDF / 关闭回退 / 超时 / 缺模型 / 坏文件

`MODE=image|pdf|scan|nofallback|badfile`；`EXPECT=timeout|missing|badfile`；`PDF_NAME=a0_scan.pdf` 或 `a0_scan3.pdf`。

```python
import asyncio, os
from a0flatpak import ocr, parsers
ocr.apply()
if os.environ.get("MODE") != "image": parsers.apply()
from plugins._document_query.helpers.fetch import FetchedDocument
from plugins._document_query.helpers.parsers.image import ImageParser
from plugins._document_query.helpers.parsers.pdf import PdfParser
mode = os.environ.get("MODE", "image"); expect = os.environ.get("EXPECT", "")
BASE = os.environ.get("PROBE_DIR", os.path.expanduser("~/a0-probe"))
def doc(path, mime):
    return FetchedDocument(uri="file://" + path, scheme="file", mimetype=mime,
                           content=open(path, "rb").read(), local_path=path)
async def main():
    try:
        if mode == "image":
            t = await ImageParser().parse(doc(BASE + "/a0_probe.png", "image/png"), {}, timeout=180)
        elif mode == "badfile":
            p = BASE + "/broken.pdf"
            open(p, "wb").write(b"%PDF-1.4\ntrailer\n<<>>\n%%EOF\n")
            t = await PdfParser().parse(doc(p, "application/pdf"), {}, timeout=30)
        else:
            name = os.environ.get("PDF_NAME", "a0_scan.pdf")
            cfg = {"pdf_ocr_fallback": mode != "nofallback"}
            t = await PdfParser().parse(doc(BASE + "/" + name, "application/pdf"), cfg, timeout=60)
        print("len:", len(t)); print("text:", repr(t[:300]))
        if mode == "nofallback":
            assert not t.strip(); print("NO_FALLBACK_OK"); return
        if mode == "badfile":
            print("BADFILE_NO_ERROR"); return
        assert t.strip(), "empty"
        print("OCR_OK")
    except Exception as e:
        msg = f"{type(e).__name__}: {e}"
        print("EXC:", msg[:400])
        if expect == "timeout" and ("timeout" in msg.lower() or "timed out" in msg.lower()):
            print("TIMEOUT_OK"); return
        if expect == "missing" and ("404" in msg or "not found" in msg.lower()):
            print("MODEL_MISSING_OK"); return
        if expect == "badfile":
            print("BADFILE_ERR_OK"); return
        raise
asyncio.run(main())
```

### S-BROWSER：Chrome 发现 / 标题 / 权限不足 / 幂等

`MODE=chrome|title|nochrome|idempotent`。

```python
import asyncio, os
from a0flatpak import browser
browser.apply()
print("chrome:", browser.find_system_chrome())
mode = os.environ.get("MODE", "title")
HTML = "data:text/html,<title>A0 Probe Title</title><h1>hello</h1>"
async def main():
    if mode == "chrome":
        assert browser.find_system_chrome() is not None
        print("CHROME_OK"); return
    from plugins._browser.helpers.runtime import get_runtime
    rt = await get_runtime("probe-ctx")
    if mode == "nochrome":
        try:
            await asyncio.wait_for(rt.call("open", HTML), timeout=60)
            print("UNEXPECTED_OPEN")
        except Exception as e:
            msg = f"{type(e).__name__}: {e}"
            print("OPEN_ERROR:", msg[:300])
            assert msg.strip() and "Traceback" not in msg
        print("NO_CHROME_OK"); return
    res = await rt.call("open", HTML)
    st = await rt.call("state", res["id"])
    print("title:", repr(st.get("title")), "url:", st.get("currentUrl"))
    assert st.get("title") == "A0 Probe Title"
    if mode == "idempotent":
        res2 = await rt.call("open", HTML)
        print("second id:", res2["id"])
        await rt.call("close_all"); await rt.call("close_all")
        print("IDEMPOTENT_OK"); return
    print("BROWSER_OK")
asyncio.run(main())
```

### S-DESKTOP：启动 / 鉴权分支 / Xvfb 可达 / headless

`MODE=start|branch|static-xvfb|headless`。

```python
import json, os, shutil, subprocess
import a0flatpak; a0flatpak.apply()
from plugins._desktop.helpers import desktop_session as ds
mode = os.environ.get("MODE", "start")
def proc_lines():
    out = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout
    return [l[:400] for l in out.splitlines() if "xpra" in l and "grep" not in l]
if mode == "static-xvfb":
    from a0flatpak import desktop as ad
    os.environ.pop("DISPLAY", None)
    try:
        host = ad._host_display()
    except Exception as e:
        host = f"EXC:{type(e).__name__}:{e}"
    print("host_display:", host)
    print("Xvfb:", shutil.which("Xvfb") or ("/app/bin/Xvfb exists" if os.path.exists("/app/bin/Xvfb") else "MISSING"))
    print("xpra:", shutil.which("xpra") or ("/app/bin/xpra exists" if os.path.exists("/app/bin/xpra") else "MISSING"))
    assert host is None or str(host).startswith(":") or "No desktop to share" in str(host)
    print("XVFB_OK")
elif mode == "branch":
    d = os.environ.get("DISPLAY", "").strip()
    n = d.partition(".")[0].partition(":")[2] if d else "0"
    sock = os.path.exists(f"/tmp/.X11-unix/X{int(n or 0)}")
    print("DISPLAY:", repr(d), "socket:", sock)
    lines = proc_lines(); print("xpra_lines:", len(lines))
    for l in lines: print("XPRA:", l)
    has_auth = any("--tcp-auth=env" in l for l in lines)
    has_start = any("start-desktop" in l for l in lines)
    print("has_tcp_auth:", has_auth, "has_start_desktop:", has_start)
    if d and sock:
        assert not has_auth; print("BRANCH_SHADOW_OK")
    else:
        assert has_auth and has_start; print("BRANCH_HEADLESS_OK")
else:
    if mode == "headless": os.environ.pop("DISPLAY", None)
    r = ds.DesktopSessionManager().ensure_system_desktop()
    print(json.dumps({k: r.get(k) for k in ("available", "error", "session_id", "display", "url")}, ensure_ascii=False))
    assert r.get("available") is True, r.get("error")
    assert r.get("url")
    if mode == "headless":
        assert str(r.get("display")).lstrip(":") in ("120", "0"), r.get("display")
        assert any("start-desktop" in l for l in proc_lines())
        print("HEADLESS_OK")
    else:
        print("DESKTOP_OK")
```

### S-WPS：MCP 握手 / 工具列表 / 工具调用

`MODE=init|tools|call`；在宿主执行，不进入沙盒。

```python
import json, os, subprocess
ROOT = os.path.expanduser("~/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files")
BUN = os.path.join(ROOT, "bin", "bun")
SERVER = os.path.join(ROOT, "wps-skills/wps-office-mcp/dist/index.js")
mode = os.environ.get("MODE", "init")
msgs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "a0-probe", "version": "0.0.1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
]
if mode == "call":
    msgs.append({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "wps_check_connection", "arguments": {}}})
payload = "".join(json.dumps(m, ensure_ascii=False) + "\n" for m in msgs)
p = subprocess.run([BUN, SERVER], input=payload, capture_output=True, text=True, timeout=90)
print("rc:", p.returncode); print("stderr:", p.stderr[:300])
by_id = {}
for line in p.stdout.splitlines():
    if line.strip():
        m = json.loads(line); by_id[m.get("id")] = m; print(json.dumps(m, ensure_ascii=False)[:500])
assert p.returncode == 0
init = by_id[1]["result"]
print("server:", init["serverInfo"]["name"], init["protocolVersion"])
assert init["serverInfo"]["name"] == "wps-office-mcp"
tools = by_id[2]["result"]["tools"]
print("tools:", len(tools)); assert tools
if mode == "call":
    call = by_id[3]
    flag = call.get("error") or (call.get("result") or {}).get("isError") or (call.get("result") or {}).get("content")
    print("call_has_error_or_content:", bool(flag)); assert flag
print("WPS_OK")
```

### S-CHAT-ASYNC：浏览器等价路径

保存为 `S-CHAT-ASYNC.sh`，`bash S-CHAT-ASYNC.sh`。

```bash
set -eu
UI=http://127.0.0.1:5080
KEY="${A0_AUTH_KEY:-}"
J=/tmp/a0-asy-cookies
curl -sS -c "$J" -H "Authorization: Bearer $KEY" "$UI/api/csrf_token" -o /tmp/a0-asy-csrf.json
CSRF=$(python3 -c 'import json;print(json.load(open("/tmp/a0-asy-csrf.json"))["token"])')
curl -sS -b "$J" -c "$J" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" \
  -d '{"text":"只回答两个字：收到","context":"probe-chat-2"}' "$UI/api/message_async"
for i in $(seq 1 60); do
  curl -sS -b "$J" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" \
    -d '{"context":"probe-chat-2","log_from":0,"notifications_from":0}' "$UI/api/poll" -o /tmp/a0-asy-poll.json
  if python3 -c 'import json;d=json.load(open("/tmp/a0-asy-poll.json"));print(any(l.get("type")=="response" and (l.get("content") or "").strip() for l in d.get("logs",[])))' | grep -q True; then break; fi
  sleep 2
done
python3 - <<'PY'
import json
d = json.load(open("/tmp/a0-asy-poll.json"))
rs = [l.get("content", "") for l in d.get("logs", []) if l.get("type") == "response" and l.get("content")]
print(rs[:3])
assert rs and any("收到" in r for r in rs), "no response"
print("ASYNC_OK")
PY
```

---

## 4. 用例表

约定：命令列中的 `$UI`、`$DATA`、`$A0_AUTH_KEY`、`$TOKEN` 见第 1 节；`P1+S-X` 表示把第 3 节脚本填入 P1。单元格内所有管道符写作 `\|`。

### A. 安装与启动

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C01 | bundle 安装 | bundle 已放在 `$BUNDLE`；未安装或允许覆盖 | `flatpak install --user -y "$BUNDLE"; flatpak info --user $APP` | 退出码 0；`flatpak info` 含 `Version:`、`Branch: master`、`Installation: user` | 非零退出；装到 system；提示缺 runtime/dependency；info 里 branch 不是 master | `01-install.log`（含 Installing/installed 原文）+ `02-info.log` | 是（安装/覆盖） |
| C02 | health 200 | 服务已启动 | `curl -sS -o /tmp/a0-health.json -w '%{http_code}\n' $UI/api/health; cat /tmp/a0-health.json` | HTTP 200；body 是 JSON；同时含 `gitinfo` 与 `error` 键；`error` 为 null 或字符串均可 | 非 200；body 非 JSON；缺任一键；5xx；连接拒绝 | `02-health.log`（HTTP 码 + body 原文） | 否 |
| C03 | 根路径无 key 401 | 服务以非空 `A0_AUTH_KEY` 启动 | `curl -sS -D /tmp/a0-root.hdr -o /tmp/a0-root.txt -w '%{http_code}\n' $UI/; grep -i '^www-authenticate:' /tmp/a0-root.hdr; cat /tmp/a0-root.txt` | HTTP 401；body 为 `unauthorized`；header 含 `WWW-Authenticate: Bearer` | 200；302 到应用页面；body 是 HTML；401 但 body 为空；缺 `WWW-Authenticate` | `03-root-401.log`（HTTP 码 + 关键 header + body；不含 key） | 否 |
| C04 | 根路径带 key 200 | 同上；`A0_AUTH_KEY` 已导出 | `curl -sS -o /tmp/a0-root-ok.html -w '%{http_code} %{size_download}\n' -H "Authorization: Bearer $A0_AUTH_KEY" $UI/; grep -c 'index.js' /tmp/a0-root-ok.html` | HTTP 200；`size_download` > 10000；`index.js` 计数 ≥ 1 | 401；200 但 body 为空或 < 1000 字节；5xx；grep 为 0 | `04-root-200.log`（HTTP 码 + size；截图首页） | 否 |
| C05 | `?key=` 设 cookie | 同上；使用临时 cookie jar | `curl -sS -c /tmp/a0.cookies -D /tmp/a0.hdr -o /dev/null "$UI/?key=$A0_AUTH_KEY"; grep -i '^set-cookie: a0key=' /tmp/a0.hdr; grep -ci httponly /tmp/a0.hdr; curl -sS -b /tmp/a0.cookies -o /dev/null -w '%{http_code}\n' $UI/` | 第一条 200 且 `Set-Cookie: a0key=`；`httponly` 计数 ≥ 1；第二条 200 | 无 Set-Cookie；第二条仍 401；cookie 缺 HttpOnly；key 出现在 body/URL 日志 | `05-query-key.log`（header 原文，key 值打码） | 否 |
| C06 | 错误 key 拒绝 | 同上 | `curl -sS -D /tmp/a0-bad.hdr -o /tmp/a0-bad.txt -w '%{http_code}\n' "$UI/?key=wrong-$RANDOM"; grep -ci '^set-cookie: a0key=' /tmp/a0-bad.hdr; cat /tmp/a0-bad.txt` | HTTP 401；grep 计数为 0；body 为 `unauthorized` | 200；返回 Set-Cookie；5xx；body 泄漏页面 | `06-wrong-key.log`（HTTP 码 + 计数 + body） | 否 |
| C07 | 免鉴权白名单 | 同上 | `for p in /api/health /js/manifest.json /api/csrf_token; do printf '%s ' "$p"; curl -sS -o /dev/null -w '%{http_code}\n' "$UI$p"; done` | 依次 200、200、401 | `/api/csrf_token` 返回 200；`/api/health` 或 manifest 返回 401；任一 5xx | `07-exempt.log`（3 个 HTTP 码） | 否 |

### B. Web UI 渲染

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C08 | 首页 HTML | C04 通过 | `curl -sS -H "Authorization: Bearer $A0_AUTH_KEY" -o /tmp/a0-index.html -w '%{http_code} %{size_download}\n' $UI/; grep -c 'index.js' /tmp/a0-index.html` | 200；size > 10000；`index.js` 计数 ≥ 1；含 `<html` 与 `Agent Zero` | 200 但 size < 5000；grep 为 0；body 是 JSON/错误页；5xx | `08-index.log` + `08-index.png` | 否 |
| C09 | 关键静态资源 | C04 通过 | `for p in /index.css /js/initFw.js /public/icon.svg; do printf '%s ' "$p"; curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' -H "Authorization: Bearer $A0_AUTH_KEY" "$UI$p"; done` | 三个均 200；content-type 分别含 `css`、`javascript`、`svg` | 任一非 200；content-type 为 `text/html`（SPA 兜底）；5xx | `09-static.log`（3 行状态 + 类型） | 否 |
| C10 | 设置页片段 | C04 通过 | `curl -sS -H "Authorization: Bearer $A0_AUTH_KEY" -o /tmp/a0-models.html -w '%{http_code} %{size_download}\n' $UI/plugins/_model_config/webui/main.html; grep -Eic 'model\|preset' /tmp/a0-models.html` | 200；size > 500；关键词计数 ≥ 1 | 404；200 但 size < 200；关键词为 0；5xx | `10-settings.log` + `10-settings.png`（设置 → Agent → Models） | 否 |
| C11 | 聊天页可用 | C04 通过 | `curl -sS -H "Authorization: Bearer $A0_AUTH_KEY" -o /tmp/a0-csrf.json -w '%{http_code}\n' $UI/api/csrf_token; python3 -c 'import json;d=json.load(open("/tmp/a0-csrf.json"));print(sorted(d));assert d.get("token") and d.get("runtime_id")'` | 200；JSON 含非空 `token` 与 `runtime_id`；首页含 `chat` 字样 | 401；缺任一字段；token 为空；首页无输入框（截图判定） | `11-chat.log` + `11-chat.png`（聊天页可见输入框） | 否 |
| C12 | PWA manifest | 无（白名单） | `curl -sS -o /tmp/a0-manifest.json -w '%{http_code}\n' $UI/js/manifest.json; python3 -c 'import json;d=json.load(open("/tmp/a0-manifest.json"));assert d["name"] and d["start_url"] and d["icons"] and d["display"]=="standalone";print(d["name"],len(d["icons"]))'` | 200；JSON 可解析；`name`、`start_url`、非空 `icons`、`display=standalone` | 401；非 JSON；缺字段；icons 为空 | `12-manifest.log`（HTTP 码 + 解析后的字段） | 否 |
| C13 | 缺失资源 404 | C04 通过 | `curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $A0_AUTH_KEY" $UI/js/does-not-exist-probe.js` | 404 | 200（SPA 兜底返回 HTML）；500；连接错误 | `13-404.log`（HTTP 码） | 否 |

### C. 聊天

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C14 | kw92 端点直验 | zproxy 在 18080 | `curl -sS -m 60 -o /tmp/a0-chat.json -w '%{http_code}\n' http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"mistral/deepseek-v4-1-flash-1017","messages":[{"role":"user","content":"用一句简体中文回答：1+1 等于几？"}],"max_tokens":64}'; python3 -c 'import json;d=json.load(open("/tmp/a0-chat.json"));c=d["choices"][0];print(c["finish_reason"],repr(c["message"]["content"]));assert c["finish_reason"]=="stop" and "2" in c["message"]["content"]'` | HTTP 200；`finish_reason=stop`；content 非空且含 `2`；`usage.completion_tokens` > 0 | 非 200；content 为空；finish_reason 为 `length`；body 是纯文本错误；超时 | `14-kw92.log`（HTTP 码 + 响应原文） | 否 |
| C15 | `/api/api_message` 一次回答 | P2 已生成 token | `TOKEN=$(cat ~/.a0-probe-token); curl -sS -m 180 -o /tmp/a0-msg.json -w '%{http_code}\n' $UI/api/api_message -H 'Content-Type: application/json' -H "Authorization: Bearer $A0_AUTH_KEY" -H "X-API-Key: $TOKEN" -d '{"message":"只回答两个字：收到","context_id":"probe-chat-1"}'; python3 -c 'import json;d=json.load(open("/tmp/a0-msg.json"));print(d);assert d.get("context_id")=="probe-chat-1" and "收到" in d.get("response","")'` | 200；`context_id` 回显；`response` 含 `收到`；不是 `Model not configured.` | 401/403；response 为空或为 `Model not configured.`；context_id 被改写；5xx；超时 | `15-api-message.log`（HTTP 码 + JSON，key 打码） | 是（写会话/日志） |
| C16 | 多轮上下文 | C15 通过 | `TOKEN=$(cat ~/.a0-probe-token); curl -sS -m 180 -o /tmp/a0-m1.json -H 'Content-Type: application/json' -H "Authorization: Bearer $A0_AUTH_KEY" -H "X-API-Key: $TOKEN" -d '{"message":"记住数字 7391，只回答：好","context_id":"probe-chat-mem"}' $UI/api/api_message; curl -sS -m 180 -o /tmp/a0-m2.json -H 'Content-Type: application/json' -H "Authorization: Bearer $A0_AUTH_KEY" -H "X-API-Key: $TOKEN" -d '{"message":"我刚才让你记住的数字是多少？只回答数字","context_id":"probe-chat-mem"}' $UI/api/api_message; python3 -c 'import json;a=json.load(open("/tmp/a0-m1.json"));b=json.load(open("/tmp/a0-m2.json"));print(a.get("response"),b.get("response"));assert "7391" in b.get("response","")'` | 两轮均 200；第二轮 `response` 含 `7391`；两轮 `context_id` 相同 | 第二轮不含 7391；context_id 变化；第二轮要求重述；5xx | `16-multiturn.log`（两轮 JSON） | 是（写会话） |
| C17 | `max_tokens=384000` 被接受 | zproxy 在 18080 | `curl -sS -m 60 -o /tmp/a0-maxtok.json -w '%{http_code}\n' http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"mistral/deepseek-v4-1-flash-1017","messages":[{"role":"user","content":"只回答 OK"}],"max_tokens":384000}'; python3 -c 'import json;d=json.load(open("/tmp/a0-maxtok.json"));c=d["choices"][0];print(c["finish_reason"],d["usage"]);assert c["finish_reason"]=="stop" and d["usage"]["completion_tokens"]<100'` | 200；`finish_reason=stop`；`completion_tokens` < 100；content 含 `OK` | 400（参数被拒）；超时；finish_reason 为 `length`；completion_tokens 接近 384000 | `17-maxtokens.log`（HTTP 码 + usage 原文） | 否 |
| C18 | 错误模型名可读 | zproxy 在 18080 | `curl -sS -m 60 -o /tmp/a0-badmodel.txt -w '%{http_code}\n' http://127.0.0.1:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"no-such-model-xyz","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'; python3 -c 'b=open("/tmp/a0-badmodel.txt").read();print(b[:300]);assert b.strip() and len(b)<4096 and "Traceback" not in b and any(k in b.lower() for k in ("error","message","model"))'` | HTTP 为 400/404/422/503 之一，或 200 且 body 含 `error`；body 非空、< 4KB、无 `Traceback`、含 error/message/model 之一 | 500 且 body 含堆栈；空 body；挂起 > 60s；200 但无任何错误说明 | `18-bad-model.log`（HTTP 码 + body 原文） | 否 |
| C19 | 空消息 | P2 已生成 token | `TOKEN=$(cat ~/.a0-probe-token); curl -sS -m 60 -o /tmp/a0-empty.txt -w '%{http_code}\n' $UI/api/api_message -H 'Content-Type: application/json' -H "Authorization: Bearer $A0_AUTH_KEY" -H "X-API-Key: $TOKEN" -d '{"message":"","context_id":"probe-empty"}'; head -c 200 /tmp/a0-empty.txt; curl -sS -o /dev/null -w 'HEALTH=%{http_code}\n' $UI/api/health` | 第一条 HTTP 为 200/400/422 之一；body ≤ 4KB 且非空；随后 `HEALTH=200`；服务未退出 | 500 + 堆栈；连接被重置；随后 health 非 200；挂起 > 60s | `19-empty.log`（两次 HTTP 码 + body 前 200 字） | 是（可能建空会话） |
| C20 | 缺 `X-API-Key` | 服务在跑 | `curl -sS -o /tmp/a0-nokey.txt -w '%{http_code}\n' -H 'Content-Type: application/json' -H "Authorization: Bearer $A0_AUTH_KEY" -d '{"message":"x","context_id":"probe-nokey"}' $UI/api/api_message; head -c 200 /tmp/a0-nokey.txt` | HTTP 401 或 403；body 非空且不含回答正文 | 200；返回模型回答；5xx；body 含完整设置页 | `20-nokey.log`（HTTP 码 + body） | 否 |
| C21 | 浏览器等价路径 | C15 通过（聊天模型已配好）；P3 可用 | `bash S-CHAT-ASYNC.sh` | 脚本打印 `ASYNC_OK`；至少一条 `type=="response"` 的 content 含 `收到`；`message_async` 回执含 `Message received.` | 60 次轮询后无 response；CSRF 403；回执非 200；response 为空 | `21-async.log`（脚本完整 stdout） | 是（写会话） |
| C22 | 超长消息不崩 | P2 已生成 token | `TOKEN=$(cat ~/.a0-probe-token); python3 -c 'import json;open("/tmp/a0-long.json","w").write(json.dumps({"message":"验收"*50000,"context_id":"probe-long"}))'; curl -sS -m 120 -o /tmp/a0-long-resp.txt -w '%{http_code}\n' $UI/api/api_message -H 'Content-Type: application/json' -H "Authorization: Bearer $A0_AUTH_KEY" -H "X-API-Key: $TOKEN" --data-binary @/tmp/a0-long.json; python3 -c 'b=open("/tmp/a0-long-resp.txt").read();print(len(b));assert b.strip() and len(b)<1048576'; curl -sS -o /dev/null -w 'HEALTH=%{http_code}\n' $UI/api/health` | HTTP 为 200/400/413/422 之一；body 非空且 < 1MB；随后 `HEALTH=200`；服务未退出 | 500 + 堆栈；连接被重置；挂起 > 120s；随后 health 非 200 | `22-long-message.log`（HTTP 码 + body 长度 + health） | 是（可能建会话） |

### D. 嵌入与记忆

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C23 | 嵌入维度 2560 | Ollama 在跑；嵌入模型存在 | `P1 + S-EMB` | 打印 `OllamaEmbeddings`、`qwen3-embedding:4b-q4_K_M`、`dimensions: 2560`、`EMB_OK` | 维度非 2560；class 不是 `OllamaEmbeddings`；模型名被替换；`ConnectError` | `23-embed.log`（完整 stdout） | 否 |
| C24 | 记忆写入 | C23 通过 | `P1 + S-MEM MODE=write` | 打印 `inserted:` 非空 id、`dir:` 以 `$DATA/usr/memory/default` 结尾、`WRITE_OK`；目录下出现索引文件 | 插入抛异常；id 为空；dir 指到别处；无文件落盘 | `24-mem-write.log` + `24-files.log`（`ls -l $DATA/usr/memory/default`） | 是（写索引） |
| C25 | 记忆检索 | C24 已写入 | `P1 + S-MEM MODE=search` | `hits:` ≥ 1；至少一条命中含 `42`；`SEARCH_OK` | hits 为 0；无 42；抛维度不匹配；`ConnectError` | `25-mem-search.log` | 否 |
| C26 | 记忆删除 | C24 的 `inserted` id，记为 MID | `P1 + S-MEM MODE=delete`（在 `INNER` 内加 `export MID=<C24 的 id>`） | `removed:` ≥ 1；`hit42_after: False`；`DELETE_OK` | removed 为 0；删除后仍命中 42；抛异常 | `26-mem-delete.log` | 是（删索引数据） |
| C27 | 旧 faiss 索引不兼容 | C24 已生成索引 | `cp -a $DATA/usr/memory/default/index.faiss /tmp/idx.bak; python3 -c 'import pickle;pickle.dump({"format":"real-faiss","dimension":2560},open("'"$DATA"'/usr/memory/default/index.faiss","wb"))'; P1 + S-MEM MODE=load; rm -f $DATA/usr/memory/default/index.faiss $DATA/usr/memory/default/index.pkl; P1 + S-MEM MODE=load` | 第一次 `load` 抛 `ValueError` 且消息含 `is not a a0flatpak numpy index`；删除两个索引文件后第二次打印 `LOAD_OK` | 第一次静默成功并返回错误数据；抛未包装的 `UnpicklingError`/`TypeError`；删除后仍无法重建；没有备份 | `27-old-index.log`（两次 stdout + 异常原文） | 是（临时替换/删除索引，必须先备份） |

### E. 语音

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C28 | TTS 出 WAV | Ollama 在跑；`A0_SPEECH_MODEL` 可用 | `P1 + S-SPEECH MODE=tts` | 打印 `RIFF`/`WAVE`；`wave` 可解析；`sample_rate` 在 8000–48000；`seconds` > 0.5；bytes > 1000；`TTS_OK` | 非 RIFF；wave 解析失败；时长为 0；bytes ≤ 1000；异常 | `28-tts.log` + `28-tts.wav`（把 base64 解码后落盘） | 否 |
| C29 | STT 回译 | C28 通过 | `P1 + S-SPEECH MODE=stt` | 返回 dict，含 `text`/`segments`/`language`；text 非空且含「验收/探针/往返」之一；`STT_OK` | text 为空；键缺失；异常；text 与输入完全无关 | `29-stt.log` | 否 |
| C30 | 空文本 TTS | 服务在跑 | `P1 + S-SPEECH MODE=empty`；再 `P3` 后 `curl -sS -o /tmp/a0-tts-empty.json -w '%{http_code}\n' -b "$HOME/.a0-cookies" -H "Authorization: Bearer $A0_AUTH_KEY" -H 'Content-Type: application/json' -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" -d '{"text":""}' $UI/api/plugins/_kokoro_tts/synthesize; cat /tmp/a0-tts-empty.json` | 脚本打印 `EMPTY_AUDIO` 与 `EMPTY_OK`；HTTP 为 200 且 `audio` 为空，或 4xx 且 body 可读；服务不崩 | 500 + 堆栈；返回非空 WAV（说明空输入未被处理）；挂起；随后 health 非 200 | `30-tts-empty.log`（脚本 stdout + HTTP 码 + body） | 否 |
| C31 | 超长文本 | Ollama 在跑 | `P1[--env=A0_SPEECH_TIMEOUT=180] + S-SPEECH MODE=long`（整条命令前加 `time -p`） | 打印 `TTS_OK`（完整 WAV、时长 > 0.5s）或 `TIMEOUT_OK`（异常消息含 timeout）；`real` ≤ 200s | 无输出/挂死 > 200s；异常消息不含 timeout；返回 0 字节且非 `EMPTY_AUDIO` | `31-tts-long.log`（stdout + `time -p` 的 `real` 行） | 否 |
| C32 | Ollama 不可达 | 服务在跑；不改系统 Ollama | `P1[--env=OLLAMA_HOST=http://127.0.0.1:9] + S-SPEECH MODE=tts EXPECT=connect`；随后 `curl -sS -o /dev/null -w 'HEALTH=%{http_code}\n' $UI/api/health` | 打印 `EXC: ...` 与 `CONNECT_ERROR_OK`；异常消息含 connect/refused；随后 health 200 | 未捕获异常；消息为空；服务退出；health 非 200 | `32-tts-offline.log`（脚本 stdout + health 码） | 否 |

### F. OCR 与文档解析

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C33 | 图片 → Markdown | P4 已生成 `a0_probe.png`；Ollama + OCR 模型可用 | `P1 + S-OCR MODE=image` | `len` > 0；文本非空且含 `42`；`OCR_OK` | 空文本；不含 42；`model not found`；`ConnectError`；`OCR_OK` 未打印 | `33-ocr-image.log` + 原图截图 | 否 |
| C34 | 数字 PDF 文本提取 | P4 已生成 `a0_probe.pdf` | `P1 + S-OCR MODE=pdf` | `len` > 0；文本含 `A0 PDF PROBE 42`；`OCR_OK` | `TypeError: ... takes 2 positional arguments but 3 were given`；空文本；`PyMuPDF` 缺失；`OCR_OK` 未打印 | `34-pdf-text.log` | 否 |
| C35 | 扫描 PDF 视觉回退 | P4 已生成 `a0_scan.pdf`；OCR 模型可用 | `P1 + S-OCR MODE=scan` | `len` > 0；文本含 `42`；`OCR_OK` | 空文本（未回退）；`model not found`；超时；`OCR_OK` 未打印 | `35-pdf-scan.log` | 否 |
| C36 | `pdf_ocr_fallback=false` 不回退 | P4 已生成 `a0_scan.pdf` | `P1[--env=OLLAMA_HOST=http://127.0.0.1:9] + S-OCR MODE=nofallback` | 返回空文本；打印 `NO_FALLBACK_OK`；没有 `ConnectError`（证明未触网） | 出现 `ConnectError`（说明仍回退）；返回非空文本；异常 | `36-no-fallback.log` | 否 |
| C37 | 多页超时 | P4 已生成 `a0_scan3.pdf` | `P1[--env=A0_OCR_TIMEOUT=1] + S-OCR MODE=scan EXPECT=timeout PDF_NAME=a0_scan3.pdf`（整条命令前加 `time -p`） | 打印 `EXC:` 与 `TIMEOUT_OK`；异常消息含 timeout/timed out；`real` < 60s | 挂死 > 60s；异常消息不含 timeout；脚本被杀 | `37-ocr-timeout.log`（stdout + `time -p` 的 `real` 行） | 否 |
| C38 | OCR 模型缺失 | P4 已生成 `a0_probe.png` | `P1[--env=A0_OCR_MODEL=no-such-model:latest] + S-OCR MODE=image EXPECT=missing` | 打印 `EXC:` 与 `MODEL_MISSING_OK`；消息含 404 或 not found | 成功返回（说明覆盖未生效）；异常消息为空；服务崩 | `38-ocr-missing.log` | 否 |
| C39 | 损坏 PDF | P4 已生成 | `P1 + S-OCR MODE=badfile EXPECT=badfile` | 打印 `EXC:` 与 `BADFILE_ERR_OK`；消息可读（≤ 4KB，无裸 `Traceback`） | 打印 `BADFILE_NO_ERROR`（静默接受）；未捕获异常；挂起 | `39-bad-pdf.log` | 否 |

### G. 浏览器工具

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C40 | 发现宿主 Chrome | 已做 `/opt/google/chrome:ro` override 并重启（P5） | `P1[--env=A0_BROWSER_CHROME=/opt/google/chrome/google-chrome] + S-BROWSER MODE=chrome` | 打印 `chrome: /opt/google/chrome/google-chrome`；`CHROME_OK` | `chrome: None`；路径不存在；打印后断言失败 | `40-chrome.log` + `flatpak info --show-permissions` 的 filesystems 行 | 否 |
| C41 | 打开 data: URL 取标题 | C40 通过 | `P1[--env=A0_BROWSER_CHROME=/opt/google/chrome/google-chrome] + S-BROWSER MODE=title` | 打印 `title: 'A0 Probe Title'`；`BROWSER_OK` | 标题不匹配；`open` 抛异常；退回下载 Patchright；无输出 | `41-browser-title.log` | 是（起 Chrome、可能写 profile） |
| C42 | 不可执行的 override 报可读错误 | `A0_BROWSER_CHROME` 指向存在但不可执行的文件（`/etc/passwd`）；应用已按 P5 启动 | `P1[--env=A0_BROWSER_CHROME=/etc/passwd] + S-BROWSER MODE=nochrome` | 打印 `chrome: None`、`OPEN_ERROR:`（消息非空、≤ 4 KB、无 `Traceback`、不含 `EACCES`）、`NO_CHROME_OK`；60 秒内返回 | `chrome:` 仍返回 `/etc/passwd`；错误里直接出现 `EACCES` 或裸堆栈；进程挂死 > 60s | `42-no-chrome.log`（stdout + 该次 `flatpak run --env` 的命令行原文） | 否 |
| C43 | 打开/关闭幂等 | C40 通过 | `P1[--env=A0_BROWSER_CHROME=/opt/google/chrome/google-chrome] + S-BROWSER MODE=idempotent` | 两次 `open` 均返回 id；`close_all` 连续两次不抛异常；`IDEMPOTENT_OK` | 第二次 open 失败；第二次 close_all 抛 `KeyError`/`RuntimeError`；残留标签页 | `43-browser-idem.log` | 是（起/停 Chrome） |

### H. 桌面 / Xpra

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C44 | `ensure_system_desktop()` | 服务在跑 | `P1 + S-DESKTOP MODE=start` | JSON 中 `available: true`；`session_id` 非空；`display` 为 `:0` 或 `:120` 类；`url` 非空；`DESKTOP_OK` | `available: false`；`error` 提到 xpra/xpra-html5 缺失；`url` 为空；异常 | `44-desktop.log`（JSON + session 文件） | 是（起 xpra、写 sessions） |
| C45 | 14500 与 HTML5 | C44 通过 | `ss -ltn \| grep -E '1450[0-9]'; curl -sS -o /tmp/a0-xpra.html -w '%{http_code}\n' http://127.0.0.1:14500/; grep -ci xpra /tmp/a0-xpra.html` | `ss` 至少一行 `127.0.0.1:1450x`；HTTP 200；body 中 `xpra` 计数 ≥ 1（HTML5 页面） | 无监听；连接拒绝；非 200；body 是二进制/不含 xpra | `45-xpra.log`（ss 行 + HTTP 码 + body 前 200 字）+ `45-xpra.png` | 否 |
| C46 | 鉴权映射分支 | C44 通过；记录是否设置 `A0_AUTH_KEY` | `P1 + S-DESKTOP MODE=branch` | 有 DISPLAY 且 X socket 存在：打印 `BRANCH_SHADOW_OK`，xpra 命令行不含 `--tcp-auth=env`；否则：打印 `BRANCH_HEADLESS_OK`，命令行含 `--tcp-auth=env` 与 `start-desktop` | 分支与输出不一致；shadow 下出现 `--tcp-auth=env`；headless 下缺 `--tcp-auth=env`；无 xpra 进程 | `46-xpra-auth.log`（分支判定 + ps 命令行，**不记录 XPRA_PASSWORD 值**） | 否 |
| C47 | Xvfb 路径可达 | 无 DISPLAY 场景 | `P1 + S-DESKTOP MODE=static-xvfb` | `host_display` 为 `None`、`:N` 或含 `No desktop to share`；`Xvfb` 显示路径或 `exists`；`xpra` 存在；`XVFB_OK` | Xvfb MISSING；xpra MISSING；抛未捕获异常；`host_display` 为无法解释的值 | `47-xvfb.log` | 否 |
| C48 | 强制 headless 启动 | 已执行 `rm -rf /tmp/a0-sessions.bak; cp -a $DATA/usr/plugins/_desktop/sessions /tmp/a0-sessions.bak; mkdir -p $DATA/usr/plugins/_desktop/sessions; rm -f $DATA/usr/plugins/_desktop/sessions/*`；P5 重启 | `P1 + S-DESKTOP MODE=headless`；之后 `cp -a /tmp/a0-sessions.bak/. $DATA/usr/plugins/_desktop/sessions/` 并 P5 | `available: true`；`display` 为 `:120`（或 `:0`）；`url` 非空；ps 中出现 `start-desktop`；`HEADLESS_OK` | `available: false`；display 不是 `:120`/`:0`；ps 无 `start-desktop`；端口不通；异常 | `48-headless.log` + `ss -ltn` 原文 + 恢复命令输出 | 是（起第二会话、清桌面状态） |

### I. WPS MCP

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C49 | 配置语法与可执行 | WPS 扩展已 user 安装；`usr/settings.json` 已注册 | `jq -r '.mcp_servers \| fromjson \| .mcpServers["wps-office"].command' $DATA/usr/settings.json; CMD=$(jq -r '.mcp_servers \| fromjson \| .mcpServers["wps-office"].command' $DATA/usr/settings.json); test -r "$CMD" && echo CMD_OK` | jq 输出非 `null`；`test -r` 成功并打印 `CMD_OK`；路径在 `~/.local/share/flatpak/...` | jq 报解析错误；输出 `null`；`test -r` 失败；路径是 `/var/lib/flatpak` 或 `bin/node` | `49-wps-config.log`（jq 输出 + `ls -l $CMD`） | 否 |
| C50 | `initialize` 握手 | C49 通过 | `MODE=init python3 S-WPS` | `rc: 0`；`server: wps-office-mcp 2024-11-05`；`WPS_OK` | `rc != 0`；`FileNotFoundError`；serverInfo 名不符；无 stdout | `50-wps-init.log`（rc + 首行 JSON） | 否 |
| C51 | `tools/list` 非空 | C50 通过 | `MODE=tools python3 S-WPS` | `tools:` > 0；列表含 `wps_check_connection`；`WPS_OK` | tools 为空；无 `wps_check_connection`；超时 | `51-wps-tools.log`（工具数与名称） | 否 |
| C52 | 无宿主 WPS 时调用 | C51 通过；宿主无 `wps` 命令 | `MODE=call python3 S-WPS` | `rc: 0`；`call_has_error_or_content: True`；返回结构化 `isError`/`content` 或 JSON-RPC `error`；`WPS_OK` | 进程崩溃；无响应；返回空 content 且无 error；挂起 > 90s | `52-wps-call.log`（完整 JSON-RPC 响应） | 否 |

### J. systemd 与重启自恢复

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C53 | 两个 unit enabled | `scripts/install-services.sh` 已执行 | `systemctl is-enabled agent-zero.service agent-zero-desktop.service; systemd-analyze verify /etc/systemd/system/agent-zero.service /etc/systemd/system/agent-zero-desktop.service` | 两个均 `enabled`；verify 无错误输出（仅警告可接受） | 任一 `disabled`/`static`；verify 报语法错误；unit 不存在 | `53-units.log`（is-enabled + verify 原文） | 否 |
| C54 | restart 后 health 200 | C53 通过 | `sudo systemctl restart agent-zero; for i in $(seq 1 120); do code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 $UI/api/health); [ "$code" = 200 ] && break; sleep 1; done; echo "HTTP=$code"; systemctl is-active agent-zero.service` | `HTTP=200`；耗时 < 120s；`is-active` 为 `active` | 120s 内未 200；unit `failed`；反复重启 | `54-restart.log`（HTTP 码 + is-active + 耗时） | 是（重启服务） |
| C55 | 崩溃后 `Restart=always` | C54 通过 | `OLD=$(systemctl show -p MainPID --value agent-zero.service); sudo kill -9 "$OLD"; sleep 10; NEW=$(systemctl show -p MainPID --value agent-zero.service); echo "$OLD -> $NEW"; curl -s -o /dev/null -w 'HTTP=%{http_code}\n' $UI/api/health` | `NEW` 非 0 且不等于 `OLD`；`HTTP=200`；`systemctl is-active` 为 `active` | PID 不变；`HTTP` 非 200；unit 进入 `failed`；10s 后仍未恢复（可在 30s 内重试一次并记录） | `55-crash.log`（前后 PID + HTTP 码 + journal 片段） | 是（杀进程） |
| C56 | 开机自启 | C53 通过 | `sudo reboot`；等待目标机回来；`systemctl is-active agent-zero.service agent-zero-desktop.service; curl -s -o /dev/null -w '%{http_code}\n' $UI/api/health` | 两个 unit 均 `active`；health 200；无需手工登录桌面 | 任一 `inactive`/`failed`；health 非 200；需要手工 `flatpak run` 才能恢复 | `56-reboot.log`（重启前后时间、unit 状态、HTTP 码） | 是（重启机器） |
| C57 | 重启记录可读 | C55 已执行 | `journalctl -u agent-zero --since '-30 min' --no-pager \| grep -Ec 'Scheduled restart\|Restarting\|Started Agent Zero'` | 计数 ≥ 1；journal 中含重启原因或下一次启动记录 | 计数为 0；journal 无该时间段；权限不足读日志 | `57-journal.log`（grep 命中行，最多 20 行） | 否 |

### K. 资源与清理

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C58 | 无孤儿进程 | 服务在跑；刚执行过 C55 | `flatpak ps \| grep -c $APP; pgrep -af 'xpra' \| wc -l; ls $DATA/usr/plugins/_desktop/sessions/*.json 2>/dev/null \| wc -l` | `flatpak ps` 中应用实例数 = 1；xpra 进程数 ≤ 会话数 + 1；无重复的 `flatpak run`/`bwrap` 残留 | 实例数 > 1；xpra 进程数远大于会话数；出现两个 `flatpak run --user $APP`；`flatpak ps` 为空 | `58-processes.log`（三条命令原文） | 否 |
| C59 | 重装不清数据 | 已记录基线；C24 有数据 | `find $DATA/usr/memory -type f \| wc -l; sha256sum $DATA/conf/model_providers.yaml; flatpak install --user -y --reinstall "$BUNDLE"; find $DATA/usr/memory -type f \| wc -l; sha256sum $DATA/conf/model_providers.yaml` | 重装前后文件数相同；`model_providers.yaml` 哈希相同；`flatpak info` 仍为 master | 文件数减少；哈希变化；`usr/memory` 被清空；重装后需要重新注册 provider | `59-reinstall.log`（两次数值 + install 原文） | 是（重装应用） |
| C60 | 日志可读 | 服务在跑 | `journalctl -u agent-zero -n 50 --no-pager \| wc -l; test -r "$HOME/.a0-app.log" && tail -n 20 "$HOME/.a0-app.log"; journalctl -u agent-zero -n 50 --no-pager \| grep -c 'Permission denied'` | journal 行数 > 0；app log 可读且非空；`Permission denied` 计数为 0 | journal 为空；app log 不存在/不可读；日志含 NUL 或乱码导致 `tail` 失败；权限错误 | `60-logs.log`（journal 20 行 + app log 20 行） | 否 |
| C61 | 磁盘未异常增长 | 已记录基线；C15、C28、C33 已执行 | `du -sm $DATA; du -sm $DATA/usr/memory; du -sm $DATA/usr/uploads 2>/dev/null \|\| true` | 与基线相比 `$DATA` 增量 < 200 MB；`usr/memory` 增量 < 50 MB；无 > 100 MB 的单文件（模型目录除外） | 增量 ≥ 200 MB；出现异常大文件；`usr/uploads` 无上限增长；磁盘满导致 health 非 200 | `61-disk.log`（基线/复测两次数值 + `du -ah \| sort -h \| tail`） | 否 |

---

### L. 安全审计与边界（C62–C77）

> C62–C77 为本轮新增，共 16 条：安全 6（S01–S06）、语音 5（E06–E10）、OCR 3（F08–F10）、嵌入 1（D06）、稳定性 1（K05）。原编号写在「目的」列开头；状态与缺陷编号见本节末尾「未执行清单」。

判定口径：本节沿用 8 列，不新增第 9 列；类别写在「目的」列开头，PASS 条件见「期望结果」，FAIL 条件见「失败判据」，已有证据与待补证据见「证据要求」。已实测状态只在「未执行清单」里给结论。

新增片段 `S-EMB-EMPTY`（填进 `P1` 的 `<<'PY'` 位置）：

```python
from a0flatpak import embeddings
embeddings.apply()
import models
m = models.get_embedding_model("huggingface", "sentence-transformers/all-mpnet-base-v2")
try:
    v = m.embed_query("")
except Exception as e:
    print("EMPTY_EMB_ERROR:", type(e).__name__, str(e)[:200])
    print("EMPTY_EMB_OK")
else:
    print("len:", len(v), "l2:", sum(x * x for x in v) ** 0.5)
    print("EMPTY_EMB_OK" if len(v) == 0 else "EMPTY_EMB_SILENT_VECTOR")
```

| CASE | 目的 | 前置条件 | 执行命令/操作 | 期望结果（可断言的） | 失败判据 | 证据要求（截图/日志原文/HTTP 码） | 是否破坏性 |
|---|---|---|---|---|---|---|---|
| C62 | 安全 S01｜8 条 `nofilesystem` 遮蔽 | v14 或更新包已安装；`flatpak override --user --show $APP` 没有清空遮蔽的项 | `flatpak info --show-permissions $APP \| grep -o 'nofilesystem=[^;]*' \| sort` | 8 行，覆盖 `~/.ssh`、`~/.gnupg`、`~/.pki`、`~/.local/share/keyrings`、`~/.config/gh`、`~/.aws`、`~/.docker`、`~/.kube`；`filesystems` 行仍含 `host` | 少于 8 行；缺任一目录；`nofilesystem` 被 override 清掉；`flatpak info` 报错 | 已有：`security-fix-plan.md §3` manifest diff、`§6` 复验清单；补：命令原文 + `show-permissions` 全文 | 否 |
| C63 | 安全 S02｜`~/.ssh` 私钥不可读 | C62 通过；沙盒入口可用 | `flatpak run --user --command=sh $APP -c 'test -r ~/.ssh/id_ed25519 && echo SSH_READABLE \|\| echo SSH_BLOCKED; ls -A ~/.ssh'` | `SSH_BLOCKED`；`ls -A ~/.ssh` 为空（目录可作为空挂载点存在） | `SSH_READABLE`；`ls -A` 非空；命令报错 | 已有：`security-fix-plan.md §2` 组 1（`SSH_READABLE`）与组 2（`SSH_BLOCKED`）；补：本轮命令原文 | 否 |
| C64 | 安全 S03｜8 个敏感目录内容为空 | C62 通过 | `flatpak run --user --command=sh $APP -c 'for d in .ssh .aws .docker .kube .config/gh .gnupg .pki .local/share/keyrings; do printf "%s=" "$d"; ls -A "$HOME/$d" 2>/dev/null \| wc -l; done'` | 8/8 计数为 0；目录可以存在但内容为空；同时记录 stderr，避免把“目录不存在”误判为空 | 任一计数非 0；命令报错；只看到 0 但 stderr 有 `No such file`  | 已有：`security-fix-plan.md §2` 组 2（八目录空）；补：命令原文 + stderr | 否 |
| C65 | 安全 S04｜文件 API 拒绝 `~/.ssh` | P3 已取 CSRF；服务在跑 | `curl -sS -b "$HOME/.a0-cookies" -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" -o /tmp/s04.json -w '%{http_code}\n' "$UI/api/get_work_dir_files?path=$HOME/.ssh"; cat /tmp/s04.json` | HTTP 403；body JSON 含 `SENSITIVE_PATH_BLOCKED`；不返回任何文件名 | 200/500；body 含 `id_ed25519`/`authorized_keys`；marker 缺失；返回目录列表 | 已有：`edge-files.md §5`（当前穿越 200）、`security-audit.md §2 C13/C14`、`security-fix-plan.md §4`（补丁 403）；补：本轮 HTTP 码 + body | 否 |
| C66 | 安全 S05｜符号链接穿越被拒绝并清理 | C65 通过；应用 PID 可查 | `PID=$(pgrep -f 'run_ui.py.*--port=5080' \| head -1); ln -sfn "$HOME/.ssh" "/proc/$PID/root/a0/link-ssh"; curl -sS -b "$HOME/.a0-cookies" -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" -o /tmp/s05a.json -w '%{http_code}\n' "$UI/api/get_work_dir_files?path=/a0/link-ssh"; curl -sS -b "$HOME/.a0-cookies" -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" -o /tmp/s05b.json -w '%{http_code}\n' "$UI/api/get_work_dir_files?path=/a0/link-ssh/id_ed25519"; rm -f "/proc/$PID/root/a0/link-ssh"` | 两个请求均 403 + `SENSITIVE_PATH_BLOCKED`；不返回私钥内容；删除链接后同路径不再 200 | 200；返回 `id_ed25519` 内容；链接清理后仍 200；rm 后链接残留 | 已有：`security-audit.md §2 C14`（当前 `/a0/a0-link-etc/passwd` 200）、`security-fix-plan.md §4`（`/tmp/a0-link-ssh` 判真、handler 403）；补：两次 HTTP 码 + body + `ls -l` 清理结果 | 是（创建/删除临时链接，必须清理） |
| C67 | 安全 S06｜正常路径回归 | C62 通过；P3 可用 | `curl -sS -b "$HOME/.a0-cookies" -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" -o /tmp/s06a.json -w '%{http_code}\n' "$UI/api/get_work_dir_files?path=/a0"; curl -sS -b "$HOME/.a0-cookies" -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" -o /tmp/s06b.json -w '%{http_code}\n' "$UI/api/get_work_dir_files?path=$HOME/Documents"; printf probe > /tmp/a0-s06.txt; curl -sS -b "$HOME/.a0-cookies" -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" -F 'file=@/tmp/a0-s06.txt' -F 'path=/a0' -o /tmp/s06c.json -w '%{http_code}\n' "$UI/api/upload_work_dir_files"; rm -f /tmp/a0-s06.txt` | `/a0` 200 且列表非空；`~/Documents` 不是 403（存在则 200，不存在则明确 404）；上传临时文件 200 | 任一 403/500；`/a0` 空列表；上传失败；临时文件残留 | 已有：`security-fix-plan.md §2` 组 3、`§4`（`~/Documents`、`/a0` 判假）；`edge-files.md §2` A 组（上传/重命名/删除 200）；补：三次 HTTP 码 + 列表计数 | 是（写临时文件，需清理） |
| C68 | 语音 E06｜TTS HTTP 连续 3 次（每次 reload） | P3 可用；`_kokoro_tts` 插件 Reload 入口可用 | `for i in 1 2 3; do 在 UI Plugins 页 Reload _kokoro_tts；然后 curl -sS -b "$HOME/.a0-cookies" -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" -H 'Content-Type: application/json' -d '{"text":"验收探针"}' "$UI/api/plugins/_kokoro_tts/synthesize" -o /tmp/e06-$i.json -w '%{http_code}\n'; done` | 3/3 HTTP 200 且 `success:true` + `audio` 非空；任一次不得出现 `No module named 'spacy'` | 任一次 `success:false`；出现 `spacy`；HTTP 非 200；audio 为空 | 已有：`edge-media.md §2 A1`（当前 `success:false` + spacy）、`§4 M1`（reload 后补丁失效）；证据目录 `~/a0-shots/edge-media-20261118-050021/`；补：3 次 body | 否 |
| C69 | 语音 E07｜STT HTTP 连续 3 次（每次 reload） | P3 可用；`_whisper_stt` Reload 入口可用；3 个 WAV（语音/静音/粉噪） | `for i in 1 2 3; do 在 UI Plugins 页 Reload _whisper_stt；然后 curl -sS -b "$HOME/.a0-cookies" -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" -H 'Content-Type: application/json' -d "{\"audio\":\"$(base64 -w0 /tmp/wav-$i.wav)\"}" "$UI/api/plugins/_whisper_stt/transcribe" -o /tmp/e07-$i.json -w '%{http_code}\n'; done` | 3/3 HTTP 200 且 `success:true` + `text` 字段存在；不得出现 `module 'whisper' has no attribute 'load_model'` | 任一次 `success:false`；出现 `load_model`；HTTP 非 200；缺 `text` | 已有：`edge-media.md §2 B6-B8`（HTTP stub）、`§4 M1`；补：3 次 body | 否 |
| C70 | 语音 E08｜5500 字 HTTP 层上限 | P3 可用 | `python3 -c 'import json;print(json.dumps({"text":"验收"*1834},ensure_ascii=False))' > /tmp/e08.json; curl -sS -b "$HOME/.a0-cookies" -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" -H 'Content-Type: application/json' -d @/tmp/e08.json -o /tmp/e08.out -w '%{http_code}\n' "$UI/api/plugins/_kokoro_tts/synthesize"; head -c 300 /tmp/e08.out` | HTTP 4xx（400/413/422）且 body 含 `SpeechInputTooLong` 或 `1200` | 200；5xx；marker 缺失；返回 `success:false` + spacy 而不是上限错误 | 已有：`edge-media.md §2 A2`（HTTP 200 + spacy；部署层 `SpeechInputTooLong: speech input is 5500 characters, the limit is 1200`）；补：HTTP 码 + body | 否 |
| C71 | 语音 E09｜1 s 静音 | P3 可用；ffmpeg 可用 | `ffmpeg -y -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -c:a pcm_s16le /tmp/silence.wav; python3 -c 'import base64,json;print(json.dumps({"audio":base64.b64encode(open("/tmp/silence.wav","rb").read()).decode()}))' > /tmp/e09.json; curl -sS -b "$HOME/.a0-cookies" -H "X-CSRF-Token: $CSRF" -H "Origin: $UI" -H 'Content-Type: application/json' -d @/tmp/e09.json -o /tmp/e09.out -w '%{http_code}\n' "$UI/api/plugins/_whisper_stt/transcribe"; cat /tmp/e09.out` | 返回空文本，或显式 `SILENCE`/`no speech` 标志；不得返回 `Oh,`/`Okay.`/`So,` 等幻觉 | 非空幻觉文本且无标注；`success:false` 只给 stub 错误；HTTP 非 200 | 已有：`edge-media.md §2 B7`（部署层 `Oh,` + `success:true`，M6）；B8/B9 同类；补：本轮 body | 否 |
| C72 | 语音 E10｜中文 TTS→STT 语言标注 | Ollama 在跑；`A0_SPEECH_MODEL` 可用 | `P1 + S-SPEECH MODE=stt` | `language` 为 `zh`/`chinese`/`中文`，或显式 `language_unreliable:true`；text 非空 | `language=english` 且无“不可靠”标注；text 为空；异常 | 已有：`edge-media.md §2 B6`（中文音频转出英文、`language=english`，M7）；补：本轮 stdout | 否 |
| C73 | OCR F08｜5 页扫描 PDF 默认配置 | P4 同法生成 5 页 `a0_scan5.pdf`；Ollama + OCR 模型可用 | `P1 + S-OCR MODE=scan PDF_NAME=a0_scan5.pdf` | 处理 ≥4 页；或尾注明确写 `A0_OCR_MAX_PAGES=4`，不得只写 `timeout after 45.0s` | `2 of 5 pages` 且只写 timeout；空文本；异常；页数上限缺失 | 已有：`edge-media.md §2 C14/C14b/C14c`（默认 2/5 + timeout；`per_document_timeout=300` 时 4/5 + `A0_OCR_MAX_PAGES=4`，M3）；补：本轮 stdout | 否 |
| C74 | OCR F09｜截断 50% PDF | 生成 `trunc50.pdf`（`a0_scan5.pdf` 截断到 50%） | `P1 + S-OCR MODE=pdf PDF_NAME=trunc50.pdf` | 可读错误（`PDF could not be read` 类）；4xx/异常 | `ok=true` + `0 of 5 pages` + 空跑约 45 s；无错误；进程崩溃 | 已有：`edge-media.md §2 C15/C15b`（`0 of 5`、45.34 s、54 条 MuPDF `object out of range`，M4）；补：本轮 stdout + 耗时 | 否 |
| C75 | OCR F10｜100×50 低分辨率图 | 把 `$PROBE_DIR/a0_probe.png` 换成 `lowres100x50.png` | `P1 + S-OCR MODE=image` | 拒绝，或返回 `OCR incomplete`/低置信标注；不得返回无关文本且 `ok=true` | 无关文本 + 无标注；空文本；异常 | 已有：`edge-media.md §2 C13`（76 字符无关数学题，M5）；补：本轮 stdout | 否 |
| C76 | 嵌入 D06｜空字符串 | Ollama 在跑；嵌入模型存在 | `P1 + S-EMB-EMPTY` | `EMPTY_EMB_ERROR`（报错）或 `EMPTY_EMB_OK`（len=0）；不得静默返回非零单位向量 | `EMPTY_EMB_SILENT_VECTOR`；`len=2560` 且 L2≈1.0 无标注 | 已有：`edge-media.md §2 D20`（2560×1、L2=1.0、非零，M8）；补：本轮 stdout | 否 |
| C77 | 稳定性 K05｜空闲 10 分钟 RSS/fd | 独占实例，无其它 worker/会话；记录基线 RSS 与 fd | `PID=$(pgrep -f 'run_ui.py.*--port=5080' \| head -1); for i in $(seq 1 10); do date +%H:%M:%S; ps -o rss= -p $PID; ls /proc/$PID/fd \| wc -l; sleep 60; done` | 末次 RSS ≤ 基线×1.05；fd ≤ 基线+10；曲线回落或持平 | 持续单调上涨；末次 RSS 超基线 5% 或 fd 超基线 10；PID 变化 | 已有：`edge-media.md §3`（RSS 504→806 MB、fd 84→334，但含其它 worker，不能当泄漏证据；M9 待隔离复测）；补：独占实例 10 次采样 | 否 |

#### 未执行清单（C62–C77）

| CASE | 原编号 | 类别 | 状态 | 缺陷编号 | 依据 | 待办 |
|---|---|---|---|---|---|---|
| C62 | S01 | 安全 | 已实测失败（待构建复验） | S2/S3 缓解 | `security-audit.md §1`（当前权限无 `nofilesystem`）；`security-fix-plan.md §3/§6` | 构建含八条遮蔽的包后复验 |
| C63 | S02 | 安全 | 已实测失败（待构建复验） | S2 | `security-fix-plan.md §2` 组 1 `SSH_READABLE`；组 2 运行时 override `SSH_BLOCKED` | 构建后复验默认生效 |
| C64 | S03 | 安全 | 已实测失败（待构建复验） | S2 | `security-fix-plan.md §2` 组 2（八目录空，运行时 override） | 构建后复验默认生效 |
| C65 | S04 | 安全 | 已实测失败（待构建复验） | S2 | `edge-files.md §5`（当前 `?path=/etc` 200）；`security-fix-plan.md §4`（补丁 403） | 构建后复验 403 + marker |
| C66 | S05 | 安全 | 已实测失败（待构建复验） | S2 | `security-audit.md §2 C14`（`/a0/a0-link-etc/passwd` 200） | 构建后复验符号链接 403 + 清理 |
| C67 | S06 | 安全 | 已实测通过 | — | `security-fix-plan.md §2` 组 3、`§4`（`/a0`、`~/Documents` 判假） | 无；构建后回归一次 |
| C68 | E06 | 语音 | 已实测失败 | M1 | `edge-media.md §2 A1`（HTTP `success:false` + spacy） | 修复补丁 reload 失效后复验 |
| C69 | E07 | 语音 | 已实测失败 | M1 | `edge-media.md §2 B6-B8`（HTTP whisper stub） | 同上 |
| C70 | E08 | 语音 | 已实测失败 | M2 | `edge-media.md §2 A2`（HTTP 200 + spacy，未出现 `SpeechInputTooLong`） | 修复 HTTP 层上限后复验 |
| C71 | E09 | 语音 | 已实测失败 | M6 | `edge-media.md §2 B7`（静音返回 `Oh,` + `success:true`） | 加静音/幻觉拒识后复验 |
| C72 | E10 | 语音 | 已实测失败 | M7 | `edge-media.md §2 B6`（中文音频 `language=english`） | 修语言标注或加不可靠标记 |
| C73 | F08 | OCR | 已实测失败 | M3 | `edge-media.md §2 C14/C14b`（默认 2/5 + timeout；上限不可达） | 默认配置提高预算或尾注写 `MAX_PAGES` |
| C74 | F09 | OCR | 已实测失败 | M4 | `edge-media.md §2 C15/C15b`（0/5 + 45 s 空跑） | 截断 PDF 改为可读错误 |
| C75 | F10 | OCR | 已实测失败 | M5 | `edge-media.md §2 C13`（低分辨率图 76 字符无关数学题） | 加拒识/低置信标注 |
| C76 | D06 | 嵌入 | 已实测失败 | M8 | `edge-media.md §2 D20`（空串静默返回 2560 非零单位向量） | 空输入报错或返回空标志 |
| C77 | K05 | 稳定性 | 待复验 | M9 | `edge-media.md §3`（共享实例 RSS/fd 上涨，含其它 worker，不能当泄漏证据） | 独占实例空闲 10 分钟采样 |

状态计数：**已实测通过 1（C67）、已实测失败 14（C62–C66、C68–C76）、待复验 1（C77）**。合计 16 条 = 61 + 16 = **77**。

---

## 5. 证据目录约定

根目录：`docs/manual-acceptance/a0lite-deploy/evidence/<CASE>/`，`<CASE>` 用表里的编号，例如 `evidence/C15/`。

- 每个 CASE 至少 1 个文件：1 张截图或 1 段原始输出。
- 命名：`NN-描述.png` / `NN-描述.log`。音频或文档类原始产物允许 `NN-描述.wav` / `NN-描述.pdf`，规则同上。`NN` 从 `01` 起，按执行顺序递增；同一 CASE 内不重复。
- 日志必须是**原始输出**，不要手工改写；需要打码的只有 `A0_AUTH_KEY`、`X-API-Key`、`XPRA_PASSWORD`，用 `<redacted>` 替换，并在文件头写一行 `redacted: <字段名>`。
- 截图必须包含可判读的界面状态或终端输出；纯文字结论不算证据。
- 每个 CASE 在 `report.md` 中记录：执行时间、执行人、命令摘要、观察到的 HTTP 码/关键输出、分数、PASS/FAIL。`report.md` 由执行者写，本文件不填。

示例：

```
evidence/C15/
  01-api-message.log
  02-chat-ui.png
evidence/C45/
  01-ss-listen.log
  02-xpra-html.png
```

---

## 6. 评分规则

### 6.1 硬失败（直接记 0，并触发全局 FAIL）

任一条件成立，该 CASE 记 0，整个验收判 FAIL，不再计算其他分数：

- 造成 `$DATA/usr/` 下数据不可恢复丢失（无备份、无重建路径）。
- 证明受保护资源可在无 key、错 key 或过期 cookie 下访问（C03/C06/C07/C20/C46 任一被绕过）。
- 证据或日志中出现完整的 `A0_AUTH_KEY`、`X-API-Key` 或 `XPRA_PASSWORD` 值。
- 用例执行后宿主机无法恢复到执行前状态，且没有事先备份。

### 6.2 五档锚点

每个 CASE 先判四个门，再落档：

- **M（主路径）**：该 CASE 的第一条正向断言是否全部通过。
- **E（边界/错误路径）**：该 CASE 的失败路径、空输入、错误模型、超时、幂等是否执行并通过。
- **V（证据）**：每个断言是否有对应的原始输出或截图，且可被第二人复核。
- **S（副作用）**：是否留下未清理的进程、文件、override 或会话。

| 分数 | 判定 |
|---|---|
| 90–100 | M 全部通过；E 全部执行且通过；V 每个断言有证据；S 无残留；无硬失败 |
| 70–89 | M 全部通过；E 缺 1 项证据或 1 项边界未执行；V 基本完整；S 有可清理残留 |
| 50–69 | M 全部通过；E 有 ≥ 2 项未执行或 ≥ 2 项证据缺失；或存在次要缺陷（文案错误、日志噪音、非关键 5xx 重试、非关键告警） |
| 20–49 | M 部分失败，但存在已验证的绕过路径，且绕过步骤写入证据 |
| 0–19 | M 失败且无绕过；或不可执行；或硬失败 |

上限规则（优先于档内取值）：

- M 通过但 V 完全没有原始输出 → 49（无法复核，落 20–49 档）。
- M 通过、V 有证据，但 E 完全未执行且该 CASE 的边界项 ≥ 2 → 50（落 50–69 档）。
- M 通过、E 通过、V 完整，但有未清理副作用 → 89（上限 89，落 70–89 档）。
- 硬失败 → 0，且全局 FAIL。

### 6.3 PASS 阈值

- 单 CASE：**≥ 70 为 PASS**，< 70 为 FAIL。
- 阈值边界：70 表示主路径全部通过、边界缺 1 项证据；69 表示主路径通过但边界完全未执行，或存在次要缺陷。
- 全局：所有 CASE 均 ≥ 70 且无硬失败，才判全局 PASS。
- 任一 CASE 触发 6.1，全局直接 FAIL，不论其他 CASE 分数。

### 6.4 可复现要求

1. 两名审计者各自只看 `evidence/<CASE>/` 与本文件，不看对方分数，独立打分。
2. 打分顺序固定：M 逐条勾选 → E 逐条勾选 → V 逐项核对 → S 核对；按 6.2 落档。
3. 分数只取档内最小值（90、70、50、20、0 之一），以 5 分为粒度；不允许凭印象给中间值。
4. 两名审计者差异 ≤ 5 分时取平均；> 5 分时由第三名审计者按同一证据重打，取三人中位数。
5. 任何分数必须能指向具体证据文件与具体断言；指不出证据的分数记 0。
6. 建议在同一台机器、同一时段完成同一 CASE 的两次打分，避免环境漂移。

### 6.5 评分示例（只示范换算，不是执行结论）

- 某 CASE 主路径全过，错误路径只跑了 1 条、另 1 条缺日志：M 过、E 缺 1 项证据 → 70–89，取 70。
- 某 CASE 主路径全过，但有 3 条边界全部没跑：M 过、E 有 3 项未执行 → 50–69，取 50。
- 某 CASE 主路径全过、证据齐全，但留下了未关闭的 Chrome 进程：S 有残留 → 上限 89，取 70。
- 某 CASE 返回 500 且无绕过：M 失败 → 0–19，取 0。
