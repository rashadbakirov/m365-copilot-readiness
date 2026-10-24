# Oversharing & Zugriff — what Copilot and agents can find.

function Test-CrS01 {
    Invoke-CrCheck 'S01' {
        $cp = Get-CrCopilotSkus
        if ($cp.Count -eq 0) { return New-CrResult S01 -State NotLicensed -Msg 'S01.none' }
        $ev = foreach ($s in $cp) { [pscustomobject]@{ SKU = $s.skuPartNumber; Enabled = [int]$s.prepaidUnits.enabled; Assigned = [int]$s.consumedUnits; Free = [int]$s.prepaidUnits.enabled - [int]$s.consumedUnits } }
        $assigned = [int]($cp | Measure-Object consumedUnits -Sum).Sum
        $enabled = [int]($cp.prepaidUnits | Measure-Object enabled -Sum).Sum
        if ($assigned -eq 0) { return New-CrResult S01 -State Warn -Score 50 -Msg 'S01.unassigned' -Arguments @{ enabled = $enabled } -Evidence $ev }
        $ids = @($cp.skuId | Where-Object { $_ })
        $users = foreach ($id in $ids) {
            Invoke-CrGraph "/users?`$filter=assignedLicenses/any(x:x/skuId eq $id)&`$select=id,displayName,userPrincipalName,licenseAssignmentStates&`$top=999" -All -Headers @{ ConsistencyLevel = 'eventual' }
        }
        $users = @($users | Where-Object { $_ } | Sort-Object id -Unique)
        # Licences are consumed but no holder is readable: that is a failed read, not "all assigned via groups".
        if ($users.Count -eq 0) { return New-CrResult S01 -State Unknown -Msg 'gen.empty' -Arguments @{ assigned = $assigned; enabled = $enabled } -Evidence $ev -Detail "$assigned licences consumed, but the licence-holder query returned no users" }
        $direct = @($users | Where-Object { @($_.licenseAssignmentStates | Where-Object { $_.skuId -in $ids -and -not $_.assignedByGroup }).Count -gt 0 }).Count
        $byGroup = $users.Count - $direct
        $a = @{ assigned = $assigned; enabled = $enabled; direct = $direct; group = $byGroup }
        $state = if ($direct -eq 0) { 'Pass' } elseif ($byGroup -eq 0 -and $assigned -gt 10) { 'Warn' } elseif ($direct -gt $byGroup) { 'Warn' } else { 'Pass' }
        $score = if ($state -eq 'Pass') { $(if ($direct -eq 0) { 100 } else { 85 }) } elseif ($byGroup -eq 0) { 55 } else { 65 }
        New-CrResult S01 -State $state -Score $score -Msg 'S01.assigned' -Arguments $a -Evidence $ev
    }
}

function Test-CrS02 {
    Invoke-CrCheck 'S02' {
        if (-not (Test-CrHasCopilot)) { return New-CrResult S02 -State NotApplicable -Msg 'S02.noLicence' }
        $rows = @(Invoke-CrGraph "/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D28')" -Beta -All)
        if ($rows.Count -eq 0) { return New-CrResult S02 -State Info -Msg 'S02.empty' }
        $active = @($rows | Where-Object { $_.lastActivityDate }).Count
        $apps = [ordered]@{ Teams = 'microsoftTeamsCopilotLastActivityDate'; Word = 'wordCopilotLastActivityDate'; Excel = 'excelCopilotLastActivityDate'; PowerPoint = 'powerPointCopilotLastActivityDate'; Outlook = 'outlookCopilotLastActivityDate'; OneNote = 'oneNoteCopilotLastActivityDate'; Loop = 'loopCopilotLastActivityDate'; 'Copilot Chat' = 'copilotChatLastActivityDate' }
        $ev = foreach ($k in $apps.Keys) { [pscustomobject]@{ App = $k; ActiveUsers = @($rows | Where-Object { $_.($apps[$k]) }).Count } }
        $refresh = ($rows | Select-Object -First 1).reportRefreshDate
        New-CrResult S02 -State Info -Msg 'S02.usage' -Arguments @{ active = $active; total = $rows.Count; pct = (Get-CrPct $active $rows.Count); refresh = "$refresh" } -Evidence $ev
    }
}

function Get-CrSpoSettings {
    if ($null -eq $script:CrSpoSettings) { $script:CrSpoSettings = Invoke-CrGraph '/admin/sharepoint/settings' }
    $script:CrSpoSettings
}

function Test-CrS03 {
    Invoke-CrCheck 'S03' {
        $s = Get-CrSpoSettings
        $cap = [string]$s.sharingCapability
        if (-not $cap) { return New-CrResult S03 -State Unknown -Msg 'gen.empty' }
        # Graph sharingCapabilities (Microsoft Learn, sharepointSettings): externalUserAndGuestSharing = Anyone links
        # without sign-in · externalUserSharingOnly = new and existing guests · existingExternalUserSharingOnly =
        # existing guests only · disabled = internal only. A value this version does not know is never a pass.
        $state = switch ($cap) { 'externalUserAndGuestSharing' { 'Fail' } 'externalUserSharingOnly' { 'Warn' } 'existingExternalUserSharingOnly' { 'Pass' } 'disabled' { 'Pass' } default { 'Unknown' } }
        $ev = @(
            [pscustomobject]@{ Setting = 'sharingCapability'; Value = $cap }
            [pscustomobject]@{ Setting = 'sharingDomainRestrictionMode'; Value = [string]$s.sharingDomainRestrictionMode }
            [pscustomobject]@{ Setting = 'sharingAllowedDomainList'; Value = (@($s.sharingAllowedDomainList | Where-Object { $_ }) -join ', ') }
            [pscustomobject]@{ Setting = 'sharingBlockedDomainList'; Value = (@($s.sharingBlockedDomainList | Where-Object { $_ }) -join ', ') }
        )
        $known = 'externalUserAndGuestSharing', 'externalUserSharingOnly', 'existingExternalUserSharingOnly', 'disabled'
        New-CrResult S03 -State $state -Score $(if ($state -eq 'Warn') { 60 } else { -1 }) -Msg $(if ($cap -in $known) { "S03.$cap" } else { 'S03.other' }) -Arguments @{ value = $cap } -Evidence $ev
    }
}

function Test-CrS04 {
    Invoke-CrCheck 'S04' {
        $s = Get-CrSpoSettings
        $rows = @(
            @{ k = 'isResharingByExternalUsersEnabled'; want = $false }
            @{ k = 'isLegacyAuthProtocolsEnabled'; want = $false }
            @{ k = 'isUnmanagedSyncAppForTenantRestricted'; want = $true }
            @{ k = 'isRequireAcceptingUserToMatchInvitedUserEnabled'; want = $true }
        )
        $bad = 0; $unknown = 0
        $ev = foreach ($r in $rows) {
            $v = $s.($r.k)
            $ok = if ($null -eq $v) { $unknown++; $null } else { $v -eq $r.want }
            if ($ok -eq $false) { $bad++ }
            [pscustomobject]@{ Setting = $r.k; Value = $v; Recommended = $r.want; OK = $ok }
        }
        if ($unknown -eq $rows.Count) { return New-CrResult S04 -State Unknown -Msg 'gen.empty' -Evidence $ev }
        $state = if ($bad -eq 0) { 'Pass' } elseif ($bad -le 2) { 'Warn' } else { 'Fail' }
        New-CrResult S04 -State $state -Score ([int](100 - 25 * $bad)) -Msg 'S04.deviations' -Arguments @{ bad = $bad; total = $rows.Count - $unknown; unknown = $unknown } -Evidence $ev
    }
}

function Get-CrM365Groups {
    if ($null -eq $script:CrM365Groups) {
        $script:CrM365Groups = @(Invoke-CrGraph "/groups?`$filter=groupTypes/any(c:c eq 'Unified')&`$select=id,displayName,visibility,mail,mailNickname,createdDateTime,creationOptions,resourceProvisioningOptions&`$top=999" -All)
    }
    $script:CrM365Groups
}

function Test-CrSystemGroup($Group) {
    <# Pure: the two groups Viva Engage provisions in every network — "All Company" and the Answers backing
       group ("Group for Answers in Viva Engage – DO NOT DELETE …"). Both are public by design: setting All
       Company to private stops users from seeing it (Microsoft Learn, "All Company community configuration").
       They are listed as evidence but never counted as oversharing, otherwise every small tenant with Viva
       Engage starts with a red S05. Recognised by Microsoft's own creationOptions marker plus the fixed
       mail nickname / name, so a user-created public community is still counted. #>
    $yammer = @($Group.creationOptions) -contains 'YammerProvisioning'
    [bool]($yammer -and ("$($Group.mailNickname)" -eq 'allcompany' -or "$($Group.displayName)" -like 'Group for Answers in Viva Engage*'))
}

function Test-CrS05 {
    Invoke-CrCheck 'S05' {
        $g = Get-CrM365Groups
        if ($g.Count -eq 0) { return New-CrResult S05 -State NotApplicable -Msg 'S05.none' }
        $system = @($g | Where-Object { Test-CrSystemGroup $_ })
        $scored = @($g | Where-Object { -not (Test-CrSystemGroup $_) })
        $row = { param($x, [bool]$sys) [pscustomobject]@{ Group = $x.displayName; Mail = $x.mail; Team = ($x.resourceProvisioningOptions -contains 'Team'); Created = (Get-CrDateText $x.createdDateTime); System = $sys } }
        $sysRows = @($system | Where-Object { $_.visibility -eq 'Public' } | Sort-Object displayName | ForEach-Object { & $row $_ $true })
        if ($scored.Count -eq 0) { return New-CrResult S05 -State NotApplicable -Msg 'S05.onlySystem' -Arguments @{ system = $system.Count } -Evidence $sysRows }
        $pub = @($scored | Where-Object { $_.visibility -eq 'Public' })
        $pct = Get-CrPct $pub.Count $scored.Count
        $state = if ($pub.Count -eq 0) { 'Pass' } elseif ($pct -le 10) { 'Warn' } else { 'Fail' }
        $ev = @($pub | Sort-Object displayName | Select-Object -First 50 | ForEach-Object { & $row $_ $false }) + $sysRows
        $msg = if ($system.Count -gt 0) { 'S05.publicSystem' } else { 'S05.public' }
        New-CrResult S05 -State $state -Score ([int][Math]::Max(0, 100 - 3 * $pct)) -Msg $msg -Arguments @{ n = $pub.Count; total = $scored.Count; pct = $pct; system = $system.Count } -Evidence $ev
    }
}

function Test-CrS06 {
    Invoke-CrCheck 'S06' {
        $g = Get-CrM365Groups
        if ($g.Count -eq 0) { return New-CrResult S06 -State NotApplicable -Msg 'S05.none' }
        $res = Invoke-CrGraphBatch -Urls @($g | ForEach-Object { "/groups/$($_.id)/owners?`$select=id&`$top=1" })
        $ownerless = New-Object System.Collections.Generic.List[object]
        $failed = 0
        for ($i = 0; $i -lt $g.Count; $i++) {
            if ($res[$i].status -ne 200) { $failed++; continue }
            if (@($res[$i].body.value).Count -eq 0) { $ownerless.Add($g[$i]) }
        }
        $known = $g.Count - $failed
        $a = @{ n = $ownerless.Count; known = $known; total = $g.Count; failed = $failed }
        $ev = $ownerless | Select-Object -First 50 | ForEach-Object { [pscustomobject]@{ Group = $_.displayName; Mail = $_.mail } }
        if ($known -eq 0 -or $failed -gt [Math]::Max(1, 0.1 * $g.Count)) { return New-CrResult S06 -State Unknown -Msg 'S06.partial' -Arguments $a -Evidence $ev }
        $pct = Get-CrPct $ownerless.Count $known
        $state = if ($ownerless.Count -eq 0) { 'Pass' } elseif ($pct -le 5) { 'Warn' } else { 'Fail' }
        New-CrResult S06 -State $state -Score ([int][Math]::Max(0, 100 - 5 * $pct)) -Msg 'S06.ownerless' -Arguments $a -Evidence $ev
    }
}

function Test-CrS07 {
    Invoke-CrCheck 'S07' {
        $rows = @(Invoke-CrGraphReport "/reports/getSharePointSiteUsageDetail(period='D180')" | Where-Object { "$($_.isDeleted)" -ne 'True' })
        if ($rows.Count -eq 0) { return New-CrResult S07 -State Unknown -Msg 'gen.empty' }
        $concealed = 'unknown'
        if (Test-CrScope 'ReportSettings.Read.All') {
            try { $concealed = if ((Invoke-CrGraph '/admin/reportSettings').displayConcealedNames) { 'yes' } else { 'no' } } catch { $concealed = 'unknown' }
        }
        $cut = (Get-CrNow).AddDays(-180)
        $inactive = @($rows | Where-Object { -not $_.lastActivityDate -or ([datetime]$_.lastActivityDate) -lt $cut })
        $top = $rows | Sort-Object { [long]($_.fileCount -as [long]) } -Descending | Select-Object -First 15 | ForEach-Object {
            [pscustomobject]@{
                Site = $(if ("$($_.siteUrl)" -match '^https?://') { $_.siteUrl } else { '(concealed)' })
                Files = [long]($_.fileCount -as [long]); ActiveFiles = [long]($_.activeFileCount -as [long])
                LastActivity = (Get-CrDateText $_.lastActivityDate); StorageGB = [Math]::Round([double]($_.storageUsedInBytes -as [double]) / 1GB, 1)
            }
        }
        $pct = Get-CrPct $inactive.Count $rows.Count
        $state = if ($pct -le 20) { 'Pass' } elseif ($pct -le 40) { 'Warn' } else { 'Fail' }
        New-CrResult S07 -State $state -Score ([int][Math]::Max(0, 100 - 2 * $pct)) -Msg 'S07.inactive' -Arguments @{ n = $inactive.Count; total = $rows.Count; pct = $pct; concealed = $concealed } -Evidence $top
    }
}

function Test-CrS08 {
    Invoke-CrCheck 'S08' {
        $rows = @(Invoke-CrGraphReport "/reports/getSharePointActivityUserDetail(period='D30')")
        if ($rows.Count -eq 0) { return New-CrResult S08 -State Unknown -Msg 'gen.empty' }
        # "Active users" means what it says: not deleted, and with activity in the period.
        $rows = @($rows | Where-Object { "$($_.isDeleted)" -ne 'True' -and $_.lastActivityDate })
        if ($rows.Count -eq 0) { return New-CrResult S08 -State NotApplicable -Msg 'S08.noActive' }
        $ext = @($rows | Where-Object { [int]($_.sharedExternallyFileCount -as [int]) -gt 0 })
        $sumExt = [int](($ext | ForEach-Object { [int]($_.sharedExternallyFileCount -as [int]) } | Measure-Object -Sum).Sum)
        $top = $ext | Sort-Object { [int]($_.sharedExternallyFileCount -as [int]) } -Descending | Select-Object -First 20 | ForEach-Object {
            [pscustomobject]@{ User = $_.userPrincipalName; SharedExternally = [int]($_.sharedExternallyFileCount -as [int]); SharedInternally = [int]($_.sharedInternallyFileCount -as [int]); LastActivity = (Get-CrDateText $_.lastActivityDate) }
        }
        $pctUsers = Get-CrPct $ext.Count $rows.Count
        $state = if ($sumExt -eq 0) { 'Pass' } elseif ($pctUsers -le 5) { 'Warn' } else { 'Fail' }
        New-CrResult S08 -State $state -Score ([int][Math]::Max(0, 100 - 4 * $pctUsers)) -Msg 'S08.external' -Arguments @{ users = $ext.Count; files = $sumExt; active = $rows.Count } -Evidence $top
    }
}

function Test-CrS09 {
    Invoke-CrCheck 'S09' {
        $guests = $null
        try { $guests = @(Invoke-CrGraph "/users?`$filter=userType eq 'Guest'&`$select=id,displayName,mail,createdDateTime,signInActivity&`$top=999" -All) }
        catch {
            # Only a refused signInActivity read means "needs Entra ID P1 / AuditLog.Read.All"; an outage is just Unknown.
            if ((Get-CrHttpStatus $_) -ge 500) { throw }
            $plain = @(Invoke-CrGraph "/users?`$filter=userType eq 'Guest'&`$select=id,displayName,mail,createdDateTime&`$top=999" -All)
            if ($plain.Count -eq 0) { return New-CrResult S09 -State NotApplicable -Msg 'S09.none' }
            return New-CrResult S09 -State Unknown -Msg 'S09.noSignIn' -Arguments @{ total = $plain.Count } -Detail "$($_.Exception.Message)"
        }
        if ($guests.Count -eq 0) { return New-CrResult S09 -State NotApplicable -Msg 'S09.none' }
        $cut = (Get-CrNow).AddDays(-90)
        $last = { param($u) $u.signInActivity.lastSuccessfulSignInDateTime ?? $u.signInActivity.lastSignInDateTime }
        # A guest invited within the last 90 days who has not signed in yet is new, not stale.
        $stale = @($guests | Where-Object { $d = & $last $_; if ($d) { (ConvertTo-CrUtc $d) -lt $cut } else { -not $_.createdDateTime -or (ConvertTo-CrUtc $_.createdDateTime) -lt $cut } })
        $pct = Get-CrPct $stale.Count $guests.Count
        $state = if ($pct -le 20) { 'Pass' } elseif ($pct -le 50) { 'Warn' } else { 'Fail' }
        $ev = $stale | Select-Object -First 50 | ForEach-Object { [pscustomobject]@{ Guest = $_.displayName; Mail = $_.mail; Created = (Get-CrDateText $_.createdDateTime); LastSignIn = (Get-CrDateText (& $last $_)) } }
        New-CrResult S09 -State $state -Score ([int][Math]::Max(0, 100 - 1.5 * $pct)) -Msg 'S09.stale' -Arguments @{ n = $stale.Count; total = $guests.Count; pct = $pct } -Evidence $ev
    }
}

function Test-CrS11 {
    Invoke-CrCheck 'S11' {
        if (-not (Test-CrHasCopilot)) { return New-CrResult S11 -State NotLicensed -Msg 'S11.noCopilot' }
        $sites = @(Invoke-CrReader Get-SPOSite @{ Limit = 'All' } | Where-Object { "$($_.Url)" -notmatch '-my\.sharepoint\.com' })
        if ($sites.Count -eq 0) { return New-CrResult S11 -State Unknown -Msg 'gen.empty' }
        $withProps = @($sites | Where-Object { $null -ne $_.RestrictContentOrgWideSearch -or $null -ne $_.RestrictedAccessControl })
        if ($withProps.Count -eq 0) { return New-CrResult S11 -State Unknown -Msg 'S11.noProps' -Arguments @{ total = $sites.Count } }
        $rcd = @($sites | Where-Object { $_.RestrictContentOrgWideSearch -eq $true })
        $rac = @($sites | Where-Object { $_.RestrictedAccessControl -eq $true })
        $rcdOnly = @($rcd | Where-Object { $_.RestrictedAccessControl -ne $true })
        $ev = @(@($rcd | Where-Object { $_ }) + @($rac | Where-Object { $_ }) | Sort-Object Url -Unique | Select-Object -First 50 | ForEach-Object {
                [pscustomobject]@{ Site = $_.Url; RCD = [bool]$_.RestrictContentOrgWideSearch; RAC = [bool]$_.RestrictedAccessControl; RacGroups = @($_.RestrictedAccessControlGroups | Where-Object { $_ }).Count; Label = $_.SensitivityLabel }
            })
        $a = @{ rcd = $rcd.Count; rac = $rac.Count; total = $sites.Count; rcdOnly = $rcdOnly.Count }
        $state = if ($rac.Count -gt 0) { 'Pass' } else { 'Warn' }
        $score = if ($rac.Count -gt 0) { 100 } elseif ($rcd.Count -gt 0) { 70 } else { 50 }
        New-CrResult S11 -State $state -Score $score -Msg $(if ($rcd.Count + $rac.Count -eq 0) { 'S11.none' } else { 'S11.used' }) -Arguments $a -Evidence $ev
    }
}

function Get-CrDagLatest {
    <# Latest existing data access governance report of one kind. Never starts a report. #>
    param([string]$Entity)
    $all = @(Invoke-CrReader Get-SPODataAccessGovernanceInsight @{ ReportEntity = $Entity })
    $done = @($all | Where-Object { "$($_.Status)" -eq 'Completed' -and $_.CreatedDateTime } | Sort-Object { ConvertTo-CrUtc $_.CreatedDateTime } -Descending)
    [pscustomobject]@{ entity = $Entity; all = $all; latest = ($done | Select-Object -First 1); running = @($all | Where-Object { "$($_.Status)" -ne 'Completed' }).Count }
}

function Test-CrS12 {
    Invoke-CrCheck 'S12' {
        $kinds = @('PermissionedUsers', 'EveryoneExceptExternalUsersAtSite', 'SharingLinks_Anyone')
        $found = foreach ($k in $kinds) { Get-CrDagLatest $k }
        $ev = foreach ($f in $found) {
            $l = $f.latest
            [pscustomobject]@{ Report = $f.entity; Status = $(if ($l) { 'Completed' } elseif ($f.running) { 'Running' } else { 'None' }); Created = (Get-CrDateText $l.CreatedDateTime); AgeDays = (Get-CrAgeDays $l.CreatedDateTime); Sites = $(if ($l) { $l.CountOfSitesInReport ?? $l.SitesFound } else { $null }) }
        }
        $perm = $found | Where-Object entity -eq 'PermissionedUsers'
        if (-not $perm.latest) { return New-CrResult S12 -State Fail -Msg 'S12.none' -Evidence $ev }
        $age = Get-CrAgeDays $perm.latest.CreatedDateTime
        $state = if ($age -le 35) { 'Pass' } else { 'Warn' }
        $score = if ($age -le 35) { 100 } elseif ($age -le 90) { 65 } else { 50 }
        New-CrResult S12 -State $state -Score $score -Msg 'S12.age' -Arguments @{ age = $age; sites = ($perm.latest.CountOfSitesInReport ?? $perm.latest.SitesFound) } -Evidence $ev
    }
}
