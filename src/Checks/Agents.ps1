# Agents — who builds, shares and owns agents.

function Test-CrA01 {
    Invoke-CrCheck 'A01' {
        $agents = @(Invoke-CrGraph '/servicePrincipals/microsoft.graph.agentIdentity?$select=id,displayName,accountEnabled,createdDateTime,agentIdentityBlueprintId&$top=100' -All)
        if ($agents.Count -eq 0) { return New-CrResult A01 -State NotApplicable -Msg 'A01.none' }
        $active = @($agents | Where-Object { $_.accountEnabled -ne $false })
        if ($active.Count -eq 0) { return New-CrResult A01 -State NotApplicable -Msg 'A01.allDisabled' -Arguments @{ total = $agents.Count } }
        $res = if ($active.Count) { Invoke-CrGraphBatch -Urls @($active | ForEach-Object { "/servicePrincipals/$($_.id)/owners?`$select=id,displayName,userPrincipalName" }) } else { @() }
        $noOwner = New-Object System.Collections.Generic.List[object]; $failed = 0
        $ev = for ($i = 0; $i -lt $active.Count; $i++) {
            $owners = $null
            if ($res[$i].status -eq 200) { $owners = @($res[$i].body.value) } else { $failed++ }
            if ($null -ne $owners -and $owners.Count -eq 0) { $noOwner.Add($active[$i]) }
            [pscustomobject]@{ Agent = $active[$i].displayName; Created = (Get-CrDateText $active[$i].createdDateTime); Owners = $(if ($null -eq $owners) { $null } else { $owners.Count }); Owner = (@($owners | ForEach-Object { $_.userPrincipalName ?? $_.displayName }) -join ', ') }
        }
        $known = $active.Count - $failed
        $a = @{ total = $agents.Count; active = $active.Count; noOwner = $noOwner.Count; failed = $failed; disabled = $agents.Count - $active.Count }
        if ($active.Count -gt 0 -and ($known -eq 0 -or $failed -gt [Math]::Max(1, 0.1 * $active.Count))) { return New-CrResult A01 -State Unknown -Msg 'A01.partial' -Arguments $a -Evidence $ev }
        $pct = Get-CrPct $noOwner.Count $known
        $state = if ($noOwner.Count -eq 0) { 'Pass' } elseif ($pct -le 20) { 'Warn' } else { 'Fail' }
        New-CrResult A01 -State $state -Score ([int][Math]::Max(0, 100 - 2 * $pct)) -Msg 'A01.owners' -Arguments $a -Evidence ($ev | Sort-Object Owners)
    }
}

function ConvertTo-CrAgentRow {
    <#
      .SYNOPSIS  Normalises one Copilot Studio inventory record (fields are preview; null means "not reported").
                 Pure; used by A02 and tests.
    #>
    param($Record)
    $get = { param($n) $Record."properties_$n" ?? $Record.properties.$n }
    $viewers = & $get 'sharedWithViewers'
    $auth = & $get 'authentication'
    $conn = & $get 'powerPlatformConnectors'
    $connText = if ($null -ne $conn) { $conn | ConvertTo-Json -Depth 8 -Compress -WarningAction SilentlyContinue } else { $null }
    [pscustomobject]@{
        Agent        = (& $get 'displayName') ?? $Record.name
        Environment  = (& $get 'environmentId')
        Owner        = (& $get 'ownerId') ?? (& $get 'createdBy')
        Auth         = $auth
        EntireTenant = $(if ($null -ne $viewers) { [bool]$viewers.entireTenant } else { $null })
        Viewers      = $(if ($null -ne $viewers) { [int]$viewers.userCount + [int]$viewers.groupCount } else { $null })
        MakerConnection = $(if ($null -ne $connText) { $connText -match '"(connectionMode|authMode|mode)"\s*:\s*"maker"' } else { $null })
        Channels     = (@(& $get 'channels') -join ', ')
    }
}

function Get-CrAgentIssues {
    param($Row)
    $i = @()
    if ($Row.Auth -eq 'None') { $i += 'noAuth' }
    if ($Row.EntireTenant -eq $true) { $i += 'tenantWide' }
    if ($Row.MakerConnection -eq $true) { $i += 'makerConnection' }
    $i
}

function Test-CrA02 {
    Invoke-CrCheck 'A02' {
        $q = @{
            TableName = 'PowerPlatformResources'
            Clauses   = @(
                @{ '$type' = 'where'; FieldName = 'type'; Operator = '=='; Values = @("'microsoft.copilotstudio/agents'") }
                @{ '$type' = 'project'; FieldList = @('name', 'properties.displayName', 'properties.environmentId', 'properties.ownerId', 'properties.createdBy', 'properties.authentication', 'properties.sharedWithViewers', 'properties.channels', 'properties.powerPlatformConnectors') }
            )
        }
        $raw = @(Invoke-CrPowerPlatformQuery -Query $q)
        if ($raw.Count -eq 0) { return New-CrResult A02 -State NotApplicable -Msg 'A02.none' }
        $rows = @($raw | ForEach-Object { ConvertTo-CrAgentRow $_ })
        $reported = @($rows | Where-Object { $null -ne $_.Auth -or $null -ne $_.EntireTenant })
        if ($reported.Count -eq 0) { return New-CrResult A02 -State Unknown -Msg 'A02.noFields' -Arguments @{ total = $rows.Count } }
        $ev = $rows | ForEach-Object { $_ | Add-Member -NotePropertyName Issues -NotePropertyValue ((Get-CrAgentIssues $_) -join ', ') -PassThru }
        $risky = @($ev | Where-Object Issues)
        $a = @{ total = $rows.Count; risky = $risky.Count; noAuth = @($ev | Where-Object Auth -eq 'None').Count; tenantWide = @($ev | Where-Object EntireTenant -eq $true).Count; maker = @($ev | Where-Object MakerConnection -eq $true).Count; unreported = $rows.Count - $reported.Count }
        $pct = Get-CrPct $risky.Count $reported.Count   # agents whose preview fields are missing cannot be judged either way
        $state = if ($risky.Count -eq 0) { 'Pass' } elseif ($pct -le 20) { 'Warn' } else { 'Fail' }
        New-CrResult A02 -State $state -Score ([int][Math]::Max(0, 100 - 2 * $pct)) -Msg 'A02.agents' -Arguments $a -Evidence ($ev | Sort-Object { -not $_.Issues })
    }
}

function Get-CrDlpEnvironmentCoverage {
    <#
      .SYNOPSIS  Which environments are covered by at least one Power Platform DLP policy. Pure; used by A03 and tests.
                 EnvironmentType: AllEnvironments | OnlyEnvironments | ExceptEnvironments (field names per module output, unverified in a live tenant).
    #>
    param([object[]]$Environments, [object[]]$Policies)
    foreach ($e in $Environments) {
        $id = "$($e.EnvironmentName)"
        $by = foreach ($p in $Policies) {
            $list = @($p.Environments | Where-Object { $_ } | ForEach-Object { "$($_.name ?? $_.EnvironmentName ?? $_)" })
            # Get-AdminDlpPolicy (Microsoft.PowerApps.Administration.PowerShell) returns FilterType include | exclude,
            # or nothing for a tenant policy that applies to all environments. EnvironmentType is the older test shape.
            $scope = switch ("$($p.FilterType)".ToLowerInvariant()) {
                'include' { 'OnlyEnvironments' }
                'exclude' { 'ExceptEnvironments' }
                default { if ("$($p.EnvironmentType)") { "$($p.EnvironmentType)" } elseif ("$($p.Type)" -match '/environments/') { 'OnlyEnvironments' } else { 'AllEnvironments' } }
            }
            $covers = switch ($scope) {
                'AllEnvironments' { $true }
                'OnlyEnvironments' { $list -contains $id }
                'ExceptEnvironments' { $list -notcontains $id }
                default { $false }
            }
            if ($covers) { $p.DisplayName }
        }
        [pscustomobject]@{ Environment = $e.DisplayName; Type = "$($e.EnvironmentType)"; Default = [bool]$e.IsDefault; Policies = (@($by) -join ', '); Covered = (@($by).Count -gt 0) }
    }
}

function Test-CrA03 {
    Invoke-CrCheck 'A03' {
        $envs = @(Invoke-CrReader Get-AdminPowerAppEnvironment)
        # Every tenant has at least the default environment: none returned means the read did not work
        # (missing Power Platform Administrator role, or the module returned nothing), never "nothing to check".
        if ($envs.Count -eq 0) { return New-CrResult A03 -State Unknown -Msg 'A03.noEnv' }
        $pol = @(Invoke-CrReader Get-AdminDlpPolicy)
        $rows = @(Get-CrDlpEnvironmentCoverage -Environments $envs -Policies $pol)
        $uncovered = @($rows | Where-Object { -not $_.Covered })
        $defaultOpen = @($uncovered | Where-Object Default).Count -gt 0
        $state = if ($uncovered.Count -eq 0) { 'Pass' } elseif ($defaultOpen) { 'Fail' } else { 'Warn' }
        New-CrResult A03 -State $state -Msg 'A03.coverage' -Arguments @{ covered = $rows.Count - $uncovered.Count; total = $rows.Count; policies = $pol.Count; defaultOpen = $(if ($defaultOpen) { 'yes' } else { 'no' }) } -Evidence ($rows | Sort-Object Covered)
    }
}
