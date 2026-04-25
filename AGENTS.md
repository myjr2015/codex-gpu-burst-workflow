# 项目运行规则

本项目的长期记忆分三层：

1. `AGENTS.md`
   - 项目级默认规则。
   - 新会话进入本仓库后，先读这里。
   - 这里放强制流程、命名、状态汇报规则。

2. `skills/okskills/SKILL.md`
   - 成功经验。
   - 跑 `wan_2_2_animate` / Wan2.2 口播流程前必须加载。

3. `skills/badskills/SKILL.md`
   - 失败经验和禁止重复踩的坑。
   - 跑 Vast、调 ComfyUI、处理冷启动问题前必须加载。

## 中文优先规则

能用中文表达的地方优先用中文，包括：

- 文档文件名和章节标题。
- 项目说明、恢复说明、操作步骤。
- 对用户的状态汇报和最终总结。
- 目录说明、素材说明、经验记录。

以下内容保持英文或 ASCII，不强行中文化：

- 已跑通的脚本文件名，例如 `scripts/run_wan_2_2_animate_end_to_end.ps1`。
- profile、JSON 字段、环境变量、命令参数、模型文件名。
- 第三方平台、库、API 的官方名称。
- 会影响自动化流程稳定性的固定输入输出名。

原则：用户可读内容尽量中文，机器要读的接口保持稳定。

## 必读启动规则

每次开始跑付费 Vast 任务前，必须先读取：

- `skills/okskills/SKILL.md`
- `skills/badskills/SKILL.md`

然后明确说明本次走哪个版本：

- `1.0`：冷启动跑通版
- `1.1`：机器库优选 + 暖启动探测版

## 机器库规则

老机器判断只以文件为准，不靠聊天记忆：

- `data/vast-machine-registry.json`

选择机器时先运行：

```powershell
pwsh -File .\scripts\select_wan_2_2_animate_vast_offer.ps1
```

规则：

- 如果当前可租机器命中机器库里的成功机器，优先租它。
- 只有命中老机器时才启用 `WarmStart`。
- 如果没有命中老机器，按 `1.0` 冷启动处理。
- `hit` 说中文叫“命中”。
- `miss` 说中文叫“未命中”，意思是没有找到可复用缓存，不是文件丢失。

## 付费运行汇报

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

## 切换机器汇报

如果同一任务中途销毁实例并切换到另一台机器，不能只在后台切换，必须立即补一条状态：

- 说明为什么切机
- 说明旧实例 `instance_id`
- 说明新实例 `instance_id`
- 说明新机器的 `host_id`、`machine_id`
- 明确当前流程重新回到哪一步

切机后的汇报格式也继续沿用上面的编号步骤，不允许省略。

需要可见日志时，用轮询脚本：

```powershell
pwsh -File .\scripts\watch_vast_workflow_job.ps1 `
  -Profile wan_2_2_animate `
  -JobName <job_name> `
  -IntervalSeconds 20 `
  -MaxChecks 60
```

## 当前生产主线

当前已跑通的固定流程：

- 源图片目录：`素材资产/美女图带光伏/`
- 远端固定输入图片名：`美女带背景.png`
- 输入视频：`光伏2.mp4`
- 工作流：`workflows/Animate+Wan2.2换风格对口型.json`
- 主入口：`scripts/run_wan_2_2_animate_end_to_end.ps1`
- 共享配置：`config/vast-workflow-profiles.json`
- 成功/失败经验：`skills/okskills/SKILL.md`、`skills/badskills/SKILL.md`

## 工作流目录

所有 ComfyUI / RunComfy workflow JSON 源文件统一放在：

- `workflows/`

规则：

- 当前主线 workflow 是 `workflows/Animate+Wan2.2换风格对口型.json`。
- 当前 profile 里的 `workflow_source` 也必须指向这个源文件。
- 以后新增 workflow，直接保存到 `workflows/`。
- 新 workflow 要上 Vast 跑时，必须先确认输入节点、输出文件匹配、依赖节点和模型清单，再新增 profile 或专用 stage 脚本。
- `output/wan_2_2_animate/<job_name>/workflow_canvas.json` 和 `workflow_runtime.json` 是每次运行自动生成的副本，不要当源文件维护。

## 本地密钥兜底

本地 key 读取顺序：

1. 先读 `.env`
2. 如果 `.env` 没有对应 key，再读根目录 `api.txt`

`api.txt` 是本地明文备份，只允许使用这种格式：

```text
网站名
key
```

规则：

- 不要把 `api.txt` 内容打印到聊天或终端。
- 不要提交 `api.txt`，它必须保持在 `.gitignore`。
- 新增平台 key 时，先写入 `api.txt`，再按需同步到 `.env`。
- PowerShell 入口通过 `scripts/r2_env_helpers.ps1` 自动做 fallback。
- Node 入口通过 `src/config.js` 自动做 fallback。

## GitHub 推送兜底

普通 `git push` 在 Windows 上可能会调用 Git Credential Manager 弹出 GitHub 登录窗口。
Git 本身不会自动读取本项目的 `api.txt`。

如果需要用本地 `api.txt` / `.env` 里的 GitHub token 非交互推送，使用：

```powershell
pwsh -File .\scripts\git_push_with_project_token.ps1
```

规则：

- 不要把 GitHub token 写进命令行参数。
- 不要把 GitHub token 打印到聊天或日志。
- helper 只通过临时 `GIT_ASKPASS` 和进程环境变量传 token，结束后清理临时文件。
- 如果普通 `git push` 弹登录或卡住，先停止卡住的 Git 进程，再用 helper 推送。

## 运行版本

默认运行入口仍然是：

```powershell
pwsh -File .\scripts\run_wan_2_2_animate_end_to_end.ps1
```

版本选择：

- `-RuntimeVersion 1.0-cold`
  - 用基础 Vast Comfy 镜像
  - 不把老机器当缓存用
- `-RuntimeVersion 1.1-machine-registry`
  - 用机器库优选老机器
  - 老机器命中时才启用 `WarmStart`

## 不要重复踩坑

- 不要用 `美女图.png` 跑这个固定流程。
- 不要用 `素材资产/美女图无背景纯色/` 里的纯色人物图跑当前 `wan_2_2_animate` 固定流程。
- 当前 `wan_2_2_animate` 源图必须从 `素材资产/美女图带光伏/` 选择；脚本会在 stage 阶段统一暂存为 `美女带背景.png`，这是 ComfyUI 工作流的固定输入名，不代表源文件必须叫这个名字。
- 不要恢复未验证的 ComfyUI 节点包。
- 不要把 `launch` 和 `stage` 并行。
- 不要猜输出文件名，必须从 ComfyUI `/history` 读取。
- 不要给 `destroy_vast_instance.ps1` 传 `-JobName`，它只接受 `-InstanceId`。
- 不要把同一台机器等同于模型缓存命中；必须看日志里的命中/未命中。
- 不要把已放弃的 Docker / 缓存镜像实验重新写回 `wan_2_2_animate` 的生产记忆。
- 新模型或新工作流必须新增独立 profile / skill，不要污染当前 Wan2.2 固定流程。

## 收尾同步规则

每次做完清理、重命名、跑通测试或修改规则后，必须检查：

```powershell
git status --short
git status -sb
```

处理原则：

- 当前主线文件有有效改动：提交并推送 GitHub。
- 只是删除未跟踪临时文件，且 `git status` 已干净：没有可提交内容，明确说明 GitHub 已经同步、无需新提交。
- 发现旧实验脏文件：不要长期留在工作区；要么删除，要么归档到明确目录，要么提交到专门分支，不要污染当前主线。
- 最终回复必须说明 GitHub 是否已同步，以及本地是否还有未提交内容。
