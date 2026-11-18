# Vulkan 侦察与本机 CPU 基线（AMD Radeon 780M）

2026-11-18，只读侦察；未改配置、未重启 Ollama。原始证据：`/tmp/vk-base-{1,2,3}.json`、`/tmp/vk-embed-{1,2}.json`。

## 1. GPU 与 Vulkan 设备

- `lspci`：`65:00.0 VGA [1002:15bf] Phoenix1 (rev c1)` → Radeon 780M 核显（UMA，共享系统内存）。
- 内核 `7.2.9-1-MANJARO`；`amdgpu` 已加载（无 `radeon`）；`/dev/dri/card1`、`/dev/dri/renderD128` 存在，render 节点为 `crw-rw-rw-`。
- Mesa `1:26.2.4-1`；`vulkan-radeon 1:26.2.4-1`；`vulkan-icd-loader 1.4.363.0`；`vulkaninfo` 实例版本 `1.4.363`。
- ICD 文件：`radeon_icd.json`、`intel_icd.json`、`intel_hasvk_icd.json`、`nouveau_icd.json`（`/usr/share/vulkan/icd.d/`）。
- **可用 Vulkan 设备只有一块硬件设备**：`deviceName = AMD Radeon 780M Graphics (RADV PHOENIX)`，`driverID = DRIVER_ID_MESA_RADV`，`driverName = radv`，`driverInfo = Mesa 26.2.4-arch1.1`，`deviceType = INTEGRATED_GPU`。`llvmpipe` 出现次数为 0。
- 交叉验证：`glxinfo -B` → `AMD Radeon 780M Graphics (radeonsi, phoenix, ACO, DRM 3.64)`。
- CPU：`AMD Ryzen 9 7940H w/ Radeon 780M`，16 线程；Ollama 报告内存 `total="62.0 GiB"`。

## 2. Ollama 现状

- 版本 `0.40.13`（`ollama` 不在 PATH；实际二进制 `/app/share/agent-zero/models/bin/ollama`，位于 Flatpak `org.agentzero.AgentZero` 沙箱）。
- 进程 `2247853 ... ollama serve`，监听 `127.0.0.1:11434`。
- 服务端环境：`OLLAMA_HOST=127.0.0.1:11434`、`OLLAMA_MODELS=/app/share/agent-zero/models/models`、`OLLAMA_MAX_LOADED_MODELS=2`、`OLLAMA_KEEP_ALIVE=30m`、`CUDA_VISIBLE_DEVICES=-1`；未设 `OLLAMA_IGPU_ENABLE`、未设 `OLLAMA_VULKAN`。
- `api/ps`：`qwen3-embedding:4b-q4_K_M size=3456148437 vram=0` → **纯 CPU（`size_vram=0`）**。
- 后端库 `/app/share/agent-zero/models/lib/ollama/`：`libggml-base.so.0.28.0`、16 个 `libggml-cpu-*.so`（含 `zen4`）、`libllama*`、`libmtmd*`，以及 **`vulkan/libggml-vulkan.so`（40.7 MB）**；无 cuda/rocm/hip 目录。
- 日志原文（`~/.var/app/org.agentzero.AgentZero/data/agent-zero/ollama.log`）：
  - `msg="dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1" id=0 library=Vulkan compute=0.0 name=Vulkan0 description="AMD Radeon 780M Graphics (RADV PHOENIX)" pci_id=0000:65:00.0`
  - `msg="user overrode visible devices" CUDA_VISIBLE_DEVICES=-1`
  - `msg="inference compute" id=cpu library=cpu compute="" name=cpu description=cpu libdirs=ollama driver="" pci_id="" type="" total="62.0 GiB" available="53.0 GiB"`
- 结论：Vulkan 后端**已加载并成功枚举到 780M**，仅因核显策略被丢弃；当前推理全走 CPU。

## 3. CPU 基线（对照）

`lfm3-omni:2b-q4_K_M`，`prompt="Hello"`、`num_predict=64`、`temperature=0`、`seed=42`；模型实际在第 10 个 token 自行结束。

| run | load_ms | prompt_ms | eval_ms | eval_count | tokens/s |
|---|---|---|---|---|---|
| 1 | 1310.9 | 82.9 | 318.4 | 10 | 31.4 |
| 2 | 0.5 | 82.3 | 300.6 | 10 | 33.3 |
| 3 | 0.8 | 84.1 | 304.0 | 10 | 32.9 |

**中位数 32.9 tokens/s**；热加载 <1 ms，prompt eval ≈83 ms。首次 `load_ms` 含模型加载，中位数不受影响。

- Embedding `qwen3-embedding:4b-q4_K_M`（dim 2560，热加载）：`0.188 s`、`0.189 s`（中位 ≈188 ms）。
- 两次测量后 `api/ps` 中 `vram` 仍为 `0`。

## 4. Vulkan 可行性判定：**可行，无需重编**

- 二进制含 `OLLAMA_VULKAN`、`Enable Vulkan support`、`discover/vulkan.go`、`parseVulkanUMA`、`libggml-vulkan.so`。
- 运行环境未设 `OLLAMA_VULKAN`，却已加载 Vulkan 并枚举设备 → 本构建**默认启用**；`OLLAMA_VULKAN` 仅为显式控制项（`serve --help` 未列出）。
- **必需**：`OLLAMA_IGPU_ENABLE=1`（核显默认被 `filterIntegratedGPUs` 丢弃，日志已明示）。
- **可选**：`GGML_VK_VISIBLE_DEVICES=0`（服务端 config 键；strings：`Set which Vulkan devices are visible by numeric ID`）。`CUDA_VISIBLE_DEVICES=-1` 可保留。
- 沙箱自带 Vulkan loader `/usr/lib/x86_64-linux-gnu/libvulkan.so.1.4.321`，宿主 `radeon_icd.json` 生效；**无需改 manifest、无需加设备权限**。

## 5. 启用步骤与预期（本次未执行，因禁止重启）

1. `flatpak/agent-zero.sh` 中 `OLLAMA_BIN serve` 前加 `export OLLAMA_IGPU_ENABLE=1`，可选 `export GGML_VK_VISIBLE_DEVICES=0`。
2. 重启 a0lite Flatpak（Ollama 是其子进程，不是独立 systemd 服务）。
3. 验证：日志出现 `inference compute id=0 library=Vulkan ...`，`api/ps` 的 `size_vram > 0`。
4. 预期：2B/4B 模型可整体 offload 到 GTT/UMA；embedding 已 188 ms，收益主要在生成吞吐与释放 CPU。
5. 回退：移除 `OLLAMA_IGPU_ENABLE` 即回 CPU；必要时 `OLLAMA_VULKAN=0`。
6. 风险：核显与 CPU 共享 62 GiB 内存，显存统计走 UMA；780M 带宽远低于独显，提升幅度须实测；Vulkan 后端成熟度低于 CUDA/ROCm，个别新架构（LFM3 多模态）可能部分算子回落。

## 6. 对 a0lite 的影响面

- `flatpak/agent-zero.sh` 已有客户端 `OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"`、`OLLAMA_MODELS`、`OLLAMA_MAX_LOADED_MODELS=2`、`OLLAMA_KEEP_ALIVE=30m`；服务端 bind 走 `A0_OLLAMA_BIND`。
- 需新增：`OLLAMA_IGPU_ENABLE=1`（必须）、`GGML_VK_VISIBLE_DEVICES=0`（单 GPU 可选）。
- 无需改 manifest：`/dev/dri` 与 Vulkan loader/ICD 在沙箱内均已可用（本次日志已实证枚举成功）。
- `usr/.env` 以 `load_dotenv(override=True)` 覆盖脚本默认；写在 `.env` 同样生效。
- 应用层无改动：a0lite 通过 `OLLAMA_HOST` 调 `/api/embed`、`/api/generate`，后端切换透明。
