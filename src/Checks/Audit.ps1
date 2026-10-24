# Audit & Nachweis — what you can prove when it matters.
# N01/N02 share one Purview audit search (the only object this tool creates in the tenant, see README).

function Start-CrAuditQuery {
    <# Submits the audit search at the start of the run, or reuses an existing one (-AuditQueryId). #>
    param([string]$ReuseId)
    $script:CrAudit = @{ id = $null; status = $null; error = $null; httpStatus = 0; reused = [bool]$ReuseId }
    try {
        if ($ReuseId) {
            $q = Invoke-CrGraph "/security/auditLog/queries/$ReuseId" -Beta
        }
        else {
            $now = Get-CrNow
            $body = @{
                '@odata.type'       = '#microsoft.graph.security.auditLogQuery'
                displayName         = "copilot-agent-readiness $($now.ToString('s'))"
                filterStartDateTime = $now.AddDays(-7).ToString('o')
                filterEndDateTime   = $now.ToString('o')
                recordTypeFilters   = @('copilotInteraction')
            }
            $q = Invoke-CrGraph '/security/auditLog/queries' -Beta -Method POST -Body $body
            Write-Host ('  ' + ((Get-CrConsoleText 'console.auditSubmitted') -replace '\{id\}', "$($q.id)")) -ForegroundColor DarkGray
        }
        $script:CrAudit.id = $q.id; $script:CrAudit.status = "$($q.status)"
    }
    catch { $script:CrAudit.error = "$($_.Exception.Message) $($_.ErrorDetails.Message)"; $script:CrAudit.httpStatus = Get-CrHttpStatus $_ }
}

function Wait-CrAuditQuery {
    param([int]$TimeoutSec = 240)
    if (-not $script:CrAudit) { Start-CrAuditQuery }
    $a = $script:CrAudit
    if ($a.error -or $a.waited) { return $a }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($a.status -notin @('succeeded', 'failed', 'cancelled') -and (Get-Date) -lt $deadline) {
        if (-not $script:CrDemoData) { Start-Sleep -Seconds 15 }
        try { $a.status = "$((Invoke-CrGraph "/security/auditLog/queries/$($a.id)" -Beta).status)" } catch { $a.error = "$($_.Exception.Message)"; $a.httpStatus = Get-CrHttpStatus $_; break }
        if ($script:CrDemoData) { break }
    }
    $a.waited = $true
    $a
}

function Get-CrAuditState {
    <#
      .SYNOPSIS  Pure mapping of the audit search outcome to a state. Used by N01/N02 and tests.
                 succeeded → Pass · audit-off message → Fail · 401/403 → NoPermission · failed/cancelled/running/other → Unknown
    #>
    param([hashtable]$Audit)
    if ($Audit.error) {
        if ($Audit.error -match 'not enabled|is disabled|turn on|UnifiedAuditLogIngestionEnabled') { return 'Fail' }
        if ($Audit.httpStatus -in 401, 403) { return 'NoPermission' }
        return 'Unknown'
    }
    if ($Audit.status -eq 'succeeded') { return 'Pass' }
    'Unknown'
}

function Test-CrN01 {
    Invoke-CrCheck 'N01' {
        $a = Wait-CrAuditQuery
        $state = Get-CrAuditState $a
        $msg = switch ($state) { 'Pass' { 'N01.ok' } 'Fail' { 'N01.off' } 'NoPermission' { 'gen.noPermission' } default { if ($a.error) { 'N01.error' } elseif ($a.status -in 'failed', 'cancelled') { 'N01.failed' } else { 'N01.pending' } } }
        New-CrResult N01 -State $state -Msg $msg -Arguments @{ status = $(if ($state -eq 'NoPermission') { $a.httpStatus } else { "$($a.status)" }); id = "$($a.id)" } -Detail "$($a.error)" `
            -Evidence @([pscustomobject]@{ Evidence = 'Graph audit search'; Status = $a.status; QueryId = $a.id; Reused = $a.reused })
    }
}

function Test-CrN02 {
    Invoke-CrCheck 'N02' {
        $a = Wait-CrAuditQuery
        $state = Get-CrAuditState $a
        if ($state -ne 'Pass') {
            $s = if ($state -eq 'Fail') { 'Unknown' } else { $state }
            return New-CrResult N02 -State $s -Msg $(if ($s -eq 'NoPermission') { 'gen.noPermission' } else { 'N02.noSearch' }) -Arguments @{ status = $(if ($s -eq 'NoPermission') { $a.httpStatus } else { "$($a.status)" }); id = "$($a.id)" }
        }
        $recs = @(Invoke-CrGraph "/security/auditLog/queries/$($a.id)/records?`$top=999" -Beta -All)
        if ($recs.Count -eq 0) {
            if (-not (Test-CrHasCopilot)) { return New-CrResult N02 -State NotApplicable -Msg 'N02.noLicence' }
            return New-CrResult N02 -State Warn -Score 50 -Msg 'N02.none'
        }
        $byApp = $recs | Group-Object { $_.auditData.CopilotEventData.AppHost ?? $_.auditData.AppHost ?? 'unknown' } | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ App = $_.Name; Interactions = $_.Count } }
        $agents = @($recs | Where-Object { $_.auditData.AgentId -or $_.auditData.CopilotEventData.AgentId }).Count
        $users = @($recs.userPrincipalName | Select-Object -Unique).Count
        # Interactions without a Copilot licence are Copilot Chat, which needs none. Saying only
        # "Copilot interactions logged" next to S01's "no Copilot licence" reads as a contradiction.
        $msg = if (Test-CrHasCopilot) { 'N02.records' } else { 'N02.recordsNoLicence' }
        New-CrResult N02 -State Pass -Msg $msg -Arguments @{ n = $recs.Count; users = $users; agents = $agents } -Evidence $byApp
    }
}

function Test-CrN03 {
    Invoke-CrCheck 'N03' {
        $plans = @(Get-CrSkus | ForEach-Object { $_.servicePlans.servicePlanName } | Select-Object -Unique)
        $p2 = $plans -contains 'AAD_PREMIUM_P2'; $p1 = $plans -contains 'AAD_PREMIUM'
        $days = if ($p1 -or $p2) { 30 } else { 7 }
        $ev = @([pscustomobject]@{ Item = 'AAD_PREMIUM'; Present = $p1 }, [pscustomobject]@{ Item = 'AAD_PREMIUM_P2'; Present = $p2 }, [pscustomobject]@{ Item = 'retentionDays'; Present = $days })
        New-CrResult N03 -State Info -Msg 'N03.days' -Arguments @{ days = $days } -Evidence $ev
    }
}

function Test-CrN04 {
    Invoke-CrCheck 'N04' {
        $a = @(Invoke-CrReader Get-ProtectionAlert | Where-Object { -not $_.IsSystemRule })
        $dlp = @($a | Where-Object { "$($_.Category)" -match 'DataLossPrevention|DataGovernance' -or "$($_.ThreatType)" -match 'Dlp' })
        $dlpOn = @($dlp | Where-Object { -not $_.Disabled })
        $ev = $a | Select-Object -First 30 | ForEach-Object { [pscustomobject]@{ Alert = $_.Name; Category = "$($_.Category)"; Severity = "$($_.Severity)"; Disabled = [bool]$_.Disabled; Notify = (@($_.NotifyUser) -join ', ') } }
        $state = if ($dlpOn.Count -gt 0) { 'Pass' } elseif ($dlp.Count -gt 0 -or @($a | Where-Object { -not $_.Disabled }).Count -gt 0) { 'Warn' } else { 'Fail' }
        New-CrResult N04 -State $state -Msg 'N04.alerts' -Arguments @{ n = $a.Count; dlp = $dlp.Count; dlpOn = $dlpOn.Count } -Evidence $ev
    }
}

function Test-CrCopilotRetentionPolicy($p) {
    # The Copilot location is read from the policy's location fields, never from its name.
    # New location "Microsoft Copilot experiences" (Get-AppRetentionCompliancePolicy, Applications "User:M365Copilot");
    # older "Teams chats and Copilot interactions" policies (TeamsChatLocation) still apply to Copilot (Microsoft Learn).
    if ("$($p.Applications)" -match 'Copilot') { return $true }
    if (@($p.TeamsChatLocation | Where-Object { $_ }).Count -gt 0) { return $true }
    [bool](@($p.PSObject.Properties | Where-Object { $_.Name -match 'Copilot' -and $_.Name -notmatch 'Exception' -and $_.Value -and "$($_.Value)" -notin '', 'False', '{}' }).Count)
}

function Get-CrRetentionRows {
    <# Pure: one row per Copilot retention policy with distribution, rule and duration. #>
    param([object[]]$Policies, [object[]]$Rules)
    foreach ($p in @($Policies | Where-Object { Test-CrCopilotRetentionPolicy $_ })) {
        $r = @($Rules | Where-Object { ($_.Policy -and ("$($_.Policy)" -eq "$($p.Guid)" -or "$($_.Policy)" -eq $p.Name)) -or ($_.ParentPolicyName -and $_.ParentPolicyName -eq $p.Name) }) | Select-Object -First 1
        [pscustomobject]@{
            Policy = $p.Name; Enabled = [bool]$p.Enabled; Distribution = "$($p.DistributionStatus)"
            Rule = $(if ($r) { $r.Name } else { $null }); Duration = $(if ($r) { "$($r.RetentionDuration)" } else { $null }); Action = $(if ($r) { "$($r.RetentionComplianceAction)" } else { $null })
            Effective = ([bool]$p.Enabled -and "$($p.DistributionStatus)" -eq 'Success' -and $null -ne $r -and "$($r.RetentionDuration)" -ne '')
        }
    }
}

function Test-CrB03 {
    Invoke-CrCheck 'B03' {
        $pol = @(Invoke-CrReader Get-RetentionCompliancePolicy @{ DistributionDetail = $true })
        $rules = @(Invoke-CrReader Get-RetentionComplianceRule)
        # The newer locations live behind the App* cmdlets; older module versions may not expose them.
        try {
            $pol += @(Invoke-CrReader Get-AppRetentionCompliancePolicy @{ DistributionDetail = $true })
            $rules += @(Invoke-CrReader Get-AppRetentionComplianceRule)
        }
        catch { Write-Verbose "B03: app retention cmdlets not available: $($_.Exception.Message)" }
        $rows = @(Get-CrRetentionRows -Policies $pol -Rules $rules)
        $eff = @($rows | Where-Object Effective).Count
        $state = if ($eff -gt 0) { 'Pass' } elseif ($rows.Count -gt 0) { 'Warn' } else { 'Fail' }
        New-CrResult B03 -State $state -Msg 'B03.retention' -Arguments @{ n = $rows.Count; effective = $eff; all = $pol.Count } -Evidence $rows
    }
}
