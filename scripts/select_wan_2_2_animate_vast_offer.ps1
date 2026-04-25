param(
    [string]$RegistryPath = ".\data\vast-machine-registry.json",

    [string]$SearchQuery = "gpu_name=RTX_3090 num_gpus=1 gpu_ram>=24 cuda_max_good>=12.4 disk_space>180 direct_port_count>=4 rented=False geolocation notin [CN]",

    [int]$Storage = 180,

    [switch]$ExcludeKnownMachines
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (Test-Path -LiteralPath $r2HelperPath) {
    . $r2HelperPath
    Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
}
$registryResolved = Join-Path $repoRoot $RegistryPath
$selectorPy = Join-Path $repoRoot "scripts\vast_machine_registry.py"
$tempOffersPath = Join-Path ([System.IO.Path]::GetTempPath()) ("vast-offers-{0}.json" -f ([guid]::NewGuid().ToString("N")))

try {
    $env:PYTHONIOENCODING = "utf-8"
    $rawOffers = & vastai search offers $SearchQuery --storage $Storage --raw
    if ($LASTEXITCODE -ne 0) {
        throw "vastai search offers failed."
    }

    $rawOffers | Set-Content -LiteralPath $tempOffersPath -Encoding UTF8

    $selectorArgs = @(
        $selectorPy,
        "choose-offer",
        "--registry-path", $registryResolved,
        "--offers-path", $tempOffersPath
    )
    if ($ExcludeKnownMachines) {
        $selectorArgs += "--exclude-known"
    }

    $decisionJson = & D:\code\YuYan\python\python.exe @selectorArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Machine registry selector failed."
    }

    $decision = $decisionJson | ConvertFrom-Json
    [pscustomobject]@{
        offer_id = $decision.offer_id
        machine_id = $decision.machine_id
        host_id = $decision.host_id
        warm_start = [bool]$decision.warm_start
        selection_mode = $decision.selection_mode
        selection_reason = $decision.selection_reason
    } | ConvertTo-Json -Depth 5
}
finally {
    Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempOffersPath) {
        Remove-Item -LiteralPath $tempOffersPath -Force
    }
}
