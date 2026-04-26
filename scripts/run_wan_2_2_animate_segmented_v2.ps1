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

    [int]$ContinueMotionFrames = 5,

    [int]$MaxSegments = 2,

    [switch]$FreshMachine,

    [switch]$CancelUnavail,

    [int]$DownloadIntervalSeconds = 30,

    [int]$DownloadMaxChecks = 240,

    [switch]$SkipPublish,

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
$uploadScript = Join-Path $repoRoot "scripts\r2_upload.py"
$ffmpegPath = Join-Path $repoRoot "node_modules\ffmpeg-static\ffmpeg.exe"
$ffprobePath = Join-Path $repoRoot "node_modules\ffprobe-static\bin\win32\x64\ffprobe.exe"

foreach ($required in @($r2HelperPath, $childRunnerPath, $uploadScript, $ffmpegPath, $ffprobePath)) {
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

function Extract-TailFrames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoPath,

        [Parameter(Mandatory = $true)]
        [int]$FrameCount,

        [Parameter(Mandatory = $true)]
        [string]$OutputDir
    )

    if ($FrameCount -le 0) {
        return @()
    }

    if (Test-Path -LiteralPath $OutputDir) {
        Remove-Item -LiteralPath $OutputDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    $pattern = Join-Path $OutputDir "tail-%03d.png"
    & $ffmpegPath `
        -y `
        -sseof -1 `
        -i $VideoPath `
        -vf "select='gte(n,0)',fps=16" `
        -vsync 0 `
        $pattern | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg tail frame extraction failed: $VideoPath"
    }

    $frames = @(Get-ChildItem -LiteralPath $OutputDir -File | Sort-Object Name)
    if ($frames.Count -lt 1) {
        throw "No continuation frames extracted from $VideoPath"
    }

    if ($frames.Count -gt $FrameCount) {
        $frames = @($frames | Select-Object -Last $FrameCount)
    }

    @($frames | ForEach-Object { $_.FullName })
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

function Resolve-OfferMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OfferId
    )

    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = "utf-8"
    try {
        $offers = @(& vastai search offers "gpu_name=RTX_3090 num_gpus=1 gpu_ram>=24 rented=False" --storage 180 --raw | ConvertFrom-Json)
    }
    finally {
        if ($null -eq $previousPythonIoEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        }
        else {
            $env:PYTHONIOENCODING = $previousPythonIoEncoding
        }
    }

    $offer = $offers | Where-Object { "$($_.id)" -eq "$OfferId" } | Select-Object -First 1
    if (-not $offer) {
        return $null
    }

    [pscustomobject]@{
        offer_id = [string]$offer.id
        machine_id = [string]$offer.machine_id
        host_id = [string]$offer.host_id
    }
}

function Resolve-CurrentOfferForMachine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MachineId,

        [int]$Storage = 180
    )

    $query = "machine_id=$MachineId rented=False"
    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = "utf-8"
    try {
        $offers = @(& vastai search offers $query --storage $Storage --raw | ConvertFrom-Json)
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
        return $null
    }

    [pscustomobject]@{
        offer_id = [string]$offer.id
        machine_id = [string]$offer.machine_id
        host_id = [string]$offer.host_id
        dph_total = $offer.dph_total
    }
}

function Read-ChildMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChildJobName
    )

    $childDir = Join-Path $repoRoot ("output\wan_2_2_animate\" + $ChildJobName)
    $childManifestPath = Join-Path $childDir "manifest.json"
    $childInstancePath = Join-Path $childDir "vast-instance.json"
    $childTimingPath = Join-Path $childDir "timing-summary.json"

    if (-not (Test-Path -LiteralPath $childManifestPath)) {
        throw "Missing child manifest: $childManifestPath"
    }

    $childManifest = Get-Content -Raw -LiteralPath $childManifestPath | ConvertFrom-Json -AsHashtable
    $childInstance = $null
    $childTiming = $null

    if (Test-Path -LiteralPath $childInstancePath) {
        $childInstance = Get-Content -Raw -LiteralPath $childInstancePath | ConvertFrom-Json -AsHashtable
    }
    if (Test-Path -LiteralPath $childTimingPath) {
        $childTiming = Get-Content -Raw -LiteralPath $childTimingPath | ConvertFrom-Json -AsHashtable
    }

    [pscustomobject]@{
        child_dir = $childDir
        manifest = $childManifest
        instance = $childInstance
        timing = $childTiming
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
$continuationDir = Join-Path $jobDir "continue-motion"
$downloadsDir = Join-Path $jobDir "downloads"
$reportPath = Join-Path $jobDir "run-report.json"
$manifestPath = Join-Path $jobDir "manifest.json"
$mergeListPath = Join-Path $jobDir "concat-inputs.txt"
$mergedOutputPath = Join-Path $downloadsDir ("wan_2_2_animate_segmented-" + $JobName + ".mp4")

New-Item -ItemType Directory -Force -Path $segmentsDir | Out-Null
New-Item -ItemType Directory -Force -Path $continuationDir | Out-Null
New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null

$segmentCount = [int][math]::Ceiling($videoDurationSeconds / $SegmentSeconds)
if ($MaxSegments -gt 0) {
    $segmentCount = [math]::Min($segmentCount, $MaxSegments)
}

$report = [ordered]@{
    profile = "wan_2_2_animate_segmented"
    variant = "v2"
    job_name = $JobName
    started_at = (Get-Date).ToString("s")
    status = "running"
    steps = @()
    warnings = @()
}
Write-JsonFile -Path $reportPath -Data $report

$segmentRecords = Invoke-Step -Name "split_segments" -Report ([ref]$report) -ReportPath $reportPath -Action {
    $records = @()

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
            continuation_frames = @()
        }
    }

    $records
}

$manifest = [ordered]@{
    profile = "wan_2_2_animate_segmented"
    variant = "v2"
    job_name = $JobName
    created_at = (Get-Date).ToString("s")
    source = [ordered]@{
        image_path = $resolvedImagePath
        video_path = $resolvedVideoPath
        video_duration_seconds = [math]::Round($videoDurationSeconds, 3)
        segment_seconds = $SegmentSeconds
        segment_count = @($segmentRecords).Count
        continue_motion_frames = $ContinueMotionFrames
    }
    segments = @($segmentRecords)
    local = [ordered]@{
        job_dir = $jobDir
        segments_dir = $segmentsDir
        continuation_dir = $continuationDir
        downloads_dir = $downloadsDir
        merge_list = $mergeListPath
        merged_output = $mergedOutputPath
        run_report = $reportPath
    }
}
Write-JsonFile -Path $manifestPath -Data $manifest

$currentPinnedMachine = $null
if (-not [string]::IsNullOrWhiteSpace($OfferId)) {
    $currentPinnedMachine = Resolve-OfferMetadata -OfferId $OfferId
}

foreach ($segment in $segmentRecords) {
    if ($segment.index -gt 1) {
        $extractStepName = "extract_continuation_{0:d2}" -f $segment.index
        $continuationFrames = Invoke-Step -Name $extractStepName -Report ([ref]$report) -ReportPath $reportPath -Action {
            $previousSegment = $segmentRecords[$segment.index - 2]
            if (-not $previousSegment.child_result_path) {
                throw "Previous segment result missing for continuation."
            }

            $outputDir = Join-Path $continuationDir ("segment-{0:d2}" -f $segment.index)
            Extract-TailFrames -VideoPath $previousSegment.child_result_path -FrameCount $ContinueMotionFrames -OutputDir $outputDir
        }
        $segment.continuation_frames = @($continuationFrames)
        Write-JsonFile -Path $manifestPath -Data $manifest
    }

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
        if ($RuntimeVersion -eq "1.1-machine-registry" -and $currentPinnedMachine -and $currentPinnedMachine.machine_id) {
            $segmentArgs += "-WarmStart"
        }

        $segmentOfferId = ""
        if ($segment.index -eq 1 -and -not [string]::IsNullOrWhiteSpace($OfferId)) {
            $segmentOfferId = $OfferId
        }
        elseif ($segment.index -gt 1 -and $currentPinnedMachine -and $currentPinnedMachine.machine_id) {
            $currentOffer = Resolve-CurrentOfferForMachine -MachineId $currentPinnedMachine.machine_id
            if ($currentOffer -and $currentOffer.offer_id) {
                $segmentOfferId = $currentOffer.offer_id
            }
            else {
                $report.warnings += "Pinned machine $($currentPinnedMachine.machine_id) had no currently rentable offer for segment $($segment.index); falling back to normal selector."
                Write-JsonFile -Path $reportPath -Data $report
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($segmentOfferId)) {
            $segmentArgs += @("-OfferId", $segmentOfferId)
        }
        else {
            $segmentArgs += @("-RegistryPath", $RegistryPath)
        }

        if (@($segment.continuation_frames).Count -gt 0) {
            $segmentArgs += @("-ContinuationFrameList", (@($segment.continuation_frames) -join "|"))
            $segmentArgs += @("-ContinueMotionMaxFrames", $ContinueMotionFrames.ToString())
            $segmentArgs += @("-VideoFrameOffset", "0")
        }

        $segmentArgs += "-SkipPublish"

        & pwsh @segmentArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Segment runner failed: $($segment.child_job_name)"
        }

        $child = Read-ChildMetadata -ChildJobName $segment.child_job_name
        $segment["child_result_path"] = [string]$child.manifest.result.local_result_path
        $segment["child_prompt_id"] = [string]$child.manifest.result.prompt_id
        $segment["child_job_dir"] = $child.child_dir
        if ($child.instance) {
            $segment["instance_id"] = [string]$child.instance.id
            $segment["machine_id"] = [string]$child.instance.machine_id
            $segment["host_id"] = [string]$child.instance.host_id
            if (-not [string]::IsNullOrWhiteSpace([string]$child.instance.machine_id)) {
                $script:currentPinnedMachine = [pscustomobject]@{
                    machine_id = [string]$child.instance.machine_id
                    host_id = [string]$child.instance.host_id
                    offer_id = $null
                }
            }
        }
        if ($child.timing -and $child.timing.prompt_execution) {
            $segment["prompt_execution"] = [string]$child.timing.prompt_execution
        }
        Write-JsonFile -Path $manifestPath -Data $manifest

        @(
            "child_job=$($segment.child_job_name)",
            "child_result=$($segment.child_result_path)",
            "machine_id=$($segment.machine_id)",
            "prompt_execution=$($segment.prompt_execution)"
        )
    } | Out-Null
}

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
