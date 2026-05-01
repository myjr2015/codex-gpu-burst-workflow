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
ghcr.io/myjr2015/codex-wan22-kj-comfy:cuda129-py312-kj-v1
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
  -Inputs @{ registry = "ghcr"; image_name = "codex-wan22-kj-comfy"; image_tag = "cuda129-py312-kj-v1" }

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
- GHCR 默认使用 GitHub Actions 内置 `GITHUB_TOKEN`，不需要 DockerHub 用户名。
- `DockerHub` 对应 DockerHub token，仅 DockerHub 路径需要。
- `DockerHub Username` 仅 DockerHub 路径需要；不要缺省盲试。

## 创建 Vast template

镜像推送成功后创建 Vast template：

```powershell
pwsh -File .\scripts\create_vast_wan22_kj_env_template.ps1 `
  -TemplateName codex-wan22-kj-comfy-cuda129 `
  -Image ghcr.io/myjr2015/codex-wan22-kj-comfy:cuda129-py312-kj-v1
```

如果 GHCR package 仍是 private，可临时创建带 registry login 的 template：

```powershell
pwsh -File .\scripts\create_vast_wan22_kj_env_template.ps1 `
  -TemplateName codex-wan22-kj-comfy-cuda129 `
  -Image ghcr.io/myjr2015/codex-wan22-kj-comfy:cuda129-py312-kj-v1 `
  -PrivateRegistryLogin `
  -RegistryHost ghcr.io `
  -RegistryUsername myjr2015
```

`RegistryToken` 默认从 `.env` / `api.txt` 的 GitHub token 读取，不要把 token 写进命令行。

创建后记录返回的 `template_hash_id`，然后设置：

```powershell
$env:VAST_WAN22_KJ_TEMPLATE_HASH = "<template_hash_id>"
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
- 减少 torch 重装概率，但仍由 bootstrap 做兼容性检查。
- 不直接减少 HuggingFace 模型下载时间。
- 不改变 KJ 推理时间。

第一版验收标准：

- Vast template 能启动实例。
- ComfyUI `8188` 能映射。
- bootstrap 日志出现 `preinstalled KJ custom nodes are ready`。
- HF speed gate 仍正常执行。
- workflow 能进入模型下载或缓存检查阶段。
