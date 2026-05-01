# 项目运行规则

本项目的长期记忆分四层：

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

4. `skills/wan_2_2_animate_segmented/SKILL.md`
   - 分段生成经验。
   - 跑 `wan_2_2_animate_segmented` / 30s 分段续接流程前必须加载。

5. `skills/wan22_kj_30s/SKILL.md`
   - KJ 30s / 60s 分段经验。
   - 跑 `wan22_kj_30s` / `wan22_kj_30s_segmented` / KJ 2.0 同图锚定版前必须加载。

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
- 如果跑分段流程，再读取 `skills/wan_2_2_animate_segmented/SKILL.md`

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
- 默认选机必须排除 `CN` 和 `TR`：`geolocation notin [CN,TR]`。
- `hit` 说中文叫“命中”。
- `miss` 说中文叫“未命中”，意思是没有找到可复用缓存，不是文件丢失。

### 选机结果以“实际启动时”为准

Vast 可租状态会在很短时间内变化。
如果人工先单独跑过一次选机脚本，再过几十秒真正启动任务，前一次结果可能已经过期。

规则：

- 不要把“手动预检查”的命中/未命中结果，当成最终运行版本判断依据。
- 真正 authoritative 的结果，是实际那次运行里 `run_wan_2_2_animate_end_to_end.ps1` 输出的：
  - `selection_mode`
  - `selection_reason`
  - `selected_machine_id`
  - `warm_start`
- 如果预检查是“未命中”，但实际启动时变成命中老机器：
  - 必须立刻向用户更正
  - 说明实际已经租到老机器
  - 后续版本判断以实际启动时结果为准
- 以后回答“这次应该是 1.0 还是 1.1”时，除非已经拿到实际启动那次的选机输出，否则只能说“预检查结果”，不能下最终结论。

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

## 工作流分支命名

版本号和工作流分支分开管理，不要混用。

规则：

- `1.0-cold`、`1.1-machine-registry` 这类名字，只表示运行策略。
- `wan_2_2_animate`、`wan_2_2_animate_segmented` 这类名字，只表示工作流分支。
- 新的长时长方案不要叫“1.0 时长版”，要开独立 profile。

当前约定：

- `wan_2_2_animate`
  - 单段直出主线
- `wan_2_2_animate_segmented`
  - 分段主线
  - `v1`：两个或多个 `10s` 片段独立生成，再用 `ffmpeg` 拼接
  - `v2`：在 `v1` 基础上补尾帧 / `continue_motion`
  - `v3_single_instance`：已验证候选入口；同一台 Vast 实例内依次跑 3 个 `10s` 片段，段 2/3 使用上一段最后 5 帧作为 `continue_motion`，再本地合并为约 `30s` 文件
- `wan22_kj_30s`
  - KJ 2.0 30秒单段版。
  - 使用纯色/透明人物 IP 图 + 30s 参考动作/表情视频 + 提示词重绘背景。
- `wan22_kj_30s_segmented`
  - KJ 2.0 长视频分段版。
  - 固定每段最多 `30s`，本地用 `ffmpeg concat` 合并。
  - 当前固定场景可用方案叫 `KJ 2.0 同图锚定版`，内部追踪名 `B1.1 same-frame anchor`。
  - 成片合并后如果只剩孤立小红点/贴纸色块，使用 `scripts/polish_generated_artifacts.py` 做本地一条龙精修；这不是纯 FFmpeg，FFmpeg 只负责抽帧/编码/音频封装，局部修复由 OpenCV inpaint 完成。

### 可跑版本友好命名

用户问“现在有哪些版本可跑”时，必须优先用中文友好名回答，不要让用户记内部实验名。

回答格式：

- 先说中文方案名。
- 括号里再写内部 profile / 脚本 / 实验名，便于追溯。
- 明确状态：`可跑`、`候选可跑`、`实验可跑`、`失败不要跑`、`暂不跑`。

当前口径：

- `Wan2.2 固定图口播主线`
  - 内部：`wan_2_2_animate`
  - 入口：`scripts/run_wan_2_2_animate_end_to_end.ps1`
  - 状态：可跑，当前稳定生产主线。
- `Wan2.2 10秒分段续接版`
  - 内部：`wan_2_2_animate_segmented` / `segmented v3_single_instance`
  - 入口：`scripts/run_wan_2_2_animate_segmented_v3_single_instance.ps1`
  - 状态：候选可跑，已验证 30s / 60s，但长视频人物一致性仍需验片。
- `KJ 2.0 30秒单段版`
  - 内部：`wan22_kj_30s`
  - 入口：`scripts/run_wan22_kj_30s_end_to_end.ps1`
  - 状态：候选可跑，单段 30s 已跑通，成本较高。
- `KJ 2.0 同图锚定版`
  - 内部：`wan22_kj_30s_segmented` / `B1.1 same-frame anchor`
  - 入口：`scripts/run_wan22_kj_30s_segmented_end_to_end.ps1`
  - 状态：当前 KJ 固定场景 60s 可用方案；用同一张完整人物+背景 anchor 图作为每段 `ip_image.png`，不接 `bg_images` / `mask`。
- `KJ 2.0 背景/Mask失败版`
  - 内部：`B2 bg_images/mask`
  - 状态：失败不要跑；该方案会压制嘴巴和身体动作。
- `KJ 2.1 通用清理版`
  - 内部：`reference cleaning 2.1 / 2.1-next`
  - 状态：暂不跑；本地清理闸门未通过，不能进入 Vast 付费推理。

规则：

- `B1.1`、`B2` 只作为内部追踪名，不作为对用户的主称呼。
- 用户说“同图版”“同图锚定”“当前KJ固定场景版”时，默认指 `KJ 2.0 同图锚定版`。
- 用户说“背景mask版”“B2”时，必须提醒该方案已失败，不要直接开跑。
- 用户说“红点修理”“成片精修”“一条龙修复”时，默认指 `scripts/polish_generated_artifacts.py` 的本地后处理：检测风险、定位候选彩色组件，v5 默认自动处理 `red/yellow/green/magenta`，目标前后默认补 `2` 帧处理不足 1 秒的边缘漏帧，围绕已确认目标尝试清理银白高光/细线残留，跳过皮肤/脸/脚等高误伤区域，OpenCV 局部 inpaint，重封装音频，复检并输出 before/after 拼图；`cyan/blue` 支持显式开启但默认关闭，避免误伤天空和光伏板。
- `kj60-b11-sameframe-30x2-20260501` 的 `polished-auto-v5.mp4` 已被用户暂时验收为可接受，作为本次 60s 推荐精修输出；后续同类 KJ 2.0 同图锚定版默认先跑 v5 精修再人工确认。
- 最新可跑状态仍以 `config/version-manifest.json` 为准；如果 AGENTS 和 manifest 冲突，以 manifest 为准，并同步修正 AGENTS。

## 版本管理规则

版本管理分四条轴，回答和文档中必须说清楚是哪一种：

- Git release：`v1.0.0`、`v1.1.0`，只表示仓库 tag。
- 运行策略：`1.0-cold`、`1.1-machine-registry`，只表示 Vast 启动和选机策略。
- 工作流分支：`wan_2_2_animate`、`wan_2_2_animate_segmented`，只表示业务 workflow。
- 脚本实现：`segmented v1/v2/v3`，只表示同一工作流分支下的实现迭代。

规则：

- 版本矩阵以 `config/version-manifest.json` 为准。
- 版本规则以 `docs/版本管理规范.md` 为准。
- `版本.md` 只记录 Git release / tag 级别变化和 `Unreleased`。
- 实验脚本不能叫生产版；只有写入 profile、完成验证、更新 skill 后，才能晋升为默认入口。
- `output/` 不能承担源码或测试 fixture 职责；需要测试样例时放到 `tests/fixtures/`。

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
- 早期 RunComfy / Node CLI 入口已移除；当前生产密钥 fallback 以 PowerShell helper 为准。

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
