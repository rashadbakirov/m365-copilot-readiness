#Requires -Modules Pester
# Pure evaluation logic of checks: Conditional Access, DLP classification, Power Platform DLP coverage,
# risky grants, PIM, audit states, retention.

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src/Core.ps1')
    Get-ChildItem (Join-Path $root 'src/Checks') -Filter *.ps1 | ForEach-Object { . $_.FullName }
    function Ca {
        param($Name = 'p', $State = 'enabled', $Users = @('All'), $ExUsers = @(), $ExGroups = @(), $Roles = @(), $Apps = @('All'), $ExApps = @(), $Clients = @('all'), $Controls = @('mfa'), $Operator = 'OR', $Strength = $null, $SignInRisk = @(), $UserRisk = @())
        [pscustomobject]@{
            displayName = $Name; state = $State
            conditions = [pscustomobject]@{
                users = [pscustomobject]@{ includeUsers = $Users; excludeUsers = $ExUsers; excludeGroups = $ExGroups; includeRoles = $Roles; excludeRoles = @() }
                applications = [pscustomobject]@{ includeApplications = $Apps; excludeApplications = $ExApps }
                clientAppTypes = $Clients; signInRiskLevels = $SignInRisk; userRiskLevels = $UserRisk
            }
            grantControls = [pscustomobject]@{ operator = $Operator; builtInControls = $Controls; authenticationStrength = $Strength }
        }
    }
}

Describe 'Conditional Access evaluation (Get-CrCaEvaluation)' {
    It 'all users + all apps + MFA + two break-glass exclusions is full' {
        (Get-CrCaEvaluation -Policy (Ca -ExUsers @('bg1', 'bg2')) -Kind mfa).Coverage | Should -Be 'full'
    }
    It 'authentication strength counts as MFA' {
        (Get-CrCaEvaluation -Policy (Ca -Controls @() -Strength ([pscustomobject]@{ id = 'x'; displayName = 'MFA' })) -Kind mfa).Coverage | Should -Be 'full'
    }
    It 'report-only is never full' {
        (Get-CrCaEvaluation -Policy (Ca -State 'enabledForReportingButNotEnforced') -Kind mfa).Coverage | Should -Be 'partial'
    }
    It 'many excluded users or a large excluded group set make it partial' {
        (Get-CrCaEvaluation -Policy (Ca -ExUsers @('a', 'b', 'c')) -Kind mfa).Coverage | Should -Be 'partial'
        (Get-CrCaEvaluation -Policy (Ca -ExGroups @('g1', 'g2')) -Kind mfa).Coverage | Should -Be 'partial'
    }
    It 'a pilot group instead of all users is partial' {
        (Get-CrCaEvaluation -Policy (Ca -Users @()) -Kind mfa).Coverage | Should -Be 'partial'
    }
    It 'MFA OR compliant device lets users skip MFA, so partial' {
        (Get-CrCaEvaluation -Policy (Ca -Controls @('mfa', 'compliantDevice')) -Kind mfa).Coverage | Should -Be 'partial'
    }
    It 'MFA AND compliant device stays full' {
        (Get-CrCaEvaluation -Policy (Ca -Controls @('mfa', 'compliantDevice') -Operator 'AND') -Kind mfa).Coverage | Should -Be 'full'
    }
    It 'excluded apps or limited client apps make it partial' {
        (Get-CrCaEvaluation -Policy (Ca -ExApps @('app1')) -Kind mfa).Coverage | Should -Be 'partial'
        (Get-CrCaEvaluation -Policy (Ca -Clients @('browser')) -Kind mfa).Coverage | Should -Be 'partial'
    }
    It 'an MFA policy only for risky sign-ins is partial for the MFA goal' {
        (Get-CrCaEvaluation -Policy (Ca -SignInRisk @('high')) -Kind mfa).Coverage | Should -Be 'partial'
    }
    It 'a block policy is not an MFA policy' {
        (Get-CrCaEvaluation -Policy (Ca -Controls @('block')) -Kind mfa).Coverage | Should -Be 'none'
    }
    It 'legacy block needs both legacy client types' {
        (Get-CrCaEvaluation -Policy (Ca -Controls @('block') -Clients @('exchangeActiveSync', 'other')) -Kind legacy).Coverage | Should -Be 'full'
        (Get-CrCaEvaluation -Policy (Ca -Controls @('block') -Clients @('other')) -Kind legacy).Coverage | Should -Be 'partial'
    }
    It 'device rule accepts Office 365 as app scope' {
        (Get-CrCaEvaluation -Policy (Ca -Controls @('compliantDevice') -Apps @('Office365')) -Kind device).Coverage | Should -Be 'full'
    }
    It 'risk policies need the right risk levels and controls' {
        (Get-CrCaEvaluation -Policy (Ca -SignInRisk @('high', 'medium')) -Kind signInRisk).Coverage | Should -Be 'full'
        (Get-CrCaEvaluation -Policy (Ca -UserRisk @('high') -Controls @('passwordChange', 'mfa') -Operator 'AND') -Kind userRisk).Coverage | Should -Be 'full'
        (Get-CrCaEvaluation -Policy (Ca) -Kind signInRisk).Coverage | Should -Be 'none'
    }
    It 'admin phishing-resistant: built-in strength on all privileged roles is full, plain MFA is none' {
        $strength = [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000004'; displayName = 'Phishing-resistant MFA' }
        $roles = @($script:CrPrivilegedRoles.Keys)
        (Get-CrCaEvaluation -Policy (Ca -Users @() -Roles $roles -Controls @() -Strength $strength) -Kind adminPhish).Coverage | Should -Be 'full'
        (Get-CrCaEvaluation -Policy (Ca -Users @() -Roles $roles) -Kind adminPhish).Coverage | Should -Be 'none'
    }
    It 'a custom strength with SMS is not phishing-resistant' {
        Test-CrPhishResistant ([pscustomobject]@{ id = 'c'; displayName = 'Custom'; allowedCombinations = @('fido2', 'password,sms') }) | Should -BeFalse
        Test-CrPhishResistant ([pscustomobject]@{ id = 'c'; displayName = 'Custom'; allowedCombinations = @('fido2', 'windowsHelloForBusiness') }) | Should -BeTrue
        # never by name: a custom strength called "Phishing-resistant" that allows password+SMS is not
        Test-CrPhishResistant ([pscustomobject]@{ id = 'c'; displayName = 'Phishing-resistant (custom)'; allowedCombinations = @('password,sms') }) | Should -BeFalse
    }
    It 'a custom authentication strength that allows a single factor is not MFA' {
        Test-CrMfaStrength ([pscustomobject]@{ id = 'c'; allowedCombinations = @('password,sms', 'fido2') }) | Should -BeTrue
        Test-CrMfaStrength ([pscustomobject]@{ id = 'c'; allowedCombinations = @('sms', 'fido2') }) | Should -BeFalse
        Test-CrMfaStrength ([pscustomobject]@{ id = '00000000-0000-0000-0000-000000000002' }) | Should -BeTrue
        (Get-CrCaEvaluation -Policy (Ca -Controls @() -Strength ([pscustomobject]@{ id = 'c'; allowedCombinations = @('sms') })) -Kind mfa).Coverage | Should -Be 'none'
    }
    It 'excluding only the Directory Synchronization Accounts role keeps full coverage; excluded locations do not' {
        $p = Ca; $p.conditions.users.excludeRoles = @('d29b2b05-8046-44ba-8758-1e26182fcf32')
        (Get-CrCaEvaluation -Policy $p -Kind mfa).Coverage | Should -Be 'full'
        $q = Ca; $q.conditions | Add-Member -NotePropertyName locations -NotePropertyValue ([pscustomobject]@{ includeLocations = @('All'); excludeLocations = @('AllTrusted') })
        (Get-CrCaEvaluation -Policy $q -Kind mfa).Coverage | Should -Be 'partial'
    }
    It 'verdict: one full policy = Pass, only partial = Warn, none = Fail' {
        (Get-CrCaVerdict @((Ca), (Ca -Users @())) 'mfa').State | Should -Be 'Pass'
        (Get-CrCaVerdict @((Ca -Users @())) 'mfa').State | Should -Be 'Warn'
        (Get-CrCaVerdict @((Ca -Controls @('block'))) 'mfa').State | Should -Be 'Fail'
        (Get-CrCaVerdict @() 'mfa').State | Should -Be 'Fail'
    }
}

Describe 'Copilot DLP classification (B01 prompts vs B05 labelled content)' {
    BeforeAll {
        $pol = @(
            [pscustomobject]@{ Name = 'Copilot'; Enabled = $true; Mode = 'Enable'; EnforcementPlanes = @('CopilotExperiences') }
            [pscustomobject]@{ Name = 'Mail'; Enabled = $true; Mode = 'Enable'; Workload = 'Exchange' }
        )
        $rules = @(
            [pscustomobject]@{ Name = 'labels'; ParentPolicyName = 'Copilot'; Disabled = $false; AdvancedRule = '{"Condition":{"SubConditions":[{"ConditionName":"ContentContainsSensitiveInformation","Value":[{"groups":[{"labels":[{"name":"x","type":"Sensitivity"}]}]}]}]}}'; RestrictAccess = @(@{ setting = 'ExcludeContentProcessing'; value = 'Block' }) }
            [pscustomobject]@{ Name = 'iban'; ParentPolicyName = 'Copilot'; Disabled = $false; ContentContainsSensitiveInformation = @(@{ name = 'IBAN' }) }
            [pscustomobject]@{ Name = 'mailrule'; ParentPolicyName = 'Mail'; Disabled = $false; ContentContainsSensitiveInformation = @(@{ name = 'IBAN' }) }
        )
        $rows = @(Get-CrCopilotDlpRules -Policies $pol -Rules $rules)
    }
    It 'ignores rules of non-Copilot policies' { $rows.Rule | Should -Not -Contain 'mailrule' }
    It 'classifies label and prompt rules' { ($rows | Where-Object Rule -eq 'labels').Kind | Should -Be 'label'; ($rows | Where-Object Rule -eq 'iban').Kind | Should -Be 'prompt' }
    It 'passes both goals when enforced' { Get-CrDlpVerdict $rows 'label' | Should -Be 'Pass'; Get-CrDlpVerdict $rows 'prompt' | Should -Be 'Pass' }
    It 'a policy in test mode is only Warn' {
        $pol[0].Mode = 'TestWithNotifications'
        Get-CrDlpVerdict @(Get-CrCopilotDlpRules -Policies $pol -Rules $rules) 'prompt' | Should -Be 'Warn'
    }
    It 'detects the Copilot location from the Locations JSON too' {
        Test-CrCopilotDlpPolicy ([pscustomobject]@{ Locations = '[{"Location":"470f2276-e011-4e9d-a6ec-20768be3a4b0"}]' }) | Should -BeTrue
        Test-CrCopilotDlpPolicy ([pscustomobject]@{ Name = 'Copilot in the name only' }) | Should -BeFalse
    }
}

Describe 'Power Platform DLP coverage (A03), no environments' {
    It 'zero environments is a failed read (every tenant has a default environment), never Not applicable' {
        function Invoke-CrReader { param($Name, $Parameters) @() }
        (Test-CrA03 6>$null).State | Should -Be 'Unknown'
    }
}

Describe 'Power Platform DLP coverage (A03)' {
    It 'handles All / Only / Except environment scopes' {
        $env = @([pscustomobject]@{ EnvironmentName = 'd'; DisplayName = 'Default'; IsDefault = $true }, [pscustomobject]@{ EnvironmentName = 'p'; DisplayName = 'Prod'; IsDefault = $false })
        # The real module shape (Get-AdminDlpPolicy): FilterType include/exclude, or none for all environments.
        $realInclude = [pscustomobject]@{ DisplayName = 'RealInc'; FilterType = 'include'; Environments = @([pscustomobject]@{ id = '/x/p'; name = 'p'; type = 'env' }) }
        $realAll = [pscustomobject]@{ DisplayName = 'RealAll'; FilterType = $null; Environments = $null; Type = 'Microsoft.BusinessAppPlatform/scopes/apiPolicies' }
        $envs2 = @([pscustomobject]@{ EnvironmentName = 'p'; DisplayName = 'Prod'; IsDefault = $false }, [pscustomobject]@{ EnvironmentName = 'd'; DisplayName = 'Default'; IsDefault = $true })
        $r1 = @(Get-CrDlpEnvironmentCoverage -Environments $envs2 -Policies @($realInclude))
        ($r1 | Where-Object Environment -eq 'Prod').Covered | Should -BeTrue
        ($r1 | Where-Object Environment -eq 'Default').Covered | Should -BeFalse
        @(Get-CrDlpEnvironmentCoverage -Environments $envs2 -Policies @($realAll) | Where-Object Covered).Count | Should -Be 2
        $only = [pscustomobject]@{ DisplayName = 'Only'; EnvironmentType = 'OnlyEnvironments'; Environments = @([pscustomobject]@{ name = 'p' }) }
        $except = [pscustomobject]@{ DisplayName = 'Except'; EnvironmentType = 'ExceptEnvironments'; Environments = @([pscustomobject]@{ name = 'p' }) }
        $all = [pscustomobject]@{ DisplayName = 'All'; EnvironmentType = 'AllEnvironments'; Environments = @() }
        (Get-CrDlpEnvironmentCoverage $env @($only) | Where-Object Default).Covered | Should -BeFalse
        (Get-CrDlpEnvironmentCoverage $env @($except) | Where-Object Default).Covered | Should -BeTrue
        @(Get-CrDlpEnvironmentCoverage $env @($all) | Where-Object Covered).Count | Should -Be 2
    }
}

Describe 'Agent inventory rows (A02)' {
    It 'treats null preview fields as unknown, not safe' {
        $row = ConvertTo-CrAgentRow ([pscustomobject]@{ name = 'x'; properties_displayName = 'A' })
        $row.EntireTenant | Should -BeNullOrEmpty
        @(Get-CrAgentIssues $row).Count | Should -Be 0
    }
    It 'flags tenant-wide sharing, no sign-in and maker connections' {
        $row = ConvertTo-CrAgentRow ([pscustomobject]@{ name = 'x'; properties_authentication = 'None'; properties_sharedWithViewers = [pscustomobject]@{ entireTenant = $true; userCount = 0; groupCount = 0 }; properties_powerPlatformConnectors = @([pscustomobject]@{ connectorId = 'c'; connectionMode = 'maker' }) })
        @(Get-CrAgentIssues $row) | Should -Be @('noAuth', 'tenantWide', 'makerConnection')
    }
}

Describe 'High-risk grants (I03)' {
    It 'keeps risky permissions of customer apps and skips Microsoft-owned clients' {
        $del = @([pscustomobject]@{ clientId = 'c1'; consentType = 'AllPrincipals'; scope = 'User.Read Mail.Read' }, [pscustomobject]@{ clientId = 'ms'; consentType = 'AllPrincipals'; scope = 'Mail.Read' }, [pscustomobject]@{ clientId = 'c2'; consentType = 'AllPrincipals'; scope = 'User.Read openid' })
        $app = @([pscustomobject]@{ principalId = 'c3'; appRoleId = 'r1' })
        $clients = @{ c1 = [pscustomobject]@{ displayName = 'One'; appOwnerOrganizationId = 'x' }; ms = [pscustomobject]@{ displayName = 'MS'; appOwnerOrganizationId = 'f8cdef31-a31e-4b4a-93e4-5f571e91255a' }; c3 = [pscustomobject]@{ displayName = 'Three'; appOwnerOrganizationId = 'y' } }
        $rows = @(Get-CrRiskyGrants -Delegated $del -AppRoles $app -RoleNames @{ r1 = 'Files.Read.All' } -Clients $clients)
        $rows.App | Should -Be @('Three', 'One')
        ($rows | Where-Object App -eq 'Three').Type | Should -Be 'application'
    }
}

Describe 'PIM summary (I04)' {
    It 'separates permanent, activated and eligible assignments' {
        $ga = '62e90394-69f5-4237-9190-012177145e10'
        $act = @([pscustomobject]@{ roleDefinitionId = $ga; assignmentType = 'Assigned'; endDateTime = $null }, [pscustomobject]@{ roleDefinitionId = $ga; assignmentType = 'Activated'; endDateTime = '2026-10-22T12:00:00Z' })
        $eli = @([pscustomobject]@{ roleDefinitionId = $ga })
        $row = Get-CrPimSummary -Active $act -Eligible $eli
        $row.Permanent | Should -Be 1; $row.Activated | Should -Be 1; $row.Eligible | Should -Be 1
    }
}

Describe 'Audit search states (N01/N02)' {
    It 'maps <status>/<error> to <state>' -ForEach @(
        @{ status = 'succeeded'; error = $null; http = 0; state = 'Pass' }
        @{ status = 'running'; error = $null; http = 0; state = 'Unknown' }
        @{ status = 'failed'; error = $null; http = 0; state = 'Unknown' }
        @{ status = 'cancelled'; error = $null; http = 0; state = 'Unknown' }
        @{ status = $null; error = 'Audit log is not enabled for the tenant'; http = 400; state = 'Fail' }
        @{ status = $null; error = 'Forbidden'; http = 403; state = 'NoPermission' }
        @{ status = $null; error = 'boom'; http = 500; state = 'Unknown' }
    ) {
        Get-CrAuditState @{ status = $status; error = $error; httpStatus = $http } | Should -Be $state
    }
}

Describe 'Copilot retention (B03)' {
    It 'needs enabled, distributed and a rule with duration' {
        $pol = @([pscustomobject]@{ Name = 'C'; Guid = 'g1'; Enabled = $true; DistributionStatus = 'Success'; Applications = @('User:M365Copilot') }, [pscustomobject]@{ Name = 'Teams'; Guid = 'g2'; Enabled = $true; DistributionStatus = 'Success'; TeamsChatLocation = @('All') })
        $rules = @([pscustomobject]@{ Name = 'r'; Policy = 'g1'; RetentionDuration = '365'; RetentionComplianceAction = 'Delete' })
        $rows = @(Get-CrRetentionRows -Policies $pol -Rules $rules)
        # An older "Teams chats and Copilot interactions" policy (TeamsChatLocation) still applies to Copilot (Microsoft Learn)
        $rows.Count | Should -Be 2
        ($rows | Where-Object Policy -eq 'Teams').Effective | Should -BeFalse   # no rule with a duration
        $rows[0].Effective | Should -BeTrue
        $pol[0].DistributionStatus = 'Pending'
        @(Get-CrRetentionRows -Policies $pol -Rules $rules | Where-Object Effective).Count | Should -Be 0
    }
}

Describe 'Label policy settings parser (K03)' {
    It 'reads default label and mandatory flags' {
        $s = ConvertFrom-CrLabelSettings @('[defaultlabelid, 1234]', '[mandatory, true]')
        $s['defaultlabelid'] | Should -Be '1234'
        $s['mandatory'] | Should -Be 'true'
    }
}

Describe 'Public groups: Viva Engage system groups (Test-CrSystemGroup)' {
    It 'recognises All Company and the Answers backing group only when Viva Engage provisioned them' {
        $allCompany = [pscustomobject]@{ displayName = 'All Company'; mailNickname = 'allcompany'; visibility = 'Public'; creationOptions = @('YammerProvisioning') }
        $answers = [pscustomobject]@{ displayName = 'Group for Answers in Viva Engage – DO NOT DELETE 123'; mailNickname = 'groupforanswersinvivaengagedonotdelete123'; visibility = 'Public'; creationOptions = @('YammerProvisioning') }
        $community = [pscustomobject]@{ displayName = 'Vertrieb'; mailNickname = 'vertrieb'; visibility = 'Public'; creationOptions = @('YammerProvisioning') }
        $lookalike = [pscustomobject]@{ displayName = 'All Company'; mailNickname = 'allcompany'; visibility = 'Public'; creationOptions = @() }
        $plain = [pscustomobject]@{ displayName = 'Projekt X'; mailNickname = 'projektx'; visibility = 'Public' }
        Test-CrSystemGroup $allCompany | Should -BeTrue
        Test-CrSystemGroup $answers | Should -BeTrue
        Test-CrSystemGroup $community | Should -BeFalse     # a user-created public community still counts
        Test-CrSystemGroup $lookalike | Should -BeFalse     # the name alone is not enough
        Test-CrSystemGroup $plain | Should -BeFalse
    }
}

Describe 'Optional readers (Invoke-CrReader)' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src/Readers.ps1')
    }
    It 'refuses anything that is not a Get- cmdlet' {
        { Invoke-CrReader 'Set-DlpCompliancePolicy' } | Should -Throw '*readers are limited to Get- cmdlets*'
    }
    It 'reports a missing cmdlet instead of failing on a null reference' {
        { Invoke-CrReader 'Get-CrNoSuchCmdlet' } | Should -Throw '*was not exposed to the signed-in account*'
    }
}
