# 短视频重写工作流骨架

这个项目只做你已经确认的生成链路，不碰监控层。

当前骨架解决 4 件事：

1. 读取源视频并探测时长、分辨率、码率
2. 抽音频并做转写
3. 把原始转写重写成新的中文讲解脚本和分镜计划
4. 按分镜计划生成 RunComfy Serverless API 请求体

它不负责：

- 抖音监控
- 自动剪切每个镜头的源视频片段
- 自动把最终成片拼回来

这些先留给后续版本。

如果你把带有大段中文标题、字幕、价签的原视频直接喂给 `Wan 2.2 Animate`，生成后这些字大概率会变成乱码。这不是这条 workflow 独有的问题，而是生成模型本身不擅长稳定重建中文 UI/字幕。更稳的做法是先把驱动视频里的字幕区裁掉或模糊掉，再把干净版本上传给 RunComfy。

## 当前两条主路径

### Path A: `direct_swap`

适合画面里文字不多、遮挡不重的素材，继续走当前 `wan_animate`：

`原视频 -> 转写/改写 -> wan_animate`

### Path B: `fixed_bg`

适合固定机位、固定背景、画面文字很多的素材。主线不再直接把原视频喂给 `wan_animate`，而是拆成：

`原视频 -> 原音频 + transcript -> 背景板/背景修补 -> 单图+音频讲话人物 -> 合成`

当前仓库已经先补了本地 MVP：

- `faster-whisper` 抽台词
- 本地中值采样生成 `background-plate.png`
- 产出 `liveportrait_img2vid` 的 avatar job 模板
- 产出 `compose-plan.json`
- 支持 `--speaker-image-urls` 批量生成多张人物候选图的 avatar jobs

要注意：本地中值背景板只是**粗糙预览**。如果主播长期坐在画面中间，或大字幕长期盖在同一区域，这张图仍然会有残影。生产版仍然建议在 RunComfy 上补：

- `MatAnyone`：视频抠像/人像分离
- `DiffuEraser`：视频去人/去字补背景

## 推荐工作流

- 低字素材快路径：`Wan 2.2 Animate`
- 固定机位人物口播：`LivePortrait Img2Vid`
- 背景分离：`MatAnyone`
- 背景修补：`DiffuEraser`
- B-roll：`Seedance 2.0 Pro`

## 目录

```text
config/
  workflows.example.json    # RunComfy workflow/deployment 映射模板
src/
  cli.js                    # 命令入口
  assets.js                 # 上传本地素材到公网 URL
  config.js                 # 环境变量和配置加载
  llm.js                    # 转写、脚本重写
  planner.js                # 分镜规划和 fallback 逻辑
  runcomfy.js               # RunComfy API 封装
  video.js                  # ffprobe / ffmpeg 处理
output/                     # 运行产物
```

## 开始

1. 安装依赖

```bash
npm install
```

2. 复制环境变量

```bash
copy .env.example .env
```

3. 复制 workflow 配置模板

```bash
copy config\\workflows.example.json config\\workflows.local.json
```

4. 在 `config/workflows.local.json` 里填你自己的：

- `deploymentId`
- 每个节点的 `nodeId`
- 对应输入名 `inputName`

这些值都来自你在 RunComfy 里导出的 `workflow_api.json`。

当前已经验证过的 `wan_animate` 输入节点是：

- `57.image`
- `63.video`
- `65.positive_prompt`

## 本地转写

默认推荐把转写切到本地 `faster-whisper`，只把视频生成留在 RunComfy。

先准备一个可用的 Python，然后在项目目录创建虚拟环境并安装依赖：

```bash
D:\code\YuYan\python\python.exe -m venv .venv-faster-whisper
.\.venv-faster-whisper\Scripts\python.exe -m pip install faster-whisper
```

再在 `.env` 里补这些配置：

```bash
TRANSCRIBE_PROVIDER=faster-whisper
FASTER_WHISPER_PYTHON=.\.venv-faster-whisper\Scripts\python.exe
FASTER_WHISPER_MODEL=small
FASTER_WHISPER_DEVICE=auto
FASTER_WHISPER_COMPUTE_TYPE=int8
FASTER_WHISPER_BEAM_SIZE=5
```

如果你想继续用 OpenAI 转写，只要把 `TRANSCRIBE_PROVIDER=openai` 并配置 `OPENAI_API_KEY`。

## 先把本地素材放到公网

RunComfy 的文件输入节点要能直接拉到原始文件内容，所以本地 `D:` 盘路径不能直接传给它。最省事的做法是放到一个公开可读的 S3 兼容对象存储里，例如你已有的 R2 / S3 / OSS / COS bucket。

先在 `.env` 里补上传配置：

```bash
ASSET_S3_ENDPOINT=https://你的对象存储 endpoint
ASSET_S3_REGION=auto
ASSET_S3_BUCKET=你的bucket
ASSET_S3_ACCESS_KEY_ID=你的access key
ASSET_S3_SECRET_ACCESS_KEY=你的secret key
ASSET_S3_PUBLIC_BASE_URL=https://这个bucket对外可访问的域名
```

然后执行：

```bash
npm run upload-assets -- --video .\\光伏.mp4 --image .\\美女图.png
```

它会把结果写到：

```text
output/uploads/uploaded-assets.json
```

里面会直接给你：

- `sourceVideoUrl`
- `speakerImageUrl`

再把这两个 URL 传给后续命令。

## 常用命令

### 1. 上传本地素材

```bash
npm run upload-assets -- --video .\\光伏.mp4 --image .\\美女图.png --audio output\\guangfu\\audio.wav
```

### 2. 清洗驱动视频里的字幕区

如果源视频底部有字幕、价签、表格条带，先做一次前处理再提交给 `Wan Animate`：

```bash
npm run prepare-driving-video -- --input .\\光伏.mp4 --crop-bottom-px 180
```

或者只把底部一条区域打码：

```bash
npm run prepare-driving-video -- --input .\\光伏.mp4 --blur-bottom-px 180
```

处理后会生成一个新的本地 MP4。把这个新文件上传到公网，再拿它当 `--source-video-url`。

### 3. 探测视频

```bash
npm run inspect -- --input .\\光伏.mp4
```

### 4. 一键跑到“生成 RunComfy 请求体”

```bash
npm run pipeline -- --mode direct_swap --input .\\光伏.mp4 --speaker-image-url https://example.com/hero.jpg --source-video-url https://example.com/source.mp4
```

如果你没有可用转写 provider 或文案改写 key，它会退回到本地 fallback 规划器，仍然会生成一份分镜计划和 job 模板。

### 5. 固定机位素材跑 `fixed_bg` 模式

```bash
npm run pipeline -- --mode fixed_bg --input .\\光伏2.mp4 --speaker-image-url https://example.com/hero.jpg --source-audio-url https://example.com/source.wav
```

会在输出目录生成：

- `audio.wav`
- `transcript.json`
- `background-plate.png`
- `avatar-jobs.json`
- `compose-plan.json`

如果你还没把 `audio.wav` 上传到公网，`avatar-jobs.json` 会明确提示缺少 `--source-audio-url`。

如果你已经准备了多张纯色背景人物图，可以直接批量生成候选人物任务：

```bash
npm run pipeline -- --mode fixed_bg --input .\\光伏2.mp4 --speaker-image-urls https://example.com/美女1.png,https://example.com/美女2.png,https://example.com/美女3.png --source-video-url https://example.com/source.mp4
```

这会在 `avatar-jobs.json` 里为每张图各生成一个候选 job，方便后面比较效果再选最终人物版本。

如果本地人物图是三视图拼图，可以直接让脚手架先裁中间人物，再以内嵌 data URI 的方式提交：

```bash
npm run pipeline -- --mode fixed_bg --input .\\光伏2.mp4 --speaker-image-files .\\美女1.png,.\\美女2.png,.\\美女3.png --speaker-sheet-mode triptych_center --source-video-url https://example.com/source.mp4
```

这会在输出目录下生成 `prepared-speakers/`，里面是裁好的单人物版本。

### 6. 只提固定机位的背景板

```bash
npm run prepare-background -- --input .\\光伏2.mp4 --sample-count 12
```

它会在输出目录生成：

- `background-plate.png`
- `background-meta.json`

这个背景板适合做本地预览或后续修补的初稿，不要把它当成最终无瑕疵背景。

### 7. 单独生成 RunComfy job

```bash
npm run build-jobs -- --plan output\\guangfu\\rewrite-plan.json --speaker-image-url https://example.com/hero.jpg --source-video-url https://example.com/source.mp4
```

### 8. 提交 RunComfy

```bash
npm run submit -- --jobs output\\guangfu\\runcomfy-jobs.json
```

### 9. 查询任务结果

```bash
npm run poll -- --jobs output\\guangfu\\submitted-jobs.json
```

### 10. 用浏览器自动导出 `workflow_api.json`

第一次会打开一个带持久化登录态的 Chromium。你登录 RunComfy 后，脚本会尝试自动点击 `Workflow -> Export (API)`。

```bash
npm run runcomfy:export-api -- --url https://www.runcomfy.com/comfyui/你的workflow页面
```

导出的文件会保存在：

```text
output/runcomfy/workflow_api.json
```

### 11. 直接通过 RunComfy API 拉取 deployment 的 `workflow_api.json`

如果你已经有真正的 RunComfy Bearer token，这个方式比浏览器导出更直接。

```bash
npm run runcomfy:fetch-deployment -- --deployment-id 你的deploymentId
```

它会调用 RunComfy Deployment API，把 deployment 明细和 `workflow_api.json` 保存到：

```text
output/<deploymentId>/deployment.json
output/<deploymentId>/workflow_api.json
```

RunComfy 文档说明了 deployment endpoint 支持 `includes=payload`，返回里会带：

- `workflow_api_json`
- `overrides`
- `object_info_url`

### 12. 直接通过 API 创建 deployment

```bash
npm run create-deployment -- --name wan-22-animate-api --workflow-id 00000000-0000-0000-0000-000000001307 --workflow-version v1 --hardware AMPERE_24
```

### 13. 直接通过 API 启用或修改 deployment

```bash
npm run update-deployment -- --deployment-id 你的deploymentId --enabled true
```

## 你要补的配置

最关键的是 `config/workflows.local.json`。每个 workflow 都要把你自己的 node id 映射进去。

RunComfy 官方 API 形态是：

- `POST /deployments/{deployment_id}/inference`
- `GET /deployments/{deployment_id}/requests/{request_id}/status`
- `GET /deployments/{deployment_id}/requests/{request_id}/result`

参考：

- https://docs.runcomfy.com/serverless/quickstart
- https://docs.runcomfy.com/serverless/about-billing
- https://docs.runcomfy.com/serverless/workflow-files

## 成本口径

当前脚手架带了一个简单估算器：

```bash
npm run estimate -- --gpu 24gb --minutes 2 --runtime 20
```

这里的 `runtime` 是单条任务在 RunComfy 上真正在线执行的分钟数，不是成片时长。
