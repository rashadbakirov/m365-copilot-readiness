# Daten schützen — labels and DLP that Copilot respects.

function Get-CrLabels {
    <#
      .SYNOPSIS  Sensitivity labels with an explicit scope. 'tenant' = tenant catalogue (v1.0 dataSecurityAndGovernance),
                 'user' = only labels published to the signed-in account (beta /me fallback). Cached; K01 and K02 share it.
    #>
    if ($script:CrLabels) { return $script:CrLabels }
    $labels = $null; $scope = $null; $err = $null
    if (Test-CrScope 'SensitivityLabel.Read', 'SensitivityLabels.Read.All') {
        try { $labels = @(Invoke-CrGraph '/security/dataSecurityAndGovernance/sensitivityLabels' -All); $scope = 'tenant' } catch { $err = $_ }
    }
    if ($null -eq $scope -and $script:CrCtx.Mode -ne 'app') {
        $labels = @(Invoke-CrGraph '/me/security/informationProtection/sensitivityLabels' -Beta -All); $scope = 'user'
    }
    elseif ($null -eq $scope -and $err) { throw $err }
    $norm = foreach ($l in $labels) {
        $formats = if ($l.applicableTo) { @("$($l.applicableTo)" -split ',\s*') } else { @($l.contentFormats | Where-Object { $_ }) }
        [pscustomobject]@{
            name = $l.name; enabled = $(if ($null -ne $l.isEnabled) { [bool]$l.isEnabled } elseif ($null -ne $l.isActive) { [bool]$l.isActive } else { $true })
            formats = @($formats | Where-Object { $_ }); priority = ($l.priority ?? $l.sensitivity); parent = $l.parent.name
        }
    }
    $script:CrLabels = [pscustomobject]@{ scope = $scope; labels = @($norm | Where-Object { $_ }) }
    $script:CrLabels
}

function Test-CrK01 {
    Invoke-CrCheck 'K01' {
        $l = Get-CrLabels
        $ev = $l.labels | ForEach-Object { [pscustomobject]@{ Label = $_.name; Enabled = $_.enabled; Formats = ($_.formats -join ', '); Priority = $_.priority; Scope = $l.scope } }
        $enabled = @($l.labels | Where-Object enabled).Count
        $a = @{ n = $l.labels.Count; enabled = $enabled; scope = $l.scope }
        if ($l.labels.Count -eq 0) {
            if ($l.scope -eq 'user') { return New-CrResult K01 -State Unknown -Msg 'K01.userScopeEmpty' -Arguments $a }
            return New-CrResult K01 -State Fail -Msg 'K01.none' -Arguments $a
        }
        $state = if ($enabled -ge 3) { 'Pass' } elseif ($enabled -ge 1) { 'Warn' } else { 'Fail' }
        New-CrResult K01 -State $state -Score $(if ($state -eq 'Warn') { 40 + 15 * $enabled } else { -1 }) -Msg "K01.labels.$($l.scope)" -Arguments $a -Evidence $ev
    }
}

function Test-CrK02 {
    Invoke-CrCheck 'K02' {
        $l = Get-CrLabels
        $on = @($l.labels | Where-Object enabled)
        if ($on.Count -eq 0) {
            # No labels at all: K01 already reports that, so there is nothing here to assess (not a failed read) —
            # unless only the user scope was readable, in which case the tenant catalogue is simply unknown.
            $state = if (@($l.labels).Count -eq 0 -and $l.scope -ne 'user') { 'NotApplicable' } else { 'Unknown' }
            return New-CrResult K02 -State $state -Msg 'K02.noLabels'
        }
        if (@($on | Where-Object { @($_.formats | Where-Object { $_ }).Count -gt 0 }).Count -eq 0) { return New-CrResult K02 -State Unknown -Msg 'gen.empty' -Detail 'labels carry no scope information' }
        $container = @($on | Where-Object { @($_.formats | Where-Object { $_ }) -match '^(site|unifiedGroup)$' })
        $file = @($on | Where-Object { @($_.formats | Where-Object { $_ }) -match '^file$' })
        $ev = $on | ForEach-Object { [pscustomobject]@{ Label = $_.name; Formats = ($_.formats -join ', '); Container = [bool](@($_.formats | Where-Object { $_ }) -match '^(site|unifiedGroup)$') } }
        $state = if ($container.Count -gt 0 -and $file.Count -gt 0) { 'Pass' } elseif ($file.Count -gt 0) { 'Warn' } else { 'Fail' }
        New-CrResult K02 -State $state -Msg 'K02.formats' -Arguments @{ file = $file.Count; container = $container.Count; scope = $l.scope } -Evidence $ev
    }
}

function ConvertFrom-CrLabelSettings {
    <# Get-LabelPolicy Settings come as "[key, value]" strings. Returns a hashtable key → value. #>
    param([object[]]$Settings)
    $h = @{}
    foreach ($s in @($Settings | Where-Object { $_ })) { if ("$s" -match '^\s*\[?\s*([^,\]]+?)\s*,\s*(.*?)\s*\]?\s*$') { $h[$Matches[1].ToLowerInvariant()] = $Matches[2] } }
    $h
}

function Test-CrK03 {
    Invoke-CrCheck 'K03' {
        $pol = @(Invoke-CrReader Get-LabelPolicy)
        if ($pol.Count -eq 0) { return New-CrResult K03 -State Fail -Msg 'K03.none' }
        $ev = foreach ($p in $pol) {
            $s = ConvertFrom-CrLabelSettings $p.Settings
            $def = $s['defaultlabelid']; $hasDef = [bool]($def -and $def -notmatch '^(none|null)?$')
            [pscustomobject]@{ Policy = $p.Name; Enabled = [bool]$p.Enabled; Labels = @($p.Labels | Where-Object { $_ }).Count; DefaultLabel = $hasDef; Mandatory = ("$($s['mandatory'])" -eq 'true') }
        }
        $active = @($ev | Where-Object Enabled)
        $both = @($active | Where-Object { $_.DefaultLabel -and $_.Mandatory }).Count
        $one = @($active | Where-Object { $_.DefaultLabel -or $_.Mandatory }).Count
        $state = if ($both -gt 0) { 'Pass' } elseif ($one -gt 0) { 'Warn' } else { 'Fail' }
        New-CrResult K03 -State $state -Msg 'K03.policies' -Arguments @{ n = $pol.Count; active = $active.Count; both = $both; one = $one } -Evidence $ev
    }
}

function Test-CrK04 {
    Invoke-CrCheck 'K04' {
        $auto = @(Invoke-CrReader Get-AutoSensitivityLabelPolicy)
        $ev = $auto | ForEach-Object { [pscustomobject]@{ Policy = $_.Name; Mode = "$($_.Mode)"; Enabled = [bool]$_.Enabled; Label = $_.ApplySensitivityLabel } }
        $enforced = @($auto | Where-Object { "$($_.Mode)" -eq 'Enable' -and $_.Enabled }).Count
        $sim = @($auto | Where-Object { "$($_.Mode)" -like 'TestWith*' -and $_.Enabled }).Count
        $state = if ($enforced -gt 0) { 'Pass' } elseif ($auto.Count -gt 0) { 'Warn' } else { 'Fail' }
        New-CrResult K04 -State $state -Score $(if ($state -eq 'Warn' -and $sim -gt 0) { 65 } else { -1 }) -Msg 'K04.policies' -Arguments @{ n = $auto.Count; enforced = $enforced; simulation = $sim } -Evidence $ev
    }
}

function Test-CrK05 {
    Invoke-CrCheck 'K05' {
        $all = @(Invoke-CrReader Get-SPODataAccessGovernanceInsight @{ ReportEntity = 'SensitivityLabelForFiles' })
        $done = @($all | Where-Object { "$($_.Status)" -eq 'Completed' -and $_.CreatedDateTime } | Sort-Object { ConvertTo-CrUtc $_.CreatedDateTime } -Descending)
        $ev = $all | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{ Report = $_.ReportName; Status = "$($_.Status)"; Created = (Get-CrDateText $_.CreatedDateTime); AgeDays = (Get-CrAgeDays $_.CreatedDateTime); Sites = ($_.CountOfSitesInReport ?? $_.SitesFound) } }
        if ($done.Count -eq 0) { return New-CrResult K05 -State Warn -Score 45 -Msg 'K05.none' -Evidence $ev }
        $age = Get-CrAgeDays $done[0].CreatedDateTime
        $state = if ($age -le 60) { 'Pass' } else { 'Warn' }
        New-CrResult K05 -State $state -Score $(if ($state -eq 'Warn') { 60 } else { -1 }) -Msg 'K05.reports' -Arguments @{ n = $done.Count; age = $age } -Evidence $ev
    }
}

function Test-CrK06 {
    Invoke-CrCheck 'K06' {
        $rl = @(Invoke-CrGraph '/security/labels/retentionLabels' -Beta -All)
        $ev = $rl | ForEach-Object { [pscustomobject]@{ Label = $_.displayName; During = $_.behaviorDuringRetentionPeriod; After = $_.actionAfterRetentionPeriod; Days = $_.retentionDuration.days; InUse = $_.isInUse } }
        $inUse = @($rl | Where-Object isInUse).Count
        $state = if ($rl.Count -eq 0) { 'Warn' } elseif ($inUse -gt 0) { 'Pass' } else { 'Warn' }
        New-CrResult K06 -State $state -Score $(if ($rl.Count -eq 0) { 45 } elseif ($state -eq 'Warn') { 65 } else { -1 }) -Msg 'K06.labels' -Arguments @{ n = $rl.Count; inUse = $inUse } -Evidence $ev
    }
}

# ---------- Purview DLP for Copilot ----------
# Copilot location id from the New-DlpCompliancePolicy example (Microsoft Learn): 470f2276-e011-4e9d-a6ec-20768be3a4b0

$script:CrCopilotDlpLocation = '470f2276-e011-4e9d-a6ec-20768be3a4b0'

function Get-CrDlp {
    if ($null -eq $script:CrDlp) {
        $script:CrDlp = [pscustomobject]@{ policies = @(Invoke-CrReader Get-DlpCompliancePolicy); rules = @(Invoke-CrReader Get-DlpComplianceRule) }
    }
    $script:CrDlp
}

function Test-CrCopilotDlpPolicy($p) {
    (@($p.EnforcementPlanes | Where-Object { $_ }) -contains 'CopilotExperiences') -or ("$($p.Locations)" -match $script:CrCopilotDlpLocation)
}

function Get-CrCopilotDlpRules {
    <#
      .SYNOPSIS  Rules of Copilot-location DLP policies, classified as 'label' (labelled files/emails excluded from processing)
                 or 'prompt' (sensitive information types). Pure over the passed objects; used by B01, B05 and tests.
    #>
    param([object[]]$Policies, [object[]]$Rules)
    $cp = @($Policies | Where-Object { Test-CrCopilotDlpPolicy $_ })
    foreach ($r in $Rules) {
        $pol = $cp | Where-Object { ($r.ParentPolicyName -and $_.Name -eq $r.ParentPolicyName) -or ($r.Policy -and ($_.Name -eq $r.Policy -or "$($_.Guid)" -eq "$($r.Policy)")) } | Select-Object -First 1
        if (-not $pol) { continue }
        $cond = "$($r.AdvancedRule) $($r.ContentContainsSensitiveInformation | ConvertTo-Json -Depth 8 -Compress -WarningAction SilentlyContinue)"
        $isLabel = $cond -match '"type"\s*:\s*"Sensitivity"' -or $cond -match '"labels"\s*:\s*\[\s*\{'
        # A rule may combine sensitive info types and labels in one condition: then it counts for both checks.
        $sitText = ($cond -replace '(?s)"labels"\s*:\s*\[[^\]]*\]', '')
        $isSit = $sitText -match '"sensitivetypes"\s*:\s*\[\s*\{' -or $sitText -match '"type"\s*:\s*"Sensitive' -or (-not $isLabel -and $cond -match '"(name|id)"\s*:')
        $active = [bool]$pol.Enabled -and "$($pol.Mode)" -eq 'Enable' -and -not [bool]$r.Disabled
        [pscustomobject]@{
            Policy = $pol.Name; Rule = $r.Name; Kind = $(if ($isLabel -and $isSit) { 'both' } elseif ($isLabel) { 'label' } elseif ($isSit) { 'prompt' } else { 'other' })
            Mode = "$($pol.Mode)"; Enabled = [bool]$pol.Enabled; RuleDisabled = [bool]$r.Disabled; Active = $active
            ExcludesProcessing = ("$($r.RestrictAccess | ConvertTo-Json -Compress -Depth 4 -WarningAction SilentlyContinue)" -match 'ExcludeContentProcessing')
        }
    }
}

function Get-CrDlpVerdict {
    param([object[]]$Rows, [string]$Kind)
    $mine = @($Rows | Where-Object { $_.Kind -eq $Kind -or $_.Kind -eq 'both' })
    $ok = @($mine | Where-Object { $_.Active -and ($Kind -ne 'label' -or $_.ExcludesProcessing) })
    if ($ok.Count -gt 0) { return 'Pass' }
    if ($mine.Count -gt 0) { return 'Warn' }
    'Fail'
}

function Test-CrB01 {
    Invoke-CrCheck 'B01' {
        $d = Get-CrDlp
        $rows = @(Get-CrCopilotDlpRules -Policies $d.policies -Rules $d.rules)
        $state = Get-CrDlpVerdict $rows 'prompt'
        $n = @($rows | Where-Object Kind -in 'prompt', 'both').Count
        New-CrResult B01 -State $state -Msg 'B01.rules' -Arguments @{ n = $n; copilotPolicies = @($d.policies | Where-Object { Test-CrCopilotDlpPolicy $_ }).Count } -Evidence ($rows | Where-Object Kind -in 'prompt', 'both', 'other')
    }
}

function Test-CrB05 {
    Invoke-CrCheck 'B05' {
        $d = Get-CrDlp
        $rows = @(Get-CrCopilotDlpRules -Policies $d.policies -Rules $d.rules)
        $state = Get-CrDlpVerdict $rows 'label'
        $n = @($rows | Where-Object Kind -in 'label', 'both').Count
        New-CrResult B05 -State $state -Msg 'B05.rules' -Arguments @{ n = $n; copilotPolicies = @($d.policies | Where-Object { Test-CrCopilotDlpPolicy $_ }).Count } -Evidence ($rows | Where-Object Kind -in 'label', 'both')
    }
}

function Test-CrB02 {
    Invoke-CrCheck 'B02' {
        $d = Get-CrDlp
        $on = @($d.policies | Where-Object { $_.Enabled -and "$($_.Mode)" -eq 'Enable' })
        $wl = @($on | ForEach-Object { "$($_.Workload)" -split ',\s*' } | Where-Object { $_ } | Select-Object -Unique)
        $core = @('Exchange', 'SharePoint', 'OneDriveForBusiness'); $extra = @('Teams', 'EndpointDevices')
        $ev = @($core + $extra) | ForEach-Object { [pscustomobject]@{ Workload = $_; Required = ($_ -in $core); Covered = ($wl -contains $_) } }
        $missCore = @($core | Where-Object { $wl -notcontains $_ }).Count
        $missExtra = @($extra | Where-Object { $wl -notcontains $_ }).Count
        $state = if ($missCore -eq 0) { 'Pass' } elseif ($missCore -eq 1) { 'Warn' } else { 'Fail' }
        $score = if ($state -eq 'Pass') { 100 - 10 * $missExtra } elseif ($state -eq 'Warn') { 60 } else { [int](40 - 10 * ($missCore - 2)) }
        New-CrResult B02 -State $state -Score $score -Msg 'B02.coverage' -Arguments @{ core = ($core.Count - $missCore); coreTotal = $core.Count; extra = ($extra.Count - $missExtra) } -Evidence $ev
    }
}
