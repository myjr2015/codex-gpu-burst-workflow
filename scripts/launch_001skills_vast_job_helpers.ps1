function Get-001SkillsLaunchExtraEnv {
    param(
        [switch]$PrewarmedImage,
        [switch]$WarmStart
    )

    $items = @()
    if ($PrewarmedImage) {
        $items += "PREWARMED_IMAGE=1"
    }
    if ($WarmStart) {
        $items += "WARM_START=1"
    }

    return $items
}
