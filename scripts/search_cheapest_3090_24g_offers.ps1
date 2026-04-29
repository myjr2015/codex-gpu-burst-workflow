param(
    [int]$Top = 10,

    [int]$Storage = 0,

    [switch]$ExcludeCN,

    [switch]$ExcludeRiskyGeos,

    [double]$MinCuda = 0,

    [int]$MinDirectPorts = 0,

    [switch]$RawJson
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (Test-Path -LiteralPath $r2HelperPath) {
    . $r2HelperPath
    Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
}

$queryParts = @(
    "gpu_name=RTX_3090"
    "num_gpus=1"
    "gpu_ram>=24"
    "rented=False"
)

if ($ExcludeCN -or $ExcludeRiskyGeos) {
    $queryParts += "geolocation notin [CN,TR]"
}

if ($MinCuda -gt 0) {
    $queryParts += "cuda_max_good>=$MinCuda"
}

if ($MinDirectPorts -gt 0) {
    $queryParts += "direct_port_count>=$MinDirectPorts"
}

$query = $queryParts -join " "
$arguments = @("search", "offers", $query)
if ($Storage -gt 0) {
    $arguments += @("--storage", $Storage.ToString())
}
$arguments += @("-o", "dph_total", "--raw")

$env:PYTHONIOENCODING = "utf-8"
try {
    $raw = & vastai @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "vastai search offers failed."
    }
}
finally {
    Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
}

$offers = @($raw | ConvertFrom-Json)
$sorted = $offers | Sort-Object dph_total, reliability2 -Descending:$false | Select-Object -First $Top

if ($RawJson) {
    $sorted | ConvertTo-Json -Depth 8
    return
}

$sorted |
    Select-Object `
        @{ Name = "offer_id"; Expression = { $_.id } },
        machine_id,
        host_id,
        gpu_name,
        gpu_ram,
        dph_total,
        driver_version,
        cuda_max_good,
        direct_port_count,
        disk_space,
        geolocation,
        reliability2,
        verification |
    Format-Table -AutoSize
