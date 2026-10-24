# Graph.ps1 — thin Graph client: paging, throttling, beta switch, CSV reports, demo fixtures.
# In -Demo mode every request is answered from fixture JSON (no network, no sign-in).

$script:CrDemoData = $null

function Set-CrDemoData {
    param([hashtable]$Data)
    $script:CrDemoData = $Data
}

function New-CrHttpError {
    # an exception that carries an HTTP status, so fixtures and real calls map to states the same way
    param([int]$Status, [string]$Message)
    $ex = [System.Exception]::new("HTTP $Status $Message")
    $ex.Data['HttpStatus'] = $Status
    $ex
}

function Get-CrDemoResponse {
    param([string]$Method, [string]$Version, [string]$Path)
    $key = "$Method $Version$Path"
    $short = "$Method $Version" + ($Path -split '\?')[0]
    if ($script:CrDemoData.ContainsKey($key)) { $hit = $script:CrDemoData[$key] }
    elseif ($script:CrDemoData.ContainsKey($short)) { $hit = $script:CrDemoData[$short] }
    else { throw (New-CrHttpError 404 "No demo fixture for: $key") }
    if ($hit -is [System.Collections.IDictionary] -and $hit.ContainsKey('_status')) { throw (New-CrHttpError ([int]$hit._status) "$($hit._error)") }
    # round-trip so callers get the same PSCustomObject shape as Invoke-RestMethod
    ConvertTo-Json -InputObject $hit -Depth 20 | ConvertFrom-Json
}

function Invoke-CrGraph {
    <#
      .SYNOPSIS  Call a Graph path. Follows @odata.nextLink when -All. Retries on 429/503/504.
      .EXAMPLE   Invoke-CrGraph '/groups?$top=999' -All
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [switch]$Beta,
        [switch]$All,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [object]$Body,
        [hashtable]$Headers = @{},
        [int]$MaxRetries = 5
    )
    $ver = if ($Beta) { 'beta' } else { 'v1.0' }
    if ($script:CrDemoData) {
        if ($Path -eq '/$batch') {
            $responses = foreach ($q in $Body.requests) {
                try { [pscustomobject]@{ id = $q.id; status = 200; body = (Get-CrDemoResponse -Method GET -Version $ver -Path $q.url) } }
                catch { [pscustomobject]@{ id = $q.id; status = [int]$_.Exception.Data['HttpStatus']; body = $null } }
            }
            return [pscustomobject]@{ responses = @($responses) }
        }
        $r = Get-CrDemoResponse -Method $Method -Version $ver -Path $Path
        if ($All) { return @($r.value) }
        return $r
    }
    $base = "https://graph.microsoft.com/$ver"
    $uri = if ($Path -like 'https://*') { $Path } else { $base + $Path }
    $items = New-Object System.Collections.Generic.List[object]
    $first = $null
    while ($uri) {
        $h = @{ Authorization = "Bearer $(Get-CrAccessToken)"; 'Content-Type' = 'application/json' } + $Headers
        $attempt = 0
        while ($true) {
            try {
                $params = @{ Method = $Method; Uri = $uri; Headers = $h; ErrorAction = 'Stop' }
                if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10) }
                $r = Invoke-RestMethod @params
                break
            }
            catch {
                $status = Get-CrHttpStatus $_
                if (($status -eq 429 -or $status -eq 503 -or $status -eq 504) -and $attempt -lt $MaxRetries) {
                    $wait = 5
                    try { $wait = [int]$_.Exception.Response.Headers.GetValues('Retry-After')[0] } catch { Write-Verbose 'no Retry-After header' }
                    Write-Verbose "Throttled ($status) on $uri, waiting $wait s"
                    Start-Sleep -Seconds ([Math]::Max($wait, 2)); $attempt++; continue
                }
                throw
            }
        }
        if (-not $first) { $first = $r }
        if ($All -and $r.PSObject.Properties['value']) {
            foreach ($i in $r.value) { $items.Add($i) }
            $uri = $r.'@odata.nextLink'
            # The bearer token goes to Microsoft Graph only, never to a host a response happens to name.
            if ($uri -and $uri -notlike 'https://graph.microsoft.com/*') { throw "Refusing to follow a paging link outside graph.microsoft.com: $uri" }
        }
        else { $uri = $null }
    }
    if ($All) { return $items.ToArray() }
    return $first
}

function Invoke-CrGraphBatch {
    <#
      .SYNOPSIS  Read-only $batch of GET requests (max 20 each). Returns one row per request with status and body.
                 Failed or throttled sub-requests are retried once and then reported, never dropped.
    #>
    param([Parameter(Mandatory)][string[]]$Urls)
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Urls.Count; $i += 20) {
        $slice = @($Urls[$i..([Math]::Min($i + 19, $Urls.Count - 1))])
        $pending = 0..($slice.Count - 1)
        $done = @{}
        for ($try = 0; $try -lt 2 -and $pending.Count -gt 0; $try++) {
            $reqs = @($pending | ForEach-Object { @{ id = "$_"; method = 'GET'; url = $slice[$_] } })
            $b = Invoke-CrGraph '/$batch' -Method POST -Body @{ requests = $reqs }
            foreach ($resp in $b.responses) { $done[[int]$resp.id] = $resp }
            $pending = @($pending | Where-Object { -not $done.ContainsKey($_) -or $done[$_].status -in 429, 503, 504 })
            if ($pending.Count -gt 0 -and -not $script:CrDemoData) { Start-Sleep -Seconds 3 }
        }
        for ($k = 0; $k -lt $slice.Count; $k++) {
            $resp = $done[$k]
            $out.Add([pscustomobject]@{ url = $slice[$k]; status = $(if ($resp) { [int]$resp.status } else { 0 }); body = $(if ($resp) { $resp.body } else { $null }) })
        }
    }
    , $out.ToArray()
}

function Invoke-CrGraphReport {
    <#
      .SYNOPSIS  Usage-report functions. Tries beta JSON ($format=application/json) first, then the
                 v1.0 CSV (302 → download URL) via HttpClient with redirects disabled.
      .EXAMPLE   Invoke-CrGraphReport "/reports/getSharePointSiteUsageDetail(period='D180')"
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($script:CrDemoData) { return @(Invoke-CrGraph $Path -Beta -All) }
    $jsonError = $null
    try {
        $sep = if ($Path -match '\?') { '&' } else { '?' }
        $rows = Invoke-CrGraph ($Path + $sep + '$format=application/json') -Beta -All
        if ($rows) { return @($rows) }
    }
    catch { $jsonError = $_; Write-Verbose "JSON report failed ($($_.Exception.Message)); falling back to CSV" }
    if ($jsonError -and (Get-CrHttpStatus $jsonError) -in 401, 403) { throw $jsonError }
    $handler = [System.Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new('GET', "https://graph.microsoft.com/v1.0$Path")
        $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', (Get-CrAccessToken))
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        if ($code -in 301, 302, 307, 308) {
            $loc = $resp.Headers.Location.AbsoluteUri
            $dl = [System.Net.Http.HttpClient]::new()
            try { $csv = $dl.GetStringAsync($loc).GetAwaiter().GetResult() } finally { $dl.Dispose() }
        }
        elseif ($code -eq 200) { $csv = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
        else { throw (New-CrHttpError $code ($resp.Content.ReadAsStringAsync().GetAwaiter().GetResult())) }
    }
    finally { $client.Dispose() }
    $csv = $csv.TrimStart([char]0xFEFF)
    $rows = @($csv | ConvertFrom-Csv)
    # normalise CSV headers to the JSON property names (remove spaces / brackets, lower first char)
    $out = foreach ($r in $rows) {
        $o = [ordered]@{}
        foreach ($pp in $r.PSObject.Properties) {
            $n = ($pp.Name -replace '[\s\(\)]', '') -replace '^Byte$', ''
            $n = $n.Substring(0, 1).ToLower() + $n.Substring(1)
            if ($n -eq 'storageUsedByte') { $n = 'storageUsedInBytes' }
            if ($n -eq 'storageAllocatedByte') { $n = 'storageAllocatedInBytes' }
            $o[$n] = $pp.Value
        }
        [pscustomobject]$o
    }
    return @($out)
}
