---
name: badskills
description: Use when the Wan2.2 talking-photo pipeline is failing on fresh Vast machines, when cold start keeps burning time or money, or when you need the known symptom-to-root-cause map before attempting another retry.
---

# badskills

## Overview

This skill records the failure path only.

Use it before retrying a broken cold start, so the next action is based on evidence instead of another blind rebuild.

## Fixed Scope

These failures were observed on the same branch:
- image: `美女带背景.png`
- video: `光伏2.mp4`
- workflow: `Animate+Wan2.2换风格对口型.json`
- runtime chain:
  - `scripts/prepare_wan22_root_canvas_prompt.mjs`
  - `scripts/bootstrap_wan22_root_canvas.sh`
  - `scripts/remote_submit_wan22_root_canvas.sh`

## Failure Ledger

- Symptom: instance says `running`, but API is dead or returns `502`
  - Root cause: Vast env injection was malformed, so expected variables were not really injected
  - Action: inspect `vastai show instance --raw`, especially `extra_env`; if dirty, recreate instead of debugging inside the machine

- Symptom: cold start spends forever reinstalling giant packages and then drifts into new import crashes
  - Root cause: old plugin requirements reintroduced heavy stacks like `accelerate`, `diffusers`, `peft`, `spandrel`
  - Action: keep filtered requirements logic in `bootstrap_wan22_root_canvas.sh`; do not restore removed heavy explicit installs

- Symptom: a previous Docker image looked like an optimization but became slow or unusable to pull
  - Root cause: it was effectively a heavy image strategy and mixed too much runtime state into one artifact
  - Action: for `1.2-light`, rebuild the Docker directory as a clean light image only:
    - no model files
    - no old extra nodes
    - no `ComfyUI-Easy-Use`
    - no `ComfyUI-WanVideoWrapper`
    - no `ComfyUI-segment-anything-2`
    - no explicit `accelerate`, `diffusers`, `peft`, `spandrel`, or `clip_interrogator`

- Symptom: a new model family such as LTX 2.3 gets mixed into the Wan2.2 `1.2-light` image
  - Root cause: treating the light image as a general AI-video environment instead of a workflow-specific runtime
  - Action:
    - do not add LTX 2.3 dependencies, nodes, or model assumptions to `001skills`
    - create a new profile and image tag for LTX 2.3
    - only share orchestration scripts when the stage/launch/download/publish contract is still compatible

- Symptom: cold start appears "stuck", but logs only show pip and curl progress for a long time
  - Root cause: the machine is still doing legitimate bootstrap work:
    - torch / cu124 wheels from `download.pytorch.org`
    - multi-GB models from Hugging Face
  - Action: do not misclassify this as a crash unless progress stops completely for an abnormal amount of time; read the latest log phase before killing the run

- Symptom: torch install dies with `ReadTimeoutError`
  - Root cause: large wheel download from PyTorch mirror timed out mid-transfer
  - Action: use long pip timeout and retry settings; if mirror instability persists, restart from staged assets, not from an ad hoc machine state

- Symptom: Vast shows `loading`, logs say `No such container`
  - Root cause: image pull is still in progress and container does not exist yet
  - Action: wait until `actual_status=running`; do not misclassify as workflow failure too early

- Symptom: instance never becomes usable and status mentions host port bind failure
  - Root cause: host-level port conflict, often on `8188`
  - Action: destroy immediately and move hosts; this is not a workflow bug

- Symptom: the cheapest host looks attractive on paper, but cold start is slow or unstable because external registries and model sources are hard to reach
  - Root cause: host geolocation is mainland China, while this branch depends on unattended pulls from Docker Hub, PyTorch, and Hugging Face
  - Action: for `001skills`, exclude `CN` when searching Vast offers unless the runtime has been explicitly rebuilt for China-network constraints

- Symptom: ComfyUI exits with `cudaGetDeviceCount Error 804`
  - Root cause: host driver and container CUDA stack are incompatible
  - Evidence seen on a failed host: `570.211.01`
  - Action: prefer `580.*` driver hosts; if Error 804 appears, stop and destroy

- Symptom: `1.2-light` starts but still reinstalls torch/cu124 on a fresh machine
  - Root cause: the selected host driver only supports CUDA below 12.4, so the prewarmed torch stack is not considered usable
  - Evidence seen on failed `v12-light-fresh-001`: driver `535.274.02`, `cuda_max_good=12.2`
  - Action: destroy and search with `cuda_max_good>=12.4`

- Symptom: `1.2-light` was retested on the exact same physical machine as a successful `1.0`, but still reached `bootstrap.model_downloads` later than `1.0`
  - Root cause: the `1.2-light` path was not actually preserving its preinstalled custom nodes at runtime
  - Evidence from `v12-light-sameA-001` on host `264182` / machine `42568`:
    - the container spent extra time in image preparation before `running`
    - `remote_submit_wan22_root_canvas.sh` replaced `COMFY_APP_ROOT/custom_nodes` with a symlink to `/workspace/ComfyUI/custom_nodes`
    - preinstalled nodes baked into the image were therefore hidden or removed before ComfyUI restart
    - `bootstrap` then reinstalled custom-node requirements and still reinstalled `torch/cu124`
  - Action:
    - in prewarmed mode, inspect and preserve `COMFY_APP_ROOT/custom_nodes`
    - do not overwrite preinstalled `custom_nodes` with an empty workspace symlink
    - do not treat same-machine `1.2` slowness as a host problem; fix `1.2` itself first

- Symptom: custom nodes were baked into `/workspace/ComfyUI` during image build, but missing at runtime
  - Root cause: `/workspace` is a runtime-mounted data location on Vast, so image-baked content there is not a reliable place for prewarmed assets
  - Action:
    - bake prewarmed `custom_nodes` into `COMFY_APP_ROOT` or another non-mounted application path
    - keep runtime-generated inputs, outputs, and models in `/workspace`

- Symptom: custom nodes were baked into `/opt/workspace-internal/ComfyUI`, but `1.2-light` still logged `prewarmed image miss: custom_nodes`
  - Root cause: the Vast Comfy base image can prepare or refresh the runnable ComfyUI tree at container startup, so that path is not stable enough for image-baked prewarm payloads
  - Evidence from `v12-light-fixed-smoke-001` on instance `35469431`:
    - image started successfully
    - `PREWARMED_IMAGE=1` was injected
    - bootstrap still reported missing `ComfyUI-GGUF`, `ComfyUI-KJNodes`, `ComfyUI-VideoHelperSuite`, and `ComfyUI-WanAnimatePreprocess`
    - the run was destroyed before inference because continuing would only repeat the cold path
  - Action:
    - store image-baked node payloads under `/opt/wan22-prewarm/custom_nodes`
    - at bootstrap time copy them into `$COMFY_APP_ROOT/custom_nodes`
    - only accept `1.2-light` when logs show `prewarmed image hit: custom_nodes`
    - avoid duplicate GitHub Actions workflows pushing the same Docker tag

- Symptom: after rebuilding `1.2-light`, a retest on the same host still behaved like the old image
  - Root cause: Docker tags such as `1.2-light` are mutable; a host that already pulled the old tag may keep using the cached local image
  - Evidence from `v12-light-fixed-smoke-002`:
    - same host and machine as the previous failed smoke test: `344939 / 68107`
    - startup still showed old `prewarmed image miss: custom_nodes` behavior
  - Action:
    - for validation of a newly built image, use the immutable Git SHA tag, for example `j1c2k3/codex-comfy-wan22-root-canvas:sha-b14e144`
    - or force a different clean host
    - only move `config/vast-workflow-profiles.json` back to the mutable `1.2-light` tag after the SHA-tag smoke test passes

- Symptom: even the immutable SHA-tag `1.2` image still reinstalled custom-node dependencies and torch
  - Root cause: the launch path still injected Vast's default `PROVISIONING_SCRIPT`, which can rebuild or refresh the ComfyUI runtime at container startup and erase the benefit of a prewarmed image
  - Evidence from `v12-light-fixed-smoke-003`:
    - image tag was `sha-b14e144`
    - instance environment still included `PROVISIONING_SCRIPT=.../comfyui/provisioning_scripts/default.sh`
    - bootstrap reinstalled custom-node requirements and torch
    - model download phase started only around 309 seconds after launch
  - Action:
    - when `-PrewarmedImage` is used, pass `-SkipDefaultProvisioning` to instance creation
    - verify `extra_env` does not contain `PROVISIONING_SCRIPT`
    - only continue to full inference if bootstrap logs show custom nodes and torch are reused

- Symptom: after removing `PROVISIONING_SCRIPT`, `1.2-light` still missed custom nodes and reinstalled torch
  - Evidence from `v12-light-fixed-smoke-004` on instance `35470507`:
    - `extra_env` correctly had no `PROVISIONING_SCRIPT`
    - image tag was immutable `sha-b14e144`
    - container spent about 366 seconds before running due to pulling the 9.6GB image
    - bootstrap still logged `prewarmed image miss: custom_nodes`
    - bootstrap still logged `reinstalling torch stack`
    - model download phase started around 507 seconds after launch
  - Conclusion:
    - `1.2-light` is currently slower than the known `1.0-cold` path
    - do not run full inference with this light-image path as a production optimization
    - next real optimization should be either `1.3-heavy` with models included or a provider/cache strategy that actually preserves model and dependency files

- Symptom: ComfyUI gets deeper into startup, then crashes with `ModuleNotFoundError: torchsde`
  - Root cause: bootstrap missed a core Comfy sampler dependency
  - Action: install `torchsde` in bootstrap, then re-stage before rerun

- Symptom: after fixing one missing module, the next startup dies on another base module like `aiohttp`
  - Root cause: bootstrap installed custom-node extras only, but not filtered ComfyUI core requirements
  - Action: install filtered `$COMFY_APP_ROOT/requirements.txt` during bootstrap

- Symptom: bootstrap log says heavy requirements are skipped, but later the same run still installs `accelerate`, `diffusers`, or `peft`
  - Root cause: a second explicit install block reintroduced them
  - Action: remove those explicit package installs; otherwise cold start cost and failure surface both increase

- Symptom: prompt submission fails with `Invalid video file: 光伏2.mp4` or `Invalid image file: 美女带背景.png`
  - Root cause: `workflow_runtime.json` used Chinese names, but generated onstart script still downloaded files as `source.mp4` and `speaker.png`
  - Action: keep filenames consistent end to end

- Symptom: ComfyUI starts, then unused custom nodes die on import errors and pollute the logs
  - Root cause: staged bundle set included unused extras such as:
    - `ComfyUI-Easy-Use`
    - `ComfyUI-WanVideoWrapper`
    - `ComfyUI-segment-anything-2`
  - Action: keep only the four validated bundles in this branch

- Symptom: bootstrap reaches `[bootstrap] done`, but ComfyUI immediately exits with `ModuleNotFoundError: transformers`
  - Root cause: filtered core requirements no longer brought `transformers` back, but ComfyUI still imports it early
  - Action: explicitly install `transformers>=4.50.3`

- Symptom: local scripts were fixed, but remote machine still used stale files
  - Root cause: job package was not re-staged and re-uploaded after script edits
  - Action: always rerun `stage_001skills_job.ps1` after any change to bootstrap, runtime JSON generation, or onstart generation

- Symptom: `onstart_001skills.sh` dies during long R2 pulls with `curl: (35) Recv failure: Connection reset by peer`
  - Root cause: earlier fetch logic was too fragile for big staged downloads
  - Action: keep hardened curl flags in `generate_001skills_onstart.mjs`:
    - `--http1.1`
    - `--retry 10`
    - `--retry-all-errors`
    - `--connect-timeout 30`
    - `--max-time 1800`

- Symptom: pulling finished files back to local wastes time on Windows with `vastai copy`
  - Root cause: `vastai copy` may require local `rsync`, which is not guaranteed in this controller environment
  - Action: do not start output retrieval with `vastai copy`; first use ComfyUI history API to get the real output filename, then download through `/view`

- Symptom: old job directory exists, but output download fails with missing `8188/tcp` bind information
  - Root cause: earlier saved `vast-instance.json` snapshots did not always include the final mapped ports
  - Action: let the download path fall back to `vastai show instance <id> --raw` and refresh local instance metadata before failing

- Symptom: wrapper or runner fails with "Missing an argument for parameter 'StageArgs'"
  - Root cause: PowerShell treats an explicitly passed empty string-array parameter as a missing value
  - Action: only pass `-StageArgs`, `-LaunchArgs`, or `-PublishArgs` when the array actually contains values

- Symptom: adding a new workflow causes another copy-paste orchestration branch
  - Root cause: workflow-specific concerns were mixed into the orchestration layer
  - Action: register a new entry in `config/vast-workflow-profiles.json` and keep the shared runner generic

- Symptom: `vastai create instance --raw` fails locally with a decode error like `'gbk' codec can't decode byte ...`
  - Root cause: the local controller process is decoding Vast CLI output with a non-UTF-8 code page
  - Action: force `PYTHONUTF8=1` and `PYTHONIOENCODING=utf-8` around the `vastai` call

- Symptom: resumed job fails immediately in download with `Instance metadata missing 8188/tcp port binding`
  - Root cause: the instance is still in `loading`, so `ports` are not populated yet even though the instance id already exists
  - Action: when `-Wait` is enabled, do not fail early; keep retrying base URL resolution until `8188/tcp` appears

- Symptom: `actual_status` flips between `loading`, `running`, or even transient `offline` while `cur_state` is still `running`
  - Root cause: Vast host state and port publication can lag behind the local orchestration view
  - Action: read `ports`, `status_msg`, and elapsed time together before deciding the machine is broken

- Symptom: the operator cannot tell what phase the run is in because the orchestration was started as one long blocking command
  - Root cause: stage / launch / monitor were not separated in the reporting path
  - Action: report progress as numbered steps and use `scripts/watch_vast_workflow_job.ps1` to poll instance status plus relevant logs

- Symptom: `launch` fails with a missing `manifest.json` right after `stage` was started
  - Root cause: `stage` and `launch` were incorrectly run in parallel, so launch read the job directory before stage had finished writing and uploading the manifest
  - Action: never parallelize dependent lifecycle steps; enforce this sequence:
    1. `stage` complete
    2. `launch` complete
    3. `watch`
    4. `download`
    5. `fetch_logs`
    6. `summarize_timings`
    7. `publish`

- Symptom: two independent `stage_001skills_job.ps1` runs fail with Git errors such as `Cannot fast-forward to multiple branches`
  - Root cause: both stage processes update the shared local custom-node cache under `.cache/001skills/custom_nodes` at the same time
  - Evidence from `v10-stability-b` initial stage attempt:
    - A and B were staged in parallel
    - A succeeded
    - B failed updating `.cache/001skills/custom_nodes/ComfyUI-GGUF`
  - Action:
    - stage jobs sequentially for this branch
    - only launch machines after all staging is complete
    - do not parallelize local cache mutation unless each job gets an isolated cache directory

- Symptom: `watch_vast_workflow_job.ps1` crashes with `Cannot bind argument to parameter 'Lines' because it is an empty string`
  - Root cause: a fresh instance can return no logs yet, and the watch helper treated the log list as mandatory non-empty input
  - Action: watch scripts must tolerate empty log output and print `<no relevant log lines yet>` instead of stopping the run

- Symptom: local download succeeds, but `publish` fails with `Cannot bind argument to parameter 'ScriptArgs' because it is an empty string`
  - Root cause: the controller `.env` used `ASSET_S3_*` names while the wrapper defaulted to `CLOUDFLARE_*` / `R2_*`, so empty credential values were still appended into `PublishArgs`
  - Action: support `ASSET_S3_*` fallback in stage and publish scripts, and never append an arg pair when the value is blank

- Symptom: cleanup step fails immediately with `A parameter cannot be found that matches parameter name 'JobName'`
  - Root cause: `scripts/destroy_vast_instance.ps1` accepts only `-InstanceId`, but the operator guessed it behaved like the job wrappers
  - Action: call it only as `pwsh -File .\scripts\destroy_vast_instance.ps1 -InstanceId <id>`; resolve the id from `vast-instance.json` before cleanup

## Fast Triage Order

1. `vastai show instance --raw`
2. Check:
   - `actual_status`
   - `status_msg`
   - `driver_version`
3. If port bind failure:
   - destroy immediately
4. If CUDA Error 804:
   - destroy immediately
5. If container not created yet:
   - wait
6. If ComfyUI import crash:
   - patch bootstrap
   - re-stage
   - retry on a clean machine

## Stop-Loss Rules

Destroy and change host when:
- host port bind fails
- driver / CUDA mismatch triggers Error 804
- the host is clearly incompatible

Do not destroy immediately when:
- image is still pulling
- container is not created yet
- model download is still in progress

## Verified Lessons

- a fresh host can succeed; mother-machine dependence was not the real root cause
- the successful branch is smaller than earlier versions
- unused custom nodes were one of the main sources of wasted time and false debugging trails
- consistent Chinese filenames are part of the working contract, not cosmetic detail
- R2 staging must be regenerated after every runtime script change
- Vast local volumes are not a general cross-machine solution; they are tied to one physical machine
- if you want faster retries across the same machine, volumes help
- if you want faster recovery across different machines, volumes alone do not solve it
- for this branch, the cheapest `CN` host is not automatically the cheapest real choice once retry waste and network friction are counted

## Log Patterns That Are Slow But Healthy

These log patterns are slow, but they are not failures by themselves:

- `Downloading trampoline-0.1.2-py3-none-any.whl`
- `Installing collected packages: trampoline, torchsde`
- `Successfully installed torchsde-0.2.6 trampoline-0.1.2`
- `[bootstrap] python module exists: color_matcher`
- `[bootstrap] creating model directories`
- `[bootstrap] downloading: Wan2.2-Animate-14B-Q4_K_S.gguf`
- `[bootstrap] downloading: umt5_xxl_fp8_e4m3fn_scaled.safetensors`

Interpret them like this:
- pip output means dependency phase
- `creating model directories` means dependency phase is ending
- large curl percentage output means model phase is active
- changing ETA during curl output is normal and should not be treated as a hard hang

## Known Good Signals

When a run is probably healthy, you should see:
- `torch 2.6.0+cu124`
- GPU detected correctly
- ComfyUI API responds on `8188`
- queue enters `running`
- history ends with `execution_success`
- `run-report.json` records completed local steps with durations
- `timing-summary.json` records remote lifecycle timing

## Output Retrieval Anti-Pattern

Do not use this sequence as the default on Windows:
- try `vastai copy`
- then try SSH
- then inspect remote directories

Use this sequence instead:
1. `GET /history` or `GET /history/{prompt_id}`
2. read `outputs -> filename/type/subfolder`
3. `GET /view?...` to download the file

Why:
- history gives the authoritative filename
- `/view` avoids controller-side `rsync` dependency
- this removes needless trial-and-error during the last step

## Visibility Rule

Do not claim a run is "still going" without showing evidence.

When the operator asks for visibility:
1. show current numbered step
2. show current instance state
3. show whether `8188` is mapped
4. show the latest relevant log lines

In this chat environment, continuous byte-for-byte log streaming is not guaranteed.
Use repeated polling output instead of pretending true live streaming exists.

Do not start a paid Vast run and then wait silently for 20 minutes.
This has already caused operator confusion.

Required live-run reporting cadence:
1. after `stage`, report duration and staged job path
2. after `launch`, report instance id, host id, machine id, mapped `8188` port, and whether `WARM_START=1`
3. during `bootstrap`, report whether it is in custom node setup, Python dependency setup, or model download
4. during inference, report the latest progress marker such as `0/4`, `1/4`, `2/4`, `3/4`, or `4/4`
5. after output appears, report download path, publish URL, and destroy status

Avoid one long monolithic `run_001skills_end_to_end.ps1` call when the human is actively watching.
Use short polling with `watch_vast_workflow_job.ps1` so progress is visible.

## Structural Rule For Future Workflows

When the workflow itself changes, do not assume the proven `001skills` output-matching logic still applies.

You must re-prove at least these workflow-specific pieces:
- which stage script prepares its inputs
- which output prefix or filename pattern identifies the right result
- whether publish rules still map to the same R2 prefix

The orchestration layer can stay shared.
The workflow contract cannot be guessed.

## Same-Machine Trap

Do not confuse these two ideas:
- same-machine preference
- real cache reuse

What was proven:
- renting the same physical machine again can reduce startup wait
- it can save a few minutes before bootstrap or before instance readiness

What was not proven:
- `custom_nodes` will already be reusable
- models will already be reusable
- torch will already be reusable

Concrete example from the validated `56268` machine:
- total runtime improved versus the first cold run
- but logs still showed:
  - `warm-start miss: custom_nodes`
  - `warm-start miss: models`
  - torch reinstall or non-hit behavior

So the correct rule is:
- treat same-machine preference as a probabilistic speedup
- do not treat it as a guaranteed cache hit

## Registry Update Trap

When the same machine has multiple successful runs, never let an older success overwrite a newer one.

Registry write logic must preserve the newest `last_success_at` record for a machine.
Otherwise selection can drift back to stale timing data and stale offer assumptions.

## Reminder

The job is not to keep a broken machine alive.

The job is to identify whether the failure is:
- host problem
- bootstrap problem
- staged asset problem
- workflow problem

Then take the cheapest next action.
