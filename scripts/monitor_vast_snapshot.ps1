param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceId,

    [Parameter(Mandatory = $true)]
    [string]$DockerUsername,

    [Parameter(Mandatory = $true)]
    [string]$DockerToken,

    [Parameter(Mandatory = $true)]
    [string]$DockerRepo,

    [string]$StatusPath = "output/vast-snapshot-monitor/status.json",

    [int]$IntervalSeconds = 300
)

$ErrorActionPreference = "Stop"

function Get-DockerHubToken {
    param(
        [string]$Username,
        [string]$Token
    )

    $body = @{
        username = $Username
        password = $Token
    } | ConvertTo-Json

    return (Invoke-RestMethod `
        -Method Post `
        -Uri "https://hub.docker.com/v2/users/login/" `
        -ContentType "application/json" `
        -Body $body).token
}

function Get-VastInstanceRecord {
    param([string]$TargetInstanceId)

    $instances = vastai show instances --raw | ConvertFrom-Json
    return $instances | Where-Object { "$($_.id)" -eq "$TargetInstanceId" } | Select-Object -First 1
}

function Get-DockerTags {
    param(
        [string]$Username,
        [string]$Token,
        [string]$Repo
    )

    $jwt = Get-DockerHubToken -Username $Username -Token $Token
    $response = Invoke-RestMethod `
        -Headers @{ Authorization = "JWT $jwt" } `
        -Uri "https://hub.docker.com/v2/repositories/$Repo/tags/?page_size=20"

    return $response
}

function Write-Status {
    param(
        [string]$Path,
        [object]$Payload
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $Payload | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

while ($true) {
    $timestamp = [DateTimeOffset]::Now.ToString("o")

    try {
        $instance = Get-VastInstanceRecord -TargetInstanceId $InstanceId
        $tags = Get-DockerTags -Username $DockerUsername -Token $DockerToken -Repo $DockerRepo

        $payload = [ordered]@{
            checked_at = $timestamp
            instance_id = $InstanceId
            docker_repo = $DockerRepo
            instance_found = $null -ne $instance
            vast = if ($instance) {
                [ordered]@{
                    actual_status = $instance.actual_status
                    cur_state = $instance.cur_state
                    intended_status = $instance.intended_status
                    next_state = $instance.next_state
                    status_msg = $instance.status_msg
                    total_hour = $instance.instance.totalHour
                    gpu_hour = $instance.instance.gpuCostPerHour
                    disk_hour = $instance.instance.diskHour
                    duration = $instance.duration
                }
            } else {
                $null
            }
            docker = [ordered]@{
                count = @($tags.results).Count
                results = @($tags.results | Select-Object name, tag_last_pushed, full_size, images)
            }
        }
    } catch {
        $payload = [ordered]@{
            checked_at = $timestamp
            instance_id = $InstanceId
            docker_repo = $DockerRepo
            error = $_.Exception.Message
        }
    }

    Write-Status -Path $StatusPath -Payload $payload
    Start-Sleep -Seconds $IntervalSeconds
}
