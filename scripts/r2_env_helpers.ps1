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

    $lines = @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    for ($i = 0; $i -lt $lines.Count) {
        $site = $lines[$i].Trim()
        if ([string]::IsNullOrWhiteSpace($site)) {
            $i += 1
            continue
        }

        if ($site -eq "Cloudflare") {
            $next = if ($i + 1 -lt $lines.Count) { $lines[$i + 1].Trim() } else { "" }
            if (-not [string]::IsNullOrWhiteSpace($next)) {
                $entries["Cloudflare"] = $next
                $entries["Cloudflare API Token"] = $next
            }
            $i += 2
            continue
        }

        if ($site -eq "Cloudflare_R2") {
            $accessKeyId = if ($i + 1 -lt $lines.Count) { $lines[$i + 1].Trim() } else { "" }
            $secretAccessKey = if ($i + 2 -lt $lines.Count) { $lines[$i + 2].Trim() } else { "" }
            if (-not [string]::IsNullOrWhiteSpace($accessKeyId)) {
                $entries["Cloudflare_R2 AccessKeyId"] = $accessKeyId
                $entries["Cloudflare R2 AccessKeyId"] = $accessKeyId
            }
            if (-not [string]::IsNullOrWhiteSpace($secretAccessKey)) {
                $entries["Cloudflare_R2 SecretAccessKey"] = $secretAccessKey
                $entries["Cloudflare R2 SecretAccessKey"] = $secretAccessKey
            }
            $i += if ([string]::IsNullOrWhiteSpace($secretAccessKey)) { 2 } else { 3 }
            continue
        }

        if ($site -eq "DockerHub") {
            $next = if ($i + 1 -lt $lines.Count) { $lines[$i + 1].Trim() } else { "" }
            $next2 = if ($i + 2 -lt $lines.Count) { $lines[$i + 2].Trim() } else { "" }
            if ($next -match '^(用户名|账号|账户|username|user)\s*[:：]\s*(?<username>.+)$') {
                $entries["DockerHub Username"] = $Matches.username.Trim()
                if ($i + 2 -lt $lines.Count) {
                    $entries["DockerHub"] = $next2
                    $i += 3
                }
                else {
                    $i += 2
                }
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($next) -and $next -notmatch '^dckr_pat_' -and $next2 -match '^dckr_pat_') {
                $entries["DockerHub Username"] = $next
                $entries["DockerHub"] = $next2
                $i += 3
                continue
            }
        }

        if ($site -match '^DockerHub\s+(Username|User|用户名|账号|账户)\s*[:：]\s*(?<username>.+)$') {
            $entries["DockerHub Username"] = $Matches.username.Trim()
            $i += 1
            continue
        }

        if ($site -match '^DockerHub\s+(Token|PAT|密钥|令牌)\s*[:：]\s*(?<token>.+)$') {
            $entries["DockerHub"] = $Matches.token.Trim()
            $i += 1
            continue
        }

        if ($i + 1 -ge $lines.Count) {
            $i += 1
            continue
        }

        $key = $lines[$i + 1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($site) -and -not [string]::IsNullOrWhiteSpace($key)) {
            $entries[$site] = $key
        }

        $i += 2
    }

    return $entries
}

function Set-ProcessEnvIfMissing {
    param(
        [string]$Name,
        [string]$Value,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if ($Force -or -not [Environment]::GetEnvironmentVariable($Name, "Process")) {
        [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
    }
}

function Get-ProjectApiBackupEntry {
    param(
        [hashtable]$Entries,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Entries.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace($Entries[$name])) {
            return $Entries[$name]
        }
    }

    return ""
}

function Import-ProjectApiBackup {
    param(
        [string]$Path = ".\api.txt"
    )

    $entries = Read-ProjectApiBackup -Path $Path
    if ($entries.Count -eq 0) {
        return
    }

    $cloudflareApiToken = Get-ProjectApiBackupEntry -Entries $entries -Names @("Cloudflare API Token", "Cloudflare")
    $cloudflareAccountId = Get-ProjectApiBackupEntry -Entries $entries -Names @("Cloudflare Account ID")
    $r2AccessKeyId = Get-ProjectApiBackupEntry -Entries $entries -Names @("Cloudflare R2 AccessKeyId", "Cloudflare_R2 AccessKeyId", "Cloudflare_R2")
    $r2SecretAccessKey = Get-ProjectApiBackupEntry -Entries $entries -Names @("Cloudflare R2 SecretAccessKey", "Cloudflare_R2 SecretAccessKey")

    Set-ProcessEnvIfMissing -Name "RUNCOMFY_API_KEY" -Value $entries["RunComfy"]
    Set-ProcessEnvIfMissing -Name "CLOUDFLARE_API_TOKEN" -Value $cloudflareApiToken
    Set-ProcessEnvIfMissing -Name "CLOUDFLARE_ACCOUNT_ID" -Value $cloudflareAccountId -Force
    Set-ProcessEnvIfMissing -Name "ASSET_S3_ACCOUNT_ID" -Value $cloudflareAccountId -Force
    Set-ProcessEnvIfMissing -Name "R2_ACCESS_KEY_ID" -Value $r2AccessKeyId -Force
    Set-ProcessEnvIfMissing -Name "ASSET_S3_ACCESS_KEY_ID" -Value $r2AccessKeyId -Force
    Set-ProcessEnvIfMissing -Name "R2_SECRET_ACCESS_KEY" -Value $r2SecretAccessKey -Force
    Set-ProcessEnvIfMissing -Name "ASSET_S3_SECRET_ACCESS_KEY" -Value $r2SecretAccessKey -Force
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
