# Core.ps1 — result model, state mapping, messages, preflight capabilities, scoring with coverage, action plan.
# Everything here is pure (no tenant calls) so it can be unit-tested with Pester.

$script:CrStates = @('Pass', 'Warn', 'Fail', 'NotLicensed', 'NoPermission', 'Manual', 'Unknown', 'NotApplicable', 'Info')
$script:CrScoredStates = @('Pass', 'Warn', 'Fail')

# ---------- messages (structured translations) ----------

function Import-CrI18n {
    param([Parameter(Mandatory)][string]$Path)
    $script:CrI18n = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $script:CrI18n
}

function Format-CrMessage {
    <#
      .SYNOPSIS  Fills a message template ("{n} of {total} …") with named arguments.
      .EXAMPLE   Format-CrMessage -Key 'S05.public' -Arguments @{ n = 3; total = 40; pct = 7.5 } -Language en
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Arguments = @{},
        [ValidateSet('de', 'en')][string]$Language = 'en',
        [hashtable]$I18n = $script:CrI18n
    )
    $m = if ($I18n -and $I18n.messages.ContainsKey($Key)) { $I18n.messages[$Key][$Language] } else { $null }
    if (-not $m) { return $Key }
    [regex]::Replace($m, '\{(\w+)\}', {
            param($x)
            $n = $x.Groups[1].Value
            if ($Arguments.ContainsKey($n)) {
                $v = $Arguments[$n]
                # Readable words instead of raw values: yes/no/unknown, Graph enums ("enum.<value>"), result states.
                if ($I18n -and $I18n.ui -and $v -is [string]) {
                    foreach ($k in @($(if ($v -in 'yes', 'no', 'unknown') { $v }), "enum.$v", "state.$v")) {
                        if ($k -and $I18n.ui.ContainsKey($k)) { return "$($I18n.ui[$k][$Language])" }
                    }
                }
                if ($v -is [double] -or $v -is [decimal]) { return ([Math]::Round([double]$v, 1)).ToString([Globalization.CultureInfo]::InvariantCulture) }
                return "$v"
            }
            return $x.Value
        })
}

function Get-CrUiText {
    <#
      .SYNOPSIS  One UI string in the requested language: falls back to English, then to the key itself.
      .EXAMPLE   Get-CrUiText $i18n 'disclosure.readonly' 'de'
    #>
    param(
        [hashtable]$I18n = $script:CrI18n,
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet('de', 'en')][string]$Language = 'de'
    )
    if (-not $I18n -or -not $I18n.ui -or -not $I18n.ui.ContainsKey($Key)) { return $Key }
    $e = $I18n.ui[$Key]
    "$(if ($e[$Language]) { $e[$Language] } elseif ($e['en']) { $e['en'] } else { $Key })"
}

function Format-CrWrap {
    <#
      .SYNOPSIS  Wraps console text at a word boundary and indents every continuation line.
      .EXAMPLE   Format-CrWrap 'a long sentence' 40 '  '
    #>
    param([string]$Text, [int]$Width = 76, [string]$Indent = '')
    $lines = @(); $cur = ''
    foreach ($w in @("$Text" -split '\s+' | Where-Object { $_ })) {
        if ($cur -and ($cur.Length + 1 + $w.Length) -gt $Width) { $lines += $cur; $cur = $w }
        else { $cur = if ($cur) { "$cur $w" } else { $w } }
    }
    if ($cur) { $lines += $cur }
    $lines -join ("`n" + $Indent)
}

# ---------- result model ----------

function New-CrResult {
    <#
      .SYNOPSIS  The one result object every check returns. Only Pass/Warn/Fail carry a score.
      .EXAMPLE   New-CrResult -Id S05 -State Warn -Score 70 -Msg 'S05.public' -Arguments @{ n = 3; total = 40; pct = 7.5 }
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Warn', 'Fail', 'NotLicensed', 'NoPermission', 'Manual', 'Unknown', 'NotApplicable', 'Info')][string]$State,
        [int]$Score = -1,
        [string]$Msg = '',
        [hashtable]$Arguments = @{},
        [object[]]$Evidence = @(),
        [string]$Detail = '',
        [object]$Raw = $null
    )
    if ($State -in $script:CrScoredStates) {
        if ($Score -lt 0) { $Score = switch ($State) { 'Pass' { 100 } 'Warn' { 50 } 'Fail' { 0 } } }
        $Score = [Math]::Max(0, [Math]::Min(100, $Score))
        # a score must never contradict its state: Pass >= 75, Fail < 45 is the report's colour band
        if ($State -eq 'Pass' -and $Score -lt 75) { $Score = 75 }
        if ($State -eq 'Fail' -and $Score -ge 45) { $Score = 40 }
        if ($State -eq 'Warn') { $Score = [Math]::Max(45, [Math]::Min(74, $Score)) }
    }
    else { $Score = -1 }
    $summary = if ($Msg) { Format-CrMessage -Key $Msg -Arguments $Arguments -Language en } else { '' }
    [pscustomobject]@{
        Id       = $Id
        State    = $State
        Score    = $Score
        Msg      = $Msg
        Args     = $Arguments
        Summary  = $summary
        Evidence = @($Evidence | Where-Object { $null -ne $_ })
        Detail   = $Detail
        Raw      = $Raw
    }
}

function Get-CrErrorState {
    <#
      .SYNOPSIS  Maps a failed call to a result state. Never returns a scored state.
                 401/403 → NoPermission · licence text → NotLicensed · everything else → Unknown.
      .EXAMPLE   Get-CrErrorState -StatusCode 403 -Message 'Authorization_RequestDenied'
    #>
    param([int]$StatusCode = 0, [string]$Message = '')
    $licence = 'licen[cs]e|not licensed|subscription|SKU|not provisioned|feature is not enabled|tenant is not enabled'
    # A server-side failure is never a statement about licences or permissions, whatever its text says.
    if ($StatusCode -ge 500) { return [pscustomobject]@{ State = 'Unknown'; Msg = 'gen.unknown' } }
    if ($StatusCode -in 401, 403) {
        if ($Message -match $licence) { return [pscustomobject]@{ State = 'NotLicensed'; Msg = 'gen.notLicensedApi' } }
        return [pscustomobject]@{ State = 'NoPermission'; Msg = 'gen.noPermission' }
    }
    if ($Message -match $licence) { return [pscustomobject]@{ State = 'NotLicensed'; Msg = 'gen.notLicensedApi' } }
    # A plain 400 'BadRequest' is usually our own malformed query, not a missing endpoint: that stays Unknown.
    if ($StatusCode -eq 404 -or ($StatusCode -eq 400 -and $Message -match 'not supported|Resource not found|segment')) {
        return [pscustomobject]@{ State = 'Unknown'; Msg = 'gen.endpointMissing' }
    }
    if ($Message -match 'Access is denied|not authorized|Unauthorized|insufficient privileges|isn.t assigned|not have permission|required role') {
        return [pscustomobject]@{ State = 'NoPermission'; Msg = 'gen.noPermission' }
    }
    # The reader connected, but the cmdlet is not offered to this account/tenant (role or licence; we cannot tell which).
    if ($Message -match 'was not exposed to the signed-in account') { return [pscustomobject]@{ State = 'Unknown'; Msg = 'gen.cmdletMissing' } }
    if (-not $StatusCode) { return [pscustomobject]@{ State = 'Unknown'; Msg = 'gen.unknownNoHttp' } }
    return [pscustomobject]@{ State = 'Unknown'; Msg = 'gen.unknown' }
}

function Get-CrHttpStatus($ErrorRecord) {
    $status = 0
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { $status = 0 }
    if (-not $status -and $ErrorRecord.Exception.Data -and $ErrorRecord.Exception.Data.Contains('HttpStatus')) { $status = [int]$ErrorRecord.Exception.Data['HttpStatus'] }
    # Only a number that is labelled as a status, e.g. "HTTP 403" or "Response status code does not indicate success: 403".
    if (-not $status -and "$($ErrorRecord.Exception.Message)" -match '(?:HTTP|status code[^0-9]{0,40}|StatusCode[:=\s]+)\s*(40[0-9]|429|50[0-9])\b') { $status = [int]$Matches[1] }
    $status
}

function Invoke-CrCheck {
    <#
      .SYNOPSIS  Runs one check body safely. A thrown error becomes NoPermission / NotLicensed / Unknown, never a pass.
    #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][scriptblock]$Body)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = @(& $Body) | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['State'] -and $_.Id -eq $Id } | Select-Object -Last 1
        # Nothing, or leaked pipeline output instead of a result: never a pass, never a crash later in the report.
        if (-not $r) { $r = New-CrResult -Id $Id -State Unknown -Msg 'gen.empty' }
    }
    catch {
        $status = Get-CrHttpStatus $_
        $msg = "$($_.Exception.Message)"
        if ($_.ErrorDetails.Message) { try { $g = ($_.ErrorDetails.Message | ConvertFrom-Json).error; if ($g.message) { $msg = "$($g.code): $($g.message)" } } catch { Write-Verbose 'no Graph error body' } }
        $map = Get-CrErrorState -StatusCode $status -Message $msg
        $r = New-CrResult -Id $Id -State $map.State -Msg $map.Msg -Arguments @{ status = $(if ($status) { $status } else { '-' }) } -Detail $msg
    }
    $sw.Stop()
    $r | Add-Member -NotePropertyName DurationMs -NotePropertyValue $sw.ElapsedMilliseconds -Force
    Write-CrResultLine $r
    return $r
}

function Get-CrConsoleText {
    <# One console string in the run language ($script:CrLanguage, set by the entry script; English when unset). #>
    param([Parameter(Mandatory)][string]$Key)
    $lang = if ($script:CrLanguage -in 'de', 'en') { $script:CrLanguage } else { 'en' }
    Get-CrUiText -I18n $script:CrI18n -Key $Key -Language $lang
}

function Write-CrResultLine($r) {
    $color = switch ($r.State) { 'Pass' { 'Green' } 'Warn' { 'Yellow' } 'Fail' { 'Red' } 'Unknown' { 'Magenta' } default { 'DarkGray' } }
    # The console speaks the report's language: state label and message from i18n (the stored Summary stays English for the JSON).
    $lang = if ($script:CrLanguage -in 'de', 'en') { $script:CrLanguage } else { 'en' }
    $label = if ($script:CrI18n) { Get-CrConsoleText "state.$($r.State)" } else { $r.State }
    $text = if ($lang -ne 'en' -and $r.Msg -and $script:CrI18n) { Format-CrMessage -Key $r.Msg -Arguments $r.Args -Language $lang } else { $r.Summary }
    Write-Host ("  [{0,-16}] {1}  {2}" -f $label, $r.Id, $text) -ForegroundColor $color
}

function Get-CrPct([double]$Part, [double]$Whole) {
    if ($Whole -le 0) { return 0 }
    [Math]::Round(100.0 * $Part / $Whole, 1)
}

# ---------- preflight: what will run ----------

function Get-CrCapabilities {
    <#
      .SYNOPSIS  Decides per check whether it runs, and why not. Pure function over the run context.
      .PARAMETER Context  @{ Mode; Scopes (granted); ServicePlans (tenant); Readers = @{ graph; purview; sharepoint; powerplatform; ppapi } }
    #>
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][hashtable]$Context, [object]$Manifest)
    $plans = @($Context.ServicePlans)
    $scopes = @($Context.Scopes)
    foreach ($c in $Catalog.checks) {
        $reader = "$($c.reader)"
        $row = [ordered]@{ id = $c.id; area = $c.area; reader = $reader; run = $true; state = $null; msg = $null; args = @{} }
        if ($reader -eq 'manual') {
            $row.run = $false; $row.state = 'Manual'; $row.msg = "$($c.id).manual"
        }
        elseif (-not $Context.Readers[$reader]) {
            $sw = if ($Manifest -and $Manifest.readers.$reader) { $Manifest.readers.$reader.switch } else { $reader }
            $row.run = $false; $row.state = 'Manual'; $row.msg = 'gen.readerOff'; $row.args = @{ switch = "$sw" }
        }
        elseif ($reader -eq 'graph' -and $Context.Mode -eq 'delegated' -and @($c.scopes | Where-Object { $_ }).Count -gt 0 -and -not (@($c.scopes | Where-Object { $_ }) | Where-Object { $_ -in $scopes })) {
            $row.run = $false; $row.state = 'NoPermission'; $row.msg = 'gen.scopeMissing'; $row.args = @{ scope = (@($c.scopes | Where-Object { $_ }) -join ' / ') }
        }
        elseif ($c.plans -and $Context.ServicePlansKnown -and -not (@($c.plans | Where-Object { $_ }) | Where-Object { $_ -in $plans })) {
            $row.run = $false; $row.state = 'NotLicensed'; $row.msg = 'gen.notLicensed'; $row.args = @{ plan = (@($c.plans | Where-Object { $_ }) -join ' / ') }
        }
        [pscustomobject]$row
    }
}

function Get-CrCapabilitySummary {
    <# One row per reader: connected?, checks that run, checks skipped and the main reason. For console and report. #>
    param([Parameter(Mandatory)]$Capabilities, [Parameter(Mandatory)][hashtable]$Context)
    $Capabilities | Group-Object reader | ForEach-Object {
        $g = $_.Group
        [pscustomobject]@{
            reader    = $_.Name
            connected = [bool]$Context.Readers[$_.Name]
            run       = @($g | Where-Object run).Count
            skipped   = @($g | Where-Object { -not $_.run }).Count
            checks    = (@($g.id) -join ', ')
            skippedIds = (@($g | Where-Object { -not $_.run } | ForEach-Object { "$($_.id) ($($_.state))" }) -join ', ')
        }
    }
}

# ---------- scoring with coverage ----------

function Get-CrScores {
    <#
      .SYNOPSIS  Weighted score of assessed checks plus coverage, per area and overall.
                 Only Pass/Warn/Fail are assessed. Unscored checks (Info items, scored=false) and NotApplicable
                 results are outside the denominator. Everything else (Manual, NoPermission, NotLicensed, Unknown)
                 stays in the denominator and lowers coverage.
                 Verdict is 'incomplete' when overall coverage < minCoverage or any area has coverage < minAreaCoverage.
    #>
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()]$Results,
        [int]$MinCoverage = 70,
        [int]$MinAreaCoverage = 25,
        [int]$Good = 75,
        [int]$Warn = 45,
        [switch]$PartialRun
    )
    $byId = @{}; foreach ($r in $Results) { $byId[$r.Id] = $r }
    $sumWS = 0.0; $sumAssessed = 0.0; $sumApplicable = 0.0
    $areas = foreach ($a in $Catalog.areas) {
        $aWS = 0.0; $aAss = 0.0; $aApp = 0.0
        $counts = [ordered]@{}; foreach ($s in $script:CrStates) { $counts[$s] = 0 }
        foreach ($c in @($Catalog.checks | Where-Object area -eq $a.key)) {
            $r = $byId[$c.id]
            if (-not $r) { continue }                       # not run (-Only) → not part of this run
            $counts[$r.State]++
            if ($c.scored -eq $false -or $r.State -in @('NotApplicable', 'Info')) { continue }
            $w = [double]$c.weight
            $aApp += $w
            if ($r.State -in $script:CrScoredStates) { $aAss += $w; $aWS += $w * [double]$r.Score }
        }
        $sumWS += $aWS; $sumAssessed += $aAss; $sumApplicable += $aApp
        [pscustomobject]@{
            key        = $a.key
            score      = $(if ($aAss -gt 0) { [int][Math]::Round($aWS / $aAss, [MidpointRounding]::AwayFromZero) } else { $null })
            coverage   = $(if ($aApp -gt 0) { [int][Math]::Round(100 * $aAss / $aApp, [MidpointRounding]::AwayFromZero) } else { $null })
            coverageExact = $(if ($aApp -gt 0) { 100 * $aAss / $aApp } else { $null })
            assessedWeight   = $aAss
            applicableWeight = $aApp
            counts     = [pscustomobject]$counts
        }
    }
    # Thresholds compare the exact values; only the displayed numbers are rounded (half away from zero, not banker's).
    $scoreExact = if ($sumAssessed -gt 0) { $sumWS / $sumAssessed } else { $null }
    $coverageExact = if ($sumApplicable -gt 0) { 100 * $sumAssessed / $sumApplicable } else { 0 }
    $score = if ($null -ne $scoreExact) { [int][Math]::Round($scoreExact, [MidpointRounding]::AwayFromZero) } else { $null }
    $coverage = [int][Math]::Round($coverageExact, [MidpointRounding]::AwayFromZero)
    $weakAreas = @($areas | Where-Object { $null -ne $_.coverageExact -and $_.coverageExact -lt $MinAreaCoverage } | ForEach-Object key)
    $verdict = if ($null -eq $score) { 'none' }
    elseif ($PartialRun -or $coverageExact -lt $MinCoverage -or $weakAreas.Count -gt 0) { 'incomplete' }
    elseif ($scoreExact -ge $Good) { 'good' }
    elseif ($scoreExact -ge $Warn) { 'warn' }
    else { 'crit' }
    [pscustomobject]@{
        areas   = @($areas)
        overall = [pscustomobject]@{
            score = $score; coverage = $coverage; verdict = $verdict
            assessedWeight = $sumAssessed; applicableWeight = $sumApplicable
            weakAreas = $weakAreas; minCoverage = $MinCoverage; minAreaCoverage = $MinAreaCoverage; partialRun = [bool]$PartialRun
        }
    }
}

# ---------- action plan 30 / 60 / 90 ----------

function Get-CrActionPlan {
    <#
      .SYNOPSIS  Sorts open items into 30/60/90 days. Fail with weight >= 2 → 30. Other Fail or Warn with weight 3 → 60.
                 Other Warn → 90. Missing evidence (Manual, NoPermission, Unknown) → 'gaps' (close in the first 30 days).
                 NotLicensed → 'licence' (a decision, not a task).
    #>
    param([Parameter(Mandatory)]$Catalog, [Parameter(Mandatory)][AllowEmptyCollection()]$Results)
    $byId = @{}; foreach ($r in $Results) { $byId[$r.Id] = $r }
    $plan = [ordered]@{ d30 = @(); d60 = @(); d90 = @(); gaps = @(); licence = @() }
    $rank = @{ Fail = 0; Warn = 1 }
    $ordered = @($Catalog.checks | Where-Object { $byId[$_.id] } | Sort-Object @{ e = { $r = $byId[$_.id]; if ($rank.ContainsKey($r.State)) { $rank[$r.State] } else { 2 } } }, @{ e = { $_.weight }; Descending = $true }, @{ e = { $byId[$_.id].Score } })
    foreach ($c in $ordered) {
        if ($c.scored -eq $false) { continue }
        $r = $byId[$c.id]
        $item = [pscustomobject]@{ id = $c.id; state = $r.State; weight = $c.weight; effort = $c.effort }
        switch ($r.State) {
            'Fail' { if ($c.weight -ge 2) { $plan.d30 += $item } else { $plan.d60 += $item } }
            'Warn' { if ($c.weight -ge 3) { $plan.d60 += $item } else { $plan.d90 += $item } }
            { $_ -in 'Manual', 'NoPermission', 'Unknown' } { $plan.gaps += $item }
            'NotLicensed' { $plan.licence += $item }
        }
    }
    [pscustomobject]$plan
}

# ---------- run id / file names ----------

function New-CrRunId {
    $hex = -join ((1..6) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$hex"
}

function Get-CrResultHash {
    <# SHA-256 over the check results only (Id, State, Score, Msg, Args, Evidence). Not a signature and not over the whole report. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Results)
    $items = @($Results | ForEach-Object {
            $a = [ordered]@{}; if ($_.Args) { foreach ($k in ($_.Args.Keys | Sort-Object)) { $a[$k] = $_.Args[$k] } }
            [ordered]@{ Id = $_.Id; State = $_.State; Score = $_.Score; Msg = $_.Msg; Args = $a; Evidence = @($_.Evidence) }
        })
    # An empty result list hashes "[]" instead of failing on a null string.
    $canon = if ($items.Count -gt 0) { $items | ConvertTo-Json -Depth 10 -Compress } else { '[]' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($canon)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' } finally { $sha.Dispose() }
}
