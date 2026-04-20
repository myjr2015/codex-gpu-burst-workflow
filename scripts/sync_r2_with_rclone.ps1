param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("upload", "download")]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$LocalPath,

    [Parameter(Mandatory = $true)]
    [string]$RemotePath,

    [string]$RcloneRemote = "r2"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    throw "rclone not found. Install rclone first."
}

$resolvedLocal = Resolve-Path -LiteralPath $LocalPath
$target = "$RcloneRemote`:$RemotePath"

switch ($Mode) {
    "upload" {
        rclone copy $resolvedLocal $target --progress --transfers 4 --checkers 8
    }
    "download" {
        rclone copy $target $resolvedLocal --progress --transfers 4 --checkers 8
    }
}
