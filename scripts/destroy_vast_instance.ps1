param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceId
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (Test-Path -LiteralPath $r2HelperPath) {
    . $r2HelperPath
    Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
}

vastai destroy instance $InstanceId --yes --raw
