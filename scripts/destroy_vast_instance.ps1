param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceId
)

$ErrorActionPreference = "Stop"

cmd /c "echo y| vastai destroy instance $InstanceId --raw"
