# 项目运行规则

本项目的长期记忆分七层：

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

6. `skills/history_video_pipeline_skills/SKILL.md`
   - 历史方案归档、暂停后恢复入口、路线切换经验。
   - 用户问“之前做过哪些方案”“现在该走哪条路线”“LTX2.3 要不要试”时必须加载。

7. `skills/vast-machine-selection/SKILL.md`
   - Vast 选机、测速、价格上限、地区排除、机器库优先级和切机止损规则。
   - 每次准备租 Vast 付费机器、切换机器、解释下载速度、或选择 3090/4090 前必须加载。

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

- `skills/vast-machine-selection/SKILL.md`
- `skills/okskills/SKILL.md`
- `skills/badskills/SKILL.md`
- 如果跑分段流程，再读取 `skills/wan_2_2_animate_segmented/SKILL.md`
- 如果是项目暂停后恢复、路线复盘、或准备切到 `LTX2.3`，再读取 `skills/history_video_pipeline_skills/SKILL.md`

然后明确说明本次走哪个版本：

- `1.0`：冷启动跑通版
- `1.1`：机器库优选 + 暖启动探测版
- `1.2`：KJ 环境镜像 + Vast template 实验版，仅限 `wan22_kj_30s` / `wan22_kj_30s_segmented`，不用于老 Wan2.2 主线

## 机器库规则

老机器判断只以文件为准，不靠聊天记忆：

- `data/vast-machine-registry.json`

选择机器前先读取 `skills/vast-machine-selection/SKILL.md`。如使用现有 selector，必须确认它没有违反该 skill 的价格和测速规则。

老 Wan2.2 selector 入口：

```powershell
pwsh -File .\scripts\select_wan_2_2_animate_vast_offer.ps1
```

规则：

- 如果当前可租机器命中机器库里的成功机器，只能作为同价/近价候选的加分项，不能压过 `skills/vast-machine-selection/SKILL.md` 里的价格上限和测速结果。
- 只有命中老机器时才启用 `WarmStart`。
- 如果没有命中老机器，按 `1.0` 冷启动处理。
- `CN` 从 2026-05-05 起不再租用；付费生成默认在 Vast 搜索条件中排除 `CN`。
- `TR` 只作为测速风险信号，不再和 `CN` 一起硬排除；是否可用以实际启动和下载日志为准。
- `hit` 说中文叫“命中”。
- `miss` 说中文叫“未命中”，意思是没有找到可复用缓存，不是文件丢失。

### 3090 价格规则

选择 `RTX 3090 24GB` 跑 KJ / Wan2.2 / LTX2.3 付费任务时，以 `skills/vast-machine-selection/SKILL.md` 为准：默认优先全部费用合计低于 `$0.15/h` 的机器，`$0.16/h` 可作为低价候选失败后的回退，超过 `$0.18/h` 必须先说明原因或得到用户明确同意。

规则：

- 默认排除 `CN`；不要为了低价把 `CN` 候选放进付费生成短名单，除非用户之后明确重新允许。
- `TR` 只作为测速风险信号，低价非 `CN` 候选可以进入短名单，是否可用以实际启动和下载日志为准。
- `driver_version` 不作为硬过滤条件；不再因为低于 `580.*` 单独否决机器，真实兼容性以 CUDA / torch / bootstrap 日志为准。
- 必须用带实际 `--storage` 后的 `dph_total` 判断价格，不能只看裸 GPU 价格。
- HF 纯测速可以用小磁盘快速测网络；真实 KJ 冷启动/推理要用实际需要的磁盘重新计算总价。
- KJ 30s / KJ 分段完整工作流默认按 `DiskGb=240` 选机，搜索也必须带 `--storage 240`；不要用 40GB/80GB 的测速价格判断真实任务成本。
- 全部费用高于 `$0.18/h` 的 3090 默认不选，除非用户明确要求、当前低价候选测速失败，或任务已经进入必须止损权衡的阶段。
- 当前用户指定的 3090 价格偏好更新于 2026-05-05：优先找含存储费用低于 `$0.15/h` 的非 `CN` 机器，`CN` 不租用。

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
  - 2026-05-02 起默认输出 `720x1280` 抖音 9:16 竖屏；stage 会把方形 IP/锚定图转成 9:16 画布，再送入 workflow。
- `wan22_kj_30s_segmented`
  - KJ 2.0 长视频分段版。
  - 固定每段最多 `30s`，本地用 `ffmpeg concat` 合并。
  - 2026-05-02 起默认每段和合并成片都按 `720x1280` 9:16 竖屏生成。
  - 2026-05-03 起，所有 9:16 竖屏质量测试都必须保持 `context_frames=121`、`context_overlap=16`、`offload_img_emb=true`、`offload_txt_emb=true`；这包括 `480x848`、`544x960`、`720x1280`。`context_frames=41/context_overlap=8` 只能作为速度实验，不能作为画质/闪烁验收依据。
  - 当前固定场景可用方案叫 `KJ 2.0 同图锚定版`，内部追踪名 `B1.1 same-frame anchor`。
  - 当前 480p 竖屏可用方案叫 `KJ 3.0 480p竖屏同图锚定版`，内部追踪名 `KJ3.0-480p-portrait-anchor`。
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
- `KJ 3.0 480p竖屏同图锚定版`
  - 内部：`wan22_kj_30s_segmented` / `KJ3.0-480p-portrait-anchor`
  - 入口：`scripts/run_wan22_kj_30s_segmented_end_to_end.ps1`
  - 状态：候选可跑，当前 480p 竖屏推荐方案；`480x848`、`10s` 已由用户验收合格，但 `60s=30s+30s` 样本 `kj60-kj3p0-480p-4090-reuse-20260503-01` 被用户发现 `28s-31s` 多手、`43s-45s` 闪屏，不能作为 60s 验收通过样本。
  - 关键参数：`-OutputWidth 480 -OutputHeight 848`，保持 `context_frames=121`、`context_overlap=16`、`offload_img_emb/offload_txt_emb=true`，推荐走 DockerHub v3 Vast template。
- `KJ 2.0 环境镜像模板版`
  - 内部：`1.2-docker-env-template`
  - 镜像：`j1c2k3/codex-wan22-kj-comfy:cuda129-py312-kj-v3`
  - Dockerfile：`docker/wan22-kj-comfy-env/Dockerfile`
  - Vast template helper：`scripts/create_vast_wan22_kj_env_template.ps1`
  - 状态：ONNX CUDA smoke 已通过；GHCR v3 因本地 token 缺 `read:packages` 会 401，默认改走 DockerHub v3。v3 仍必须先通过 `RemoteStopAfter=onnx_cuda`，确认 `CUDAExecutionProvider` 和 tiny ONNX GPU session 成功，再允许进入模型下载或完整推理。
- `KJ 2.0 背景/Mask失败版`
  - 内部：`B2 bg_images/mask`
  - 状态：失败不要跑；该方案会压制嘴巴和身体动作。
- `KJ 2.1 通用清理版`
  - 内部：`reference cleaning 2.1 / 2.1-next`
  - 状态：暂不跑；本地清理闸门未通过，不能进入 Vast 付费推理。
- `MultiTalk / InfiniteTalk 10秒口型实验`
  - 内部：`multitalk10-smoke-20260504-001`
  - 入口：仅为 `scripts/_test` 临时 smoke，不是生产 profile
  - 状态：失败不要跑；虽然生成了 `480x848`、约 `11.88s` MP4，但最后几秒不说话/口型对不上，用户已否决。
- `LTX2.3 候选新路线`
  - 内部：`ltx23_talking_head_smoke`
  - 入口：`scripts/run_ltx23_talking_head_smoke_end_to_end.ps1`
  - 状态：候选可跑；自托管 Vast 3090 链路已跑通，旧底座 `2043593704170070018` 两次出现伪字幕/伪文字，不能生产。当前无字幕底座 `2040333916862685186` 已由 `ltx23-nosub-nag-20260504-01` 跑通；VBVR motion LoRA strength `0.60` 已由 `ltx23-vbvr-motion-s06-20260504-01` 跑通，但 VBVR 只算轻动效，不算严格动作模仿。`2026-05-05` 已接入 prompt-only 背景提示词模块：`-BackgroundPrompt` 只拼进 LTX 正向 prompt，不加载 PromptRelay / Qwen3-VL / Gemini 节点，也不下载额外提示词大模型。当前动作模仿候选是 `2044017351640748034 / LTX2.3_自定义音频+人物动作迁移V3（单采IDLoRA）`，本地 workflow 为 `workflows/LTX2.3动作模仿+音频对口型-V3候选.json`，入口使用 `-ActionMimic -ReferenceVideoPath`。当前推荐 10s 样本是 `ltx23-v6-cleanref-action-s045-nocn-ca-20260505-02`：使用 V6 grounded RGB 坐姿 anchor + `光伏10s_clean_reference_v6_skip1.mp4` 干净参考，`ActionGuideStrength=0.45`、`ActionLoraStrength=0.65`，输出 `512x896`、`24fps`、`10.041667s`，1fps/尾帧拼图未见伪字幕/文字、多人，尾部嘴部仍动，已发布 R2 并销毁实例。`ltx23-matte-action-cleanref-nocn-20260505-05` 的纯灰 matte 动作参考方案虽然技术跑通，但整段出现底部伪中文字幕样式文本，本地遮罩修复会伤腿/脚/椅子，标记失败不要作为默认路线。
  - `2026-05-06` 已跑完用户要求的 V3 `10s` VL背景付费探测：job `ltx23-v3-10s-vlbg-nocn-us-20260506-01`，Bulgaria RTX 3090 `instance=36231273 / host=203531 / machine=49870 / driver=570.195.03`，`dph_total=0.18333333333333335`，输出 `512x896`、`24fps`、`241` 帧、视频 `10.041667s` / 音频 `10.000000s`，prompt 执行 `373.686s`，R2 地址为 `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/ltx23_talking_head_smoke/ltx23-v3-10s-vlbg-nocn-us-20260506-01/output/ltx23_talking_head_smoke-ltx23-v3-10s-vlbg-nocn-us-20260506-01_00001_.mp4`。按用户要求本次实例跑完后不销毁，继续计费以便改参数复跑。该运行暴露并已写回的自托管修复：pip hash mismatch 先清 pip cache 再 `--no-cache-dir` 重试；ComfyUI 启动前让 `/usr/lib/x86_64-linux-gnu` 的宿主 `libcuda.so` 优先于 CUDA compat 路径，避免 570 驱动机器的 CUDA 804 误判；LTX bootstrap 不再过滤 `comfyui-frontend-package`，当前需要 `comfyui-frontend-package==1.42.11`。
  - `2026-05-06` 针对用户指出的“一只脚不能算完成”追加全身保脚构图：以 `ltx23-nosub-vbvr-s03-fullbody-nocn-bg-20260506-07` 的 stablehead 底座做 zoom110 bottom-preserving 720x1280 输入，再接 RunningHub `2046494511848755201 / 精准视频口型同步`。当前优先候选为 `ltx23-latentsync204649-vbvr07-zoom110-lip22-step25-pad01-20260506-03/deliverables/ltx23-vbvr07-zoom110-lip22-latentsync204649-step25-v1-10s-originalaudio-720x1280.mp4`：`720x1280`、`25fps`、视频 `10.000s`、原音频 `10.008s`，参数 `inference_steps=25`、`lips_expression=2.2`，R2 地址为 `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/ltx23_talking_head_smoke/ltx23-latentsync204649-vbvr07-zoom110-lip22-step25-pad01-20260506-03/output/ltx23-vbvr07-zoom110-lip22-latentsync204649-step25-v1-10s-originalaudio-720x1280.mp4`。全身 2fps、脚部 4fps、脸部 2fps 和风险拼图复查：两只红鞋全程可见，未见底部字幕条、伪中文/英文、多人或背景文字；风险框主要落在嘴、红鞋、手、椅子腿、光伏板和屋顶边缘。`lips_expression=1.8` 回退版为 `ltx23-latentsync204649-vbvr07-zoom110-step25-pad01-20260506-02`，R2 地址为 `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/ltx23_talking_head_smoke/ltx23-latentsync204649-vbvr07-zoom110-step25-pad01-20260506-02/output/ltx23-vbvr07-zoom110-latentsync204649-step25-v1-10s-originalaudio-720x1280.mp4`。两条都仍需正常播放确认逐字口型，不能只靠拼图宣布最终完成。
  - `2026-05-06` 已接入 V4 三采 IDLoRA 候选：RunningHub `2044022005221036033`，本地 workflow `workflows/LTX2.3动作模仿+音频对口型-V4三采IDLoRA候选.json`，通过 `-ActionMimicWorkflowSource` / `-ActionMimicWorkflowId` 指定。V4 目前只是 stage 通过，未完成付费推理验收；非 `CN` 3090 在 `180GB/120GB/80GB` 下最终被 Vast 账户余额不足阻塞，实例列表已确认 `[]`。余额恢复前不要继续换机烧时间；余额恢复后可用 V4 参数 `ActionGuideStrength=0.48`、`ActionLoraStrength=0.70`、`IdentityLoraStrength=0.78`、`IdentityGuidanceScale=2.8` 继续跑。
  - `2026-05-06` 临时 RunningHub 验证表明：V4 三采 `2044022005221036033` 在云端 512x768 会生成底部伪英文字母，512x896 会 OOM，暂不作为推荐路线。当前更稳的 RunningHub 备选是 `2040718940661354497 / LTX 2.3 音频驱动参考角色伪替换工作流`，它没有 Qwen/ASR/LLM 改词链；最佳样本为 `ltx23-rh204071-audiodrive-facehand-20260506-04` 的节点 `5135` 输出，并本地裁成 `deliverables/ltx23-rh204071-facehand-04-upperbody-reframe-720x1280.mp4`：带音频、`720x1280`、`24fps`、`9.708333s`，抽帧未见伪字幕/多人，脸、手、口型和光伏背景目前最均衡，R2 地址为 `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/ltx23_talking_head_smoke/ltx23-rh204071-audiodrive-facehand-20260506-04/output/ltx23-rh204071-facehand-04-upperbody-reframe-720x1280.mp4`。`upperonly-03` 腿更稳但动作弱；`lowmotion-05` 腿脚踢开并出现疑似墙面文字，失败不要用。
  - `2026-05-06` 在 `facehand-04` 基础上追加 RunningHub `2046494511848755201 / 精准视频口型同步` 后处理，当前推荐交付为 `ltx23-latentsync204649-facehand04-strict25-pad01-20260506-03/deliverables/ltx23-facehand04-latentsync204649-v3-10s-originalaudio-720x1280.mp4`：`720x1280`、`25fps`、视频 `10.000s`、原音频 `10.008s`，R2 地址为 `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/ltx23_talking_head_smoke/ltx23-latentsync204649-facehand04-strict25-pad01-20260506-03/output/ltx23-facehand04-latentsync204649-v3-10s-originalaudio-720x1280.mp4`。复查拼图未见伪字幕、多人或背景文字，自动风险框主要是嘴唇/红窗框/腿鞋/椅子误报；它是当前 10s 口型增强候选，但仍需正常播放确认逐字口型。
  - `2026-05-06` 继续筛 RunningHub 后新增动作更强的组合候选：`2031596620839657473 / LTX2.3 动作迁移` 因云端 API 图找不到本地 `LoadAudio` 节点 `36`，create 阶段失败未扣推理；`2031355634699997185 / LTX2.3人物动作迁移V1` 可跑但动作偏弱；`2031367576470687746 / LTX2.3人物动作迁移V2` 动作更明显，先生成 `512x896`、`24fps`、约 `11.041667s` 动作底座，再裁成 `720x1280`、`25fps`、`10s` 接 `204649` 做 mouth-only 口型增强。当前动作+口型 RunningHub 候选为 `ltx23-latentsync204649-action203136-strict25-pad01-20260506-01/deliverables/ltx23-action203136-latentsync204649-v1-10s-originalaudio-720x1280.mp4`，R2 地址为 `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/ltx23_talking_head_smoke/ltx23-latentsync204649-action203136-strict25-pad01-20260506-01/output/ltx23-action203136-latentsync204649-v1-10s-originalaudio-720x1280.mp4`。复查未见伪字幕、多人或背景文字；它比 `204071 facehand-04 + 204649` 动作更明显，但手部自然度仍需正常播放验片。
  - `2026-05-06` 继续按用户要求临时用 RunningHub 试动作模板：`2048694979278671873 / 动作参考并保持脸部一致性` 的 `cleanref-01` 和 `facehand-cleanref-02` 都会腿部发散、脸部裁切不稳，且该 workflow 没有独立 `LoadAudio`，不适合直接做最终口型；`2046642168843997185 / 视频编辑+人物替换+自定义音频` 虽有真实音频和手势，但把人物衣服/身份改成灰色职业装，背景偏离光伏并在尾部出现黑色遮挡物；`2039196522113409025 / 人物动作迁移图生音视频` 使用重编码的带原音频干净参考后可跑通，手脸版动作弱，body 强化版腿脚明显乱动。三者都没有超过当前 `203136 + 204649` 动作口型组合或 `204071 facehand-04 + 204649` 稳定口型候选，默认不要复跑同类参数。

规则：

- `B1.1`、`B2` 只作为内部追踪名，不作为对用户的主称呼。
- 用户说“同图版”“同图锚定”“当前KJ固定场景版”时，默认指 `KJ 2.0 同图锚定版`。
- 用户说“3.0”“480p版”“低成本竖屏版”时，默认指 `KJ 3.0 480p竖屏同图锚定版`。
- 用户说“背景mask版”“B2”时，必须提醒该方案已失败，不要直接开跑。
- 用户说“红点修理”“成片精修”“一条龙修复”时，默认指 `scripts/polish_generated_artifacts.py` 的本地后处理：检测风险、定位候选彩色组件，v5 默认自动处理 `red/yellow/green/magenta`，目标前后默认补 `2` 帧处理不足 1 秒的边缘漏帧，围绕已确认目标尝试清理银白高光/细线残留，跳过皮肤/脸/脚等高误伤区域，OpenCV 局部 inpaint，重封装音频，复检并输出 before/after 拼图；`cyan/blue` 支持显式开启但默认关闭，避免误伤天空和光伏板。
- `kj60-b11-sameframe-30x2-20260501` 的 `polished-auto-v5.mp4` 已被用户暂时验收为可接受，作为本次 60s 推荐精修输出；后续同类 KJ 2.0 同图锚定版默认先跑 v5 精修再人工确认。
- 用户说“MultiTalk”“InfiniteTalk”“最后几秒不说话那个方案”时，默认指 `multitalk10-smoke-20260504-001`，必须先说明该方案已被否决，不要直接复跑。
- 用户说“LTX2.3”时，默认走 `ltx23_talking_head_smoke` 独立路线；如果他说“动作模仿+对口型”，默认先给当前 V6/V3 clean-reference 样本、RunningHub `203136 + 204649` 动作口型组合、以及 `204071 facehand-04 + 204649` 稳定口型候选做取舍，不是继续改 KJ 2.0/3.0；如果明确说 V4/三采，必须提醒 V4 云端已出现伪英文字母/OOM 风险，不能直接当推荐路线；如果要求继续 RunningHub 临时测试，不要默认复跑 `204869`、`204664`、`203919` 这三条已失败动作模板，除非换了新的干净参考或目标已改成只验视觉/不验动作。
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

## 本地配置和密钥

本地运行配置和密钥分开管理：

1. 根目录 `config.json`：只放非密钥运行配置，例如 API base URL、本机工具路径、R2 bucket / public URL / prefix、转写和重写模型名。
2. 根目录 `api.txt`：只放平台账号、token、key、secret。
3. `.env`：仅作为旧脚本兼容兜底；新增配置和新增密钥默认不要再写入 `.env`。

PowerShell 入口通过 `scripts/r2_env_helpers.ps1` 自动读取：

1. 先读根目录 `config.json`
2. 再读根目录 `api.txt`
3. 最后才读 `.env` 补旧值

`api.txt` 是本地明文备份，只允许使用这种格式：

```text
网站名
key
```

R2 相关条目有一个兼容块：

```text
Cloudflare
api_token

Cloudflare Account ID
account_id

Cloudflare_R2
r2_access_key_id
r2_secret_access_key
```

规则：

- 不要把 `api.txt` 内容打印到聊天或终端。
- 不要提交 `api.txt`，它必须保持在 `.gitignore`。
- 新增平台 key 时，写入 `api.txt`；不要再同步到 `.env`。
- 新增非密钥配置时，写入根目录 `config.json`；不要再新增 `.env` 字段。
- PowerShell 入口通过 `scripts/r2_env_helpers.ps1` 自动做 fallback。
- R2 相关入口会优先使用 `api.txt` 里的 `Cloudflare Account ID` 和 `Cloudflare_R2` 块，避免旧 `.env` 里的 R2 值阻塞发布或上传。
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
- `-RuntimeVersion 1.2-docker-env-template`
  - 仅用于 KJ 分支
  - 通过 `-VastTemplateHash` 或 `VAST_WAN22_KJ_TEMPLATE_HASH` 使用 Vast template
  - template 指向项目 Docker 环境镜像，目标是减少 custom nodes / Python 依赖安装时间
  - 不代表模型缓存命中；模型仍然走 HF 测速和下载/缓存检查
  - v3 起必须先跑 `-RemoteStopAfter onnx_cuda` 小测试，确认 ONNXRuntime CUDA provider 不退回 CPU，再做 `validate_nodes` 或完整推理

## 不要重复踩坑

- 不要用 `美女图.png` 跑这个固定流程。
- 不要用 `素材资产/美女图无背景纯色/` 里的纯色人物图跑当前 `wan_2_2_animate` 固定流程。
- 当前 `wan_2_2_animate` 源图必须从 `素材资产/美女图带光伏/` 选择；脚本会在 stage 阶段统一暂存为 `美女带背景.png`，这是 ComfyUI 工作流的固定输入名，不代表源文件必须叫这个名字。
- 不要恢复未验证的 ComfyUI 节点包。
- 不要把 `launch` 和 `stage` 并行。
- 不要猜输出文件名，必须从 ComfyUI `/history` 读取。
- 不要给 `destroy_vast_instance.ps1` 传 `-JobName`，它只接受 `-InstanceId`。
- 不要把同一台机器等同于模型缓存命中；必须看日志里的命中/未命中。
- 不要把 Vast template 等同于模型缓存；template 只固化启动配置和镜像，模型是否命中仍看远端文件检查。
- 不要把 KJ 环境镜像实验写回老 `wan_2_2_animate` 生产主线；它只属于 KJ 独立 profile。
- 不要把大模型第一版塞进 Docker 镜像；先验证环境镜像能不能省掉节点和依赖安装时间。
- 不要把 `validate_nodes` 当成 KJ 环境镜像通过标准；它只能证明节点存在，不能证明 ONNXRuntime GPU 前处理可用。v3 必须看 `[onnx-cuda-smoke] tiny inference ok`。
- 不要把已放弃的 Docker / 缓存镜像实验重新写回 `wan_2_2_animate` 的生产记忆。
- 新模型或新工作流必须新增独立 profile / skill，不要污染当前 Wan2.2 固定流程。
- 不要把 `MultiTalk / InfiniteTalk` 10s smoke 当成可用口型路线；`multitalk10-smoke-20260504-001` 已被用户否决，原因是最后几秒不说话且口型不对。
- 不要把 KJ clean-motion / 自己做动作当成口型解决方案；KJ 音频主要是封装到成片，不能稳定驱动中文密集口播嘴型。

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
