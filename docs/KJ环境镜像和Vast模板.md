# KJ 环境镜像和 Vast 模板

## 目标

为 `wan22_kj_30s` 和 `wan22_kj_30s_segmented` 增加一个实验启动策略：

- Docker 镜像固化 ComfyUI 基础环境、KJ custom nodes 和 Python 依赖。
- Vast private template 固化镜像、端口、基础环境变量和搜索过滤。
- 模型权重暂不进入镜像，继续通过 HuggingFace speed gate 和机器库控制成本。

这个方案不使用 Vast volume。volume 会持续付费，并且绑定物理机器，不适合作为跨机器主线缓存。

## 当前实现

- Dockerfile：`docker/wan22-kj-comfy-env/Dockerfile`
- 安装脚本：`docker/wan22-kj-comfy-env/install-kj-env.sh`
- GitHub Actions：`.github/workflows/build-wan22-kj-env-image.yml`
- 本地构建脚本：`scripts/build_wan22_kj_env_image.ps1`
- GitHub Actions secret helper：`scripts/bootstrap_github_actions_dockerhub.ps1`，仅 DockerHub 构建路径需要
- workflow dispatch helper：`scripts/dispatch_github_actions_workflow.ps1`
- Vast template helper：`scripts/create_vast_wan22_kj_env_template.ps1`

默认镜像名：

```text
j1c2k3/codex-wan22-kj-comfy:cuda129-py312-kj-v3
```

## 不放进镜像的内容

- Wan/KJ 模型权重
- 输入素材
- API key
- 用户视频输出
- Vast volume 挂载配置

原因：模型很大，把它们放进镜像可能只是把 HuggingFace 下载慢变成 Docker 镜像拉取慢。第一阶段只验证“少装环境”。

## 构建镜像

本地有 Docker 时：

```powershell
pwsh -File .\scripts\build_wan22_kj_env_image.ps1 -Push
```

当前 Windows 控制机没有 Docker CLI 时，走 GitHub Actions：

```powershell
pwsh -File .\scripts\dispatch_github_actions_workflow.ps1 `
  -Workflow build-wan22-kj-env-image.yml `
  -Inputs @{ registry = "ghcr"; image_name = "codex-wan22-kj-comfy"; image_tag = "cuda129-py312-kj-v3" }

pwsh -File .\scripts\watch_github_actions_workflow.ps1 `
  -Workflow build-wan22-kj-env-image.yml
```

如果明确要推 DockerHub，再先执行：

```powershell
pwsh -File .\scripts\bootstrap_github_actions_dockerhub.ps1
```

密钥读取规则：

- 先读 `.env`
- 再读 `api.txt`
- 当前默认走 DockerHub v3，因为 GHCR v3 在本地/Vast 拉取侧需要 `read:packages`，当前本地 GitHub token scopes 只有 `gist, repo, workflow`，manifest 检查会返回 `401`。
- `DockerHub` 对应 DockerHub token。
- `DockerHub Username` 对应 DockerHub 用户名。

## 创建 Vast template

镜像推送成功后创建 Vast template：

```powershell
pwsh -File .\scripts\create_vast_wan22_kj_env_template.ps1 `
  -TemplateName codex-wan22-kj-comfy-cuda129 `
  -Image j1c2k3/codex-wan22-kj-comfy:cuda129-py312-kj-v3
```

如果 DockerHub 仓库需要登录，template 仍可创建，但真正拉镜像的私有登录要在创建实例时传入：

```powershell
pwsh -File .\scripts\create_vast_wan22_kj_env_template.ps1 `
  -TemplateName codex-wan22-kj-comfy-cuda129 `
  -Image j1c2k3/codex-wan22-kj-comfy:cuda129-py312-kj-v3
```

后续 launch 时加：

```powershell
-PrivateRegistryLogin -RegistryHost docker.io -RegistryUsername j1c2k3
```

`RegistryToken` 默认从 `.env` / `api.txt` 的 GitHub token 读取，不要把 token 写进命令行。实例创建脚本会对命令输出做脱敏。

创建后记录返回的 `template_hash_id`，然后设置：

```powershell
$env:VAST_WAN22_KJ_TEMPLATE_HASH = "<template_hash_id>"
```

当前 v2 template：

```text
template_hash_id=3f38ca38792bcefce25bb1688f4ca2ca
template_id=400059
image=ghcr.io/myjr2015/codex-wan22-kj-comfy:cuda129-py312-kj-v2
status=failed_for_onnx_cuda_provider
reason=v2 only passed ComfyUI node registration; later KJ preprocessing fell back to CPU because ONNXRuntime CUDA provider could not load libcublasLt.so.12.
```

当前 v3 目标镜像：

```text
image=j1c2k3/codex-wan22-kj-comfy:cuda129-py312-kj-v3
template_hash_id=eb3ff9185d9de9a9482c2cffbdfd8f9f
template_id=400607
status=onnx_cuda_smoke_passed
validated_job=kj30s-v3-dhub-4090-onnxfix-20260502-0020
```

## 运行方式

单段 30s：

```powershell
pwsh -File .\scripts\run_wan22_kj_30s_end_to_end.ps1 `
  -JobName <job_name> `
  -RuntimeVersion 1.2-docker-env-template `
  -VastTemplateHash <template_hash_id>
```

分段 30s+30s：

```powershell
pwsh -File .\scripts\run_wan22_kj_30s_segmented_end_to_end.ps1 `
  -JobName <job_name> `
  -RuntimeVersion 1.2-docker-env-template `
  -VastTemplateHash <template_hash_id>
```

## 预期收益

- 省掉大部分 custom node clone / requirements 安装时间。
- 降低 Python 依赖漂移导致的启动失败概率。
- 减少 torch 重装概率：bootstrap 以 `torch + CUDA>=12.4 + GPU 可用` 作为硬条件，缺 `torchvision` / `torchaudio` 时优先按当前 torch 版本和当前 torch CUDA 后缀补装辅助包；如果上游没有对应 wheel，默认警告后继续，不触发整套 torch force reinstall。
- v3 额外强制验证 ONNXRuntime CUDA provider：安装 `onnxruntime-gpu[cuda,cudnn]`，写入 Python NVIDIA runtime 库路径，验证 `CUDAExecutionProvider`、`libcublasLt.so.12`、`libcudnn.so.9`、`libcudart.so.12`，并用 tiny ONNX Identity 模型创建 CUDA session 跑一次推理。
- 模型下载默认 `3` 路并行，最多 `4` 路；每个模型先写入 `.part` 临时文件，curl 使用断点续传，下载成功后再 `mv` 到目标文件，任一模型失败则 bootstrap 失败。
- 不直接减少 HuggingFace 模型下载时间。
- 不改变 KJ 推理时间。

第一版验收标准：

- Vast template 能启动实例。
- ComfyUI `8188` 能映射。
- bootstrap 日志出现 `preinstalled KJ custom nodes are ready`。
- HF speed gate 仍正常执行。
- workflow 能进入模型下载或缓存检查阶段。
- `RemoteStopAfter=onnx_cuda` 能在模型下载前验证 ONNXRuntime CUDA provider，失败必须停止，不允许退回 CPU 前处理。

## Smoke 验证

验证 template 启动速度时，不要完整提交 30s 推理。v3 先跑 ONNX CUDA smoke，让远端停在模型下载前：

```powershell
pwsh -File .\scripts\launch_wan22_kj_30s_vast_job.ps1 `
  -JobName <job_name> `
  -OfferId <offer_id> `
  -TemplateHash <template_hash_id> `
  -PrivateRegistryLogin `
  -RegistryHost docker.io `
  -RegistryUsername j1c2k3 `
  -ModelDownloadParallelism 3 `
  -RemoteStopAfter onnx_cuda
```

该模式只验证：

1. 镜像能拉起。
2. HF speed gate 能执行。
3. bootstrap 能复用/安装 ONNXRuntime GPU 依赖。
4. `onnxruntime` 能以 `CUDAExecutionProvider` 创建 tiny session 并完成一次推理。
5. 停止在模型下载和 `/prompt` 之前。

节点完整校验再使用：

```powershell
pwsh -File .\scripts\launch_wan22_kj_30s_vast_job.ps1 `
  -JobName <job_name> `
  -OfferId <offer_id> `
  -TemplateHash <template_hash_id> `
  -PrivateRegistryLogin `
  -RegistryHost docker.io `
  -RegistryUsername j1c2k3 `
  -ModelDownloadParallelism 3 `
  -RemoteStopAfter validate_nodes
```

该模式会执行：

1. 下载 R2 中的 workflow / 输入素材 / bootstrap 脚本。
2. 执行 HF speed gate。
3. 执行 bootstrap，验证镜像内 KJ custom nodes 是否可复用。
4. 重启 ComfyUI，等待 `8188` API 可用。
5. 校验 KJ workflow 所需节点存在。
6. 停止在提交 `/prompt` 之前，避免烧完整推理费用。
