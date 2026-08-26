# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
    .SYNOPSIS
    Azure DevOps entry point for Win32-OpenSSH code coverage.

    .DESCRIPTION
    Runs one OpenSSH test suite (the "Core" flow - setup + unit + E2E - or the
    "Bash" flow) under OpenCppCoverage against an already-installed OpenSSH
    directory, using the same AzDOBuildTools entry points the CI test jobs use.
    Each run writes a per-suite binary (.cov) and Cobertura report, then merges
    every .cov present under -OutputDirectory into a combined, de-duplicated
    report plus per-suite/overlap summaries.

    Because the merge scans -OutputDirectory each time, the script is
    idempotent: call it once per suite (Core, then Bash) into the same
    -OutputDirectory and the final call produces the aggregate report.

    This script assumes the solution is already built and installed (the CI
    Build stage produces PDBs alongside the binaries, which OpenCppCoverage
    needs). It never builds.

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
$openCpp = Install-OpenCppCoverage
Write-Host "OpenCppCoverage : $openCpp"
Write-Host "Suite           : $Suite"
Write-Host "OpenSSHBinPath  : $OpenSSHBinPath"
Write-Host "SourceRoot      : $SourceRoot"

# The current PowerShell host re-invokes itself so OpenCppCoverage can monitor
# it (and every ssh/sshd/unittest child it spawns).
$pwshHost = (Get-Process -Id $PID).Path

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

$session = Invoke-CoverageSession -Name $name `
    -Program $pwshHost -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $cmd) `
    -OutputDirectory (Join-Path $OutputDirectory $name) `
    -SourceRoot $SourceRoot -ModuleFilter $OpenSSHBinPath `
    -OpenCppCoveragePath $openCpp

Write-Host "Suite '$name' coverage exit code: $($session.ExitCode)"

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
# Start each run from a clean merged directory. The CI job calls this script
# once per suite into the same -OutputDirectory; regenerating the merge from
# every .cov found (below) keeps the report complete, and clearing first avoids
# OpenCppCoverage refusing to overwrite an existing HTML export directory.
Remove-Item -LiteralPath $mergedDir -Recurse -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Path $mergedDir -Force

$nativeMerged = Join-Path $mergedDir 'merged.cobertura.xml'
$helperMerged = Join-Path $mergedDir 'merged-helper.cobertura.xml'

# Authoritative native merge (also emits browsable HTML).
$binaries = Get-ChildItem -Path $OutputDirectory -Filter '*.cov' -Recurse | ForEach-Object { $_.FullName }
$nativeMergeOk = $false
if ($binaries) {
    try {
        Merge-CoverageBinary -BinaryPath $binaries -OutputDirectory $mergedDir -Html -OpenCppCoveragePath $openCpp | Out-Null
        $nativeMergeOk = Test-Path -LiteralPath $nativeMerged
    }
    catch {
        Write-Warning "Native binary merge failed: $($_.Exception.Message)"
    }
}

# Helper-merged Cobertura (independent of the native merge) + summaries.
New-MergedCoberturaReport -CoverageMap $mergedMap -OutputPath $helperMerged | Out-Null

# Guarantee merged.cobertura.xml exists for the publish step even when the
# native merge was skipped (no .cov) or failed, by falling back to the helper.
if (-not $nativeMergeOk) {
    Write-Warning 'Using helper-merged Cobertura as merged.cobertura.xml (native merge unavailable).'
    Copy-Item -LiteralPath $helperMerged -Destination $nativeMerged -Force
}

$summary = Get-CoverageSummary -SuiteStatistic $suiteStats -CombinedStatistic $combinedStat -Overlap $overlap
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $OutputDirectory 'coverage-summary.json')

$markdown = Format-CoverageSummaryMarkdown -Summary $summary
$markdown | Set-Content -Path (Join-Path $OutputDirectory 'coverage-summary.md')
Write-Host "`n$markdown"
