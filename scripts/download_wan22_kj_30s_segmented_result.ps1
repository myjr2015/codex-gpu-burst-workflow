param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$BaseUrl,

    [string]$OutputDir,

    [int]$IntervalSeconds = 30,

    [int]$MaxChecks = 900,

    [switch]$Wait
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (Test-Path -LiteralPath $r2HelperPath) {
    . $r2HelperPath
    Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
}

$ffmpegCandidates = @(
    (Join-Path $repoRoot "node_modules\ffmpeg-static\ffmpeg.exe"),
    "D:\code\KuangJia\ffmpeg\ffmpeg.exe"
)
$ffprobeCandidates = @(
    (Join-Path $repoRoot "node_modules\ffprobe-static\bin\win32\x64\ffprobe.exe"),
    "D:\code\KuangJia\ffmpeg\ffprobe.exe"
)
$ffmpegPath = $ffmpegCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$ffprobePath = $ffprobeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($ffmpegPath)) {
    throw "Missing ffmpeg. Checked: $($ffmpegCandidates -join ', ')"
}
if ([string]::IsNullOrWhiteSpace($ffprobePath)) {
    throw "Missing ffprobe. Checked: $($ffprobeCandidates -join ', ')"
}

function Get-JobPaths {
    param([Parameter(Mandatory = $true)][string]$JobName)

    $jobDir = Join-Path $repoRoot ("output\wan22_kj_30s_segmented\" + $JobName)
    if (-not (Test-Path -LiteralPath $jobDir)) {
        throw "Missing job directory: $jobDir"
    }

    $manifestPath = Join-Path $jobDir "manifest.json"
    $instancePath = Join-Path $jobDir "vast-instance.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Missing manifest: $manifestPath"
    }
    if (-not (Test-Path -LiteralPath $instancePath)) {
        throw "Missing instance metadata: $instancePath"
    }

    [pscustomobject]@{
        JobDir = $jobDir
        ManifestPath = $manifestPath
        InstancePath = $instancePath
        HistoryApiPath = Join-Path $jobDir "history.api.json"
        ResultMetaPath = Join-Path $jobDir "result.api.json"
        DownloadsDir = Join-Path $jobDir "downloads"
        MergeListPath = Join-Path $jobDir "concat-inputs.txt"
    }
}

function Get-InstanceIdFromPath {
    param([Parameter(Mandatory = $true)][string]$InstancePath)

    if (-not (Test-Path -LiteralPath $InstancePath)) {
        return $null
    }
    $instance = Get-Content -Raw $InstancePath | ConvertFrom-Json
    if ($instance -and $instance.id) {
        return "$($instance.id)"
    }
    $null
}

function Get-BaseUrlFromInstance {
    param([Parameter(Mandatory = $true)][string]$InstancePath)

    $instance = Get-Content -Raw $InstancePath | ConvertFrom-Json
    $portBindings = $instance.ports.'8188/tcp'
    if ((-not $portBindings -or $portBindings.Count -lt 1) -and $instance.id) {
        $previousPythonIoEncoding = $env:PYTHONIOENCODING
        $env:PYTHONIOENCODING = "utf-8"
        try {
            $liveInstance = & vastai show instance $instance.id --raw 2>$null | ConvertFrom-Json
        }
        finally {
            if ($null -eq $previousPythonIoEncoding) {
                Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
            }
            else {
                $env:PYTHONIOENCODING = $previousPythonIoEncoding
            }
        }
        if ($liveInstance) {
            $instance = $liveInstance | Select-Object * -ExcludeProperty @("instance_api_key", "jupyter_token", "onstart", "ssh_key", "extra_env")
            $portBindings = $instance.ports.'8188/tcp'
            $instance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $InstancePath -Encoding UTF8
        }
    }
    if (-not $portBindings -or $portBindings.Count -lt 1) {
        throw "Instance metadata missing 8188/tcp port binding."
    }

    $hostPort = $portBindings[0].HostPort
    $publicIp = $instance.public_ipaddr
    if ([string]::IsNullOrWhiteSpace($hostPort) -or [string]::IsNullOrWhiteSpace($publicIp)) {
        throw "Instance metadata missing public IP or 8188 host port."
    }

    "http://{0}:{1}" -f $publicIp, $hostPort
}

function Get-VastLogTailSafe {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
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
        @()
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

function Assert-NoRemotePreflightFailure {
    param([string]$InstanceId)

    if ([string]::IsNullOrWhiteSpace($InstanceId)) {
        return
    }

    $failure = Get-VastLogTailSafe -InstanceId $InstanceId |
        Where-Object {
            $_ -match '^\[hf-speedtest\].*decision=reject' -or
            $_ -match '^\[hf-speedtest\] reject' -or
            $_ -match 'stopping before bootstrap to avoid slow model download'
        } |
        Select-Object -Last 1

    if ($failure) {
        throw "HF speed preflight rejected this machine: $failure"
    }
}

function Get-HistoryPayload {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)
    Invoke-RestMethod -Uri "$($BaseUrl.TrimEnd('/'))/history" -Method Get -TimeoutSec 60
}

function Get-EntryTimestamp {
    param([Parameter(Mandatory = $true)]$Entry)

    $timestamp = 0L
    if ($Entry.status -and $Entry.status.messages) {
        foreach ($message in $Entry.status.messages) {
            if ($message.Count -ge 2 -and $message[1].timestamp) {
                $value = [int64]$message[1].timestamp
                if ($value -gt $timestamp) {
                    $timestamp = $value
                }
            }
        }
    }
    if ($timestamp -eq 0 -and $Entry.prompt -and $Entry.prompt.Count -ge 4) {
        $promptMeta = $Entry.prompt[3]
        if ($promptMeta -and $promptMeta.create_time) {
            $timestamp = [int64]$promptMeta.create_time
        }
    }
    $timestamp
}

function Find-OutputCandidateByPrefix {
    param(
        [Parameter(Mandatory = $true)]$History,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($historyProperty in $History.PSObject.Properties) {
        $promptId = $historyProperty.Name
        $entry = $historyProperty.Value
        if (-not $entry.outputs) {
            continue
        }

        $entryTimestamp = Get-EntryTimestamp -Entry $entry
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
                    Timestamp = $entryTimestamp
                    Filename = $gif.filename
                    Type = $gif.type
                    Subfolder = [string]$gif.subfolder
                    Format = [string]$gif.format
                    FrameRate = $gif.frame_rate
                    FullPath = [string]$gif.fullpath
                })
            }
        }
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    $candidates |
        Sort-Object `
            @{ Expression = { $_.Timestamp }; Descending = $true }, `
            @{ Expression = { $_.Filename }; Descending = $true } |
        Select-Object -First 1
}

function Test-RemoteSegmentEnded {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Logs,

        [Parameter(Mandatory = $true)]
        [string]$SegmentId
    )

    $escaped = [regex]::Escape($SegmentId)
    $patterns = @(
        "remote\.segment_$escaped\s+end",
        "\[remote-kj30s-segmented\]\s+segment_$escaped\s+end"
    )

    foreach ($line in $Logs) {
        foreach ($pattern in $patterns) {
            if ($line -match $pattern) {
                return $true
            }
        }
    }

    $false
}

function New-PredictedOutputCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SegmentId,

        [Parameter(Mandatory = $true)]
        [string]$Prefix
    )

    [pscustomobject]@{
        PromptId = "history_unavailable_segment_$SegmentId"
        NodeId = "156"
        Timestamp = 0
        Filename = "${Prefix}_00001-audio.mp4"
        Type = "output"
        Subfolder = ""
        Format = "video/h264-mp4"
        FrameRate = 16.0
        FullPath = ""
    }
}

function Get-VideoDurationSeconds {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $Path
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw "Failed to read video duration: $Path"
    }
    [double]$raw
}

function Merge-VideoSegments {
    param(
        [Parameter(Mandatory = $true)][string[]]$InputPaths,
        [Parameter(Mandatory = $true)][string]$ListPath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    $lines = foreach ($path in $InputPaths) {
        $normalized = $path.Replace("\", "/").Replace("'", "''")
        "file '$normalized'"
    }
    Set-Content -LiteralPath $ListPath -Value $lines -Encoding ASCII

    & $ffmpegPath -y -f concat -safe 0 -i $ListPath -c copy $OutputPath | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return "concat_copy"
    }

    & $ffmpegPath -y -f concat -safe 0 -i $ListPath -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -c:a aac -movflags +faststart $OutputPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg merge failed: $OutputPath"
    }
    "concat_transcode"
}

$paths = Get-JobPaths -JobName $JobName
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = $paths.DownloadsDir
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$manifest = Get-Content -Raw $paths.ManifestPath | ConvertFrom-Json -AsHashtable
$segments = @($manifest["segments"])
if ($segments.Count -lt 1) {
    throw "Manifest has no segments."
}

$history = $null
$resolvedBaseUrl = $BaseUrl
$instanceId = Get-InstanceIdFromPath -InstancePath $paths.InstancePath
$lastError = $null
$segmentCandidates = @{}

for ($check = 1; $check -le $MaxChecks; $check += 1) {
    try {
        Assert-NoRemotePreflightFailure -InstanceId $instanceId
        if ([string]::IsNullOrWhiteSpace($resolvedBaseUrl)) {
            $resolvedBaseUrl = Get-BaseUrlFromInstance -InstancePath $paths.InstancePath
        }
        $resolvedBaseUrl = $resolvedBaseUrl.TrimEnd("/")
        $history = Get-HistoryPayload -BaseUrl $resolvedBaseUrl
        $segmentCandidates = @{}
        foreach ($segment in $segments) {
            $candidate = Find-OutputCandidateByPrefix -History $history -Prefix ([string]$segment.output_prefix)
            if ($candidate) {
                $segmentCandidates[[string]$segment.id] = $candidate
            }
        }
        if ($segmentCandidates.Count -lt $segments.Count -and -not [string]::IsNullOrWhiteSpace($instanceId)) {
            $logs = Get-VastLogTailSafe -InstanceId $instanceId -Tail 20000
            foreach ($segment in $segments) {
                $segmentId = [string]$segment.id
                if ($segmentCandidates.ContainsKey($segmentId)) {
                    continue
                }
                if (Test-RemoteSegmentEnded -Logs $logs -SegmentId $segmentId) {
                    $segmentCandidates[$segmentId] = New-PredictedOutputCandidate -SegmentId $segmentId -Prefix ([string]$segment.output_prefix)
                }
            }
        }
        if ($segmentCandidates.Count -ge $segments.Count) {
            break
        }
        $lastError = $null
    }
    catch {
        $lastError = $_.Exception.Message
    }

    if (-not $Wait) {
        break
    }
    Assert-NoRemotePreflightFailure -InstanceId $instanceId
    Start-Sleep -Seconds $IntervalSeconds
}

if (-not $history) {
    if ($lastError) {
        throw "Failed to read ComfyUI history API: $lastError"
    }
    throw "Failed to read ComfyUI history API."
}

$history | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $paths.HistoryApiPath -Encoding UTF8

if ($segmentCandidates.Count -lt $segments.Count) {
    $ready = @($segmentCandidates.Keys | Sort-Object) -join ","
    throw "Only $($segmentCandidates.Count)/$($segments.Count) segment outputs found. ready=[$ready]"
}

$downloadedSegments = @()
$downloadedPaths = @()
foreach ($segment in $segments) {
    $candidate = $segmentCandidates[[string]$segment.id]
    $query = "filename=$([uri]::EscapeDataString($candidate.Filename))&type=$([uri]::EscapeDataString($candidate.Type))&subfolder=$([uri]::EscapeDataString($candidate.Subfolder))"
    $downloadUrl = "$resolvedBaseUrl/view?$query"
    $localResultPath = Join-Path (Resolve-Path -LiteralPath $OutputDir).Path $candidate.Filename

    Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $localResultPath -TimeoutSec 1800
    $duration = Get-VideoDurationSeconds -Path $localResultPath
    $downloadedPaths += $localResultPath
    $downloadedSegments += [ordered]@{
        id = [string]$segment.id
        prompt_id = $candidate.PromptId
        node_id = $candidate.NodeId
        filename = $candidate.Filename
        type = $candidate.Type
        subfolder = $candidate.Subfolder
        frame_rate = $candidate.FrameRate
        local_result_path = $localResultPath
        duration_seconds = [math]::Round($duration, 3)
        download_url = $downloadUrl
    }
}

$mergedOutputPath = Join-Path (Resolve-Path -LiteralPath $OutputDir).Path ("wan22_kj_30s_segmented-" + $JobName + ".mp4")
$mergeMode = Merge-VideoSegments -InputPaths @($downloadedPaths | ForEach-Object { [string]$_ }) -ListPath $paths.MergeListPath -OutputPath $mergedOutputPath
$mergedDuration = Get-VideoDurationSeconds -Path $mergedOutputPath

$resultInfo = [ordered]@{
    base_url = $resolvedBaseUrl
    local_result_path = $mergedOutputPath
    merged_duration_seconds = [math]::Round($mergedDuration, 3)
    merge_mode = $mergeMode
    segment_count = $segments.Count
    segments = @($downloadedSegments)
    downloaded_at = (Get-Date).ToString("s")
}

$resultInfo | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $paths.ResultMetaPath -Encoding UTF8
$manifest["result"] = $resultInfo
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $paths.ManifestPath -Encoding UTF8

Write-Host "base_url=$resolvedBaseUrl"
Write-Host "segment_count=$($segments.Count)"
foreach ($segmentResult in $downloadedSegments) {
    Write-Host "segment_$($segmentResult.id)=$($segmentResult.local_result_path)"
}
Write-Host "merge_mode=$mergeMode"
Write-Host "merged_duration_seconds=$([math]::Round($mergedDuration, 3))"
Write-Host "local_result=$mergedOutputPath"
