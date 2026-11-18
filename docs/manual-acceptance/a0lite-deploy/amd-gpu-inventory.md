# AMD Radeon 780M 加速路径清点
采集：2026-11-18 09:49 CST，kunweiz，只读。内核 7.2.9-1-MANJARO，内存 62 GiB。

## §1 硬件
| 项 | 值 |
|---|---|
| CPU | AMD Ryzen 9 7940HS w/ Radeon 780M Graphics（16 线程，zen4） |
| GPU | Phoenix1 [1002:15bf] Radeon 780M（gfx1103 核显），共享内存约 32 GiB 可分配 |
| DRM | /dev/dri/card1、/dev/dri/renderD128；amdgpu 已加载 |

## §2 Vulkan 设备表
`vulkaninfo --summary`（instance 1.4.363）只枚举到 1 个物理设备：

| # | deviceName | driverName / driverVersion | deviceType | apiVersion |
|---|---|---|---|---|
| GPU0 | AMD Radeon 780M Graphics (RADV PHOENIX) | radv / 26.2.4（Mesa 26.2.4-arch1.1） | INTEGRATED_GPU | 1.4.354 |

- 无 llvmpipe 条目；ICD：/usr/share/vulkan/icd.d/radeon_icd.json → libvulkan_radeon.so
- llama.cpp 同样识别为 `Vulkan0: AMD Radeon 780M Graphics (RADV PHOENIX)`

## §3 ROCm 可用性
- rocminfo、rocm-smi 不存在；/opt/rocm 不存在；pacman 无 rocm/hip 包；仅 ocl-icd 2.3.5-1（无 AMD OpenCL 驱动）。
- 结论：ROCm 未安装、当前不可用。gfx1103 不受 ROCm 官方完整支持；若安装通常需 HSA_OVERRIDE_GFX_VERSION=11.0.0 伪装 gfx1100，仍无保证。

## §4 Ollama 后端库
- Ollama 0.40.13（Agent Zero Flatpak 自带，非 pacman），监听 127.0.0.1:11434。
- 后端目录 /app/share/agent-zero/models/lib/ollama/（宿主经 /proc/<pid>/root 只读可见）：
  - CPU：libggml-cpu-*.so（含 zen4）、libggml-base.so.0.28.0、libggml.so.0.28.0
  - Vulkan：vulkan/libggml-vulkan.so（40 MB）存在
- 日志：探测到 Vulkan0 780M，但 `dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1` → 当前 library=cpu。
- 运行中的 llama-server 仅映射 libggml-cpu-zen4.so，size_vram=0（qwen3-embedding:4b 全在内存）。
- 旁路：~/Desktop/atomic-llama-cpp-turboquant/build/bin/libggml-vulkan.so.0.18.1 存在，但 llama-server --list-devices 报 `failed to find ggml_backend_init`（ABI 不匹配，暂不可用）。

## §5 结论
| 路径 | 可行性 | 前置条件 |
|---|---|---|
| Vulkan + Ollama | 最可行 | 设 OLLAMA_IGPU_ENABLE=1 并重启 ollama（本次未执行）；后端与 RADV 26.2.4 均已就绪 |
| Vulkan + llama.cpp | 修复后可用 | 清理/重链旧 libggml-vulkan.so，与主程序 ABI 对齐 |
| ROCm | 不可行 | 需装 ROCm 且 gfx1103 override；核显无官方支持 |
| CPU | 已生效 | 无；zen4 后端，embedding 可用，生成慢 |

建议：保留 CPU 基线；唯一低风险提速点是给 Ollama 开 iGPU Vulkan。

## §6 Vulkan 隔离实验（2026-11-18 09:50–09:53）

- 方法：测试实例 `127.0.0.1:11435`，`OLLAMA_IGPU_ENABLE=1`，独立 `OLLAMA_MODELS`（软链主实例 blobs）；主实例 11434 未停。
- 模型 `lfm3-omni:2b-q4_K_M`，prompt `Hello`，`num_predict=64`，每组 3 次（均 eval_count=10，模型自然停止）。

| 组 | 端口 | 环境 | size_vram | tps 1/2/3 | 中位数 |
|---|---|---|---|---|---|
| A 基线 | 11434 | 默认（丢核显） | 0 / 0 / 0 | 32.27 / 31.52 / 33.92 | 32.27 |
| B 实验 | 11435 | OLLAMA_IGPU_ENABLE=1 | 1958341507（3 次同值） | 44.10 / 41.73 / 42.75 | 42.75 |

- 首载：B1 load_ms=2207，B2/B3 ≈0.7 ms；A 组 ≈0.5 ms（模型已驻留）。
- 加速比（中位数）：42.75 / 32.27 = **1.32×**（约 +32%）。

B 组日志原文：
```
inference compute ... library=Vulkan ... name=Vulkan0 description="AMD Radeon 780M Graphics (RADV PHOENIX)" ... type=iGPU
load_backend: loaded Vulkan backend from /app/share/agent-zero/models/lib/ollama/vulkan/libggml-vulkan.so
load_tensors: Vulkan0 model buffer size = 1040.82 MiB
llama_kv_cache: Vulkan0 KV buffer size = 384.00 MiB
clip_ctx: CLIP using Vulkan0 backend
```

- `llama-server` 映射含 `vulkan/libggml-vulkan.so` 与 `libvulkan_radeon.so`，与日志一致。
- 判定：**Vulkan 真正接管**（size_vram ≈1.82 GiB > 0），加速 1.32×；无失败项。
- B 组 `size` 比 A 大约 328 MiB（Vulkan compute/KV buffer），符合预期。
- 清理：测试实例已停，11435 关闭，主实例 11434 仍 200；日志留证于
  `~/.var/app/org.agentzero.AgentZero/data/agent-zero/vk-ollama.log`。
