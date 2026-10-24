#Requires -Modules Pester
# Catalogue / function parity, translation completeness, manifest and README consistency, parsing.

BeforeDiscovery {
    $root = Split-Path $PSScriptRoot -Parent
    $script:checkIds = @((Get-Content (Join-Path $root 'src/Catalog.json') -Raw | ConvertFrom-Json).checks.id)
    $script:scriptFiles = @(Get-ChildItem $root -Recurse -Filter *.ps1 | Where-Object FullName -notmatch '[\\/](out|\.git)[\\/]' | ForEach-Object { @{ path = $_.FullName; name = $_.Name } })
}

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $catalog = Get-Content (Join-Path $root 'src/Catalog.json') -Raw | ConvertFrom-Json
    $manifest = Get-Content (Join-Path $root 'src/Manifest.json') -Raw | ConvertFrom-Json
    $i18n = Get-Content (Join-Path $root 'src/i18n.json') -Raw | ConvertFrom-Json -AsHashtable
    $checkSource = (Get-ChildItem (Join-Path $root 'src/Checks') -Filter *.ps1 | Get-Content -Raw) -join "`n"
    $allSource = ((Get-ChildItem (Join-Path $root 'src') -Recurse -Filter *.ps1 | Get-Content -Raw) -join "`n") + (Get-Content (Join-Path $root 'Invoke-CopilotReadiness.ps1') -Raw)
    $template = Get-Content (Join-Path $root 'src/Report/template.html') -Raw
    . (Join-Path $root 'src/Core.ps1')
    Get-ChildItem (Join-Path $root 'src/Checks') -Filter *.ps1 | ForEach-Object { . $_.FullName }
}

Describe 'Catalogue / function parity' {
    It 'check <_> has a Test-Cr function' -ForEach $checkIds {
        Get-Command "Test-Cr$_" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'every Test-Cr function has a catalogue entry' {
        $fns = [regex]::Matches($checkSource, 'function Test-Cr([A-Z]\d\d)\b') | ForEach-Object { $_.Groups[1].Value }
        $fns | Where-Object { $_ -notin $catalog.checks.id } | Should -BeNullOrEmpty
    }
    It 'ids are unique' { ($catalog.checks.id | Select-Object -Unique).Count | Should -Be $catalog.checks.Count }
    It 'every check is in a known area, weight 1..3, known reader' {
        foreach ($c in $catalog.checks) {
            $c.area | Should -BeIn $catalog.areas.key
            $c.weight | Should -BeIn 1, 2, 3
            $c.reader | Should -BeIn @($manifest.readers.PSObject.Properties.Name)
        }
    }
    It 'dropped checks B04 and B06 stay dropped' { $catalog.checks.id | Should -Not -Contain 'B04'; $catalog.checks.id | Should -Not -Contain 'B06' }
    It 'graph checks only ask for scopes that the manifest requests' {
        $all = @($manifest.graphScopes.core) + @($manifest.graphScopes.extended)
        foreach ($c in $catalog.checks | Where-Object reader -eq 'graph') { foreach ($s in $c.scopes) { $s | Should -BeIn $all } }
    }
}

Describe 'Translation completeness (DE + EN)' {
    It 'check <_> has German and English title, why and fix' -ForEach $checkIds {
        $c = $catalog.checks | Where-Object id -eq $_
        foreach ($k in 'title_de', 'title_en', 'why_de', 'why_en', 'fix_de', 'fix_en', 'path', 'docs', 'source') { $c.$k | Should -Not -BeNullOrEmpty -Because "$_.$k" }
        $c.docs | Should -Match '^https://learn\.microsoft\.com/'
    }
    It 'every area has DE and EN names' { foreach ($a in $catalog.areas) { $a.de | Should -Not -BeNullOrEmpty; $a.en | Should -Not -BeNullOrEmpty; $a.sub_de | Should -Not -BeNullOrEmpty; $a.sub_en | Should -Not -BeNullOrEmpty } }
    It 'every message, column and UI text exists in both languages with the same placeholders' {
        foreach ($section in 'messages', 'columns', 'ui') {
            foreach ($k in $i18n[$section].Keys) {
                $de = $i18n[$section][$k]['de']; $en = $i18n[$section][$k]['en']
                $de | Should -Not -BeNullOrEmpty -Because "$section.$k de"
                $en | Should -Not -BeNullOrEmpty -Because "$section.$k en"
                $pd = @([regex]::Matches($de, '\{(\w+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                $pe = @([regex]::Matches($en, '\{(\w+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                ($pd -join ',') | Should -Be ($pe -join ',') -Because "$section.$k placeholders"
            }
        }
    }
    It 'every message key used in the code exists' {
        $keys = [regex]::Matches($allSource, "(?:-Msg|msg\s*=)\s*'([A-Za-z0-9]+\.[A-Za-z0-9.]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $keys.Count | Should -BeGreaterThan 40
        $keys | Where-Object { -not $i18n.messages.ContainsKey($_) } | Should -BeNullOrEmpty
    }
    It 'dynamic message keys exist (S03.<capability>, K01.labels.<scope>, Z07.consent.<mode>, <id>.manual)' {
        foreach ($k in 'S03.externalUserAndGuestSharing', 'S03.externalUserSharingOnly', 'S03.existingExternalUserSharingOnly', 'S03.disabled', 'S03.other', 'K01.labels.tenant', 'K01.labels.user', 'Z07.consent.all', 'Z07.consent.lowImpact', 'Z07.consent.recommended', 'Z07.consent.custom', 'Z07.consent.none') { $i18n.messages.ContainsKey($k) | Should -BeTrue -Because $k }
        foreach ($c in $catalog.checks | Where-Object reader -eq 'manual') { $i18n.messages.ContainsKey("$($c.id).manual") | Should -BeTrue }
    }
    It 'every evidence column the checks emit has a translation' {
        $cols = [regex]::Matches($checkSource, '\[pscustomobject\]@\{([^\r\n]*)\}') | ForEach-Object { [regex]::Matches($_.Groups[1].Value, '(?:^|;)\s*([A-Z][A-Za-z]+)\s*=') | ForEach-Object { $_.Groups[1].Value } } | Sort-Object -Unique
        $missing = $cols | Where-Object { -not $i18n.columns.ContainsKey($_) }
        $missing | Should -BeNullOrEmpty
    }
    It 'every state and UI key the template uses exists' {
        foreach ($s in $manifest.states) { $i18n.ui.ContainsKey("state.$s") | Should -BeTrue -Because $s }
        $used = [regex]::Matches($template, "u\('([\w.]+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $used | Where-Object { -not $i18n.ui.ContainsKey($_) } | Should -BeNullOrEmpty
    }
    It 'the template has no hard-coded regex translation table any more' { $template | Should -Not -Match 'const DE = \[' }
}

Describe 'Manifest and docs' {
    It 'product name lives only in the manifest' {
        $manifest.product.name | Should -Not -BeNullOrEmpty
        $allSource.Contains($manifest.product.name) | Should -BeFalse
    }
    It '<file> lists exactly the scopes from the manifest' -ForEach @(
        @{ file = 'README.md' }, @{ file = 'README.en.md' }
    ) {
        $readme = Get-Content (Join-Path $root $file) -Raw
        $block = [regex]::Match($readme, '(?s)<!-- scopes:start -->(.*?)<!-- scopes:end -->').Groups[1].Value
        $listed = [regex]::Matches($block, '`([A-Za-z\.\-]+\.[A-Za-z]+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $want = @($manifest.graphScopes.core) + @($manifest.graphScopes.extended) | Sort-Object -Unique
        ($listed -join ' ') | Should -Be ($want -join ' ')
    }
    It '<file> lists every check from the catalogue' -ForEach @(
        @{ file = 'README.md' }, @{ file = 'README.en.md' }
    ) {
        $readme = Get-Content (Join-Path $root $file) -Raw
        $block = [regex]::Match($readme, '(?s)<!-- checks:start -->(.*?)<!-- checks:end -->').Groups[1].Value
        $listed = [regex]::Matches($block, '(?m)^\| ([A-Z]\d{2}) \|') | ForEach-Object { $_.Groups[1].Value } | Sort-Object
        ($listed -join ' ') | Should -Be ((@($catalog.checks.id) | Sort-Object) -join ' ')
    }
    It 'both READMEs clone from the real repository, not a placeholder' {
        # A stranger copies this line verbatim. "<org>" made the very first command of the guide fail.
        foreach ($f in 'README.md', 'README.en.md') {
            $clone = [regex]::Match((Get-Content (Join-Path $root $f) -Raw), 'git clone (\S+)').Groups[1].Value
            $clone | Should -Be 'https://github.com/rashadbakirov/m365-copilot-readiness.git' -Because $f
        }
    }
    It 'both READMEs offer the other language' {
        (Get-Content (Join-Path $root 'README.md') -Raw) | Should -Match 'README\.en\.md'
        (Get-Content (Join-Path $root 'README.en.md') -Raw) | Should -Match '\]\(README\.md\)'
    }
    It 'talks to Microsoft endpoints only (every URL in the code has an allowed host)' {
        # The read-only promise, proven: the code can only ever send a token to these hosts.
        $allowed = '^(login\.microsoftonline\.com|graph\.microsoft\.com|api\.powerplatform\.com|learn\.microsoft\.com|govnex\.de|localhost|.*\.sharepoint\.com)$'
        $files = @(Get-ChildItem (Join-Path $root 'src') -Recurse -Filter *.ps1) + @(Get-Item (Join-Path $root 'Invoke-CopilotReadiness.ps1'))
        $hosts = foreach ($f in $files) {
            foreach ($m in [regex]::Matches((Get-Content $f.FullName -Raw), 'https?://([^/\s''"`?]+)')) {
                $h = $m.Groups[1].Value -replace '\\', '' -replace ':\S*$', ''        # regex literals, ports
                if ($h -eq '*') { continue }                                        # the 'https://*' -like pattern in Graph.ps1
                if ($h -match '\$') { $h = $h -replace '^.*\$[^-]*', 'x' }            # "$($Matches[1])-admin.sharepoint.com" → x-admin.sharepoint.com
                $h
            }
        }
        $bad = @($hosts | Sort-Object -Unique | Where-Object { $_ -notmatch $allowed })
        $bad | Should -BeNullOrEmpty -Because 'a new host would mean data can leave the tenant boundary'
    }
    It 'never writes to the tenant: no Invoke-Expression, and POST only for the batch read, the audit search and the inventory query' {
        $files = @(Get-ChildItem (Join-Path $root 'src') -Recurse -Filter *.ps1) + @(Get-Item (Join-Path $root 'Invoke-CopilotReadiness.ps1'))
        $posts = @(); $writes = @()
        foreach ($f in $files) {
            $t = (Get-Content $f.FullName | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"   # code, not comments
            if ($t -match 'Invoke-Expression|\biex\b') { $writes += "$($f.Name): Invoke-Expression" }
            if ($t -match '-Method\s+(Put|Patch|Delete)\b') { $writes += "$($f.Name): HTTP write method" }
            if ($t -match '\b(Set|Remove|New|Update|Add|Enable|Disable)-(Mg|SPO|Dlp|Label|Retention|AdminPowerApp|Protection|Unified)\w*') { $writes += "$($f.Name): write cmdlet" }
            foreach ($m in [regex]::Matches($t, '-Method\s+(''?)POST\1', 'IgnoreCase')) { $posts += $f.Name }
        }
        $writes | Should -BeNullOrEmpty
        # Auth.ps1: token requests to login.microsoftonline.com · Audit.ps1: the one audit search · Graph.ps1: $batch of GETs · Readers.ps1: inventory query
        (@($posts | Sort-Object -Unique) -join ',') | Should -Be 'Audit.ps1,Auth.ps1,Graph.ps1,Readers.ps1'
    }
    It 'Readers only ever run Get- cmdlets' {
        . (Join-Path $root 'src/Graph.ps1'); . (Join-Path $root 'src/Readers.ps1')
        { Invoke-CrReader 'Start-SPODataAccessGovernanceInsight' } | Should -Throw '*Get- cmdlets*'
        { Invoke-CrReader 'Set-SPOSite' } | Should -Throw
    }
    It 'no write cmdlets are called anywhere in src' {
        [regex]::IsMatch($allSource, '(?m)^\s*(Set|New|Remove|Start|Stop|Enable|Disable|Add|Update)-(SPO|Dlp|Label|Retention|AdminDlp|Mg)\w*') | Should -BeFalse
    }
}

Describe 'All scripts parse under PowerShell 7' {
    It '<name> parses without errors' -ForEach $scriptFiles {
        $tokens = $null; $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs) | Out-Null
        $errs | Should -BeNullOrEmpty
    }
}
