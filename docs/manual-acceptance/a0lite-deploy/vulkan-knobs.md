# Vulkan 调优开关静态侦察

2026-11-18，只读侦察：flatpak `org.agentzero.AgentZero` 内 `ollama` 0.40.13（43.8 MB）、`lib/ollama/vulkan/libggml-vulkan.so`（40.7 MB，ggml 0.28.0）、宿主 Mesa 26.2.4、运行中的 `ollama serve`（pid 2275890）。`strings` 只作线索；标 `[推断]` 者未验证。

## §1 Ollama 二进制里的 OLLAMA_* / GGML_*

`strings -n 6` 命中 31 条 `OLLAMA_*`；Go 字符串表会粘连相邻常量，下表已拆分、剔除串接残留（`OLLAMA_AL`、`OLLAMA_DEBUGC`、`OLLAMA_AUTH…`、`OLLAMA_LAUNCH…`、`OLLAMA_REMOTESA`）。分类即相关性标注。

| 分类 | 变量 |
| --- | --- |
| 显存/内存 | `OLLAMA_GPU_OVERHEAD` `OLLAMA_MAX_LOADED_MODELS` `OLLAMA_KEEP_ALIVE` `OLLAMA_IGPU_ENABLE` `OLLAMA_CONTEXT_LENGTH` `OLLAMA_KV_CACHE_TYPE` `OLLAMA_FLASH_ATTENTION` `OLLAMA_MAX_TRANSFER_STREAMS` |
| 性能/并发 | `OLLAMA_NUM_PARALLEL` `OLLAMA_MAX_QUEUE` `OLLAMA_SCHED_SPREAD` `OLLAMA_LOAD_TIMEOUT` `LLAMA_ARG_FIT` `LLAMA_ARG_FIT_TARGET` |
| 后端选择 | `OLLAMA_VULKAN` `OLLAMA_LLM_LIBRARY` `OLLAMA_LIBRARY_PATH` `GGML_VK_VISIBLE_DEVICES` `GGML_BACKEND_PATH` `GGML_CUDA_INIT` `HSA_OVERRIDE_GFX_VERSION` |
| 调试 | `OLLAMA_DEBUG` `OLLAMA_DEBUG_LOG_REQUESTS` `GGML_ASSERT` `GGML_METAL_TENSOR_DISABLE` |
| 服务/云/无关 | `OLLAMA_HOST` `OLLAMA_MODELS` `OLLAMA_ORIGINS` `OLLAMA_NO_CLOUD` `OLLAMA_NOPRUNE` `OLLAMA_EXPERIMENT` `OLLAMA_CREATE_REMOTE` `OLLAMA_REMOTES` `OLLAMA_API_KEY` `OLLAMA_CLOUD_BASE_URL` `OLLAMA_CODEX_AUTO_REVIEW_MODEL` `OLLAMA_EDITOR` `OLLAMA_GO_TEMPLATE` `OLLAMA_NOHISTORY` |

`OLLAMA_VULKAN` 只在二进制里出现（尾字母为粘连噪声），`serve --help` 未列出，当前进程也没设；作用 [推断] 为后端起用开关，而日志显示本构建默认已加载 Vulkan。二进制里除 `GGML_VK_VISIBLE_DEVICES` 外没有第二个 `GGML_VK_*`——其余全在动态库中（§2）。

## §2 libggml-vulkan.so 的 GGML_VK_* 全集（34 个）

- 提交/同步：`GGML_VK_DISABLE_ASYNC` `GGML_VK_ASYNC_USE_TRANSFER_QUEUE` `GGML_VK_SERIALIZE_SUBMISSIONS` `GGML_VK_MAX_NODES_PER_SUBMIT` `GGML_VK_ALLOW_GRAPHICS_QUEUE`
- 特性开关：`GGML_VK_DISABLE_F16` `GGML_VK_DISABLE_BFLOAT16` `GGML_VK_DISABLE_COOPMAT` `GGML_VK_DISABLE_COOPMAT2` `GGML_VK_DISABLE_COOPMAT2_DECODE_VECTOR` `GGML_VK_DISABLE_DOT2` `GGML_VK_DISABLE_INTEGER_DOT_PRODUCT` `GGML_VK_DISABLE_MMVQ` `GGML_VK_FORCE_MMVQ` `GGML_VK_DISABLE_MULTI_ADD` `GGML_VK_DISABLE_FUSION` `GGML_VK_DISABLE_GRAPH_OPTIMIZE` `GGML_VK_DISABLE_DESCRIPTOR_REUSE` `GGML_VK_FA_SPARSE_DISABLE`
- 内存/分配：`GGML_VK_ALLOW_SYSMEM_FALLBACK` `GGML_VK_PREFER_HOST_MEMORY` `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM` `GGML_VK_ENABLE_MEMORY_PRIORITY` `GGML_VK_FORCE_MAX_ALLOCATION_SIZE` `GGML_VK_FORCE_MAX_BUFFER_SIZE` `GGML_VK_SUBALLOCATION_BLOCK_SIZE`
- 诊断/设备：`GGML_VK_VISIBLE_DEVICES` `GGML_VK_PERF_LOGGER` `GGML_VK_PERF_LOGGER_CONCURRENT` `GGML_VK_PERF_LOGGER_FREQUENCY` `GGML_VK_MEMORY_LOGGER` `GGML_VK_SYNC_LOGGER` `GGML_VK_DEBUG_MARKERS` `GGML_VK_PIPELINE_STATS`

## §3 Mesa / RADV

- 版本：mesa 26.2.4-1、vulkan-radeon 26.2.4-1、vulkan-icd-loader 1.4.363.0-1、libdrm 2.4.134-1；ICD 含 `radeon_icd.json`（另有 intel/nouveau）。GPU：Phoenix1 [1002:15bf]，Radeon 780M 级 iGPU，UMA 共享内存。
- `libvulkan_radeon.so` 的 `RADV_*`：`RADV_DEBUG` `RADV_PERFTEST` `RADV_EXPERIMENTAL` `RADV_FORCE_VRS` `RADV_FORCE_VRS_CONFIG_FILE` `RADV_PROFILE_PSTATE` `RADV_QUEUE_DISABLE` `RADV_TEX_ANISO` `RADV_CACHE_COUNTERS_BUFFER_SIZE` `RADV_PRINTF_BUFFER_SIZE` `RADV_BVH_STATS_FILE` `RADV_GPU_TRACEPOINT` `RADV_RRA_TRACE_*` `RADV_SPM_COUNTERS_CONFIG` `RADV_THREAD_TRACE_*` `RADV_TRAP_HANDLER`；后两类只用于 trace/profiling。
- `MESA_*` 只有调试与磁盘缓存（`MESA_DEBUG` `MESA_LOG` `MESA_GLSL_CACHE_*` `MESA_DISK_CACHE_*`），与计算吞吐无关；`AMD_*` 是 Mesa 内部调试/测试开关（`AMD_PARSE_IB` `AMD_PRIORITY` `AMD_USERQ` 等）。
- 关键事实：`libggml-vulkan.so` 里没有任何 `RADV_`/`MESA_` 字符串，这些只能由 Mesa 自己读取，Ollama 不转发。[推断] 对 tps 可能有关的是 `RADV_DEBUG`/`RADV_PERFTEST`/`RADV_EXPERIMENTAL`，合法取值未在二进制中枚举。

## §4 当前 `ollama serve` 进程的实际环境（pid 2275890）

```
CUDA_VISIBLE_DEVICES=-1
GGML_VK_VISIBLE_DEVICES=0
LD_LIBRARY_PATH=/app/lib/gi:/app/share/agent-zero/cuda/cuda_v12:/app/share/agent-zero/cuda/cuda_v13:/app/share/agent-zero/models/lib/ollama
OLLAMA_HOST=127.0.0.1:11434
OLLAMA_IGPU_ENABLE=1
OLLAMA_KEEP_ALIVE=30m
OLLAMA_MAX_LOADED_MODELS=2
OLLAMA_MODELS=/app/share/agent-zero/models/models
_=/app/share/agent-zero/models/bin/ollama
```

共 164 个环境变量；命令行 `/app/share/agent-zero/models/bin/ollama serve`。关键缺口：没有任何 `GGML_VK_*` 性能开关，也没设 `OLLAMA_FLASH_ATTENTION`/`OLLAMA_KV_CACHE_TYPE`/`OLLAMA_NUM_PARALLEL`/`OLLAMA_CONTEXT_LENGTH`/`OLLAMA_GPU_OVERHEAD`。

## §5 候选清单（按可能影响 tps 排序，前 12）

多数 `GGML_VK_DISABLE_*` 默认关闭（即优化默认开启）；排在前面的正反向都值得 A/B。

| # | 变量 | 推测作用 | 生效时机 |
| --- | --- | --- | --- |
| 1 | `GGML_VK_DISABLE_MMVQ` / `GGML_VK_FORCE_MMVQ` | decode 主循环的矩阵向量乘路径，命中与否差异可达数十 % [推断] | 启动前 |
| 2 | `GGML_VK_DISABLE_COOPMAT2` / `GGML_VK_DISABLE_DOT2` / `GGML_VK_DISABLE_INTEGER_DOT_PRODUCT` | RDNA 协作矩阵/点积指令路径；gfx1103 支持度决定默认值 [推断] | 启动前 |
| 3 | `OLLAMA_FLASH_ATTENTION` | FA kernel 减少 KV 读写，长上下文收益最大 [推断] | 启动前（serve 级） |
| 4 | `OLLAMA_KV_CACHE_TYPE` | KV 量化 f16→q8_0/q4_0 直接降带宽，iGPU 带宽是瓶颈 [推断] | 启动前 |
| 5 | `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM` / `GGML_VK_PREFER_HOST_MEMORY` | buffer 落在 host-visible 还是 device-local；UMA 下同一块内存，路径差异影响映射与零拷贝 [推断] | 启动前 |
| 6 | `GGML_VK_ALLOW_SYSMEM_FALLBACK` | 显存不足时回落系统内存，避免整层卸到 CPU [推断] | 启动前 |
| 7 | `GGML_VK_DISABLE_ASYNC` / `GGML_VK_ASYNC_USE_TRANSFER_QUEUE` | compute/transfer 异步重叠，UMA 带宽下未必有利 [推断] | 启动前 |
| 8 | `GGML_VK_MAX_NODES_PER_SUBMIT` / `GGML_VK_SERIALIZE_SUBMISSIONS` | 提交粒度与串行化，影响同步开销与首 token 延迟 [推断] | 启动前 |
| 9 | `OLLAMA_NUM_PARALLEL` / `OLLAMA_MAX_LOADED_MODELS` | 并发槽位切分（每槽一份 KV）；单流不变，并发时此消彼长 [推断] | 启动前 |
| 10 | `GGML_VK_SUBALLOCATION_BLOCK_SIZE` / `GGML_VK_FORCE_MAX_ALLOCATION_SIZE` | 分配器块大小/单次上限；主要影响 load 与峰值内存，tps 间接 [推断] | 启动前 |
| 11 | `GGML_VK_DISABLE_FUSION` / `GGML_VK_DISABLE_GRAPH_OPTIMIZE` | 关融合/图优化通常变慢，作 A/B 反向验证驱动 bug [推断] | 启动前 |
| 12 | `RADV_PERFTEST` / `RADV_DEBUG` / `RADV_EXPERIMENTAL` | 驱动实验特性，可能影响 compute 队列与调度 [推断] | 启动 Ollama 前（Mesa 在进程启动时读） |

`GGML_VK_PERF_LOGGER=1`、`GGML_VK_MEMORY_LOGGER=1` 不提速，但能给出每 kernel/分配的耗时，建议与实测同时开。[推断]

## §6 推断与未验证项

- 变量语义均由名字 + 上游 llama.cpp 常识得出 [推断]；本次未跑 benchmark、未改环境、未重启进程。
- 「启动前设置」也是 [推断]：后端在库初始化/模型加载时读 env，`ollama serve` 无重载入口，故一律按「重启 serve 才生效」处理。
- `OLLAMA_VULKAN` 语义、RADV 变量合法取值、`GGML_VK_*` 各开关在本机 gfx1103 上的真实效果，全是 [推断]，需实测确认。
- §5 排序依据是 iGPU + Vulkan + 7B 级量化模型的先验，不代表本机实测结果。
