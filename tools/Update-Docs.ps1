<#
.SYNOPSIS
  Regenerates the generated blocks in README.md from src/Manifest.json and src/Catalog.json:
  the Graph scope list and the check table. Run after changing either file. A Pester test checks the scope block.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$manifest = Get-Content (Join-Path $root 'src/Manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
$catalog = Get-Content (Join-Path $root 'src/Catalog.json') -Raw -Encoding utf8 | ConvertFrom-Json
function Get-CrScopeTable([string]$Lang) {
    $head = if ($Lang -eq 'de') { '| Berechtigung | Satz | Gebraucht von |' } else { '| Permission | Set | Used by |' }
    $none = if ($Lang -eq 'de') { 'Vorprüfung / Tenant-Infos' } else { 'preflight / tenant info' }
    @(
        $head, '|---|---|---|'
        foreach ($set in 'core', 'extended') {
            foreach ($s in $manifest.graphScopes.$set) {
                $by = @($catalog.checks | Where-Object { $_.reader -eq 'graph' -and $s -in $_.scopes } | ForEach-Object id)
                "| ``$s`` | $set | $(if ($by) { $by -join ', ' } else { $none }) |"
            }
        }
    ) -join "`n"
}

function Get-CrCheckTable([string]$Lang) {
    $de = $Lang -eq 'de'
    $head = if ($de) { '| ID | Bereich | Check | Leser | Bewertet | Gewicht |' } else { '| ID | Area | Check | Reader | Scored | Weight |' }
    @(
        $head, '|---|---|---|---|---|---|'
        foreach ($a in $catalog.areas) {
            foreach ($c in $catalog.checks | Where-Object area -eq $a.key) {
                $reader = switch ($c.reader) {
                    'graph' { 'Graph' } 'purview' { '`-Purview`' } 'sharepoint' { '`-SharePoint`' }
                    'powerplatform' { '`-PowerPlatform`' } 'ppapi' { '`-PowerPlatform -PowerPlatformClientId`' }
                    'manual' { if ($de) { 'Portal (manuell)' } else { 'portal (manual)' } }
                }
                $area = if ($de) { $a.de } else { $a.en }
                $title = if ($de) { $c.title_de } else { $c.title_en }
                $preview = if ($c.preview) { if ($de) { ' *(Preview-Felder)*' } else { ' *(preview fields)*' } }
                $scored = if ($c.scored -eq $false) { if ($de) { 'Info' } else { 'info' } } else { if ($de) { 'ja' } else { 'yes' } }
                "| $($c.id) | $area | $title$preview | $reader | $scored | $($c.weight) |"
            }
        }
    ) -join "`n"
}

# Both READMEs are filled from the same catalogue, so the German and English tables cannot drift apart.
foreach ($t in @{ file = 'README.md'; lang = 'de' }, @{ file = 'README.en.md'; lang = 'en' }) {
    $path = Join-Path $root $t.file
    if (-not (Test-Path $path)) { Write-Host "skipped (missing): $($t.file)"; continue }
    $text = Get-Content $path -Raw -Encoding utf8
    $sc = Get-CrScopeTable $t.lang
    $ch = Get-CrCheckTable $t.lang
    $text = [regex]::Replace($text, '(?s)(<!-- scopes:start -->).*?(<!-- scopes:end -->)', { param($m) "$($m.Groups[1].Value)`n$sc`n$($m.Groups[2].Value)" })
    $text = [regex]::Replace($text, '(?s)(<!-- checks:start -->).*?(<!-- checks:end -->)', { param($m) "$($m.Groups[1].Value)`n$ch`n$($m.Groups[2].Value)" })
    Set-Content $path $text -Encoding utf8 -NoNewline
    "updated: $($t.file)"
}
