# Identität für KI — who may sign in, act and consent on behalf of users.

$script:CrGaRole = '62e90394-69f5-4237-9190-012177145e10'
# Built-in privileged Entra roles (role template ids) that steer Copilot, agents, data or identities.
$script:CrPrivilegedRoles = @{
    '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'
    'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator'
    '7be44c8a-adaf-4e2a-84d6-ab2649e08a13' = 'Privileged Authentication Administrator'
    '194ae4cb-b126-40b2-bd5b-6091b380977d' = 'Security Administrator'
    'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9' = 'Conditional Access Administrator'
    '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3' = 'Application Administrator'
    '158c047a-c907-4556-b7ef-446551a6b5f7' = 'Cloud Application Administrator'
    'f28a1f50-f6e7-4571-818b-6a12f2af6b6c' = 'SharePoint Administrator'
    '29232cdf-9323-42fd-ade2-1d097af3e4de' = 'Exchange Administrator'
    '17315797-102d-40b4-93e0-432062caca18' = 'Compliance Administrator'
    'fe930be7-5e62-47db-91af-98c3a49a38b1' = 'User Administrator'
}
# Built-in authentication strength "Phishing-resistant MFA"; custom strengths count when they only allow these methods.
$script:CrPhishResistantStrength = '00000000-0000-0000-0000-000000000004'
$script:CrPhishResistantMethods = @('windowsHelloForBusiness', 'fido2', 'x509CertificateMultiFactor', 'passKey', 'platformCredential')

function Get-CrSecurityDefaults {
    if ($null -eq $script:CrSecDefaults) { $script:CrSecDefaults = [bool](Invoke-CrGraph '/policies/identitySecurityDefaultsEnforcementPolicy').isEnabled }
    $script:CrSecDefaults
}

function Get-CrCaPolicies {
    if ($null -eq $script:CrCa) { $script:CrCa = @(Invoke-CrGraph '/identity/conditionalAccess/policies' -All) }
    $script:CrCa
}

# Built-in strengths: ...0002 Multifactor, ...0003 Passwordless MFA, ...0004 Phishing-resistant MFA.
$script:CrMfaStrengths = @('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000004')
# Methods that are multifactor on their own; any other combination needs a second factor ("password,sms").
$script:CrMfaAloneMethods = @('windowsHelloForBusiness', 'fido2', 'x509CertificateMultiFactor', 'deviceBasedPush', 'temporaryAccessPassOneTime', 'temporaryAccessPassMultiUse', 'federatedMultiFactor', 'passKey', 'platformCredential', 'qrCodePin')
# Microsoft's Directory Synchronization Accounts role: Microsoft's own CA guides tell you to exclude it.
$script:CrDirSyncRole = 'd29b2b05-8046-44ba-8758-1e26182fcf32'

function Test-CrPhishResistant($Strength) {
    # By id or by the allowed methods — never by display name (a custom strength can be named anything).
    if (-not $Strength) { return $false }
    if ("$($Strength.id)" -eq $script:CrPhishResistantStrength) { return $true }
    $combos = @($Strength.allowedCombinations | Where-Object { $_ })
    $combos.Count -gt 0 -and -not ($combos | Where-Object { $parts = "$_" -split ','; ($parts | Where-Object { $_ -notin $script:CrPhishResistantMethods }).Count -gt 0 })
}

function Test-CrMfaStrength($Strength) {
    <# Pure: does an authentication strength demand a second factor? A custom strength that allows "password"
       or "sms" alone does not. Unknown shape (no id we know, no combinations) is given the benefit of the doubt. #>
    if (-not $Strength) { return $false }
    if ("$($Strength.id)" -in $script:CrMfaStrengths) { return $true }
    $combos = @($Strength.allowedCombinations | Where-Object { $_ })
    if ($combos.Count -eq 0) { return $true }
    -not ($combos | Where-Object { "$_" -notmatch ',' -and "$_" -notin $script:CrMfaAloneMethods })
}

function Get-CrCaEvaluation {
    <#
      .SYNOPSIS  Evaluates one Conditional Access policy for one control goal. Pure function, unit-tested.
                 Returns Coverage 'full' | 'partial' | 'none' and the reasons. Report-only or disabled policies are never 'full'.
      .PARAMETER Kind  mfa | legacy | device | signInRisk | userRisk | adminPhish
    #>
    param([Parameter(Mandatory)]$Policy, [Parameter(Mandatory)][ValidateSet('mfa', 'legacy', 'device', 'signInRisk', 'userRisk', 'adminPhish')][string]$Kind, [int]$MaxExcludedUsers = 2, [int]$MaxExcludedGroups = 1)
    $c = $Policy.conditions; $g = $Policy.grantControls
    $u = $c.users; $apps = $c.applications
    $controls = @($g.builtInControls | Where-Object { $_ })
    $reasons = New-Object System.Collections.Generic.List[string]

    # 1. does the grant do what this goal needs?
    $isMfa = $controls -contains 'mfa' -or (Test-CrMfaStrength $g.authenticationStrength)
    $relevant = switch ($Kind) {
        'mfa' { $isMfa }
        'legacy' { $controls -contains 'block' -and (@($c.clientAppTypes | Where-Object { $_ }) -contains 'exchangeActiveSync' -or @($c.clientAppTypes | Where-Object { $_ }) -contains 'other') }
        'device' { $controls -contains 'compliantDevice' -or $controls -contains 'domainJoinedDevice' }
        'signInRisk' { @($c.signInRiskLevels | Where-Object { $_ -in 'high', 'medium' }).Count -gt 0 -and ($isMfa -or $controls -contains 'block') }
        'userRisk' { @($c.userRiskLevels | Where-Object { $_ }) -contains 'high' -and ($controls -contains 'passwordChange' -or $controls -contains 'block') }
        'adminPhish' { Test-CrPhishResistant $g.authenticationStrength }
    }
    if (-not $relevant) { return [pscustomobject]@{ Policy = $Policy.displayName; Coverage = 'none'; Reasons = 'not this control' } }
    if ($Kind -eq 'signInRisk' -and @($c.signInRiskLevels | Where-Object { $_ -in 'high', 'medium' }).Count -lt 2) { $reasons.Add('not both medium and high sign-in risk') }

    # 2. is it on? A disabled policy protects nobody; report-only at least shows intent (partial).
    if ($Policy.state -eq 'disabled') { return [pscustomobject]@{ Policy = $Policy.displayName; Coverage = 'none'; Reasons = 'disabled' } }
    if ($Policy.state -ne 'enabled') { $reasons.Add("state $($Policy.state)") }

    # 3. who is in scope?
    if ($Kind -eq 'adminPhish') {
        $roles = @($u.includeRoles | Where-Object { $_ })
        $hasAll = @($u.includeUsers | Where-Object { $_ }) -contains 'All'
        $hasGa = $roles -contains $script:CrGaRole
        if (-not $hasAll -and -not $hasGa) { $reasons.Add('Global Administrator not included') }
        $missing = @($script:CrPrivilegedRoles.Keys | Where-Object { $_ -notin $roles })
        if (-not $hasAll -and $missing.Count -gt 6) { $reasons.Add("only $($roles.Count) admin roles included") }
    }
    elseif (@($u.includeUsers | Where-Object { $_ }) -notcontains 'All') { $reasons.Add('not all users') }
    $exU = @($u.excludeUsers | Where-Object { $_ -and $_ -ne 'GuestsOrExternalUsers' }).Count
    $exG = @($u.excludeGroups | Where-Object { $_ }).Count
    if ($exU -gt $MaxExcludedUsers) { $reasons.Add("$exU users excluded") }
    if ($exG -gt $MaxExcludedGroups) { $reasons.Add("$exG groups excluded") }
    if (@($u.excludeRoles | Where-Object { $_ -and $_ -ne $script:CrDirSyncRole }).Count -gt 0 -and $Kind -ne 'adminPhish') { $reasons.Add('roles excluded') }
    if ($Kind -eq 'adminPhish' -and (@($u.excludeRoles | Where-Object { $_ }) | Where-Object { $_ -in $script:CrPrivilegedRoles.Keys })) { $reasons.Add('admin roles excluded') }

    # 4. which apps?
    $inc = @($apps.includeApplications | Where-Object { $_ })
    $appsOk = switch ($Kind) { 'device' { $inc -contains 'All' -or $inc -contains 'Office365' } default { $inc -contains 'All' } }
    if (-not $appsOk) { $reasons.Add('not all resources') }
    if (@($apps.excludeApplications | Where-Object { $_ }).Count -gt 0) { $reasons.Add("$(@($apps.excludeApplications | Where-Object { $_ }).Count) apps excluded") }

    # 5. narrowing conditions
    $cat = @($c.clientAppTypes | Where-Object { $_ })
    if ($Kind -eq 'legacy') {
        if (-not ($cat -contains 'exchangeActiveSync' -and $cat -contains 'other')) { $reasons.Add('only one legacy client type') }
    }
    elseif ($cat.Count -gt 0 -and $cat -notcontains 'all' -and -not ($cat -contains 'browser' -and $cat -contains 'mobileAppsAndDesktopClients')) { $reasons.Add('limited client apps') }
    if ($c.platforms -and @($c.platforms.includePlatforms | Where-Object { $_ }) -notcontains 'all') { $reasons.Add('limited platforms') }
    if ($c.locations -and @($c.locations.includeLocations | Where-Object { $_ }) -notcontains 'All') { $reasons.Add('limited locations') }
    if ($c.platforms -and @($c.platforms.excludePlatforms | Where-Object { $_ }).Count -gt 0) { $reasons.Add('platforms excluded') }
    if ($c.locations -and @($c.locations.excludeLocations | Where-Object { $_ }).Count -gt 0) { $reasons.Add('locations excluded') }
    if ($Kind -eq 'signInRisk' -and @($c.userRiskLevels | Where-Object { $_ }).Count -gt 0) { $reasons.Add('also limited by user risk') }
    if ($Kind -eq 'userRisk' -and @($c.signInRiskLevels | Where-Object { $_ }).Count -gt 0) { $reasons.Add('also limited by sign-in risk') }
    if ($Kind -in 'mfa', 'device', 'adminPhish', 'legacy' -and (@($c.signInRiskLevels | Where-Object { $_ }).Count -gt 0 -or @($c.userRiskLevels | Where-Object { $_ }).Count -gt 0)) { $reasons.Add('only for risky sign-ins') }

    # 6. OR with a weaker control lets users pick the weaker one
    if ("$($g.operator)" -eq 'OR' -and $controls.Count + [int][bool]$g.authenticationStrength -gt 1) {
        $weaker = switch ($Kind) { 'mfa' { @($controls | Where-Object { $_ -notin 'mfa' }) } 'device' { @($controls | Where-Object { $_ -notin 'compliantDevice', 'domainJoinedDevice' }) } 'adminPhish' { $controls } { $_ -in 'signInRisk', 'userRisk' } { @($controls | Where-Object { $_ -notin 'mfa', 'block', 'passwordChange' }) } default { @() } }
        if ($weaker.Count -gt 0) { $reasons.Add("OR with $($weaker -join '/')") }
    }

    [pscustomobject]@{ Policy = $Policy.displayName; Coverage = $(if ($reasons.Count -eq 0) { 'full' } else { 'partial' }); Reasons = ($reasons -join '; ') }
}

function Get-CrCaVerdict {
    <# Best coverage across all policies for one goal: Pass = one full policy, Warn = only partial, Fail = none. #>
    param([object[]]$Policies, [string]$Kind)
    $ev = @($Policies | ForEach-Object { Get-CrCaEvaluation -Policy $_ -Kind $Kind } | Where-Object Coverage -ne 'none')
    $state = if ($ev | Where-Object Coverage -eq 'full') { 'Pass' } elseif ($ev.Count -gt 0) { 'Warn' } else { 'Fail' }
    [pscustomobject]@{ State = $state; Full = @($ev | Where-Object Coverage -eq 'full').Count; Partial = @($ev | Where-Object Coverage -eq 'partial').Count; Evidence = $ev }
}

function Test-CrZ01 {
    Invoke-CrCheck 'Z01' {
        if (Get-CrSecurityDefaults) { return New-CrResult Z01 -State Warn -Score 70 -Msg 'Z01.secDefaults' }
        $v = Get-CrCaVerdict (Get-CrCaPolicies) 'mfa'
        New-CrResult Z01 -State $v.State -Score $(if ($v.State -eq 'Warn') { 60 } else { -1 }) -Msg 'gen.ca' -Arguments @{ full = $v.Full; partial = $v.Partial; total = (Get-CrCaPolicies).Count } -Evidence $v.Evidence
    }
}

function Test-CrZ02 {
    Invoke-CrCheck 'Z02' {
        if (Get-CrSecurityDefaults) { return New-CrResult Z02 -State Pass -Msg 'Z02.secDefaults' }
        $v = Get-CrCaVerdict (Get-CrCaPolicies) 'legacy'
        New-CrResult Z02 -State $v.State -Msg 'gen.ca' -Arguments @{ full = $v.Full; partial = $v.Partial; total = (Get-CrCaPolicies).Count } -Evidence $v.Evidence
    }
}

function Test-CrZ03 {
    Invoke-CrCheck 'Z03' {
        $v = Get-CrCaVerdict (Get-CrCaPolicies) 'device'
        New-CrResult Z03 -State $v.State -Score $(if ($v.State -eq 'Fail') { 30 } else { -1 }) -Msg 'gen.ca' -Arguments @{ full = $v.Full; partial = $v.Partial; total = (Get-CrCaPolicies).Count } -Evidence $v.Evidence
    }
}

function Test-CrZ04 {
    Invoke-CrCheck 'Z04' {
        $r = @(Invoke-CrGraph '/reports/authenticationMethods/userRegistrationDetails?$top=999' -All)
        $members = @($r | Where-Object { $_.userType -ne 'guest' })
        if ($members.Count -eq 0) { return New-CrResult Z04 -State Unknown -Msg 'gen.empty' }
        $reg = @($members | Where-Object isMfaRegistered).Count
        $adminsNo = @($members | Where-Object { $_.isAdmin -and -not $_.isMfaRegistered })
        $pct = Get-CrPct $reg $members.Count
        $state = if ($pct -ge 95 -and $adminsNo.Count -eq 0) { 'Pass' } elseif ($pct -ge 80 -and $adminsNo.Count -le 1) { 'Warn' } else { 'Fail' }
        $ev = @(
            [pscustomobject]@{ Metric = 'members'; Value = $members.Count }
            [pscustomobject]@{ Metric = 'mfaRegistered'; Value = $reg }
            [pscustomobject]@{ Metric = 'mfaCapable'; Value = @($members | Where-Object isMfaCapable).Count }
            [pscustomobject]@{ Metric = 'adminsWithoutMfa'; Value = (@($adminsNo.userPrincipalName | Where-Object { $_ }) -join ', ') }
        )
        New-CrResult Z04 -State $state -Score ([int]$pct) -Msg 'Z04.registered' -Arguments @{ pct = $pct; n = $reg; total = $members.Count; admins = $adminsNo.Count } -Evidence $ev
    }
}

function Test-CrZ05 {
    Invoke-CrCheck 'Z05' {
        $roles = @((Invoke-CrGraph '/directoryRoles?$select=id,displayName,roleTemplateId').value)
        $ga = $roles | Where-Object roleTemplateId -eq $script:CrGaRole | Select-Object -First 1
        $members = if ($ga) { @(Invoke-CrGraph "/directoryRoles/$($ga.id)/members?`$select=id,displayName,userPrincipalName,assignedLicenses" -All) } else { @() }
        $users = @($members | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.user' })
        # Global Administrator through a role-assignable group: count the group's users as well.
        foreach ($grp in @($members | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' })) {
            $users += @(Invoke-CrGraph "/groups/$($grp.id)/transitiveMembers/microsoft.graph.user?`$select=id,displayName,userPrincipalName,assignedLicenses" -All)
        }
        $users = @($users | Where-Object { $_ } | Sort-Object id -Unique)
        $spCount = @($members | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.servicePrincipal' }).Count
        # No readable Global Administrator is a failed read, not a tenant without admins (every tenant has one).
        if ($users.Count -eq 0) { return New-CrResult Z05 -State Unknown -Msg 'gen.empty' -Detail "$(if ($ga) { "role found, $($members.Count) member objects, none of type user" } else { 'Global Administrator role not activated or not readable' })" }
        # The licence list is context; an unreadable /subscribedSkus must not turn a successful role read into NoPermission.
        $cpIds = @(); try { $cpIds = @((Get-CrCopilotSkus).skuId) } catch { Write-Verbose "Z05: licences not readable: $_" }
        $withCopilot = @($users | Where-Object { @($_.assignedLicenses.skuId | Where-Object { $_ -in $cpIds }).Count -gt 0 })
        $state = if ($users.Count -ge 2 -and $users.Count -le 5 -and $withCopilot.Count -eq 0) { 'Pass' } elseif ($users.Count -le 8) { 'Warn' } else { 'Fail' }
        $ev = $users | ForEach-Object { [pscustomobject]@{ GlobalAdmin = $_.displayName; UPN = $_.userPrincipalName; CopilotLicence = (@($_.assignedLicenses.skuId | Where-Object { $_ -in $cpIds }).Count -gt 0) } }
        New-CrResult Z05 -State $state -Score $(if ($state -eq 'Warn' -and $withCopilot.Count -gt 0) { 50 } else { -1 }) -Msg 'Z05.admins' -Arguments @{ n = $users.Count; copilot = $withCopilot.Count } -Evidence $ev `
            -Detail $(if ($spCount -gt 0) { "$spCount service principal(s) also hold Global Administrator (not counted as people)." } else { '' })
    }
}

function Get-CrAuthPolicy {
    if ($null -eq $script:CrAuthPolicy) { $script:CrAuthPolicy = Invoke-CrGraph '/policies/authorizationPolicy' }
    $script:CrAuthPolicy
}

function Test-CrZ06 {
    Invoke-CrCheck 'Z06' {
        $ap = Get-CrAuthPolicy
        $inv = [string]$ap.allowInvitesFrom
        if (-not $inv -or -not $ap.guestUserRoleId) { return New-CrResult Z06 -State Unknown -Msg 'gen.empty' }
        $roleName = switch ([string]$ap.guestUserRoleId) { 'a0b1b346-4d3e-4e8b-98f8-753987be4970' { 'member' } '10dae51f-b6af-4016-8d66-8c2a99b929b3' { 'limited' } '2af84b1e-32c8-42b7-82bc-daa82404023b' { 'restricted' } default { 'unknown' } }
        $bad = 0
        if ($inv -in 'everyone', 'adminsGuestInvitersAndAllMembers') { $bad++ }
        if ($roleName -eq 'member') { $bad += 2 } elseif ($roleName -ne 'restricted') { $bad++ }
        if ($ap.allowEmailVerifiedUsersToJoinOrganization) { $bad++ }
        $ev = @(
            [pscustomobject]@{ Setting = 'allowInvitesFrom'; Value = $inv; Recommended = 'adminsAndGuestInviters' }
            [pscustomobject]@{ Setting = 'guestUserRoleId'; Value = $roleName; Recommended = 'restricted' }
            [pscustomobject]@{ Setting = 'allowEmailVerifiedUsersToJoinOrganization'; Value = $ap.allowEmailVerifiedUsersToJoinOrganization; Recommended = $false }
        )
        $state = if ($bad -eq 0) { 'Pass' } elseif ($bad -le 1) { 'Warn' } else { 'Fail' }
        New-CrResult Z06 -State $state -Score ([int](100 - 30 * $bad)) -Msg 'Z06.guests' -Arguments @{ invites = $inv; role = $roleName } -Evidence $ev
    }
}

function Test-CrZ07 {
    Invoke-CrCheck 'Z07' {
        $ap = Get-CrAuthPolicy
        $d = $ap.defaultUserRolePermissions
        if (-not $d) { return New-CrResult Z07 -State Unknown -Msg 'gen.empty' }
        $consent = @($d.permissionGrantPoliciesAssigned | Where-Object { $_ })
        $legacy = [bool]($consent | Where-Object { $_ -match 'microsoft-user-default-legacy' })
        $low = [bool]($consent | Where-Object { $_ -match 'microsoft-user-default-low' })
        $recommended = [bool]($consent | Where-Object { $_ -match 'microsoft-user-default-recommended' })   # Microsoft-managed default, not custom
        $mode = if ($legacy) { 'all' } elseif ($low) { 'lowImpact' } elseif ($recommended) { 'recommended' } elseif ($consent | Where-Object { $_ -match 'ManagePermissionGrantsForSelf' }) { 'custom' } else { 'none' }
        $bad = 0
        if ($d.allowedToCreateApps) { $bad++ }
        if ($mode -eq 'all') { $bad += 2 }
        $ev = @(
            [pscustomobject]@{ Setting = 'allowedToCreateApps'; Value = $d.allowedToCreateApps; Recommended = $false }
            [pscustomobject]@{ Setting = 'permissionGrantPoliciesAssigned'; Value = ($consent -join ', '); Recommended = 'none, microsoft-user-default-low or microsoft-user-default-recommended' }
        )
        $state = if ($bad -eq 0) { 'Pass' } elseif ($bad -eq 1) { 'Warn' } else { 'Fail' }
        New-CrResult Z07 -State $state -Msg "Z07.consent.$mode" -Arguments @{ createApps = $(if ($d.allowedToCreateApps) { 'yes' } else { 'no' }) } -Evidence $ev
    }
}

function Test-CrI01 {
    Invoke-CrCheck 'I01' {
        $ca = Get-CrCaPolicies
        $si = Get-CrCaVerdict $ca 'signInRisk'
        $ur = Get-CrCaVerdict $ca 'userRisk'
        $state = if ($si.State -eq 'Pass' -and $ur.State -eq 'Pass') { 'Pass' } elseif ($si.State -ne 'Fail' -or $ur.State -ne 'Fail') { 'Warn' } else { 'Fail' }
        $ev = @($si.Evidence | ForEach-Object { $_ | Add-Member -NotePropertyName Goal -NotePropertyValue 'signInRisk' -PassThru }) + @($ur.Evidence | ForEach-Object { $_ | Add-Member -NotePropertyName Goal -NotePropertyValue 'userRisk' -PassThru })
        New-CrResult I01 -State $state -Msg 'I01.risk' -Arguments @{ signIn = $si.State; user = $ur.State } -Evidence $ev
    }
}

function Test-CrI02 {
    Invoke-CrCheck 'I02' {
        $v = Get-CrCaVerdict (Get-CrCaPolicies) 'adminPhish'
        New-CrResult I02 -State $v.State -Score $(if ($v.State -eq 'Fail') { 20 } else { -1 }) -Msg 'gen.ca' -Arguments @{ full = $v.Full; partial = $v.Partial; total = (Get-CrCaPolicies).Count } -Evidence $v.Evidence
    }
}

# Delegated scopes / application roles on Microsoft Graph that read or change the same data Copilot works with.
$script:CrHighRiskGraph = @('Mail.Read', 'Mail.ReadWrite', 'Mail.Send', 'MailboxSettings.ReadWrite', 'Files.Read.All', 'Files.ReadWrite.All', 'Sites.Read.All', 'Sites.ReadWrite.All', 'Sites.FullControl.All', 'Sites.Manage.All', 'Chat.Read', 'Chat.ReadWrite', 'Chat.Read.All', 'Chat.ReadWrite.All', 'ChannelMessage.Read.All', 'Notes.Read.All', 'Notes.ReadWrite.All', 'Directory.ReadWrite.All', 'User.ReadWrite.All', 'Group.ReadWrite.All', 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'RoleManagement.ReadWrite.Directory', 'EWS.AccessAsUser.All')
$script:CrMicrosoftTenant = 'f8cdef31-a31e-4b4a-93e4-5f571e91255a'

function Get-CrRiskyGrants {
    <#
      .SYNOPSIS  Pure: turns delegated grants + app role assignments into one row per client app with high-risk Graph permissions.
                 Clients owned by Microsoft's own tenant are skipped.
    #>
    param([object[]]$Delegated, [object[]]$AppRoles, [hashtable]$RoleNames, [hashtable]$Clients)
    $rows = @{}
    $add = {
        param($clientId, $type, $perms)
        $cl = $Clients[$clientId]
        if ($cl -and "$($cl.appOwnerOrganizationId)" -eq $script:CrMicrosoftTenant) { return }
        $risky = @($perms | Where-Object { $_ -in $script:CrHighRiskGraph })
        if ($risky.Count -eq 0) { return }
        $k = "$clientId|$type"
        if (-not $rows.ContainsKey($k)) { $rows[$k] = [pscustomobject]@{ App = $(if ($cl) { $cl.displayName } else { $clientId }); Type = $type; Permissions = @() } }
        $rows[$k].Permissions = @($rows[$k].Permissions + $risky | Select-Object -Unique)
    }
    foreach ($g in $Delegated) {
        $type = if ($g.consentType -eq 'AllPrincipals') { 'delegatedAllUsers' } else { 'delegatedOneUser' }
        & $add $g.clientId $type @("$($g.scope)" -split '\s+' | Where-Object { $_ })
    }
    foreach ($a in $AppRoles) { & $add $a.principalId 'application' @($RoleNames["$($a.appRoleId)"]) }
    @($rows.Values | ForEach-Object { [pscustomobject]@{ App = $_.App; Type = $_.Type; Permissions = ($_.Permissions -join ', ') } } | Sort-Object Type, App)
}

function Test-CrI03 {
    Invoke-CrCheck 'I03' {
        $graph = Invoke-CrGraph "/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')?`$select=id,appRoles"
        $names = @{}; foreach ($r in @($graph.appRoles | Where-Object { $_ })) { $names["$($r.id)"] = $r.value }
        $del = @(Invoke-CrGraph "/oauth2PermissionGrants?`$filter=resourceId eq '$($graph.id)'" -All)
        $app = @(Invoke-CrGraph "/servicePrincipals/$($graph.id)/appRoleAssignedTo?`$top=999" -All)
        $ids = @(@($del.clientId | Where-Object { $_ }) + @($app.principalId | Where-Object { $_ }) | Where-Object { $_ } | Select-Object -Unique)
        $clients = @{}
        if ($ids.Count) {
            $res = Invoke-CrGraphBatch -Urls @($ids | ForEach-Object { "/servicePrincipals/$_`?`$select=id,displayName,appOwnerOrganizationId" })
            for ($i = 0; $i -lt $ids.Count; $i++) { if ($res[$i].status -eq 200) { $clients[$ids[$i]] = $res[$i].body } }
        }
        $rows = @(Get-CrRiskyGrants -Delegated $del -AppRoles $app -RoleNames $names -Clients $clients)
        $apps = @($rows.App | Select-Object -Unique).Count
        $tenantWide = @($rows | Where-Object Type -in 'delegatedAllUsers', 'application').Count
        $tenantWideApps = @($rows | Where-Object Type -in 'delegatedAllUsers', 'application' | ForEach-Object App | Select-Object -Unique).Count
        # A single user's own consent reaches that user's data only; tenant-wide or app-only grants reach everyone's.
        $state = if ($rows.Count -eq 0) { 'Pass' } elseif ($tenantWideApps -le 10) { 'Warn' } else { 'Fail' }
        New-CrResult I03 -State $state -Score $(if ($state -eq 'Warn') { [int][Math]::Max(45, 74 - 3 * $tenantWideApps) } else { -1 }) -Msg 'I03.grants' -Arguments @{ apps = $apps; tenantWide = $tenantWide; grants = $del.Count + $app.Count } -Evidence $rows
    }
}

function Get-CrPimSummary {
    <# Pure: active (permanent / activated) vs eligible assignments for privileged roles. #>
    param([object[]]$Active, [object[]]$Eligible)
    foreach ($id in $script:CrPrivilegedRoles.Keys) {
        $act = @($Active | Where-Object roleDefinitionId -eq $id)
        $perm = @($act | Where-Object { $_.assignmentType -ne 'Activated' -and -not $_.endDateTime })
        $eli = @($Eligible | Where-Object roleDefinitionId -eq $id)
        if ($act.Count + $eli.Count -eq 0) { continue }
        [pscustomobject]@{ Role = $script:CrPrivilegedRoles[$id]; Permanent = $perm.Count; Activated = @($act | Where-Object assignmentType -eq 'Activated').Count; TimeBound = @($act | Where-Object { $_.assignmentType -ne 'Activated' -and $_.endDateTime }).Count; Eligible = $eli.Count; IsGA = ($id -eq $script:CrGaRole) }
    }
}

function Test-CrI04 {
    Invoke-CrCheck 'I04' {
        $act = @(Invoke-CrGraph '/roleManagement/directory/roleAssignmentScheduleInstances' -All)
        $eli = @(Invoke-CrGraph '/roleManagement/directory/roleEligibilityScheduleInstances' -All)
        $rows = @(Get-CrPimSummary -Active $act -Eligible $eli)
        $perm = [int]($rows | Measure-Object Permanent -Sum).Sum
        $permGa = [int]($rows | Where-Object IsGA | Measure-Object Permanent -Sum).Sum
        $eligible = [int]($rows | Measure-Object Eligible -Sum).Sum
        $beyondBreakGlass = $perm - [Math]::Min(2, $permGa)
        # Only the two emergency accounts permanent and nothing eligible: PIM is not in use, but nothing is over-privileged either.
        $state = if ($beyondBreakGlass -le 0 -and $eligible -gt 0) { 'Pass' } elseif ($beyondBreakGlass -le 0) { 'Warn' } elseif ($eligible -eq 0) { 'Fail' } elseif ($beyondBreakGlass -le 3) { 'Warn' } else { 'Fail' }
        New-CrResult I04 -State $state -Msg 'I04.pim' -Arguments @{ permanent = $perm; eligible = $eligible; extra = [Math]::Max(0, $beyondBreakGlass) } -Evidence ($rows | Select-Object Role, Permanent, Activated, TimeBound, Eligible)
    }
}
