# Cuda / Wps 扩展是否必须随主包重建

**结论：不必。** extension 的 `base` 是 **ref（app id + arch + branch）**，不是 commit；Wps 根本不依赖主包。磁盘上的 Cuda/Wps bundle 也**已重建**（04:20/04:21），只是尚未重装。

## 1. base 字段原文

`flatpak/org.agentzero.AgentZero.Cuda.yml`：

```yaml
runtime: org.agentzero.AgentZero
runtime-version: master
base: org.agentzero.AgentZero
base-version: master
```

安装后 `runtime/org.agentzero.AgentZero.Cuda/x86_64/12/active/metadata`：

```ini
base=app/org.agentzero.AgentZero/x86_64/master
[ExtensionOf]
ref=app/org.agentzero.AgentZero/x86_64/master
runtime=org.freedesktop.Platform/x86_64/25.08
```

`Wps.yml`：`runtime: org.freedesktop.Platform` / `'25.08'`，**无 `base:`**；metadata 只有 `runtime=org.freedesktop.Platform/x86_64/25.08`，是独立 app，与主包 commit 无关。
新主包 metadata 的扩展点：`Cuda → share/agent-zero/cuda, version=12`、`Models → share/agent-zero/models, version=1.0`，与已装扩展 branch 对应。

## 2. 当前状态

| 包 | 已安装 commit | 时间 | build/cache ref | bundle |
|---|---|---|---|---|
| 主包 | `5631f3ab75d7…ec76` | 11-18 20:10 UTC | `5631f3ab75d7…ec76` | 60,029,120 B / 04:12 |
| Cuda | `8d1b15a30062…7a84` | 11-01 09:53 UTC | `333e66556c8e…f440` | 859,737,528 B / 04:20 |
| Wps | `184cc3776f17…3380` | 11-01 09:57 UTC | `cc6c1a871892…b8d0` | 50,210,264 B / 04:21 |

**v14 更新（04:31–04:42，一轮构建 623 s）**：主包 `ab3d8e6150f7`；Cuda `075925938031`（bundle sha256 `39c3f403…`）；Wps `33285d744f9d`（bundle sha256 `1971d99f…`）。主包与 Cuda 已安装到该 commit，Wps 扩展本机仍是 2026-11-01 的旧 commit。上表与下一段都是 04:12 前后的快照；v14 之后 `flatpak info` 与 5080 进程均为 `ab3d8e61`。

**v18 更新（06:18–06:29，648 s）**：主包 `be957363ef7e`（60,318,144 B / 06:20:08）、Cuda `62ab409394bd`（860,274,832 B / 06:27:57，bundle sha256 `5a1b5c41…`）、Wps `e04738e292a6`（50,210,360 B / 06:29:36，bundle sha256 `e84bbed0…`）。三件均已安装到该 commit；`flatpak info` 与 5080 进程均为 `be957363`。上面两段（含 v14 的“Wps 仍旧”）都只是更早时点的快照。

**v20 更新（07:41–07:51，最终交付）**：主包 `21b0e23abd78`（60,530,648 B / 07:43:22，sha256 `5f8f1ee1…`）、Cuda `6b60dbc5d210`（860,262,096 B / 07:50:38，sha256 `e66e8d73…`）、Wps `2444a5752aff`（50,210,816 B / 07:51:48，sha256 `4c451457…`）。三件均已安装；`flatpak info` 为 `21b0e23a`（Installed Size 126.7 MB，Date 2026-11-17 23:42:14 +0000）。上面所有段落都是更早时点的快照。

**v21 更新（09:30–09:39，最终交付）**：主包 `053ed951355a`（60,516,256 B / 09:31:18，sha256 `8c8e1e53…`）、Cuda `ec01de1218b0`（860,267,312 B / 09:37:58，sha256 `e5c12af3…`）、Wps `5dd808f043f8`（50,210,576 B / 09:39:07，sha256 `63b51ce2…`）。三件均已安装；`flatpak info` 为 `053ed951`（Installed Size 126.8 MB，Date 2026-11-18 01:30:35 +0000）。上面所有段落都是更早时点的快照。

**v22 更新（09:52–10:01，最终交付）**：主包 `d7749980`（60,506,136 B / 09:53:45，sha256 `97615832…`）、Cuda `b0633fcb`（860,271,248 B / 10:00:27，sha256 `1a5196a4…`）、Wps `790cee09`（50,210,992 B / 10:01:30，sha256 `3ddbd350…`）。三件均已安装；`flatpak info` 为 `d7749980`（Installed Size 126.7 MB，Date 2026-11-18 01:52:27 +0000）。上面所有段落都是更早时点的快照。

`build/checksums` 与 cache ref mtime 为 04:10–04:11，bundle 依次 04:12/04:20/04:21 打出，顺序与 `scripts/build.sh` 一致。**“Cuda/Wps 没重建”的前提已过时**：bundle 是新的，安装的扩展仍旧。另注：本机当前 5080 由**旧** commit `4d0ccd2c`（已移到 `flatpak/.removed/`）的进程服务，`flatpak info` 的 `5631f3ab` 只代表“已安装”，线上版本要看进程的 mount 源。

## 3. 为什么不必重建（证据）

- 已装 Cuda（旧 commit）正被运行中的应用挂载：`/proc/<pid>/mountinfo` 有 `…Cuda/x86_64/12/8d1b15a3…/files /app/share/agent-zero/cuda`，其 `cuda_v12/` 内有 `libcublas.so.12`。
- 挂载依据是扩展点 `directory` + `version`，新主包未变（§1）。
- `base=` 只写 ref；`deploy` 文件只有 `extension-of app/org.agentzero.AgentZero/x86_64/master`，无 commit 字段。

## 4. 若真缺扩展，失败模式

- **Cuda 缺失**：静默退化。`/app/share/agent-zero/cuda` 不存在，`LD_LIBRARY_PATH` 指向空路径，Ollama 走 CPU，日志无 `library=cuda`，但 health 仍 200、不报错。
- **Wps 缺失**：`flatpak run --command=wps-mcp org.agentzero.AgentZero.Wps` 报 `app … not installed`，WPS 工具全不可用；不影响主包。
- **安装期报错**只在 base ref/branch 不存在时出现：`error: Runtime org.agentzero.AgentZero/x86_64/master not installed`；换 commit 不触发。

## 5. 重建 / 重装命令

```sh
flatpak build-bundle build/cache bundles/agent-zero.flatpak org.agentzero.AgentZero master
flatpak build-bundle --runtime build/cache bundles/agent-zero-cuda.flatpak org.agentzero.AgentZero.Cuda 12
flatpak build-bundle build/cache bundles/agent-zero-wps.flatpak org.agentzero.AgentZero.Wps 1.0
```

全量用 `A0_SRC=<checkout> scripts/build.sh`（先主包、后两个扩展）。耗时（本轮实测）：cache refs 04:11 → 主包 04:12、Cuda 04:20、Wps 04:21，**三件重打包约 10 分钟**；走完整 `build.sh` 另加主包编译时间。装到机器上仍按主包 → Cuda → Wps（`--user --reinstall`）。

