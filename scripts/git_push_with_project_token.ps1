param(
    [string[]]$GitArgs = @("push")
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (-not (Test-Path -LiteralPath $r2HelperPath)) {
    throw "Missing environment helper: $r2HelperPath"
}

. $r2HelperPath
Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")

$token = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $env:GITHUB_TOKEN
} elseif (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    $env:GH_TOKEN
} else {
    ""
}

if ([string]::IsNullOrWhiteSpace($token)) {
    throw "GitHub token missing. Add a GitHub entry to .env or api.txt."
}

$askPass = Join-Path $env:TEMP ("git-askpass-" + [guid]::NewGuid().ToString("N") + ".cmd")
@'
@echo off
echo %~1 | findstr /I "Username" >nul
if not errorlevel 1 (
  echo x-access-token
) else (
  echo %GIT_ASKPASS_TOKEN%
)
'@ | Set-Content -LiteralPath $askPass -Encoding ASCII

$previousAskPass = $env:GIT_ASKPASS
$previousTerminalPrompt = $env:GIT_TERMINAL_PROMPT
$previousAskPassToken = $env:GIT_ASKPASS_TOKEN
$env:GIT_ASKPASS = $askPass
$env:GIT_TERMINAL_PROMPT = "0"
$env:GIT_ASKPASS_TOKEN = $token

try {
    git -c credential.helper= @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}
finally {
    if ($null -eq $previousAskPass) {
        Remove-Item Env:GIT_ASKPASS -ErrorAction SilentlyContinue
    } else {
        $env:GIT_ASKPASS = $previousAskPass
    }

    if ($null -eq $previousTerminalPrompt) {
        Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
    } else {
        $env:GIT_TERMINAL_PROMPT = $previousTerminalPrompt
    }

    if ($null -eq $previousAskPassToken) {
        Remove-Item Env:GIT_ASKPASS_TOKEN -ErrorAction SilentlyContinue
    } else {
        $env:GIT_ASKPASS_TOKEN = $previousAskPassToken
    }

    Remove-Item -LiteralPath $askPass -Force -ErrorAction SilentlyContinue
}
