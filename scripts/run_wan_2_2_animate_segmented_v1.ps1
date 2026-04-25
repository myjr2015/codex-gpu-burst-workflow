param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$ImagePath,

    [Parameter(Mandatory = $true)]
    [string]$VideoPath,

    [string]$ImageAssetDir = ".\素材资产\美女图带光伏",

    [ValidateSet("1.0-cold", "1.1-machine-registry")]
    [string]$RuntimeVersion = "1.1-machine-registry",

    [string]$OfferId,

    [string]$RegistryPath = ".\data\vast-machine-registry.json",

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [int]$SegmentSeconds = 10,

    [switch]$UseSpeechAwareSegmentation,

    [string]$TranscriptPath,

    [double]$TargetSegmentSeconds = 10.0,

    [double]$MinSegmentSeconds = 8.0,

    [double]$MaxSegmentSeconds = 12.0,

    [double]$OverlapSeconds = 0.0,

    [double]$PauseThresholdSeconds = 0.35,

    [string]$WhisperModel = "small",

    [string]$WhisperDevice = "auto",

    [string]$WhisperComputeType = "int8",

    [int]$WhisperBeamSize = 5,

    [int]$MaxSegments = 0,

    [switch]$FreshMachine,

    [switch]$CancelUnavail,

    [int]$DownloadIntervalSeconds = 30,

    [int]$DownloadMaxChecks = 240,

    [switch]$SkipPublish,

    [switch]$SkipSegmentRuns,

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
$childRunnerPath = Join-Path $repoRoot "scripts\run_wan_2_2_animate_end_to_end.ps1"
$speechPlannerPath = Join-Path $repoRoot "scripts\plan_speech_aware_segments.py"
$transcribeScriptPath = Join-Path $repoRoot "scripts\faster-whisper-transcribe.py"
$uploadScript = Join-Path $repoRoot "scripts\r2_upload.py"
$ffmpegPath = Join-Path $repoRoot "node_modules\ffmpeg-static\ffmpeg.exe"
$ffprobePath = Join-Path $repoRoot "node_modules\ffprobe-static\bin\win32\x64\ffprobe.exe"
$whisperPythonPath = Join-Path $repoRoot ".venv-faster-whisper\Scripts\python.exe"

foreach ($required in @($r2HelperPath, $childRunnerPath, $speechPlannerPath, $transcribeScriptPath, $uploadScript, $ffmpegPath, $ffprobePath)) {
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

    $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [ref]$Report,

        [Parameter(Mandatory = $true)]
        [string]$ReportPath
    )

    $step = [ordered]@{
        name = $Name
        started_at = (Get-Date).ToString("s")
        ended_at = $null
        duration_seconds = $null
        status = "running"
        notes = @()
    }

    $steps = @($Report.Value.steps)
    $steps += $step
    $Report.Value.steps = $steps
    $stepIndex = $Report.Value.steps.Count - 1
    Write-JsonFile -Path $ReportPath -Data $Report.Value

    try {
        $result = & $Action
        $ended = Get-Date
        $started = [datetime]::Parse($step.started_at, [System.Globalization.CultureInfo]::InvariantCulture)
        $step.ended_at = $ended.ToString("s")
        $step.duration_seconds = [math]::Round(($ended - $started).TotalSeconds, 3)
        $step.status = "succeeded"
        if ($null -ne $result) {
            if ($result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
                $step.notes = @($result)
            }
            else {
                $step.notes = @("$result")
            }
        }
        $Report.Value.steps[$stepIndex] = $step
        Write-JsonFile -Path $ReportPath -Data $Report.Value
        return $result
    }
    catch {
        $ended = Get-Date
        $started = [datetime]::Parse($step.started_at, [System.Globalization.CultureInfo]::InvariantCulture)
        $step.ended_at = $ended.ToString("s")
        $step.duration_seconds = [math]::Round(($ended - $started).TotalSeconds, 3)
        $step.status = "failed"
        $step.notes = @($_.Exception.Message)
        $Report.Value.steps[$stepIndex] = $step
        $Report.Value.status = "failed"
        $Report.Value.error = $_.Exception.Message
        $Report.Value.ended_at = (Get-Date).ToString("s")
        Write-JsonFile -Path $ReportPath -Data $Report.Value
        throw
    }
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

function Invoke-JsonPythonScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PythonPath,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string[]]$ScriptArgs
    )

    $previousPythonUtf8 = $env:PYTHONUTF8
    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"

    try {
        $output = & $PythonPath $ScriptPath @ScriptArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Python script failed: $ScriptPath"
        }
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

    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Python script returned empty output: $ScriptPath"
    }

    $text | ConvertFrom-Json
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

$resolvedVideoPath = (Resolve-Path -LiteralPath $VideoPath).Path
if ([string]::IsNullOrWhiteSpace($ImagePath)) {
    $ImagePath = Resolve-DefaultImage -AssetDir (Join-Path $repoRoot $ImageAssetDir)
}
$resolvedImagePath = (Resolve-Path -LiteralPath $ImagePath).Path
$videoDurationSeconds = Get-VideoDurationSeconds -Path $resolvedVideoPath
$jobDir = Join-Path $repoRoot ("output\wan_2_2_animate_segmented\" + $JobName)
$segmentsDir = Join-Path $jobDir "segments"
$downloadsDir = Join-Path $jobDir "downloads"
$reportPath = Join-Path $jobDir "run-report.json"
$manifestPath = Join-Path $jobDir "manifest.json"
$mergeListPath = Join-Path $jobDir "concat-inputs.txt"
$mergedOutputPath = Join-Path $downloadsDir ("wan_2_2_animate_segmented-" + $JobName + ".mp4")
$transcriptOutPath = Join-Path $jobDir "transcript.json"
$segmentPlanPath = Join-Path $jobDir "segment-plan.json"

New-Item -ItemType Directory -Force -Path $segmentsDir | Out-Null
New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null

$segmentCount = [int][math]::Ceiling($videoDurationSeconds / $SegmentSeconds)
if ($MaxSegments -gt 0) {
    $segmentCount = [math]::Min($segmentCount, $MaxSegments)
}

$report = [ordered]@{
    profile = "wan_2_2_animate_segmented"
    variant = "v1"
    job_name = $JobName
    started_at = (Get-Date).ToString("s")
    status = "running"
    steps = @()
    warnings = @()
}
Write-JsonFile -Path $reportPath -Data $report

$speechAwarePlan = $null

if ($UseSpeechAwareSegmentation) {
    if (-not (Test-Path -LiteralPath $whisperPythonPath)) {
        throw "Speech-aware segmentation requires faster-whisper python environment: $whisperPythonPath"
    }

    Invoke-Step -Name "transcribe_source" -Report ([ref]$report) -ReportPath $reportPath -Action {
        if (-not [string]::IsNullOrWhiteSpace($TranscriptPath)) {
            Copy-Item -LiteralPath (Resolve-Path -LiteralPath $TranscriptPath).Path -Destination $transcriptOutPath -Force
            return @("transcript_source=$TranscriptPath")
        }

        $transcript = Invoke-JsonPythonScript `
            -PythonPath $whisperPythonPath `
            -ScriptPath $transcribeScriptPath `
            -ScriptArgs @(
                "--audio-path", $resolvedVideoPath,
                "--language", "zh",
                "--model", $WhisperModel,
                "--device", $WhisperDevice,
                "--compute-type", $WhisperComputeType,
                "--beam-size", $WhisperBeamSize.ToString()
            )

        Write-JsonFile -Path $transcriptOutPath -Data $transcript
        @(
            "transcript_path=$transcriptOutPath",
            "transcript_segments=$(@($transcript.segments).Count)"
        )
    } | Out-Null

    Invoke-Step -Name "plan_segments" -Report ([ref]$report) -ReportPath $reportPath -Action {
        $plan = Invoke-JsonPythonScript `
            -PythonPath $whisperPythonPath `
            -ScriptPath $speechPlannerPath `
            -ScriptArgs @(
                "--transcript-path", $transcriptOutPath,
                "--output-path", $segmentPlanPath,
                "--target-seconds", $TargetSegmentSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
                "--min-seconds", $MinSegmentSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
                "--max-seconds", $MaxSegmentSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
                "--overlap-seconds", $OverlapSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture),
                "--pause-threshold-seconds", $PauseThresholdSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            )

        Write-JsonFile -Path $segmentPlanPath -Data $plan
        @(
            "segment_plan_path=$segmentPlanPath",
            "planned_segments=$(@($plan.segments).Count)"
        )
    } | Out-Null

    $speechAwarePlan = Get-Content -Raw -LiteralPath $segmentPlanPath | ConvertFrom-Json
}

$segmentRecords = Invoke-Step -Name "split_segments" -Report ([ref]$report) -ReportPath $reportPath -Action {
    $records = @()

    if ($speechAwarePlan) {
        $plannedSegments = @($speechAwarePlan.segments)
        if ($MaxSegments -gt 0) {
            $plannedSegments = @($plannedSegments | Select-Object -First $MaxSegments)
        }

        foreach ($plannedSegment in $plannedSegments) {
            $segmentNumber = [int]$plannedSegment.index
            $startSeconds = [double]$plannedSegment.start_seconds
            $endSeconds = [double]$plannedSegment.end_seconds
            $durationSeconds = [math]::Max(0.0, $endSeconds - $startSeconds)
            if ($durationSeconds -le 0) {
                continue
            }

            $segmentPath = Join-Path $segmentsDir ("segment-{0:d2}.mp4" -f $segmentNumber)
            New-VideoSegment -InputPath $resolvedVideoPath -StartSeconds $startSeconds -DurationSeconds $durationSeconds -OutputPath $segmentPath
            $records += [ordered]@{
                index = $segmentNumber
                start_seconds = [math]::Round($startSeconds, 3)
                end_seconds = [math]::Round($endSeconds, 3)
                duration_seconds = [math]::Round($durationSeconds, 3)
                segment_path = $segmentPath
                text = [string]$plannedSegment.text
                child_job_name = ("{0}-s{1:d2}" -f $JobName, $segmentNumber)
            }
        }

        return $records
    }

    for ($index = 0; $index -lt $segmentCount; $index += 1) {
        $segmentNumber = $index + 1
        $startSeconds = $index * $SegmentSeconds
        $remaining = [math]::Max(0.0, $videoDurationSeconds - $startSeconds)
        $durationSeconds = [math]::Min([double]$SegmentSeconds, $remaining)
        if ($durationSeconds -le 0) {
            break
        }

        $segmentPath = Join-Path $segmentsDir ("segment-{0:d2}.mp4" -f $segmentNumber)
        New-VideoSegment -InputPath $resolvedVideoPath -StartSeconds $startSeconds -DurationSeconds $durationSeconds -OutputPath $segmentPath
        $records += [ordered]@{
            index = $segmentNumber
            start_seconds = [math]::Round($startSeconds, 3)
            end_seconds = [math]::Round(($startSeconds + $durationSeconds), 3)
            duration_seconds = [math]::Round($durationSeconds, 3)
            segment_path = $segmentPath
            child_job_name = ("{0}-s{1:d2}" -f $JobName, $segmentNumber)
        }
    }
    $records
}

$manifest = [ordered]@{
    profile = "wan_2_2_animate_segmented"
    variant = "v1"
    job_name = $JobName
    created_at = (Get-Date).ToString("s")
    source = [ordered]@{
        image_path = $resolvedImagePath
        video_path = $resolvedVideoPath
        video_duration_seconds = [math]::Round($videoDurationSeconds, 3)
        segment_seconds = $SegmentSeconds
        segment_count = @($segmentRecords).Count
        segmentation_mode = $(if ($UseSpeechAwareSegmentation) { "speech_aware" } else { "fixed" })
    }
    segments = @($segmentRecords)
    local = [ordered]@{
        job_dir = $jobDir
        segments_dir = $segmentsDir
        downloads_dir = $downloadsDir
        merge_list = $mergeListPath
        merged_output = $mergedOutputPath
        run_report = $reportPath
        transcript_path = $(if ($UseSpeechAwareSegmentation) { $transcriptOutPath } else { $null })
        segment_plan_path = $(if ($UseSpeechAwareSegmentation) { $segmentPlanPath } else { $null })
    }
}
Write-JsonFile -Path $manifestPath -Data $manifest

if (-not $SkipSegmentRuns) {
    foreach ($segment in $segmentRecords) {
        $stepName = "run_segment_{0:d2}" -f $segment.index
        Invoke-Step -Name $stepName -Report ([ref]$report) -ReportPath $reportPath -Action {
            $segmentArgs = @(
                "-File", $childRunnerPath,
                "-JobName", $segment.child_job_name,
                "-RuntimeVersion", $RuntimeVersion,
                "-ImagePath", $resolvedImagePath,
                "-VideoPath", $segment.segment_path,
                "-DownloadIntervalSeconds", $DownloadIntervalSeconds.ToString(),
                "-DownloadMaxChecks", $DownloadMaxChecks.ToString(),
                "-DestroyInstance"
            )

            if ($CancelUnavail) {
                $segmentArgs += "-CancelUnavail"
            }
            if ($FreshMachine) {
                $segmentArgs += "-FreshMachine"
            }
            if (-not [string]::IsNullOrWhiteSpace($OfferId)) {
                $segmentArgs += @("-OfferId", $OfferId)
            }
            else {
                $segmentArgs += @("-RegistryPath", $RegistryPath)
            }

            # Segment outputs are intermediate artifacts; only the merged output is published.
            $segmentArgs += "-SkipPublish"

            & pwsh @segmentArgs
            if ($LASTEXITCODE -ne 0) {
                throw "Segment runner failed: $($segment.child_job_name)"
            }

            $childManifestPath = Join-Path $repoRoot ("output\wan_2_2_animate\" + $segment.child_job_name + "\manifest.json")
            if (-not (Test-Path -LiteralPath $childManifestPath)) {
                throw "Missing child manifest: $childManifestPath"
            }
            $childManifest = Get-Content -Raw -LiteralPath $childManifestPath | ConvertFrom-Json -AsHashtable
            $segment["child_result_path"] = [string]$childManifest.result.local_result_path
            $segment["child_prompt_id"] = [string]$childManifest.result.prompt_id
            $segment["child_job_dir"] = Join-Path $repoRoot ("output\wan_2_2_animate\" + $segment.child_job_name)
            @(
                "child_job=$($segment.child_job_name)",
                "child_result=$($segment.child_result_path)"
            )
        } | Out-Null
    }

    Write-JsonFile -Path $manifestPath -Data $manifest

    Invoke-Step -Name "merge_segments" -Report ([ref]$report) -ReportPath $reportPath -Action {
        $childResults = @($manifest.segments | ForEach-Object { [string]$_["child_result_path"] })
        if ($childResults.Count -lt 1) {
            throw "No child segment outputs available to merge."
        }
        Merge-VideoSegments -InputPaths $childResults -ListPath $mergeListPath -OutputPath $mergedOutputPath
        $mergedDuration = Get-VideoDurationSeconds -Path $mergedOutputPath
        $manifest["merged_result"] = [ordered]@{
            local_result_path = $mergedOutputPath
            duration_seconds = [math]::Round($mergedDuration, 3)
            merged_at = (Get-Date).ToString("s")
        }
        Write-JsonFile -Path $manifestPath -Data $manifest
        @(
            "merged_result=$mergedOutputPath",
            "merged_duration_seconds=$([math]::Round($mergedDuration, 3))"
        )
    } | Out-Null

    if (-not $SkipPublish) {
        Invoke-Step -Name "publish_merged_result" -Report ([ref]$report) -ReportPath $reportPath -Action {
            if ([string]::IsNullOrWhiteSpace($R2AccountId) -or [string]::IsNullOrWhiteSpace($R2AccessKeyId) -or [string]::IsNullOrWhiteSpace($R2SecretAccessKey)) {
                throw "R2 credentials missing for segmented publish."
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
                throw "Failed to upload merged segmented result."
            }

            $resultName = [System.IO.Path]::GetFileName($mergedOutputPath)
            $remoteKey = "$R2Prefix/$JobName/output/$resultName"
            $publicUrl = "$($R2PublicBaseUrl.TrimEnd('/'))/$(Encode-R2Key -Key $remoteKey)"
            $manifest["published_result"] = [ordered]@{
                local_result_path = $mergedOutputPath
                bucket = $R2Bucket
                remote_key = $remoteKey
                public_url = $publicUrl
                uploaded_at = (Get-Date).ToString("s")
            }
            Write-JsonFile -Path $manifestPath -Data $manifest
            @(
                "public_url=$publicUrl"
            )
        } | Out-Null
    }
}

$report.status = "succeeded"
$report.ended_at = (Get-Date).ToString("s")
Write-JsonFile -Path $reportPath -Data $report

Write-Host "run_report=$reportPath"
Write-Host "manifest=$manifestPath"
if ($manifest.merged_result.local_result_path) {
    Write-Host "local_result=$($manifest.merged_result.local_result_path)"
}
if ($manifest.published_result.public_url) {
    Write-Host "public_url=$($manifest.published_result.public_url)"
}
