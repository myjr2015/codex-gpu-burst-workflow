param(
    [string]$CodexHome = "$env:USERPROFILE\.codex",

    [string]$VersionName = "v1.0.0",

    [string]$Commit = "",

    [string]$Remote = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path ".").Path
$skillsSourceRoot = Join-Path $repoRoot "skills"
$docsSourcePath = Join-Path $repoRoot "docs\wan22-v1.0-baseline.md"
$profilesSourcePath = Join-Path $repoRoot "config\vast-workflow-profiles.json"
$machineRegistrySourcePath = Join-Path $repoRoot "data\vast-machine-registry.json"

foreach ($requiredPath in @(
    (Join-Path $skillsSourceRoot "history_video_pipeline_skills"),
    (Join-Path $skillsSourceRoot "okskills"),
    (Join-Path $skillsSourceRoot "badskills"),
    $docsSourcePath,
    $profilesSourcePath,
    $machineRegistrySourcePath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Missing required source path: $requiredPath"
    }
}

$skillsTargetRoot = Join-Path $CodexHome "skills"
$referenceRoot = Join-Path $CodexHome "references\wan22\$VersionName"

New-Item -ItemType Directory -Force -Path $skillsTargetRoot | Out-Null
New-Item -ItemType Directory -Force -Path $referenceRoot | Out-Null

foreach ($skillName in @("history_video_pipeline_skills", "okskills", "badskills")) {
    $sourceDir = Join-Path $skillsSourceRoot $skillName
    $targetDir = Join-Path $skillsTargetRoot $skillName

    if (Test-Path -LiteralPath $targetDir) {
        Remove-Item -LiteralPath $targetDir -Recurse -Force
    }

    Copy-Item -LiteralPath $sourceDir -Destination $targetDir -Recurse -Force
}

$baselineTargetPath = Join-Path $referenceRoot "wan22-v1.0-baseline.md"
$profilesTargetPath = Join-Path $referenceRoot "vast-workflow-profiles.json"
$machineRegistryTargetPath = Join-Path $referenceRoot "vast-machine-registry.json"
$latestPath = Join-Path (Join-Path $CodexHome "references\wan22") "CURRENT_VERSION.txt"
$latestRegistryPath = Join-Path (Join-Path $CodexHome "references\wan22") "machine-registry.json"
$metadataPath = Join-Path $referenceRoot "version.json"

Copy-Item -LiteralPath $docsSourcePath -Destination $baselineTargetPath -Force
Copy-Item -LiteralPath $profilesSourcePath -Destination $profilesTargetPath -Force
Copy-Item -LiteralPath $machineRegistrySourcePath -Destination $machineRegistryTargetPath -Force

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $latestPath) | Out-Null
Set-Content -LiteralPath $latestPath -Value $VersionName -Encoding ASCII
Copy-Item -LiteralPath $machineRegistrySourcePath -Destination $latestRegistryPath -Force

$metadata = [ordered]@{
    version = $VersionName
    commit = $Commit
    remote = $Remote
    repo_root = $repoRoot
    synced_at = (Get-Date).ToString("s")
    synced_items = @(
        "skills/history_video_pipeline_skills",
        "skills/okskills",
        "skills/badskills",
        "docs/wan22-v1.0-baseline.md",
        "config/vast-workflow-profiles.json",
        "data/vast-machine-registry.json"
    )
}

$metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataPath -Encoding UTF8

Write-Host "skills_root=$skillsTargetRoot"
Write-Host "reference_root=$referenceRoot"
Write-Host "current_version=$VersionName"
Write-Host "metadata=$metadataPath"
