# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
    .SYNOPSIS
    Azure DevOps entry point for Win32-OpenSSH code coverage.

    .DESCRIPTION
    Runs one OpenSSH test suite (the "Core" flow - setup + unit + E2E - or the
    "Bash" flow) under Microsoft.CodeCoverage.Console against an
    already-installed OpenSSH directory, using the same AzDOBuildTools entry
    points the CI test jobs use.

    The installed OpenSSH binaries (built with /PROFILE by the coverage build
    job) are statically instrumented with a per-suite session id, then the suite
    runs while a background server-mode collector owns that session. This
    captures every instrumented OpenSSH process - including sshd.exe running as a
    Windows service, which is not a child of this script. `shutdown` flushes a
    per-suite .coverage file that is converted to Cobertura; every per-suite
    report found under -OutputDirectory is then aggregated into a combined,
    de-duplicated report plus per-suite/overlap summaries.

    Because the aggregation scans -OutputDirectory each time, the script is
    idempotent: call it once per suite (Core, then Bash) into the same
    -OutputDirectory and the final call produces the aggregate report. The
    instrument step restores (uninstruments) each binary first, so sharing an
    installed directory across the two invocations is safe.

    This script assumes the solution is already built (with /PROFILE) and
    installed. It never builds.

    .PARAMETER Suite
    Which suite to measure this invocation: Core or Bash.

    .PARAMETER OpenSSHBinPath
    Installed OpenSSH directory containing the binaries, their PDBs and the
    unittest-*.exe binaries (CI installs this to $env:SystemDrive\OpenSSH).

    .PARAMETER SourceRoot
    Repository root used to scope coverage to OpenSSH source files.

    .PARAMETER OutputDirectory
    Where per-suite and merged coverage artifacts are written.

    .EXAMPLE
    .\Invoke-AzDOCodeCoverage.ps1 -Suite Core -OutputDirectory C:\cov
    .\Invoke-AzDOCodeCoverage.ps1 -Suite Bash -OutputDirectory C:\cov
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Core', 'Bash')]
    [string] $Suite,

    [string] $OpenSSHBinPath = "$env:SystemDrive\OpenSSH",

    [string] $SourceRoot,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'

$opensshDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $SourceRoot) {
    $SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
}
$azdoModule = Join-Path $opensshDir 'AzDOBuildTools'

Import-Module (Join-Path $PSScriptRoot 'OpenSSHCodeCoverage.psm1') -Force

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$tool = Find-CodeCoverageConsole
Write-Host "CodeCoverage.Console : $tool"
Write-Host "Suite                : $Suite"
Write-Host "OpenSSHBinPath       : $OpenSSHBinPath"
Write-Host "SourceRoot           : $SourceRoot"

switch ($Suite) {
    'Core' {
        $name = 'core'
        $cmd = "Import-Module '$azdoModule' -Force; Invoke-OpenSSHTests -OpenSSHBinPath '$OpenSSHBinPath'"
    }
    'Bash' {
        $name = 'bash'
        $cmd = "Import-Module '$azdoModule' -Force; Invoke-OpenSSHBashTestsOnly -OpenSSHBinPath '$OpenSSHBinPath'"
    }
}

# Instrument the installed OpenSSH binaries with a per-suite session id, then
# run the suite while a server-mode collector owns that session.
$targets = Get-OpenSSHCoverageTarget -BinaryDirectory $OpenSSHBinPath
if (-not $targets) {
    throw "No OpenSSH binaries to instrument were found under '$OpenSSHBinPath'."
}
Write-Host "Instrumenting $($targets.Count) binaries for suite '$name'..."

$sessionId = [guid]::NewGuid().ToString()
Invoke-CoverageInstrument -BinaryPath $targets -SessionId $sessionId -ToolPath $tool | Out-Null

# The current PowerShell host re-invokes itself so its ssh/sshd/unittest
# children (all instrumented) run inside the collection window.
$pwshHost = (Get-Process -Id $PID).Path

try {
    $session = Invoke-CoverageSession -Name $name `
        -Program $pwshHost -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $cmd) `
        -SessionId $sessionId `
        -OutputDirectory (Join-Path $OutputDirectory $name) `
        -ToolPath $tool
    Write-Host "Suite '$name' coverage exit code: $($session.ExitCode)"
}
finally {
    # Restore the binaries so a subsequent suite step starts from clean images.
    Invoke-CoverageUninstrument -BinaryPath $targets -ToolPath $tool
}

# --- Aggregate every per-suite report collected so far --------------------
$coberturaReports = Get-ChildItem -Path $OutputDirectory -Filter '*.cobertura.xml' -Recurse |
    Where-Object { $_.FullName -notmatch '\\merged\\' }

if (-not $coberturaReports) {
    Write-Warning 'No per-suite Cobertura reports were produced; skipping aggregation.'
    return
}

$suiteMaps = @()
$suiteStats = @()
foreach ($report in $coberturaReports) {
    $suiteName = [System.IO.Path]::GetFileNameWithoutExtension($report.Name) -replace '\.cobertura$', ''
    $map = Import-CoberturaCoverage -Path $report.FullName -RepositoryRoot $SourceRoot
    $suiteMaps += , $map
    $suiteStats += Get-CoverageStatistic -CoverageMap $map -Name $suiteName
}

$mergedMap = Merge-CoverageData -CoverageMap $suiteMaps
$combinedStat = Get-CoverageStatistic -CoverageMap $mergedMap -Name 'combined'
$overlap = Measure-CoverageOverlap -CoverageMap $suiteMaps

$mergedDir = Join-Path $OutputDirectory 'merged'
# Regenerate the merge from every .coverage found each run so the report stays
# complete as suites accumulate; clear first to avoid stale outputs.
Remove-Item -LiteralPath $mergedDir -Recurse -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Path $mergedDir -Force

$nativeMerged = Join-Path $mergedDir 'merged.cobertura.xml'
$helperMerged = Join-Path $mergedDir 'merged-helper.cobertura.xml'

# Authoritative native merge of every per-suite .coverage file.
$coverageFiles = Get-ChildItem -Path $OutputDirectory -Filter '*.coverage' -Recurse | ForEach-Object { $_.FullName }
$nativeMergeOk = $false
if ($coverageFiles) {
    try {
        Convert-CoverageReport -InputPath $coverageFiles -OutputPath $nativeMerged -Format cobertura -ToolPath $tool | Out-Null
        $nativeMergeOk = Test-Path -LiteralPath $nativeMerged
    }
    catch {
        Write-Warning "Native coverage merge failed: $($_.Exception.Message)"
    }
}

# Helper-merged Cobertura (independent of the native merge) + summaries.
New-MergedCoberturaReport -CoverageMap $mergedMap -OutputPath $helperMerged | Out-Null

# Guarantee merged.cobertura.xml exists for the publish step even when the
# native merge was skipped (no .coverage) or failed, by falling back to the
# helper.
if (-not $nativeMergeOk) {
    Write-Warning 'Using helper-merged Cobertura as merged.cobertura.xml (native merge unavailable).'
    Copy-Item -LiteralPath $helperMerged -Destination $nativeMerged -Force
}

$summary = Get-CoverageSummary -SuiteStatistic $suiteStats -CombinedStatistic $combinedStat -Overlap $overlap
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $OutputDirectory 'coverage-summary.json')

$markdown = Format-CoverageSummaryMarkdown -Summary $summary
$markdown | Set-Content -Path (Join-Path $OutputDirectory 'coverage-summary.md')
Write-Host "`n$markdown"
