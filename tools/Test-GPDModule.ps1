#requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$SkipAnalyzer,
    [switch]$SkipPester
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleManifest = Join-Path $repoRoot 'Google-PhotosDeDuplicate/Google-PhotosDeDuplicate.psd1'

Import-Module $moduleManifest -Force

if (-not $SkipAnalyzer) {
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        throw 'PSScriptAnalyzer is not installed. Run: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck'
    }

    $analysis = Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot 'Google-PhotosDeDuplicate') -Recurse -Severity Warning,Error
    if ($analysis) {
        $analysis | Format-Table -AutoSize
        throw "PSScriptAnalyzer found $($analysis.Count) issue(s)."
    }
}

if (-not $SkipPester) {
    if (-not (Get-Module -ListAvailable -Name Pester)) {
        throw 'Pester is not installed. Run: Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck'
    }

    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $repoRoot 'tests'
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $result = Invoke-Pester -Configuration $config
    if ($result.FailedCount -gt 0) {
        throw "Pester failed: $($result.FailedCount) failing test(s)."
    }
}

$review = Invoke-GPDDetractorReview
if (-not $review.Passed) {
    $review.Findings | Format-Table -AutoSize
    throw "Detractor review failed with $($review.FindingCount) finding(s)."
}

$review
Write-Host 'Validation completed successfully.' -ForegroundColor Green
