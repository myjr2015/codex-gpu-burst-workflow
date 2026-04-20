param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceId,

    [Parameter(Mandatory = $true)]
    [string]$SshHost,

    [Parameter(Mandatory = $true)]
    [int]$SshPort,

    [Parameter(Mandatory = $true)]
    [string]$PublicIp,

    [string]$StatusPath = "output/vast-instance-startup-monitor/status.json",

    [string]$HttpPorts = "1111,8080",

    [int]$IntervalSeconds = 120
)

$ErrorActionPreference = "Stop"

$ResolvedHttpPorts = @()
foreach ($rawPort in ($HttpPorts -split ",")) {
    $trimmed = $rawPort.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
        $ResolvedHttpPorts += [int]$trimmed
    }
}

function Get-InstanceRecord {
    param([string]$TargetInstanceId)
    $instances = vastai show instances --raw | ConvertFrom-Json
    return $instances | Where-Object { "$($_.id)" -eq "$TargetInstanceId" } | Select-Object -First 1
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
        $instance = Get-InstanceRecord -TargetInstanceId $InstanceId
        $tcp = Test-NetConnection $SshHost -Port $SshPort -WarningAction SilentlyContinue

        $httpChecks = [ordered]@{
            public_ip = $PublicIp
        }
        foreach ($port in $ResolvedHttpPorts) {
            $label = "port_$port"
            try {
                $httpChecks[$label] = (Invoke-WebRequest -UseBasicParsing -Uri "http://$PublicIp`:$port" -TimeoutSec 8).StatusCode
            } catch {
                $httpChecks[$label] = $_.Exception.Message
            }
        }

        $payload = [ordered]@{
            checked_at = $timestamp
            instance_id = $InstanceId
            found = $null -ne $instance
            ssh = [ordered]@{
                host = $SshHost
                port = $SshPort
                tcp_ok = $tcp.TcpTestSucceeded
            }
            http = $httpChecks
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
                    public_ip = $instance.public_ipaddr
                    ssh_host = $instance.ssh_host
                    ssh_port = $instance.ssh_port
                }
            } else {
                $null
            }
        }
    } catch {
        $payload = [ordered]@{
            checked_at = $timestamp
            instance_id = $InstanceId
            error = $_.Exception.Message
        }
    }

    Write-Status -Path $StatusPath -Payload $payload
    Start-Sleep -Seconds $IntervalSeconds
}
