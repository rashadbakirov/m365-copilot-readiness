#Requires -Modules Pester
# End-to-end: -Demo builds the full report from the fictional Contoso fixtures without any sign-in.

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $out = Join-Path ([IO.Path]::GetTempPath()) ("car-test-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
    & (Join-Path $root 'Invoke-CopilotReadiness.ps1') -Demo -NoOpen -OutputPath $out -Language de 6>$null | Out-Null
    $json = Get-ChildItem $out -Filter *.json | Select-Object -First 1
    $html = Get-ChildItem $out -Filter *.html | Select-Object -First 1
    $data = Get-Content $json.FullName -Raw | ConvertFrom-Json
    $catalog = Get-Content (Join-Path $root 'src/Catalog.json') -Raw | ConvertFrom-Json
}

Describe 'Demo run' {
    It 'writes one JSON and one HTML with a run id in the name' {
        $json | Should -Not -BeNullOrEmpty
        $html.Name | Should -Match '^copilot-agent-readiness-contoso-maschinenbau\.de-\d{8}-\d{6}-[0-9a-f]{6}\.html$'
    }
    It 'has a result for every catalogue check' { @($data.results).Count | Should -Be @($catalog.checks).Count }
    It 'uses only known states' { $data.results.State | Where-Object { $_ -notin 'Pass', 'Warn', 'Fail', 'NotLicensed', 'NoPermission', 'Manual', 'Unknown', 'NotApplicable', 'Info' } | Should -BeNullOrEmpty }
    It 'has no missing fixtures (Unknown only where the demo injects a 503)' {
        @($data.results | Where-Object State -eq 'Unknown').Id | Should -Be @('S08')
        $data.results.Detail | Where-Object { $_ -match 'No demo fixture' } | Should -BeNullOrEmpty
    }
    It 'shows the grey states the demo is built for' {
        ($data.results | Where-Object Id -eq 'K06').State | Should -Be 'NoPermission'
        ($data.results | Where-Object Id -eq 'I01').State | Should -Be 'NotLicensed'
        ($data.results | Where-Object Id -eq 'D01').State | Should -Be 'Manual'
        ($data.results | Where-Object Id -eq 'S02').State | Should -Be 'Info'
    }
    It 'scores with coverage and gives a verdict' {
        $data.scores.overall.coverage | Should -BeGreaterOrEqual 70
        $data.scores.overall.verdict | Should -BeIn 'good', 'warn', 'crit'
        @($data.scores.areas).Count | Should -Be 6
    }
    It 'builds a 30/60/90 plan' { @($data.plan.d30).Count | Should -BeGreaterThan 0; @($data.plan.licence).Count | Should -BeGreaterThan 0 }
    It 'embeds the payload into a self-contained HTML (no external scripts, styles or fonts)' {
        $h = Get-Content $html.FullName -Raw
        $h | Should -Not -Match '/\*__CR_PAYLOAD__\*/null'
        $h | Should -Not -Match '<script[^>]+src='
        $h | Should -Not -Match '<link[^>]+stylesheet'
        $h | Should -Not -Match 'fonts\.googleapis'
        $h | Should -Match 'Unterstützung gewünscht\? govnex\.de'
    }
    It 'records what it creates in the tenant' { $data.createsInTenant | Should -Match 'audit search' }
}
