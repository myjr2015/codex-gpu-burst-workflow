param(
    [string]$Repo = "myjr2015/codex-gpu-burst-workflow",

    [string]$Workflow = "build-wan22-kj-env-image.yml",

    [string]$Ref = "main",

    [hashtable]$Inputs = @{},

    [string]$GitHubToken = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$r2HelperPath = Join-Path $repoRoot "scripts\r2_env_helpers.ps1"
if (Test-Path -LiteralPath $r2HelperPath) {
    . $r2HelperPath
    Import-ProjectDotEnv -Path (Join-Path $repoRoot ".env")
}

if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
    $GitHubToken = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } elseif ($env:GH_TOKEN) { $env:GH_TOKEN } else { "" }
}
if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
    throw "Missing GitHub token. Set GITHUB_TOKEN/GH_TOKEN or add GitHub to api.txt."
}

$owner, $repoName = $Repo -split "/", 2
if ([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($repoName)) {
    throw "Repo must be owner/repo: $Repo"
}

$uri = "https://api.github.com/repos/$owner/$repoName/actions/workflows/$Workflow/dispatches"
$body = @{
    ref = $Ref
    inputs = $Inputs
} | ConvertTo-Json -Depth 8

$headers = @{
    Accept = "application/vnd.github+json"
    Authorization = "Bearer $GitHubToken"
    "X-GitHub-Api-Version" = "2022-11-28"
}

Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body -ContentType "application/json" | Out-Null
Write-Host "workflow_dispatched=$Workflow"
Write-Host "repo=$Repo"
Write-Host "ref=$Ref"
if ($Inputs.Count -gt 0) {
    Write-Host ("inputs=" + (($Inputs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ","))
}
