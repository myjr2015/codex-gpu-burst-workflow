# GPU Burst Workflow

这份文档定义后续标准流程：本地只负责编排，不负责生成；云端只负责临时算力。

## 目标

把流程固定成这 5 步：

1. 本地准备素材
2. `rclone` 上传到 Cloudflare R2
3. Vast 临时起一台 GPU 机器
4. 机器拉环境、拉模型、跑工作流
5. 结果回传到 R2，然后销毁实例

## 单一归属

三层都要用，但不能重复存同一种资产。

原则：

- GitHub 只做代码与流程的唯一来源
- Docker 只做运行环境
- R2 只做媒体和大体积资产

归属配置文件：

- [asset_ownership.json](D:\code\DaiMa\happy_dev\codex\config\asset_ownership.json)

## 资产分层

### 1. GitHub

只放轻量、可版本化内容：

- 工作流 JSON
- 启动脚本
- 模型清单
- 任务脚本
- 文档

明确不放：

- 大模型
- 输入媒体
- 输出视频
- Docker 镜像层

### 2. Docker

只放运行环境：

- ComfyUI
- custom nodes
- Python 依赖
- 系统运行时

明确不放：

- 工作流 JSON
- 输入媒体
- 输出媒体
- 大模型

### 3. R2

只放对象资产和大文件：

- 输入图片/音频/视频
- 输出视频
- 可复用模型包或压缩资产

明确不放：

- 工作流 JSON
- 启动脚本
- 任务脚本
- Docker 镜像

### 4. Vast 实例

只当临时算力：

- 开机
- 跑任务
- 回传结果
- 销毁

## 这次踩过的坑

### 1. 不要把复杂配置全塞进 `--env`

在 PowerShell + Vast CLI 下，带空格的值容易被截断。

这次已经实测到：

- `COMFYUI_ARGS` 只剩一部分
- `PORTAL_CONFIG` 被截断

所以后续原则：

- `--env` 只放简单键值
- 复杂启动逻辑放到脚本里

### 2. Vast 外网端口不是固定 `8080/8188`

实例起来后，要以 `vastai show instance <id> --raw` 返回的 `ports` 映射为准。

不要默认拿 `public_ip:8080` 或 `public_ip:8188` 直接打。

### 3. 失败机不要保留

失败试机直接销毁，不要只停机。

保留停机磁盘只适合：

- 母机存档
- 已经完成配置且确认还有复用价值的实例

## 当前推荐启动方式

先用最小环境起机，再进入实例做恢复。

当前入口脚本：

- [create_vast_instance_minimal.ps1](D:\code\DaiMa\happy_dev\codex\scripts\create_vast_instance_minimal.ps1)

特点：

- 只传最小必要环境变量
- 只开必要端口
- 不再把复杂 `PORTAL_CONFIG` 硬塞进 `--env`

示例：

```powershell
pwsh -File .\scripts\create_vast_instance_minimal.ps1 -OfferId 31112437 -Label wan21-5090
```

## R2 同步方式

入口脚本：

- [sync_r2_with_rclone.ps1](D:\code\DaiMa\happy_dev\codex\scripts\sync_r2_with_rclone.ps1)

示例：

```powershell
pwsh -File .\scripts\sync_r2_with_rclone.ps1 `
  -Mode upload `
  -LocalPath .\output\vast-clean-anchor-multitalk-24g `
  -RemotePath runcomfy-inputs\vast-clean-anchor-multitalk-24g
```

## 销毁实例

入口脚本：

- [destroy_vast_instance.ps1](D:\code\DaiMa\happy_dev\codex\scripts\destroy_vast_instance.ps1)

示例：

```powershell
pwsh -File .\scripts\destroy_vast_instance.ps1 -InstanceId 35319502
```

## 归属示例

### 例子 1: `workflow_api_24g_pruned.json`

- 归 GitHub
- 不进 Docker
- 不进 R2

### 例子 2: `ComfyUI-WanVideoWrapper`

- 归 Docker
- GitHub 只记录来源和版本信息，不重复保存整个运行副本
- 不进 R2

### 例子 3: `Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors`

- 归 R2
- GitHub 只放文件名和下载清单
- Docker 不内置

### 例子 4: 成片 `mp4`

- 归 R2
- GitHub 不存
- Docker 不存

## 后续还要补的两项

### 1. onstart 或 provisioning 脚本

下一步要把恢复逻辑改成：

- 起机
- 自动执行 bootstrap
- 自动拉 nodes / models

减少手工进入实例的次数。

### 2. GitHub 仓库落点

你已经给了 GitHub token，但当前目录还不是 Git 仓库，也还没有远端地址。

所以现在已经能做的是：

- 把脚本和文档整理好

等仓库地址确定后，再做：

- `git init`
- 配置 remote
- 提交并推送

## 当前结论

你的长期方案是对的：

- 本地没有显卡，不做生成
- R2 保资产
- GitHub 保版本
- Docker 保环境
- Vast 提供临时算力

后面要做的是把“恢复链路”压缩到稳定的 10 到 20 分钟内，而不是让单台实例长期在线。
