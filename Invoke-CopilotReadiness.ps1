<#
.SYNOPSIS
  Read-only Microsoft 365 tenant check for Microsoft 365 Copilot, AI agents
  and the security basics that matter for AI. One offline HTML report (German / English).

.DESCRIPTION
  Signs in once in the browser (Microsoft Graph Command Line Tools public client, delegated,
  read-only scopes; no app registration is created). One window opens, you pick your admin account,
  that is all — use -DeviceCode on a host without a desktop (SSH, remote shell). Optional readers are opt-in:
    -Purview        Security & Compliance PowerShell (labels policies, DLP, retention, alerts)
    -SharePoint     SharePoint Online PowerShell (RCD/RAC per site, data access governance reports)
    -PowerPlatform  Power Platform admin PowerShell (DLP for agent environments);
                    add -PowerPlatformClientId for the agent inventory API (needs your own app registration, see README)
  The only object the tool creates in the tenant is one Purview audit search for Copilot interactions.

.EXAMPLE
  ./Invoke-CopilotReadiness.ps1 -TenantId contoso.de

  Graph checks only, German report. The tenant is pinned: a sign-in to another tenant stops the run.

.EXAMPLE
  ./Invoke-CopilotReadiness.ps1 -TenantId contoso.de -Deep -Purview -SharePoint -Language en

  All Graph checks plus Purview and SharePoint, English report.

.EXAMPLE
  ./Invoke-CopilotReadiness.ps1 -TenantId contoso.de -Deep -PowerPlatform

  The Power Platform checks in a separate run (they cannot share one PowerShell session with -Purview).

.EXAMPLE
  ./Invoke-CopilotReadiness.ps1 -Logout -TenantId contoso.de

  Forget the saved sign-in for one tenant (without -TenantId: for all tenants).

.NOTES
  Free and open source (MIT). Read-only: nothing is changed in your tenant. https://govnex.de
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$TenantId = 'organizations',
    [ValidateSet('de', 'en')][string]$Language = 'de',
    [string]$OutputPath = (Join-Path $PSScriptRoot 'out'),
    [string[]]$Only,
    [switch]$Purview,
    [switch]$SharePoint,
    [string]$SharePointAdminUrl,
    [switch]$PowerPlatform,
    [string]$PowerPlatformClientId,
    [string]$AuditQueryId,
    [switch]$Deep,
    [switch]$DeviceCode,
    [switch]$Yes,
    [switch]$NoTokenCache,
    [switch]$Logout,
    # Development only: builds the report from the fictional Contoso fixtures in tests/, no sign-in.
    [Parameter(DontShow)][switch]$Demo,
    [Parameter(DontShow)][string]$DemoPath = (Join-Path $PSScriptRoot 'tests/fixtures/contoso'),
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$root = $PSScriptRoot
. (Join-Path $root 'src/Core.ps1')
. (Join-Path $root 'src/Graph.ps1')
. (Join-Path $root 'src/Auth.ps1')
. (Join-Path $root 'src/Readers.ps1')
Get-ChildItem (Join-Path $root 'src/Checks') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
. (Join-Path $root 'src/Report/Render.ps1')

$manifest = Get-Content (Join-Path $root 'src/Manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
$catalog = Get-Content (Join-Path $root 'src/Catalog.json') -Raw -Encoding utf8 | ConvertFrom-Json
$i18n = Import-CrI18n (Join-Path $root 'src/i18n.json')
$script:CrLanguage = $Language   # the console speaks the report's language

if ($Logout) {
    if (-not (Test-CrTokenCacheSupported)) { Write-Host (Get-CrConsoleText 'console.noCachePlatform') }
    elseif ($PSBoundParameters.ContainsKey('TenantId')) {
        $keys = Get-CrTenantCacheKeys -TenantId (Resolve-CrTenantId $TenantId) -CoreScopes @($manifest.graphScopes.core) -ExtendedScopes @($manifest.graphScopes.extended)
        if (Remove-CrTokenCache -Keys $keys) { Write-Host (Get-CrConsoleText 'console.loggedOutTenant') } else { Write-Host (Get-CrConsoleText 'console.noSavedSignIn') }
    }
    elseif (Remove-CrTokenCache) { Write-Host (Get-CrConsoleText 'console.loggedOutAll') }
    else { Write-Host (Get-CrConsoleText 'console.noSavedSignIn') }
    return
}

# "-Only S01,Z01" arrives as one string when the script is started with pwsh -File.
if ($Only) { $Only = @($Only | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() }) }
# Reject unknown check ids with a list of valid ones.
if ($Only) {
    $known = @($catalog.checks.id)
    $bad = @($Only | Where-Object { $_ -and $_ -notin $known })
    if ($bad.Count -gt 0) {
        Write-Host ''
        Write-Host ("Unknown check id in -Only: {0}" -f ($bad -join ', ')) -ForegroundColor Red
        Write-Host ("Valid ids: {0}" -f ($known -join ', '))
        Write-Host 'Leave -Only out to run every check.'
        exit 1
    }
}
$product = $manifest.product

Write-Host ''
Write-Host ("{0} v{1}  —  read-only" -f $product.name, $product.version) -ForegroundColor Cyan
Write-Host ''
$started = Get-Date

# ---------- sign-in and context ----------
$roles = @(); $readerState = @{ graph = $true; purview = $false; sharepoint = $false; powerplatform = $false; ppapi = $false; manual = $false }
if ($Demo) {
    $ctxFile = Get-Content (Join-Path $DemoPath 'context.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    Set-CrDemoData (Get-Content (Join-Path $DemoPath 'graph.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)
    Set-CrDemoCmd (Get-Content (Join-Path $DemoPath 'readers.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)
    $script:CrNow = ([datetime]$ctxFile.now).ToUniversalTime()
    $script:CrCtx = [ordered]@{ TenantId = $ctxFile.tenant.id; TenantName = $ctxFile.tenant.name; DefaultDomain = $ctxFile.tenant.domain; InitialDomain = $ctxFile.tenant.domain; Mode = 'delegated'; Account = $ctxFile.account; Scopes = @($ctxFile.scopes); ScopeFallback = $false }
    $roles = @($ctxFile.roles)
    foreach ($k in @($ctxFile.readers.Keys)) { $readerState[$k] = [bool]$ctxFile.readers[$k] }
    foreach ($k in @($ctxFile.readerNotes.Keys)) { $script:CrReaderNotes[$k] = $ctxFile.readerNotes[$k] }
    Write-Host "Demo mode: fictional tenant $($ctxFile.tenant.name), no sign-in." -ForegroundColor DarkYellow
}
else {
    # Everything the admin is entitled to know before a single call is made. German by default.
    $u = { param($k) Get-CrUiText -I18n $i18n -Key $k -Language $Language }
    $scopesToAsk = @($manifest.graphScopes.core) + $(if ($Deep) { @($manifest.graphScopes.extended) } else { @() })
    Write-Host ''
    Write-Host ("  " + (& $u 'disclosure.title')) -ForegroundColor White
    Write-Host ('  ' + ('-' * 76)) -ForegroundColor DarkGray
    foreach ($k in 'disclosure.readonly', 'disclosure.account', 'disclosure.local', 'disclosure.creates', 'disclosure.reads', 'disclosure.revoke', 'disclosure.source') {
        Write-Host ''
        Write-Host ("  " + (Format-CrWrap (& $u $k) 76 '  '))
    }
    Write-Host ''
    Write-Host ("  {0} ({1}):" -f (& $u 'disclosure.scopes'), $scopesToAsk.Count) -ForegroundColor White
    foreach ($s in $scopesToAsk) { Write-Host ("    - {0}" -f $s) -ForegroundColor Gray }
    Write-Host ''
    if (-not $Yes) {
        Write-Host ("  " + (& $u 'disclosure.continue')) -ForegroundColor Cyan
        # The disclosure is the trust argument: without a console that can confirm it, stop and ask for -Yes
        # instead of carrying on silently (scheduled task, redirected input, pwsh -NonInteractive).
        $canAsk = $true
        try { if ([Console]::IsInputRedirected) { $canAsk = $false } else { Read-Host | Out-Null } } catch { $canAsk = $false }
        if (-not $canAsk) { Write-Host ''; Write-Host ("  " + (Get-CrConsoleText 'console.nonInteractive')) -ForegroundColor Yellow; exit 2 }
    }

    # Default asks for the core scopes only. In a tenant that already consented the Graph Command Line
    # Tools (any Graph PowerShell user) that often means no consent screen at all, just an account picker.
    # The three newer scopes are asked for only with -Deep.
    # Not "$x = if (...) {} else { @() }": PowerShell unrolls the empty array to nothing, $x becomes $null,
    # and $null bound to [string[]] arrives as one empty scope that Entra rejects (AADSTS70011).
    $extendedScopes = @()
    if ($Deep) { $extendedScopes = @($manifest.graphScopes.extended) }
    # Delegated only: the tool never uses an app registration or a client secret.
    # A failed sign-in ends with one readable sentence, not a PowerShell stack trace. Nothing was read at this point.
    try { Connect-CrGraph -TenantId $TenantId -CoreScopes @($manifest.graphScopes.core) -ExtendedScopes $extendedScopes -DeviceCode:$DeviceCode -NoTokenCache:$NoTokenCache }
    catch {
        Write-Host ''
        Write-Host ("  " + (Get-CrConsoleText 'console.signInFailed')) -ForegroundColor Red
        Write-Host ("  " + (Format-CrWrap "$($_.Exception.Message)" 100 '  ')) -ForegroundColor Yellow
        exit 1
    }
    # No -TenantId was pinned, so the tenant followed from whichever account was picked: confirm it
    # before anything is read. With -TenantId the match was already enforced during sign-in.
    if (-not $Yes -and -not $PSBoundParameters.ContainsKey('TenantId') -and $script:CrCtx.Mode -eq 'delegated') {
        Write-Host ''
        Write-Host ("  " + (& $u 'tenantConfirm.title')) -ForegroundColor White
        Write-Host ("  " + (& $u 'tenantConfirm.continue')) -ForegroundColor Cyan
        $canAsk = $true
        try { if ([Console]::IsInputRedirected) { $canAsk = $false } else { Read-Host | Out-Null } } catch { $canAsk = $false }
        if (-not $canAsk) { Write-Host ''; Write-Host ("  " + (Get-CrConsoleText 'console.nonInteractive')) -ForegroundColor Yellow; exit 2 }
    }
    if ($script:CrCtx.Mode -eq 'delegated') {
        try { $roles = @(Invoke-CrGraph '/me/memberOf/microsoft.graph.directoryRole?$select=displayName,roleTemplateId' -All | ForEach-Object displayName) } catch { $roles = @('(not readable)') }
    }
    if ($script:CrCtx.Mode -eq 'app' -and ($Purview -or $SharePoint -or $PowerPlatform)) {
        Write-Host 'App-only mode: optional readers need an interactive sign-in and are skipped.' -ForegroundColor DarkYellow
    }
    elseif ($script:CrCtx.Mode -eq 'delegated') {
        # ExchangeOnlineManagement and Microsoft.PowerApps.Administration.PowerShell ship different
        # Microsoft.Identity.Client versions and cannot both authenticate in one process: whichever
        # connects first wins and the other fails to load its assembly, in either order.
        # Purview feeds seven checks against two, so Purview keeps the
        # session and the Power Platform checks stay Manual with a note to run them separately.
        if ($Purview -and $PowerPlatform) {
            Write-Host '  -Purview and -PowerPlatform cannot share one PowerShell session (the two modules ship different Microsoft.Identity.Client versions).' -ForegroundColor DarkYellow
            Write-Host '  Purview is used in this run. For A02/A03 start a second run with -PowerPlatform (without -Purview).' -ForegroundColor DarkYellow
            $script:CrReaderNotes.powerplatform = 'skipped: cannot share a session with -Purview; run -PowerPlatform in a separate run'
            $PowerPlatform = [switch]$false
        }
        if ($Purview) { $readerState.purview = Connect-CrPurview -Account $script:CrCtx.Account }
        if ($SharePoint) {
            $url = if ($SharePointAdminUrl) { $SharePointAdminUrl } else { Get-CrSharePointAdminUrl $script:CrCtx.InitialDomain }
            if ($url) { $readerState.sharepoint = Connect-CrSharePoint -AdminUrl $url } else { $script:CrReaderNotes.sharepoint = 'admin URL unknown: pass -SharePointAdminUrl' }
        }
        if ($PowerPlatform) {
            $readerState.powerplatform = Connect-CrPowerPlatform
            if ($PowerPlatformClientId) {
                try { Connect-CrPowerPlatformApi -ClientId $PowerPlatformClientId -Tenant $script:CrCtx.TenantId -DeviceCode:$DeviceCode; $readerState.ppapi = $true; $script:CrReaderNotes.ppapi = 'connected' }
                catch { $script:CrReaderNotes.ppapi = "sign-in failed: $($_.Exception.Message)" }
            }
            else { $script:CrReaderNotes.ppapi = 'no -PowerPlatformClientId (needs your own app registration, see README)' }
        }
    }
}

# ---------- preflight ----------
$plans = @(); $plansKnown = $true
try { $plans = @(Get-CrSkus | ForEach-Object { $_.servicePlans.servicePlanName } | Select-Object -Unique) } catch { $plansKnown = $false; Write-Host "Licences not readable: $($_.Exception.Message)" -ForegroundColor DarkYellow }
$context = @{ Mode = $script:CrCtx.Mode; Scopes = @($script:CrCtx.Scopes); ServicePlans = $plans; ServicePlansKnown = $plansKnown; Readers = $readerState }
$caps = @(Get-CrCapabilities -Catalog $catalog -Context $context -Manifest $manifest)
$ids = @($catalog.checks.id)
if ($Only) { $ids = @($ids | Where-Object { $_ -in $Only }) }
$capSummary = @(Get-CrCapabilitySummary -Capabilities ($caps | Where-Object { $_.id -in $ids }) -Context $context)

$t = { param($k) Get-CrConsoleText $k }
Write-Host ''
Write-Host (& $t 'console.preflight') -ForegroundColor White
Write-Host ("  {0} {1}" -f (& $t 'console.roles'), $(if ($roles) { $roles -join ', ' } else { (& $t 'console.noneFound') }))
Write-Host ("  {0} {1}" -f (& $t 'console.copilotLicence'), $(if ($plansKnown) { if (Test-CrHasCopilot) { (& $t 'yes') } else { (& $t 'no') } } else { (& $t 'console.unknown') }))
$capSummary | ForEach-Object {
    $note = $script:CrReaderNotes[$_.reader]
    Write-Host ("  {0,-14} {1,-14} {2} {3,2}  {4} {5,2}  {6}" -f $_.reader, $(if ($_.connected) { (& $t 'connected') } else { (& $t 'notConnected') }), (& $t 'console.run'), $_.run, (& $t 'console.skipped'), $_.skipped, $(if ($note) { "($note)" } else { '' })) -ForegroundColor $(if ($_.connected) { 'Gray' } else { 'DarkGray' })
}
if (-not $Demo -and -not $Deep) {
    $needDeep = @($caps | Where-Object { $_.id -in $ids -and -not $_.run -and $_.msg -eq 'gen.scopeMissing' })
    if ($needDeep.Count -gt 0) {
        Write-Host ("  " + ((& $t 'console.needDeep') -replace '\{n\}', $needDeep.Count -replace '\{ids\}', (@($needDeep.id) -join ', '))) -ForegroundColor DarkYellow
    }
}
Write-Host ''

# ---------- run ----------
$capById = @{}; foreach ($c in $caps) { $capById[$c.id] = $c }
if (@('N01', 'N02') | Where-Object { $_ -in $ids -and $capById[$_].run }) { Start-CrAuditQuery -ReuseId $AuditQueryId }
$results = New-Object System.Collections.Generic.List[object]
foreach ($a in $catalog.areas) {
    $these = @($catalog.checks | Where-Object { $_.area -eq $a.key -and $_.id -in $ids })
    if (-not $these) { continue }
    Write-Host ("{0} — {1}" -f $a.n, $(if ($Language -eq 'de') { $a.de } else { $a.en })) -ForegroundColor White
    foreach ($c in $these) {
        $cap = $capById[$c.id]
        if ($cap.run) { $results.Add((& "Test-Cr$($c.id)")) }
        else {
            $r = New-CrResult -Id $c.id -State $cap.state -Msg $cap.msg -Arguments $cap.args
            $r | Add-Member -NotePropertyName DurationMs -NotePropertyValue 0 -Force
            Write-CrResultLine $r
            $results.Add($r)
        }
    }
}

# ---------- score, plan, output ----------
$s = $manifest.scoring
$scores = Get-CrScores -Catalog $catalog -Results $results -MinCoverage $s.minCoverage -MinAreaCoverage $s.minAreaCoverage -Good $s.good -Warn $s.warn -PartialRun:([bool]$Only)
$plan = Get-CrActionPlan -Catalog $catalog -Results $results
$runId = New-CrRunId
$data = [ordered]@{
    product   = $product.name
    version   = $product.version
    runId     = $runId
    generated = $(if ($Demo) { $script:CrNow.ToString('o') } else { (Get-Date).ToUniversalTime().ToString('o') })
    demo      = [bool]$Demo
    partialRun = [bool]$Only
    tenant    = [ordered]@{ id = $script:CrCtx.TenantId; name = $script:CrCtx.TenantName; domain = $script:CrCtx.DefaultDomain; mode = $script:CrCtx.Mode; account = $script:CrCtx.Account }
    preflight = [ordered]@{
        roles = $roles; servicePlansKnown = $plansKnown
        skus = @(try { Get-CrSkus | Where-Object { $_.prepaidUnits.enabled -gt 0 } | ForEach-Object { $_.skuPartNumber } } catch { @() })
        scopeFallback = [bool]$script:CrCtx.ScopeFallback
        readers = @($capSummary | ForEach-Object { [ordered]@{ reader = $_.reader; connected = $_.connected; run = $_.run; skipped = $_.skipped; skippedIds = $_.skippedIds; note = $script:CrReaderNotes[$_.reader] } })
    }
    scores    = $scores
    plan      = $plan
    results   = $results
    createsInTenant = @($manifest.createsInTenant)
    durationSec = [int]((Get-Date) - $started).TotalSeconds
}
$data.sha256 = Get-CrResultHash $data.results

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$safe = ($script:CrCtx.DefaultDomain ?? 'tenant') -replace '[^a-zA-Z0-9.-]', ''
$base = Join-Path $OutputPath "$($product.filePrefix)-$safe-$runId"
$data | ConvertTo-Json -Depth 14 | Set-Content "$base.json" -Encoding utf8
ConvertTo-CrReport -Data $data -Catalog $catalog -I18n $i18n -Manifest $manifest -Language $Language -TemplatePath (Join-Path $root 'src/Report/template.html') -OutFile "$base.html"

$o = $scores.overall
Write-Host ''
Write-Host ("{0} {1}   {2} {3} %   {4} {5}" -f (& $t 'console.score'), $(if ($null -ne $o.score) { "$($o.score) %" } else { 'n/a' }), (& $t 'console.coverage'), $o.coverage, (& $t 'console.verdict'), (& $t "verdict.$($o.verdict)")) -ForegroundColor Cyan
Write-Host ("{0,-9} {1}" -f (& $t 'console.report'), "$base.html")
Write-Host ("{0,-9} {1}   {2}" -f (& $t 'console.data'), "$base.json", (& $t 'console.keepLocal'))
if (-not $NoOpen -and ($IsWindows -or $IsMacOS)) { try { Invoke-Item "$base.html" } catch { Write-Verbose 'could not open the report' } }
