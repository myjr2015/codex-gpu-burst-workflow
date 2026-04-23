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
