<#
.SYNOPSIS
  Generates the fictional "Contoso Maschinenbau GmbH" demo tenant used by the test suite (tests/fixtures/contoso/*.json).
  Deterministic (fixed seed, fixed date), so the committed example report does not drift.
  Every name, domain and id here is invented. No real tenant data.
#>
param([string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tests/fixtures/contoso'))
$ErrorActionPreference = 'Stop'
$rnd = [System.Random]::new(42)
$now = [datetime]::new(2026, 10, 22, 9, 0, 0, [DateTimeKind]::Utc)
$dom = 'contoso-maschinenbau.de'
function Id { param([int]$n, [string]$p = 'c0') '{0}{1:x6}-0000-4000-8000-{2:x12}' -f $p, $n, $n }
function D([int]$daysAgo) { $now.AddDays(-$daysAgo).ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Dd([int]$daysAgo) { $now.AddDays(-$daysAgo).ToString('yyyy-MM-dd') }
$first = 'Anna', 'Ben', 'Clara', 'David', 'Eva', 'Felix', 'Greta', 'Hannes', 'Ida', 'Jonas', 'Katrin', 'Lukas', 'Mara', 'Nils', 'Olga', 'Paul', 'Rita', 'Stefan', 'Tina', 'Uwe'
$last = 'Albers', 'Brandt', 'Conrad', 'Diehl', 'Engel', 'Franke', 'Gruber', 'Hahn', 'Imhof', 'Jäger', 'Kunz', 'Lorenz', 'Maurer', 'Nowak', 'Otto', 'Pohl'
function Person([int]$i) { $f = $first[$i % $first.Count]; $l = $last[[int]($i / $first.Count) % $last.Count]; [pscustomobject]@{ name = "$f $l"; upn = ("{0}.{1}@{2}" -f $f, $l, $dom).ToLower().Replace('ä', 'ae') } }

$g = [ordered]@{}
$copilotSku = '639dec6b-bb19-468b-871c-c5c441c4b0cb'
$bpSku = 'cbdc14ab-d96c-4c30-b9f4-6ada7cdc1d46'
$plan = { param($names) @($names | ForEach-Object { @{ servicePlanName = $_ } }) }
$g['GET v1.0/subscribedSkus'] = @{ value = @(
        @{ skuId = $bpSku; skuPartNumber = 'SPB'; consumedUnits = 389; prepaidUnits = @{ enabled = 400 }; servicePlans = (& $plan 'AAD_PREMIUM', 'MFA_PREMIUM', 'MIP_S_CLP1', 'RMS_S_PREMIUM', 'INTUNE_A', 'EXCHANGE_S_STANDARD', 'SHAREPOINTSTANDARD', 'TEAMS1', 'ADALLOM_S_DISCOVERY', 'Bing_Chat_Enterprise') }
        @{ skuId = $copilotSku; skuPartNumber = 'Microsoft_365_Copilot'; consumedUnits = 52; prepaidUnits = @{ enabled = 60 }; servicePlans = (& $plan 'M365_COPILOT_APPS', 'M365_COPILOT_TEAMS', 'M365_COPILOT_BUSINESS_CHAT', 'M365_COPILOT_SHAREPOINT') }
        @{ skuId = 'f30db892-07e9-47e9-837c-80727f46fd3d'; skuPartNumber = 'FLOW_FREE'; consumedUnits = 14; prepaidUnits = @{ enabled = 10000 }; servicePlans = (& $plan 'FLOW_P2_VIRAL') }
    )
}
$cpUsers = foreach ($i in 0..51) { $p = Person $i; @{ id = (Id $i 'a1'); displayName = $p.name; userPrincipalName = $p.upn; licenseAssignmentStates = @(@{ skuId = $copilotSku; assignedByGroup = $(if ($i -lt 40) { (Id 900 'b1') } else { $null }) }) } }
$g["GET v1.0/users?`$filter=assignedLicenses/any(x:x/skuId eq $copilotSku)&`$select=id,displayName,userPrincipalName,licenseAssignmentStates&`$top=999"] = @{ value = @($cpUsers) }
$usage = foreach ($i in 0..51) {
    $p = Person $i; $act = $i -lt 38
    @{ reportRefreshDate = (Dd 2); userPrincipalName = $p.upn; displayName = $p.name; lastActivityDate = $(if ($act) { Dd ($i % 20 + 2) } else { '' })
        microsoftTeamsCopilotLastActivityDate = $(if ($act -and $i % 3 -ne 0) { Dd 3 } else { '' }); wordCopilotLastActivityDate = $(if ($act -and $i % 2 -eq 0) { Dd 5 } else { '' })
        excelCopilotLastActivityDate = $(if ($act -and $i % 5 -eq 0) { Dd 6 } else { '' }); powerPointCopilotLastActivityDate = $(if ($act -and $i % 7 -eq 0) { Dd 9 } else { '' })
        outlookCopilotLastActivityDate = $(if ($act -and $i % 2 -eq 1) { Dd 4 } else { '' }); oneNoteCopilotLastActivityDate = ''; loopCopilotLastActivityDate = ''
        copilotChatLastActivityDate = $(if ($act) { Dd 2 } else { '' })
    }
}
$g["GET beta/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D28')"] = @{ value = @($usage) }
$g['GET v1.0/admin/sharepoint/settings'] = @{ sharingCapability = 'externalUserAndGuestSharing'; sharingDomainRestrictionMode = 'none'; sharingAllowedDomainList = @(); sharingBlockedDomainList = @(); isResharingByExternalUsersEnabled = $true; isLegacyAuthProtocolsEnabled = $false; isUnmanagedSyncAppForTenantRestricted = $false; isRequireAcceptingUserToMatchInvitedUserEnabled = $true }

$topics = 'Projekt', 'Vertrieb', 'Konstruktion', 'Einkauf', 'Service', 'Fertigung', 'Qualität', 'Logistik', 'Marketing', 'HR', 'Finanzen', 'IT'
$groups = foreach ($i in 0..119) {
    $t = $topics[$i % $topics.Count]
    @{ id = (Id $i 'b2'); displayName = "$t $([int]($i / $topics.Count) + 1)"; visibility = $(if ($i % 9 -eq 4 -and $i -lt 126) { 'Public' } else { 'Private' }); mail = ("{0}{1}@{2}" -f $t.ToLower().Replace('ä', 'ae'), $i, $dom); createdDateTime = (D (30 + 11 * $i)); resourceProvisioningOptions = @(if ($i % 2 -eq 0) { 'Team' }) }
}
$g['GET v1.0/groups'] = @{ value = @($groups) }
foreach ($i in 0..119) { $g["GET v1.0/groups/$((Id $i 'b2'))/owners"] = @{ value = @(if ($i -notin 7, 23, 41, 66, 88, 101) { @{ id = (Id ($i % 50) 'a1') } }) } }

$sites = foreach ($i in 0..139) {
    $t = $topics[$i % $topics.Count]
    $inactive = $i % 3 -eq 1
    @{ siteUrl = "https://contosomb.sharepoint.com/sites/$($t.ToLower().Replace('ä','ae'))-$i"; isDeleted = $false; fileCount = 200 + ($i * 137) % 9000; activeFileCount = $(if ($inactive) { 0 } else { 20 + $i % 300 }); lastActivityDate = $(if ($inactive) { $(if ($i % 2 -eq 0) { '' } else { Dd (200 + $i) }) } else { Dd ($i % 60) }); storageUsedInBytes = [long](1GB * (1 + $i % 40)) }
}
$g["GET beta/reports/getSharePointSiteUsageDetail(period='D180')"] = @{ value = @($sites) }
$g['GET v1.0/admin/reportSettings'] = @{ displayConcealedNames = $false }
$g["GET beta/reports/getSharePointActivityUserDetail(period='D30')"] = @{ _status = 503; _error = 'ServiceUnavailable: the reporting service did not respond' }
$guests = foreach ($i in 0..86) { @{ id = (Id $i 'c3'); displayName = "Gast $($i + 1) (Partner)"; mail = "kontakt$i@partner$($i % 9).example"; createdDateTime = (D (60 + 9 * $i)); signInActivity = @{ lastSignInDateTime = $(if ($i % 16 -lt 9) { D (100 + $i) } else { D ($i % 60) }); lastSuccessfulSignInDateTime = $(if ($i % 16 -lt 9) { $null } else { D ($i % 60) }) } } }
$g["GET v1.0/users?`$filter=userType eq 'Guest'&`$select=id,displayName,mail,createdDateTime,signInActivity&`$top=999"] = @{ value = @($guests) }

$g['GET v1.0/security/dataSecurityAndGovernance/sensitivityLabels'] = @{ value = @(
        @{ id = (Id 1 'd4'); name = 'Öffentlich'; isEnabled = $true; priority = 0; applicableTo = 'email,file' }
        @{ id = (Id 2 'd4'); name = 'Intern'; isEnabled = $true; priority = 1; applicableTo = 'email,file,site,unifiedGroup' }
        @{ id = (Id 3 'd4'); name = 'Vertraulich'; isEnabled = $true; priority = 2; applicableTo = 'email,file,site,unifiedGroup' }
        @{ id = (Id 4 'd4'); name = 'Streng vertraulich'; isEnabled = $true; priority = 3; applicableTo = 'email,file' }
        @{ id = (Id 5 'd4'); name = 'Entwurf (alt)'; isEnabled = $false; priority = 4; applicableTo = 'file' }
    )
}
$g['GET beta/security/labels/retentionLabels'] = @{ _status = 403; _error = 'Forbidden: Caller does not have the RecordsManagement.Read.All permission' }

$agents = foreach ($i in 0..5) { @{ id = (Id $i 'e5'); displayName = @('Angebots-Agent', 'Service-Wissensagent', 'Einkauf-Assistent', 'HR-Fragen-Agent', 'Test-Agent Konstruktion', 'Reisekosten-Agent')[$i]; accountEnabled = ($i -ne 4); createdDateTime = (D (20 + 30 * $i)); agentIdentityBlueprintId = (Id 1 'e6') } }
$g['GET v1.0/servicePrincipals/microsoft.graph.agentIdentity'] = @{ value = @($agents) }
foreach ($i in 0..5) { $p = Person (60 + $i); $g["GET v1.0/servicePrincipals/$((Id $i 'e5'))/owners"] = @{ value = @(if ($i -notin 2, 5) { @{ id = (Id (60 + $i) 'a1'); displayName = $p.name; userPrincipalName = $p.upn } }) } }

$g['GET v1.0/policies/identitySecurityDefaultsEnforcementPolicy'] = @{ isEnabled = $false }
$breakGlass = @((Id 990 'a1'), (Id 991 'a1'))
$ca = @(
    @{ displayName = 'CA001 MFA für alle Nutzer'; state = 'enabled'; conditions = @{ users = @{ includeUsers = @('All'); excludeUsers = $breakGlass; excludeGroups = @(); excludeRoles = @() }; applications = @{ includeApplications = @('All'); excludeApplications = @() }; clientAppTypes = @('all') }; grantControls = @{ operator = 'OR'; builtInControls = @('mfa') } }
    @{ displayName = 'CA002 Legacy-Authentifizierung blockieren'; state = 'enabled'; conditions = @{ users = @{ includeUsers = @('All'); excludeUsers = $breakGlass; excludeGroups = @() }; applications = @{ includeApplications = @('All') }; clientAppTypes = @('exchangeActiveSync', 'other') }; grantControls = @{ operator = 'OR'; builtInControls = @('block') } }
    @{ displayName = 'CA003 Verwaltetes Gerät für Office 365 (Pilot)'; state = 'enabled'; conditions = @{ users = @{ includeUsers = @(); includeGroups = @((Id 900 'b1')); excludeUsers = @() }; applications = @{ includeApplications = @('Office365') }; clientAppTypes = @('all') }; grantControls = @{ operator = 'OR'; builtInControls = @('compliantDevice', 'domainJoinedDevice') } }
    @{ displayName = 'CA004 Admins phishing-resistent'; state = 'enabledForReportingButNotEnforced'; conditions = @{ users = @{ includeUsers = @(); includeRoles = @('62e90394-69f5-4237-9190-012177145e10', 'e8611ab8-c189-46e8-94e1-60213ab1f814', '194ae4cb-b126-40b2-bd5b-6091b380977d'); excludeUsers = $breakGlass }; applications = @{ includeApplications = @('All') }; clientAppTypes = @('all') }; grantControls = @{ operator = 'OR'; builtInControls = @(); authenticationStrength = @{ id = '00000000-0000-0000-0000-000000000004'; displayName = 'Phishing-resistant MFA'; allowedCombinations = @('windowsHelloForBusiness', 'fido2', 'x509CertificateMultiFactor') } } }
    @{ displayName = 'CA005 Gäste MFA'; state = 'enabled'; conditions = @{ users = @{ includeUsers = @('GuestsOrExternalUsers') }; applications = @{ includeApplications = @('All') }; clientAppTypes = @('all') }; grantControls = @{ operator = 'OR'; builtInControls = @('mfa') } }
)
$g['GET v1.0/identity/conditionalAccess/policies'] = @{ value = $ca }
$reg = foreach ($i in 0..411) { $p = Person $i; @{ userPrincipalName = $p.upn; userType = 'member'; isAdmin = ($i -lt 7); isMfaRegistered = ($i % 10 -ne 3 -and $i -ne 5) -or ($i -lt 5); isMfaCapable = ($i % 10 -ne 3) } }
$g['GET v1.0/reports/authenticationMethods/userRegistrationDetails'] = @{ value = @($reg) }
$gaId = Id 1 'f7'
$g['GET v1.0/directoryRoles'] = @{ value = @(@{ id = $gaId; displayName = 'Global Administrator'; roleTemplateId = '62e90394-69f5-4237-9190-012177145e10' }) }
$gas = foreach ($i in 0..5) { $p = Person (200 + $i); @{ '@odata.type' = '#microsoft.graph.user'; id = (Id (200 + $i) 'a1'); displayName = $(if ($i -lt 2) { "Notfallkonto $($i + 1)" } else { $p.name }); userPrincipalName = $(if ($i -lt 2) { "breakglass$($i + 1)@contosomb.onmicrosoft.com" } else { $p.upn }); assignedLicenses = @(if ($i -in 3, 4) { @{ skuId = $copilotSku } }) } }
$g["GET v1.0/directoryRoles/$gaId/members"] = @{ value = @($gas) }
$g['GET v1.0/policies/authorizationPolicy'] = @{ allowInvitesFrom = 'adminsAndGuestInviters'; guestUserRoleId = '10dae51f-b6af-4016-8d66-8c2a99b929b3'; allowEmailVerifiedUsersToJoinOrganization = $false; defaultUserRolePermissions = @{ allowedToCreateApps = $true; allowedToCreateSecurityGroups = $false; permissionGrantPoliciesAssigned = @('ManagePermissionGrantsForSelf.microsoft-user-default-low') } }

$graphSp = Id 1 '9a'
$roles = @(@{ id = '810c84a8-4a9e-49e6-bf7d-12d183f40d01'; value = 'Mail.Read' }, @{ id = '01d4889c-1287-42c6-ac1f-5d1e02578ef6'; value = 'Files.Read.All' }, @{ id = '332a536c-c7ef-4017-ab91-336970924f0d'; value = 'Sites.Read.All' }, @{ id = 'df021288-bdef-4463-88db-98f22de89214'; value = 'User.Read.All' })
$g["GET v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')"] = @{ id = $graphSp; appRoles = $roles }
$c1 = Id 11 '9b'; $c2 = Id 12 '9b'; $c3 = Id 13 '9b'; $c4 = Id 14 '9b'; $cms = Id 15 '9b'
$g['GET v1.0/oauth2PermissionGrants'] = @{ value = @(
        @{ clientId = $c1; consentType = 'AllPrincipals'; principalId = $null; resourceId = $graphSp; scope = 'User.Read Mail.Read Files.Read.All' }
        @{ clientId = $c2; consentType = 'Principal'; principalId = (Id 17 'a1'); resourceId = $graphSp; scope = 'User.Read Mail.ReadWrite' }
        @{ clientId = $c4; consentType = 'AllPrincipals'; principalId = $null; resourceId = $graphSp; scope = 'User.Read openid profile' }
        @{ clientId = $cms; consentType = 'AllPrincipals'; principalId = $null; resourceId = $graphSp; scope = 'Directory.Read.All Mail.Read' }
    )
}
$g["GET v1.0/servicePrincipals/$graphSp/appRoleAssignedTo"] = @{ value = @(
        @{ principalId = $c3; appRoleId = '01d4889c-1287-42c6-ac1f-5d1e02578ef6' }
        @{ principalId = $c3; appRoleId = '332a536c-c7ef-4017-ab91-336970924f0d' }
        @{ principalId = $c4; appRoleId = 'df021288-bdef-4463-88db-98f22de89214' }
    )
}
$g["GET v1.0/servicePrincipals/$c1"] = @{ id = $c1; displayName = 'Angebots-Assistent (Eigenentwicklung)'; appOwnerOrganizationId = (Id 1 'aa') }
$g["GET v1.0/servicePrincipals/$c2"] = @{ id = $c2; displayName = 'Mail-Sortierer Pro'; appOwnerOrganizationId = (Id 2 'aa') }
$g["GET v1.0/servicePrincipals/$c3"] = @{ id = $c3; displayName = 'Backup Cloud 365'; appOwnerOrganizationId = (Id 3 'aa') }
$g["GET v1.0/servicePrincipals/$c4"] = @{ id = $c4; displayName = 'Zeiterfassung Online'; appOwnerOrganizationId = (Id 4 'aa') }
$g["GET v1.0/servicePrincipals/$cms"] = @{ id = $cms; displayName = 'Microsoft first-party example'; appOwnerOrganizationId = 'f8cdef31-a31e-4b4a-93e4-5f571e91255a' }

$controls = @(
    @{ controlName = 'mfaRegistrationV2'; controlCategory = 'Identity'; scoreInPercentage = 89; score = 8 }
    @{ controlName = 'BlockLegacyAuthentication'; controlCategory = 'Identity'; scoreInPercentage = 100; score = 8 }
    @{ controlName = 'IntegratedApps'; controlCategory = 'Apps'; scoreInPercentage = 0; score = 0 }
    @{ controlName = 'dlp_datalossprevention'; controlCategory = 'Data'; scoreInPercentage = 50; score = 5 }
    @{ controlName = 'mip_autosensitivitylabelspolicies'; controlCategory = 'Data'; scoreInPercentage = 0; score = 0 }
    @{ controlName = 'PWAgePolicyNew'; controlCategory = 'Identity'; scoreInPercentage = 100; score = 8 }
    @{ controlName = 'SigninRiskPolicy'; controlCategory = 'Identity'; scoreInPercentage = 0; score = 0 }
    @{ controlName = 'OneAdmin'; controlCategory = 'Identity'; scoreInPercentage = 0; score = 0 }
)
$g['GET v1.0/security/secureScores'] = @{ value = @(@{ currentScore = 241.5; maxScore = 416; controlScores = $controls }) }
$g['GET v1.0/security/secureScoreControlProfiles'] = @{ value = @(
        @{ id = 'mfaRegistrationV2'; title = 'Ensure all users can complete multifactor authentication'; maxScore = 9 }
        @{ id = 'IntegratedApps'; title = 'Do not allow users to grant consent to unreliable applications'; maxScore = 4 }
        @{ id = 'dlp_datalossprevention'; title = 'Turn on data loss prevention policies'; maxScore = 10 }
        @{ id = 'mip_autosensitivitylabelspolicies'; title = 'Apply sensitivity labels automatically'; maxScore = 3 }
        @{ id = 'SigninRiskPolicy'; title = 'Turn on sign-in risk policy'; maxScore = 7 }
        @{ id = 'OneAdmin'; title = 'Designate more than one global admin (keep the number low)'; maxScore = 1 }
    )
}
$qid = Id 1 'ab'
$g['POST beta/security/auditLog/queries'] = @{ id = $qid; status = 'running' }
$g["GET beta/security/auditLog/queries/$qid"] = @{ id = $qid; status = 'succeeded' }
$hosts = 'Teams', 'Word', 'Outlook', 'BizChat', 'Excel', 'Teams', 'BizChat'
$recs = foreach ($i in 0..183) { $p = Person ($i % 31); @{ id = (Id $i 'ac'); userPrincipalName = $p.upn; auditData = @{ CopilotEventData = @{ AppHost = $hosts[$i % $hosts.Count]; AgentId = $(if ($i % 13 -eq 0) { 'CopilotStudio.Declarative.' + (Id 2 'e5') } else { $null }) } } } }
$g["GET beta/security/auditLog/queries/$qid/records"] = @{ value = @($recs) }

# ---------- optional readers ----------
$r = [ordered]@{}
$r['Get-LabelPolicy'] = @(@{ Name = 'Standard-Labelrichtlinie'; Enabled = $true; Labels = @('Öffentlich', 'Intern', 'Vertraulich', 'Streng vertraulich'); Settings = @("[defaultlabelid, $((Id 2 'd4'))]", '[mandatory, false]', '[requiredowngradejustification, true]') })
$r['Get-DlpCompliancePolicy'] = @(
    @{ Name = 'DLP Basis: Bank- und Personaldaten'; Guid = (Id 1 'ad'); Enabled = $true; Mode = 'Enable'; Workload = 'Exchange, SharePoint, OneDriveForBusiness'; EnforcementPlanes = @(); Locations = '' }
    @{ Name = 'Copilot: sensible Prompts'; Guid = (Id 2 'ad'); Enabled = $true; Mode = 'TestWithNotifications'; Workload = 'Applications'; EnforcementPlanes = @('CopilotExperiences'); Locations = '[{"Workload":"Applications","Location":"470f2276-e011-4e9d-a6ec-20768be3a4b0","Inclusions":[{"Type":"Tenant","Identity":"All"}]}]' }
)
$r['Get-DlpComplianceRule'] = @(
    @{ Name = 'Bankdaten extern blockieren'; ParentPolicyName = 'DLP Basis: Bank- und Personaldaten'; Disabled = $false; ContentContainsSensitiveInformation = @(@{ name = 'International Banking Account Number (IBAN)' }) }
    @{ Name = 'IBAN in Prompts'; ParentPolicyName = 'Copilot: sensible Prompts'; Disabled = $false; ContentContainsSensitiveInformation = @(@{ name = 'International Banking Account Number (IBAN)'; minCount = '1' }); RestrictAccess = @(@{ setting = 'ExcludeContentProcessing'; value = 'Block' }) }
)
$r['Get-ProtectionAlert'] = @(
    @{ Name = 'DLP-Treffer an IT-Sicherheit'; Category = 'DataLossPrevention'; Severity = 'Medium'; Disabled = $true; IsSystemRule = $false; NotifyUser = @("it-sicherheit@$dom") }
    @{ Name = 'Massenlöschung SharePoint'; Category = 'DataGovernance2'; Severity = 'High'; Disabled = $false; IsSystemRule = $false; NotifyUser = @("it-sicherheit@$dom") }
    @{ Name = 'Elevation of Exchange admin privilege'; Category = 'PermissionsManagement'; Severity = 'Low'; Disabled = $false; IsSystemRule = $true }
)
$r['Get-RetentionCompliancePolicy -DistributionDetail True'] = @(
    @{ Name = 'Copilot-Interaktionen 1 Jahr'; Guid = (Id 1 'ae'); Enabled = $true; DistributionStatus = 'Success'; Applications = @('User:M365Copilot') }
    @{ Name = 'Teams-Chats 2 Jahre'; Guid = (Id 2 'ae'); Enabled = $true; DistributionStatus = 'Success'; Applications = @(); TeamsChatLocation = @('All') }
)
$r['Get-RetentionComplianceRule'] = @(
    @{ Name = 'Copilot 365 Tage löschen'; Policy = (Id 1 'ae'); RetentionDuration = '365'; RetentionComplianceAction = 'Delete' }
    @{ Name = 'Teams 730 Tage'; Policy = (Id 2 'ae'); RetentionDuration = '730'; RetentionComplianceAction = 'KeepAndDelete' }
)
$spo = foreach ($s in $sites) {
    $u = $s.siteUrl
    @{ Url = $u; RestrictContentOrgWideSearch = ($u -match '/(hr-9|finanzen-10|finanzen-22)$'); RestrictedAccessControl = ($u -match '/hr-9$'); RestrictedAccessControlGroups = @(if ($u -match '/hr-9$') { (Id 9 'b2') }); SensitivityLabel = $(if ($u -match '/(hr-9|finanzen-10|finanzen-22)$') { (Id 3 'd4') } else { '' }) }
}
$r['Get-SPOSite -Limit All'] = @($spo)
$r['Get-SPODataAccessGovernanceInsight -ReportEntity PermissionedUsers'] = @(@{ ReportId = (Id 1 'af'); ReportName = 'Site-Berechtigungen SharePoint'; ReportEntity = 'PermissionedUsers'; Status = 'Completed'; Workload = 'SharePoint'; CreatedDateTime = (D 48); CountOfSitesInReport = 37; CountOfSitesInTenant = 140 })
$r['Get-SPODataAccessGovernanceInsight -ReportEntity EveryoneExceptExternalUsersAtSite'] = @(@{ ReportId = (Id 2 'af'); ReportEntity = 'EveryoneExceptExternalUsersAtSite'; Status = 'Completed'; Workload = 'SharePoint'; CreatedDateTime = (D 48); SitesFound = 9 })
$r['Get-SPODataAccessGovernanceInsight -ReportEntity SharingLinks_Anyone'] = @()
$r['Get-SPODataAccessGovernanceInsight -ReportEntity SensitivityLabelForFiles'] = @(@{ ReportId = (Id 3 'af'); ReportName = 'Dateien mit Label Vertraulich'; ReportEntity = 'SensitivityLabelForFiles'; Status = 'Completed'; Workload = 'SharePoint'; CreatedDateTime = (D 20); SitesFound = 22 })
$r['Get-AdminPowerAppEnvironment'] = @(
    @{ EnvironmentName = 'Default-' + (Id 1 'b0'); DisplayName = 'Contoso Maschinenbau (default)'; EnvironmentType = 'Default'; IsDefault = $true }
    @{ EnvironmentName = (Id 2 'b0'); DisplayName = 'Produktion'; EnvironmentType = 'Production'; IsDefault = $false }
    @{ EnvironmentName = (Id 3 'b0'); DisplayName = 'Entwicklung'; EnvironmentType = 'Developer'; IsDefault = $false }
    @{ EnvironmentName = (Id 4 'b0'); DisplayName = 'Vertrieb Agents'; EnvironmentType = 'Production'; IsDefault = $false }
)
$r['Get-AdminDlpPolicy'] = @(@{ DisplayName = 'Basis-DLP Produktion'; PolicyName = (Id 1 'b9'); EnvironmentType = 'OnlyEnvironments'; Environments = @(@{ name = (Id 2 'b0') }, @{ name = (Id 3 'b0') }) })
$pp = foreach ($i in 0..8) {
    $p = Person (120 + $i)
    @{ name = (Id $i 'ba'); properties_displayName = @('Angebots-Agent', 'Service-Wissen', 'Einkauf-Assistent', 'HR-Fragen', 'Reisekosten', 'Schichtplan-Bot', 'Messe-Agent', 'IT-Helpdesk', 'Produkt-FAQ')[$i]
        properties_environmentId = $(if ($i -lt 4) { 'Default-' + (Id 1 'b0') } else { (Id 4 'b0') }); properties_ownerId = (Id (120 + $i) 'a1'); properties_createdBy = $p.upn
        properties_authentication = @('Microsoft Entra', 'Microsoft Entra', 'None', 'Microsoft Entra', 'Microsoft Entra', 'Microsoft Entra', 'Generic OAuth 2.0', 'Microsoft Entra', 'Microsoft Entra')[$i]
        properties_sharedWithViewers = @{ userCount = (3 * $i); groupCount = ($i % 3); entireTenant = ($i -in 1, 3, 8) }
        properties_channels = @('Teams', 'Microsoft 365 Copilot')
        properties_powerPlatformConnectors = $(if ($i -in 0, 6) { @(@{ connectorId = 'shared_sharepointonline'; connectionMode = 'maker'; operations = @(@{ operationId = 'GetItems' }) }) } else { @(@{ connectorId = 'shared_office365'; connectionMode = 'invoker' }) })
    }
}
$r['PPAPI resourcequery'] = @($pp)

$ctx = [ordered]@{
    now = $now.ToString('o')
    tenant = @{ id = (Id 1 '00'); name = 'Contoso Maschinenbau GmbH'; domain = $dom }
    account = "it-admin@$dom"
    roles = @('Global Reader', 'Reports Reader', 'Compliance Data Administrator')
    scopes = @((Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Manifest.json') -Raw | ConvertFrom-Json).graphScopes.PSObject.Properties.Value | ForEach-Object { $_ })
    readers = @{ graph = $true; purview = $true; sharepoint = $true; powerplatform = $true; ppapi = $true; manual = $false }
    readerNotes = @{ purview = 'demo fixtures'; sharepoint = 'demo fixtures'; powerplatform = 'demo fixtures'; ppapi = 'demo fixtures' }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$g | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $OutDir 'graph.json') -Encoding utf8
$r | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $OutDir 'readers.json') -Encoding utf8
$ctx | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutDir 'context.json') -Encoding utf8
"demo fixtures written to $OutDir ($($g.Count) Graph responses, $($r.Count) reader responses)"
