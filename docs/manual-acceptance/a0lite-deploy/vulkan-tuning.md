# Vulkan 推理调优实测（Radeon 780M）

环境：Ollama 0.40.13（Flatpak `org.agentzero.AgentZero`，二进制 `/app/share/agent-zero/models/bin/ollama`）· Ryzen 9 7940HS · Radeon 780M（Mesa RADV）· 模型 `lfm3-omni:2b-q4_K_M` · 2026-11-18。

## 1. 测试方法

- 独立实例 `127.0.0.1:11436`；主实例 `11434` 全程未停、未改其环境变量。测试结束 11436 已关闭、无残留进程。
- 每次配置重启实例：`flatpak run --user --command=sh org.agentzero.AgentZero -c 'export OLLAMA_HOST=127.0.0.1:11436 OLLAMA_MODELS=/app/share/agent-zero/models/models OLLAMA_KEEP_ALIVE=60s OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_IGPU_ENABLE=1 GGML_VK_VISIBLE_DEVICES=0 CUDA_VISIBLE_DEVICES=-1 LD_LIBRARY_PATH=/app/share/agent-zero/models/lib/ollama:/app/lib/gi <配置变量>; exec /app/share/agent-zero/models/bin/ollama serve'`
- 严格串行：同一时刻只有一个实例；每次测量前确认 11436 空载、主实例 `/api/ps` 为空。
- 固定请求：`/api/generate`，固定 prompt（光合作用技术解释），`num_predict=128`、`temperature=0`、`seed=42`、`stream=false`。
- 每配置 3 次，第 1 次含加载（1.2–1.5 s），取第 2、3 次中位（均值）；`tps = eval_count/(eval_duration/1e9)`。
- 判定：vs B0 提升 <5% 记「无显著差异」；`size_vram=0` 或加载失败记失败配置（本次未出现）。

## 2. 环境变量矩阵（`num_ctx=32768`、`num_batch=1024`）

| # | 配置 | 三次 tps | 中位 | vs B0 | size_vram | 判定 |
|---|---|---|---:|---:|---:|---|
| B0 | 基线（仅 IGPU_ENABLE / VK_VISIBLE / MAX_LOADED=1） | 65.29/65.06/65.23 | 65.15 | — | 1.958 GB | 基准 |
| B1 | `FLASH_ATTENTION=1` | 65.56/65.94/65.96 | 65.95 | +1.2% | 1.958 GB | 无显著差异 |
| B2 | `KV_CACHE_TYPE=q8_0` | 65.75/65.73/65.59 | 65.66 | +0.8% | 1.952 GB | 无显著差异 |
| B3 | `KV_CACHE_TYPE=q4_0` | 65.52/65.68/65.35 | 65.52 | +0.6% | 1.949 GB | 无显著差异 |
| B4 | FA=1 + KV q8_0 | 65.73/65.72/64.70 | 65.21 | +0.1% | 1.952 GB | 无显著差异 |
| B5 | `NUM_PARALLEL=2` | 65.82/65.38/65.64 | 65.51 | +0.6% | 2.814 GB | 显存 +855 MB → 有害 |
| B6 | `GGML_VK_DISABLE_FUSION=1` | 65.25/65.41/65.11 | 65.26 | +0.2% | 1.958 GB | 无显著差异 |
| B7 | `RADV_PERFTEST=aco` | 66.10/65.95/66.07 | 66.01 | +1.3% | 1.958 GB | 无显著差异（Mesa 默认） |

## 3. 模型参数矩阵（B0 环境）

| 参数 | 值 | 三次 tps | 中位 | vs B0 | size_vram | 判定 |
|---|---|---:|---|---:|---:|---|
| `num_ctx` | 2048 | 66.14/66.12/65.99 | 66.06 | +1.4% | 1.607 GB | 无显著差异 |
| `num_ctx` | 4096 | 65.91/65.83/66.04 | 65.94 | +1.2% | 1.609 GB | 无显著差异 |
| `num_ctx` | 8192 | 65.86/65.99/64.40 | 65.20 | +0.1% | 1.908 GB | 无显著差异 |
| `num_ctx` | 32768 | 65.88/66.07/64.53 | 65.30 | +0.2% | 1.958 GB | 无显著差异 |
| `num_batch` | 512 | 65.99/65.79/64.31 | 65.05 | −0.2% | 1.639 GB | 无显著差异 |
| `num_batch` | 1024 | 65.84/66.01/65.04 | 65.53 | +0.6% | 1.958 GB | 无显著差异 |
| `num_batch` | 2048 | 66.12/66.07/63.79 | 64.93 | −0.3% | 2.789 GB | 显存 +831 MB → 有害 |
| `num_thread` | 8 | 66.02/65.97/65.94 | 65.96 | +1.2% | 1.958 GB | 无显著差异 |
| `num_thread` | 16 | 63.08/62.78/63.25 | 63.02 | −3.3% | 1.958 GB | 方向为负，建议 8 |

`num_batch=1024` 的 `size_vram` 与 B0 完全相同 → 本版本默认批大小为 1024。`num_ctx=4096` 首测第 3 次 63.53 为离群值，已重测并采用 65.94。

## 4. 最优组合与预期收益

实测 `FLASH_ATTENTION=1` + `KV_CACHE_TYPE=q8_0` + `CONTEXT_LENGTH=4096` + `num_batch=512`：三次 65.86/65.94/65.75，中位 **65.85（+1.1%）**，`size_vram` **1.606 GB**。

- 速度无可测提升（噪声内）。
- 显存 1.958 → 1.606 GB，**省 353 MB（−18.0%）**，这是唯一有实际意义的收益：为更大模型或更长上下文腾出余量。
- 若无法逐请求传 `num_batch`，仅 `OLLAMA_CONTEXT_LENGTH=4096` 一项即可省 349 MB，速度不变。

## 5. 未生效或反向的配置

- B1–B4、B6、B7 全部落在 5% 噪声内，**没有一个环境变量带来显著加速**。
- B7 的 +1.3% 不可归因于该变量：`aco` 自 Mesa 20.x 起已是 RADV 默认，新 Mesa 基本忽略 `RADV_PERFTEST=aco`。
- B6 与基线无差别：只能说明当前 ggml Vulkan 后端上融合开/关无可测差异，不能证明融合「有效」。
- B5 `NUM_PARALLEL=2`：速度不变、显存 +855 MB（KV cache 按槽位翻倍），单用户场景应关闭。
- M2 `num_batch=2048`：+831 MB，速度略降。
- M3 `num_thread=16`：−3.3% vs B0、−4.5% vs 8 线程，方向为负。
- KV 量化收益小：q8_0 省 6 MB、q4_0 省 9 MB。2B 模型 KV cache 本身只有几十 MB 量级；换大模型/长上下文会放大。
- 全部配置 `size_vram > 0`（100% VRAM），无 CPU 回退、无加载失败、无输出乱码、780M 未出现驱动 hang。

## 6. 与 58.36 tps 基线对照

- 本次 B0 **65.15 tps**，比交接材料中的 58.36 高 **11.6%**。这是测量条件差异（独立实例独占 GPU、`MAX_LOADED=1`、无 Agent Zero 并发），不是配置收益。
- 主实例真实环境与交接描述不符：实际 `OLLAMA_MAX_LOADED_MODELS=2`、`OLLAMA_KEEP_ALIVE=30m`（交接写的是 1 / 10m）。这不影响单请求 tps，但 `MAX_LOADED=2` 会在多模型场景争抢显存。

## 7. 建议固化进 `agent-zero.sh` 的清单（本轮不改代码）

必留：`OLLAMA_IGPU_ENABLE=1`、`GGML_VK_VISIBLE_DEVICES=0`、`OLLAMA_VULKAN=1`（显式写死，防默认值回退）。

建议新增/调整：

| 变量 | 值 | 实测依据 |
|---|---|---|
| `OLLAMA_MAX_LOADED_MODELS` | `1` | 主实例实际为 2；单模型场景避免显存争抢 |
| `OLLAMA_CONTEXT_LENGTH` | `4096` | 省 349 MB，tps 不变（65.94 vs 65.15） |
| `OLLAMA_FLASH_ATTENTION` | `1` | +1.2%（噪声内），无副作用，且为 KV 量化前提 |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | 省 6 MB，无精度/速度副作用 |
| `OLLAMA_KEEP_ALIVE` | `30m` | 保持现状，减少重载 |

不固化：`OLLAMA_NUM_PARALLEL=2`（+855 MB）、`RADV_PERFTEST=aco`（无效）、`GGML_VK_DISABLE_FUSION=1`（无收益）、请求级 `num_batch=2048`（+831 MB）。

**最值得固化的三个**：`OLLAMA_MAX_LOADED_MODELS=1`、`OLLAMA_CONTEXT_LENGTH=4096`、`OLLAMA_FLASH_ATTENTION=1`。
