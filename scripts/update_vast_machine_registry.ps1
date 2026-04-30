param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$Profile = "wan_2_2_animate",

    [string]$ProfileConfigPath = ".\config\vast-workflow-profiles.json",

    [string]$RegistryPath = ".\data\vast-machine-registry.json",

    [string]$LocalCodexHome = "$env:USERPROFILE\.codex"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$resolvedProfileConfig = (Resolve-Path -LiteralPath $ProfileConfigPath).Path
$profileConfig = Get-Content -Raw $resolvedProfileConfig | ConvertFrom-Json -AsHashtable
if (-not $profileConfig.profiles.ContainsKey($Profile)) {
    throw "Unknown profile '$Profile' in $resolvedProfileConfig"
}
$profileDef = $profileConfig.profiles[$Profile]
$jobDir = Join-Path (Join-Path $repoRoot $profileDef.job_root) $JobName
$registryResolved = Join-Path $repoRoot $RegistryPath
$scriptPath = Join-Path $repoRoot "scripts\vast_machine_registry.py"
$instancePath = Join-Path $jobDir "vast-instance.json"
$timingPath = Join-Path $jobDir "timing-summary.json"
$runReportPath = Join-Path $jobDir "run-report.json"

foreach ($required in @($scriptPath, $instancePath, $timingPath, $runReportPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required path: $required"
    }
}

$logPath = Get-ChildItem -LiteralPath $jobDir -Filter "vast-*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1

$args = @(
    $scriptPath,
    "record-run",
    "--registry-path", $registryResolved,
    "--instance-path", $instancePath,
    "--timing-path", $timingPath,
    "--run-report-path", $runReportPath,
    "--result", "succeeded"
)
if ($logPath) {
    $args += @("--log-path", $logPath.FullName)
}

$env:PYTHONIOENCODING = "utf-8"
$recordJson = & D:\code\YuYan\python\python.exe @args
if ($LASTEXITCODE -ne 0) {
    throw "Failed to update Vast machine registry."
}
Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue

$localRegistryDir = Join-Path $LocalCodexHome "references\wan22"
$localRegistryPath = Join-Path $localRegistryDir "machine-registry.json"
New-Item -ItemType Directory -Force -Path $localRegistryDir | Out-Null
Copy-Item -LiteralPath $registryResolved -Destination $localRegistryPath -Force

Write-Host "registry=$registryResolved"
Write-Host "local_registry=$localRegistryPath"
$recordJson
