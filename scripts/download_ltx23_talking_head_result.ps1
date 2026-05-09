param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$BaseUrl,

    [string]$PromptId,

    [string]$OutputDir,

    [int]$IntervalSeconds = 30,

    [int]$MaxChecks = 240,

    [switch]$Wait
)

$ErrorActionPreference = "Stop"

$repoRootForEnv = (Resolve-Path ".").Path
$r2HelperPathForEnv = Join-Path $repoRootForEnv "scripts\r2_env_helpers.ps1"
if (Test-Path -LiteralPath $r2HelperPathForEnv) {
    . $r2HelperPathForEnv
    Import-ProjectLocalConfig -RootPath $repoRootForEnv
}

function Get-JobPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName
    )

    $repoRoot = (Resolve-Path ".").Path
    $jobDir = Join-Path $repoRoot ("output\ltx23_talking_head_smoke\" + $JobName)
    if (-not (Test-Path -LiteralPath $jobDir)) {
        throw "Missing job directory: $jobDir"
    }

    $manifestPath = Join-Path $jobDir "manifest.json"
    $instancePath = Join-Path $jobDir "vast-instance.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Missing manifest: $manifestPath"
    }
    if (-not (Test-Path -LiteralPath $instancePath)) {
        throw "Missing instance metadata: $instancePath"
    }

    [pscustomobject]@{
        RepoRoot = $repoRoot
        JobDir = $jobDir
        ManifestPath = $manifestPath
        InstancePath = $instancePath
        HistoryApiPath = Join-Path $jobDir "history.api.json"
        ResultMetaPath = Join-Path $jobDir "result.api.json"
        DownloadsDir = Join-Path $jobDir "downloads"
    }
}

function Get-BaseUrlFromInstance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstancePath
    )

    $instance = Get-Content -Raw $InstancePath | ConvertFrom-Json
    $portBindings = $instance.ports.'8188/tcp'
    if ((-not $portBindings -or $portBindings.Count -lt 1) -and $instance.id) {
        $previousPythonUtf8 = $env:PYTHONUTF8
        $previousPythonIoEncoding = $env:PYTHONIOENCODING
        $env:PYTHONUTF8 = "1"
        $env:PYTHONIOENCODING = "utf-8"
        try {
            $liveInstance = & vastai show instance $instance.id --raw 2>$null | ConvertFrom-Json
            if ($liveInstance) {
                $instance = $liveInstance
                $portBindings = $instance.ports.'8188/tcp'
                $instance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $InstancePath -Encoding UTF8
            }
        }
        finally {
            if ($null -eq $previousPythonUtf8) {
                Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
            }
            else {
                $env:PYTHONUTF8 = $previousPythonUtf8
            }
            if ($null -eq $previousPythonIoEncoding) {
                Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
            }
            else {
                $env:PYTHONIOENCODING = $previousPythonIoEncoding
            }
        }
    }
    if (-not $portBindings -or $portBindings.Count -lt 1) {
        throw "Instance metadata missing 8188/tcp port binding."
    }

    $hostPort = $portBindings[0].HostPort
    $publicIp = $instance.public_ipaddr
    if ([string]::IsNullOrWhiteSpace($hostPort) -or [string]::IsNullOrWhiteSpace($publicIp)) {
        throw "Instance metadata missing public IP or 8188 host port."
    }

    "http://{0}:{1}" -f $publicIp, $hostPort
}

function Get-HistoryPayload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [string]$PromptId
    )

    $uri = if ([string]::IsNullOrWhiteSpace($PromptId)) {
        "$BaseUrl/history"
    } else {
        "$BaseUrl/history/$PromptId"
    }

    Invoke-RestMethod -Uri $uri -Method Get
}

function Get-EntryTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        $Entry
    )

    $timestamp = 0L
    if ($Entry.status -and $Entry.status.messages) {
        foreach ($message in $Entry.status.messages) {
            if ($message.Count -ge 2 -and $message[1].timestamp) {
                $value = [int64]$message[1].timestamp
                if ($value -gt $timestamp) {
                    $timestamp = $value
                }
            }
        }
    }

    if ($timestamp -eq 0 -and $Entry.prompt -and $Entry.prompt.Count -ge 4) {
        $promptMeta = $Entry.prompt[3]
        if ($promptMeta -and $promptMeta.create_time) {
            $timestamp = [int64]$promptMeta.create_time
        }
    }

    $timestamp
}

function Add-OutputFilesFromProperty {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Candidates,

        [Parameter(Mandatory = $true)]
        [string]$PromptId,

        [Parameter(Mandatory = $true)]
        [string]$NodeId,

        [Parameter(Mandatory = $true)]
        [long]$Timestamp,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Value,

        [Parameter(Mandatory = $true)]
        [string]$OutputPrefix
    )

    if (-not $Value) {
        return
    }

    $items = @()
    if ($Value -is [System.Array]) {
        $items = @($Value)
    }
    else {
        $items = @($Value)
    }

    foreach ($item in $items) {
        $filenameProperty = $item.PSObject.Properties["filename"]
        if (-not $filenameProperty -or -not $filenameProperty.Value) {
            continue
        }
        $filename = [string]$filenameProperty.Value
        if ($filename -notmatch '\.(mp4|mov|mkv|webm)$') {
            continue
        }
        if ($filename -notlike "$OutputPrefix*") {
            continue
        }

        $typeProperty = $item.PSObject.Properties["type"]
        $type = if ($typeProperty -and $typeProperty.Value) { [string]$typeProperty.Value } else { "output" }
        if ($type -ne "output") {
            continue
        }

        $subfolderProperty = $item.PSObject.Properties["subfolder"]
        $formatProperty = $item.PSObject.Properties["format"]
        $frameRateProperty = $item.PSObject.Properties["frame_rate"]
        $fullPathProperty = $item.PSObject.Properties["fullpath"]

        $Candidates.Add([pscustomobject]@{
            PromptId = $PromptId
            NodeId = $NodeId
            Timestamp = $Timestamp
            Filename = $filename
            Type = $type
            Subfolder = if ($subfolderProperty -and $subfolderProperty.Value) { [string]$subfolderProperty.Value } else { "" }
            Format = if ($formatProperty -and $formatProperty.Value) { [string]$formatProperty.Value } else { "" }
            FrameRate = if ($frameRateProperty -and $frameRateProperty.Value) { $frameRateProperty.Value } else { $null }
            FullPath = if ($fullPathProperty -and $fullPathProperty.Value) { [string]$fullPathProperty.Value } else { "" }
        })
    }
}

function Get-PromptIdFromEntry {
    param(
        [Parameter(Mandatory = $true)]
        $Entry
    )

    if ($Entry.status -and $Entry.status.messages) {
        foreach ($message in $Entry.status.messages) {
            if ($message.Count -ge 2 -and $message[1].prompt_id) {
                return [string]$message[1].prompt_id
            }
        }
    }

    if ($Entry.prompt -and $Entry.prompt.Count -ge 2 -and $Entry.prompt[1]) {
        return [string]$Entry.prompt[1]
    }

    ""
}

function Find-OutputCandidate {
    param(
        [Parameter(Mandatory = $true)]
        $History,

        [Parameter(Mandatory = $true)]
        [string]$JobName,

        [string]$RequestedPromptId = ""
    )

    $prefix = "ltx23_talking_head_smoke-$JobName"
    $candidates = New-Object System.Collections.Generic.List[object]

    $historyEntries = @()
    if ($History.outputs) {
        $directPromptId = if ([string]::IsNullOrWhiteSpace($RequestedPromptId)) {
            Get-PromptIdFromEntry -Entry $History
        }
        else {
            $RequestedPromptId
        }
        $historyEntries += [pscustomobject]@{
            PromptId = $directPromptId
            Entry = $History
        }
    }
    else {
        foreach ($historyProperty in $History.PSObject.Properties) {
            $historyEntries += [pscustomobject]@{
                PromptId = $historyProperty.Name
                Entry = $historyProperty.Value
            }
        }
    }

    foreach ($historyItem in $historyEntries) {
        $promptId = $historyItem.PromptId
        $entry = $historyItem.Entry
        if (-not $entry.outputs) {
            continue
        }

        $entryTimestamp = Get-EntryTimestamp -Entry $entry
        foreach ($outputProperty in $entry.outputs.PSObject.Properties) {
            $nodeId = $outputProperty.Name
            $outputNode = $outputProperty.Value

            Add-OutputFilesFromProperty `
                -Candidates $candidates `
                -PromptId $promptId `
                -NodeId $nodeId `
                -Timestamp $entryTimestamp `
                -Value $outputNode `
                -OutputPrefix $prefix

            foreach ($property in $outputNode.PSObject.Properties) {
                Add-OutputFilesFromProperty `
                    -Candidates $candidates `
                    -PromptId $promptId `
                    -NodeId $nodeId `
                    -Timestamp $entryTimestamp `
                    -Value $property.Value `
                    -OutputPrefix $prefix
            }
        }
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    $candidates |
        Sort-Object `
            @{ Expression = { $_.Timestamp }; Descending = $true }, `
            @{ Expression = { $_.Filename }; Descending = $true } |
        Select-Object -First 1
}

function Update-ManifestResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$ResultInfo
    )

    $manifest = Get-Content -Raw $ManifestPath | ConvertFrom-Json -AsHashtable
    $manifest["result"] = $ResultInfo
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
}

$paths = Get-JobPaths -JobName $JobName
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = $paths.DownloadsDir
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$history = $null
$candidate = $null
$lastError = $null
$resolvedBaseUrl = $BaseUrl

for ($check = 1; $check -le $MaxChecks; $check += 1) {
    try {
        if ([string]::IsNullOrWhiteSpace($resolvedBaseUrl)) {
            $resolvedBaseUrl = Get-BaseUrlFromInstance -InstancePath $paths.InstancePath
        }
        $resolvedBaseUrl = $resolvedBaseUrl.TrimEnd("/")

        $history = Get-HistoryPayload -BaseUrl $resolvedBaseUrl -PromptId $PromptId
        $candidate = Find-OutputCandidate -History $history -JobName $JobName -RequestedPromptId $PromptId
        if ($candidate) {
            break
        }
        $lastError = $null
    } catch {
        $lastError = $_.Exception.Message
    }

    if (-not $Wait) {
        break
    }
    Start-Sleep -Seconds $IntervalSeconds
}

if (-not $history) {
    if ($lastError) {
        throw "Failed to read ComfyUI history API: $lastError"
    }
    throw "Failed to read ComfyUI history API."
}

$history | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $paths.HistoryApiPath -Encoding UTF8

if (-not $candidate) {
    if ($Wait) {
        throw "No output file matching ltx23_talking_head_smoke-$JobName was found after waiting."
    }
    throw "No output file matching ltx23_talking_head_smoke-$JobName was found in ComfyUI history."
}

$query = "filename=$([uri]::EscapeDataString($candidate.Filename))&type=$([uri]::EscapeDataString($candidate.Type))&subfolder=$([uri]::EscapeDataString($candidate.Subfolder))"
$downloadUrl = "$resolvedBaseUrl/view?$query"
$localResultPath = Join-Path (Resolve-Path -LiteralPath $OutputDir).Path $candidate.Filename

Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $localResultPath

$resultInfo = [ordered]@{
    base_url = $resolvedBaseUrl
    prompt_id = $candidate.PromptId
    node_id = $candidate.NodeId
    filename = $candidate.Filename
    type = $candidate.Type
    subfolder = $candidate.Subfolder
    format = $candidate.Format
    frame_rate = $candidate.FrameRate
    fullpath = $candidate.FullPath
    local_result_path = $localResultPath
    downloaded_at = (Get-Date).ToString("s")
    download_url = $downloadUrl
}

$resultInfo | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $paths.ResultMetaPath -Encoding UTF8
Update-ManifestResult -ManifestPath $paths.ManifestPath -ResultInfo $resultInfo

Write-Host "base_url=$resolvedBaseUrl"
Write-Host "prompt_id=$($candidate.PromptId)"
Write-Host "filename=$($candidate.Filename)"
Write-Host "local_result=$localResultPath"
