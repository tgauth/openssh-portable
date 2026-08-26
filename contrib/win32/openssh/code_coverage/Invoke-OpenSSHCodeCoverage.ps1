# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
    .SYNOPSIS
    Generates a C code coverage estimate for the Win32-OpenSSH solution
    (contrib\win32\openssh\Win32-OpenSSH.sln) across the unit, Pester (E2E) and
    bash test suites, then aggregates them into a single de-duplicated report.

    .DESCRIPTION
    For each requested suite the script runs the suite under OpenCppCoverage,
    which attaches to the launched process and every child it spawns (ssh.exe,
    sshd.exe, sftp.exe, the unittest-*.exe binaries, ...) and records line
    coverage from the debug PDBs. Each suite produces:

        <OutputDirectory>\<suite>\<suite>.cov            (binary, mergeable)
        <OutputDirectory>\<suite>\<suite>.cobertura.xml  (per-suite report)

    The binary files are merged natively by OpenCppCoverage into
    <OutputDirectory>\merged\merged.cobertura.xml (plus an HTML report). Because
    merging unions per-line hits, a line exercised by two suites is counted once
    - that is the aggregation-with-overlap behaviour requested.

    In parallel, the pure helpers in OpenSSHCodeCoverage.psm1 re-derive the same
    numbers from the per-suite Cobertura reports and additionally quantify how
    much the suites overlap. The final artifacts are:

        <OutputDirectory>\coverage-summary.json
        <OutputDirectory>\coverage-summary.md

    A Debug build is recommended so that full, unoptimized PDBs are available.

    .PARAMETER NativeHostArch
    Architecture whose bin\ folder holds the built binaries (x64, x86, arm64, arm).

    .PARAMETER Configuration
    Build configuration to measure. Debug is recommended for accurate coverage.

    .PARAMETER Suite
    Which suites to measure. Defaults to all three.

    .PARAMETER OutputDirectory
    Where coverage artifacts are written.

    .PARAMETER SkipBuild
    Assume the solution is already built; do not invoke MSBuild.

    .EXAMPLE
    .\Invoke-OpenSSHCodeCoverage.ps1 -Configuration Debug -Suite Unit

    .EXAMPLE
    .\Invoke-OpenSSHCodeCoverage.ps1 -Configuration Debug -OutputDirectory C:\cov
#>
[CmdletBinding()]
param(
    [ValidateSet('x86', 'x64', 'arm64', 'arm')]
    [string] $NativeHostArch = 'x64',

    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Debug',

    [ValidateSet('Unit', 'E2E', 'Bash')]
    [string[]] $Suite = @('Unit', 'E2E', 'Bash'),

    [string] $OutputDirectory,

    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
$opensshDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'OpenSSHCodeCoverage.psm1') -Force
Import-Module (Join-Path $opensshDir 'OpenSSHBuildHelper.psm1') -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $opensshDir 'OpenSSHTestHelper.psm1') -Force -ErrorAction SilentlyContinue

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repositoryRoot 'coverage'
}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force

$folderName = if ($NativeHostArch -ieq 'x86') { 'Win32' } else { $NativeHostArch }
$binPath = Join-Path $repositoryRoot "bin\$folderName\$Configuration"

Write-Host "Repository root : $repositoryRoot"
Write-Host "Binaries        : $binPath"
Write-Host "Output          : $OutputDirectory"
Write-Host "Suites          : $($Suite -join ', ')"

# --- Build -----------------------------------------------------------------
if (-not $SkipBuild) {
    if (-not (Get-Command 'Start-OpenSSHBuild' -ErrorAction SilentlyContinue)) {
        throw 'Start-OpenSSHBuild is unavailable; import OpenSSHBuildHelper.psm1 or pass -SkipBuild.'
    }
    Write-Host "Building Win32-OpenSSH ($NativeHostArch/$Configuration)..."
    Start-OpenSSHBuild -NativeHostArch $NativeHostArch -Configuration $Configuration
}

if (-not (Test-Path $binPath)) {
    throw "Binaries not found at $binPath. Build first or correct -NativeHostArch/-Configuration."
}

$openCpp = Install-OpenCppCoverage
Write-Host "OpenCppCoverage : $openCpp"

$pwsh = (Get-Process -Id $PID).Path  # path to the current PowerShell host
$sessions = @()

# --- Unit tests ------------------------------------------------------------
if ($Suite -contains 'Unit') {
    Write-Host "`n=== Unit tests ==="
    $cmd = "Import-Module '$opensshDir\OpenSSHTestHelper.psm1' -Force; Invoke-OpenSSHUnitTest -UnitTestDirectory '$binPath'"
    $sessions += Invoke-CoverageSession -Name 'unit' `
        -Program $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $cmd) `
        -OutputDirectory (Join-Path $OutputDirectory 'unit') `
        -SourceRoot $repositoryRoot -ModuleFilter $binPath `
        -OpenCppCoveragePath $openCpp
}

# --- Pester E2E tests ------------------------------------------------------
if ($Suite -contains 'E2E') {
    Write-Host "`n=== Pester E2E tests ==="
    $cmd = "Import-Module '$opensshDir\OpenSSHTestHelper.psm1' -Force; Set-OpenSSHTestEnvironment -OpenSSHBinPath '$binPath'; Invoke-OpenSSHE2ETest"
    $sessions += Invoke-CoverageSession -Name 'e2e' `
        -Program $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $cmd) `
        -OutputDirectory (Join-Path $OutputDirectory 'e2e') `
        -SourceRoot $repositoryRoot -ModuleFilter $binPath `
        -OpenCppCoveragePath $openCpp
}

# --- Bash tests ------------------------------------------------------------
if ($Suite -contains 'Bash') {
    Write-Host "`n=== Bash tests ==="
    $cmd = "Import-Module '$opensshDir\OpenSSHTestHelper.psm1' -Force; Set-OpenSSHTestEnvironment -OpenSSHBinPath '$binPath'; Invoke-OpenSSHBashTests"
    $sessions += Invoke-CoverageSession -Name 'bash' `
        -Program $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $cmd) `
        -OutputDirectory (Join-Path $OutputDirectory 'bash') `
        -SourceRoot $repositoryRoot -ModuleFilter $binPath `
        -OpenCppCoveragePath $openCpp
}

if (-not $sessions) {
    throw 'No suites were run; nothing to report.'
}

# --- Native merge (authoritative combined report) --------------------------
Write-Host "`n=== Merging coverage ==="
$binaries = $sessions | ForEach-Object { $_.BinaryPath } | Where-Object { Test-Path $_ }
$mergedCobertura = Merge-CoverageBinary -BinaryPath $binaries `
    -OutputDirectory (Join-Path $OutputDirectory 'merged') -Html -OpenCppCoveragePath $openCpp
Write-Host "Merged report   : $mergedCobertura"

# --- Helper aggregation + overlap ------------------------------------------
$suiteMaps = @()
$suiteStats = @()
foreach ($session in $sessions) {
    if (-not (Test-Path $session.CoberturaPath)) {
        Write-Warning "No Cobertura report for suite '$($session.Name)'; skipping."
        continue
    }
    $map = Import-CoberturaCoverage -Path $session.CoberturaPath -RepositoryRoot $repositoryRoot
    $suiteMaps += , $map
    $suiteStats += Get-CoverageStatistic -CoverageMap $map -Name $session.Name
}

$mergedMap = Merge-CoverageData -CoverageMap $suiteMaps
$combinedStat = Get-CoverageStatistic -CoverageMap $mergedMap -Name 'combined'
$overlap = Measure-CoverageOverlap -CoverageMap $suiteMaps

$summary = Get-CoverageSummary -SuiteStatistic $suiteStats -CombinedStatistic $combinedStat -Overlap $overlap
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $OutputDirectory 'coverage-summary.json')

$markdown = Format-CoverageSummaryMarkdown -Summary $summary
$markdown | Set-Content -Path (Join-Path $OutputDirectory 'coverage-summary.md')

Write-Host "`n$markdown"
Write-Host "Artifacts written to $OutputDirectory"
