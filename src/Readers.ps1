# Readers.ps1 — optional readers beyond Graph. All are opt-in switches and read-only.
#   -Purview        Security & Compliance PowerShell (ExchangeOnlineManagement)
#   -SharePoint     SharePoint Online Management Shell (Microsoft.Online.SharePoint.PowerShell)
#   -PowerPlatform  Microsoft.PowerApps.Administration.PowerShell (+ Power Platform API with -PowerPlatformClientId)
# Every cmdlet call goes through Invoke-CrReader so -Demo can answer it from fixtures.

$script:CrDemoCmd = $null
$script:CrReaderNotes = @{}

function Set-CrDemoCmd { param([hashtable]$Data) $script:CrDemoCmd = $Data }

function Get-CrReaderKey {
    param([string]$Name, [hashtable]$Parameters = @{})
    $p = ($Parameters.Keys | Sort-Object | ForEach-Object { "-$_ $($Parameters[$_])" }) -join ' '
    ("$Name $p").Trim()
}

function Invoke-CrReader {
    <#
      .SYNOPSIS  Runs one read-only cmdlet of an optional reader (or answers it from demo fixtures).
      .EXAMPLE   Invoke-CrReader Get-DlpComplianceRule
      .EXAMPLE   Invoke-CrReader Get-SPODataAccessGovernanceInsight @{ ReportEntity = 'PermissionedUsers' }
    #>
    param([Parameter(Mandatory, Position = 0)][string]$Name, [Parameter(Position = 1)][hashtable]$Parameters = @{})
    if ($Name -notmatch '^Get-') { throw "Refusing to run '$Name': readers are limited to Get- cmdlets." }
    if ($script:CrDemoCmd) {
        $key = Get-CrReaderKey $Name $Parameters
        if ($script:CrDemoCmd.ContainsKey($key)) { $hit = $script:CrDemoCmd[$key] }
        elseif ($script:CrDemoCmd.ContainsKey($Name)) { $hit = $script:CrDemoCmd[$Name] }
        else { throw (New-CrHttpError 404 "No demo fixture for: $key") }
        if ($hit -is [System.Collections.IDictionary] -and $hit.ContainsKey('_status')) { throw (New-CrHttpError ([int]$hit._status) "$($hit._error)") }
        if (@($hit).Count -eq 0) { return @() }
        return @(ConvertTo-Json -InputObject @($hit) -Depth 20 | ConvertFrom-Json)
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        # Deliberately free of licence/permission wording: Get-CrErrorState classifies on the message text,
        # and we do not know which of the two it is. Unknown with this detail is the honest answer.
        throw "Cmdlet '$Name' was not exposed to the signed-in account in this session, although the reader connected. Check the same value in the portal."
    }
    $p = @{ ErrorAction = 'Stop' } + $Parameters
    if ($cmd.Parameters.ContainsKey('WarningAction')) { $p.WarningAction = 'SilentlyContinue' }
    @(& $Name @p)
}

function Invoke-CrPowerPlatformQuery {
    <# Read query against the Power Platform inventory (POST is a query, not a change). Follows skipToken. #>
    param([Parameter(Mandatory)][hashtable]$Query)
    if ($script:CrDemoCmd) {
        $hit = $script:CrDemoCmd['PPAPI resourcequery']
        if ($null -eq $hit) { throw (New-CrHttpError 404 'No demo fixture for: PPAPI resourcequery') }
        return @($hit | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $skip = ''
    do {
        $Query.Options = @{ Top = 1000; SkipToken = $skip }
        $r = Invoke-RestMethod -Method Post -Uri 'https://api.powerplatform.com/resourcequery/resources/query?api-version=2024-10-01' `
            -Headers @{ Authorization = "Bearer $script:CrPpToken" } -ContentType 'application/json' -Body ($Query | ConvertTo-Json -Depth 10) -ErrorAction Stop
        foreach ($d in @($r.data)) { $rows.Add($d) }
        $skip = "$($r.skipToken)"
    } while ($skip)
    $rows.ToArray()
}

function Test-CrModule([string]$Name) { [bool](Get-Module $Name -ListAvailable) }

function Connect-CrPurview {
    param([string]$Account)
    if (-not (Test-CrModule 'ExchangeOnlineManagement')) {
        $script:CrReaderNotes.purview = 'module ExchangeOnlineManagement not installed'
        Write-Host '  ExchangeOnlineManagement not installed: Install-Module ExchangeOnlineManagement -Scope CurrentUser' -ForegroundColor DarkYellow
        return $false
    }
    try {
        Import-Module ExchangeOnlineManagement -ErrorAction Stop
        Write-Host 'Connecting to Security & Compliance PowerShell (browser window)...' -ForegroundColor Cyan
        # -DisableWAM: the Windows broker needs a parent window handle and fails from non-interactive hosts
        Connect-IPPSSession -UserPrincipalName $Account -ShowBanner:$false -DisableWAM -ErrorAction Stop
        $script:CrReaderNotes.purview = 'connected'
        return $true
    }
    catch { $script:CrReaderNotes.purview = "connection failed: $($_.Exception.Message)"; Write-Host "  Purview connection failed: $($_.Exception.Message)" -ForegroundColor DarkYellow; return $false }
}

function Connect-CrSharePoint {
    param([Parameter(Mandatory)][string]$AdminUrl)
    $mod = 'Microsoft.Online.SharePoint.PowerShell'
    if (-not (Test-CrModule $mod)) {
        $script:CrReaderNotes.sharepoint = "module $mod not installed"
        Write-Host "  $mod not installed: Install-Module $mod -Scope CurrentUser" -ForegroundColor DarkYellow
        return $false
    }
    try {
        try { Import-Module $mod -ErrorAction Stop -WarningAction SilentlyContinue }
        catch { if ($IsWindows) { Import-Module $mod -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue } else { throw } }
        Write-Host "Connecting to SharePoint Online ($AdminUrl, browser window)..." -ForegroundColor Cyan
        Connect-SPOService -Url $AdminUrl -ErrorAction Stop
        $script:CrReaderNotes.sharepoint = 'connected'
        return $true
    }
    catch { $script:CrReaderNotes.sharepoint = "connection failed: $($_.Exception.Message)"; Write-Host "  SharePoint connection failed: $($_.Exception.Message)" -ForegroundColor DarkYellow; return $false }
}

function Connect-CrPowerPlatform {
    $mod = 'Microsoft.PowerApps.Administration.PowerShell'
    if (-not (Test-CrModule $mod)) {
        $script:CrReaderNotes.powerplatform = "module $mod not installed"
        Write-Host "  $mod not installed: Install-Module $mod -Scope CurrentUser" -ForegroundColor DarkYellow
        return $false
    }
    try {
        # -DisableNameChecking: the module's own "unapproved verbs" warning only unsettles the admin.
        Import-Module $mod -ErrorAction Stop -WarningAction SilentlyContinue -DisableNameChecking 3>$null
        Write-Host 'Connecting to Power Platform admin (browser window)...' -ForegroundColor Cyan
        Add-PowerAppsAccount -ErrorAction Stop | Out-Null
        $script:CrReaderNotes.powerplatform = 'connected'
        return $true
    }
    catch { $script:CrReaderNotes.powerplatform = "connection failed: $($_.Exception.Message)"; Write-Host "  Power Platform connection failed: $($_.Exception.Message)" -ForegroundColor DarkYellow; return $false }
}

function Get-CrSharePointAdminUrl {
    <# contoso.onmicrosoft.com → https://contoso-admin.sharepoint.com #>
    param([string]$InitialDomain)
    if ($InitialDomain -match '^([^.]+)\.onmicrosoft\.com$') { return "https://$($Matches[1])-admin.sharepoint.com" }
    $null
}
