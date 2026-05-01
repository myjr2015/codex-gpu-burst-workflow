param(
    [string]$GitHubToken = "",

    [string]$Repo = "myjr2015/codex-gpu-burst-workflow",

    [string]$DockerHubUsername = "",

    [string]$DockerHubToken = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (Test-Path -LiteralPath $r2HelperPath) {
    . $r2HelperPath
    Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
}

if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
    $GitHubToken = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } elseif ($env:GH_TOKEN) { $env:GH_TOKEN } else { "" }
}
if ([string]::IsNullOrWhiteSpace($DockerHubToken)) {
    $DockerHubToken = if ($env:DOCKERHUB_TOKEN) { $env:DOCKERHUB_TOKEN } else { "" }
}
if ([string]::IsNullOrWhiteSpace($DockerHubUsername)) {
    $DockerHubUsername = if ($env:DOCKERHUB_USERNAME) { $env:DOCKERHUB_USERNAME } else { "" }
}

if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
    throw "Missing GitHub token. Set GITHUB_TOKEN/GH_TOKEN or add GitHub to api.txt."
}
if ([string]::IsNullOrWhiteSpace($DockerHubToken)) {
    throw "Missing DockerHub token. Set DOCKERHUB_TOKEN or add DockerHub to api.txt."
}
if ([string]::IsNullOrWhiteSpace($DockerHubUsername)) {
    throw "Missing DockerHub username. Set DOCKERHUB_USERNAME or pass -DockerHubUsername."
}

$python = "D:\code\YuYan\python\python.exe"
$script = Join-Path $repoRoot "scripts\set_github_actions_secret.py"

try {
    $env:CODEX_GITHUB_SECRET_TOKEN = $GitHubToken
    $env:CODEX_ACTIONS_SECRET_VALUE = $DockerHubUsername
    & $python $script --token-env CODEX_GITHUB_SECRET_TOKEN --repo $Repo --name DOCKERHUB_USERNAME --value-env CODEX_ACTIONS_SECRET_VALUE
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set DOCKERHUB_USERNAME"
    }

    $env:CODEX_ACTIONS_SECRET_VALUE = $DockerHubToken
    & $python $script --token-env CODEX_GITHUB_SECRET_TOKEN --repo $Repo --name DOCKERHUB_TOKEN --value-env CODEX_ACTIONS_SECRET_VALUE
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set DOCKERHUB_TOKEN"
    }
}
finally {
    Remove-Item Env:CODEX_GITHUB_SECRET_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_ACTIONS_SECRET_VALUE -ErrorAction SilentlyContinue
}

Write-Host "GitHub Actions Docker Hub secrets configured for $Repo"
