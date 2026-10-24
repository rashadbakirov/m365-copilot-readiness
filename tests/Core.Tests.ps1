#Requires -Modules Pester
# State mapping, result model, scoring with coverage, action plan, preflight capabilities.

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src/Core.ps1')
    Import-CrI18n (Join-Path $root 'src/i18n.json') | Out-Null
    function New-TestCatalog {
        [pscustomobject]@{
            areas  = @([pscustomobject]@{ key = 'a'; n = 1 }, [pscustomobject]@{ key = 'b'; n = 2 })
            checks = @(
                [pscustomobject]@{ id = 'A1'; area = 'a'; weight = 3; scored = $true }
                [pscustomobject]@{ id = 'A2'; area = 'a'; weight = 1; scored = $true }
                [pscustomobject]@{ id = 'A3'; area = 'a'; weight = 2; scored = $false }
                [pscustomobject]@{ id = 'B1'; area = 'b'; weight = 2; scored = $true }
                [pscustomobject]@{ id = 'B2'; area = 'b'; weight = 2; scored = $true }
            )
        }
    }
    function New-TR($id, $state, $score = -1) { New-CrResult -Id $id -State $state -Score $score }
}

Describe 'State mapping (Get-CrErrorState)' {
    It 'maps <code> "<msg>" to <state>' -ForEach @(
        @{ code = 401; msg = 'Unauthorized'; state = 'NoPermission' }
        @{ code = 403; msg = 'Authorization_RequestDenied'; state = 'NoPermission' }
        @{ code = 403; msg = 'Tenant does not have a SKU required for this feature'; state = 'NotLicensed' }
        @{ code = 400; msg = 'The tenant is not licensed for this feature'; state = 'NotLicensed' }
        @{ code = 404; msg = 'Resource not found for the segment'; state = 'Unknown' }
        @{ code = 400; msg = 'BadRequest: not supported'; state = 'Unknown' }
        @{ code = 500; msg = 'Internal server error'; state = 'Unknown' }
        @{ code = 503; msg = 'Service unavailable'; state = 'Unknown' }
        @{ code = 0; msg = 'The term Get-Foo is not recognized'; state = 'Unknown' }
        @{ code = 0; msg = 'Access is denied'; state = 'NoPermission' }
        @{ code = 503; msg = 'Subscription service temporarily unavailable'; state = 'Unknown' }   # an outage is not a missing licence
        @{ code = 400; msg = 'BadRequest: Invalid filter clause'; state = 'Unknown' }               # our own bad query, not "endpoint missing"
    ) {
        (Get-CrErrorState -StatusCode $code -Message $msg).State | Should -Be $state
    }
    It 'gives a readable message when a reader cmdlet is missing or there is no HTTP status' {
        (Get-CrErrorState -StatusCode 0 -Message "Cmdlet 'Get-DlpCompliancePolicy' was not exposed to the signed-in account in this session").Msg | Should -Be 'gen.cmdletMissing'
        (Get-CrErrorState -StatusCode 0 -Message 'something odd').Msg | Should -Be 'gen.unknownNoHttp'
    }
    It 'keeps the HTTP mapping table' -ForEach @(
        @{ code = 404; msg = 'Resource not found for the segment'; state = 'Unknown' }
    ) {
        (Get-CrErrorState -StatusCode $code -Message $msg).State | Should -Be $state
    }
    It 'reads an HTTP status only where it is labelled as one' {
        $er = { param($m) try { throw [Exception]::new($m) } catch { $_ } }
        Get-CrHttpStatus (& $er 'Response status code does not indicate success: 403 (Forbidden).') | Should -Be 403
        Get-CrHttpStatus (& $er 'Policy 4031 has 500 items') | Should -Be 0
    }
    It 'turns leaked pipeline output into Unknown instead of a junk result' {
        (Invoke-CrCheck 'T2' { 'stray string' } 6>$null).State | Should -Be 'Unknown'
    }
    It 'hashes an empty result list' {
        Get-CrResultHash @() | Should -Match '^[0-9a-f]{64}$'
    }
    It 'never returns a scored state' {
        foreach ($c in 0, 200, 400, 401, 403, 404, 429, 500) { (Get-CrErrorState -StatusCode $c -Message 'x').State | Should -Not -BeIn @('Pass', 'Warn', 'Fail') }
    }
    It 'Invoke-CrCheck turns a thrown 403 into NoPermission, not a pass' {
        $r = Invoke-CrCheck 'T1' { $e = [Exception]::new('HTTP 403 Forbidden'); $e.Data['HttpStatus'] = 403; throw $e } 6>$null
        $r.State | Should -Be 'NoPermission'
        $r.Score | Should -Be -1
    }
    It 'Invoke-CrCheck turns an empty body into Unknown' {
        (Invoke-CrCheck 'T2' { $null } 6>$null).State | Should -Be 'Unknown'
    }
    It 'a cmdlet missing from a connected reader stays Unknown, not NotLicensed' {
        # The message must not claim a licence or a permission reason, because we cannot tell which it is.
        $msg = "Cmdlet 'Get-DlpCompliancePolicy' was not exposed to the signed-in account in this session, although the reader connected. Check the same value in the portal."
        (Get-CrErrorState -StatusCode 0 -Message $msg).State | Should -Be 'Unknown'
    }
}

Describe 'Result model (New-CrResult)' {
    It 'gives grey states no score' {
        foreach ($s in 'NotLicensed', 'NoPermission', 'Manual', 'Unknown', 'NotApplicable', 'Info') { (New-CrResult -Id X -State $s -Score 100).Score | Should -Be -1 }
    }
    It 'keeps the score inside the state colour band' {
        (New-CrResult -Id X -State Pass -Score 30).Score | Should -BeGreaterOrEqual 75
        (New-CrResult -Id X -State Fail -Score 90).Score | Should -BeLessThan 45
        (New-CrResult -Id X -State Warn -Score 100).Score | Should -BeLessThan 75
        (New-CrResult -Id X -State Warn -Score 0).Score | Should -BeGreaterOrEqual 45
    }
    It 'renders the English summary from the message key' {
        (New-CrResult -Id S05 -State Warn -Msg 'S05.public' -Arguments @{ n = 3; total = 40; pct = 7.5 }).Summary | Should -Be '3 of 40 Microsoft 365 groups are public (7.5 %).'
    }
}

Describe 'Scoring with coverage (Get-CrScores)' {
    It 'scores only Pass/Warn/Fail and reports coverage' {
        $res = @((New-TR A1 Pass 100), (New-TR A2 Fail 0), (New-TR B1 Pass 100), (New-TR B2 Manual))
        $s = Get-CrScores -Catalog (New-TestCatalog) -Results $res
        $a = $s.areas | Where-Object key -eq 'a'
        $a.score | Should -Be 75        # (3*100 + 1*0) / 4
        $a.coverage | Should -Be 100
        ($s.areas | Where-Object key -eq 'b').coverage | Should -Be 50
        $s.overall.score | Should -Be 83 # (300 + 0 + 200) / 6
        $s.overall.coverage | Should -Be 75 # 6 / 8
    }
    It 'shows 100 % score but verdict incomplete when a whole area is missing (the "100 with a level missing" case)' {
        $res = @((New-TR A1 Pass 100), (New-TR A2 Pass 100), (New-TR B1 NoPermission), (New-TR B2 Unknown))
        $s = Get-CrScores -Catalog (New-TestCatalog) -Results $res
        $s.overall.score | Should -Be 100
        $s.overall.verdict | Should -Be 'incomplete'
        $s.overall.weakAreas | Should -Contain 'b'
        ($s.areas | Where-Object key -eq 'b').score | Should -BeNullOrEmpty
    }
    It 'gives verdict incomplete below the coverage threshold even when every area has something' {
        $cat = New-TestCatalog
        $res = @((New-TR A1 NotLicensed), (New-TR A2 Pass 100), (New-TR B1 Pass 100), (New-TR B2 Manual))
        $s = Get-CrScores -Catalog $cat -Results $res -MinCoverage 70 -MinAreaCoverage 20
        $s.overall.coverage | Should -Be 38   # 3 / 8
        $s.overall.verdict | Should -Be 'incomplete'
    }
    It 'keeps unscored (Info) checks and NotApplicable results out of the denominator' {
        $res = @((New-TR A1 Pass 100), (New-TR A2 NotApplicable), (New-CrResult -Id A3 -State Info), (New-TR B1 Pass 100), (New-TR B2 Pass 100))
        $s = Get-CrScores -Catalog (New-TestCatalog) -Results $res
        $s.overall.coverage | Should -Be 100
        $s.overall.applicableWeight | Should -Be 7
        $s.overall.verdict | Should -Be 'good'
    }
    It 'returns verdict none when nothing could be assessed' {
        $res = @((New-TR A1 Manual), (New-TR A2 Manual), (New-TR B1 Manual), (New-TR B2 Manual))
        (Get-CrScores -Catalog (New-TestCatalog) -Results $res).overall.verdict | Should -Be 'none'
    }
    It 'maps scores to good / warn / crit when coverage is complete' {
        $cat = New-TestCatalog
        (Get-CrScores -Catalog $cat -Results @((New-TR A1 Pass 100), (New-TR A2 Pass 100), (New-TR B1 Warn 60), (New-TR B2 Warn 60))).overall.verdict | Should -Be 'good'
        (Get-CrScores -Catalog $cat -Results @((New-TR A1 Warn 60), (New-TR A2 Warn 60), (New-TR B1 Warn 60), (New-TR B2 Warn 60))).overall.verdict | Should -Be 'warn'
        (Get-CrScores -Catalog $cat -Results @((New-TR A1 Fail 0), (New-TR A2 Fail 0), (New-TR B1 Warn 50), (New-TR B2 Fail 0))).overall.verdict | Should -Be 'crit'
    }
    It 'never gives a verdict for a partial (-Only) run' {
        (Get-CrScores -Catalog (New-TestCatalog) -Results @((New-TR A1 Pass 100), (New-TR B1 Pass 100)) -PartialRun).overall.verdict | Should -Be 'incomplete'
    }
}

Describe 'Action plan 30/60/90 (Get-CrActionPlan)' {
    It 'buckets by state and weight' {
        $res = @((New-TR A1 Fail 0), (New-TR A2 Fail 0), (New-TR B1 Warn 60), (New-TR B2 NoPermission), (New-CrResult -Id A3 -State Fail))
        $p = Get-CrActionPlan -Catalog (New-TestCatalog) -Results $res
        $p.d30.id | Should -Be @('A1')
        $p.d60.id | Should -Be @('A2')
        $p.d90.id | Should -Be @('B1')
        $p.gaps.id | Should -Be @('B2')
        $p.d30.id + $p.d60.id + $p.d90.id | Should -Not -Contain 'A3'   # unscored never in the plan
    }
}

Describe 'Preflight capabilities (Get-CrCapabilities)' {
    BeforeAll {
        $cat = [pscustomobject]@{ checks = @(
                [pscustomobject]@{ id = 'G1'; area = 'a'; reader = 'graph'; scopes = @('Policy.Read.All') }
                [pscustomobject]@{ id = 'G2'; area = 'a'; reader = 'graph'; scopes = @('AgentIdentity.Read.All') }
                [pscustomobject]@{ id = 'G3'; area = 'a'; reader = 'graph'; scopes = @('Policy.Read.All'); plans = @('AAD_PREMIUM_P2') }
                [pscustomobject]@{ id = 'P1'; area = 'a'; reader = 'purview'; scopes = @() }
                [pscustomobject]@{ id = 'M1'; area = 'a'; reader = 'manual'; scopes = @() }
            )
        }
        $ctx = @{ Mode = 'delegated'; Scopes = @('Policy.Read.All'); ServicePlans = @('AAD_PREMIUM'); ServicePlansKnown = $true; Readers = @{ graph = $true; purview = $false; manual = $false } }
        $caps = @{}; Get-CrCapabilities -Catalog $cat -Context $ctx | ForEach-Object { $caps[$_.id] = $_ }
    }
    It 'runs a check whose scope was granted' { $caps.G1.run | Should -BeTrue }
    It 'marks a missing scope as NoPermission' { $caps.G2.state | Should -Be 'NoPermission' }
    It 'marks a missing service plan as NotLicensed' { $caps.G3.state | Should -Be 'NotLicensed' }
    It 'marks an optional reader that is off as Manual' { $caps.P1.state | Should -Be 'Manual'; $caps.P1.msg | Should -Be 'gen.readerOff' }
    It 'marks portal-only checks as Manual' { $caps.M1.state | Should -Be 'Manual' }
}

Describe 'Output hygiene' {
    It 'creates unique run ids' { (1..20 | ForEach-Object { New-CrRunId } | Select-Object -Unique).Count | Should -Be 20 }
    It 'hash depends only on results and is stable' {
        $r = @((New-TR A1 Pass 100))
        Get-CrResultHash $r | Should -Be (Get-CrResultHash $r)
        Get-CrResultHash $r | Should -Not -Be (Get-CrResultHash @((New-TR A1 Warn 60)))
    }
}

Describe 'Saved sign-in (token cache)' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src/Auth.ps1')
    }
    It 'keys one entry per tenant, client and exact scope set' {
        $a = New-CrTokenCacheKey -TenantId 't1' -Scopes @('A', 'B') -ClientId 'c'
        $b = New-CrTokenCacheKey -TenantId 't1' -Scopes @('B', 'A') -ClientId 'c'
        $c = New-CrTokenCacheKey -TenantId 't1' -Scopes @('A', 'B', 'C') -ClientId 'c'
        $d = New-CrTokenCacheKey -TenantId 't2' -Scopes @('A', 'B') -ClientId 'c'
        $a | Should -Be $b                      # order must not matter
        $a | Should -Not -Be $c                 # a core token is never reused for a -Deep run
        $a | Should -Not -Be $d                 # never across tenants
        $a | Should -Match '^[0-9a-f]{64}$'
    }
    It 'round-trips a refresh token through DPAPI and never writes it in clear' -Skip:(-not $IsWindows) {
        # Never touch the real saved sign-in: redirect the cache to a temp file for this test.
        $script:CrTokenCachePathOverride = Join-Path ([IO.Path]::GetTempPath()) "cr-test-$([Guid]::NewGuid()).dat"
        try {
            $key = New-CrTokenCacheKey -TenantId 'test-tenant' -Scopes @('X') -ClientId 'test-client'
            $secret = "rt-$([Guid]::NewGuid())"
            Set-CrCachedRefreshToken -Key $key -RefreshToken $secret
            Get-CrCachedRefreshToken -Key $key | Should -Be $secret
            (Get-Content (Get-CrTokenCachePath) -Raw) | Should -Not -Match ([regex]::Escape($secret))
            Get-CrCachedRefreshToken -Key 'no-such-key' | Should -BeNullOrEmpty
            Remove-CrTokenCache | Should -BeTrue
            Test-Path (Get-CrTokenCachePath) | Should -BeFalse
        }
        finally {
            if (Test-Path $script:CrTokenCachePathOverride) { Remove-Item $script:CrTokenCachePathOverride -Force }
            $script:CrTokenCachePathOverride = $null
        }
    }
    It 'keeps several tenants side by side in one cache file' -Skip:(-not $IsWindows) {
        $script:CrTokenCachePathOverride = Join-Path ([IO.Path]::GetTempPath()) "cr-test-$([Guid]::NewGuid()).dat"
        try {
            $k1 = New-CrTokenCacheKey -TenantId 't1' -Scopes @('X') -ClientId 'c'
            $k2 = New-CrTokenCacheKey -TenantId 't2' -Scopes @('X') -ClientId 'c'
            Set-CrCachedRefreshToken -Key $k1 -RefreshToken 'rt-one'
            Set-CrCachedRefreshToken -Key $k2 -RefreshToken 'rt-two'
            Get-CrCachedRefreshToken -Key $k1 | Should -Be 'rt-one'
            Get-CrCachedRefreshToken -Key $k2 | Should -Be 'rt-two'
            Set-CrCachedRefreshToken -Key $k1 -RefreshToken 'rt-one-rotated'
            Get-CrCachedRefreshToken -Key $k1 | Should -Be 'rt-one-rotated'
            Get-CrCachedRefreshToken -Key $k2 | Should -Be 'rt-two'
        }
        finally {
            if (Test-Path $script:CrTokenCachePathOverride) { Remove-Item $script:CrTokenCachePathOverride -Force }
            $script:CrTokenCachePathOverride = $null
        }
    }
}

Describe 'Tenant resolution and guard (ConvertFrom-CrIssuer, Test-CrTenantMatch)' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src/Auth.ps1')
    }
    It 'reads the tenant id out of the OpenID issuer and ignores the organizations placeholder' {
        ConvertFrom-CrIssuer 'https://login.microsoftonline.com/11111111-2222-4333-8444-555555555555/v2.0' | Should -Be '11111111-2222-4333-8444-555555555555'
        ConvertFrom-CrIssuer 'https://login.microsoftonline.com/{tenantid}/v2.0' | Should -BeNullOrEmpty
        ConvertFrom-CrIssuer '' | Should -BeNullOrEmpty
        ConvertFrom-CrIssuer 'https://evil.example/11111111-2222-4333-8444-555555555555/v2.0' | Should -BeNullOrEmpty
    }
    It 'parses the sign-in redirect and ignores speculative and favicon requests' {
        $r = ConvertFrom-CrRedirectRequest 'GET /?code=0.AX%2Babc&state=58ee&session_state=x HTTP/1.1'
        $r['code'] | Should -Be '0.AX+abc'
        $r['state'] | Should -Be '58ee'
        (ConvertFrom-CrRedirectRequest 'GET /?error=access_denied&error_description=User+declined HTTP/1.1')['error_description'] | Should -Be 'User declined'
        (ConvertFrom-CrRedirectRequest 'GET /favicon.ico HTTP/1.1').Count | Should -Be 0
        (ConvertFrom-CrRedirectRequest '').Count | Should -Be 0
    }
    It 'does not resolve the multi-tenant authorities over the network' {
        Resolve-CrTenantId 'organizations' | Should -Be 'organizations'
        Resolve-CrTenantId 'common' | Should -Be 'common'
    }
    It 'accepts the requested tenant by any verified domain or the id, in any case, and rejects the rest' {
        $known = @('Contoso.de', 'contoso.onmicrosoft.com', '11111111-2222-4333-8444-555555555555')
        Test-CrTenantMatch -Asked 'contoso.de' -Known $known | Should -BeTrue
        Test-CrTenantMatch -Asked 'CONTOSO.ONMICROSOFT.COM' -Known $known | Should -BeTrue
        Test-CrTenantMatch -Asked '11111111-2222-4333-8444-555555555555' -Known $known | Should -BeTrue
        Test-CrTenantMatch -Asked 'fabrikam.de' -Known $known | Should -BeFalse
        Test-CrTenantMatch -Asked 'contoso.de' -Known @() | Should -BeFalse
    }
}

Describe 'Scope list hygiene (Set-CrScopes)' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src/Auth.ps1')
    }
    It 'drops null and empty scopes so no "<resource>/" scope is ever requested' {
        # An empty scope would be requested as "https://graph.microsoft.com/" and Entra rejects that (AADSTS70011).
        Set-CrScopes @('Organization.Read.All', $null, '', '  ', 'Policy.Read.All')
        $s = Get-CrScopeString (Get-Variable -Scope Script -Name CrDelegatedScopes -ValueOnly)
        $s | Should -Be 'https://graph.microsoft.com/Organization.Read.All https://graph.microsoft.com/Policy.Read.All offline_access'
        $s | Should -Not -Match 'graph\.microsoft\.com/\s'
    }
}

Describe 'Admin disclosure text' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src/Core.ps1')
        $script:I = Import-CrI18n (Join-Path $root 'src/i18n.json')
    }
    It 'has German and English for every disclosure and tenant-confirm key' {
        $keys = @($script:I.ui.Keys | Where-Object { $_ -like 'disclosure.*' -or $_ -like 'tenantConfirm.*' })
        $keys.Count | Should -BeGreaterThan 8
        foreach ($k in $keys) {
            $script:I.ui[$k]['de'] | Should -Not -BeNullOrEmpty -Because "$k needs German"
            $script:I.ui[$k]['en'] | Should -Not -BeNullOrEmpty -Because "$k needs English"
        }
    }
    It 'defaults to German and falls back to the key when unknown' {
        (Get-CrUiText -I18n $script:I -Key 'disclosure.readonly' -Language de) | Should -Match 'Nur lesend'
        (Get-CrUiText -I18n $script:I -Key 'disclosure.readonly' -Language en) | Should -Match 'Read-only'
        (Get-CrUiText -I18n $script:I -Key 'no.such.key' -Language de) | Should -Be 'no.such.key'
    }
    It 'promises read-only and local-only in both languages' {
        (Get-CrUiText -I18n $script:I -Key 'disclosure.local' -Language de) | Should -Match 'bleiben auf diesem PC'
        (Get-CrUiText -I18n $script:I -Key 'disclosure.account' -Language de) | Should -Match 'delegiert'
    }
    It 'wraps console text and indents continuation lines' {
        $w = Format-CrWrap 'aaa bbb ccc ddd eee' 11 '>>'
        @($w -split "`n").Count | Should -Be 2
        $w | Should -Match '^aaa bbb ccc'
        ($w -split "`n")[1] | Should -Be '>>ddd eee'
    }
}
