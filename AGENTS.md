# Project Operating Rules

本项目的长期记忆分三层：

1. `AGENTS.md`
   - 项目级默认规则。
   - 新会话进入本仓库后，先读这里。
   - 这里放强制流程、命名、状态汇报规则。

2. `skills/okskills/SKILL.md`
   - 成功经验。
   - 跑 `001skills` / Wan2.2 口播流程前必须加载。

3. `skills/badskills/SKILL.md`
   - 失败经验和禁止重复踩的坑。
   - 跑 Vast、调 ComfyUI、处理冷启动问题前必须加载。

## Mandatory Startup Rule

每次开始跑付费 Vast 任务前，必须先读取：

- `skills/okskills/SKILL.md`
- `skills/badskills/SKILL.md`

然后明确说明本次走哪个版本：

- `1.0`：冷启动跑通版
- `1.1`：机器库优选 + 暖启动探测版
- `1.2`：轻 Docker 镜像版，预装 ComfyUI、必需节点、Python 依赖、torch/cu124，不内置大模型
- `1.3`：重 Docker 镜像版，计划内置模型，尚未完成

## Machine Registry

老机器判断只以文件为准，不靠聊天记忆：

- `data/vast-machine-registry.json`

选择机器时先运行：

```powershell
pwsh -File .\scripts\select_001skills_vast_offer.ps1
```

规则：

- 如果当前可租机器命中机器库里的成功机器，优先租它。
- 只有命中老机器时才启用 `WarmStart`。
- 如果没有命中老机器，按 `1.0` 冷启动处理。
- `hit` 说中文叫“命中”。
- `miss` 说中文叫“未命中”，意思是没有找到可复用缓存，不是文件丢失。

## Paid Run Reporting

付费机器运行时不能长时间沉默。必须按步骤汇报：

1. `stage`：本地打包和上传素材
2. `launch`：租机器并启动
3. `port mapping`：等待 `8188` 端口映射
4. `bootstrap`：节点、依赖、模型准备
5. `inference`：ComfyUI 正在生成，报告 `0/4` 到 `4/4` 进度
6. `download`：从 ComfyUI 历史记录拿真实文件名并下载
7. `fetch_logs`：拉 Vast 日志
8. `summarize_timings`：生成耗时报告
9. `publish`：上传 R2
10. `destroy`：销毁实例，停止计费
11. `update registry`：更新机器库

需要可见日志时，用轮询脚本：

```powershell
pwsh -File .\scripts\watch_vast_workflow_job.ps1 `
  -Profile 001skills `
  -JobName <job_name> `
  -IntervalSeconds 20 `
  -MaxChecks 60
```

## Current Production Branch

当前已跑通的固定流程：

- 输入图片：`美女带背景.png`
- 输入视频：`光伏2.mp4`
- 工作流：`Animate+Wan2.2换风格对口型.json`
- 主入口：`scripts/run_001skills_end_to_end.ps1`
- 共享配置：`config/vast-workflow-profiles.json`
- 成功/失败经验：`skills/okskills/SKILL.md`、`skills/badskills/SKILL.md`

## Runtime Versions

默认运行入口仍然是：

```powershell
pwsh -File .\scripts\run_001skills_end_to_end.ps1
```

版本选择：

- `-RuntimeVersion 1.0-cold`
  - 用基础 Vast Comfy 镜像
  - 不把老机器当缓存用
- `-RuntimeVersion 1.1-machine-registry`
  - 用机器库优选老机器
  - 老机器命中时才启用 `WarmStart`
- `-RuntimeVersion 1.2-light`
  - 用轻 Docker 镜像 `j1c2k3/codex-comfy-wan22-root-canvas:1.2-light`
  - 自动传 `PREWARMED_IMAGE=1`
  - 跳过自定义节点解压
  - 尽量跳过 Python/torch 安装
  - 大模型仍然按需下载
  - 做公平冷启动测试时，加 `-FreshMachine` 排除机器库里的成功老机器
- `-RuntimeVersion 1.3-heavy`
  - 预留给重镜像
  - 当前未完成，不能用于生产

## Do Not Repeat

- 不要用 `美女图.png` 跑这个固定流程。
- 不要恢复未验证的 ComfyUI 节点包。
- 不要把 `launch` 和 `stage` 并行。
- 不要猜输出文件名，必须从 ComfyUI `/history` 读取。
- 不要给 `destroy_vast_instance.ps1` 传 `-JobName`，它只接受 `-InstanceId`。
- 不要把同一台机器等同于模型缓存命中；必须看日志里的命中/未命中。
- 不要把以前失败过的重 Docker 镜像当 1.2 基础。
- `1.2-light` 必须是干净轻镜像：不放模型，不放旧多余节点。
