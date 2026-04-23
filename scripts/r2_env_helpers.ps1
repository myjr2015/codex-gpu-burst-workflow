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

function Import-ProjectDotEnv {
    param(
        [string]$Path = ".\.env"
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

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
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not [Environment]::GetEnvironmentVariable($name, "Process")) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}
