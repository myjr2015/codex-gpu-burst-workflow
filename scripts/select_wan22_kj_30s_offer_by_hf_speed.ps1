param(
    [string]$SearchQuery = "gpu_name=RTX_4090 num_gpus=1 gpu_ram>=24 cuda_max_good>=12.4 disk_space>240 direct_port_count>=4 rented=False geolocation notin [CN,TR]",

    [int]$DiskGb = 240,

    [int]$CandidateCount = 20,

    [int]$BatchSize = 3,

    [int]$MaxTests = 9,

    [double]$MaxDphTotal = 0.4,

    [int]$MinDriverMajor = 580,

    [string]$RegistryPath = ".\data\vast-machine-registry.json",

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [double]$HfMinMiBps = 15,

    [int]$HfMaxEstimatedDownloadMinutes = 30,

    [int]$HfSpeedTestSampleMiB = 256,

    [int]$HfSpeedTestMaxSeconds = 120,

    [int]$PollIntervalSeconds = 10,

    [int]$MaxWaitMinutes = 20,

    [int]$MaxStartupWaitMinutes = 5,

    [switch]$ListOnly,

    [switch]$KeepPassingInstance
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
$createScript = Join-Path $repoRoot "scripts\create_vast_instance_minimal.ps1"
$destroyScript = Join-Path $repoRoot "scripts\destroy_vast_instance.ps1"
$speedRoot = Join-Path $repoRoot "output\wan22_kj_30s\_hf_speedtests"

foreach ($required in @($createScript, $destroyScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}

if (Test-Path -LiteralPath $r2HelperPath) {
    . $r2HelperPath
    Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
}

function Get-DriverMajor {
    param($Offer)

    $driverMajor = 0
    if ($Offer.driver_version -match '^\s*(\d+)') {
        $driverMajor = [int]$Matches[1]
    }
    $driverMajor
}

function Get-RegistryBlacklist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Join-Path $repoRoot $Path
    $machines = @{}
    $hosts = @{}
    if (Test-Path -LiteralPath $resolved) {
        $registry = Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
        if ($registry.blacklist.machines) {
            foreach ($item in @($registry.blacklist.machines)) {
                if ($item.machine_id) {
                    $machines[[string]$item.machine_id] = $true
                }
            }
        }
        if ($registry.blacklist.hosts) {
            foreach ($item in @($registry.blacklist.hosts)) {
                if ($item.host_id) {
                    $hosts[[string]$item.host_id] = $true
                }
            }
        }
    }

    [pscustomobject]@{
        Machines = $machines
        Hosts = $hosts
    }
}

function Invoke-VastJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousPythonUtf8 = $env:PYTHONUTF8
    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    try {
        & vastai @Arguments
    }
    finally {
        if ($null -eq $previousPythonUtf8) {
            Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONUTF8 = $previousPythonUtf8
        }
        if ($null -eq $previousPythonIoEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONIOENCODING = $previousPythonIoEncoding
        }
    }
}

function Get-VastLogTailSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId,

        [int]$Tail = 200
    )

    $previousPythonUtf8 = $env:PYTHONUTF8
    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    try {
        @(& vastai logs $InstanceId --tail $Tail 2>&1 | ForEach-Object { "$_" })
    }
    catch {
        @("vastai logs failed: $($_.Exception.Message)")
    }
    finally {
        if ($null -eq $previousPythonUtf8) {
            Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONUTF8 = $previousPythonUtf8
        }
        if ($null -eq $previousPythonIoEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONIOENCODING = $previousPythonIoEncoding
        }
    }
}

function New-HfSpeedTestOnstart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [double]$MinMiBps,

        [Parameter(Mandatory = $true)]
        [int]$MaxEstimatedDownloadMinutes,

        [Parameter(Mandatory = $true)]
        [int]$SampleMiB,

        [Parameter(Mandatory = $true)]
        [int]$MaxSeconds
    )

    $content = @"
#!/usr/bin/env bash
set -euo pipefail

RUN_DIR="/workspace/wan22-kj-30s-hf-speedtest"
COMFY_ROOT="/workspace/ComfyUI"
MODELS_DIR="`$COMFY_ROOT/models"
HF_MIN_MIB_PER_SEC="$MinMiBps"
HF_MAX_ESTIMATED_DOWNLOAD_MINUTES="$MaxEstimatedDownloadMinutes"
HF_SPEEDTEST_SAMPLE_MIB="$SampleMiB"
HF_SPEEDTEST_MAX_SECONDS="$MaxSeconds"

mkdir -p "`$RUN_DIR" "`$MODELS_DIR"
exec > >(tee -a "`$RUN_DIR/onstart.log") 2>&1

stage_event() {
  local stage_name="`$1"
  local stage_status="`$2"
  echo "[stage] `$(date -Iseconds) `$stage_name `$stage_status"
}

echo "[hf-speedtest] started at `$(date -Iseconds)"
stage_event "remote.hf_speedtest" "start"

model_manifest=(
  "https://huggingface.co/VladimirSoch/For_Work/resolve/main/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors|diffusion_models/Wan22Animate/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors|17317143060"
  "https://huggingface.co/realung/umt5-xxl-enc-fp8_e4m3fn.safetensors/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors|text_encoders/umt5-xxl-enc-fp8_e4m3fn.safetensors|6731333792"
  "https://huggingface.co/VladimirSoch/For_Work/resolve/main/wan_2.1_vae.safetensors|vae/wan_2.1_vae.safetensors|253815318"
  "https://huggingface.co/VladimirSoch/For_Work/resolve/main/clip_vision_h.safetensors|clip_vision/clip_vision_h.safetensors|1264219396"
  "https://huggingface.co/VladimirSoch/For_Work/resolve/main/vitpose-l-wholebody.onnx|detection/vitpose-l-wholebody.onnx|1234579166"
  "https://huggingface.co/VladimirSoch/For_Work/resolve/main/yolov10m.onnx|detection/yolov10m.onnx|61659339"
  "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/lightx2v_elite_it2v_animate_face.safetensors|loras/lightx2v_elite_it2v_animate_face.safetensors|3257907064"
  "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/WAN22_MoCap_fullbodyCOPY_ED.safetensors|loras/WAN22_MoCap_fullbodyCOPY_ED.safetensors|2129598528"
  "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/FullDynamic_Ultimate_Fusion_Elite.safetensors|loras/FullDynamic_Ultimate_Fusion_Elite.safetensors|987745068"
  "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors|loras/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors|858457612"
  "https://huggingface.co/VladimirSoch/For_Work/resolve/main/Wan2.2-Fun-A14B-InP-low-noise-HPS2.1.safetensors|loras/Wan2.2-Fun-A14B-InP-low-noise-HPS2.1.safetensors|858457436"
)

total_bytes=0
remaining_bytes=0
cached_count=0
missing_count=0
test_url=""

for item in "`${model_manifest[@]}"; do
  IFS='|' read -r url relative_path size_bytes <<< "`$item"
  if [ -z "`$test_url" ]; then
    test_url="`$url"
  fi
  total_bytes=`$((total_bytes + size_bytes))
  target="`$MODELS_DIR/`$relative_path"
  if [ -f "`$target" ]; then
    current_size="`$(stat -c%s "`$target" 2>/dev/null || echo 0)"
    if [ "`$current_size" -ge `$((size_bytes * 95 / 100)) ]; then
      cached_count=`$((cached_count + 1))
    else
      missing_bytes=`$((size_bytes - current_size))
      if [ "`$missing_bytes" -gt 0 ]; then
        remaining_bytes=`$((remaining_bytes + missing_bytes))
      fi
      missing_count=`$((missing_count + 1))
    fi
  else
    remaining_bytes=`$((remaining_bytes + size_bytes))
    missing_count=`$((missing_count + 1))
  fi
done

sample_bytes=`$((HF_SPEEDTEST_SAMPLE_MIB * 1024 * 1024))
range_end=`$((sample_bytes - 1))
metrics_path="`$RUN_DIR/hf_speedtest.curl_metrics.txt"

echo "[hf-speedtest] total_model_bytes=`$total_bytes remaining_model_bytes=`$remaining_bytes cached=`$cached_count missing=`$missing_count"
echo "[hf-speedtest] sample_url=`$test_url sample_mib=`$HF_SPEEDTEST_SAMPLE_MIB max_seconds=`$HF_SPEEDTEST_MAX_SECONDS"

curl_code=0
set +e
curl --http1.1 -L --fail --silent --show-error \
  --retry 2 --retry-delay 2 --retry-all-errors \
  --connect-timeout 30 --max-time "`$HF_SPEEDTEST_MAX_SECONDS" \
  -r "0-`$range_end" \
  -o /dev/null \
  -w "speed_download=%{speed_download}\ntime_total=%{time_total}\nsize_download=%{size_download}\nhttp_code=%{http_code}\n" \
  "`$test_url" > "`$metrics_path"
curl_code=`$?
set -e

speed_bps="`$(awk -F= '`$1=="speed_download"{print `$2}' "`$metrics_path" | tail -n 1)"
time_total="`$(awk -F= '`$1=="time_total"{print `$2}' "`$metrics_path" | tail -n 1)"
size_download="`$(awk -F= '`$1=="size_download"{print `$2}' "`$metrics_path" | tail -n 1)"
http_code="`$(awk -F= '`$1=="http_code"{print `$2}' "`$metrics_path" | tail -n 1)"

set +e
python3 - "`$RUN_DIR/hf_speedtest.json" \
  "`$total_bytes" "`$remaining_bytes" "`$cached_count" "`$missing_count" \
  "`$speed_bps" "`$time_total" "`$size_download" "`$http_code" "`$curl_code" \
  "`$HF_MIN_MIB_PER_SEC" "`$HF_MAX_ESTIMATED_DOWNLOAD_MINUTES" \
  "`$sample_bytes" "`$test_url" <<'PY'
import json
import math
import sys
from datetime import datetime, timezone

(
    output,
    total,
    remaining,
    cached,
    missing,
    speed_bps,
    time_total,
    size_download,
    http_code,
    curl_code,
    min_mibps,
    max_minutes,
    sample_bytes,
    sample_url,
) = sys.argv[1:15]

def as_float(value, default=0.0):
    try:
        number = float(str(value).strip())
        return number if math.isfinite(number) else default
    except Exception:
        return default

def as_int(value, default=0):
    try:
        return int(float(str(value).strip()))
    except Exception:
        return default

total = as_int(total)
remaining = as_int(remaining)
cached = as_int(cached)
missing = as_int(missing)
speed_bps_value = as_float(speed_bps)
time_total_value = as_float(time_total)
size_download_value = as_int(size_download)
http_code_value = str(http_code or "").strip()
curl_code_value = as_int(curl_code)
min_mibps_value = as_float(min_mibps)
max_minutes_value = as_float(max_minutes)
sample_bytes_value = as_int(sample_bytes)

mibps = speed_bps_value / 1024 / 1024 if speed_bps_value > 0 else 0.0
estimated_seconds = remaining / speed_bps_value if speed_bps_value > 0 else None
estimated_minutes = estimated_seconds / 60 if estimated_seconds is not None else None
downloaded_enough = size_download_value >= min(10 * 1024 * 1024, max(1, sample_bytes_value // 10))

reasons = []
decision = "pass"
if speed_bps_value <= 0 or not downloaded_enough:
    decision = "reject"
    reasons.append("speed sample did not download enough data")
if curl_code_value not in (0, 28) and not downloaded_enough:
    decision = "reject"
    reasons.append(f"curl failed with exit code {curl_code_value}")
if min_mibps_value > 0 and mibps < min_mibps_value:
    decision = "reject"
    reasons.append(f"speed {mibps:.2f} MiB/s below minimum {min_mibps_value:.2f} MiB/s")
if max_minutes_value > 0 and estimated_minutes is not None and estimated_minutes > max_minutes_value:
    decision = "reject"
    reasons.append(f"estimated model download {estimated_minutes:.1f} min above maximum {max_minutes_value:.1f} min")

payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "decision": decision,
    "reason": "; ".join(reasons) if reasons else "speed and estimated model download time are acceptable",
    "total_model_bytes": total,
    "total_model_gib": round(total / 1024 ** 3, 3),
    "remaining_model_bytes": remaining,
    "remaining_model_gib": round(remaining / 1024 ** 3, 3),
    "cached_model_count": cached,
    "missing_model_count": missing,
    "sample_url": sample_url,
    "sample_requested_bytes": sample_bytes_value,
    "sample_downloaded_bytes": size_download_value,
    "sample_time_seconds": time_total_value,
    "curl_exit_code": curl_code_value,
    "http_code": http_code_value,
    "speed_bytes_per_sec": speed_bps_value,
    "speed_mib_per_sec": round(mibps, 3),
    "estimated_download_seconds": round(estimated_seconds, 3) if estimated_seconds is not None else None,
    "estimated_download_minutes": round(estimated_minutes, 3) if estimated_minutes is not None else None,
    "min_mib_per_sec": min_mibps_value,
    "max_estimated_download_minutes": max_minutes_value,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")

estimate_text = "unknown" if estimated_minutes is None else f"{estimated_minutes:.1f} min"
print(
    "[hf-speedtest] "
    f"decision={decision} speed={mibps:.2f} MiB/s "
    f"estimated_model_download={estimate_text} "
    f"remaining={remaining / 1024 ** 3:.2f} GiB "
    f"threshold_min_speed={min_mibps_value:.2f} MiB/s "
    f"threshold_max_minutes={max_minutes_value:.1f}"
)
if reasons:
    print("[hf-speedtest] reason=" + "; ".join(reasons))
raise SystemExit(0 if decision == "pass" else 42)
PY
decision_code=`$?
set -e
stage_event "remote.hf_speedtest" "end"
echo "[hf-speedtest] finished at `$(date -Iseconds)"
exit "`$decision_code"
"@

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $content = $content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
}

function Get-InstanceByLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    for ($attempt = 1; $attempt -le 30; $attempt += 1) {
        $instances = Invoke-VastJson -Arguments @("show", "instances", "--raw") | ConvertFrom-Json
        $instance = $instances |
            Where-Object { $_.label -eq $Label } |
            Sort-Object start_date -Descending |
            Select-Object -First 1
        if ($instance) {
            return $instance
        }
        Start-Sleep -Seconds 6
    }
    $null
}

function Convert-SpeedLogToResult {
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines = @()
    )

    if (-not $Lines -or $Lines.Count -eq 0) {
        return $null
    }

    $line = $Lines |
        Where-Object { $_ -match '^\[hf-speedtest\] decision=' } |
        Select-Object -Last 1
    if (-not $line) {
        return $null
    }

    $decision = $null
    $speed = $null
    $minutes = $null
    $remaining = $null
    if ($line -match 'decision=([a-z]+)') { $decision = $Matches[1] }
    if ($line -match 'speed=([0-9.]+) MiB/s') { $speed = [double]$Matches[1] }
    if ($line -match 'estimated_model_download=([0-9.]+) min') { $minutes = [double]$Matches[1] }
    if ($line -match 'remaining=([0-9.]+) GiB') { $remaining = [double]$Matches[1] }

    $reason = $Lines |
        Where-Object { $_ -match '^\[hf-speedtest\] reason=' } |
        Select-Object -Last 1

    [pscustomobject]@{
        Decision = $decision
        SpeedMiBps = $speed
        EstimatedDownloadMinutes = $minutes
        RemainingGiB = $remaining
        Reason = $reason
        RawLine = $line
    }
}

function Invoke-HfSpeedTestOffer {
    param(
        [Parameter(Mandatory = $true)]
        $Offer,

        [Parameter(Mandatory = $true)]
        [int]$TestIndex
    )

    $offerId = [string]$Offer.id
    $label = "wan22-kj-hf-test-$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$offerId"
    $jobDir = Join-Path $speedRoot $label
    $onstartPath = Join-Path $jobDir "onstart_hf_speedtest.sh"
    New-HfSpeedTestOnstart `
        -Path $onstartPath `
        -MinMiBps $HfMinMiBps `
        -MaxEstimatedDownloadMinutes $HfMaxEstimatedDownloadMinutes `
        -SampleMiB $HfSpeedTestSampleMiB `
        -MaxSeconds $HfSpeedTestMaxSeconds

    Write-Host ""
    Write-Host ("[hf-select] test {0}: offer={1} machine={2} host={3} price=`${4}/h location={5}" -f `
        $TestIndex, $offerId, $Offer.machine_id, $Offer.host_id, $Offer.dph_total, $Offer.geolocation)

    $createOutput = @(& pwsh -File $createScript `
        -OfferId $offerId `
        -Image $Image `
        -Label $label `
        -DiskGb $DiskGb `
        -Onstart $onstartPath `
        -CancelUnavail 2>&1 | ForEach-Object { "$_" })

    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            offer_id = $offerId
            machine_id = $Offer.machine_id
            host_id = $Offer.host_id
            gpu_name = $Offer.gpu_name
            dph_total = [double]$Offer.dph_total
            geolocation = $Offer.geolocation
            driver_version = $Offer.driver_version
            status = "create_failed"
            decision = "reject"
            speed_mib_per_sec = $null
            estimated_download_minutes = $null
            estimated_download_cost_usd = $null
            instance_id = $null
            label = $label
            reason = ($createOutput | Select-Object -Last 3) -join " | "
        }
    }

    $instance = Get-InstanceByLabel -Label $label
    if (-not $instance) {
        return [pscustomobject]@{
            offer_id = $offerId
            machine_id = $Offer.machine_id
            host_id = $Offer.host_id
            gpu_name = $Offer.gpu_name
            dph_total = [double]$Offer.dph_total
            geolocation = $Offer.geolocation
            driver_version = $Offer.driver_version
            status = "instance_not_found"
            decision = "reject"
            speed_mib_per_sec = $null
            estimated_download_minutes = $null
            estimated_download_cost_usd = $null
            instance_id = $null
            label = $label
            reason = "Instance was created but could not be found by label."
        }
    }

    $safeInstance = $instance | Select-Object * -ExcludeProperty @("instance_api_key", "jupyter_token", "onstart", "ssh_key", "extra_env")
    $safeInstance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $jobDir "vast-instance.json") -Encoding UTF8

    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    $startupDeadline = (Get-Date).AddMinutes($MaxStartupWaitMinutes)
    $speedtestStarted = $false
    $startupTimedOut = $false
    $parsed = $null
    $lastLines = @()
    while ((Get-Date) -lt $deadline) {
        $lastLines = Get-VastLogTailSafe -InstanceId "$($safeInstance.id)" -Tail 240
        if ($lastLines | Where-Object { $_ -match '^\[hf-speedtest\]' } | Select-Object -First 1) {
            $speedtestStarted = $true
        }
        $parsed = Convert-SpeedLogToResult -Lines $lastLines
        if ($parsed) {
            break
        }

        if (-not $speedtestStarted -and (Get-Date) -ge $startupDeadline) {
            $startupTimedOut = $true
            Write-Host ("  [hf-select] startup_timeout: no hf-speedtest log after {0} min" -f $MaxStartupWaitMinutes)
            break
        }

        $interesting = $lastLines |
            Where-Object {
                $_ -match '^\[hf-speedtest\]' -or
                $_ -match '^\[stage\]' -or
                $_ -match 'No such container' -or
                $_ -match 'curl:'
            } |
            Select-Object -Last 4
        if ($interesting) {
            foreach ($line in $interesting) {
                Write-Host "  $line"
            }
        }
        else {
            Write-Host "  [hf-select] waiting for speedtest logs..."
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    $status = if ($parsed) { "measured" } elseif ($startupTimedOut) { "startup_timeout" } else { "timeout" }
    $decision = if ($parsed) { $parsed.Decision } else { "reject" }
    $estimatedCost = $null
    if ($parsed -and $null -ne $parsed.EstimatedDownloadMinutes) {
        $estimatedCost = [math]::Round(([double]$Offer.dph_total) * $parsed.EstimatedDownloadMinutes / 60, 4)
    }

    $result = [pscustomobject]@{
        offer_id = $offerId
        machine_id = $Offer.machine_id
        host_id = $Offer.host_id
        gpu_name = $Offer.gpu_name
        dph_total = [double]$Offer.dph_total
        geolocation = $Offer.geolocation
        driver_version = $Offer.driver_version
        status = $status
        decision = $decision
        speed_mib_per_sec = if ($parsed) { $parsed.SpeedMiBps } else { $null }
        estimated_download_minutes = if ($parsed) { $parsed.EstimatedDownloadMinutes } else { $null }
        estimated_download_cost_usd = $estimatedCost
        instance_id = $safeInstance.id
        label = $label
        reason = if ($parsed -and $parsed.Reason) { $parsed.Reason } elseif ($parsed) { $parsed.RawLine } elseif ($startupTimedOut) { "No hf-speedtest log within $MaxStartupWaitMinutes minutes after instance creation." } else { "Timed out waiting for speedtest result." }
    }

    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $jobDir "speedtest-result.json") -Encoding UTF8
    $lastLines | Set-Content -LiteralPath (Join-Path $jobDir "vast-log-tail.txt") -Encoding UTF8

    if (-not ($KeepPassingInstance -and $decision -eq "pass")) {
        try {
            & pwsh -File $destroyScript -InstanceId "$($safeInstance.id)" | Out-Null
            $result | Add-Member -NotePropertyName destroyed -NotePropertyValue $true
        }
        catch {
            $result | Add-Member -NotePropertyName destroyed -NotePropertyValue $false
            $result | Add-Member -NotePropertyName destroy_error -NotePropertyValue $_.Exception.Message
        }
    }
    else {
        $result | Add-Member -NotePropertyName destroyed -NotePropertyValue $false
    }

    Write-Host ("[hf-select] result offer={0} decision={1} speed={2}MiB/s estimate={3}min download_cost=`${4}" -f `
        $offerId, $result.decision, $result.speed_mib_per_sec, $result.estimated_download_minutes, $result.estimated_download_cost_usd)

    $result
}

$blacklist = Get-RegistryBlacklist -Path $RegistryPath

Write-Host "[hf-select] search query: $SearchQuery"
$rawOffers = Invoke-VastJson -Arguments @("search", "offers", $SearchQuery, "--storage", "$DiskGb", "--raw")
if ($LASTEXITCODE -ne 0) {
    throw "vastai search offers failed."
}

$offers = @($rawOffers | ConvertFrom-Json)
$filtered = @(
    $offers |
        Where-Object {
            if ($MaxDphTotal -gt 0 -and [double]$_.dph_total -gt $MaxDphTotal) { return $false }
            if ($MinDriverMajor -gt 0 -and (Get-DriverMajor -Offer $_) -lt $MinDriverMajor) { return $false }
            if ($blacklist.Machines.ContainsKey([string]$_.machine_id)) { return $false }
            if ($blacklist.Hosts.ContainsKey([string]$_.host_id)) { return $false }
            return $true
        } |
        Sort-Object `
            @{ Expression = { [double]$_.dph_total }; Ascending = $true }, `
            @{ Expression = { Get-DriverMajor -Offer $_ }; Descending = $true } |
        Select-Object -First $CandidateCount
)

if ($filtered.Count -eq 0) {
    throw "No candidate offers after price, driver, geolocation, and blacklist filters."
}

New-Item -ItemType Directory -Force -Path $speedRoot | Out-Null

$candidateSummary = @(
    $filtered | ForEach-Object {
        [pscustomobject]@{
            offer_id = $_.id
            machine_id = $_.machine_id
            host_id = $_.host_id
            gpu_name = $_.gpu_name
            dph_total = [double]$_.dph_total
            geolocation = $_.geolocation
            driver_version = $_.driver_version
        }
    }
)

$summaryPath = Join-Path $speedRoot ("candidates-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$candidateSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host "[hf-select] candidate_count=$($candidateSummary.Count) saved=$summaryPath"
$candidateSummary | Format-Table -AutoSize | Out-String | Write-Host

if ($ListOnly) {
    [pscustomobject]@{
        candidates_path = $summaryPath
        candidates = $candidateSummary
    } | ConvertTo-Json -Depth 10
    exit 0
}

$testLimit = [math]::Min($MaxTests, $filtered.Count)
$results = New-Object System.Collections.Generic.List[object]
$tested = 0

while ($tested -lt $testLimit) {
    $remainingSlots = $testLimit - $tested
    $currentBatchSize = [math]::Min($BatchSize, $remainingSlots)
    $batch = @($filtered | Select-Object -Skip $tested -First $currentBatchSize)
    if ($batch.Count -eq 0) {
        break
    }

    Write-Host ""
    Write-Host "[hf-select] testing next batch: size=$($batch.Count) tested_so_far=$tested max_tests=$testLimit"
    foreach ($offer in $batch) {
        $tested += 1
        $results.Add((Invoke-HfSpeedTestOffer -Offer $offer -TestIndex $tested))
    }

    $passing = @(
        $results |
            Where-Object { $_.decision -eq "pass" } |
            Sort-Object `
                @{ Expression = { if ($null -eq $_.estimated_download_cost_usd) { [double]::PositiveInfinity } else { [double]$_.estimated_download_cost_usd } }; Ascending = $true }, `
                @{ Expression = { [double]$_.dph_total }; Ascending = $true }, `
                @{ Expression = { if ($null -eq $_.speed_mib_per_sec) { 0 } else { [double]$_.speed_mib_per_sec } }; Descending = $true }
    )

    if ($passing.Count -gt 0) {
        break
    }

    Write-Host "[hf-select] no passing machine in this batch; continuing with the next candidate batch."
}

$finalPath = Join-Path $speedRoot ("speedtest-results-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $finalPath -Encoding UTF8

$best = @(
    $results |
        Where-Object { $_.decision -eq "pass" } |
        Sort-Object `
            @{ Expression = { if ($null -eq $_.estimated_download_cost_usd) { [double]::PositiveInfinity } else { [double]$_.estimated_download_cost_usd } }; Ascending = $true }, `
            @{ Expression = { [double]$_.dph_total }; Ascending = $true }, `
            @{ Expression = { if ($null -eq $_.speed_mib_per_sec) { 0 } else { [double]$_.speed_mib_per_sec } }; Descending = $true } |
        Select-Object -First 1
)

Write-Host "[hf-select] results saved=$finalPath"
if ($best.Count -gt 0) {
    Write-Host ("[hf-select] selected offer={0} machine={1} host={2} price=`${3}/h speed={4}MiB/s estimated_download={5}min" -f `
        $best[0].offer_id, $best[0].machine_id, $best[0].host_id, $best[0].dph_total, $best[0].speed_mib_per_sec, $best[0].estimated_download_minutes)
    $best[0] | ConvertTo-Json -Depth 10
}
else {
    Write-Host "[hf-select] no suitable machine found in tested candidates."
    [pscustomobject]@{
        selected = $null
        tested = $results.Count
        results_path = $finalPath
        candidates_path = $summaryPath
    } | ConvertTo-Json -Depth 10
    exit 2
}
