param(
    [string]$Repo = "myjr2015/codex-gpu-burst-workflow",

    [string]$Workflow = "build-wan22-kj-env-image.yml",

    [string]$Branch = "main",

    [int]$IntervalSeconds = 30,

    [int]$MaxChecks = 120,

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

$headers = @{
    Accept = "application/vnd.github+json"
    Authorization = "Bearer $GitHubToken"
    "X-GitHub-Api-Version" = "2022-11-28"
}

$uri = "https://api.github.com/repos/$owner/$repoName/actions/workflows/$Workflow/runs?branch=$Branch&per_page=1"

for ($i = 1; $i -le $MaxChecks; $i += 1) {
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    $run = @($response.workflow_runs) | Select-Object -First 1
    if ($null -eq $run) {
        Write-Host "check=$i status=no_runs"
    }
    else {
        Write-Host "check=$i run_id=$($run.id) status=$($run.status) conclusion=$($run.conclusion) url=$($run.html_url)"
        if ($run.status -eq "completed") {
            if ($run.conclusion -ne "success") {
                throw "Workflow completed with conclusion=$($run.conclusion): $($run.html_url)"
            }
            exit 0
        }
    }
    Start-Sleep -Seconds $IntervalSeconds
}

throw "Workflow did not complete after $MaxChecks checks."
