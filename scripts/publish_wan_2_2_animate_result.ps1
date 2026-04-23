param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$ResultPath,

    [string]$R2Prefix = $(if ($env:ASSET_S3_PREFIX) { $env:ASSET_S3_PREFIX.TrimEnd('/') + "/wan_2_2_animate" } elseif ($env:R2_PREFIX) { $env:R2_PREFIX } else { "runcomfy-inputs/wan_2_2_animate" }),

    [string]$R2Bucket = $(if ($env:ASSET_S3_BUCKET) { $env:ASSET_S3_BUCKET } elseif ($env:R2_BUCKET) { $env:R2_BUCKET } else { "runcomfy" }),

    [string]$R2PublicBaseUrl = $(if ($env:ASSET_S3_PUBLIC_BASE_URL) { $env:ASSET_S3_PUBLIC_BASE_URL } elseif ($env:R2_PUBLIC_BASE_URL) { $env:R2_PUBLIC_BASE_URL } else { "https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev" }),

    [string]$R2AccountId = $(if ($env:CLOUDFLARE_ACCOUNT_ID) { $env:CLOUDFLARE_ACCOUNT_ID } elseif ($env:ASSET_S3_ACCOUNT_ID) { $env:ASSET_S3_ACCOUNT_ID } else { "" }),

    [string]$R2AccessKeyId = $(if ($env:R2_ACCESS_KEY_ID) { $env:R2_ACCESS_KEY_ID } elseif ($env:ASSET_S3_ACCESS_KEY_ID) { $env:ASSET_S3_ACCESS_KEY_ID } else { "" }),

    [string]$R2SecretAccessKey = $(if ($env:R2_SECRET_ACCESS_KEY) { $env:R2_SECRET_ACCESS_KEY } elseif ($env:ASSET_S3_SECRET_ACCESS_KEY) { $env:ASSET_S3_SECRET_ACCESS_KEY } else { "" })
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (-not (Test-Path -LiteralPath $r2HelperPath)) {
    throw "Missing R2 helper: $r2HelperPath"
}

. $r2HelperPath
Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
if ([string]::IsNullOrWhiteSpace($R2AccessKeyId) -and $env:ASSET_S3_ACCESS_KEY_ID) {
    $R2AccessKeyId = $env:ASSET_S3_ACCESS_KEY_ID
}
if ([string]::IsNullOrWhiteSpace($R2SecretAccessKey) -and $env:ASSET_S3_SECRET_ACCESS_KEY) {
    $R2SecretAccessKey = $env:ASSET_S3_SECRET_ACCESS_KEY
}
$R2AccountId = Resolve-R2AccountId -CloudflareAccountId $R2AccountId -AssetAccountId $env:ASSET_S3_ACCOUNT_ID -Endpoint $env:ASSET_S3_ENDPOINT

$uploadScript = Join-Path $repoRoot "scripts\r2_upload.py"
$jobDir = Join-Path $repoRoot ("output\wan_2_2_animate\" + $JobName)
$manifestPath = Join-Path $jobDir "manifest.json"
if (-not (Test-Path -LiteralPath $uploadScript)) {
    throw "Missing upload helper: $uploadScript"
}
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Missing manifest: $manifestPath"
}

function Encode-R2Key {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    (($Key -split "/") | ForEach-Object { [uri]::EscapeDataString($_) }) -join "/"
}

$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json -AsHashtable

if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    $ResultPath = [string]$manifest.result.local_result_path
}
if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    throw "ResultPath not provided and manifest.result.local_result_path is empty."
}

$resolvedResult = (Resolve-Path -LiteralPath $ResultPath).Path

if ([string]::IsNullOrWhiteSpace($R2AccountId) -or [string]::IsNullOrWhiteSpace($R2AccessKeyId) -or [string]::IsNullOrWhiteSpace($R2SecretAccessKey)) {
    throw "R2 credentials missing. Provide -R2AccountId, -R2AccessKeyId, and -R2SecretAccessKey, or set matching environment variables."
}

& D:\code\YuYan\python\python.exe $uploadScript `
    --account-id $R2AccountId `
    --access-key-id $R2AccessKeyId `
    --secret-access-key $R2SecretAccessKey `
    --bucket $R2Bucket `
    --local-path $resolvedResult `
    --remote-prefix "$R2Prefix/$JobName/output" `
    --public-base-url $R2PublicBaseUrl

if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload result to R2."
}

$resultName = [System.IO.Path]::GetFileName($resolvedResult)
$remoteKey = "$R2Prefix/$JobName/output/$resultName"
$publicUrl = "$($R2PublicBaseUrl.TrimEnd('/'))/$(Encode-R2Key -Key $remoteKey)"
$manifest["published_result"] = [ordered]@{
    local_result_path = $resolvedResult
    bucket = $R2Bucket
    remote_key = $remoteKey
    public_url = $publicUrl
    uploaded_at = (Get-Date).ToString("s")
}
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host "uploaded result to $R2Prefix/$JobName/output"
Write-Host "public_url=$publicUrl"
