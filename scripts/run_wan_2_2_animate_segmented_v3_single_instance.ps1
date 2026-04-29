param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$VideoPath,

    [string]$ImagePath,

    [string]$ImageAssetDir = ".\素材资产\美女图带光伏",

    [ValidateSet("1.0-cold", "1.1-machine-registry")]
    [string]$RuntimeVersion = "1.1-machine-registry",

    [string]$OfferId,

    [string]$RegistryPath = ".\data\vast-machine-registry.json",

    [string]$SearchQuery = "gpu_name=RTX_3090 num_gpus=1 gpu_ram>=24 cuda_max_good>=12.4 disk_space>180 direct_port_count>=4 rented=False geolocation notin [CN,TR]",

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [int]$DiskGb = 180,

    [int]$SegmentSeconds = 10,

    [int]$ContinueMotionFrames = 5,

    [int]$MaxSegments = 3,

    [switch]$CancelUnavail,

    [switch]$SkipPublish,

    [switch]$PrepareOnly,

    [switch]$KeepInstanceForDebug,

    [int]$PollIntervalSeconds = 30,

    [int]$MaxWaitMinutes = 360,

    [string]$R2Prefix = $(if ($env:ASSET_S3_PREFIX) { $env:ASSET_S3_PREFIX.TrimEnd("/") + "/wan_2_2_animate_segmented" } elseif ($env:R2_PREFIX) { $env:R2_PREFIX + "_segmented" } else { "runcomfy-inputs/wan_2_2_animate_segmented" }),

    [string]$R2Bucket = $(if ($env:ASSET_S3_BUCKET) { $env:ASSET_S3_BUCKET } elseif ($env:R2_BUCKET) { $env:R2_BUCKET } else { "runcomfy" }),

    [string]$R2PublicBaseUrl = $(if ($env:ASSET_S3_PUBLIC_BASE_URL) { $env:ASSET_S3_PUBLIC_BASE_URL } elseif ($env:R2_PUBLIC_BASE_URL) { $env:R2_PUBLIC_BASE_URL } else { "https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev" }),

    [string]$R2AccountId = $(if ($env:CLOUDFLARE_ACCOUNT_ID) { $env:CLOUDFLARE_ACCOUNT_ID } elseif ($env:ASSET_S3_ACCOUNT_ID) { $env:ASSET_S3_ACCOUNT_ID } else { "" }),

    [string]$R2AccessKeyId = $(if ($env:R2_ACCESS_KEY_ID) { $env:R2_ACCESS_KEY_ID } elseif ($env:ASSET_S3_ACCESS_KEY_ID) { $env:ASSET_S3_ACCESS_KEY_ID } else { "" }),

    [string]$R2SecretAccessKey = $(if ($env:R2_SECRET_ACCESS_KEY) { $env:R2_SECRET_ACCESS_KEY } elseif ($env:ASSET_S3_SECRET_ACCESS_KEY) { $env:ASSET_S3_SECRET_ACCESS_KEY } else { "" })
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
$selectOfferScript = Join-Path $repoRoot "scripts\select_wan_2_2_animate_vast_offer.ps1"
$createInstanceScript = Join-Path $repoRoot "scripts\create_vast_instance_minimal.ps1"
$destroyInstanceScript = Join-Path $repoRoot "scripts\destroy_vast_instance.ps1"
$prepareScript = Join-Path $repoRoot "scripts\prepare_wan22_root_canvas_prompt.mjs"
$bootstrapScript = Join-Path $repoRoot "scripts\bootstrap_wan22_root_canvas.sh"
$warmstartInspectorScript = Join-Path $repoRoot "scripts\inspect_wan22_warmstart.py"
$uploadScript = Join-Path $repoRoot "scripts\r2_upload.py"
$registryPy = Join-Path $repoRoot "scripts\vast_machine_registry.py"
$ffmpegPath = Join-Path $repoRoot "node_modules\ffmpeg-static\ffmpeg.exe"
$ffprobePath = Join-Path $repoRoot "node_modules\ffprobe-static\bin\win32\x64\ffprobe.exe"
$profileConfigPath = Join-Path $repoRoot "config\vast-workflow-profiles.json"

foreach ($required in @(
    $r2HelperPath,
    $selectOfferScript,
    $createInstanceScript,
    $destroyInstanceScript,
    $prepareScript,
    $bootstrapScript,
    $warmstartInspectorScript,
    $uploadScript,
    $registryPy,
    $ffmpegPath,
    $ffprobePath,
    $profileConfigPath
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required path: $required"
    }
}

. $r2HelperPath
Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
if ([string]::IsNullOrWhiteSpace($R2AccessKeyId) -and $env:ASSET_S3_ACCESS_KEY_ID) {
    $R2AccessKeyId = $env:ASSET_S3_ACCESS_KEY_ID
}
if ([string]::IsNullOrWhiteSpace($R2SecretAccessKey) -and $env:ASSET_S3_SECRET_ACCESS_KEY) {
    $R2SecretAccessKey = $env:ASSET_S3_SECRET_ACCESS_KEY
}
$R2AccountId = Resolve-R2AccountId -CloudflareAccountId $R2AccountId -AssetAccountId $env:ASSET_S3_ACCOUNT_ID -Endpoint $env:ASSET_S3_ENDPOINT

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $Data
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $Data | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Resolve-DefaultImage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssetDir
    )

    $resolvedAssetDir = (Resolve-Path -LiteralPath $AssetDir).Path
    $candidate = Get-ChildItem -LiteralPath $resolvedAssetDir -File |
        Where-Object { @(".png", ".jpg", ".jpeg", ".webp") -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        throw "No image asset found in $resolvedAssetDir"
    }
    $candidate.FullName
}

function Get-VideoDurationSeconds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $raw = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $Path
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw "Failed to read video duration: $Path"
    }
    [double]$raw
}

function New-VideoSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [double]$StartSeconds,

        [Parameter(Mandatory = $true)]
        [double]$DurationSeconds,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    & $ffmpegPath `
        -y `
        -ss $StartSeconds.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture) `
        -i $InputPath `
        -t $DurationSeconds.ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture) `
        -c:v libx264 `
        -preset veryfast `
        -crf 18 `
        -c:a aac `
        -movflags +faststart `
        $OutputPath | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg split failed: $OutputPath"
    }
}

function Merge-VideoSegments {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$InputPaths,

        [Parameter(Mandatory = $true)]
        [string]$ListPath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $lines = foreach ($path in $InputPaths) {
        $normalized = $path.Replace("\", "/").Replace("'", "''")
        "file '$normalized'"
    }
    Set-Content -LiteralPath $ListPath -Value $lines -Encoding ASCII

    & $ffmpegPath -y -f concat -safe 0 -i $ListPath -c copy $OutputPath | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    & $ffmpegPath -y -f concat -safe 0 -i $ListPath -c:v libx264 -preset veryfast -crf 18 -c:a aac -movflags +faststart $OutputPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg merge failed: $OutputPath"
    }
}

function Encode-R2Key {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    (($Key -split "/") | ForEach-Object { [uri]::EscapeDataString($_) }) -join "/"
}

function Get-EncodedPublicUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    "$($R2PublicBaseUrl.TrimEnd('/'))/$(Encode-R2Key -Key $Key)"
}

function Remove-InstanceSecrets {
    param(
        [Parameter(Mandatory = $true)]
        $Instance
    )

    $Instance |
        Select-Object * -ExcludeProperty @(
            "instance_api_key",
            "jupyter_token",
            "onstart",
            "ssh_key",
            "extra_env"
        )
}

function Redact-LogText {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return ""
    }

    $redacted = $Text -replace '("instance_api_key"\s*:\s*")[^"]+', '$1<redacted>'
    $redacted = $redacted -replace '(token=)[A-Za-z0-9._-]+', '$1<redacted>'
    $redacted = $redacted -replace '(jupyter_token=)[A-Za-z0-9._-]+', '$1<redacted>'
    $redacted
}

function Test-NodeBundleDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    foreach ($bundleName in @(
        "ComfyUI-GGUF.zip",
        "ComfyUI-KJNodes.zip",
        "ComfyUI-VideoHelperSuite.zip",
        "ComfyUI-WanAnimatePreprocess.zip"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $bundleName))) {
            return $false
        }
    }

    return $true
}

function Resolve-NodeBundleSourceDir {
    $preferred = Join-Path $repoRoot "output\vast-wan22-root-strict-3090b\node-bundles"
    if (Test-NodeBundleDirectory -Path $preferred) {
        return $preferred
    }

    $jobRoot = Join-Path $repoRoot "output\wan_2_2_animate"
    if (Test-Path -LiteralPath $jobRoot) {
        $candidate = Get-ChildItem -LiteralPath $jobRoot -Directory |
            ForEach-Object { Join-Path $_.FullName "node-bundles" } |
            Where-Object { Test-NodeBundleDirectory -Path $_ } |
            Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending |
            Select-Object -First 1
        if ($candidate) {
            return [string]$candidate
        }
    }

    throw "Missing reusable node bundle directory with required zips."
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $step = [ordered]@{
        name = $Name
        started_at = (Get-Date).ToString("s")
        ended_at = $null
        duration_seconds = $null
        status = "running"
        notes = @()
    }
    $script:report.steps = @($script:report.steps) + $step
    Write-JsonFile -Path $script:reportPath -Data $script:report
    Write-Host "[$Name] start"

    try {
        $result = & $Action
        $ended = Get-Date
        $started = [datetime]::Parse($step.started_at, [System.Globalization.CultureInfo]::InvariantCulture)
        $step.ended_at = $ended.ToString("s")
        $step.duration_seconds = [math]::Round(($ended - $started).TotalSeconds, 3)
        $step.status = "succeeded"
        if ($null -ne $result) {
            $step.notes = @($result | ForEach-Object { "$_" })
        }
        $script:report.steps[$script:report.steps.Count - 1] = $step
        Write-JsonFile -Path $script:reportPath -Data $script:report
        Write-Host "[$Name] succeeded duration_seconds=$($step.duration_seconds)"
        return $result
    }
    catch {
        $ended = Get-Date
        $started = [datetime]::Parse($step.started_at, [System.Globalization.CultureInfo]::InvariantCulture)
        $step.ended_at = $ended.ToString("s")
        $step.duration_seconds = [math]::Round(($ended - $started).TotalSeconds, 3)
        $step.status = "failed"
        $step.notes = @($_.Exception.Message)
        $script:report.steps[$script:report.steps.Count - 1] = $step
        $script:report.status = "failed"
        $script:report.error = $_.Exception.Message
        $script:report.ended_at = (Get-Date).ToString("s")
        Write-JsonFile -Path $script:reportPath -Data $script:report
        throw
    }
}

function Get-BaseUrlFromInstance {
    param(
        [Parameter(Mandatory = $true)]
        $Instance
    )

    $portBindings = $Instance.ports.'8188/tcp'
    if (-not $portBindings -or $portBindings.Count -lt 1) {
        return ""
    }
    $hostPort = $portBindings[0].HostPort
    $publicIp = $Instance.public_ipaddr
    if ([string]::IsNullOrWhiteSpace($hostPort) -or [string]::IsNullOrWhiteSpace($publicIp)) {
        return ""
    }
    "http://{0}:{1}" -f $publicIp, $hostPort
}

function Get-LiveInstance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId
    )

    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = "utf-8"
    try {
        $raw = & vastai show instance $InstanceId --raw 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($raw | Out-String))) {
            return $null
        }
        $instance = $raw | ConvertFrom-Json
        Remove-InstanceSecrets -Instance $instance
    }
    finally {
        if ($null -eq $previousPythonIoEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONIOENCODING = $previousPythonIoEncoding
        }
    }
}

function Find-OutputCandidate {
    param(
        [Parameter(Mandatory = $true)]
        $History,

        [Parameter(Mandatory = $true)]
        [string]$Prefix
    )

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($historyProperty in $History.PSObject.Properties) {
        $promptId = $historyProperty.Name
        $entry = $historyProperty.Value
        if (-not $entry.outputs) {
            continue
        }
        foreach ($outputProperty in $entry.outputs.PSObject.Properties) {
            $outputNode = $outputProperty.Value
            if (-not $outputNode.gifs) {
                continue
            }
            foreach ($gif in $outputNode.gifs) {
                if ($gif.type -ne "output") {
                    continue
                }
                if (-not $gif.filename.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
                $candidates.Add([pscustomobject]@{
                    PromptId = $promptId
                    NodeId = $outputProperty.Name
                    Filename = $gif.filename
                    Type = $gif.type
                    Subfolder = [string]$gif.subfolder
                    Format = [string]$gif.format
                })
            }
        }
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    $candidates | Sort-Object Filename -Descending | Select-Object -First 1
}

function Get-History {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl
    )

    Invoke-RestMethod -Uri "$($BaseUrl.TrimEnd('/'))/history" -Method Get -TimeoutSec 60
}

function Download-ComfyOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        $Candidate,

        [Parameter(Mandatory = $true)]
        [string]$OutputDir
    )

    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $query = "filename=$([uri]::EscapeDataString($Candidate.Filename))&type=$([uri]::EscapeDataString($Candidate.Type))&subfolder=$([uri]::EscapeDataString($Candidate.Subfolder))"
    $downloadUrl = "$($BaseUrl.TrimEnd('/'))/view?$query"
    $localPath = Join-Path (Resolve-Path -LiteralPath $OutputDir).Path $Candidate.Filename
    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $localPath -TimeoutSec 1800
    $localPath
}

function New-RemoteSegmentedScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [int]$SegmentCount,

        [Parameter(Mandatory = $true)]
        [int]$ContinuationFrameCount
    )

    $content = @"
#!/usr/bin/env bash
set -euo pipefail

COMFY_APP_ROOT="`${COMFY_APP_ROOT:-/opt/workspace-internal/ComfyUI}"
COMFY_ROOT="`${COMFY_ROOT:-/workspace/ComfyUI}"
RUN_DIR="`${RUN_DIR:-/workspace/wan22-segmented-v3-run}"
BUNDLE_DIR="`${BUNDLE_DIR:-`$RUN_DIR/node-bundles}"
BOOTSTRAP_PATH="`$RUN_DIR/bootstrap_wan22_root_canvas.sh"
COMFY_LOG_PATH="`$RUN_DIR/comfyui.log"
COMFY_PID_PATH="`$RUN_DIR/comfyui.pid"
SEGMENT_COUNT="$SegmentCount"
CONTINUE_FRAME_COUNT="$ContinuationFrameCount"
export COMFY_APP_ROOT COMFY_ROOT RUN_DIR BUNDLE_DIR

mkdir -p "`$RUN_DIR"
exec > >(tee -a "`$RUN_DIR/run.log") 2>&1

stage_event() {
  local stage_name="`$1"
  local stage_status="`$2"
  echo "[stage] `$(date -Iseconds) `$stage_name `$stage_status"
}

echo "[remote-v3] started at `$(date -Iseconds)"
echo "[remote-v3] segment_count=`$SEGMENT_COUNT continue_frames=`$CONTINUE_FRAME_COUNT"

if [ ! -f "`$BOOTSTRAP_PATH" ]; then
  echo "[remote-v3] missing bootstrap: `$BOOTSTRAP_PATH" >&2
  exit 1
fi

stage_event "remote.bootstrap" "start"
bash "`$BOOTSTRAP_PATH"
stage_event "remote.bootstrap" "end"

stage_event "remote.restart_comfy" "start"
if [ "`$COMFY_APP_ROOT" != "`$COMFY_ROOT" ]; then
  mkdir -p "`$COMFY_ROOT/input" "`$COMFY_ROOT/output" "`$COMFY_ROOT/temp" "`$COMFY_ROOT/custom_nodes" "`$COMFY_ROOT/models"
  for entry in input output temp models; do
    rm -rf "`$COMFY_APP_ROOT/`$entry"
    ln -s "`$COMFY_ROOT/`$entry" "`$COMFY_APP_ROOT/`$entry"
  done
  rm -rf "`$COMFY_APP_ROOT/custom_nodes"
  ln -s "`$COMFY_ROOT/custom_nodes" "`$COMFY_APP_ROOT/custom_nodes"
fi

pkill -f 'python.*main.py' || true
cd "`$COMFY_APP_ROOT"
rm -f "`$COMFY_LOG_PATH" "`$COMFY_PID_PATH"
(
  cd "`$COMFY_APP_ROOT"
  PYTHONUNBUFFERED=1 python3 -u main.py --listen 0.0.0.0 --port 8188 2>&1 | tee -a "`$COMFY_LOG_PATH"
) &
COMFY_PID="`$!"
echo "`$COMFY_PID" > "`$COMFY_PID_PATH"
stage_event "remote.restart_comfy" "end"

stage_event "remote.wait_api" "start"
for _ in `$(seq 1 240); do
  if curl -sf http://127.0.0.1:8188/object_info > "`$RUN_DIR/object_info.json"; then
    break
  fi
  if ! kill -0 "`$COMFY_PID" >/dev/null 2>&1; then
    echo "[remote-v3] ComfyUI exited before API ready" >&2
    tail -n 200 "`$COMFY_LOG_PATH" >&2 || true
    exit 1
  fi
  sleep 5
done
stage_event "remote.wait_api" "end"

if [ ! -s "`$RUN_DIR/object_info.json" ]; then
  echo "[remote-v3] ComfyUI API did not become ready" >&2
  tail -n 200 "`$COMFY_LOG_PATH" >&2 || true
  exit 1
fi

submit_segment() {
  local segment_index="`$1"
  local workflow_path="`$RUN_DIR/workflows/workflow_segment_`$(printf '%02d' "`$segment_index").json"
  local submit_path="`$RUN_DIR/prompt_submit_segment_`$(printf '%02d' "`$segment_index").json"
  python3 - "`$workflow_path" "`$submit_path" <<'PY'
import json
import sys
import urllib.error
import urllib.request

workflow_path = sys.argv[1]
output_path = sys.argv[2]
with open(workflow_path, "r", encoding="utf-8") as handle:
    prompt = json.load(handle)

payload = json.dumps({"prompt": prompt}).encode("utf-8")
request = urllib.request.Request(
    "http://127.0.0.1:8188/prompt",
    data=payload,
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(request, timeout=120) as response:
        raw = response.read().decode("utf-8")
except urllib.error.HTTPError as exc:
    raw = exc.read().decode("utf-8", errors="replace")
    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(raw)
    print(raw)
    raise

with open(output_path, "w", encoding="utf-8") as handle:
    handle.write(raw)
print(raw)
PY
}

wait_history() {
  local segment_index="`$1"
  local prompt_id="`$2"
  local history_path="`$RUN_DIR/history_segment_`$(printf '%02d' "`$segment_index").json"
  python3 - "`$prompt_id" "`$history_path" <<'PY'
import json
import sys
import time
import urllib.request
from pathlib import Path

prompt_id = sys.argv[1]
history_path = Path(sys.argv[2])
deadline = time.time() + 4 * 60 * 60
url = f"http://127.0.0.1:8188/history/{prompt_id}"

while time.time() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception:
        payload = {}
    if prompt_id in payload:
        history_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("history-ready")
        raise SystemExit(0)
    time.sleep(10)

print("history-timeout", file=sys.stderr)
raise SystemExit(124)
PY
}

find_output() {
  local segment_index="`$1"
  local prefix="`$2"
  local history_path="`$RUN_DIR/history_segment_`$(printf '%02d' "`$segment_index").json"
  local output_path="`$RUN_DIR/segment_`$(printf '%02d' "`$segment_index")_result.json"
  python3 - "`$history_path" "`$prefix" "`$output_path" <<'PY'
import json
import sys
from pathlib import Path

history = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
prefix = sys.argv[2]
output_path = Path(sys.argv[3])
candidates = []
for prompt_id, entry in history.items():
    for node_id, output in (entry.get("outputs") or {}).items():
        for item in output.get("gifs") or []:
            if item.get("type") != "output":
                continue
            filename = item.get("filename") or ""
            if not filename.startswith(prefix):
                continue
            candidates.append({
                "prompt_id": prompt_id,
                "node_id": node_id,
                "filename": filename,
                "type": item.get("type", "output"),
                "subfolder": item.get("subfolder") or "",
                "format": item.get("format") or "",
            })
if not candidates:
    print(f"no output found for prefix {prefix}", file=sys.stderr)
    raise SystemExit(1)
result = sorted(candidates, key=lambda item: item["filename"])[-1]
output_path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(result["filename"])
PY
}

extract_tail_frames() {
  local video_path="`$1"
  local frame_count="`$2"
  local tmp_dir="`$RUN_DIR/tail_frames"
  rm -rf "`$tmp_dir"
  mkdir -p "`$tmp_dir"
  python3 - "`$video_path" "`$frame_count" "`$tmp_dir" "`$COMFY_ROOT/input" <<'PY'
import shutil
import subprocess
import sys
from pathlib import Path

video_path = Path(sys.argv[1])
frame_count = int(sys.argv[2])
tmp_dir = Path(sys.argv[3])
input_dir = Path(sys.argv[4])
try:
    import imageio_ffmpeg
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    ffmpeg = "ffmpeg"

pattern = str(tmp_dir / "tail-%03d.png")
subprocess.run(
    [ffmpeg, "-y", "-sseof", "-1", "-i", str(video_path), "-vf", "fps=16", "-vsync", "0", pattern],
    check=True,
)
frames = sorted(tmp_dir.glob("tail-*.png"))
if not frames:
    raise SystemExit("no tail frames extracted")
selected = frames[-frame_count:]
for index, frame in enumerate(selected, start=1):
    target = input_dir / f"continue_motion_{index:02d}.png"
    shutil.copy2(frame, target)
    print(f"continue_frame={target}")
PY
}

for segment_index in `$(seq 1 "`$SEGMENT_COUNT"); do
  padded="`$(printf '%02d' "`$segment_index")"
  prefix="wan_2_2_animate_segmented-$JobName-s`$padded"
  stage_event "remote.segment_`$padded.submit" "start"
  submit_segment "`$segment_index" | tee "`$RUN_DIR/submit_segment_`$padded.log"
  prompt_id="`$(python3 - "`$RUN_DIR/prompt_submit_segment_`$padded.json" <<'PY'
import json
import sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload.get("prompt_id", ""))
PY
)"
  if [ -z "`$prompt_id" ]; then
    echo "[remote-v3] missing prompt id for segment `$padded" >&2
    exit 1
  fi
  echo "[remote-v3] segment `$padded prompt_id=`$prompt_id"
  stage_event "remote.segment_`$padded.submit" "end"

  stage_event "remote.segment_`$padded.wait_history" "start"
  wait_history "`$segment_index" "`$prompt_id"
  stage_event "remote.segment_`$padded.wait_history" "end"

  filename="`$(find_output "`$segment_index" "`$prefix")"
  echo "[remote-v3] segment `$padded output=`$filename"

  if [ "`$segment_index" -lt "`$SEGMENT_COUNT" ]; then
    stage_event "remote.segment_`$padded.extract_tail" "start"
    extract_tail_frames "`$COMFY_ROOT/output/`$filename" "`$CONTINUE_FRAME_COUNT"
    stage_event "remote.segment_`$padded.extract_tail" "end"
  fi
done

python3 - "`$RUN_DIR" "`$SEGMENT_COUNT" <<'PY'
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
segment_count = int(sys.argv[2])
segments = []
for index in range(1, segment_count + 1):
    path = run_dir / f"segment_{index:02d}_result.json"
    segments.append(json.loads(path.read_text(encoding="utf-8")))
(run_dir / "segmented_v3_done.json").write_text(
    json.dumps({"status": "succeeded", "segments": segments}, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY

echo "[remote-v3] finished at `$(date -Iseconds)"
"@

    Set-Content -LiteralPath $OutputPath -Value $content -Encoding UTF8
}

function New-OnstartScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string]$RemotePrefix,

        [Parameter(Mandatory = $true)]
        [int]$SegmentCount
    )

    $fetchLines = @()
    $fetchLines += "fetch `"$(Get-EncodedPublicUrl -Key "$RemotePrefix/bootstrap_wan22_root_canvas.sh")`" `"`$RUN_DIR/bootstrap_wan22_root_canvas.sh`""
    $fetchLines += "fetch `"$(Get-EncodedPublicUrl -Key "$RemotePrefix/remote_run_segmented_v3.sh")`" `"`$RUN_DIR/remote_run_segmented_v3.sh`""
    $fetchLines += "fetch `"$(Get-EncodedPublicUrl -Key "$RemotePrefix/inspect_wan22_warmstart.py")`" `"`$RUN_DIR/inspect_wan22_warmstart.py`""
    $fetchLines += "fetch `"$(Get-EncodedPublicUrl -Key "$RemotePrefix/input/美女带背景.png")`" `"`$COMFY_ROOT/input/美女带背景.png`""

    for ($index = 1; $index -le $SegmentCount; $index += 1) {
        $padded = "{0:d2}" -f $index
        $fetchLines += "fetch `"$(Get-EncodedPublicUrl -Key "$RemotePrefix/input/segment-$padded.mp4")`" `"`$COMFY_ROOT/input/segment-$padded.mp4`""
        $fetchLines += "fetch `"$(Get-EncodedPublicUrl -Key "$RemotePrefix/workflows/workflow_segment_$padded.json")`" `"`$RUN_DIR/workflows/workflow_segment_$padded.json`""
    }

    foreach ($bundleName in @(
        "ComfyUI-GGUF.zip",
        "ComfyUI-KJNodes.zip",
        "ComfyUI-VideoHelperSuite.zip",
        "ComfyUI-WanAnimatePreprocess.zip"
    )) {
        $fetchLines += "fetch `"$(Get-EncodedPublicUrl -Key "$RemotePrefix/node-bundles/$bundleName")`" `"`$BUNDLE_DIR/$bundleName`""
    }

    $fetchBlock = $fetchLines -join "`n"
    $content = @"
#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT="/workspace/ComfyUI"
RUN_DIR="/workspace/wan22-segmented-v3-run"
BUNDLE_DIR="`$RUN_DIR/node-bundles"
mkdir -p "`$RUN_DIR/workflows" "`$BUNDLE_DIR" "`$COMFY_ROOT/input"
exec > >(tee -a "`$RUN_DIR/onstart.log") 2>&1

fetch() {
  local url="`$1"
  local target="`$2"
  mkdir -p "`$(dirname "`$target")"
  echo "[onstart-v3] fetch `$url -> `$target"
  curl --http1.1 --fail --location --silent --show-error \
    --retry 10 --retry-delay 8 --retry-all-errors \
    --connect-timeout 30 --max-time 1800 \
    -o "`$target" "`$url"
}

echo "[onstart-v3] started at `$(date -Iseconds)"
$fetchBlock
chmod +x "`$RUN_DIR/bootstrap_wan22_root_canvas.sh" "`$RUN_DIR/remote_run_segmented_v3.sh"
bash "`$RUN_DIR/remote_run_segmented_v3.sh"
echo "[onstart-v3] finished at `$(date -Iseconds)"
"@

    Set-Content -LiteralPath $OutputPath -Value $content -Encoding UTF8
}

function Wait-InstanceBaseUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId,

        [Parameter(Mandatory = $true)]
        [string]$InstancePath
    )

    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-Date) -lt $deadline) {
        $instance = Get-LiveInstance -InstanceId $InstanceId
        if ($instance) {
            $instance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $InstancePath -Encoding UTF8
            $baseUrl = Get-BaseUrlFromInstance -Instance $instance
            if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
                return [pscustomobject]@{
                    Instance = $instance
                    BaseUrl = $baseUrl
                }
            }
            Write-Host "[port mapping] status=$($instance.actual_status) cur_state=$($instance.cur_state) waiting for 8188"
        }
        Start-Sleep -Seconds 15
    }
    throw "Timed out waiting for 8188 port mapping."
}

function Get-VastLogTail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId,

        [int]$Tail = 240
    )

    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = "utf-8"
    try {
        @(& vastai logs $InstanceId --tail $Tail 2>&1 | ForEach-Object { Redact-LogText -Text "$_" })
    }
    finally {
        if ($null -eq $previousPythonIoEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONIOENCODING = $previousPythonIoEncoding
        }
    }
}

function Wait-RemoteBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId
    )

    $deadline = (Get-Date).AddMinutes([math]::Min($MaxWaitMinutes, 180))
    $lastMarker = ""
    while ((Get-Date) -lt $deadline) {
        $lines = @(Get-VastLogTail -InstanceId $InstanceId -Tail 260)
        $text = ($lines -join "`n")

        if ($text -match "\[stage\]\s+\S+\s+remote\.wait_api\s+end" -or $text -match "\[stage\]\s+\S+\s+remote\.segment_01\.submit\s+start") {
            return "remote_bootstrap_ready"
        }

        if ($text -match "cudaGetDeviceCount Error 804|ComfyUI exited before API ready|ComfyUI API did not become ready") {
            throw "Remote bootstrap failed; see Vast logs."
        }

        $marker = $null
        foreach ($line in ($lines | Select-Object -Last 80)) {
            if ($line -match "\[bootstrap\] warm-start (hit|miss):") {
                $marker = $line
            }
            elseif ($line -match "\[bootstrap\] (existing torch stack is compatible|reinstalling torch stack|creating model directories|downloading:)") {
                $marker = $line
            }
            elseif ($line -match "\[stage\].*remote\.bootstrap (start|end)") {
                $marker = $line
            }
            elseif ($line -match "\[stage\].*remote\.wait_api (start|end)") {
                $marker = $line
            }
            elseif ($line -match "\[stage\].*remote\.segment_01\.submit start") {
                $marker = $line
            }
        }

        if ($marker -and $marker -ne $lastMarker) {
            Write-Host "[bootstrap] $marker"
            $lastMarker = $marker
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out waiting for remote bootstrap."
}

function Wait-SegmentOutputs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [object[]]$Segments
    )

    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    $lastFoundCount = -1
    while ((Get-Date) -lt $deadline) {
        try {
            $history = Get-History -BaseUrl $BaseUrl
            $found = @()
            foreach ($segment in $Segments) {
                $candidate = Find-OutputCandidate -History $history -Prefix $segment.output_prefix
                if ($candidate) {
                    $found += $candidate
                }
            }
            if ($found.Count -ne $lastFoundCount) {
                Write-Host "[inference] outputs=$($found.Count)/$($Segments.Count)"
                $lastFoundCount = $found.Count
            }
            if ($found.Count -eq $Segments.Count) {
                return $history
            }
        }
        catch {
            Write-Host "[inference] waiting history: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    throw "Timed out waiting for all segment outputs."
}

function Update-RegistryFromV3Run {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstancePath,

        [Parameter(Mandatory = $true)]
        [string]$TimingPath,

        [Parameter(Mandatory = $true)]
        [string]$RunReportPath,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $registryResolved = Join-Path $repoRoot $RegistryPath
    $args = @(
        $registryPy,
        "record-run",
        "--registry-path", $registryResolved,
        "--instance-path", $InstancePath,
        "--timing-path", $TimingPath,
        "--run-report-path", $RunReportPath,
        "--result", "succeeded"
    )
    if (Test-Path -LiteralPath $LogPath) {
        $args += @("--log-path", $LogPath)
    }
    $env:PYTHONIOENCODING = "utf-8"
    try {
        $recordJson = & D:\code\YuYan\python\python.exe @args
        if ($LASTEXITCODE -ne 0) {
            throw "registry record-run failed."
        }
        $localRegistryDir = Join-Path $env:USERPROFILE ".codex\references\wan22"
        New-Item -ItemType Directory -Force -Path $localRegistryDir | Out-Null
        Copy-Item -LiteralPath $registryResolved -Destination (Join-Path $localRegistryDir "machine-registry.json") -Force
        $recordJson
    }
    finally {
        Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
    }
}

$resolvedVideoPath = (Resolve-Path -LiteralPath $VideoPath).Path
if ([string]::IsNullOrWhiteSpace($ImagePath)) {
    $ImagePath = Resolve-DefaultImage -AssetDir (Join-Path $repoRoot $ImageAssetDir)
}
$resolvedImagePath = (Resolve-Path -LiteralPath $ImagePath).Path
$videoDurationSeconds = Get-VideoDurationSeconds -Path $resolvedVideoPath

$jobDir = Join-Path $repoRoot ("output\wan_2_2_animate_segmented\" + $JobName)
$segmentsDir = Join-Path $jobDir "segments"
$inputDir = Join-Path $jobDir "input"
$workflowDir = Join-Path $jobDir "workflows"
$bundleDir = Join-Path $jobDir "node-bundles"
$downloadsDir = Join-Path $jobDir "downloads"
$logsDir = Join-Path $jobDir "logs"
$script:reportPath = Join-Path $jobDir "run-report.json"
$manifestPath = Join-Path $jobDir "manifest.json"
$instancePath = Join-Path $jobDir "vast-instance.json"
$timingPath = Join-Path $jobDir "timing-summary.json"
$onstartPath = Join-Path $jobDir "onstart_segmented_v3.sh"
$remoteRunPath = Join-Path $jobDir "remote_run_segmented_v3.sh"
$mergeListPath = Join-Path $jobDir "concat-inputs.txt"
$mergedOutputPath = Join-Path $downloadsDir ("wan_2_2_animate_segmented-" + $JobName + ".mp4")
$vastLogPath = Join-Path $logsDir "vast.log"

New-Item -ItemType Directory -Force -Path $segmentsDir, $inputDir, $workflowDir, $bundleDir, $downloadsDir, $logsDir | Out-Null

$script:report = [ordered]@{
    profile = "wan_2_2_animate_segmented"
    variant = "v3_single_instance"
    job_name = $JobName
    started_at = (Get-Date).ToString("s")
    ended_at = $null
    status = "running"
    steps = @()
    runtime_version = $RuntimeVersion
}
Write-JsonFile -Path $script:reportPath -Data $script:report

$instanceId = ""
$baseUrl = ""
$launched = $false
$completedSuccessfully = $false
$destroyed = $false

try {
    $profileConfig = Get-Content -Raw -LiteralPath $profileConfigPath | ConvertFrom-Json
    $workflowSourceRel = [string]$profileConfig.profiles."wan_2_2_animate".workflow_source
    if ([string]::IsNullOrWhiteSpace($workflowSourceRel)) {
        $workflowSourceRel = "workflows\Animate+Wan2.2换风格对口型.json"
    }
    $sourceWorkflow = Join-Path $repoRoot $workflowSourceRel
    if (-not (Test-Path -LiteralPath $sourceWorkflow)) {
        throw "Missing workflow source: $sourceWorkflow"
    }

    $segmentRecords = Invoke-Step -Name "stage" -Action {
        Copy-Item -LiteralPath $resolvedImagePath -Destination (Join-Path $inputDir "美女带背景.png") -Force
        Copy-Item -LiteralPath $bootstrapScript -Destination (Join-Path $jobDir "bootstrap_wan22_root_canvas.sh") -Force
        Copy-Item -LiteralPath $warmstartInspectorScript -Destination (Join-Path $jobDir "inspect_wan22_warmstart.py") -Force

        $bundleSourceDir = Resolve-NodeBundleSourceDir
        Get-ChildItem -LiteralPath $bundleSourceDir -File -Filter "*.zip" | ForEach-Object {
            if (@("ComfyUI-GGUF.zip", "ComfyUI-KJNodes.zip", "ComfyUI-VideoHelperSuite.zip", "ComfyUI-WanAnimatePreprocess.zip") -contains $_.Name) {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $bundleDir $_.Name) -Force
            }
        }

        $segmentCount = [int][math]::Ceiling($videoDurationSeconds / $SegmentSeconds)
        if ($MaxSegments -gt 0) {
            $segmentCount = [math]::Min($segmentCount, $MaxSegments)
        }

        $records = @()
        for ($index = 0; $index -lt $segmentCount; $index += 1) {
            $segmentNumber = $index + 1
            $padded = "{0:d2}" -f $segmentNumber
            $startSeconds = $index * $SegmentSeconds
            $remaining = [math]::Max(0.0, $videoDurationSeconds - $startSeconds)
            $durationSeconds = [math]::Min([double]$SegmentSeconds, $remaining)
            if ($durationSeconds -le 0) {
                break
            }

            $segmentFileName = "segment-$padded.mp4"
            $segmentPath = Join-Path $segmentsDir $segmentFileName
            $stagedSegmentPath = Join-Path $inputDir $segmentFileName
            New-VideoSegment -InputPath $resolvedVideoPath -StartSeconds $startSeconds -DurationSeconds $durationSeconds -OutputPath $segmentPath
            Copy-Item -LiteralPath $segmentPath -Destination $stagedSegmentPath -Force

            $frameLoadCap = ([math]::Max(1, [int][math]::Round($durationSeconds)) * 16) + 1
            $runtimeWorkflowPath = Join-Path $workflowDir ("workflow_segment_$padded.json")
            $outputPrefix = "wan_2_2_animate_segmented-$JobName-s$padded"
            $prepareArgs = @(
                $prepareScript,
                "--input", $sourceWorkflow,
                "--output", $runtimeWorkflowPath,
                "--image-name", "美女带背景.png",
                "--video-name", $segmentFileName,
                "--frame-load-cap", "$frameLoadCap",
                "--output-prefix", $outputPrefix
            )
            if ($segmentNumber -gt 1) {
                $continuationNames = @(1..$ContinueMotionFrames | ForEach-Object { "continue_motion_{0:d2}.png" -f $_ })
                $prepareArgs += @(
                    "--continue-motion-images", ($continuationNames -join "|"),
                    "--continue-motion-max-frames", "$ContinueMotionFrames",
                    "--video-frame-offset", "0"
                )
            }
            & node @prepareArgs | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to prepare workflow for segment $padded"
            }

            $records += [ordered]@{
                index = $segmentNumber
                padded = $padded
                start_seconds = [math]::Round($startSeconds, 3)
                duration_seconds = [math]::Round($durationSeconds, 3)
                segment_file = $segmentFileName
                segment_path = $segmentPath
                staged_segment_path = $stagedSegmentPath
                workflow_path = $runtimeWorkflowPath
                output_prefix = $outputPrefix
                frame_load_cap = $frameLoadCap
            }
        }

        New-RemoteSegmentedScript -OutputPath $remoteRunPath -SegmentCount $records.Count -ContinuationFrameCount $ContinueMotionFrames
        $remotePrefix = "$R2Prefix/$JobName"
        New-OnstartScript -OutputPath $onstartPath -RemotePrefix $remotePrefix -SegmentCount $records.Count

        $manifest = [ordered]@{
            profile = "wan_2_2_animate_segmented"
            variant = "v3_single_instance"
            job_name = $JobName
            created_at = (Get-Date).ToString("s")
            runtime_version = $RuntimeVersion
            source = [ordered]@{
                image_path = $resolvedImagePath
                video_path = $resolvedVideoPath
                video_duration_seconds = [math]::Round($videoDurationSeconds, 3)
                segment_seconds = $SegmentSeconds
                segment_count = $records.Count
                continue_motion_frames = $ContinueMotionFrames
            }
            local = [ordered]@{
                job_dir = $jobDir
                input_dir = $inputDir
                workflows_dir = $workflowDir
                node_bundles = $bundleDir
                downloads_dir = $downloadsDir
                merged_output = $mergedOutputPath
                run_report = $script:reportPath
                timing_summary = $timingPath
            }
            r2 = [ordered]@{
                bucket = $R2Bucket
                public_base_url = $R2PublicBaseUrl
                prefix = $remotePrefix
                output = "$remotePrefix/output"
            }
            remote = [ordered]@{
                run_dir = "/workspace/wan22-segmented-v3-run"
                input_dir = "/workspace/ComfyUI/input"
                output_dir = "/workspace/ComfyUI/output"
            }
            segments = @($records)
        }
        Write-JsonFile -Path $manifestPath -Data $manifest

        Write-Host "[stage] job_dir=$jobDir"
        Write-Host "[stage] segment_count=$($records.Count)"
        Write-Host "[stage] node_bundle_source=$bundleSourceDir"
        return $records
    }

    if ($PrepareOnly) {
        $script:report.status = "succeeded"
        $script:report.ended_at = (Get-Date).ToString("s")
        $script:report.prepare_only = $true
        Write-JsonFile -Path $script:reportPath -Data $script:report

        Write-Host "[prepare_only] staged segmented v3 job without upload or launch"
        Write-Host "run_report=$script:reportPath"
        Write-Host "manifest=$manifestPath"
        return
    }

    Invoke-Step -Name "upload_stage" -Action {
        if ([string]::IsNullOrWhiteSpace($R2AccountId) -or [string]::IsNullOrWhiteSpace($R2AccessKeyId) -or [string]::IsNullOrWhiteSpace($R2SecretAccessKey)) {
            throw "R2 credentials missing for segmented v3 stage upload."
        }
        & D:\code\YuYan\python\python.exe $uploadScript `
            --account-id $R2AccountId `
            --access-key-id $R2AccessKeyId `
            --secret-access-key $R2SecretAccessKey `
            --bucket $R2Bucket `
            --local-path $jobDir `
            --remote-prefix "$R2Prefix/$JobName" `
            --public-base-url $R2PublicBaseUrl
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to upload v3 staged job to R2."
        }
        "r2_prefix=$R2Prefix/$JobName"
    } | Out-Null

    $selection = Invoke-Step -Name "select_offer" -Action {
        if (-not [string]::IsNullOrWhiteSpace($OfferId)) {
            [pscustomobject]@{
                offer_id = $OfferId
                machine_id = $null
                host_id = $null
                warm_start = $false
                selection_mode = "manual_offer"
                selection_reason = "OfferId provided"
            }
            return
        }

        if ($RuntimeVersion -eq "1.1-machine-registry") {
            $decision = & pwsh -File $selectOfferScript -RegistryPath $RegistryPath | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0) {
                throw "Offer selector failed."
            }
            $decision
            return
        }

        $previousPythonIoEncoding = $env:PYTHONIOENCODING
        $env:PYTHONIOENCODING = "utf-8"
        try {
            $offers = @(& vastai search offers $SearchQuery --storage $DiskGb --raw | ConvertFrom-Json)
        }
        finally {
            if ($null -eq $previousPythonIoEncoding) {
                Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
            }
            else {
                $env:PYTHONIOENCODING = $previousPythonIoEncoding
            }
        }
        $offer = $offers | Sort-Object dph_total | Select-Object -First 1
        if (-not $offer) {
            throw "No Vast offer found."
        }
        [pscustomobject]@{
            offer_id = $offer.id
            machine_id = $offer.machine_id
            host_id = $offer.host_id
            warm_start = $false
            selection_mode = "cold_start"
            selection_reason = "1.0 cheapest non-CN/TR RTX 3090 offer"
        }
    }
    $OfferId = [string]$selection.offer_id
    $warmStart = [bool]$selection.warm_start
    $script:report.selection = [ordered]@{
        offer_id = $OfferId
        machine_id = [string]$selection.machine_id
        host_id = [string]$selection.host_id
        warm_start = $warmStart
        selection_mode = [string]$selection.selection_mode
        selection_reason = [string]$selection.selection_reason
    }
    Write-JsonFile -Path $script:reportPath -Data $script:report
    Write-Host "[select_offer] offer_id=$OfferId machine=$($selection.machine_id) host=$($selection.host_id) warm_start=$warmStart mode=$($selection.selection_mode)"

    $launchResult = Invoke-Step -Name "launch" -Action {
        $label = "wan22-segmented-v3-$JobName"
        $createArgs = @(
            "-File", $createInstanceScript,
            "-OfferId", $OfferId,
            "-Image", $Image,
            "-Label", $label,
            "-DiskGb", "$DiskGb",
            "-Onstart", $onstartPath
        )
        if ($CancelUnavail) {
            $createArgs += "-CancelUnavail"
        }
        if ($warmStart) {
            $createArgs += @("-ExtraEnv", "WARM_START=1")
        }
        $createOutput = @(& pwsh @createArgs 2>&1)
        $createExitCode = $LASTEXITCODE
        $redactedCreateOutput = @($createOutput | ForEach-Object { Redact-LogText -Text "$_" })
        $redactedCreateOutput | Set-Content -LiteralPath (Join-Path $jobDir "vast-create-response.txt") -Encoding UTF8
        $redactedCreateOutput | ForEach-Object { Write-Host $_ }
        if ($createExitCode -ne 0) {
            throw "Failed to create Vast instance."
        }

        Start-Sleep -Seconds 3
        $instance = $null
        for ($attempt = 1; $attempt -le 20; $attempt += 1) {
            $env:PYTHONIOENCODING = "utf-8"
            try {
                $instances = @(vastai show instances --raw | ConvertFrom-Json)
            }
            finally {
                Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
            }
            $instance = $instances | Where-Object { $_.label -eq $label } | Sort-Object start_date -Descending | Select-Object -First 1
            if ($instance) {
                break
            }
            Start-Sleep -Seconds 6
        }
        if (-not $instance) {
            throw "Instance created but could not be found by label: $label"
        }
        $safeInstance = Remove-InstanceSecrets -Instance $instance
        $safeInstance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $instancePath -Encoding UTF8
        $script:instanceId = [string]$safeInstance.id
        $script:launched = $true
        Write-Host "[launch] instance_id=$($safeInstance.id)"
        Write-Host "[launch] host_id=$($safeInstance.host_id)"
        Write-Host "[launch] machine_id=$($safeInstance.machine_id)"
        Write-Host "[launch] warm_start=$warmStart"
        return $safeInstance
    }
    $instanceId = [string]$launchResult.id
    $launched = $true
    $script:report.instance_id = $instanceId
    Write-JsonFile -Path $script:reportPath -Data $script:report
    Write-Host "[launch] instance_id=$instanceId host=$($launchResult.host_id) machine=$($launchResult.machine_id) warm_start=$warmStart"

    $mapping = Invoke-Step -Name "port_mapping" -Action {
        $result = Wait-InstanceBaseUrl -InstanceId $instanceId -InstancePath $instancePath
        Write-Host "[port_mapping] base_url=$($result.BaseUrl)"
        return $result
    }
    $baseUrl = [string]$mapping.BaseUrl
    $script:report.base_url = $baseUrl
    Write-JsonFile -Path $script:reportPath -Data $script:report
    Write-Host "[port mapping] base_url=$baseUrl"

    Invoke-Step -Name "bootstrap" -Action {
        Wait-RemoteBootstrap -InstanceId $instanceId
    } | Out-Null

    $history = Invoke-Step -Name "inference" -Action {
        Wait-SegmentOutputs -BaseUrl $baseUrl -Segments @($segmentRecords)
    }
    $history | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $jobDir "history.api.json") -Encoding UTF8

    $downloadedPaths = Invoke-Step -Name "download" -Action {
        $paths = @()
        foreach ($segment in $segmentRecords) {
            $candidate = Find-OutputCandidate -History $history -Prefix $segment.output_prefix
            if (-not $candidate) {
                throw "Missing candidate for $($segment.output_prefix)"
            }
            $localPath = Download-ComfyOutput -BaseUrl $baseUrl -Candidate $candidate -OutputDir $downloadsDir
            $segment["result"] = [ordered]@{
                prompt_id = $candidate.PromptId
                filename = $candidate.Filename
                local_result_path = $localPath
                type = $candidate.Type
                subfolder = $candidate.Subfolder
            }
            $paths += $localPath
        }
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
        $manifest["segments"] = @($segmentRecords)
        Write-JsonFile -Path $manifestPath -Data $manifest
        $paths
    }

    Invoke-Step -Name "merge_segments" -Action {
        Merge-VideoSegments -InputPaths @($downloadedPaths | ForEach-Object { [string]$_ }) -ListPath $mergeListPath -OutputPath $mergedOutputPath
        $mergedDuration = Get-VideoDurationSeconds -Path $mergedOutputPath
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
        $manifest["merged_result"] = [ordered]@{
            local_result_path = $mergedOutputPath
            duration_seconds = [math]::Round($mergedDuration, 3)
            merged_at = (Get-Date).ToString("s")
        }
        Write-JsonFile -Path $manifestPath -Data $manifest
        @("merged_result=$mergedOutputPath", "duration_seconds=$([math]::Round($mergedDuration, 3))")
    } | Out-Null

    Invoke-Step -Name "fetch_logs" -Action {
        $env:PYTHONIOENCODING = "utf-8"
        try {
            $logs = & vastai logs $instanceId 2>$null
            $logs | Set-Content -LiteralPath $vastLogPath -Encoding UTF8
        }
        finally {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        }
        "vast_log=$vastLogPath"
    } | Out-Null

    Invoke-Step -Name "summarize_timings" -Action {
        $promptStartStages = @()
        $promptEndStages = @()
        if (Test-Path -LiteralPath $vastLogPath) {
            $logText = Get-Content -Raw -LiteralPath $vastLogPath
            $stageMatches = [regex]::Matches($logText, "\[stage\]\s+(\S+)\s+(\S+)\s+(\S+)")
            foreach ($match in $stageMatches) {
                $name = $match.Groups[2].Value
                $status = $match.Groups[3].Value
                if ($name -like "remote.segment_*.submit" -and $status -eq "start") {
                    $promptStartStages += $match.Groups[1].Value
                }
                if ($name -like "remote.segment_*.wait_history" -and $status -eq "end") {
                    $promptEndStages += $match.Groups[1].Value
                }
            }
        }
        $totalSeconds = $null
        try {
            $started = [datetime]::Parse($script:report.started_at, [System.Globalization.CultureInfo]::InvariantCulture)
            if ([string]::IsNullOrWhiteSpace([string]$script:report.ended_at)) {
                $ended = Get-Date
            }
            else {
                $ended = [datetime]::Parse($script:report.ended_at, [System.Globalization.CultureInfo]::InvariantCulture)
            }
            $totalSeconds = [math]::Round(($ended - $started).TotalSeconds, 3)
        }
        catch {
            $totalSeconds = $null
        }
        $timing = [ordered]@{
            prompt_execution = $null
            stages = @()
            lifecycle = [ordered]@{
                result_downloaded_at = (Get-Date).ToString("s")
                total_until_download_seconds = $totalSeconds
            }
            segmented = [ordered]@{
                segment_count = @($segmentRecords).Count
                submit_stage_count = @($promptStartStages).Count
                completed_stage_count = @($promptEndStages).Count
            }
        }
        Write-JsonFile -Path $timingPath -Data $timing
        "timing_summary=$timingPath"
    } | Out-Null

    if (-not $SkipPublish) {
        Invoke-Step -Name "publish" -Action {
            if ([string]::IsNullOrWhiteSpace($R2AccountId) -or [string]::IsNullOrWhiteSpace($R2AccessKeyId) -or [string]::IsNullOrWhiteSpace($R2SecretAccessKey)) {
                throw "R2 credentials missing for publish."
            }
            & D:\code\YuYan\python\python.exe $uploadScript `
                --account-id $R2AccountId `
                --access-key-id $R2AccessKeyId `
                --secret-access-key $R2SecretAccessKey `
                --bucket $R2Bucket `
                --local-path $mergedOutputPath `
                --remote-prefix "$R2Prefix/$JobName/output" `
                --public-base-url $R2PublicBaseUrl
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to upload merged v3 result."
            }
            $resultName = [System.IO.Path]::GetFileName($mergedOutputPath)
            $remoteKey = "$R2Prefix/$JobName/output/$resultName"
            $publicUrl = "$($R2PublicBaseUrl.TrimEnd('/'))/$(Encode-R2Key -Key $remoteKey)"
            $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
            $manifest["published_result"] = [ordered]@{
                local_result_path = $mergedOutputPath
                bucket = $R2Bucket
                remote_key = $remoteKey
                public_url = $publicUrl
                uploaded_at = (Get-Date).ToString("s")
            }
            Write-JsonFile -Path $manifestPath -Data $manifest
            "public_url=$publicUrl"
        } | Out-Null
    }

    if (-not $KeepInstanceForDebug) {
        Invoke-Step -Name "destroy" -Action {
            & pwsh -File $destroyInstanceScript -InstanceId $instanceId | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to destroy Vast instance $instanceId"
            }
            $script:launched = $false
            $script:destroyed = $true
            "destroyed_instance=$instanceId"
        } | Out-Null
        $launched = $false
        $destroyed = $true
    }

    Invoke-Step -Name "update_registry" -Action {
        Update-RegistryFromV3Run -InstancePath $instancePath -TimingPath $timingPath -RunReportPath $script:reportPath -LogPath $vastLogPath
    } | Out-Null

    $script:report.status = "succeeded"
    $script:report.ended_at = (Get-Date).ToString("s")
    Write-JsonFile -Path $script:reportPath -Data $script:report
    $completedSuccessfully = $true
}
finally {
    if ($launched -and -not [string]::IsNullOrWhiteSpace($instanceId) -and -not $completedSuccessfully -and -not (Test-Path -LiteralPath $vastLogPath)) {
        try {
            $env:PYTHONIOENCODING = "utf-8"
            $logs = & vastai logs $instanceId 2>$null
            $logs | Set-Content -LiteralPath $vastLogPath -Encoding UTF8
        }
        catch {
            Write-Warning "Failed to fetch Vast logs before destroy for instance ${instanceId}: $($_.Exception.Message)"
        }
        finally {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        }
    }

    if ($launched -and -not $destroyed -and -not [string]::IsNullOrWhiteSpace($instanceId) -and -not $KeepInstanceForDebug) {
        try {
            Invoke-Step -Name "destroy" -Action {
                & pwsh -File $destroyInstanceScript -InstanceId $instanceId | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to destroy Vast instance $instanceId"
                }
                "destroyed_instance=$instanceId"
            } | Out-Null
        }
        catch {
            Write-Warning "Destroy failed for instance ${instanceId}: $($_.Exception.Message)"
        }
    }
}

$manifestFinal = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
Write-Host "run_report=$script:reportPath"
Write-Host "manifest=$manifestPath"
if ($manifestFinal.merged_result.local_result_path) {
    Write-Host "local_result=$($manifestFinal.merged_result.local_result_path)"
}
if ($manifestFinal.published_result.public_url) {
    Write-Host "public_url=$($manifestFinal.published_result.public_url)"
}
