# Auth.ps1 — token acquisition without any module dependency.
# Modes:
#   1. Delegated, interactive browser sign-in (default): authorization code + PKCE on a loopback port.
#      The admin gets one browser window, picks the account and is done — nothing to type.
#      Uses the Microsoft Graph Command Line Tools public client id, so the customer creates no app
#      registration. Consent is needed once.
#   2. Delegated device code (-DeviceCode, or automatic fallback when no browser can be reached):
#      for remote sessions, SSH and hosts without a desktop.
#   3. App-only client credentials (-ClientId/-ClientSecret) for test tenants. Optional readers are skipped.
# The scope list lives in src/Manifest.json (core + extended). If the tenant rejects an extended scope,
# the sign-in is retried with the core scopes and the affected checks show NoPermission.

$script:CrGraphPublicClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'   # Microsoft Graph Command Line Tools
$script:CrDelegatedScopes = @()

function Set-CrScopes {
    param([string[]]$Scopes)
    # Drop empty and null entries: one of them becomes the scope "https://graph.microsoft.com/" and
    # Entra then rejects the whole sign-in with AADSTS70011.
    $script:CrDelegatedScopes = @($Scopes | Where-Object { "$_".Trim() })
}

# ---------- saved sign-in (refresh token only, DPAPI, per Windows user) ----------
# Stores nothing but the refresh token for the read-only delegated scopes, encrypted with
# ProtectedData/DPAPI at CurrentUser scope: only the same Windows user on the same machine can read it.
# DPAPI exists only on Windows, so on Linux/macOS nothing is cached and every run signs in.
# -NoTokenCache turns it off, -Logout deletes the file.

$script:CrTokenCacheEnabled = $false
$script:CrTokenCacheKey = $null

$script:CrTokenCachePathOverride = $null

function Get-CrTokenCachePath {
    # The override exists so tests never read, write or delete the real saved sign-in of the user.
    if ($script:CrTokenCachePathOverride) { return $script:CrTokenCachePathOverride }
    if ($IsWindows -and $env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'govnex/cr-token.dat') }
    $null
}

function Test-CrTokenCacheSupported { [bool](Get-CrTokenCachePath) }

function New-CrTokenCacheKey {
    <# One entry per tenant + client + exact scope set: a refresh token for the core set must never be
       reused for a -Deep run, which asks for more. #>
    param([Parameter(Mandatory)][string]$TenantId, [string[]]$Scopes = @(), [string]$ClientId = '')
    $raw = "$TenantId|$ClientId|$((@($Scopes) | Sort-Object -Unique) -join ' ')"
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($raw))
    ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-CrCachedRefreshToken {
    param([Parameter(Mandatory)][string]$Key)
    $path = Get-CrTokenCachePath
    if (-not $path -or -not (Test-Path $path)) { return $null }
    try {
        $e = @((Get-Content $path -Raw -Encoding utf8 | ConvertFrom-Json).entries) | Where-Object { $_.key -eq $Key } | Select-Object -First 1
        if (-not $e) { return $null }
        $clear = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($e.rt), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [Text.Encoding]::UTF8.GetString($clear)
    }
    catch { $null }   # wrong user, wrong machine or a damaged file: sign in again
}

function Set-CrCachedRefreshToken {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$RefreshToken)
    $path = Get-CrTokenCachePath
    if (-not $path) { return }
    try {
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $keep = @()
        if (Test-Path $path) {
            # The whole pipeline must stay in @(): with exactly one remaining entry Where-Object returns a
            # scalar PSCustomObject, and the += below then throws (no op_Addition) — which silently lost
            # the second tenant's entry until a test caught it.
            try { $keep = @(@((Get-Content $path -Raw -Encoding utf8 | ConvertFrom-Json).entries) | Where-Object { $_ -and $_.key -ne $Key }) } catch { $keep = @() }
        }
        $enc = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect(
                [Text.Encoding]::UTF8.GetBytes($RefreshToken), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
        $keep += [pscustomobject]@{ key = $Key; rt = $enc; saved = (Get-Date).ToUniversalTime().ToString('o') }
        [pscustomobject]@{ entries = @($keep) } | ConvertTo-Json -Depth 4 | Set-Content -Path $path -Encoding utf8
    }
    # A failing cache must never break the run, but it must not be invisible either.
    catch { Write-Host "  The sign-in could not be saved: $($_.Exception.Message)" -ForegroundColor DarkGray }
}

function Remove-CrTokenCache {
    <# Without -Keys: forget every saved sign-in. With -Keys: forget only those entries (one tenant). #>
    param([string[]]$Keys)
    $path = Get-CrTokenCachePath
    if (-not $path -or -not (Test-Path $path)) { return $false }
    if (-not $Keys) { Remove-Item $path -Force; return $true }
    $all = @(@((Get-Content $path -Raw -Encoding utf8 | ConvertFrom-Json).entries) | Where-Object { $_ })
    $keep = @($all | Where-Object { $_.key -notin $Keys })
    if ($keep.Count -eq $all.Count) { return $false }
    [pscustomobject]@{ entries = @($keep) } | ConvertTo-Json -Depth 4 | Set-Content -Path $path -Encoding utf8
    $true
}

function Get-CrTenantCacheKeys {
    <# Every cache key one tenant can have: core set and core + extended set. #>
    param([Parameter(Mandatory)][string]$TenantId, [string[]]$CoreScopes, [string[]]$ExtendedScopes)
    @(
        New-CrTokenCacheKey -TenantId $TenantId -Scopes @($CoreScopes | Where-Object { $_ }) -ClientId $script:CrGraphPublicClientId
        New-CrTokenCacheKey -TenantId $TenantId -Scopes @(@($CoreScopes) + @($ExtendedScopes) | Where-Object { $_ }) -ClientId $script:CrGraphPublicClientId
    )
}

function Save-CrSessionToken {
    <# Keeps the newest refresh token (Entra rotates it on every refresh). #>
    if ($script:CrTokenCacheEnabled -and $script:CrCtx.RefreshToken) {
        $script:CrTokenCacheKey = New-CrTokenCacheKey -TenantId $script:CrCtx.CacheTenant -Scopes $script:CrDelegatedScopes -ClientId $script:CrGraphPublicClientId
        Set-CrCachedRefreshToken -Key $script:CrTokenCacheKey -RefreshToken $script:CrCtx.RefreshToken
    }
}

function Get-CrScopeString([string[]]$Scopes, [string]$Resource = 'https://graph.microsoft.com') {
    ((@($Scopes) | ForEach-Object { "$Resource/$_" }) + 'offline_access') -join ' '
}

function ConvertFrom-CrIssuer {
    <# Pure: the tenant id inside an OpenID issuer URL, or $null for the '{tenantid}' placeholder that
       'organizations' and 'common' return. Tested. #>
    param([string]$Issuer)
    if ("$Issuer" -match '^https://login\.microsoftonline\.com/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/v2\.0/?$') { return $Matches[1].ToLowerInvariant() }
    $null
}

function Resolve-CrTenantId {
    <# The tenant id behind a domain or id, read from the tenant's public OpenID metadata — no sign-in,
       no token, nothing tenant-specific is sent. It lets 'contoso.de', 'contoso.onmicrosoft.com' and the
       id share ONE saved sign-in instead of opening a browser window for every spelling. Falls back to
       the typed value when the metadata cannot be read; 'organizations' / 'common' cannot be resolved. #>
    param([Parameter(Mandatory)][string]$Tenant)
    if ($Tenant -in 'organizations', 'common', 'consumers') { return $Tenant }
    try {
        $meta = Invoke-RestMethod -Method Get -Uri "https://login.microsoftonline.com/$([Uri]::EscapeDataString($Tenant))/v2.0/.well-known/openid-configuration" -TimeoutSec 20
        $id = ConvertFrom-CrIssuer $meta.issuer
        if ($id) { return $id }
    }
    catch { Write-Verbose "tenant metadata not readable for '$Tenant': $($_.Exception.Message)" }
    $Tenant
}

function Connect-CrGraph {
    [CmdletBinding()]
    param(
        [string]$TenantId = 'organizations',
        [string]$ClientId,
        [string]$ClientSecret,
        [string[]]$CoreScopes,
        [string[]]$ExtendedScopes = @(),
        [switch]$DeviceCode,
        [switch]$NoTokenCache
    )
    $script:CrCtx = [ordered]@{
        TenantId = $TenantId; Asked = $TenantId; CacheTenant = $TenantId; Mode = $null; Token = $null; ExpiresAt = [datetime]::MinValue
        ClientId = $ClientId; ClientSecret = $ClientSecret; Account = $null; Scopes = @(); ScopeFallback = $false
        FromSavedSession = $false
    }
    if ($ClientId -and $ClientSecret) {
        $script:CrCtx.Mode = 'app'
        Update-CrToken
    }
    else {
        $script:CrCtx.Mode = 'delegated'
        Set-CrScopes ($CoreScopes + $ExtendedScopes)
        $useDeviceCode = [bool]$DeviceCode
        $script:CrTokenCacheEnabled = (-not $NoTokenCache) -and (Test-CrTokenCacheSupported)

        # A saved sign-in makes every run after the first one silent. The cache entry is keyed by the
        # resolved tenant id, so the admin may type the domain today and the id tomorrow.
        if ($script:CrTokenCacheEnabled) {
            $script:CrCtx.CacheTenant = Resolve-CrTenantId $TenantId
            $script:CrTokenCacheKey = New-CrTokenCacheKey -TenantId $script:CrCtx.CacheTenant -Scopes $script:CrDelegatedScopes -ClientId $script:CrGraphPublicClientId
            $saved = Get-CrCachedRefreshToken -Key $script:CrTokenCacheKey
            # -Deep in a tenant that refused the newer permissions: a core-set sign-in was saved last time.
            # Use it instead of opening the browser twice on every run.
            if (-not $saved -and $ExtendedScopes.Count -gt 0) {
                $coreKey = New-CrTokenCacheKey -TenantId $script:CrCtx.CacheTenant -Scopes @($CoreScopes | Where-Object { $_ }) -ClientId $script:CrGraphPublicClientId
                $saved = Get-CrCachedRefreshToken -Key $coreKey
                if ($saved) { Set-CrScopes $CoreScopes; $script:CrCtx.ScopeFallback = $true; $script:CrTokenCacheKey = $coreKey }
            }
            if ($saved) {
                $script:CrCtx.RefreshToken = $saved
                try {
                    Update-CrToken
                    $script:CrCtx.FromSavedSession = $true
                    Write-Host (Get-CrConsoleText 'console.savedSession') -ForegroundColor DarkGray
                }
                catch {
                    $script:CrCtx.RefreshToken = $null
                    Write-Host ('  ' + (Get-CrConsoleText 'console.savedInvalid')) -ForegroundColor DarkYellow
                }
            }
        }

        if (-not $script:CrCtx.Token) {
            try { Invoke-CrInteractiveLogin -DeviceCode:$useDeviceCode }
            catch {
                $e = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
                if ($ExtendedScopes.Count -gt 0 -and $e -match 'invalid_scope|AADSTS70011|AADSTS650053|AADSTS65005') {
                    Write-Host (Get-CrConsoleText 'console.scopeFallback') -ForegroundColor DarkYellow
                    $script:CrCtx.ScopeFallback = $true
                    Set-CrScopes $CoreScopes
                    Invoke-CrInteractiveLogin -DeviceCode:$useDeviceCode
                }
                elseif (-not $useDeviceCode -and $e -match 'No browser could be started|Browser sign-in timed out|loopback port') {
                    Write-Host ("  " + ((Get-CrConsoleText 'console.browserFallback') -replace '\{why\}', "$($_.Exception.Message)")) -ForegroundColor DarkYellow
                    Invoke-CrInteractiveLogin -DeviceCode
                }
                else { throw }
            }
        }
    }
    $org = Invoke-CrGraph -Path '/organization?$select=id,displayName,verifiedDomains'
    $o = $org.value[0]
    $script:CrCtx.TenantId = $o.id
    $script:CrCtx.TenantName = $o.displayName
    $script:CrCtx.DefaultDomain = ($o.verifiedDomains | Where-Object isDefault | Select-Object -First 1).name
    $script:CrCtx.InitialDomain = ($o.verifiedDomains | Where-Object isInitial | Select-Object -First 1).name

    # Never read a tenant the caller did not ask for: if -TenantId was given it must match what we
    # actually signed in to, otherwise stop before the first check runs.
    $asked = "$($script:CrCtx.Asked)"
    if ($asked -and $asked -ne 'organizations' -and $asked -ne 'common') {
        $known = @(@($o.verifiedDomains | ForEach-Object { $_.name }) + $o.id) | Where-Object { $_ }
        if (-not (Test-CrTenantMatch -Asked $asked -Known $known)) {
            # The sign-in was saved before we could see which tenant it belongs to: forget it again,
            # so the next run asks for the right account instead of reusing the wrong one.
            if ($script:CrTokenCacheEnabled -and $script:CrTokenCacheKey) { $null = Remove-CrTokenCache -Keys @($script:CrTokenCacheKey) }
            throw ("Wrong tenant: -TenantId '{0}' was requested, but this sign-in belongs to '{1}' ({2}, {3}). Nothing was read. This sign-in was not saved. Run again and pick an account of the requested tenant." -f `
                    $asked, $o.displayName, $o.id, (@($known | Where-Object { $_ -ne $o.id }) -join ', '))
        }
    }

    Write-Host ''
    Write-Host ("  {0,-8} {1}" -f (Get-CrConsoleText 'console.tenant'), $o.displayName) -ForegroundColor White
    Write-Host ("  {0,-8} {1}" -f (Get-CrConsoleText 'console.domain'), $script:CrCtx.DefaultDomain)
    Write-Host ("  {0,-8} {1}" -f (Get-CrConsoleText 'console.id'), $o.id)
    Write-Host ("  {0,-8} {1} ({2})" -f (Get-CrConsoleText 'console.account'), $script:CrCtx.Account, $script:CrCtx.Mode)
}

function ConvertFrom-CrRedirectRequest {
    <# Pure: the query parameters of the first HTTP request line the browser sends to the loopback port
       ("GET /?code=...&state=... HTTP/1.1"). Empty hashtable for speculative or favicon requests. Tested. #>
    param([string]$RequestLine)
    $out = @{}
    $target = @("$RequestLine" -split ' ')[1]
    $q = ''
    if ("$target" -match '\?(.+)$') { $q = $Matches[1] }
    foreach ($pair in @($q -split '&' | Where-Object { $_ })) {
        $kv = $pair -split '=', 2
        $out[$kv[0]] = if ($kv.Count -eq 2) { [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { '' }
    }
    $out
}

function Test-CrTenantMatch {
    <# Pure: does the tenant the admin asked for (-TenantId: a verified domain or the id, any case) belong to
       the tenant the sign-in landed in? Used by the guard that aborts before the first check; tested. #>
    param([Parameter(Mandatory)][string]$Asked, [string[]]$Known = @())
    [bool](@($Known) | Where-Object { $_ -and "$_".Trim().ToLowerInvariant() -eq $Asked.Trim().ToLowerInvariant() })
}

function Update-CrToken {
    $ctx = $script:CrCtx
    $tokenUrl = "https://login.microsoftonline.com/$($ctx.TenantId)/oauth2/v2.0/token"
    if ($ctx.Mode -eq 'app') {
        $body = @{ client_id = $ctx.ClientId; client_secret = $ctx.ClientSecret; scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials' }
    }
    elseif ($ctx.RefreshToken) {
        $body = @{ client_id = $script:CrGraphPublicClientId; refresh_token = $ctx.RefreshToken; grant_type = 'refresh_token'; scope = (Get-CrScopeString $script:CrDelegatedScopes) }
    }
    else { throw 'No refresh token available; run Connect-CrGraph again.' }
    $r = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded'
    $script:CrCtx.Token = $r.access_token
    $script:CrCtx.ExpiresAt = (Get-Date).AddSeconds([int]$r.expires_in - 120)
    if ($r.refresh_token) { $script:CrCtx.RefreshToken = $r.refresh_token }
    $claims = Get-CrTokenClaims $r.access_token
    $script:CrCtx.Scopes = if ($ctx.Mode -eq 'app') { @($claims.roles) } else { @("$($claims.scp)" -split ' ') }
    if ($ctx.Mode -ne 'app') {
        $script:CrCtx.Account = $claims.upn ?? $claims.preferred_username
        if ($r.refresh_token) { Save-CrSessionToken }   # Entra rotates the refresh token on every refresh
    }
}

function Invoke-CrDeviceCodeFlow {
    <# Generic device-code flow. Returns the token response. Used for Graph and for the optional Power Platform API. #>
    param([Parameter(Mandatory)][string]$Tenant, [Parameter(Mandatory)][string]$ClientId, [Parameter(Mandatory)][string]$Scope)
    $dc = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $ClientId; scope = $Scope } -ContentType 'application/x-www-form-urlencoded'
    Write-Host ''
    Write-Host $dc.message -ForegroundColor Cyan
    Write-Host ''
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    $interval = [Math]::Max([int]$dc.interval, 5)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            return Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token" `
                -Body @{ client_id = $ClientId; grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; device_code = $dc.device_code } `
                -ContentType 'application/x-www-form-urlencoded'
        }
        catch {
            $err = $null
            try { $err = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { $err = $null }
            if ($err -eq 'authorization_pending') { continue }
            if ($err -eq 'slow_down') { $interval += 5; continue }
            throw
        }
    }
    throw 'Device code sign-in timed out.'
}

function New-CrPkcePair {
    <# PKCE verifier and S256 challenge, base64url without padding (RFC 7636). #>
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($verifier))
    @{
        Verifier  = $verifier
        Challenge = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
}

function Invoke-CrBrowserCodeFlow {
    <#
      .SYNOPSIS  Authorization code flow with PKCE against a loopback redirect: one browser window,
                 no code to type. Returns the token response. A plain TCP listener on 127.0.0.1 is used
                 so no URL reservation or elevation is needed. Entra ignores the port for http://localhost
                 redirects of public clients.
    #>
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Scope,
        [int]$TimeoutSeconds = 300
    )
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try { $listener.Start() } catch { throw "Cannot open a loopback port for the browser sign-in: $($_.Exception.Message)" }
    try {
        $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $redirect = "http://localhost:$port"
        $pkce = New-CrPkcePair
        $state = [Guid]::NewGuid().ToString('N')
        $query = (@(
                "client_id=$ClientId"
                'response_type=code'
                "redirect_uri=$([Uri]::EscapeDataString($redirect))"
                "scope=$([Uri]::EscapeDataString($Scope))"
                "code_challenge=$($pkce.Challenge)"
                'code_challenge_method=S256'
                "state=$state"
                'prompt=select_account'
            ) -join '&')
        $authUrl = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/authorize?$query"

        Write-Host ''
        Write-Host (Get-CrConsoleText 'console.signIn') -ForegroundColor Cyan
        Write-Host ("  " + (Get-CrConsoleText 'console.noWindow') + "`n  $authUrl") -ForegroundColor DarkGray
        Write-Host ''
        # No browser on this host: say so now and let the caller fall back to the device code,
        # instead of waiting the full timeout for a redirect that can never come.
        try { Start-Process $authUrl -ErrorAction Stop }
        catch { throw "No browser could be started on this host ($($_.Exception.Message))." }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $received = @{}; $client = $null; $stream = $null
        # Browsers open speculative connections and ask for /favicon.ico. Accept connections until one carries
        # the redirect (code or error); answer anything else with an empty 204 and keep listening.
        while ($true) {
            while (-not $listener.Pending()) {
                if ((Get-Date) -ge $deadline) { throw 'Browser sign-in timed out.' }
                Start-Sleep -Milliseconds 250
            }
            $client = $listener.AcceptTcpClient()
            $client.ReceiveTimeout = 5000
            $stream = $client.GetStream()
            $buffer = [byte[]]::new(16384)
            $read = 0
            try { $read = $stream.Read($buffer, 0, $buffer.Length) } catch { $read = 0 }
            $requestLine = if ($read -gt 0) { ([Text.Encoding]::ASCII.GetString($buffer, 0, $read) -split "`r?`n")[0] } else { '' }
            $parsed = ConvertFrom-CrRedirectRequest $requestLine
            if ($parsed.ContainsKey('code') -or $parsed.ContainsKey('error')) { $received = $parsed; break }
            if ($read -gt 0) {
                $noContent = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 204 No Content`r`nConnection: close`r`n`r`n")
                try { $stream.Write($noContent, 0, $noContent.Length) } catch { Write-Verbose 'speculative connection closed' }
            }
            $client.Close()
        }
        try {
            $ok = [bool]$received['code'] -and $received['state'] -eq $state
            $why = if ($received['error_description'] -or $received['error']) { $received['error_description'] ?? $received['error'] }
            elseif ($received['code']) { 'the state of the reply does not match this sign-in' }
            else { 'no authorization code returned' }
            $message = if ($ok) { 'Sign-in complete. You can close this tab and go back to PowerShell.' } else { "Sign-in failed: $why" }
            $html = @"
<!doctype html><html><head><meta charset="utf-8"><title>Copilot &amp; Agent Readiness</title></head>
<body style="font:16px/1.5 system-ui,sans-serif;max-width:34rem;margin:4rem auto;padding:0 1rem;color:#1a1a1a">
<h1 style="font-size:1.25rem">Copilot &amp; Agent Readiness</h1><p>$([Net.WebUtility]::HtmlEncode($message))</p></body></html>
"@
            $body = [Text.Encoding]::UTF8.GetBytes($html)
            $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
            $stream.Write($header, 0, $header.Length)
            $stream.Write($body, 0, $body.Length)
            $stream.Flush()
        }
        finally { $client.Close() }

        if (-not $ok) {
            # Worded without "browser", so an answer from Entra (consent declined, wrong account) is not mistaken
            # for a browser that could not be reached and does not trigger the device-code fallback.
            throw ("Entra did not complete the sign-in: $why")
        }
        Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token" -Body @{
            client_id     = $ClientId
            grant_type    = 'authorization_code'
            code          = $received['code']
            redirect_uri  = $redirect
            code_verifier = $pkce.Verifier
            scope         = $Scope
        } -ContentType 'application/x-www-form-urlencoded'
    }
    finally { $listener.Stop() }
}

function Invoke-CrInteractiveLogin {
    <# Delegated sign-in: browser by default, device code with -DeviceCode. #>
    param([switch]$DeviceCode)
    $ctx = $script:CrCtx
    $scope = Get-CrScopeString $script:CrDelegatedScopes
    $r = if ($DeviceCode) { Invoke-CrDeviceCodeFlow -Tenant $ctx.TenantId -ClientId $script:CrGraphPublicClientId -Scope $scope }
    else { Invoke-CrBrowserCodeFlow -Tenant $ctx.TenantId -ClientId $script:CrGraphPublicClientId -Scope $scope }
    $script:CrCtx.Token = $r.access_token
    $script:CrCtx.RefreshToken = $r.refresh_token
    $script:CrCtx.ExpiresAt = (Get-Date).AddSeconds([int]$r.expires_in - 120)
    $claims = Get-CrTokenClaims $r.access_token
    $script:CrCtx.Account = $claims.upn ?? $claims.preferred_username
    $script:CrCtx.Scopes = @("$($claims.scp)" -split ' ')
    Save-CrSessionToken
}

function Get-CrTokenClaims([string]$Jwt) {
    $p = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

function Get-CrAccessToken {
    if ((Get-Date) -ge $script:CrCtx.ExpiresAt) { Update-CrToken }
    $script:CrCtx.Token
}

function Connect-CrPowerPlatformApi {
    <#
      .SYNOPSIS  Optional: delegated token for the Power Platform API (agent inventory). Needs the customer's own
                 public-client app registration with the delegated permission ResourceQuery.Resources.Read
                 (see README). The tool never creates one.
    #>
    param([Parameter(Mandatory)][string]$ClientId, [Parameter(Mandatory)][string]$Tenant, [switch]$DeviceCode)
    Write-Host 'Signing in to the Power Platform API (agent inventory)...' -ForegroundColor Cyan
    $scope = 'https://api.powerplatform.com/.default offline_access'
    $r = if ($DeviceCode) { Invoke-CrDeviceCodeFlow -Tenant $Tenant -ClientId $ClientId -Scope $scope }
    else { Invoke-CrBrowserCodeFlow -Tenant $Tenant -ClientId $ClientId -Scope $scope }
    $script:CrPpToken = $r.access_token
}
