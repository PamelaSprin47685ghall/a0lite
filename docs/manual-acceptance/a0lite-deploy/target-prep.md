# 目标机部署前准备（760K）

- 采集时间：2026-11-17 23:0x（本地）／目标机同一时钟
- 目标机：`root@127.0.0.1:12022`（免密可用），主机名档案别名 `760K`
- 本轮边界：**只做备份与只读侦察**。未停止/重启任何服务，未执行任何 `flatpak install/uninstall/update`，未修改 override，未删除用户数据，未触碰 `/home/kunweiz/a0-models-repo`。
- 统一前缀：

```bash
SSH='ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -p 12022 root@127.0.0.1'
```

---

## 1. 备份

### 命令

```bash
B=/root/a0lite-deploy-backup/20261117
mkdir -p "$B"/{systemd,bin,flatpak-overrides,appdata}
cp -a /etc/systemd/system/agent-zero.service \
      /etc/systemd/system/agent-zero-desktop.service "$B"/systemd/
cp -a /usr/local/bin/a0-desktop-start "$B"/bin/
cp -a /home/kunweiz/.local/share/flatpak/overrides/. "$B"/flatpak-overrides/
cp -a /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/.env "$B"/appdata/env.agent-zero
cp -a /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/conf "$B"/appdata/conf
find "$B" -maxdepth 3 -printf "%M %u:%g %10s %p\n" | sort -k4
```

### 关键输出

```
drwxr-xr-x root:root       3488 /root/a0lite-deploy-backup/20261117
drwxr-xr-x root:root       3488 .../appdata
drwxr-xr-x kunweiz:kunweiz 3488 .../appdata/conf
-rw-r--r-- kunweiz:kunweiz 2353 .../appdata/conf/AGENTS.md
-rw-r--r-- kunweiz:kunweiz 9024 .../appdata/conf/model_providers.yaml
-rw-r--r-- kunweiz:kunweiz  158 .../appdata/conf/projects.default.gitignore
-rw-r--r-- kunweiz:kunweiz  146 .../appdata/conf/skill.default.gitignore
-rw-r--r-- kunweiz:kunweiz  158 .../appdata/conf/workdir.gitignore
-rw-r--r-- kunweiz:kunweiz  990 .../appdata/env.agent-zero
drwxr-xr-x root:root       3488 .../bin
-rwxr-xr-x root:root       1005 .../bin/a0-desktop-start
drwxr-xr-x kunweiz:kunweiz 3488 .../flatpak-overrides
-rw-r--r-- kunweiz:kunweiz  180 .../flatpak-overrides/org.agentzero.AgentZero
drwxr-xr-x root:root       3488 .../systemd
-rw-r--r-- root:root        535 .../systemd/agent-zero-desktop.service
-rw-r--r-- root:root        715 .../systemd/agent-zero.service
合计 41K，10 个文件
```

另外两处事实：`.env` 存在且 40 个非空行；`conf/` 只有 5 个文件（AGENTS.md、model_providers.yaml、3 个 gitignore 模板）。

### 判断

- 备份完整，路径与权限（`cp -a`）保留，可直接用于回滚。
- **`A0_AUTH_KEY` 不在 `.env` 里，而在 flatpak override**（`.../flatpak-overrides/org.agentzero.AgentZero`）；该文件已备份，**已备份，长度 5**。`deploy.sh` 只在调用方设置 `A0_AUTH_KEY` 环境变量时才重写 override，因此现有 key 不会因重装被清掉。
- `.env` 共 40 个变量：37 个 `API_KEY_*`，加 `AUTH_LOGIN`、`AUTH_PASSWORD`、`RFC_PASSWORD`，以及 `A0_PERSISTENT_RUNTIME_ID`、时区、`ALLOWED_ORIGINS`。已随备份留存，报告不展开。
- 备份目录额外保留了一个 1 KB 的 scp 测试文件（见 §7）。

### 备份校验（便于回滚后核对）

```
42b3667c84ad4b71e5405e58006a4dac87747f8cfc02a3748ef4f3a0309a9d32  flatpak-overrides/org.agentzero.AgentZero
05d7c227093a019f50100efe25063422167c4307447b2c118f71eb0e9244ab08  systemd/agent-zero.service
1611085fabb4a3b3d61d923b1f41e92436a234b8d01ac6b7d398d091053e7265  systemd/agent-zero-desktop.service
b468845fb90f4a5606aa97f88bdea71d0f26db42529159a61450e8adc9416589  bin/a0-desktop-start
7ba0bde32cadbb0c8e5348b98715aa4f68a9955120074409fab602d133df762f  appdata/env.agent-zero
```

---

## 2. 清理坏挂载

### 命令

```bash
$SSH 'umount -f /home/kunweiz/public-mm /home/kunweiz/private-mm 2>&1
      fusermount -uz /home/kunweiz/public-mm 2>&1
      fusermount -uz /home/kunweiz/private-mm 2>&1
      mount | grep -c syncmount'
```

### 关键输出

```
BEFORE:
syncmount-mm on /home/kunweiz/public-mm type fuse.syncmount-mm (rw,nosuid,nodev,...)
syncmount-mm on /home/kunweiz/private-mm type fuse.syncmount-mm (rw,nosuid,nodev,...)
syncmount    on /home/kunweiz/private    type fuse.syncmount    (rw,nosuid,nodev,...)
syncmount    on /home/kunweiz/public     type fuse.syncmount    (rw,nosuid,nodev,...)
umount rc=0
fusermount: failed to unmount /home/kunweiz/public-mm: Invalid argument
fusermount: failed to unmount /home/kunweiz/private-mm: Invalid argument
AFTER: 2
```

后续核验：`public-mm` / `private-mm` 目录可列且为空；`ls -A /home/kunweiz/public` 与 `/home/kunweiz/private` 都能正常返回内容（说明剩余两个挂载是健康的，不是坏挂载）。

### 判断

- **两个坏掉的 `*-mm` 挂载已解除**（`umount -f` 生效；随后 `fusermount -uz` 报 Invalid argument 属正常，因为已无挂载点）。未强删目录。
- 计数仍为 2，但对象不同：`/home/kunweiz/public`、`/home/kunweiz/private` 两个 syncmount 仍在线且可用。按“若仍挂载则报告并跳过”的口径，未对其做任何操作。
- 风险提示：`agent-zero.service` 含 `RequiresMountsFor=/home/kunweiz`，重启/停服务时若这两个 fuse 挂载卡住，systemd 会阻塞。目前它们健康，暂不构成阻断。

---

## 3. 旧状态快照（回滚对照基线）

### 命令与输出

```bash
systemctl show agent-zero -p ActiveState,SubState,ExecMainPID,UnitFileState
```
```
ActiveState=active
SubState=running
UnitFileState=enabled
ExecMainPID=595
```

```bash
systemctl show agent-zero-desktop -p ActiveState,SubState,ExecMainPID
```
```
ActiveState=active
SubState=exited
ExecMainPID=596
```

```bash
flatpak --user list --all --columns=application,branch,commit,origin,size
```
```
error: Unknown column: commit        # Flatpak 1.18.4 无 commit 列，改用默认列 + flatpak info
```

改用默认列，实际安装集：

| 组件 | ID | 版本 | 分支 | 来源 |
|---|---|---|---|---|
| Agent Zero | org.agentzero.AgentZero | 1.0 | master | agentzero-origin |
| Cuda | org.agentzero.AgentZero.Cuda | — | 12 | cuda-origin |
| Models | org.agentzero.AgentZero.Models | — | 1.0 | models-local |
| Wps | org.agentzero.AgentZero.Wps | — | 1.0 | wps-origin |
| Freedesktop Platform / SDK | org.freedesktop.* | 25.08 | 25.08 | flathub |
| Mesa / Mesa Extra | org.freedesktop.Platform.GL.default | 26.2.5 | 25.08(-extra) | flathub |
| nvidia-610-57-04 | org.freedesktop.Platform.GL.nvidia-610-57-04 | — | 1.4 | flathub |
| Nvidia VAAPI | org.freedesktop.Platform.VAAPI.nvidia | — | 25.08 | flathub |
| codecs-extra | org.freedesktop.Platform.codecs-extra | — | 25.08-extra | flathub |
| GTK 主题 | org.gtk.Gtk3theme.Matcha-light-sea | 2021-12-25 | 3.22 | flathub |

`flatpak --user info org.agentzero.AgentZero`：

```
        Commit: b15bc3875ed0fbbb6c842e863259d19ac0dd7a3f3b72fc7019f6b620b190ad1d
        Parent: 55f1ef2a82ce37db17b19748fa508fd227a8fe7d8bdcfb55b76dc8275583040a
          Date: 2026-11-02 18:53:45 +0000
        Origin: agentzero-origin
    Installed Size: 128.0 MB
```

接口快照：

```
curl -sS http://127.0.0.1:5080/api/health   -> {"status":"ok"}
curl -o /dev/null -w '%{http_code}' /       -> 401          # 鉴权生效，符合预期
curl -sS http://127.0.0.1:11434/api/tags    -> 3 个模型：
    lfm3-omni:2b-q4_K_M            2.05 GB   (completion/vision/audio/speech/tools)
    qwen3-embedding:4b-q4_K_M      2.50 GB
    xiaomi-ocr:latest              0.74 GB
curl -o /dev/null -w '%{http_code}' :14500  -> 200          # Xpra HTML
```

监听端口（`ss -ltnp`）：`127.0.0.1:5080`（python, pid 782）、`127.0.0.1:11434`（ollama, pid 808）、`127.0.0.1:14500`（python, pid 972）。**`58891`（WPS MCP）无监听。**

已安装 commit 目录：`.../app/org.agentzero.AgentZero/x86_64/master/` 下有 `27f5730…`（旧）与 `b15bc387…`（active），`active` 为符号链接指向后者。

### 判断

- 两个 unit 都是 `active`：主服务 running，desktop 为 `Type=oneshot` 所以 `exited` 属正常（`RemainAfterExit=yes`）。
- 回滚基线：`Commit b15bc387…`、健康检查 `{"status":"ok"}`、5080 返回 401、14500 返回 200、Ollama 三模型。
- 回滚判定口径：只要新部署后这三项与模型列表一致，即为功能等价。

---

## 4. WPS Office 是否存在

### 命令与输出

```
command -v wps et wpp          -> 三者均 MISSING
ls -d /opt/kingsoft/wps-office -> MISSING
ls ~/.local/share/Kingsoft/wps/jsaddons -> MISSING（且 ~/.local/share/Kingsoft 整个目录不存在）
flatpak list | grep -i wps     -> org.agentzero.AgentZero.Wps（1.0，已安装，190.1 MB，wps-origin）
Wps 扩展载荷：bin lib manifest.json share wps-skills
Wps 扩展 share：licenses skills wps-claude-assistant wps-office-mcp
```

`org.agentzero.AgentZero.Wps.yml` 内注释已明确：

> It does not ship WPS Office itself: the host must provide it, because the add-in writes into the user's WPS profile and talks to the running WPS process.
> 1. this extension, which provides the MCP server on 127.0.0.1:58891
> 2. the WPS add-in, installed into ~/.local/share/Kingsoft/wps/jsaddons/ by flatpak/install-wps-addon.sh

### 判断

- **宿主上没有 WPS Office**（无二进制、无 `/opt/kingsoft/wps-office`、无 Kingsoft 用户档案）。
- 已装的是 **WPS 的 MCP 服务扩展**，不是 WPS 本身；且 58891 未监听、jsaddons 未安装。
- 结论：**WPS 相关验收当前不具备条件**。要么先装宿主 WPS 并执行 `flatpak/install-wps-addon.sh`，要么把 WPS 用例标记为“环境不具备，不可验收”，不要消耗验收轮次去试。

---

## 5. 验收所需宿主工具

### 命令与输出

```
google-chrome:          /usr/bin/google-chrome
google-chrome-stable:   /usr/bin/google-chrome-stable
chromium:               MISSING
chromium-browser:       MISSING
scrot:                  MISSING
import:                 /usr/bin/import        # ImageMagick
convert:                /usr/bin/convert
ffmpeg:                 /usr/bin/ffmpeg
python3:                /usr/bin/python3
curl:                   /usr/bin/curl
wget:                   /usr/bin/wget
unzip:                  /usr/bin/unzip
ffplay:                 /usr/bin/ffplay
aplay:                  /usr/bin/aplay
xdotool:                MISSING
wmctrl:                 MISSING
/usr/share/icons:       Adwaita AdwaitaLegacy HighContrast Papirus Papirus-* Simple-and-Soft
                        Vanilla-DMZ-AA breeze-cursors* default elementary hicolor locolor manjaro
```

### 判断

- **可用**：Chrome（两条命令都指向同一份）、ImageMagick `import`/`convert`、ffmpeg/ffplay、python3、curl/wget/unzip、aplay。
- **缺失**：`chromium`/`chromium-browser`（有 Chrome 替代）、`scrot`（有 `import` 替代）、`xdotool`、`wmctrl`。
- 影响：纯浏览器验收可用 Chrome；截图用 `import -window root`；**窗口级自动化（激活窗口、按键注入、几何查询）没有 xdotool/wmctrl**，凡是脚本依赖它们就必须改写方案（例如用 Chrome DevTools 或 Xpra 自带能力），否则相关用例不可自动执行。
- 图标主题齐全，桌面项与图标类用例有素材。

---

## 6. 磁盘与 inode

### 命令与输出

```
df -h /   -> /dev/sda2  933G  498G  435G  54%  /
df -i /   -> /dev/sda2  10017277 8319656 1697620 84%  /
du -sh /home/kunweiz/.var/app/org.agentzero.AgentZero   1.5G
du -sh /home/kunweiz/a0-models-repo                     4.7G
du -sh /home/kunweiz/.local/share/flatpak               9.6G
du -sh /tmp                                             1.9G
```

### 判断

- 容量充裕（435G 可用），装一个新 commit（约 133M）与三个 bundle 无压力。
- **inode 已用 84%，只剩 169.7 万**。flatpak 新旧两个 commit 会并存一段（现有 `27f5730…` 与 `b15bc387…` 已经并存），构建/安装会再消耗一批小文件；`/tmp` 1.9G 可回收作为缓冲。不算阻断，但构建前清 `/tmp` 是低成本的保险。
- `/home/kunweiz/.local/share/flatpak` 9.6G 里主要是 Models/Cuda 扩展与运行库；本轮不动。

---

## 7. 传输入口

### 命令与输出

```bash
head -c 1024 /dev/urandom > /tmp/a0lite-scp-probe.bin
scp -P 12022 -o BatchMode=yes /tmp/a0lite-scp-probe.bin root@127.0.0.1:/root/a0lite-deploy-backup/
```

```
本地:  8c6607c80c603807310c783a35d5fce75ea9d17a2a26edcac35127b41c20ee83
远端:  8c6607c80c603807310c783a35d5fce75ea9d17a2a26edcac35127b41c20ee83
-rw-r--r-- 1 root root 1024 .../a0lite-deploy-backup/a0lite-scp-probe.bin
scp rc=0
```

反向：本机 22 端口在听（`ss -ltn | grep -c ':22 '` = 1），但部署是**本地推送到目标机**的单向模型（`deploy.sh` 全程 `scp` + 远端命令），目标机→本机不需要通道。

### 判断

- `scp -P 12022` 可用，1 KB 往返后 sha256 一致，`/root/a0lite-deploy-backup/` 可写。
- 单向足够；无需为反向开放额外端口。

---

## 8. 旧安装里 a0flatpak 的版本标识

### 命令

```bash
REMOTE=/home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero/current/active/files/share/agent-zero/flatpak
sudo -u kunweiz head -20 "$REMOTE"/a0flatpak/__init__.py
sudo -u kunweiz sha256sum "$REMOTE"/a0flatpak/*      # 忽略 __pycache__
sha256sum flatpak/a0flatpak/*                        # 本地
```

### 关键输出

远端 `ls`：`__init__.py auth.py base_dir.py browser.py code_exec.py compat.py desktop.py embeddings.py health.py ocr.py packages.py parsers.py provider_urls.py rfc_loop.py serve.py speech.py vector_store.py` + `__pycache__`（编译产物）。
本地：同名 17 个 `.py`，无 `__pycache__`。

逐文件 sha256（节选，全部 17 个一致）：

| 文件 | 远端 | 本地 | 结论 |
|---|---|---|---|
| `__init__.py` | 6671e933cf2d | 6671e933cf2d | 同 |
| `auth.py` | 3616bdf420f3 | 3616bdf420f3 | 同 |
| `base_dir.py` | 469bf6b3ce9d | 469bf6b3ce9d | 同 |
| `browser.py` | e061d6ecd892 | e061d6ecd892 | 同 |
| `compat.py` | 29f35dbfefcd | 29f35dbfefcd | 同 |
| `desktop.py` | 0f0cf02dd51b | 0f0cf02dd51b | 同 |
| `speech.py` | e04357127bd9 | e04357127bd9 | 同 |
| `vector_store.py` | 7c8ff9061fc7 | 7c8ff9061fc7 | 同 |

把整个 `flatpak/` 载荷（34 个文件）一起比对，结论相同：**README、a0flatpak 全部 17 个模块、agent-zero.sh、三个扩展 manifest、主 manifest、desktop/metainfo/png、overrides.txt、prompts、requirements-flatpak.txt、unpack-deb.sh、wps-mcp-config.json、wps-mcp.sh —— 全部 sha256 相同；缺失 0，差异 0。**

唯一差异曾出现在 `wps-office-mcp-deps.tar.gz`（生成物，不是源码）：本地该文件在采集期间先出现（15,934,759 B，hash `b77df78e…`）随后消失，属另一个构建任务按 `build.sh` 的“校验 pin，不一致则删除重建”逻辑在作业中。仓库里 `org.agentzero.AgentZero.Wps.yml` 钉的是：

```
path: wps-office-mcp-deps.tar.gz
sha256: ff53b5920ebd705b0f47e9ee8dcd04b0755cab1f937e515a0f1ee28ea547ec73
```

而远端已装载荷中该文件正是 `ff53b5920e…`（15,946,720 B）。**pin 与已装版本一致，重建时会按此 pin 生成。**

### 判断

- **a0flatpak 无缺失、无差异，不需要因为“模块缺失”而重建。**
- 打包层（`flatpak/`）与已装 commit `b15bc387…` 完全一致，说明自那次构建以来打包层未变；本地 HEAD 已到 `058582f`，多出的提交在 agent-zero 上游源码侧（不在本仓库），所以**是否重建取决于上游源码差异，而不是 a0flatpak**。
- 远端多出的 `__pycache__` 是运行期产物，重装后自然重建，不是版本标识。

---

## 9. 重新安装不会丢数据的证据

### 命令与输出

```bash
readlink -f .../app/org.agentzero.AgentZero/current/active
```
```
/home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero/x86_64/master/b15bc3875ed0fbbb6c842e863259d19ac0dd7a3f3b72fc7019f6b620b190ad1d
```

```bash
ls /home/kunweiz/.var/app
```
```
org.agentzero.AgentZero
org.agentzero.AgentZero.Wps
```

```bash
ls -ld /home/kunweiz/.var/app/org.agentzero.AgentZero     # drwxr-xr-x 7 kunweiz kunweiz，mtime 11-01 16:55
readlink /home/kunweiz/.var/app/org.agentzero.AgentZero   # 非符号链接
```

数据目录内部（1.5G）：

```
agents  api  conf  extensions  knowledge  plugins  prompts  tmp  usr  venv  webui
venv/bin/python -> /home/kunweiz/.var/app/org.agentzero.AgentZero/data/uv/python/cpython-3.14-linux-x86_64-gnu/bin/python3.14
大项：venv 831M、tmp 384M、webui 18M、plugins 13M
```

应用安装目录（约 133M）只含部署内容，且已有两代 commit 并存：

```
.../app/org.agentzero.AgentZero/x86_64/master/
  27f57309029ad020512d015ba000d5725deabd93ecd560560d76314b26213300   # 旧
  b15bc3875ed0fbbb6c842e863259d19ac0dd7a3f3b72fc7019f6b620b190ad1d   # active
  active -> b15bc387…
```

`flatpak info --show-permissions` 显示 override 与清单合并后的权限：`filesystems=host-etc:ro;host-os:ro;/run/udev:ro;host;`，环境含 `A0_AUTH_KEY`（长度 5）、`ALLOWED_ORIGINS`、`OLLAMA_HOST`、`A0_OLLAMA_BIND`。

### 判断

- 用户数据在 **`~/.var/app/<app-id>`**，应用在 **`~/.local/share/flatpak/app/<app-id>/<arch>/<branch>/<commit>`**；两者是不同树，`--reinstall` 只替换后者。数据目录不是软链接，没有指进应用目录。
- 已有两代 commit 并存、且 override 文件 mtime（11-02 23:19）早于 active 部署时间（11-03 02:54）却仍然生效——**上一次重装/更新没有动数据和 override**，这是比文档更强的现场证据。
- `venv` 在数据目录内并指向 `~/.var/app/.../data/uv/...`，重装不会重建 venv，也不会丢 Python 包；`deploy.sh` 的安装命令只有 `flatpak install --reinstall`，没有删除 `~/.var/app`。
- 因此：**重装应用安全；仍需在部署前另做一次数据目录快照**（2.9M 的 Wps 数据 + 1.5G 主数据），因为“不删”不等于“不会被新代码写坏”。

---

## 10. 重启窗口记录（内核更换）

### 触发条件

另一位工程师将把目标机内核从自定义 `7.3.0-rc6-1-MANJARO` 换成官方稳定内核，并安装匹配的 nvidia 驱动，随后重启。重启会清空运行态，但**不会改变 flatpak 安装 commit、`~/.var/app` 用户数据、override、`/root` 备份**。

### 采集时刻的实际状态（未重启）

```bash
$SSH 'uptime; who -b; uname -r; ls /dev/nvidia*; systemctl show agent-zero -p ActiveState,SubState,ExecMainPID'
```

```
 23:06:51 up 7 days,  1:21
         system boot  Nov 10 21:44
7.3.0-rc6-1-MANJARO
(no /dev/nvidia*)
ActiveState=active / SubState=running / ExecMainPID=595
ActiveState(desktop)=active / SubState=exited
LISTEN 127.0.0.1:5080 / 127.0.0.1:11434 / 127.0.0.1:14500
```

判断：截至该时刻**尚未重启**，仍是 rc 内核、仍无 nvidia 设备节点、两个服务 PID 与 §3 完全一致（595/596）。

### 重启前指纹（用于重启后对照，判断“是否需要重装”）

| 项 | 重启前值 |
|---|---|
| 内核 | `7.3.0-rc6-1-MANJARO` |
| nvidia 设备 | 无 `/dev/nvidia*` |
| 已装 commit | `b15bc3875ed0fbbb6c842e863259d19ac0dd7a3f3b72fc7019f6b620b190ad1d` |
| `agent-zero` | active/running, PID 595 |
| `agent-zero-desktop` | active/exited, PID 596 |
| 5080 `/api/health` | `{"status":"ok"}` |
| 5080 `/` | 401 |
| 14500 | 200 |
| Ollama | 3 个模型（lfm3-omni/qwen3-embedding/xiaomi-ocr） |
| 打包层 sha256 | 34 文件与本地全一致（§8） |

### 三项优先项的持久性

- **备份**：`/root/a0lite-deploy-backup/20261117/` 在根文件系统，重启保留；校验和列在 §1，可离线复核。
- **旧状态快照**：§3 与本节表格；不依赖进程存活。
- **sha256 逐文件对比**：§8，结论“34 个载荷文件全部一致，a0flatpak 17 模块零缺失”。该结论本身已固化，重启不会改变已装 commit 的内容。

### 因目标机重启而未完成的项目

**无。** 本轮 9 项任务均在重启前完成，没有被中断的命令，也没有因 fuse 挂载或 `/home/kunweiz` 扫描卡住的操作（唯一涉及 `/home/kunweiz` 的递归动作是 `du -sh` 三个指定目录，均秒级返回）。若重启发生在报告交接之后，唯一的后续动作是按下节清单复核，不需要重跑 §1–§9。

### 重启后需复核（不属于本轮，供接手者执行）

```bash
uname -r; ls /dev/nvidia*; nvidia-smi 2>&1 | head -5
systemctl show agent-zero -p ActiveState,SubState,ExecMainPID
systemctl show agent-zero-desktop -p ActiveState,SubState
curl -sS http://127.0.0.1:5080/api/health
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5080/
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:14500/
curl -sS http://127.0.0.1:11434/api/tags | head -c 400
flatpak --user info org.agentzero.AgentZero | grep -E 'Commit|Date'
```

判定顺序：

1. 内核与驱动是否匹配（`uname -r`、`/dev/nvidia*`、`nvidia-smi`）。匹配失败属于驱动问题，不要往打包层归因。
2. 服务是否自动回来。`agent-zero` 是 `enabled`，但带 `RequiresMountsFor=/home/kunweiz`；若 `public`/`private` 的 fuse 挂载在重启时卡住，unit 会阻塞而不是失败。
3. 健康与端口是否与上表一致；`401` 是预期值，不是故障。
4. 只有当“驱动匹配、服务已起、健康异常”同时成立时，才进入“是否需要重装”的判断；此时对照 §8 的 sha256 结论即可排除“打包层版本不一致”。
5. 重启不会改变 `Commit b15bc387…`；若它变了，说明有人执行过安装，不是重启导致。

---

## 11. 部署前必须先解决的问题（按严重度）

1. **【阻断】`bundles/` 为空，一键部署没有输入。**
   本地 `bundles/` 存在但 0 个文件；`deploy.sh` 硬性要求 `agent-zero.flatpak`、`agent-zero-cuda.flatpak`、`agent-zero-wps.flatpak` 三件，缺一即退出。同时目标机 `flatpak --user remotes` 只有 `flathub` 与 `models-local`——`agentzero-origin`/`cuda-origin`/`wps-origin` 只是历史安装来源标签，**不是可用 remote**。所以部署路径只能是“本地构建 bundle → scp → `flatpak install --user --reinstall /tmp/*.flatpak`”；任何 repo/`flatpak update` 路线都缺源。先产出三件 bundle 并校验 `flatpak build-bundle` 成功。

2. **【阻断 WPS 验收范围】宿主没有 WPS Office。**
   无 `wps/et/wpp`、无 `/opt/kingsoft/wps-office`、无 `~/.local/share/Kingsoft`（jsaddons 不存在）；已装的 `org.agentzero.AgentZero.Wps` 只是 MCP 扩展，58891 未监听。要么先装宿主 WPS 并跑 `flatpak/install-wps-addon.sh`，要么在验收表里把 WPS 用例整体标记“环境不具备”。不要带着这个缺口排验收轮次。

3. **【高】旧服务仍在跑，部署窗口必须先停。**
   `agent-zero.service` = `active/running`（PID 595，`Restart=always`），`agent-zero-desktop.service` = `active/exited`（`RemainAfterExit=yes`）。本轮按约定未停。停止顺序应为 desktop → agent-zero，否则 `Restart=always` 会让主服务在重装过程中自我拉起，造成半新半旧的运行态。

4. **【中高】inode 余量偏低（84% 已用，剩 169.7 万）。**
   容量不是问题，但 flatpak 会并行保留旧 commit，构建又在本地产生大量小文件。部署前清 `/tmp`（1.9G）并确认构建机 inode 余量，属于低成本保险。

5. **【中】验收工具缺 `chromium`、`scrot`、`xdotool`、`wmctrl`。**
   有 Chrome、ImageMagick、ffmpeg、ffplay、python3，浏览器与截图可替代；**窗口级自动化没有替代品**，依赖 xdotool/wmctrl 的用例需要改写成 DevTools 或 Xpra 方案，否则无法执行。

6. **【中，已知】GPU 驱动与内核不匹配（无 `/dev/nvidia*`）。**
   Cuda 扩展与 nvidia GL 运行时都在，但实际不可用；Ollama 会走 CPU。部署后不要用 GPU 相关指标做验收，也不要把 Cuda 扩展是否“加载成功”当作判据。

7. **【低中】`/home/kunweiz/public`、`/home/kunweiz/private` 仍挂两个 syncmount（健康）。**
   本次未动，也能正常列目录；但 `agent-zero.service` 有 `RequiresMountsFor=/home/kunweiz`，重启窗口里 fuse 若卡住会阻塞启动。部署前顺手确认一次 `ls` 可返回即可。

8. **【低】认证配置只在 override，不在 `.env`。**
   已备份（长度 5）。`deploy.sh` 只在调用方传入 `A0_AUTH_KEY` 时才重写 override；不传则保留现值。重装后必须复核 5080 仍然返回 401、且携带正确 key 能通过，避免“以为还在、其实已被覆盖”。

9. **【低】WPS 依赖 tarball 是生成物，不随仓库分发。**
   当前本地不存在，`build.sh` 会按 `sha256: ff53b5920e…` 生成并回写 pin；该 pin 与目标机已装载荷一致。若手工往目标机补文件，必须先对齐这个 pin，否则 `flatpak-builder` 会拒绝或产生第二个版本。

10. **【低】旧 commit `27f5730…` 仍占空间。**
    重装成功后可用 `flatpak uninstall --unused` 清理，但要在验收通过、回滚窗口关闭之后再做。

---

## 附：本轮产生的远端文件

- `/root/a0lite-deploy-backup/20261117/`：10 个文件，41K
- `/root/a0lite-deploy-backup/a0lite-scp-probe.bin`：1 KB 传输验证文件（可随时删除）
