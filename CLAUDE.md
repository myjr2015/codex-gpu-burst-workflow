# douyin-video-rewriter (codex)

## 项目说明
抖音/短视频自动化重写与 AI 视频生成管道，核心流程：原始视频 → 转写 → LLM 重写脚本 → 构建 AI 任务 → 提交 RunComfy → 轮询结果 → 合成

## 关键规则
- **本地修改后自动 push 到 GitHub**，保持本地和远端同步
- commit 格式: `Vx.x.x 简要描述`，版本号在前
- 版本记录更新 `版本.md`
- API 密钥存放在 `api.txt`，不提交到 git
- workflow 配置在 `config/workflows.local.json`（不提交 git），示例用 `config/workflows.example.json`
