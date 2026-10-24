# Defender & Schatten-KI — protection posture and AI outside control.

function Test-CrS10 {
    Invoke-CrCheck 'S10' {
        $ss = @((Invoke-CrGraph '/security/secureScores?$top=1').value) | Select-Object -First 1
        if (-not $ss -or -not ([double]$ss.maxScore -gt 0)) { return New-CrResult S10 -State Unknown -Msg 'gen.empty' }
        $pct = Get-CrPct $ss.currentScore $ss.maxScore
        # scoreInPercentage is not documented for every control; a control without it is not "open at 0 %".
        $open = @($ss.controlScores | Where-Object { $null -ne $_.scoreInPercentage -and [double]$_.scoreInPercentage -lt 100 -and $_.controlCategory -in @('Data', 'Apps', 'Identity') })
        $titles = @{}
        try { Invoke-CrGraph '/security/secureScoreControlProfiles?$select=id,title,maxScore' -All | ForEach-Object { $titles[$_.id] = $_ } } catch { Write-Verbose "S10 profiles: $_" }
        $ev = $open | Sort-Object { [double]$_.scoreInPercentage } | Select-Object -First 25 | ForEach-Object {
            $pr = $titles[$_.controlName]
            [pscustomobject]@{ Control = $(if ($pr) { $pr.title } else { $_.controlName }); Category = $_.controlCategory; Implemented = [int][double]$_.scoreInPercentage; MaxPoints = $(if ($pr) { $pr.maxScore } else { $null }) }
        }
        $state = if ($pct -ge 70) { 'Pass' } elseif ($pct -ge 45) { 'Warn' } else { 'Fail' }
        New-CrResult S10 -State $state -Score ([int]$pct) -Msg 'S10.score' -Arguments @{ pct = $pct; open = $open.Count } -Evidence $ev
    }
}

function Test-CrD01 {
    # Shadow-AI discovery is a portal step in v1 (Defender for Cloud Apps). The preflight marks it Manual before this runs.
    Invoke-CrCheck 'D01' { New-CrResult D01 -State Manual -Msg 'D01.manual' }
}
