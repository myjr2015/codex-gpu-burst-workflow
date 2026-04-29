# Wan2.2 Vast 口播生成工作流

这个仓库当前只维护已经跑通的 Vast + ComfyUI / Wan2.2 口播生成链路。

早期 RunComfy Serverless / Node CLI 实验入口已移除；Node 现在只保留给当前生产链路需要的工作流转换脚本和 `ffmpeg-static` / `ffprobe-static` 依赖。

## 当前主线

- 工作流分支：`wan_2_2_animate`
- 源工作流：`workflows/Animate+Wan2.2换风格对口型.json`
- 主入口：`scripts/run_wan_2_2_animate_end_to_end.ps1`
- profile：`config/vast-workflow-profiles.json`
- 版本矩阵：`config/version-manifest.json`
- 版本规则：`docs/版本管理规范.md`
- 成功经验：`skills/okskills/SKILL.md`
- 失败经验：`skills/badskills/SKILL.md`

固定输入约束：

- 源图片必须来自 `素材资产/美女图带光伏/`
- stage 后的 ComfyUI 图片名固定为 `美女带背景.png`
- 输入视频在 ComfyUI 里固定为 `光伏2.mp4`
- 当前源 workflow 不要改成 `output/**/workflow_runtime.json`

## 可用版本

运行策略版本：

- `1.0-cold`：冷启动基线，不使用机器库缓存判断。
- `1.1-machine-registry`：默认策略，先查机器库，命中历史成功机器才启用 `WarmStart`。

工作流分支：

- `wan_2_2_animate`：单段直出，生产主线。
- `wan_2_2_animate_segmented`：分段生成再拼接，候选/实验分支。

脚本实现：

- `segmented v1`：多段生成后拼接。
- `segmented v2`：加入尾帧 / continue motion。
- `segmented v3 single instance`：本地实验脚本，未纳入正式 profile 前不能称为生产版。

## 一键运行

付费 Vast 任务运行前必须先读：

- `skills/okskills/SKILL.md`
- `skills/badskills/SKILL.md`

默认推荐：

```powershell
pwsh -File .\scripts\run_wan_2_2_animate_end_to_end.ps1 `
  -JobName demo-001 `
  -VideoPath .\素材资产\原视频\光伏10s.mp4 `
  -RuntimeVersion 1.1-machine-registry `
  -CancelUnavail `
  -DestroyInstance
```

强制冷启动：

```powershell
pwsh -File .\scripts\run_wan_2_2_animate_end_to_end.ps1 `
  -JobName demo-cold-001 `
  -VideoPath .\素材资产\原视频\光伏10s.mp4 `
  -RuntimeVersion 1.0-cold `
  -FreshMachine `
  -CancelUnavail `
  -DestroyInstance
```

如果不传 `-ImagePath`，脚本会自动从 `素材资产/美女图带光伏/` 选择最新图片。

## 选机预检查

预检查只能作为参考，最终版本判断以实际启动输出为准：

```powershell
pwsh -File .\scripts\select_wan_2_2_animate_vast_offer.ps1
```

实际启动时看这些输出：

- `selection_mode`
- `selection_reason`
- `selected_machine_id`
- `warm_start`

## 可见日志

付费运行时不要长时间无反馈。需要可见日志时使用：

```powershell
pwsh -File .\scripts\watch_vast_workflow_job.ps1 `
  -Profile wan_2_2_animate `
  -JobName <job_name> `
  -IntervalSeconds 20 `
  -MaxChecks 60
```

## 目录说明

```text
config/
  vast-workflow-profiles.json  # workflow profile 配置
  version-manifest.json        # 版本矩阵
data/
  vast-machine-registry.json   # 成功机器库
docs/
  版本管理规范.md
scripts/
  run_wan_2_2_animate_end_to_end.ps1
  run_vast_workflow_job.ps1
  stage_wan_2_2_animate_job.ps1
  launch_wan_2_2_animate_vast_job.ps1
  download_wan_2_2_animate_result.ps1
  publish_wan_2_2_animate_result.ps1
  prepare_wan22_root_canvas_prompt.mjs
  generate_wan_2_2_animate_onstart.mjs
skills/
  okskills/
  badskills/
workflows/
  Animate+Wan2.2换风格对口型.json
素材资产/
  美女图带光伏/
  原视频/
```

## 本地依赖

```powershell
npm install
```

当前 npm 只保留主线需要的 Node 工具依赖：

- `ffmpeg-static`
- `ffprobe-static`

Node 语法检查：

```powershell
npm run check:node
```

Python 测试：

```powershell
pytest -q
```

## 密钥

本地密钥读取顺序：

1. `.env`
2. 根目录 `api.txt`

不要打印或提交 `api.txt`。PowerShell 入口通过 `scripts/r2_env_helpers.ps1` 做 fallback。

## 收尾

每次做完清理、重命名、跑通测试或规则修改后检查：

```powershell
git status --short
git status -sb
```

如果当前主线文件有有效改动，按项目规则提交并推送；如果工作区仍有旧实验脏文件，要明确说明。
