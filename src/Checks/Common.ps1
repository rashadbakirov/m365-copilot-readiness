# Common.ps1 — shared, cached tenant reads used by several checks.

$script:CrCopilotPlan = 'M365_COPILOT_APPS'   # service plan inside every Microsoft 365 Copilot SKU (licensing reference)

function Get-CrSkus {
    if ($null -eq $script:CrSkus) {
        $script:CrSkus = @((Invoke-CrGraph '/subscribedSkus?$select=skuId,skuPartNumber,consumedUnits,prepaidUnits,servicePlans').value)
    }
    $script:CrSkus
}

function Get-CrCopilotSkus {
    @(Get-CrSkus | Where-Object { $_.servicePlans.servicePlanName -contains $script:CrCopilotPlan -and $_.prepaidUnits.enabled -gt 0 })
}

function Test-CrHasCopilot { (Get-CrCopilotSkus).Count -gt 0 }

function Test-CrScope {
    <# True when the signed-in token holds one of the scopes (or when running app-only / demo). #>
    param([string[]]$Any)
    if (-not $script:CrCtx -or $script:CrCtx.Mode -ne 'delegated') { return $true }
    [bool](@($Any) | Where-Object { $_ -in @($script:CrCtx.Scopes) })
}

function ConvertTo-CrUtc($Value) {
    <# Graph dates are UTC. A date-only value ("2026-01-31") must not become the day before in a UTC+ time zone. #>
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
}

function Get-CrDateText($Value) {
    if (-not $Value) { return $null }
    try { (ConvertTo-CrUtc $Value).ToString('yyyy-MM-dd') } catch { "$Value" }
}

function Get-CrNow {
    # demo runs pin "now" to the fixture date so the example report never drifts
    if ($script:CrNow) { return $script:CrNow }
    (Get-Date).ToUniversalTime()
}

function Get-CrAgeDays($Value) {
    if (-not $Value) { return $null }
    try { [int]((Get-CrNow) - (ConvertTo-CrUtc $Value)).TotalDays } catch { $null }
}
