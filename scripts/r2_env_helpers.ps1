function Resolve-R2AccountId {
    param(
        [string]$CloudflareAccountId = "",
        [string]$AssetAccountId = "",
        [string]$Endpoint = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($CloudflareAccountId)) {
        return $CloudflareAccountId
    }

    if (-not [string]::IsNullOrWhiteSpace($AssetAccountId)) {
        return $AssetAccountId
    }

    if (-not [string]::IsNullOrWhiteSpace($Endpoint)) {
        if ($Endpoint -match '^https?://([a-fA-F0-9]{32})\.r2\.cloudflarestorage\.com/?$') {
            return $Matches[1]
        }
    }

    return ""
}

function Read-ProjectApiBackup {
    param(
        [string]$Path = ".\api.txt"
    )

    $entries = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $entries
    }

    $lines = @(Get-Content -LiteralPath $Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    for ($i = 0; $i + 1 -lt $lines.Count; $i += 2) {
        $site = $lines[$i].Trim()
        $key = $lines[$i + 1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($site) -and -not [string]::IsNullOrWhiteSpace($key)) {
            $entries[$site] = $key
        }
    }

    return $entries
}

function Set-ProcessEnvIfMissing {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if (-not [Environment]::GetEnvironmentVariable($Name, "Process")) {
        [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
    }
}

function Import-ProjectApiBackup {
    param(
        [string]$Path = ".\api.txt"
    )

    $entries = Read-ProjectApiBackup -Path $Path
    if ($entries.Count -eq 0) {
        return
    }

    Set-ProcessEnvIfMissing -Name "RUNCOMFY_API_KEY" -Value $entries["RunComfy"]
    Set-ProcessEnvIfMissing -Name "CLOUDFLARE_API_TOKEN" -Value $entries["Cloudflare API Token"]
    Set-ProcessEnvIfMissing -Name "CLOUDFLARE_ACCOUNT_ID" -Value $entries["Cloudflare Account ID"]
    Set-ProcessEnvIfMissing -Name "ASSET_S3_ACCOUNT_ID" -Value $entries["Cloudflare Account ID"]
    Set-ProcessEnvIfMissing -Name "R2_ACCESS_KEY_ID" -Value $entries["Cloudflare R2 AccessKeyId"]
    Set-ProcessEnvIfMissing -Name "ASSET_S3_ACCESS_KEY_ID" -Value $entries["Cloudflare R2 AccessKeyId"]
    Set-ProcessEnvIfMissing -Name "R2_SECRET_ACCESS_KEY" -Value $entries["Cloudflare R2 SecretAccessKey"]
    Set-ProcessEnvIfMissing -Name "ASSET_S3_SECRET_ACCESS_KEY" -Value $entries["Cloudflare R2 SecretAccessKey"]
    Set-ProcessEnvIfMissing -Name "VAST_API_KEY" -Value $entries["Vast.ai"]
    Set-ProcessEnvIfMissing -Name "GITHUB_TOKEN" -Value $entries["GitHub"]
    Set-ProcessEnvIfMissing -Name "GH_TOKEN" -Value $entries["GitHub"]
    if (-not [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "Process")) {
        Set-ProcessEnvIfMissing -Name "GITHUB_TOKEN" -Value $entries["GitHub PAT 用户给过"]
    }
    if (-not [Environment]::GetEnvironmentVariable("GH_TOKEN", "Process")) {
        Set-ProcessEnvIfMissing -Name "GH_TOKEN" -Value $entries["GitHub PAT 用户给过"]
    }
    Set-ProcessEnvIfMissing -Name "DOCKERHUB_TOKEN" -Value $entries["DockerHub"]
    Set-ProcessEnvIfMissing -Name "DOCKERHUB_USERNAME" -Value $entries["DockerHub Username"]
    Set-ProcessEnvIfMissing -Name "RUNPOD_API_KEY" -Value $entries["RunPod"]
    Set-ProcessEnvIfMissing -Name "OPENAI_API_KEY" -Value $entries["OpenAI"]
}

function Import-ProjectDotEnv {
    param(
        [string]$Path = ".\.env",
        [string]$ApiBackupPath = ""
    )

    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
                continue
            }
            $parts = $trimmed -split "=", 2
            if ($parts.Count -ne 2) {
                continue
            }
            $name = $parts[0].Trim()
            $value = $parts[1].Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            Set-ProcessEnvIfMissing -Name $name -Value $value
        }
    }

    if ([string]::IsNullOrWhiteSpace($ApiBackupPath)) {
        $baseDir = if ([string]::IsNullOrWhiteSpace($Path)) { "." } else { Split-Path -Parent $Path }
        if ([string]::IsNullOrWhiteSpace($baseDir)) {
            $baseDir = "."
        }
        $ApiBackupPath = Join-Path $baseDir "api.txt"
    }

    Import-ProjectApiBackup -Path $ApiBackupPath
}
