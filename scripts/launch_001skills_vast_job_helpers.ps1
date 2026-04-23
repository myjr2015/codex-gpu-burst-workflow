function Get-001SkillsLaunchExtraEnv {
    param(
        [switch]$WarmStart
    )

    $items = @()
    if ($WarmStart) {
        $items += "WARM_START=1"
    }

    return $items
}
