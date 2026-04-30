param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$ImagePath = ".\素材资产\美女图无背景纯色\纯色站着.png",

    [string]$VideoPath = ".\素材资产\原视频\光伏30s.mp4",

    [string]$Prompt = "女孩在现代光伏发电场景中自然口播介绍产品，固定人物身份和五官，保持参考视频中的动作、表情、口型节奏和身体姿态。背景根据提示词重绘为真实户外光伏板场景，画面稳定，人物边缘干净，真实自然。",

    [ValidateSet("1.0-cold", "1.1-machine-registry")]
    [string]$RuntimeVersion = "1.1-machine-registry",

    [string]$OfferId,

    [string]$RegistryPath = ".\data\vast-machine-registry.json",

    [string]$SearchQuery = "gpu_name=RTX_3090 num_gpus=1 gpu_ram>=24 cuda_max_good>=12.4 disk_space>240 direct_port_count>=4 rented=False geolocation notin [CN,TR]",

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [int]$DiskGb = 240,

    [double]$MaxDphTotal = 0.215,

    [int]$MinDriverMajor = 580,

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

    [int]$DownloadMaxChecks = 600
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
$selectorScript = Join-Path $repoRoot "scripts\select_wan_2_2_animate_vast_offer.ps1"
$runnerScript = Join-Path $repoRoot "scripts\run_vast_workflow_job.ps1"
$stageScript = Join-Path $repoRoot "scripts\stage_wan22_kj_30s_job.ps1"

foreach ($required in @($r2HelperPath, $selectorScript, $runnerScript, $stageScript)) {
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
        -Prompt $Prompt
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
elseif ($RuntimeVersion -eq "1.1-machine-registry") {
    $selection = & pwsh -File $selectorScript `
        -RegistryPath $RegistryPath `
        -SearchQuery $SearchQuery `
        -Storage $DiskGb `
        -MaxDphTotal $MaxDphTotal `
        -MinDriverMajor $MinDriverMajor | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "Offer selector failed."
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
    $offer = $offers | Sort-Object dph_total | Select-Object -First 1
    if (-not $offer) {
        throw "No Vast offer found under max dph_total $MaxDphTotal and min driver major $MinDriverMajor."
    }
    $selection = [pscustomobject]@{
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
        -Profile "wan22_kj_30s" `
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
        -Profile "wan22_kj_30s" `
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
        -Profile "wan22_kj_30s" `
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
        -Profile "wan22_kj_30s" `
        -JobName $JobName `
        -StageArgs $stageArgs `
        -LaunchArgs $launchArgs `
        -DownloadIntervalSeconds $DownloadIntervalSeconds `
        -DownloadMaxChecks $DownloadMaxChecks `
        -MachineRegistryPath $RegistryPath
}
exit $LASTEXITCODE
