# Xpra `mmap` 导入问题：取证、根因与修复

- 应用：`org.agentzero.AgentZero`，Flatpak user 安装
- 安装 commit：`1ddcd34f7b351eab88be1d14789c27f400c3b04d3e2611d6e8d01f03d237075b`
- 仓库：`/home/kunweiz/Desktop/a0lite`
- 结论先行：**`No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package` 在当前安装树里不可复现。**
  镜像与 venv 都是 `mmap/` 包，`import xpra.net.mmap.common` 实测成功；静态预演一次构建也成功。
  本轮改动把这条保证从"碰巧成立"变成**构建期硬断言**，并订正了关于布局年代的注释。

**证据分级**：本报告的根因判定只依据可重复执行的 import 实测、文件内容哈希与 deb 成员清单，
不依据 `xpra-stderr.log`。原因见 1.4：该日志在每次桌面 spawn 时被 `open(..., "wb")` 截断。

---

## 1 取证：镜像里是"模块"还是"包"

### 1.1 沙盒内原始输出

```
=== PYTHONPATH ===
                                          <- 空：直接 `flatpak run --command=sh` 不走 launcher
=== which python ===
ls: cannot access '/app/bin/python*': No such file or directory
/usr/bin/python3
/usr/bin/python
=== /app/share/python-deps/xpra/net (head 60) ===
total 288
drwxr-xr-x  1 kunweiz kunweiz   618 Jan  1  1970 .
drwxr-xr-x  1 kunweiz kunweiz   552 Jan  1  1970 ..
-rw-r--r-- 28 kunweiz kunweiz   213 Jan  1  1970 __init__.py
drwxr-xr-x  1 kunweiz kunweiz    40 Jan  1  1970 aio
drwxr-xr-x  1 kunweiz kunweiz   194 Jan  1  1970 brotli
-rw-r--r--  4 kunweiz kunweiz 26665 Jan  1  1970 bytestreams.py
-rw-r--r--  4 kunweiz kunweiz 14534 Jan  1  1970 common.py
-rw-r--r--  4 kunweiz kunweiz  9027 Jan  1  1970 compression.py
-rw-r--r--  4 kunweiz kunweiz 16152 Jan  1  1970 connect.py
-rw-r--r--  4 kunweiz kunweiz  5227 Jan  1  1970 constants.py
drwxr-xr-x  1 kunweiz kunweiz    56 Jan  1  1970 control
-rw-r--r--  4 kunweiz kunweiz 11035 Jan  1  1970 crypto.py
-rw-r--r--  4 kunweiz kunweiz  4727 Jan  1  1970 device_info.py
-rw-r--r--  4 kunweiz kunweiz  4790 Jan  1  1970 digest.py
-rw-r--r--  4 kunweiz kunweiz  5126 Jan  1  1970 dispatch.py
-rw-r--r--  4 kunweiz kunweiz 51935 Jan  1  1970 file_transfer.py
drwxr-xr-x  1 kunweiz kunweiz   100 Jan  1  1970 http
-rw-r--r--  4 kunweiz kunweiz  5801 Jan  1  1970 libproxy.py
drwxr-xr-x  1 kunweiz kunweiz    92 Jan  1  1970 lz4
drwxr-xr-x  1 kunweiz kunweiz   132 Jan  1  1970 mdns
drwxr-xr-x  1 kunweiz kunweiz    70 Jan  1  1970 mmap
-rw-r--r--  4 kunweiz kunweiz 21467 Jan  1  1970 net_util.py
-rw-r--r--  4 kunweiz kunweiz  5630 Jan  1  1970 packet_encoding.py
-rw-r--r--  4 kunweiz kunweiz  3813 Jan  1  1970 packet_type.py
drwxr-xr-x  1 kunweiz kunweiz  110 Jan  1  1970 protocol
drwxr-xr-x  1 kunweiz kunweiz  102 Jan  1  1970 qrcode
drwxr-xr-x  1 kunweiz kunweiz   220 Jan  1  1970 quic
-rw-r--r--  1 kunweiz kunweiz    86 Jan  1  1970 rencodeplus
-rw-r--r--  1 kunweiz kunweiz    94 Jan  1  1970 rfb
-rw-r--r--  4 kunweiz kunweiz 43487 Jan  1  1970 socket_util.py
drwxr-xr-x  1 kunweiz kunweiz   112 Jan  1  1970 ssh
-rw-r--r--  4 kunweiz kunweiz 16342 Jan  1  1970 subprocess_wrapper.py
drwxr-xr-x  1 kunweiz kunweiz    92 Jan  1  1970 tls
-rw-r--r--  4 kunweiz kunweiz 10279 Jan  1  1970 upnp.py
drwxr-xr-x  1 kunweiz kunweiz    96 Jan  1  1970 vsock
-rw-r--r--  1 kunweiz kunweiz   186 Jan  1  1970 websockets
=== mmap 相关 ===
drwxr-xr-x 1 kunweiz kunweiz 70 Jan  1  1970 /app/share/python-deps/xpra/net/mmap
=== mmap 目录内容 ===
total 36
drwxr-xr-x 1 kunweiz kunweiz    70 Jan  1  1970 .
drwxr-xr-x 1 kunweiz kunweiz   618 Jan  1  1970 ..
-rw-r--r-- 16 kunweiz kunweiz   213 Jan  1  1970 __init__.py
-rw-r--r--  4 kunweiz kunweiz  2465 Jan  1  1970 common.py
-rw-r--r--  4 kunweiz kunweiz 20445 Jan  1  1970 io.py
-rw-r--r--  4 kunweiz kunweiz  4900 Jan  1  1970 objects.py
=== 文件类型 ===
/app/share/python-deps/xpra/net/mmap.py -> missing
/app/share/python-deps/xpra/net/mmap/__init__.py -> exists
/app/share/python-deps/xpra/net/mmap/common.py -> exists
=== 版本 ===
__version_info__ = (6, 5, 5)
__version__ = "6.5.5"
```

**判定：镜像是"包"，不是"模块"。** `mmap.py` 不存在，`mmap/` 有 `__init__.py`。

关于硬链接计数：`__init__.py` 显示 16、`common.py` 显示 4。那个 16 不是异常，
是同一份 213 字节版权头 `__init__.py` 被多个包共用 inode。内容与 deb 成员一致，
不影响 import。

### 1.2 沙盒内真实 import 探针（venv 的 CPython 3.14，镜像优先）

```
--- python:  Python 3.14.10
xpra_file= /app/share/python-deps/xpra/__init__.py
net_file= /app/share/python-deps/xpra/net/__init__.py
mmap= <module 'xpra.net.mmap' from '/app/share/python-deps/xpra/net/mmap/__init__.py'>
      file= /app/share/python-deps/xpra/net/mmap/__init__.py
      path= ['/app/share/python-deps/xpra/net/mmap']
MMAP_OK
```

**判定：`xpra.net.mmap` 有 `__path__`，`xpra.net.mmap.common` 可导入。错误在当前安装树里不可复现。**

这是本报告最重要的一条：它不是从日志推断，而是把与服务端相同的解释器、相同的 `PYTHONPATH`
放进沙盒里直接执行的结果。模块顶层导入 `xpra.net.mmap.common` 的共有四处：
`xpra/server/encoder/server.py:20`、`xpra/server/window/compress.py:24`、
`xpra/server/source/mmap.py:14`、`xpra/client/base/encode.py:14`，走的正是这条链。

### 1.3 venv 与镜像逐文件一致

```
=== venv 刷新时间证据 ===
mtime=2026-11-18 00:50:07  site-packages
mtime=2026-11-18 00:50:07  site-packages/.a0-python-deps
ctime=2026-11-18 00:50:07  site-packages/xpra
ctime=2026-11-18 00:50:07  site-packages/xpra/net/mmap
--- stamp 内容（venv） ---
315e2a61fcaa940b491fc7beab6cc6e9b391c1e97508957d259cdf0211e13a0d
--- 镜像 stamp ---
315e2a61fcaa940b491fc7beab6cc6e9b391c1e97508957d259cdf0211e13a0d
=== venv 与镜像 xpra 逐文件比对 ===
文件清单完全一致（662 个文件）
=== xpra 组合哈希对比 ===
镜像: 7faa5513de5b80fbc4ae2f2de41c6bf8a1e2268254d2be652b5e51fa8be26f4a
venv: 7faa5513de5b80fbc4ae2f2de41c6bf8a1e2268254d2be652b5e51fa8be26f4a
```

**判定：venv 的 xpra 不是"另一份可能过期的副本"，它与镜像是同一份内容。**
launcher 的 `install_extension_modules()`（`flatpak/agent-zero.sh:194-207`）
在 `00:50:07` 执行了 `rm -rf` + `cp -a`，并以同一个 stamp 收尾。

### 1.4 日志不能作为"已修复"的独立证据

`~/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/plugins/_desktop/profiles/agent-zero-desktop/xpra-stderr.log`
（2070 B，`2026-11-18 00:54:16~17`）结尾：

```
created tcp socket '127.0.0.1:14500'
serving html content from '/app/share/xpra/www'
wrote pid 24 to '/run/user/1000/xpra/0/server.pid'
xpra X11 shadow server version 6.5.5-r0
 cpython 3.14 x86_64
X11 display :0 size 3840x2160
capture using XImageCapture
xpra is ready.
```

`grep -n 'not a package\|mmap'` 对该日志**返回空**。但这**不能**证明错误已消失，因为
`flatpak/a0flatpak/desktop.py:354` 每次 spawn 桌面都用
`open(..., "wb")` 截断同一个文件：

```python
shadow_stderr = open(session.profile_dir / "xpra-stderr.log", "wb")
```

上一轮的 traceback 会被下一次启动抹掉。所以本报告的判定改走两条不依赖日志的路：
1.2 的直接 import，和 2.1 的静态构建预演。

另有一条**反向**观察值得记录：该日志里没有 `New tcp connection received`
（`xpra/net/bytestreams.py:695` 对每条新连接都会记一行），也没有任何 HTTP 请求行
（`xpra/net/http/handler.py:322` 的 `log_message` 会记）。这说明 `00:54` 那一轮
**没有任何浏览器到达过 14500**，
与"浏览器停在 connection error 页、canvas 数为 0"是自洽的。详见附录。

---

## 2 取证：五个 deb 里各自的 `xpra/net/mmap*` 成员

对 `build/downloads/<sha256>/xpra-*.deb` 逐个 `ar p <deb> data.tar.xz | tar -tvJf - | grep 'xpra/net/mmap'`：

| deb | 版本 | `xpra/net/mmap/` 目录 | `xpra/net/mmap.py` | mmap 成员清单 |
|---|---|---|---|---|
| `xpra-common` | `6.5.5-r0-1` | **有** | **无** | `mmap/`、`mmap/__init__.py` (213 B)、`mmap/common.py` (2465 B)、`mmap/io.py` (20445 B)、`mmap/objects.py` (4900 B) |
| `xpra-server` | `6.5.5-r0-1` | 无 | 无 | 无 |
| `xpra-client` | `6.5.5-r0-1` | 无 | 无 | 无 |
| `xpra-x11` | `6.5.5-r0-1` | 无 | 无 | 无 |
| `xpra-html5` | `21-r1-1` | 无 | 无 | 无 |

`xpra-common` 的原始成员行：

```
drwxr-xr-x root/root         0 2026-10-11 20:30 ./usr/lib/python3/dist-packages/xpra/net/mmap/
-rw-r--r-- root/root       213 2026-07-18 15:33 ./usr/lib/python3/dist-packages/xpra/net/mmap/__init__.py
-rw-r--r-- root/root      2465 2026-10-11 20:30 ./usr/lib/python3/dist-packages/xpra/net/mmap/common.py
-rw-r--r-- root/root     20445 2026-10-11 20:30 ./usr/lib/python3/dist-packages/xpra/net/mmap/io.py
-rw-r--r-- root/root      4900 2026-10-11 20:30 ./usr/lib/python3/dist-packages/xpra/net/mmap/objects.py
```

**判定：没有任何 deb 携带 `xpra/net/mmap.py`。`cp -a` 不可能把单文件装进镜像。**

### 2.0 上游布局的年代（订正一处常见说法）

下载上游 tag 源码复核（`https://github.com/Xpra-org/xpra/archive/refs/tags/v<版本>.tar.gz`）：

```
v6.4.4 -> PACKAGE (mmap/__init__.py)
v6.3.6 -> SINGLE FILE (mmap.py)
```

所以"旧布局"指 **6.3 及更早**，不是 6.4。这一条已用于订正 manifest 注释。

### 2.1 静态预演一次构建（不跑 flatpak-builder）

按 manifest 的顺序把五个 deb 依次 `sh flatpak/unpack-deb.sh` 到**同一个** `unpacked` 目录
（`flatpak/unpack-deb.sh` 只做 `ar p … | tar -x`，无 strip、无路径改写），
再用 venv 的 CPython 3.14 对结果做 import：

```
=== 模拟结果：xpra/net/mmap* ===
drwxr-xr-x .../unpacked/usr/lib/python3/dist-packages/xpra/net/mmap
=== 断言 ===
xpra/net/mmap.py -> missing
xpra/net/mmap/__init__.py -> EXISTS
xpra/net/mmap/common.py -> EXISTS
=== import ===
xpra:   .../unpacked/usr/lib/python3/dist-packages/xpra/__init__.py
mmap:   .../xpra/net/mmap/__init__.py  path=['.../xpra/net/mmap']
common: .../xpra/net/mmap/common.py
MMAP_OK
```

**重建后的镜像必然是"包"。这一点只依赖 deb 内容与 `cp -a`，不依赖运行时状态。**

---

## 3 根因判定

**一句话：根因在 venv 的旧布局残留，不在镜像。** `xpra` 从 `/app/share/python-deps`
被复制进 venv；当镜像从 6.3（`mmap.py` 单文件）升到 6.5.5（`mmap/` 包）时，
若采用"只增不删"的合并复制，venv 里旧的 `mmap.py` 会活下来。此时若 `mmap/` 目录
**缺 `__init__.py`**，`FileFinder` 就选中单文件，`xpra.net.mmap` 变成没有 `__path__`
的普通模块，之后服务端顶层导入 `xpra.net.mmap.common` 即报
`No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package`。

**证据链：**

1. 镜像与五个 deb：`mmap` 只有目录形式，`mmap.py` 缺失（第 1、2 节）。
2. 沙盒 import：`MMAP_OK`，`__path__` 存在（第 1.2 节）。
3. venv 与镜像 xpra 内容全等（662 文件、同组合哈希，第 1.3 节）。
4. 静态构建预演：`MMAP_OK`（第 2.1 节）。
5. **`FileFinder` 实测**，三种布局，用 venv 的 CPython 3.14：

   | 情形 | 布局 | 结果 |
   |---|---|---|
   | A | `mm.py` + `mm/__init__.py` | **包胜出**，`import pkg.mm.sub` 成功 |
   | B | `mm.py` + `mm/`（**无** `__init__.py`） | **单文件胜出**，`ModuleNotFoundError: No module named 'pkg.mm.sub'; 'pkg.mm' is not a package` |
   | C | 只有 `mm/__init__.py` | 正常 |

   A 的实测结果**推翻了"单文件与目录包并存必然产生 not-a-package"这一前提**：
   只要 `__init__.py` 在，包就优先。B 才是这条错误的唯一触发条件。
   `__init__.py` 是两种布局之间的保险丝。

6. 同一结论在真实旧树上复核（上游 6.3.6 完整源码 + 6.5.5 venv 解释器）：

   | 树 | 结果 |
   |---|---|
   | 6.3.6 原样（`net/mmap.py`） | `ModuleNotFoundError: No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package`（生产日志逐字） |
   | 6.3.6 但把 `net/mmap.py` 换成 `net/mmap/` 包 | `MMAP_OK` |
   | 6.3.6 只删 `net/mmap.py`、不补包 | `ModuleNotFoundError: No module named 'xpra.net.mmap'` |
   | 6.5.5 树 + 额外 `net/mmap.py`（包保留） | `MMAP_OK`（包优先） |

   第三行说明：**修复动作是"整 slot 替换"，不是"删一个文件"**。launcher 的
   `rm -rf "$site/xpra" && cp -a "$PY_DEPS"/. "$site"/` 正是整树替换，方向正确。

**因此 `flatpak/agent-zero.sh:194-207` 已经是正确修复，不需要改 `a0flatpak/*.py`。**
它在 `00:50:07` 生效：stamp 两侧一致，venv 与镜像 662 文件哈希全等。

**遗留的真实风险**（本轮不扩大范围，仅记录）：该函数只清 `maxdepth 2` 的 `__pycache__`；
`gi/repository/__pycache__` 这类第 3 层不在范围内。构建把 mtime 归零后，
大小相同的新旧 `.py` 会让旧 `.pyc` 仍然通过校验。`xpra` 整树被 `rm -rf` 覆盖，不受影响。

---

## 4 Manifest 改动

只改 `flatpak/org.agentzero.AgentZero.yml` 的 `xpra` 模块，加两条构建期断言。
不删文件（镜像里没有可删的东西），补断言（把 B 情形的两个必要条件钉死在构建里）。

### before

```yaml
      - install -d /app/share/python-deps
      - cp -a unpacked/usr/lib/python3/dist-packages/xpra /app/share/python-deps/
      - cp -a unpacked/usr/share/xpra /app/share/xpra
```

### after

```yaml
      - install -d /app/share/python-deps
      - cp -a unpacked/usr/lib/python3/dist-packages/xpra /app/share/python-deps/
      # xpra.net.mmap is a package from 6.5.5 on: xpra-common carries
      # mmap/__init__.py, common.py, io.py and objects.py. The encoder imports
      # xpra.net.mmap.common at module level (server/encoder/server.py), so the
      # package has to stay importable or the server dies on start.
      #
      # A single-file xpra/net/mmap.py in the same slot - the layout 6.3 and
      # earlier used - wins over a directory without __init__.py, and every
      # later import then fails with "No module named 'xpra.net.mmap.common';
      # 'xpra.net.mmap' is not a package". A directory with __init__.py wins
      # over the single file, so the marker is what keeps the two layouts
      # apart. Assert both halves here instead of discovering them at runtime.
      - test -f /app/share/python-deps/xpra/net/mmap/__init__.py
      - test ! -e /app/share/python-deps/xpra/net/mmap.py
      - cp -a unpacked/usr/share/xpra /app/share/xpra
```

### 断言行为实测

| 目标树 | `test -f .../mmap/__init__.py` | `test ! -e .../mmap.py` | 构建结果 |
|---|---|---|---|
| 模拟构建树（五个 deb 解包） | 0 | 0 | **通过** |
| `/app`（当前安装） | 0 | 0 | **通过** |
| A：并存单文件 + 有 marker | 0 | 1 | **失败**（拒绝残留） |
| B：缺 marker + 单文件 | 1 | 1 | **失败**（这就是原错误的布局） |

`yaml.safe_load` 解析通过；`xpra` 模块 `build-commands` 现为 15 条，
两条断言位于第 4、5 位（`cp -a xpra` 之后，`cp -a /usr/share/xpra` 之前）。

---

## 5 验证结果

| 验证项 | 状态 |
|---|---|
| 沙盒内 `import xpra.net.mmap.common` → `MMAP_OK` | **已通过** |
| 镜像 `/app` 的 mmap 布局为包、无单文件 | **已通过** |
| 五个 deb 无 `mmap.py`，`xpra-common` 只带目录 | **已通过** |
| 静态重建预演（五 deb 解包 + CPython 3.14 import） | **已通过** |
| venv 与镜像 xpra 逐文件一致（662 文件、同组合哈希） | **已通过** |
| 真实旧树复现/修复对照（6.3.6 ↔ 6.5.5） | **已通过** |
| manifest 两条断言在正确树上通过、在两种坏树上失败 | **已通过** |
| `flatpak-builder` 重建 | **待 build-main** |
| 重建后 `xpra-stderr.log` 无 `is not a package` | **待重建**（且必须与"有无 `New tcp connection received`"一起读，见 1.4） |
| 桌面 CDP `canvases > 0`、截图有 XFCE 壁纸/面板/图标 | **待重建 + 见附录** |

当前 14500 端口已无监听（`curl` 返回 `000`），5080 仍健康（200）。
桌面会话在 `00:54:17` 之后结束，因此"桌面能否渲染"无法在本轮观测。

### 重建后预期结果

`mmap` 报错不会再出现：镜像与 venv 都会是 `mmap/` 包，`import xpra.net.mmap.common` 返回 0。
若重建后这条错误**仍然出现**，那么它一定不再来自镜像，只能来自 venv 或环境拼接（见第 6 节）。

---

## 6 如果重建后仍失败，下一步该查什么

1. **确认运行时实际命中的 xpra 到底在哪，而不是假设。**
   ```
   flatpak run --user --command=sh org.agentzero.AgentZero -c '
   V=$HOME/data/agent-zero/venv
   PYTHONPATH=/app/share/python-deps LD_LIBRARY_PATH=/app/lib/gi "$V/bin/python" -c "
   import xpra, xpra.net.mmap as m
   print(\"xpra=\", xpra.__file__); print(\"mmap=\", m.__file__); print(\"path=\", getattr(m,\"__path__\",None))"'
   ```
   若 `mmap.__path__` 为 `None`，说明命中的树是旧布局。再对比两个 stamp：
   `cat "$V/../lib/python3.14/site-packages/.a0-python-deps"` 与
   `cat /app/share/python-deps/.a0-python-deps`。两者不同却未刷新，就是
   `sysconfig.get_path("purelib")` 指向的目录与 xpra 实际所在目录不一致。

2. **确认两个必要条件同时成立，而不只看其一。**
   ```
   S=<venv purelib>; ls -la "$S/xpra/net/mmap/"; ls -l "$S/xpra/net/mmap.py" 2>&1
   ```
   必须：`mmap/__init__.py` 在，`mmap.py` 不在。只满足后者会得到
   `No module named 'xpra.net.mmap'`（另一种故障），只满足前者仍可能被未来的
   布局变更打回。构建期断言已覆盖这两条，运行时再查一次是为了确认 venv 而不是镜像。

3. **不要把 `xpra-stderr.log` 当作历史证据。**
   `flatpak/a0flatpak/desktop.py:354` 每次 spawn 都用 `open(..., "wb")` 截断它。
   要判断"服务端有没有被客户端连上"，看同一次运行里有没有
   `New tcp connection received`（`xpra/net/bytestreams.py:695`）和 HTTP 请求行
   （`xpra/net/http/handler.py:322` 的 `log_message`）。若两者都没有，那么
   "connection error"页面与 mmap 无关，是浏览器停在了一张不会自动重连的静态页
   （见附录）。

---

## 附录：桌面不渲染的独立问题（本轮未修改）

`mmap` 已不成立，但 `canvases=0` / Xpra connection error 页仍未解释。
独立排查得到的结论按可能性排序：

1. **页面不会自愈。** Xpra 的 `www/index.html:935` 在连接关闭且非表单提交时执行
   `window.location = "connect.html"`（无参数、不重连）。`connect.html` 只显示
   disconnect 理由和 server/port 输入框（第 49、51 行），**不自动连接**：
   唯一入口是第 131 行的 `Connect` 按钮（`onclick="doConnect()"`），而
   `doConnect()`（第 492-505 行）的目标是 `./index.html` 加 `submit=true`。
   所以只要服务端曾在一个 hello 阶段断开过，浏览器就停在这一帧，
   直到有人手工点一次 `Connect`，即使服务端之后已经健康。
2. **`00:54` 那一轮没有任何浏览器到达 14500。** 日志里缺少
   `New tcp connection received` 与 HTTP 请求行，且 14500 现在已无监听。
   这解释了"静态资源 200 但 canvas=0"：资源是上一轮或直连探测拿到的，
   页面本身没有重新发起连接。
3. **服务端曾主动发 `CONNECTION_ERROR`。** 该字符串
   （`xpra/net/constants.py:106`）由
   `xpra/server/core.py:1469` 的 `disconnect_client(..., CONNECTION_ERROR,
   "error accepting new connection")` 发出，只可能来自 hello 阶段异常，
   不是端口错误或静态资源 404。历史上被日志证实的唯一此类异常就是
   `xpra.net.mmap.common` 导入失败——而它现在已不可复现。

因此，重建并重启后，正确的一次性验收顺序是：

```
# 1. 服务端起来
ss -ltnp | grep ':14500'
# 2. 真的接受连接（这一行是关键，不是 "xpra is ready."）
grep -c 'New tcp connection received' <profile>/xpra-stderr.log
# 3. 浏览器那一帧来自哪里
#    CDP Runtime.evaluate: location.origin, location.pathname, sessionStorage.getItem("disconnect")
#    若停在 connect.html，手工 location.href='/index.html' 或刷新，再看 canvases
```

若第 2 步为 0，问题在连接建立，不在 python 导入；
若第 2 步 >0 而 canvas 仍为 0，问题在 hello/编码，读同一次运行里的
`hello`、`allowed encodings`、`pillow encodings` 三组行。

---

## 7 桌面 URL 的 submit 参数

这一节回答"要不要给桌面 URL 加 `?submit=true`"，并给出可直接粘贴的补丁草案。
**结论先说：不该加，加了也不改变行为。** `submit` 的缺省值就是 `true`；
真正让浏览器停在连接页的是"打开了一个裸的 `14500/connect.html`"，不是缺参数。

### 7.1 谁生成桌面 URL

**生成点**：`helpers/virtual_desktop.py:121-153` 的 `session_url()`。
常量 `SESSION_PATH = "/desktop/session"`（同文件第 26 行）。

```python
# helpers/virtual_desktop.py:131-153（当前实现）
quoted_token = quote(str(token), safe="")
base_path = f"{SESSION_PATH}/{quoted_token}/"
options = {
    "path": base_path,
    "title": title,
    "quality": str(...), "speed": str(...),
    "sharing": "true",
    "clipboard": "true", "clipboard_direction": "both",
    "clipboard_poll": "true", "clipboard_preferred_format": "text/plain",
    "printing": ..., "file_transfer": ...,
    "sound": "false", "offscreen": "true",
    "floating_menu": "false", "xpramenu": "false",
}
if encoding:
    options["encoding"] = str(encoding)
return f"{base_path}index.html?{urlencode(options)}"
```

当前拼法共 15 个 query 参数，**没有 `submit`，没有 `password`，没有 `server`，没有 `port`**。

**全部调用点**（`grep -rn session_url` 只有这三处，外加一处测试断言）：

| 位置 | 用法 |
|---|---|
| `helpers/virtual_desktop.py:121` | 定义 |
| `plugins/_desktop/helpers/desktop_session.py:1824` | `_xpra_url(token)` → `session_url(token, title="Desktop")`；被 `DesktopSession(url=...)` 在 627、680 行使用 |
| `plugins/_browser/helpers/interactive_view.py:171` | `session_url(token, title="Browser", encoding="", quality=90, speed=90, file_transfer=False, printing=False)` |

**反代还有第二条拼装点，容易漏**：`helpers/virtual_desktop_routes.py:291-294`
的 `session_index_url()` 返回 `{mount_path}/session/{token}/index.html?path=<quoted>`，
只有 `path` 一个参数。它是 `/desktop/session/<token>/` 这个裸路径的 302 目标
（`virtual_desktop_routes.py:106-108`），与 `session_url()` **不是同一份实现**。

**前端消费点**：`plugins/_desktop/webui/desktop-store.js:1090-1103`
`officialOfficeUrl()` 读 `tab.desktop.url`，用 `new URL(url, window.location.href)`
解析后补 `offscreen`/`clipboard_poll`，再返回同源相对路径。所以 UI 走的是完整参数版。

### 7.2 `submit` 与 `password` 的确切语义

**`submit`**

```js
// /app/share/xpra/www/index.html:659
var submit = getboolparam("submit", true);
// index.html:295-298
var getboolparam = function(prop, default_value) {
  var v = getparam(prop);
  return Utilities.stristrue(v, default_value);
};
// /app/share/xpra/www/js/Utilities.js
stristrue(v, default_value) {
  return v ? ["true","on","1","yes","enabled"].includes(String(v).toLowerCase())
           : default_value
}
```

| URL 写法 | `submit` 实际值 |
|---|---|
| 不带 `submit` | **`true`**（走 `default_value`） |
| `?submit=true` / `1` / `on` / `yes` / `enabled` | `true` |
| `?submit=false` / `0` / `no` / `off` | `false` |

只有 `submit === false` 才会在连接关闭时执行静默跳转（`index.html:933-936`）：

```js
client.callback_close = function(reason) {
  if (!submit) {
    window.location = "connect.html";
    return;
  }
  ...
```

**所以 `?submit=true` 是冗余的。** `connect.html` 自己的 `doConnect()`
（第 492-505 行）之所以显式加 `submit=true`，是为了在
`default-settings.txt` 写了 `submit=false` 时能覆盖它——而本镜像的
`default-settings.txt`（17 行、283 B）只有 `blocked-hosts`、`min-quality`、
`min-speed` 三行有效配置，**没有 `submit`**。

**`password`**

```js
// index.html:638-647
var passwords = [];
for (var i = 0; i < 10; i++) {
  var password = getparam("password" + i) || getparam("token" + i) || null;
  if (!password && i == 0) {
    password = getparam("password") || getparam("token") || null;
  }
  if (password) { passwords.push(password); } else { break; }
}
// index.html:910-911
if (passwords) { client.passwords = passwords; }
```

- 参数名：`password` / `token`，也支持 `password0..9`、`token0..9`。
- 用 `getparam`（`index.html:276-287`）读取，**不经过 `ALLOWED_CHARS` 过滤**；
  带 `+` `/` `=` 的 base64 密钥不会被截断。（`getstrparam` 才有过滤。）
- `connect.html:519-523` 只在 `is_password_safe()` 为真时才把密码拼进
  `xpra+ws://user:pass@host:port/` URI；否则禁用密码输入框
  （`connect.html:802-815`）。
- `isSafeHost`（`www/js/Utilities.js`）只认 `localhost`、`127.0.0.1`、`::1`。
  本场景正是 `127.0.0.1`，所以 `is_password_safe()` 返回真，密码框可用。

**`host` / `port` / `path` 的缺省**

```js
var server = getstrparam("server") || window.location.hostname;
var port   = getintparam("port")    || window.location.port;
var path   = getstrparam("path", ALLOWED_CHARS + "/") || window.location.pathname;
```

走 5080 反代时 `port` 自动取 5080、`path` 取 `session_url` 给的
`/desktop/session/<token>/`，这是设计意图；直连 14500 时两者取 14500 与 `/`。
**都不是必填参数。**

### 7.3 最合适的注入点

`flatpak/a0flatpak/desktop.py` 已经有一套成熟的补丁模式：模块级函数
`_patch_*()` + 目标对象上的 `_a0flatpak_*_patched` 幂等标记 + 在 `apply()`
（第 198-209 行）里按固定顺序调用。新增一个同形函数即可，不需要碰上游。

**推荐挂在 `virtual_desktop.session_url`**，理由：

1. 它是两个调用点（`desktop_session._xpra_url` 与 `interactive_view`）的**唯一出口**，
   一处替换同时覆盖"用户从 UI 打开 Desktop"和 `systemd/a0-desktop-start`
   的 `ensure_system_desktop()` 两条路径（后者最终也走 `_xpra_url`）。
2. 它返回的是相对路径，`desktop-store.js` 的 `new URL(url, location.href)` 会正确解析。
3. 不改 `desktop_session` 的 `public()` 结构，前端契约不变。

**不要**patch `virtual_desktop_routes.session_index_url`：那条路径只用于
`/desktop/session/<token>/` 的 302 兜底，参数少但可用（`port` 取反代端口）。

### 7.4 安全判断与推荐

**现状**：`A0_AUTH_KEY` **未设置**。证据是运行进程的环境与 flatpak override
都是空的：

```
$ tr '\0' '\n' < /proc/1697965/environ | grep A0_AUTH_KEY
（无输出）
$ flatpak override --user --show
（无输出）
```

因此 `flatpak/a0flatpak/desktop.py:273-276` 的 `auth_key` 为空、`xpra_auth` 为空，
**当前 xpra 命令里没有 `--tcp-auth=env`**。真实进程命令行（pid 1702461，
2026-11-18 01:01:55）已核实：

```
venv/bin/python /app/bin/xpra shadow :0 --daemon=no --mdns=no --mmap=no --html=on
  --tray=no --system-tray=no --notifications=no --clipboard=yes --clipboard-direction=both
  --file-transfer=yes --open-files=no --open-url=no --printing=yes --audio=no --speaker=off
  --microphone=off --quality=85 --speed=80 --encoding=png --bind-tcp=127.0.0.1:14500
  --resize-display=yes --log-dir=... --log-file=xpra.log
```

上游 `_xpra_shadow_command`（`desktop_session.py:1851-1879`）本身**不带**
`--tcp-auth`。所以只要 `A0_AUTH_KEY` 为空，链路就是无鉴权的。

**判断**：把 `A0_AUTH_KEY` 放进 URL query 会进入浏览器历史、截图、
以及任何反向代理的访问日志。本场景虽然是 `127.0.0.1` 回环，
但"默认把密钥写进 URL"是不必要的风险，且与 5080 本身的暴露面无关。

**推荐：默认不传 `password`，只保留显式 opt-in。** 若将来启用 `A0_AUTH_KEY`，
首选仍是让用户在 `connect.html` 输入一次（`isSafeHost` 已允许 127.0.0.1，
密码框可用，不需要勾 `insecure`）；确实要免点击时，再打开环境变量开关。

### 7.5 补丁草案（可直接粘贴，本轮未改仓库）

改动文件：`flatpak/a0flatpak/desktop.py`。两处：顶部 import 一行，
新增一个函数并在 `apply()` 里调用一次。

**（1）顶部 import 区（第 21-28 行）追加一行：**

```python
from urllib.parse import quote
```

**（2）在 `_patch_launcher_setup()` 之后（`_patch_desktop_status()` 之前或之后均可）新增：**

```python
def _patch_session_url() -> None:
    """Optionally carry the local auth key inside desktop URLs.

    ``--tcp-auth=env`` makes Xpra challenge the HTML5 client for a password.
    The connect form accepts one (``isSafeHost`` covers 127.0.0.1), but the
    desktop tab then waits for a click before anything renders. Passing the key
    as ``?password=`` removes that click - and also writes the key into browser
    history, screenshots and any proxy log. So it stays off unless the operator
    sets ``A0_DESKTOP_URL_PASSWORD=1``.

    The parameter name is ``password`` (not ``token``): ``index.html:640``
    reads ``password0..9``/``token0..9`` and falls back to the unsuffixed
    ``password``/``token`` at ``i == 0``, and ``getparam`` does not strip
    characters, so a base64 key survives intact.
    """
    from helpers import virtual_desktop

    if getattr(virtual_desktop, "_a0flatpak_url_patched", False):
        return

    original = virtual_desktop.session_url

    def session_url(token: str, **kwargs: Any) -> str:
        url = original(token, **kwargs)
        if os.environ.get("A0_DESKTOP_URL_PASSWORD", "").strip().lower() not in {
            "1",
            "true",
            "yes",
        }:
            return url
        key = os.environ.get("A0_AUTH_KEY", "").strip()
        if not key:
            return url
        separator = "&" if "?" in url else "?"
        return f"{url}{separator}password={quote(key, safe='')}"

    virtual_desktop.session_url = session_url
    virtual_desktop._a0flatpak_url_patched = True
```

**（3）在 `apply()` 的补丁调用列表里加一行：**

```python
    _patch_status_checks()
    _patch_desktop_status()
    _patch_launcher_setup()
    _patch_session_url()
```

**不要加 `submit=true`。** 缺省即真（7.2 的表格），加了只是噪声，
而且会让"用 `default-settings.txt` 关掉表单提交"这条上游能力失效。

### 7.6 需要重建吗

**需要。** 改的是 `flatpak/a0flatpak/desktop.py`，它被打包进主包
`/app/share/agent-zero/flatpak`（`agent-zero.sh:265` 把该目录加进 `PYTHONPATH`，
`268-269` 用 `import a0flatpak; a0flatpak.apply()` 启动），属于主包内容。

但**这个补丁默认关闭**（没有 `A0_DESKTOP_URL_PASSWORD=1` 时行为与现在完全相同），
所以不重建也不影响当前验收；重建只在真的启用 `A0_AUTH_KEY` 时才必要。

不需要改 manifest，也不需要新的 flatpak 权限。

### 7.7 验证方法

**A. 验证"UI 路径本来就对"（不需要重建）**

```sh
curl -s -m5 'http://127.0.0.1:5080/api/plugins/_desktop/desktop_session' \
  -H 'Content-Type: application/json' \
  -d '{"action":"desktop"}' | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(d["desktop"]["url"])'
```

期望输出形如：

```
/desktop/session/agent-zero-desktop/index.html?path=%2Fdesktop%2Fsession%2Fagent-zero-desktop%2F&title=Desktop&quality=85&speed=80&sharing=true&clipboard=true&clipboard_direction=both&clipboard_poll=true&clipboard_preferred_format=text%2Fplain&printing=true&file_transfer=true&sound=false&offscreen=true&floating_menu=false&xpramenu=false&encoding=jpeg
```

在浏览器里打开 `http://127.0.0.1:5080` + 该相对路径，期望 `canvases > 0`。

**B. 验证"裸 connect 页确实是死路"（已实测）**

```sh
curl -s -m3 http://127.0.0.1:9223/json/list | grep -E '"url"|"title"'
```

实测输出（2026-11-18 01:0x）：

```
"title": "Xpra HTML5 Client"
"url":   "http://127.0.0.1:14500/connect.html"
```

CDP `Runtime.evaluate` 读到的页面状态：

```json
{
  "href": "http://127.0.0.1:14500/connect.html",
  "search": "",
  "canvases": 0,
  "bodyText": "Xpra HTML5 Client\nVersion 21\n\nYou were disconnected for the following reason:\n\nconnection errorerror accepting new connection\n...",
  "storage": {},
  "fields": {"server": {"value": "127.0.0.1"}, "port": {"value": "14500"},
             "password": {"value": ""}, "main_action_button": {"text": "Connect"}}
}
```

`search` 为空、`sessionStorage` 为空、唯一的连接入口是 `Connect` 按钮——
**这个页面不会自己连**，所以 `canvases` 永远是 0。这不是缺 `submit`，
而是从未发生过一次由 `index.html` 发起的连接。

**C. 有 key 时的自动登录（重建后、且显式开启时）**

```sh
flatpak override --user --env=A0_DESKTOP_URL_PASSWORD=1 org.agentzero.AgentZero
# 重启 Web UI 后取 URL，应看到末尾多出 &password=<key>
# 打开后应直接进入桌面，不出现登录框
```

检查日志里不应出现 `AUTHENTICATION_FAILURE`，CDP 里
`document.getElementById("password-box").offsetParent === null`（登录框未显示）。

**D. 回退**：去掉 `A0_DESKTOP_URL_PASSWORD` 即恢复原行为。

### 7.8 这一节的结论

1. **不要加 `?submit=true`**：缺省即 `true`，加了不改变任何行为。
2. **当前没有鉴权**（`A0_AUTH_KEY` 未设置，命令里无 `--tcp-auth=env`），
   所以 `<password>` 也不参与当前失败。
3. **真正的症状是浏览器停在裸的 `14500/connect.html`**：无参数、不自动连接、
   显示的理由来自更早一次 hello 阶段失败。
4. **服务端当时是健康的**：同一时段 14500 返回 200、WS 带
   `Sec-WebSocket-Protocol: binary` 得到 `101`、日志有
   `New tcp connection received`、无任何 error/traceback。
5. 因此本节补丁是**健壮性选项**（鉴权可用时免一次点击），
   不是当前 `canvases=0` 的修复；验收脚本应改用 7.7-A 的完整 URL。

---

## 7.9 PYTHONPATH 与 PYTHONHOME 的推导

**状态：待另一个人用相同 env 复现后确认。** 本节区分"已实测"与"推断"，
并记录一个在当前镜像上**无法复现**的前提问题。

### 7.9.1 `XPRA_START_ENV` 全文

`helpers/virtual_desktop.py:30-33`：

```python
XPRA_START_ENV = {
    "XPRA_SYSTEM_DBUS_TIMEOUT": "1",
    "XPRA_SYSTEM_CUPS_TIMEOUT": "1",
}
```

就这两个键。**没有 `PYTHONPATH`、没有 `PYTHONHOME`、没有 `LD_LIBRARY_PATH`。**
该文件里 `grep 'PYTHONPATH\|PYTHONHOME\|LD_LIBRARY_PATH'` 返回空。

### 7.9.2 `env` 从哪来：`_session_env` 是 `**os.environ`

关键在 `desktop.py:257` 的第二项：

```python
env = {**virtual_desktop.XPRA_START_ENV, **self._display_env(session)}
```

`_display_env`（`desktop_session.py:1576-1585`）→ `_session_env`
（`desktop_session.py:1557-1574`）**整份继承进程环境**：

```python
def _session_env(self, session: DesktopSession) -> dict[str, str]:
    env = {
        **os.environ,                      # <- 全部继承
        "HOME": str(session.profile_dir),
        "LANG": os.environ.get("LANG") or "C.UTF-8",
        "TZ": session.timezone or ...,
    }
```

所以 `desktop.py` 里 `existing = env.get("PYTHONPATH", "")` 取到的**不是空串**，
而是 launcher 与 flatpak 叠加后的值。实测（读 `/proc/<xpra pid>/environ`）：

```
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps
PYTHONHOME=
LD_LIBRARY_PATH=/app/lib/gi:/app/lib/xvfb
```

来源可逐项对上：

| 片段 | 来源 |
|---|---|
| `/app/share/agent-zero` | Web UI 进程自身的 `PYTHONPATH`（`cd /app/share/agent-zero` 启动） |
| `/app/share/agent-zero/flatpak` | `flatpak/agent-zero.sh:265` `export PYTHONPATH="$APP_ROOT/flatpak${PYTHONPATH:+:$PYTHONPATH}"` |
| `/app/share/python-deps` | `flatpak/agent-zero.sh:177` `export PYTHONPATH="$PY_DEPS${PYTHONPATH:+:$PYTHONPATH}"`，在 265 之前执行 |

**因此 `desktop.py:262-264` 的 `insert(0)` 是空操作**：

```python
existing = env.get("PYTHONPATH", "")           # 已有三段，含 python-deps
parts = [p for p in existing.split(":") if p]
for extra in (BUNDLED_PY_DEPS,):
    if extra not in parts:                     # 已存在 -> 不插入
        parts.insert(0, extra)
env["PYTHONPATH"] = ":".join(parts)            # 顺序保持 agent-zero:flatpak:python-deps
```

这与真实进程的 environ 完全一致（`python-deps` 在最后，且没有重复）。
任务里猜的"两处叠加后顺序变成 `venv-site:python-deps:python-deps`"**没有发生**：
叠加确实存在，但 `python-deps` 只出现一次、且排在 `agent-zero` 系列之后。

### 7.9.3 `sys.path` 的实际顺序（已实测）

用真实进程的 `PYTHONPATH`/`PYTHONHOME`/`LD_LIBRARY_PATH`、venv 的 CPython 3.14，
在沙盒里 `cd /app/bin` 后打印：

```
sys.path:
  ''                                             <- -c/stdin 形式；真实运行为 /app/bin
  /app/share/agent-zero
  /app/share/agent-zero/flatpak
  /app/share/python-deps
  .../uv/python/cpython-3.14.10-.../lib/python314.zip   (不存在)
  .../uv/python/cpython-3.14.10-.../lib/python3.14
  .../uv/python/cpython-3.14.10-.../lib/python3.14/lib-dynload
  .../venv/lib/python3.14/site-packages          <- 永远最后
```

按 CPython 规则推导（`python /app/bin/xpra` 时）：

1. `sys.path[0]` = 脚本目录 `/app/bin`（**不含 `xpra`，安全**）；
2. `PYTHONPATH` 从左到右插入：`agent-zero` → `agent-zero/flatpak` → `python-deps`；
3. 然后是解释器自身前缀推算的标准库路径（`PYTHONHOME` 为空 → uv 的 CPython 前缀），
   `lib-dynload` 紧随；
4. 最后才是 venv 的 `site-packages`（由 `pyvenv.cfg` 决定）。

**结论：`venv/site-packages` 永远排在 `/app/share/python-deps` 之后，
venv 里的 xpra 不可能抢先。** `import xpra` 命中
`/app/share/python-deps/xpra/__init__.py`，`xpra.net.__path__` =
`['/app/share/python-deps/xpra/net']`，`xpra.net.mmap` 有 `__path__`。

已排除的抢注候选（逐个实测不存在）：

```
/app/share/agent-zero/xpra{,py}            不存在
/app/share/agent-zero/mmap{,py}            不存在
/app/share/agent-zero/flatpak/xpra{,py}    不存在
/app/share/agent-zero/flatpak/mmap{,py}    不存在
/app/bin/xpra                              是文件，无 .py 后缀，不参与 import
<venv>/site-packages/xpra/net/mmap.py      不存在
<venv>/site-packages/*.pth                 不存在（无 .pth 注入）
/app/share/agent-zero/sitecustomize.py     不存在
/var/data/python                           不存在（PYTHONUSERBASE 指向空路径）
```

### 7.9.4 `PYTHONHOME=""` 的影响判断

**判断：在 CPython 3.14 下等价于"未设置"，当前没有造成路径污染。**

依据：

1. CPython 的 `_PyPathConfig` 处理 `PYTHONHOME` 时用 `if (home)` 判真，
   空串为假，走"未配置 home"分支，改用解释器自身前缀。实测 `sys.path` 出现的
   正是 uv 的 CPython 前缀，没有 runtime 的 `/usr/lib/python3.14`。
2. 同一 env 下 `import xpra` 命中 `/app/share/python-deps/xpra/__init__.py`，
   与不带 `PYTHONHOME` 时一致（两种写法都实测过，结果相同）。
3. `sys.path` 里没有出现 `/app/lib/python3.14/site-packages` 之类的 runtime 站点目录。

**但它仍是一个应该去掉的键**：`PYTHONHOME=` 把"未设置"写成"已设置且为空"，
等于把语义正确性押在 CPython 的空值处理上。`env.pop("PYTHONHOME", None)`
表达同一个意图，且不依赖解释器实现细节。

### 7.9.5 与 01:04 那次失败的关系：无法从这一侧证实

必须如实记录矛盾：

| 观察 | 结论 |
|---|---|
| `/app/share/python-deps/xpra/net/mmap/` 有 `__init__.py`/`common.py`/`io.py`/`objects.py` | 是包 |
| 从 `/proc/<pid>/root` 进入失败进程的 mount namespace 看，同一目录仍是完整包、版本 6.5.5 | 它眼里的镜像也是包 |
| 用真实进程的完整 env 跑 `import xpra.net.mmap.common` | `MMAP_OK` |
| 直接 `import xpra.server.window.compress`（traceback 的那一行） | 成功 |
| 失败后 `sys.modules` 里 `xpra.net.mmap` 与 `xpra.net.mmap.common` | 都是正常模块，`__path__` 存在 |
| `/app` 下两份 xpra（镜像与 Cuda 扩展挂载点） | 都是 6.5.5 包布局 |

**所以 01:04 那次失败无法在当前镜像状态下复现。** 唯一未被读到的输入是
那个 `bwrap --args 70 -- sh -s` 沙盒脚本本身（进程退出后 stdin 关闭，
`/proc/<pid>/fd/0` 已不可读）；它的 stdout 只有一行 `desktop: True`。

两种可能，按可能性排序：

1. **该次运行的 `/app` 内容与现在不同**（例如刚被另一个 worker 的
   bind-mount/overlay 覆盖过，或构建产物在 01:04 与 01:08 之间被替换）。
   旁证：`xpra-stderr.log` 的 mtime 是 01:08:04 且以
   `closing tcp socket 127.0.0.1:14500` 结束，说明 01:04 之后再没有新会话。
2. **该次运行的 `sys.path` 里出现了一个尚未枚举的条目**，它包含
   `xpra/net/mmap.py`。最可能的来源是另一个 worker 为验证而 bind-mount 的
   overlay 目录（任务描述里就提到过这种验证手法）。

**给下一位的复现命令**（必须在**失败发生的那一刻**执行，否则无效）：

```sh
PID=$(pgrep -f 'xpra shadow' | head -1)
tr '\0' '\n' < /proc/$PID/environ | grep -E '^(PYTHONPATH|PYTHONHOME|PYTHONUSERBASE)='
ls -l /proc/$PID/root/app/share/python-deps/xpra/net/mmap/
```

抓 `sys.path` 需要 `py-spy`/`gdb`；没有时用同 env 起子进程复现：

```sh
env -i $(tr '\0' '\n' < /proc/$PID/environ | grep -E '^(PYTHONPATH|PYTHONHOME|PYTHONUSERBASE|HOME|PATH|LD_LIBRARY_PATH)=' | tr '\n' ' ') \
  <venv>/bin/python -c 'import sys,xpra,xpra.net.mmap as m; print(xpra.__file__); print(getattr(m,"__path__",None)); print(sys.path)'
```

**注意：必须在沙盒内执行**（宿主看不到 `/app`），否则得到的是 venv 的 xpra，
会误导判断。本节记录过一次这样的误判：在宿主上用 `env -i` 复现，
`xpra.__file__` 指向 venv，看起来像"venv 抢先"，实际是宿主没有 `/app`。

### 7.9.6 最小改法（待确认后合入，本轮未改仓库）

**改法 A（推荐）：显式构造 `PYTHONPATH`，不继承。**

替换 `flatpak/a0flatpak/desktop.py:260-266`：

```python
        # Never inherit PYTHONPATH here. The launcher already prepends
        # /app/share/agent-zero and its flatpak/ directory, and a value carried
        # over from an outer process can put a second xpra tree ahead of the
        # bundle. Spell the order out: bundle first, framework second, and let
        # the interpreter's own site-packages stay last.
        frame_root = "/app/share/agent-zero"
        env["PYTHONPATH"] = ":".join(
            (BUNDLED_PY_DEPS, frame_root, os.path.join(frame_root, "flatpak"))
        )
        # An empty PYTHONHOME is "set to blank", not "unset"; CPython happens to
        # ignore it, but the intent is absence.
        env.pop("PYTHONHOME", None)
```

**改法 B（更保守，只动两个语义点，不改变现有顺序）：**

```python
        env.pop("PYTHONHOME", None)
        existing = env.get("PYTHONPATH", "")
        parts = [p for p in existing.split(":") if p]
        if BUNDLED_PY_DEPS in parts:
            parts.remove(BUNDLED_PY_DEPS)
        parts.insert(0, BUNDLED_PY_DEPS)
        env["PYTHONPATH"] = ":".join(parts)
```

**改法 C（防御性，与 A/B 可叠加）：起进程前自检，把"hello 阶段才炸"变成"启动前报清楚"。**

在 `_spawn_desktop_locked` 里 `subprocess.Popen` 之前插入：

```python
        probe = subprocess.run(
            [
                *interpreter,
                "-c",
                "import xpra, xpra.net.mmap as m;"
                "print(xpra.__file__);"
                "print(getattr(m, '__path__', None) is not None)",
            ],
            capture_output=True, text=True, env=env, timeout=30,
        )
        lines = probe.stdout.splitlines()
        if probe.returncode != 0 or lines[-1:] != ["True"]:
            raise RuntimeError(
                "the xpra tree this session would import has no xpra.net.mmap "
                f"package:\nstdout={probe.stdout}\nstderr={probe.stderr}"
            )
```

三条改法的取舍：

| 改法 | 效果 | 风险 |
|---|---|---|
| A | 顺序完全确定，镜像永远第一 | 将来若有别的框架路径必须在前，会被压掉（当前没有） |
| B | 只去掉已知的两个隐患，顺序与今天一致 | 不解决"未来继承值里出现第二棵 xpra 树" |
| C | 任何布局问题在 spawn 时失败并带上证据 | 每次启动多一次进程（约 0.3 s） |

**推荐 A + C**：A 消除顺序不确定性，C 让下一次同类故障自己说出原因，
不必再派一个 worker 花两小时取证。
