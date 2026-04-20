# Vast Clean Anchor MultiTalk Rebuild

这份文档只服务一件事：在母机不可用时，把已经验证过的 `clean-anchor-multitalk` 工作流重新拉起来。

## 当前已固化资产

- 工作流 JSON:
  - [workflow_api_24g_pruned.json](D:\code\DaiMa\happy_dev\codex\output\vast-clean-anchor-multitalk-24g\workflow_api_24g_pruned.json)
  - [workflow_api_24g.json](D:\code\DaiMa\happy_dev\codex\output\vast-clean-anchor-multitalk-24g\workflow_api_24g.json)
- 依赖清单:
  - [requirements_manifest.json](D:\code\DaiMa\happy_dev\codex\output\vast-clean-anchor-multitalk-24g\requirements_manifest.json)
- 重建脚本:
  - [rebuild_comfy_env.sh](D:\code\DaiMa\happy_dev\codex\output\vast-clean-anchor-multitalk-24g\rebuild_comfy_env.sh)
  - [download_models.sh](D:\code\DaiMa\happy_dev\codex\output\vast-clean-anchor-multitalk-24g\download_models.sh)
  - [bootstrap_wan21_clean_anchor.sh](D:\code\DaiMa\happy_dev\codex\output\vast-clean-anchor-multitalk-24g\bootstrap_wan21_clean_anchor.sh)
- 已验证成片:
  - [vast_clean_anchor_multitalk_24g_00001-audio.mp4](D:\code\DaiMa\happy_dev\codex\output\vast-clean-anchor-multitalk-24g-result\vast_clean_anchor_multitalk_24g_00001-audio.mp4)
- 总方案记录:
  - [workflow-combos.md](D:\code\DaiMa\happy_dev\codex\docs\workflow-combos.md)

## 环境基线

从现有 Vast 记录和启动日志能确定的基线：

- Vast 基础镜像: `vastai/comfy:v0.19.3-cuda-12.9-py312`
- ComfyUI version: `0.7.0`
- ComfyUI frontend version: `1.35.9`
- ComfyUI revision: `4449 [f59f71cf]`

对应证据：

- [vast-comfy-instance-35259906.json](D:\code\DaiMa\happy_dev\codex\output\vast-comfy-instance-35259906.json)
- [vast-a100-40g-logs-after-accelerate.txt](D:\code\DaiMa\happy_dev\codex\output\vast-a100-40g-logs-after-accelerate.txt)

## 这条工作流真正依赖的自定义节点

只需要这两个包，不需要整台母机：

1. `ComfyUI-WanVideoWrapper`
2. `ComfyUI-VideoHelperSuite`

本地留存源码位置：

- [ComfyUI-WanVideoWrapper](D:\code\DaiMa\happy_dev\codex\output\vast-node-bundles\src\ComfyUI-WanVideoWrapper)
- [ComfyUI-VideoHelperSuite](D:\code\DaiMa\happy_dev\codex\output\vast-node-bundles\src\ComfyUI-VideoHelperSuite)

## Python 依赖

### ComfyUI-WanVideoWrapper

- `accelerate>=1.2.1`
- `diffusers>=0.33.0`
- `einops`
- `ftfy`
- `gguf>=0.17.1`
- `opencv-python`
- `peft>=0.17.0`
- `protobuf`
- `pyloudnorm`
- `scipy`
- `sentencepiece>=0.2.0`

### ComfyUI-VideoHelperSuite

- `opencv-python`
- `imageio-ffmpeg`

### ComfyUI 主仓库依赖

- 切到 `f59f71cf` 这类新版本后，必须额外执行：
  - `python3 -m pip install -r "$COMFY_ROOT/requirements.txt"`

否则会出现这些问题：

- `No module named 'pydantic_settings'`
- `No module named 'alembic'`
- `comfyui-workflow-templates is not installed`
- `comfyui-embedded-docs package not found`

额外说明：

- 之前确实踩过一次缺依赖，报错是 `No module named 'accelerate'`
- 证据在 [vast-a100-40g-logs-after-accelerate.txt](D:\code\DaiMa\happy_dev\codex\output\vast-a100-40g-logs-after-accelerate.txt)

## 模型文件与目录

下面这些不是猜的，是从当前 workflow JSON 和节点源码一起反推出的。

### `ComfyUI/models/vae`

- `wan_2.1_vae.safetensors`

依据：

- `WanVideoVAELoader` 从 `models/vae` 读取
- 代码位置: [nodes_model_loading.py](D:\code\DaiMa\happy_dev\codex\output\vast-node-bundles\src\ComfyUI-WanVideoWrapper\nodes_model_loading.py)

### `ComfyUI/models/text_encoders`

- `umt5-xxl-enc-bf16.safetensors`

依据：

- `LoadWanVideoT5TextEncoder` 从 `models/text_encoders` 读取
- 代码位置: [nodes_model_loading.py](D:\code\DaiMa\happy_dev\codex\output\vast-node-bundles\src\ComfyUI-WanVideoWrapper\nodes_model_loading.py)

### `ComfyUI/models/diffusion_models`

- `Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors`
- `WanVideo_2_1_Multitalk_14B_fp8_e4m3fn.safetensors`

依据：

- `WanVideoModelLoader` 从 `models/diffusion_models` 读取
- `MultiTalkModelLoader` 从 `models/diffusion_models` 读取
- 代码位置:
  - [nodes_model_loading.py](D:\code\DaiMa\happy_dev\codex\output\vast-node-bundles\src\ComfyUI-WanVideoWrapper\nodes_model_loading.py)
  - [multitalk/nodes.py](D:\code\DaiMa\happy_dev\codex\output\vast-node-bundles\src\ComfyUI-WanVideoWrapper\multitalk\nodes.py)

### `ComfyUI/models/loras`

- `Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors`

说明：

- `WanVideoLoraSelect` 这颗节点在这条 workflow 里引用的也是 `Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors`
- 实测这次远端重建时，ComfyUI 节点校验只接受 `models/loras`
- 放在 `diffusion_models` 会直接报 `Value not in list`

### `ComfyUI/models/controlnet`

- `Wan21_Uni3C_controlnet_fp16.safetensors`

依据：

- `WanVideoUni3C_ControlnetLoader` 从 `models/controlnet` 读取
- 代码位置: [uni3c/nodes.py](D:\code\DaiMa\happy_dev\codex\output\vast-node-bundles\src\ComfyUI-WanVideoWrapper\uni3c\nodes.py)

### `ComfyUI/models/clip_vision`

- `clip_vision_h.safetensors`

依据：

- 这是 ComfyUI 核心 `CLIPVisionLoader` 使用的标准目录

### `ComfyUI/models/transformers`

- `TencentGameMate/chinese-wav2vec2-base`

依据：

- `DownloadAndLoadWav2VecModel` 会把 HuggingFace repo 下载到 `models/transformers/<repo-id>`
- 代码位置: [fantasytalking/nodes.py](D:\code\DaiMa\happy_dev\codex\output\vast-node-bundles\src\ComfyUI-WanVideoWrapper\fantasytalking\nodes.py)

## 输入素材

这条 workflow 的最小输入只有两个：

- `clean-anchor-image.png`
- `clean-anchor-audio.wav`

在新机上放到 ComfyUI 可读取的位置后，再按 workflow 对应的文件输入节点改名或上传。

## 重建顺序

1. 起一台 Vast/AutoDL/Vast 同级别新机器
2. 使用 `vastai/comfy:v0.19.3-cuda-12.9-py312` 或尽量接近的 ComfyUI 基础环境
3. 放入两个 custom nodes：
   - `ComfyUI-WanVideoWrapper`
   - `ComfyUI-VideoHelperSuite`
4. 安装上面列出的 Python 依赖
5. 把模型文件按目录放好
6. 导入 [workflow_api_24g_pruned.json](D:\code\DaiMa\happy_dev\codex\output\vast-clean-anchor-multitalk-24g\workflow_api_24g_pruned.json)
7. 上传 `clean-anchor-image.png` 和 `clean-anchor-audio.wav`
8. 先跑一次最小验证，再跑正式任务

最快执行入口：

```bash
cd /path/to/vast-clean-anchor-multitalk-24g
bash bootstrap_wan21_clean_anchor.sh
```

它会顺序完成：

1. 安装 custom nodes 和 Python 依赖
2. 下载 Wan 2.1 / MultiTalk 模型
3. 创建 `ComfyUI/input`
4. 提醒放入 `clean-anchor-image.png` 和 `clean-anchor-audio.wav`

## 当前结论

现在最重要的已经不是“母机能不能复活”，而是：

- workflow 已经保存了
- 成片已经保存了
- 自定义节点源码已经保存了
- 模型名和目录已经抽出来了
- pip 依赖已经抽出来了

所以后面即使母机彻底不可用，也不是从零开始，而是按这份文档重建环境。
