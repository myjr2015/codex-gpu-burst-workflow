param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$ImagePath = ".\素材资产\美女图无背景纯色\纯色坐着.png",

    [string]$VideoPath = ".\素材资产\原视频\光伏60s.mp4",

    [string]$BackgroundImagePath = "",

    [int]$BackgroundMaskGrow = 12,

    [string]$Prompt = "固定同一个女性IP，在现代户外光伏发电场景中自然口播介绍产品。画面中只有一个女性主体，保持参考视频中的动作、表情、口型节奏、身体姿态和关键道具关系；背景和道具根据视频反推提示词重绘，不额外强加视频里没有的物体。镜头稳定，人物边缘干净，身份和五官稳定。 one person only, same character, prompt-guided scene and props, no background people.",

    [string]$NegativePrompt = "色调艳丽，过曝，静态，细节模糊不清，字幕，风格，作品，画作，画面，静止，整体发灰，最差质量，低质量，JPEG压缩残留，丑陋的，残缺的，多余的手指，画得不好的手部，画得不好的脸部，畸形的，毁容的，形态畸形的肢体，手指融合，静止不动的画面，杂乱的背景，三条腿，背景人很多，倒着走，第二个人，双人，两个女人，重复人物，重复身体，重复头部，额外身体，额外躯干，背景里的大人物，身后站人，幽灵人影，残影，透明人，双曝光，镜像身体，倒影身体，影子人物，多个人，multiple people, second person, duplicate body, duplicate woman, person behind, background person, ghost, double exposure, extra torso, extra head",

    [Int64]$Seed = 387956277078883,

    [ValidateSet("1.0-cold", "1.1-machine-registry", "1.2-docker-env-template")]
    [string]$RuntimeVersion = "1.1-machine-registry",

    [string]$OfferId,

    [string]$RegistryPath = ".\data\vast-machine-registry.json",

    [string]$SearchQuery = "gpu_name=RTX_4090 num_gpus=1 gpu_ram>=24 cuda_max_good>=12.4 disk_space>240 direct_port_count>=4 rented=False geolocation notin [CN,TR]",

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$VastTemplateHash = $(if ($env:VAST_WAN22_KJ_TEMPLATE_HASH) { $env:VAST_WAN22_KJ_TEMPLATE_HASH } else { "" }),

    [int]$DiskGb = 240,

    [double]$MaxDphTotal = 0.4,

    [int]$MinDriverMajor = 580,

    [int]$OutputWidth = 720,

    [int]$OutputHeight = 1280,

    [int]$SegmentSeconds = 30,

    [int]$MaxSegments = 0,

    [ValidateSet("Off", "Warn", "FailOnHigh")]
    [string]$ReferenceRiskPolicy = "Warn",

    [string]$PythonPath = "D:\code\YuYan\python\python.exe",

    [double]$ReferenceRiskSampleInterval = 0.5,

    [double]$ReferenceRiskThreshold = 3.0,

    [double]$ReferenceRiskHighThreshold = 5.0,

    [int]$ReferenceRiskMaxSheetFrames = 48,

    [switch]$DisableHfSpeedTest,

    [double]$HfMinMiBps = 15,

    [int]$HfMaxEstimatedDownloadMinutes = 30,

    [int]$HfSpeedTestSampleMiB = 256,

    [int]$HfSpeedTestMaxSeconds = 120,

    [ValidateRange(1, 4)]
    [int]$ModelDownloadParallelism = 3,

    [switch]$CancelUnavail,

    [switch]$PrivateRegistryLogin,

    [string]$RegistryHost = "",

    [string]$RegistryUsername = "",

    [switch]$SkipPublish,

    [switch]$PrepareOnly,

    [switch]$KeepInstanceForDebug,

    [int]$DownloadIntervalSeconds = 30,

    [int]$DownloadMaxChecks = 1200
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
$runnerScript = Join-Path $repoRoot "scripts\run_vast_workflow_job.ps1"
$stageScript = Join-Path $repoRoot "scripts\stage_wan22_kj_30s_segmented_job.ps1"

foreach ($required in @($r2HelperPath, $runnerScript, $stageScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}

. $r2HelperPath
Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")

function Invoke-ReferenceRiskPreflight {
    param(
        [string]$Policy,
        [string]$JobName,
        [string]$VideoPath,
        [string]$PythonPath,
        [double]$SampleInterval,
        [double]$RiskThreshold,
        [double]$HighThreshold,
        [int]$MaxSheetFrames,
        [int]$SegmentSeconds
    )

    if ($Policy -eq "Off") {
        Write-Host "reference_risk_policy=Off"
        return
    }

    $analyzerScript = Join-Path $repoRoot "scripts\analyze_reference_overlay_risk.py"
    if (-not (Test-Path -LiteralPath $analyzerScript)) {
        throw "Reference risk analyzer missing: $analyzerScript"
    }
    if (-not (Test-Path -LiteralPath $VideoPath)) {
        throw "Reference video missing for risk preflight: $VideoPath"
    }

    $pythonExe = $PythonPath
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
        if ($pythonCommand) {
            $pythonExe = $pythonCommand.Source
        }
        elseif ($Policy -eq "FailOnHigh") {
            throw "Python not found for required reference risk preflight: $PythonPath"
        }
        else {
            Write-Warning "Python not found, skip reference risk preflight: $PythonPath"
            return
        }
    }

    $riskOutputDir = Join-Path $repoRoot ("output\reference_risk_preflight\" + $JobName)
    New-Item -ItemType Directory -Force -Path $riskOutputDir | Out-Null

    & $pythonExe $analyzerScript `
        --video $VideoPath `
        --output-dir $riskOutputDir `
        --sample-interval $SampleInterval `
        --segment-seconds $SegmentSeconds `
        --risk-threshold $RiskThreshold `
        --high-threshold $HighThreshold `
        --max-sheet-frames $MaxSheetFrames

    if ($LASTEXITCODE -ne 0) {
        throw "Reference risk analyzer failed with exit code $LASTEXITCODE."
    }

    $riskReportPath = Join-Path $riskOutputDir "overlay-risk-report.json"
    if (-not (Test-Path -LiteralPath $riskReportPath)) {
        throw "Reference risk report not generated: $riskReportPath"
    }

    $report = Get-Content -Raw -Path $riskReportPath | ConvertFrom-Json
    $windows = @($report.windows)
    $highWindows = @($windows | Where-Object { $_.level -eq "high" })
    $maxScore = 0.0
    if ($windows.Count -gt 0) {
        $maxScore = [double]($windows | Measure-Object -Property max_score -Maximum).Maximum
    }

    Write-Host "reference_risk_policy=$Policy"
    Write-Host "reference_risk_report=$riskReportPath"
    Write-Host "reference_risk_windows=$($windows.Count)"
    Write-Host "reference_risk_high_windows=$($highWindows.Count)"
    Write-Host ("reference_risk_max_score={0:N3}" -f $maxScore)

    if ($highWindows.Count -gt 0) {
        $summary = "Reference video has $($highWindows.Count) high-risk overlay window(s). Review $riskReportPath before paid inference."
        if ($Policy -eq "FailOnHigh") {
            throw $summary
        }
        Write-Warning $summary
    }
}

Invoke-ReferenceRiskPreflight `
    -Policy $ReferenceRiskPolicy `
    -JobName $JobName `
    -VideoPath $VideoPath `
    -PythonPath $PythonPath `
    -SampleInterval $ReferenceRiskSampleInterval `
    -RiskThreshold $ReferenceRiskThreshold `
    -HighThreshold $ReferenceRiskHighThreshold `
    -MaxSheetFrames $ReferenceRiskMaxSheetFrames `
    -SegmentSeconds $SegmentSeconds

if ($PrepareOnly) {
    $prepareStageArgs = @(
        "-File", $stageScript,
        "-JobName", $JobName,
        "-ImagePath", $ImagePath,
        "-VideoPath", $VideoPath,
        "-BackgroundMaskGrow", "$BackgroundMaskGrow",
        "-Prompt", $Prompt,
        "-NegativePrompt", $NegativePrompt,
        "-Seed", "$Seed",
        "-OutputWidth", "$OutputWidth",
        "-OutputHeight", "$OutputHeight",
        "-SegmentSeconds", "$SegmentSeconds",
        "-MaxSegments", "$MaxSegments"
    )
    if (-not [string]::IsNullOrWhiteSpace($BackgroundImagePath)) {
        $prepareStageArgs += @("-BackgroundImagePath", $BackgroundImagePath)
    }
    & pwsh @prepareStageArgs
    exit $LASTEXITCODE
}

if ($RuntimeVersion -eq "1.2-docker-env-template" -and [string]::IsNullOrWhiteSpace($VastTemplateHash)) {
    throw "RuntimeVersion 1.2-docker-env-template requires -VastTemplateHash or env VAST_WAN22_KJ_TEMPLATE_HASH."
}

$selection = $null
$warmStart = $false

if (-not [string]::IsNullOrWhiteSpace($OfferId)) {
    $selection = [pscustomobject]@{
        offer_id = $OfferId
        machine_id = $null
        host_id = $null
        warm_start = $false
        selection_mode = "manual_offer"
        selection_reason = "OfferId provided"
    }
}
else {
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
    if ($MaxDphTotal -gt 0) {
        $offers = @($offers | Where-Object { [double]$_.dph_total -le $MaxDphTotal })
    }
    if ($MinDriverMajor -gt 0) {
        $offers = @($offers | Where-Object {
            $driverMajor = 0
            if ($_.driver_version -match '^\s*(\d+)') {
                $driverMajor = [int]$Matches[1]
            }
            $driverMajor -ge $MinDriverMajor
        })
    }

    $registry = $null
    if (($RuntimeVersion -eq "1.1-machine-registry" -or $RuntimeVersion -eq "1.2-docker-env-template") -and (Test-Path -LiteralPath $RegistryPath)) {
        $registry = Get-Content -Raw $RegistryPath | ConvertFrom-Json
    }
    $knownMachineIds = @()
    if ($registry -and $registry.machines) {
        $preferredGpuName = ""
        if ($SearchQuery -match 'gpu_name=([^\s]+)') {
            $preferredGpuName = $Matches[1].Replace("_", " ")
        }
        $knownMachineIds = @($registry.machines | Where-Object {
            $_.result -eq "succeeded" -and
            ([string]::IsNullOrWhiteSpace($preferredGpuName) -or $_.gpu_name -eq $preferredGpuName)
        } | ForEach-Object { [string]$_.machine_id })
    }
    $preferred = $offers | Where-Object { $knownMachineIds -contains [string]$_.machine_id } | Sort-Object dph_total | Select-Object -First 1
    $offer = if ($preferred) { $preferred } else { $offers | Sort-Object dph_total | Select-Object -First 1 }
    if (-not $offer) {
        throw "No RTX 4090 Vast offer found under max dph_total $MaxDphTotal and min driver major $MinDriverMajor."
    }
    $selection = [pscustomobject]@{
        offer_id = $offer.id
        machine_id = $offer.machine_id
        host_id = $offer.host_id
        warm_start = [bool]$preferred
        selection_mode = if ($preferred) { "preferred_machine" } else { "cold_start" }
        selection_reason = if ($preferred) { "Matched successful $preferredGpuName machine in registry" } else { "Cheapest matching non-CN/TR $preferredGpuName offer" }
    }
}

$OfferId = [string]$selection.offer_id
$warmStart = [bool]$selection.warm_start

Write-Host "runtime_version=$RuntimeVersion"
Write-Host "selection_mode=$($selection.selection_mode)"
Write-Host "selection_reason=$($selection.selection_reason)"
Write-Host "offer_id=$OfferId"
Write-Host "selected_machine_id=$($selection.machine_id)"
Write-Host "selected_host_id=$($selection.host_id)"
Write-Host "warm_start=$warmStart"

$stageArgs = @(
    "-ImagePath", $ImagePath,
    "-VideoPath", $VideoPath,
    "-BackgroundMaskGrow", "$BackgroundMaskGrow",
    "-Prompt", $Prompt,
    "-NegativePrompt", $NegativePrompt,
    "-Seed", "$Seed",
    "-OutputWidth", "$OutputWidth",
    "-OutputHeight", "$OutputHeight",
    "-SegmentSeconds", "$SegmentSeconds",
    "-MaxSegments", "$MaxSegments",
    "-UploadToR2"
)
if (-not [string]::IsNullOrWhiteSpace($BackgroundImagePath)) {
    $stageArgs += @("-BackgroundImagePath", $BackgroundImagePath)
}

$launchArgs = @(
    "-OfferId", $OfferId,
    "-Image", $Image,
    "-DiskGb", "$DiskGb",
    "-ModelDownloadParallelism", "$ModelDownloadParallelism"
)
if (-not [string]::IsNullOrWhiteSpace($VastTemplateHash)) {
    $launchArgs += @("-TemplateHash", $VastTemplateHash)
}
if ($PrivateRegistryLogin) {
    $launchArgs += "-PrivateRegistryLogin"
    if (-not [string]::IsNullOrWhiteSpace($RegistryHost)) {
        $launchArgs += @("-RegistryHost", $RegistryHost)
    }
    if (-not [string]::IsNullOrWhiteSpace($RegistryUsername)) {
        $launchArgs += @("-RegistryUsername", $RegistryUsername)
    }
}
if ($CancelUnavail) {
    $launchArgs += "-CancelUnavail"
}
if ($warmStart) {
    $launchArgs += "-WarmStart"
}
if ($DisableHfSpeedTest) {
    $launchArgs += "-DisableHfSpeedTest"
}
else {
    $launchArgs += @(
        "-HfMinMiBps", "$HfMinMiBps",
        "-HfMaxEstimatedDownloadMinutes", "$HfMaxEstimatedDownloadMinutes",
        "-HfSpeedTestSampleMiB", "$HfSpeedTestSampleMiB",
        "-HfSpeedTestMaxSeconds", "$HfSpeedTestMaxSeconds"
    )
}

if ($SkipPublish -and -not $KeepInstanceForDebug) {
    & $runnerScript `
        -Profile "wan22_kj_30s_segmented" `
        -JobName $JobName `
        -StageArgs $stageArgs `
        -LaunchArgs $launchArgs `
        -DownloadIntervalSeconds $DownloadIntervalSeconds `
        -DownloadMaxChecks $DownloadMaxChecks `
        -MachineRegistryPath $RegistryPath `
        -SkipPublish `
        -DestroyInstance
}
elseif ($SkipPublish) {
    & $runnerScript `
        -Profile "wan22_kj_30s_segmented" `
        -JobName $JobName `
        -StageArgs $stageArgs `
        -LaunchArgs $launchArgs `
        -DownloadIntervalSeconds $DownloadIntervalSeconds `
        -DownloadMaxChecks $DownloadMaxChecks `
        -MachineRegistryPath $RegistryPath `
        -SkipPublish
}
elseif (-not $KeepInstanceForDebug) {
    & $runnerScript `
        -Profile "wan22_kj_30s_segmented" `
        -JobName $JobName `
        -StageArgs $stageArgs `
        -LaunchArgs $launchArgs `
        -DownloadIntervalSeconds $DownloadIntervalSeconds `
        -DownloadMaxChecks $DownloadMaxChecks `
        -MachineRegistryPath $RegistryPath `
        -DestroyInstance
}
else {
    & $runnerScript `
        -Profile "wan22_kj_30s_segmented" `
        -JobName $JobName `
        -StageArgs $stageArgs `
        -LaunchArgs $launchArgs `
        -DownloadIntervalSeconds $DownloadIntervalSeconds `
        -DownloadMaxChecks $DownloadMaxChecks `
        -MachineRegistryPath $RegistryPath
}
exit $LASTEXITCODE
