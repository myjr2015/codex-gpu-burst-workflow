param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$ResultPath,

    [string]$R2Prefix = "runcomfy-inputs/001skills",

    [string]$R2Bucket = "runcomfy",

    [string]$R2PublicBaseUrl = "https://pub-9bd0a6fd057f4ec9b2938513e07e229a.r2.dev",

    [string]$R2AccountId = $env:CLOUDFLARE_ACCOUNT_ID,

    [string]$R2AccessKeyId = $env:R2_ACCESS_KEY_ID,

    [string]$R2SecretAccessKey = $env:R2_SECRET_ACCESS_KEY
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$uploadScript = Join-Path $repoRoot "scripts\r2_upload.py"
if (-not (Test-Path -LiteralPath $uploadScript)) {
    throw "Missing upload helper: $uploadScript"
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

Write-Host "uploaded result to $R2Prefix/$JobName/output"
