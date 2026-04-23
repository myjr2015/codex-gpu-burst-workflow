---
name: okskills
description: Use when running the proven Wan2.2 talking-photo pipeline with one composed speaker image and one source video, or when needing the exact known-good deployment contract, asset layout, and acceptance checks that already succeeded on fresh Vast hosts.
---

# okskills

## Overview

This skill records the success path only.

Use it when the goal is to reproduce the already validated Wan2.2 talking-photo flow with the fewest moving parts and without re-deciding architecture.

## Fixed Input Contract

Use this branch only when all of the following are true:
- final speaker image is `美女带背景.png`
- source speech video is `光伏2.mp4`
- target workflow is `Animate+Wan2.2换风格对口型.json`
- output goal is one direct talking-photo clip, not segmented stitching

Do not use this skill for:
- `美女图.png`
- multi-character generation
- 30s to 120s segmented continuation
- true background regeneration

## Proven Stack

Pinned workflow chain:
1. `Animate+Wan2.2换风格对口型.json`
2. `scripts/prepare_wan22_root_canvas_prompt.mjs`
3. `scripts/bootstrap_wan22_root_canvas.sh`
4. `scripts/remote_submit_wan22_root_canvas.sh`
5. `config/vast-workflow-profiles.json`
6. `scripts/run_vast_workflow_job.ps1`
7. `scripts/run_001skills_end_to_end.ps1`
8. `scripts/summarize_vast_job_timing.ps1`

Pinned runtime behavior:
- input image name must stay `美女带背景.png`
- input video name must stay `光伏2.mp4`
- `TorchCompileModelWanVideoV2` is removed at runtime conversion
- `PathchSageAttentionKJ.sage_attention=disabled`
- output prefix comes from the job name

## Minimal Required Node Bundles

Only keep these four bundles in this branch:
- `ComfyUI-GGUF`
- `ComfyUI-KJNodes`
- `ComfyUI-VideoHelperSuite`
- `ComfyUI-WanAnimatePreprocess`

Anything else is noise unless re-proven.

## Proven Fresh-Host Runs

Run 1:
- Vast instance `35439373`
- host `74292`
- machine `47075`
- GPU `RTX 3090 24GB`
- image `vastai/comfy:v0.19.3-cuda-12.9-py312`
- local output: `output/001skills/smoke-002/downloads/001skills-smoke-002_00001-audio.mp4`

Run 2:
- Vast instance `35440443`
- host `296571`
- machine `48954`
- GPU `RTX 3090 24GB`
- image `vastai/comfy:v0.19.3-cuda-12.9-py312`
- local output: `output/001skills/smoke-003/downloads/001skills-smoke-003_00001-audio.mp4`
- R2 output: `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/001skills/smoke-003/output/001skills-smoke-003_00001-audio.mp4`

Core conclusion:
- this chain survives fresh-host cold start
- this chain does not depend on one lucky mother machine

## Storage Roles

Keep responsibilities separate:

- workspace / GitHub:
  - workflow JSON
  - conversion scripts
  - bootstrap scripts
  - manifests
- R2:
  - staged inputs
  - accepted outputs
  - node bundles for cold start
- Vast:
  - temporary execution only

## Current Download Sources

This branch currently pulls its heavy runtime from two places:

- PyTorch CUDA stack:
  - `https://download.pytorch.org/whl/cu124`
  - packages:
    - `torch`
    - `torchvision`
    - `torchaudio`
- Model weights and preprocess assets:
  - Hugging Face
  - examples:
    - `QuantStack/Wan2.2-Animate-14B-GGUF`
    - `Comfy-Org/Wan_2.1_ComfyUI_repackaged`
    - `eddy1111111/Wan_toolkit`
    - `Kijai/WanVideo_comfy`
    - `Wan-AI/Wan2.2-Animate-14B`
    - `JunkyByte/easy_ViTPose`

This means a truly fresh machine pays cold-start time twice:
- first for Python and CUDA wheels
- then for multi-GB model downloads

## Vast Storage Optimization Direction

Official Vast storage docs change the optimization strategy in a very specific way:

- Local volumes are tied to one physical machine and cannot move to another machine
- Cloud Sync can move data to and from supported cloud providers even while an instance is stopped
- Scheduled Cloud Backups can automate repeated instance-to-cloud copies

Practical consequence for this branch:

1. Same-machine speedup:
- create a Vast local volume on a machine that already works
- mount it into later instances on that same machine
- keep at least these directories on the volume:
  - `/workspace/ComfyUI/models`
  - `/workspace/ComfyUI/custom_nodes`
  - optionally pip wheel / cache directories

2. Cross-machine recovery:
- do not rely on Vast local volumes alone, because they cannot move across machines
- keep workspace scripts and stage payloads in R2
- keep accepted outputs in R2
- if you want cloud-native restore inside Vast, prefer Vast Cloud Sync / Cloud Backups to a supported provider

3. Best future state:
- Docker image stores environment and preinstalled Python deps
- Vast local volume stores model cache on one proven machine
- R2 stores stage inputs and final outputs
- optional cloud backup stores model archives if you want provider-managed restore logic

## Progress Markers To Expect In Logs

These log lines are now normal and should not be treated as failures:

- `Downloading trampoline-0.1.2-py3-none-any.whl`
- `Successfully installed torchsde-0.2.6 trampoline-0.1.2`
- `[bootstrap] python module exists: color_matcher`
- `[bootstrap] creating model directories`
- `[bootstrap] downloading: Wan2.2-Animate-14B-Q4_K_S.gguf`
- `[bootstrap] downloading: umt5_xxl_fp8_e4m3fn_scaled.safetensors`

Interpretation:
- wheel install lines mean bootstrap is still on dependency setup
- `creating model directories` means Python deps are nearly done
- `downloading: Wan2.2...` means model phase has started
- repeated curl progress lines during model downloads are expected on a fresh machine

## Bootstrap Optimization Already Applied

The bootstrap script now avoids forced torch reinstall on every fresh machine.

Current behavior:
- first validate whether `torch`, `torchvision`, and `torchaudio` already exist
- verify the existing torch runtime reports CUDA `12.4`
- only reinstall from `https://download.pytorch.org/whl/cu124` when that check fails

Practical consequence:
- on base images that already ship a compatible `cu124` torch stack, the cold start skips the heaviest Python wheel reinstall phase
- the remaining major cold-start cost is model download from Hugging Face

The launcher also now exposes raw mount args for Vast env strings, so the same flow can attach a known local volume later, for example:

```powershell
pwsh -File .\scripts\launch_001skills_vast_job.ps1 `
  -JobName demo-001 `
  -OfferId <offer_id> `
  -MountArgs '-v V.123456:/workspace/ComfyUI/models'
```

## Standard Paths

Local staged job:
- `output/001skills/<job_name>/`

Inside staged job:
- `input/美女带背景.png`
- `input/光伏2.mp4`
- `workflow_canvas.json`
- `workflow_runtime.json`
- `bootstrap_wan22_root_canvas.sh`
- `remote_submit_wan22_root_canvas.sh`
- `onstart_001skills.sh`
- `manifest.json`
- `run-report.json`
- `timing-summary.json`
- `result.api.json`

R2:
- `runcomfy-inputs/001skills/<job_name>/input/`
- `runcomfy-inputs/001skills/<job_name>/output/`
- `runcomfy-inputs/001skills/<job_name>/node-bundles/`

Remote:
- `/workspace/ComfyUI/input/美女带背景.png`
- `/workspace/ComfyUI/input/光伏2.mp4`
- `/workspace/wan22-root-canvas-run/`
- `/workspace/ComfyUI/output/*.mp4`

## Standard Success Flow

1. Stage job:

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

2. Launch Vast instance:

```powershell
pwsh -File .\scripts\launch_001skills_vast_job.ps1 `
  -JobName demo-001 `
  -OfferId <vast_offer_id> `
  -Image vastai/comfy:v0.19.3-cuda-12.9-py312 `
  -CancelUnavail
```

3. Let generated `onstart_001skills.sh` pull the staged files from R2.

4. Wait for:
- bootstrap complete
- ComfyUI API ready
- queue empty
- history shows `execution_success`

5. Pull output to local.

## Preferred Entry Points

Lowest-level reusable entry:
- `scripts/run_vast_workflow_job.ps1`

Convenience wrapper for this exact branch:
- `scripts/run_001skills_end_to_end.ps1`

Recommended command for this branch:

```powershell
pwsh -File .\scripts\run_001skills_end_to_end.ps1 `
  -JobName demo-001 `
  -ImagePath .\美女带背景.png `
  -VideoPath .\光伏2.mp4 `
  -OfferId <vast_offer_id>
```

Resume an already running job without restaging or relaunching:

```powershell
pwsh -File .\scripts\run_001skills_end_to_end.ps1 `
  -JobName demo-001 `
  -SkipStage `
  -SkipLaunch
```

## Output Retrieval Rule

For this branch, output retrieval is API-first and must stay API-first.

Required order:
1. Query ComfyUI history API to get the actual output filename
2. Download the finished file through ComfyUI `/view`
3. Only fall back to SSH / SCP if the API path is unavailable

Do not start with `vastai copy` on a Windows controller machine.

Reason:
- `vastai copy` may depend on local `rsync`
- this Windows environment does not guarantee `rsync`
- ComfyUI already exposes the authoritative filename and output file over HTTP

Known-good pattern:

```powershell
(Invoke-WebRequest -UseBasicParsing 'http://<ip>:<mapped_8188>/history').Content
Invoke-WebRequest -UseBasicParsing "http://<ip>:<mapped_8188>/view?filename=<actual_filename>&type=output&subfolder=" -OutFile '.\output\001skills\<job>\downloads\<actual_filename>'
```

The key rule is:
- do not guess output filenames
- do not guess remote paths
- read the filename from history first, then download it

6. Publish accepted result:

```powershell
pwsh -File .\scripts\publish_001skills_result.ps1 `
  -JobName demo-001 `
  -ResultPath .\output\001skills\demo-001\downloads\001skills-demo-001_00001-audio.mp4 `
  -R2AccountId $env:CLOUDFLARE_ACCOUNT_ID `
  -R2AccessKeyId $env:R2_ACCESS_KEY_ID `
  -R2SecretAccessKey $env:R2_SECRET_ACCESS_KEY
```

7. Destroy the instance after the file is confirmed.

## New Observable Outputs

The automation layer now writes these files and they are part of the success path:

- `manifest.json`
  - authoritative job metadata
  - now records `result` and `published_result`
- `run-report.json`
  - local orchestration step status and durations
  - step-level evidence for:
    - `download`
    - `fetch_logs`
    - `summarize_timings`
    - optional `publish`
    - optional `destroy`
- `timing-summary.json`
  - remote timing summary parsed from Vast / Comfy logs
  - currently guaranteed fields:
    - `prompt_execution`
    - `stages`
    - `lifecycle`

## What Was Verified

The current automation layer was verified against existing job `smoke-004`:
- `download_001skills_result.ps1`
  - re-read ComfyUI history
  - re-downloaded the finished MP4
- `summarize_vast_job_timing.ps1`
  - fetched live Vast logs
  - wrote `timing-summary.json`
- `publish_001skills_result.ps1`
  - uploaded the local result back to R2
  - wrote `published_result.public_url`
- `run_001skills_end_to_end.ps1`
  - resumed the existing job with `-SkipStage -SkipLaunch -SkipPublish`
  - wrote a step-complete `run-report.json`

The next live run `smoke-005` also proved two additional operational details:
- a fresh job can be staged successfully with the new wrapper using:
  - image `素材资产\美女图带光伏\美女带背景.png`
  - video `output\vast-wan22-root-strict-3090b\光伏2.mp4`
- Vast instance creation can require UTF-8 forcing on the controller side
- download logic must tolerate `loading` instances whose `ports` are not populated yet

## Extension Rule For Future Workflows

Do not fork this whole orchestration layer just because a new workflow arrives.

For a new workflow branch:
1. add a new profile entry in `config/vast-workflow-profiles.json`
2. point it at that workflow's own stage / launch / download / publish scripts
3. keep `run_vast_workflow_job.ps1` as the shared orchestration layer

Only workflow-specific contracts belong in per-workflow scripts:
- input filenames
- prompt preparation
- output filename matching
- custom bundle set
- publish rules if they differ

## Operator Sequence

When reporting progress, keep the sequence explicit:
1. `stage`
2. `launch`
3. wait for instance port mapping
4. wait for Comfy history result
5. `download`
6. `fetch_logs`
7. `summarize_timings`
8. `publish`

Do not collapse `launch` and `download` into one vague status line.

When the operator wants visibility, use:
- `scripts/watch_vast_workflow_job.ps1`

Example:

```powershell
pwsh -File .\scripts\watch_vast_workflow_job.ps1 `
  -Profile 001skills `
  -JobName demo-001 `
  -IntervalSeconds 20 `
  -MaxChecks 60
```

Expected output style:
1. instance status
2. port mapping
3. current local step
4. timing summary readiness
5. recent relevant log lines

This is the preferred way to expose:
- model download progress
- pip install progress
- bootstrap stage changes
- prompt execution completion

## Acceptance Check

Only accept the clip if:
- lip sync is acceptable
- source scene text is not being redrawn back into the result
- identity matches the composed speaker image
- local file exists
- R2 archived file exists

## Success Rules That Must Stay Pinned

- do not rename the Chinese input filenames
- do not add back unused custom-node bundles
- do not switch the workflow without re-proving it on a fresh host
- do not claim success before both local and R2 outputs exist

## Quick Reuse Summary

If you need the shortest path back to production:
- reuse the same workflow
- reuse the same scripts
- reuse the same four node bundles
- use a 24GB class NVIDIA card on a `580.*` driver host
- keep R2 as staging + archive
- for real cold-start reduction, add either:
  - a same-machine Vast local volume for `/workspace/ComfyUI/models`
  - or a prewarmed Docker image plus model cache strategy
