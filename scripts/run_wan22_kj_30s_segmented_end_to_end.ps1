param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$ImagePath = ".\素材资产\美女图无背景纯色\纯色坐着.png",

    [string]$VideoPath = ".\素材资产\原视频\光伏60s.mp4",

    [string]$Prompt = "固定同一个女性IP，在现代户外光伏发电场景中自然口播介绍产品。画面中只有一个女性主体，全程坐在同一把椅子上，椅子形态和人物比例保持一致，保持参考视频中的动作、表情、口型节奏和坐姿身体姿态。背景根据提示词重绘为真实光伏板场景，背景里不要人物，镜头固定，人物边缘干净，身份和五官稳定。 single seated woman, one person only, same chair, no background people.",

    [string]$NegativePrompt = "色调艳丽，过曝，静态，细节模糊不清，字幕，风格，作品，画作，画面，静止，整体发灰，最差质量，低质量，JPEG压缩残留，丑陋的，残缺的，多余的手指，画得不好的手部，画得不好的脸部，畸形的，毁容的，形态畸形的肢体，手指融合，静止不动的画面，杂乱的背景，三条腿，背景人很多，倒着走，第二个人，双人，两个女人，重复人物，重复身体，重复头部，额外身体，额外躯干，站立人物，站着的女人，背景里的大人物，身后站人，幽灵人影，残影，透明人，双曝光，镜像身体，倒影身体，影子人物，多个人，多把椅子，椅子消失，椅子变形，multiple people, second person, duplicate body, duplicate woman, standing woman, person behind, background person, ghost, double exposure, extra torso, extra head, extra chair, missing chair",

    [Int64]$Seed = 387956277078883,

    [ValidateSet("1.0-cold", "1.1-machine-registry")]
    [string]$RuntimeVersion = "1.1-machine-registry",

    [string]$OfferId,

    [string]$RegistryPath = ".\data\vast-machine-registry.json",

    [string]$SearchQuery = "gpu_name=RTX_4090 num_gpus=1 gpu_ram>=24 cuda_max_good>=12.4 disk_space>240 direct_port_count>=4 rented=False geolocation notin [CN,TR]",

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [int]$DiskGb = 240,

    [double]$MaxDphTotal = 0.4,

    [int]$MinDriverMajor = 580,

    [int]$SegmentSeconds = 30,

    [int]$MaxSegments = 0,

    [switch]$DisableHfSpeedTest,

    [double]$HfMinMiBps = 15,

    [int]$HfMaxEstimatedDownloadMinutes = 30,

    [int]$HfSpeedTestSampleMiB = 256,

    [int]$HfSpeedTestMaxSeconds = 120,

    [switch]$CancelUnavail,

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

if ($PrepareOnly) {
    & pwsh -File $stageScript `
        -JobName $JobName `
        -ImagePath $ImagePath `
        -VideoPath $VideoPath `
        -Prompt $Prompt `
        -NegativePrompt $NegativePrompt `
        -Seed $Seed `
        -SegmentSeconds $SegmentSeconds `
        -MaxSegments $MaxSegments
    exit $LASTEXITCODE
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
    if ($RuntimeVersion -eq "1.1-machine-registry" -and (Test-Path -LiteralPath $RegistryPath)) {
        $registry = Get-Content -Raw $RegistryPath | ConvertFrom-Json
    }
    $knownMachineIds = @()
    if ($registry -and $registry.machines) {
        $knownMachineIds = @($registry.machines | Where-Object { $_.result -eq "succeeded" -and $_.gpu_name -eq "RTX 4090" } | ForEach-Object { [string]$_.machine_id })
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
        selection_reason = if ($preferred) { "Matched successful RTX 4090 machine in registry" } else { "Cheapest matching non-CN/TR RTX 4090 offer" }
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
    "-Prompt", $Prompt,
    "-NegativePrompt", $NegativePrompt,
    "-Seed", "$Seed",
    "-SegmentSeconds", "$SegmentSeconds",
    "-MaxSegments", "$MaxSegments",
    "-UploadToR2"
)

$launchArgs = @(
    "-OfferId", $OfferId,
    "-Image", $Image,
    "-DiskGb", "$DiskGb"
)
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
