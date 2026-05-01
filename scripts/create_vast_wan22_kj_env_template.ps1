param(
    [string]$TemplateName = "codex-wan22-kj-comfy-cuda129",

    [string]$Image = "ghcr.io/myjr2015/codex-wan22-kj-comfy:cuda129-py312-kj-v2",

    [int]$DiskGb = 240,

    [string]$SearchParams = "gpu_name=RTX_4090 num_gpus=1 gpu_ram>=24 cuda_max_good>=12.4 disk_space>240 direct_port_count>=4 rented=False geolocation notin [CN,TR]",

    [switch]$PrivateDockerHubLogin,

    [string]$DockerHubUsername = "",

    [string]$DockerHubToken = "",

    [switch]$PrivateRegistryLogin,

    [string]$RegistryHost = "",

    [string]$RegistryUsername = "",

    [string]$RegistryToken = ""
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
if ([string]::IsNullOrWhiteSpace($RegistryHost)) {
    if ($Image -match "^(?<host>[^/]+\.[^/]+)/") {
        $RegistryHost = $Matches.host
    }
    else {
        $RegistryHost = "docker.io"
    }
}
if ([string]::IsNullOrWhiteSpace($RegistryUsername)) {
    if ($RegistryHost -eq "ghcr.io") {
        $RegistryUsername = if ($env:GITHUB_USERNAME) { $env:GITHUB_USERNAME } elseif ($env:GITHUB_ACTOR) { $env:GITHUB_ACTOR } else { "myjr2015" }
    }
    elseif ($RegistryHost -eq "docker.io") {
        $RegistryUsername = $DockerHubUsername
    }
}
if ([string]::IsNullOrWhiteSpace($RegistryToken)) {
    if ($RegistryHost -eq "ghcr.io") {
        $RegistryToken = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } elseif ($env:GH_TOKEN) { $env:GH_TOKEN } else { "" }
    }
    elseif ($RegistryHost -eq "docker.io") {
        $RegistryToken = $DockerHubToken
    }
}

$imageRepo = $Image
$imageTag = "latest"
if ($Image -match "^(?<repo>.+):(?<tag>[^/:]+)$") {
    $imageRepo = $Matches.repo
    $imageTag = $Matches.tag
}

$dockerOptions = @(
    "-e DATA_DIRECTORY=/workspace/"
    "-e JUPYTER_DIR=/"
    "-e OPEN_BUTTON_PORT=8188"
    "-e KJ_ENV_IMAGE=1"
    "-e KJ_CUSTOM_NODE_SEED_DIR=/opt/codex/kj-custom_nodes"
    "-e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/vast-ai/base-image/refs/heads/main/derivatives/pytorch/derivatives/comfyui/provisioning_scripts/default.sh"
    "-p 1111:1111"
    "-p 8080:8080"
    "-p 8188:8188"
    "-p 8384:8384"
) -join " "

$description = "Codex Wan2.2 KJ ComfyUI env image. Includes custom nodes and Python deps, excludes model weights."

$arguments = @(
    "create", "template",
    "--name", $TemplateName,
    "--image", $imageRepo,
    "--image_tag", $imageTag,
    "--env", $dockerOptions,
    "--jupyter",
    "--direct",
    "--jupyter-dir", "/",
    "--disk_space", "$DiskGb",
    "--search_params", $SearchParams,
    "--desc", $description,
    "--hide-readme",
    "--raw"
)

if ($PrivateDockerHubLogin) {
    if ([string]::IsNullOrWhiteSpace($DockerHubUsername) -or [string]::IsNullOrWhiteSpace($DockerHubToken)) {
        throw "PrivateDockerHubLogin requires DockerHub username and token."
    }
    $arguments += @("--login", "-u $DockerHubUsername -p $DockerHubToken docker.io")
}
elseif ($PrivateRegistryLogin) {
    if ([string]::IsNullOrWhiteSpace($RegistryHost) -or [string]::IsNullOrWhiteSpace($RegistryUsername) -or [string]::IsNullOrWhiteSpace($RegistryToken)) {
        throw "PrivateRegistryLogin requires registry host, username, and token."
    }
    $arguments += @("--login", "-u $RegistryUsername -p $RegistryToken $RegistryHost")
}

$previousPythonUtf8 = $env:PYTHONUTF8
$previousPythonIoEncoding = $env:PYTHONIOENCODING
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

function Redact-SecretText {
    param(
        [string]$Text,
        [string[]]$Secrets = @()
    )

    $result = $Text
    foreach ($secret in $Secrets) {
        if ([string]::IsNullOrWhiteSpace($secret)) {
            continue
        }
        $result = $result -replace [regex]::Escape($secret), "<redacted>"
    }
    $result
}

try {
    Write-Host "creating_vast_template=$TemplateName"
    Write-Host "image=$imageRepo`:$imageTag"
    if ($PrivateDockerHubLogin) {
        Write-Host "private_dockerhub_login=true"
    }
    if ($PrivateRegistryLogin) {
        Write-Host "private_registry_login=true"
        Write-Host "registry_host=$RegistryHost"
        Write-Host "registry_username=$RegistryUsername"
    }
    $output = @(& vastai @arguments 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    $secretsToRedact = @($DockerHubToken, $RegistryToken)
    foreach ($line in $output) {
        Write-Host (Redact-SecretText -Text $line -Secrets $secretsToRedact)
    }
    if ($exitCode -ne 0) {
        throw "vastai create template failed with exit code $exitCode"
    }
}
finally {
    if ($null -eq $previousPythonUtf8) {
        Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONUTF8 = $previousPythonUtf8
    }
    if ($null -eq $previousPythonIoEncoding) {
        Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
    }
    else {
        $env:PYTHONIOENCODING = $previousPythonIoEncoding
    }
}
