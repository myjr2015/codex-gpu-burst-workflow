param(
    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [string]$BaseUrl,

    [string]$PromptId,

    [string]$OutputDir,

    [int]$IntervalSeconds = 30,

    [int]$MaxChecks = 360,

    [switch]$Wait
)

$ErrorActionPreference = "Stop"

function Get-JobPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName
    )

    $repoRoot = (Resolve-Path ".").Path
    $jobDir = Join-Path $repoRoot ("output\wan22_kj_30s\" + $JobName)
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
        $previousPythonIoEncoding = $env:PYTHONIOENCODING
        $env:PYTHONIOENCODING = "utf-8"
        try {
            $liveInstance = & vastai show instance $instance.id --raw 2>$null | ConvertFrom-Json
        }
        finally {
            if ($null -eq $previousPythonIoEncoding) {
                Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
            }
            else {
                $env:PYTHONIOENCODING = $previousPythonIoEncoding
            }
        }
        if ($liveInstance) {
            $instance = $liveInstance | Select-Object * -ExcludeProperty @("instance_api_key", "jupyter_token", "onstart", "ssh_key", "extra_env")
            $portBindings = $instance.ports.'8188/tcp'
            $instance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $InstancePath -Encoding UTF8
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

function Get-InstanceIdFromPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstancePath
    )

    if (-not (Test-Path -LiteralPath $InstancePath)) {
        return $null
    }
    $instance = Get-Content -Raw $InstancePath | ConvertFrom-Json
    if ($instance -and $instance.id) {
        return "$($instance.id)"
    }
    $null
}

function Get-VastLogTailSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId,

        [int]$Tail = 160
    )

    $previousPythonUtf8 = $env:PYTHONUTF8
    $previousPythonIoEncoding = $env:PYTHONIOENCODING
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    try {
        @(& vastai logs $InstanceId --tail $Tail 2>&1 | ForEach-Object { "$_" })
    }
    catch {
        @()
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

function Assert-NoRemotePreflightFailure {
    param(
        [string]$InstanceId
    )

    if ([string]::IsNullOrWhiteSpace($InstanceId)) {
        return
    }

    $lines = Get-VastLogTailSafe -InstanceId $InstanceId
    $failure = $lines |
        Where-Object {
            $_ -match '^\[hf-speedtest\].*decision=reject' -or
            $_ -match '^\[hf-speedtest\] reject' -or
            $_ -match 'stopping before bootstrap to avoid slow model download'
        } |
        Select-Object -Last 1

    if ($failure) {
        throw "HF speed preflight rejected this machine: $failure"
    }
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

    Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 60
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

function Find-OutputCandidate {
    param(
        [Parameter(Mandatory = $true)]
        $History,

        [Parameter(Mandatory = $true)]
        [string]$JobName
    )

    $prefix = "wan22_kj_30s-$JobName"
    $candidates = New-Object System.Collections.Generic.List[object]

    foreach ($historyProperty in $History.PSObject.Properties) {
        $promptId = $historyProperty.Name
        $entry = $historyProperty.Value
        if (-not $entry.outputs) {
            continue
        }

        $entryTimestamp = Get-EntryTimestamp -Entry $entry
        foreach ($outputProperty in $entry.outputs.PSObject.Properties) {
            $outputNode = $outputProperty.Value
            if (-not $outputNode.gifs) {
                continue
            }
            foreach ($gif in $outputNode.gifs) {
                if ($gif.type -ne "output") {
                    continue
                }
                if (-not $gif.filename.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $candidates.Add([pscustomobject]@{
                    PromptId = $promptId
                    NodeId = $outputProperty.Name
                    Timestamp = $entryTimestamp
                    Filename = $gif.filename
                    Type = $gif.type
                    Subfolder = [string]$gif.subfolder
                    Format = [string]$gif.format
                    FrameRate = $gif.frame_rate
                    FullPath = [string]$gif.fullpath
                })
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
$instanceId = Get-InstanceIdFromPath -InstancePath $paths.InstancePath

for ($check = 1; $check -le $MaxChecks; $check += 1) {
    try {
        Assert-NoRemotePreflightFailure -InstanceId $instanceId
        if ([string]::IsNullOrWhiteSpace($resolvedBaseUrl)) {
            $resolvedBaseUrl = Get-BaseUrlFromInstance -InstancePath $paths.InstancePath
        }
        $resolvedBaseUrl = $resolvedBaseUrl.TrimEnd("/")

        $history = Get-HistoryPayload -BaseUrl $resolvedBaseUrl -PromptId $PromptId
        $candidate = Find-OutputCandidate -History $history -JobName $JobName
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
    Assert-NoRemotePreflightFailure -InstanceId $instanceId
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
        throw "No output file matching wan22_kj_30s-$JobName was found after waiting."
    }
    throw "No output file matching wan22_kj_30s-$JobName was found in ComfyUI history."
}

$query = "filename=$([uri]::EscapeDataString($candidate.Filename))&type=$([uri]::EscapeDataString($candidate.Type))&subfolder=$([uri]::EscapeDataString($candidate.Subfolder))"
$downloadUrl = "$resolvedBaseUrl/view?$query"
$localResultPath = Join-Path (Resolve-Path -LiteralPath $OutputDir).Path $candidate.Filename

Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $localResultPath -TimeoutSec 1800

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
