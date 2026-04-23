param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceId
)

$ErrorActionPreference = "Stop"

vastai destroy instance $InstanceId --yes --raw
