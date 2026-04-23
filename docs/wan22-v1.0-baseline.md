# Wan2.2 Talking Photo V1.0

## Scope

This V1.0 baseline freezes the currently proven Vast cold-start workflow for one talking-photo clip.

Pinned contract:
- workflow: `workflows/Animate+Wan2.2换风格对口型.json`
- source image directory: `素材资产/美女图带光伏/`
- staged ComfyUI image input: `美女带背景.png`
- video input: `光伏2.mp4`
- runtime profile: `wan_2_2_animate`
- target: one direct MP4 output with lip sync, local download, and R2 publish

This baseline is for reproducibility first. It does not yet claim minimum-cost startup.

## What Works Now

Verified path:
1. stage local assets and runtime files to R2
2. rent a fresh Vast GPU instance
3. bootstrap ComfyUI + required nodes + runtime deps on the remote host
4. submit the Wan2.2 workflow through the ComfyUI API
5. wait for `execution_success`
6. download the actual output file through `/history` + `/view`
7. publish the accepted MP4 to R2
8. collect timing summary and run report

Proven output example:
- local: `output/wan_2_2_animate/smoke-006/downloads/wan_2_2_animate-smoke-006_00001-audio.mp4`
- public: `https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev/runcomfy-inputs/wan_2_2_animate/smoke-006/output/wan_2_2_animate-smoke-006_00001-audio.mp4`

## Main Entry Point

Full run:

```powershell
pwsh -File .\scripts\run_wan_2_2_animate_end_to_end.ps1 \
  -JobName demo-001 \
  -VideoPath .\output\vast-wan22-root-strict-3090b\光伏2.mp4 \
  -OfferId <vast_offer_id>
```

If `-ImagePath` is omitted, the wrapper selects the newest image from `素材资产\美女图带光伏` and stages it as `美女带背景.png`.

Resume an already running job:

```powershell
pwsh -File .\scripts\run_wan_2_2_animate_end_to_end.ps1 \
  -JobName demo-001 \
  -SkipStage \
  -SkipLaunch
```

Watch progress with numbered steps:

```powershell
pwsh -File .\scripts\watch_vast_workflow_job.ps1 \
  -Profile wan_2_2_animate \
  -JobName demo-001 \
  -IntervalSeconds 20 \
  -MaxChecks 60
```

## Files That Define V1.0

Core files:
- `workflows/Animate+Wan2.2换风格对口型.json`
- `config/vast-workflow-profiles.json`
- `scripts/stage_wan_2_2_animate_job.ps1`
- `scripts/launch_wan_2_2_animate_vast_job.ps1`
- `scripts/download_wan_2_2_animate_result.ps1`
- `scripts/publish_wan_2_2_animate_result.ps1`
- `scripts/run_vast_workflow_job.ps1`
- `scripts/run_wan_2_2_animate_end_to_end.ps1`
- `scripts/watch_vast_workflow_job.ps1`
- `scripts/summarize_vast_job_timing.ps1`
- `scripts/bootstrap_wan22_root_canvas.sh`
- `scripts/generate_wan_2_2_animate_onstart.mjs`
- `skills/okskills/SKILL.md`
- `skills/badskills/SKILL.md`

## Verified Timing Snapshot

From `smoke-006`:
- total until local download: `1412s`
- total until publish: `1534s`
- prompt execution: `00:11:48`
- remote bootstrap: `504s`
- python dependency phase: `176s`
- model download phase: `270s`

Interpretation:
- V1.0 is functionally stable on fresh hosts
- V1.0 is not yet optimized for startup time or bandwidth cost

## Cost Snapshot

From `smoke-006` approximate totals:
- compute + storage until publish: about `$0.078`
- bandwidth: about `$0.029`
- total: about `$0.107`

This is the baseline to beat in later optimization work.

## Out Of Scope For V1.0

Not part of this version:
- prewarmed Docker runtime
- model cache persistence across new machines
- node bundle preinstallation in the base image
- segmented 60s to 120s continuation pipeline
- automatic background regeneration pipeline
- multi-workflow profile library

## Next Optimization Track

The next round should optimize startup time and waste, without changing the V1.0 baseline contract:
1. prefer known successful Vast machines through the machine registry
2. keep workflow source files under `workflows/`
3. reduce repeated model and node download work only after a cache strategy is proven
4. keep V1.0 as the rollback point if optimization work regresses
