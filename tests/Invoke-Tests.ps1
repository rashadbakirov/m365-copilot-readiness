<#
.SYNOPSIS  Runs the Pester tests (Pester 5 or later) and PSScriptAnalyzer. Exit code 1 on any failure or analyzer error.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module Pester -MinimumVersion 5.5
$cfg = New-PesterConfiguration
$cfg.Run.Path = $PSScriptRoot
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Normal'
$r = Invoke-Pester -Configuration $cfg

Import-Module PSScriptAnalyzer
$issues = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1') | Where-Object ScriptPath -notmatch '[\\/](internal|out)[\\/]')
$errors = @($issues | Where-Object Severity -eq 'Error')
Write-Host ("PSScriptAnalyzer: {0} errors, {1} warnings, {2} information" -f $errors.Count, @($issues | Where-Object Severity -eq 'Warning').Count, @($issues | Where-Object Severity -eq 'Information').Count)
$errors | Format-Table RuleName, ScriptName, Line, Message -AutoSize | Out-String -Width 200 | Write-Host
if ($r.FailedCount -gt 0 -or $errors.Count -gt 0) { exit 1 }
