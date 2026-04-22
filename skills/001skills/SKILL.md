---
name: 001skills
description: Use when running the fixed Wan2.2 talking-photo pipeline from one composed speaker image plus one source video on temporary Vast GPU machines, with assets staged locally and archived through Cloudflare R2.
---

# 001skills

## Overview

This is the fixed deployment skill for the validated `Animate+Wan2.2换风格对口型.json` chain.

Use this branch when the input contract is:
- one final composed speaker image with background: `美女带背景.png`
- one source video carrying the target speech rhythm/audio: `光伏2.mp4`

Do not use this skill for:
- `美女图.png`
- segmented 30s to 120s stitching
- true new-background regeneration
- multi-character jobs

## Fixed Contract

The validated stack is:
1. root canvas workflow: `Animate+Wan2.2换风格对口型.json`
2. local conversion: `scripts/prepare_wan22_root_canvas_prompt.mjs`
3. remote bootstrap: `scripts/bootstrap_wan22_root_canvas.sh`
4. remote submit/wait: `scripts/remote_submit_wan22_root_canvas.sh`

Pinned behavior:
- image input name must be `美女带背景.png`
- video input name must be `光伏2.mp4`
- `TorchCompileModelWanVideoV2` is removed at runtime conversion
- `PathchSageAttentionKJ.sage_attention=disabled`
- output prefix comes from the job name

## Storage Roles

Keep responsibilities separate:

- GitHub / workspace:
  - workflow JSON
  - conversion scripts
  - bootstrap scripts
  - job manifests
- R2:
  - staged input jobs
  - accepted outputs
- Vast:
  - temporary execution only

## Standard Paths

Local job package:
- `output/001skills/<job_name>/`

Inside each job package:
- `input/美女带背景.png`
- `input/光伏2.mp4`
- `workflow_canvas.json`
- `workflow_runtime.json`
- `bootstrap_wan22_root_canvas.sh`
- `remote_submit_wan22_root_canvas.sh`
- `manifest.json`

R2 layout:
- `runcomfy-inputs/001skills/<job_name>/input/`
- `runcomfy-inputs/001skills/<job_name>/output/`

Remote machine layout:
- `/workspace/ComfyUI/input/美女带背景.png`
- `/workspace/ComfyUI/input/光伏2.mp4`
- `/workspace/ComfyUI/output/*.mp4`
- `/workspace/wan22-root-canvas-run/`

## Fast Deploy Flow

1. Stage a job locally:

```powershell
pwsh -File .\scripts\stage_001skills_job.ps1 `
  -JobName demo-001 `
  -ImagePath .\美女带背景.png `
  -VideoPath .\光伏2.mp4 `
  -R2AccountId $env:CLOUDFLARE_ACCOUNT_ID `
  -R2AccessKeyId $env:R2_ACCESS_KEY_ID `
  -R2SecretAccessKey $env:R2_SECRET_ACCESS_KEY `
  -UploadToR2
```

2. Start a Vast machine that can hold the validated chain. Current known-good floor is `24GB`, but larger cards are safer for first recovery runs.

Recommended fast path after the mother image is built:

```powershell
pwsh -File .\scripts\launch_001skills_vast_job.ps1 `
  -JobName demo-001 `
  -OfferId <vast_offer_id> `
  -Image j1c2k3/codex-comfy-wan22-root-canvas:latest `
  -PrewarmedImage
```

In this mode:
- the machine still pulls staged assets from R2
- `bootstrap_wan22_root_canvas.sh` only prepares models and folders
- custom nodes and Python deps are assumed to already exist in the image

3. Upload the staged job package to the machine, or pull it from R2 to the machine.

4. Ensure the remote files exist:
- `/workspace/ComfyUI/input/美女带背景.png`
- `/workspace/ComfyUI/input/光伏2.mp4`
- `/workspace/wan22-root-canvas-run/workflow_runtime.json`
- `/workspace/wan22-root-canvas-run/bootstrap_wan22_root_canvas.sh`

5. Run remote submit:

```bash
bash /workspace/wan22-root-canvas-run/remote_submit_wan22_root_canvas.sh
```

6. Pull the result back to local, then archive it to:
- `runcomfy-inputs/001skills/<job_name>/output/`

```powershell
pwsh -File .\scripts\publish_001skills_result.ps1 `
  -JobName demo-001 `
  -ResultPath .\output\vast-wan22-root-strict-3090b\downloads\wan22-root-canvas_00001-audio.mp4 `
  -R2AccountId $env:CLOUDFLARE_ACCOUNT_ID `
  -R2AccessKeyId $env:R2_ACCESS_KEY_ID `
  -R2SecretAccessKey $env:R2_SECRET_ACCESS_KEY
```

7. Destroy the instance after the output is confirmed.

## Acceptance Check

Promote the result only if:
- mouth sync is acceptable
- no old scene text is being redrawn
- the composed speaker image is the exact source identity
- output exists both locally and in R2

## Common Mistakes

- Using `美女图.png` instead of `美女带背景.png`
- Treating this skill as a true background-regeneration branch
- Forgetting that the result depends on the exact local runtime patching
- Uploading only media but not the generated `workflow_runtime.json`
