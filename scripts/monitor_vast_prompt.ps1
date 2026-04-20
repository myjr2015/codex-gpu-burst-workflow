param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$PromptId,
    [Parameter(Mandatory = $true)][string]$StatusPath,
    [int]$IntervalSeconds = 120,
    [int]$MaxChecks = 240
)

$ErrorActionPreference = "Stop"

$authBytes = [System.Text.Encoding]::ASCII.GetBytes("vastai:$Token")
$authHeader = "Basic " + [Convert]::ToBase64String($authBytes)
$headers = @{ Authorization = $authHeader }

for ($i = 1; $i -le $MaxChecks; $i++) {
    $timestamp = (Get-Date).ToString("s")

    try {
        $queue = Invoke-RestMethod -Uri "$BaseUrl/queue" -Headers $headers -Method Get
    } catch {
        $queue = @{ error = $_.Exception.Message }
    }

    try {
        $history = Invoke-RestMethod -Uri "$BaseUrl/history/$PromptId" -Headers $headers -Method Get
    } catch {
        $history = @{ error = $_.Exception.Message }
    }

    $payload = [ordered]@{
        timestamp = $timestamp
        check = $i
        prompt_id = $PromptId
        queue = $queue
        history = $history
    }

    $payload | ConvertTo-Json -Depth 100 | Set-Content -Path $StatusPath -Encoding UTF8

    if ($history.PSObject.Properties.Name -contains $PromptId) {
        break
    }

    Start-Sleep -Seconds $IntervalSeconds
}
