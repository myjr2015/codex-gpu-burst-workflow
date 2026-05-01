param(
    [string]$DockerHubUsername = "",

    [string]$DockerHubToken = "",

    [string]$ImageName = "codex-wan22-kj-comfy",

    [string]$Tag = "cuda129-py312-kj-v1",

    [string]$Dockerfile = ".\docker\wan22-kj-comfy-env\Dockerfile",

    [string]$Context = ".\docker\wan22-kj-comfy-env",

    [string]$Platform = "linux/amd64",

    [switch]$Push,

    [switch]$Load,

    [switch]$NoCache
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (Test-Path -LiteralPath $r2HelperPath) {
    . $r2HelperPath
    Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
}

if ([string]::IsNullOrWhiteSpace($DockerHubUsername)) {
    $DockerHubUsername = if ($env:DOCKERHUB_USERNAME) { $env:DOCKERHUB_USERNAME } else { "myjr2015" }
}
if ([string]::IsNullOrWhiteSpace($DockerHubToken)) {
    $DockerHubToken = if ($env:DOCKERHUB_TOKEN) { $env:DOCKERHUB_TOKEN } else { "" }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker command not found. Use GitHub Actions workflow .github/workflows/build-wan22-kj-env-image.yml or install Docker locally."
}
if (-not (Test-Path -LiteralPath $Dockerfile)) {
    throw "Missing Dockerfile: $Dockerfile"
}
if (-not (Test-Path -LiteralPath $Context)) {
    throw "Missing build context: $Context"
}
if ($Push -and [string]::IsNullOrWhiteSpace($DockerHubToken)) {
    throw "DockerHub token missing. Set DOCKERHUB_TOKEN or add DockerHub to api.txt."
}

$imageRef = "$DockerHubUsername/$ImageName`:$Tag"

if ($Push) {
    $DockerHubToken | docker login --username $DockerHubUsername --password-stdin
    if ($LASTEXITCODE -ne 0) {
        throw "docker login failed."
    }
}

$buildArgs = @(
    "buildx", "build",
    "--platform", $Platform,
    "-f", (Resolve-Path -LiteralPath $Dockerfile).Path,
    "-t", $imageRef
)
if ($NoCache) {
    $buildArgs += "--no-cache"
}
if ($Push) {
    $buildArgs += "--push"
}
elseif ($Load) {
    $buildArgs += "--load"
}
$buildArgs += (Resolve-Path -LiteralPath $Context).Path

Write-Host "docker image=$imageRef"
Write-Host ("docker " + ($buildArgs -join " "))
& docker @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw "docker build failed."
}

Write-Host "image_ref=$imageRef"
