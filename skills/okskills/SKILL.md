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
- source speaker image is selected from `素材资产/美女图带光伏/`
- staged ComfyUI image name is `美女带背景.png`
- source speech video is `光伏2.mp4`
- target workflow is `workflows/Animate+Wan2.2换风格对口型.json`
- output goal is one direct talking-photo clip, not segmented stitching

Do not use this skill for:
- `美女图.png`
- pure-color speaker assets under `素材资产/美女图无背景纯色/`
- multi-character generation
- 30s to 120s segmented continuation
- true background regeneration

## Proven Stack

Pinned workflow chain:
1. `workflows/Animate+Wan2.2换风格对口型.json`
2. `scripts/prepare_wan22_root_canvas_prompt.mjs`
3. `scripts/bootstrap_wan22_root_canvas.sh`
4. `scripts/remote_submit_wan22_root_canvas.sh`
5. `config/vast-workflow-profiles.json`
6. `scripts/run_vast_workflow_job.ps1`
7. `scripts/run_wan_2_2_animate_end_to_end.ps1`
8. `scripts/summarize_vast_job_timing.ps1`

Pinned runtime behavior:
- input image name must stay `美女带背景.png`
- input video name must stay `光伏2.mp4`
- the local source image can have any filename, but it must come from `素材资产/美女图带光伏/`
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

Current production boundary:
- only `1.0-cold` and `1.1-machine-registry` belong in this skill
- abandoned Docker / cache-image experiments do not belong in this production memory
- new model families or new workflow families must get their own profile and skill
- `config/vast-workflow-profiles.json` must keep `profiles.wan_2_2_animate.workflow_source` pointed at the current source workflow under `workflows/`

## Proven Fresh-Host Runs

Run 1:
- Vast instance `35439373`
- host `74292`
- machine `47075`
- GPU `RTX 3090 24GB`
- image `vastai/comfy:v0.19.3-cuda-12.9-py312`
- local output: `output/wan_2_2_animate/smoke-002/downloads/wan_2_2_animate-smoke-002_00001-audio.mp4`

Run 2:
- Vast instance `35440443`
- host `296571`
- machine `48954`
- GPU `RTX 3090 24GB`
- image `vastai/comfy:v0.19.3-cuda-12.9-py312`
- local output: `output/wan_2_2_animate/smoke-003/downloads/wan_2_2_animate-smoke-003_00001-audio.mp4`
- R2 output: `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/wan_2_2_animate/smoke-003/output/wan_2_2_animate-smoke-003_00001-audio.mp4`

Run 3:
- job `v10-stability-a`
- Vast instance `35471352`
- host `229807`
- machine `45200`
- GPU `RTX 3090 24GB`
- driver `590.48.01`
- image `vastai/comfy:v0.19.3-cuda-12.9-py312`
- prompt execution `00:12:07`
- local output: `output/wan_2_2_animate/v10-stability-a/downloads/wan_2_2_animate-v10-stability-a_00001-audio.mp4`
- R2 output: `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/wan_2_2_animate/v10-stability-a/output/wan_2_2_animate-v10-stability-a_00001-audio.mp4`

Run 4:
- job `v10-stability-b`
- Vast instance `35471353`
- host `42512`
- machine `5314`
- GPU `RTX 3090 24GB`
- driver `580.95.05`
- image `vastai/comfy:v0.19.3-cuda-12.9-py312`
- prompt execution `00:11:30`
- local output: `output/wan_2_2_animate/v10-stability-b/downloads/wan_2_2_animate-v10-stability-b_00001-audio.mp4`
- R2 output: `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/wan_2_2_animate/v10-stability-b/output/wan_2_2_animate-v10-stability-b_00001-audio.mp4`

Core conclusion:
- this chain survives fresh-host cold start
- this chain does not depend on one lucky mother machine
- two separate 3090 machines completed successfully in the same stability test

## Machine Selection Rule

Default Vast search rule for this branch:
- exclude mainland China and Turkey hosts: `geolocation notin [CN,TR]`

Reason:
- the current cold-start path downloads from Docker Hub, PyTorch, and Hugging Face
- China-region and Turkey hosts can be slower or require extra network workarounds
- that adds retry waste and breaks the assumption that a fresh machine should bootstrap unattended

Preferred order when searching:
1. `RTX 3090 24GB`
2. `verified=true`
3. `geolocation notin [CN,TR]`
4. `driver_version` in the proven-safe range, preferably `580.*` or `590.*`
5. enough disk for the configured job
6. then sort by `dph_total`

If the absolute cheapest offer is in `CN` or `TR`, do not automatically choose it for `wan_2_2_animate`.
Choose the cheapest non-`CN` and non-`TR` offer that satisfies the runtime assumptions.

## Machine Registry Rule

The merged `1.1` path is now:
- prefer a previously successful machine when it is currently rentable
- enable `WarmStart` only for that preferred-machine case
- otherwise fall back to normal cold start on the cheapest matching offer

Authoritative registry file in the repo:
- `data/vast-machine-registry.json`

Local Codex mirror:
- `C:\Users\myjr2\.codex\references\wan22\machine-registry.json`

Selection entry point:

```powershell
pwsh -File .\scripts\select_wan_2_2_animate_vast_offer.ps1
```

Current default behavior:
1. search non-`CN` and non-`TR` `RTX 3090 24GB` offers
2. match available offers against `data/vast-machine-registry.json`
3. if a machine already has a successful run record:
   - choose that machine
   - set `WarmStart=true`
4. if no known machine is available:
   - choose the cheapest matching offer
   - keep `WarmStart=false`

Automatic registry update entry point:

```powershell
pwsh -File .\scripts\update_vast_machine_registry.ps1 `
  -JobName <job_name>
```

This writes:
- repo registry: `data/vast-machine-registry.json`
- local mirror: `C:\Users\myjr2\.codex\references\wan22\machine-registry.json`

## Storage Roles

Keep responsibilities separate:

- workspace / GitHub:
  - workflow JSON under `workflows/`
  - conversion scripts
  - bootstrap scripts
  - manifests
- R2:
  - staged inputs
  - accepted outputs
  - node bundles for cold start
- Vast:
  - temporary execution only

## Local Key Fallback

Credential lookup order for this branch:
1. read `.env`
2. if the needed key is still missing, read root `api.txt`

`api.txt` is local-only and must stay ignored by Git.
Its format is exactly:

```text
site name
key
```

Known site names used by the automation:
- `RunComfy`
- `Cloudflare API Token`
- `Cloudflare Account ID`
- `Cloudflare R2 AccessKeyId`
- `Cloudflare R2 SecretAccessKey`
- `Vast.ai`
- `GitHub`
- `GitHub PAT 用户给过`
- `DockerHub`
- `RunPod`

Do not print `api.txt` values in logs or chat.
Only report which site names exist.

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

Current accepted direction:
- do not use paid Vast volumes as a default, because the user does not want ongoing storage fees
- do not use Docker / cache-image experiments as the production path for this branch
- R2 stores staged inputs, node bundles, and accepted outputs
- fresh machines still download model files when no real cache is present
- the only active speed optimization in this skill is machine-registry selection plus a warm-start probe

Practical rule:
- if a known machine is available, use `1.1-machine-registry`
- if no known machine is available, use `1.0-cold`
- if a new workflow needs a different cache strategy, create a separate profile and skill instead of changing this one

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
pwsh -File .\scripts\launch_wan_2_2_animate_vast_job.ps1 `
  -JobName demo-001 `
  -OfferId <offer_id> `
  -MountArgs '-v V.123456:/workspace/ComfyUI/models'
```

## Standard Paths

Workflow source:
- `workflows/Animate+Wan2.2换风格对口型.json`
- `config/vast-workflow-profiles.json -> profiles.wan_2_2_animate.workflow_source`

Local staged job:
- `output/wan_2_2_animate/<job_name>/`

Inside staged job:
- `input/美女带背景.png`
- `input/光伏2.mp4`
- `workflow_canvas.json`
- `workflow_runtime.json`
- `bootstrap_wan22_root_canvas.sh`
- `remote_submit_wan22_root_canvas.sh`
- `onstart_wan_2_2_animate.sh`
- `manifest.json`
- `run-report.json`
- `timing-summary.json`
- `result.api.json`

R2:
- `runcomfy-inputs/wan_2_2_animate/<job_name>/input/`
- `runcomfy-inputs/wan_2_2_animate/<job_name>/output/`
- `runcomfy-inputs/wan_2_2_animate/<job_name>/node-bundles/`

Remote:
- `/workspace/ComfyUI/input/美女带背景.png`
- `/workspace/ComfyUI/input/光伏2.mp4`
- `/workspace/wan22-root-canvas-run/`
- `/workspace/ComfyUI/output/*.mp4`

## Standard Success Flow

1. Stage job:

```powershell
$img = Get-ChildItem -LiteralPath '.\素材资产\美女图带光伏' -File |
  Where-Object { $_.Extension -in '.png', '.jpg', '.jpeg', '.webp' } |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

pwsh -File .\scripts\stage_wan_2_2_animate_job.ps1 `
  -JobName demo-001 `
  -ImagePath $img.FullName `
  -VideoPath .\光伏2.mp4 `
  -R2AccountId $env:CLOUDFLARE_ACCOUNT_ID `
  -R2AccessKeyId $env:R2_ACCESS_KEY_ID `
  -R2SecretAccessKey $env:R2_SECRET_ACCESS_KEY `
  -UploadToR2
```

2. Launch Vast instance:

```powershell
pwsh -File .\scripts\launch_wan_2_2_animate_vast_job.ps1 `
  -JobName demo-001 `
  -OfferId <vast_offer_id> `
  -Image vastai/comfy:v0.19.3-cuda-12.9-py312 `
  -CancelUnavail
```

3. Let generated `onstart_wan_2_2_animate.sh` pull the staged files from R2.

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
- `scripts/run_wan_2_2_animate_end_to_end.ps1`

Recommended command for this branch:

```powershell
pwsh -File .\scripts\run_wan_2_2_animate_end_to_end.ps1 `
  -JobName demo-001 `
  -VideoPath .\光伏2.mp4 `
  -OfferId <vast_offer_id>
```

If `-ImagePath` is omitted, the wrapper selects the newest image from `素材资产\美女图带光伏`.

Recommended Vast search pattern before selecting `<vast_offer_id>`:

```powershell
vastai search offers 'gpu_name=RTX_3090 num_gpus=1 gpu_ram>=24 disk_space>180 direct_port_count>=4 rented=False geolocation notin [CN,TR]' --storage 180 -o 'dph_total'
```

Resume an already running job without restaging or relaunching:

```powershell
pwsh -File .\scripts\run_wan_2_2_animate_end_to_end.ps1 `
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
Invoke-WebRequest -UseBasicParsing "http://<ip>:<mapped_8188>/view?filename=<actual_filename>&type=output&subfolder=" -OutFile '.\output\wan_2_2_animate\<job>\downloads\<actual_filename>'
```

The key rule is:
- do not guess output filenames
- do not guess remote paths
- read the filename from history first, then download it

6. Publish accepted result:

```powershell
pwsh -File .\scripts\publish_wan_2_2_animate_result.ps1 `
  -JobName demo-001 `
  -ResultPath .\output\wan_2_2_animate\demo-001\downloads\wan_2_2_animate-demo-001_00001-audio.mp4 `
  -R2AccountId $env:CLOUDFLARE_ACCOUNT_ID `
  -R2AccessKeyId $env:R2_ACCESS_KEY_ID `
  -R2SecretAccessKey $env:R2_SECRET_ACCESS_KEY
```

7. Destroy the instance after the file is confirmed.

Use the destroy helper with the instance id only:

```powershell
pwsh -File .\scripts\destroy_vast_instance.ps1 `
  -InstanceId <vast_instance_id>
```

Do not pass `-JobName` to `destroy_vast_instance.ps1`.
Resolve the instance id from `output/wan_2_2_animate/<job_name>/vast-instance.json` or `run-report.json` first, then destroy.

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
- `download_wan_2_2_animate_result.ps1`
  - re-read ComfyUI history
  - re-downloaded the finished MP4
- `summarize_vast_job_timing.ps1`
  - fetched live Vast logs
  - wrote `timing-summary.json`
- `publish_wan_2_2_animate_result.ps1`
  - uploaded the local result back to R2
  - wrote `published_result.public_url`
- `run_wan_2_2_animate_end_to_end.ps1`
  - resumed the existing job with `-SkipStage -SkipLaunch -SkipPublish`
  - wrote a step-complete `run-report.json`

The next live run `smoke-005` also proved two additional operational details:
- a fresh job can be staged successfully with the new wrapper using:
  - an image from `素材资产\美女图带光伏\`
  - video `output\vast-wan22-root-strict-3090b\光伏2.mp4`
- Vast instance creation can require UTF-8 forcing on the controller side
- download logic must tolerate `loading` instances whose `ports` are not populated yet

## Extension Rule For Future Workflows

Do not fork this whole orchestration layer just because a new workflow arrives.

For a new workflow branch:
1. save the source workflow JSON under `workflows/`
2. add a new profile entry in `config/vast-workflow-profiles.json`, including `workflow_source`
3. point it at that workflow's own stage / launch / download / publish scripts
4. keep `run_vast_workflow_job.ps1` as the shared orchestration layer

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

Before every run in this branch:
1. load `okskills`
2. load `badskills`
3. state which version path is being used:
   - `1.0-cold`: baseline cold start
   - `1.1-machine-registry`: machine registry + warm-start probe

For paid Vast runs, do not use one long silent blocking command as the operator interface.
Use the numbered sequence above and report after each phase.
During the long remote phase, report at least:
- current local step
- instance id
- host id and machine id
- whether `WARM_START=1` was injected
- whether warm-start model/node checks hit or missed, once logs show it
- latest generation progress such as `0/4`, `1/4`, `2/4`, `3/4`, `4/4`

When the operator wants visibility, use:
- `scripts/watch_vast_workflow_job.ps1`

Example:

```powershell
pwsh -File .\scripts\watch_vast_workflow_job.ps1 `
  -Profile wan_2_2_animate `
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

## 1.1 Quick Cache Probe Rule

In `1.1`, same-machine preference is only a scheduling optimization.
Still probe the remote machine quickly before assuming anything is cached.

The current probe is:
- `scripts/inspect_wan22_warmstart.py`

Expected log lines:
- `[bootstrap] warm-start hit: custom_nodes`
- `[bootstrap] warm-start miss: custom_nodes`
- `[bootstrap] warm-start hit: models`
- `[bootstrap] warm-start miss: models`
- `[bootstrap] existing torch stack is compatible with this workflow runtime`
- `[bootstrap] reinstalling torch stack from https://download.pytorch.org/whl/cu124`

Interpretation:
- hit on `models` means the big model files already exist and model download time should collapse
- miss on `models` means the run is still a cold model download even if the machine id is familiar
- hit on `custom_nodes` means node extraction can be skipped
- hit on torch means Python dependency time should shrink

If all three miss, treat the run as effectively cold start even if it was same-machine selected.

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
- reuse the machine registry and let selection prefer a previously successful machine
- reuse the same four node bundles
- use a 24GB class NVIDIA card on a `580.*` driver host
- keep R2 as staging + archive
- use `1.0-cold` by default
- use `1.1-machine-registry` only to prefer known successful machines and probe for real cache hits
