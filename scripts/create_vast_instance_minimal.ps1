param(
    [Parameter(Mandatory = $true)]
    [string]$OfferId,

    [string]$Image = "vastai/comfy:v0.19.3-cuda-12.9-py312",

    [string]$TemplateHash = "",

    [string]$Label = "codex-comfy-minimal",

    [int]$DiskGb = 180,

    [switch]$CancelUnavail,

    [string]$Onstart,

    [string[]]$ExtraEnv = @(),

    [string[]]$MountArgs = @(),

    [switch]$TemplateProvidesStaticEnv,

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
        $RegistryUsername = if ($env:DOCKERHUB_USERNAME) { $env:DOCKERHUB_USERNAME } else { "" }
    }
}
if ([string]::IsNullOrWhiteSpace($RegistryToken)) {
    if ($RegistryHost -eq "ghcr.io") {
        $RegistryToken = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } elseif ($env:GH_TOKEN) { $env:GH_TOKEN } else { "" }
    }
    elseif ($RegistryHost -eq "docker.io") {
        $RegistryToken = if ($env:DOCKERHUB_TOKEN) { $env:DOCKERHUB_TOKEN } else { "" }
    }
}

$useTemplate = -not [string]::IsNullOrWhiteSpace($TemplateHash)
$envItems = @()
if (-not $useTemplate -or -not $TemplateProvidesStaticEnv) {
    $envItems += @(
        "DATA_DIRECTORY=/workspace/"
        "JUPYTER_DIR=/"
        "OPEN_BUTTON_PORT=8188"
    )
    $envItems += "PROVISIONING_SCRIPT=https://raw.githubusercontent.com/vast-ai/base-image/refs/heads/main/derivatives/pytorch/derivatives/comfyui/provisioning_scripts/default.sh"
}
if ($ExtraEnv.Count -gt 0) {
    foreach ($item in $ExtraEnv) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }
        foreach ($part in ($item -split ",")) {
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                $envItems += $part.Trim()
            }
        }
    }
}

$envParts = @($envItems | ForEach-Object { "-e $_" })
if ($MountArgs.Count -gt 0) {
    foreach ($item in $MountArgs) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }
        foreach ($part in ($item -split ",")) {
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                $envParts += $part.Trim()
            }
        }
    }
}
if (-not $useTemplate -or -not $TemplateProvidesStaticEnv) {
    $envParts += @(
        "-p 1111:1111"
        "-p 8080:8080"
        "-p 8188:8188"
        "-p 8384:8384"
    )
}
$envString = $envParts -join " "

$arguments = @(
    "create", "instance", $OfferId
)

if ($useTemplate) {
    $arguments += @("--template_hash", $TemplateHash)
}
else {
    $arguments += @("--image", $Image)
}

$arguments += @(
    "--disk", $DiskGb.ToString(),
    "--label", $Label,
    "--jupyter",
    "--direct"
)
if (-not [string]::IsNullOrWhiteSpace($envString)) {
    $arguments += @("--env", $envString)
}
$arguments += "--raw"

if ($CancelUnavail) {
    $arguments += "--cancel-unavail"
}

if ($Onstart) {
    $resolvedOnstart = (Resolve-Path -LiteralPath $Onstart).Path
    $arguments += @("--onstart", $resolvedOnstart)
}
if ($PrivateRegistryLogin) {
    if ([string]::IsNullOrWhiteSpace($RegistryHost) -or [string]::IsNullOrWhiteSpace($RegistryUsername) -or [string]::IsNullOrWhiteSpace($RegistryToken)) {
        throw "PrivateRegistryLogin requires registry host, username, and token."
    }
    $arguments += @("--login", "-u $RegistryUsername -p $RegistryToken $RegistryHost")
}

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

Write-Host "Creating Vast instance with minimal environment..."
Write-Host (Redact-SecretText -Text ("vastai " + ($arguments -join " ")) -Secrets @($RegistryToken))
$previousPythonUtf8 = $env:PYTHONUTF8
$previousPythonIoEncoding = $env:PYTHONIOENCODING
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

try {
    $output = @(& vastai @arguments 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        Write-Host (Redact-SecretText -Text $line -Secrets @($RegistryToken))
    }
    if ($exitCode -ne 0) {
        throw "vastai create instance failed with exit code $exitCode"
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
