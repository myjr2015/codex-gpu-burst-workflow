param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubToken,

    [string]$Repo = "myjr2015/codex-gpu-burst-workflow",

    [Parameter(Mandatory = $true)]
    [string]$DockerHubUsername,

    [Parameter(Mandatory = $true)]
    [string]$DockerHubToken
)

$ErrorActionPreference = "Stop"

$python = "D:\code\YuYan\python\python.exe"
$script = Join-Path (Resolve-Path ".").Path "scripts\set_github_actions_secret.py"

& $python $script --token $GitHubToken --repo $Repo --name DOCKERHUB_USERNAME --value $DockerHubUsername
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set DOCKERHUB_USERNAME"
}

& $python $script --token $GitHubToken --repo $Repo --name DOCKERHUB_TOKEN --value $DockerHubToken
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set DOCKERHUB_TOKEN"
}

Write-Host "GitHub Actions Docker Hub secrets configured for $Repo"
