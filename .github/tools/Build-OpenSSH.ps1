<#
.SYNOPSIS
    MCP wrapper tool that builds and verifies OpenSSH in a single operation.

.DESCRIPTION
    This script combines Start-OpenSSHBuild and Test-OpenSSHBuild into a single
    convenient operation. It first builds OpenSSH using the specified configuration
    and architecture, then tests that all expected artifacts were produced and
    parses the build log for errors.

    This is the recommended tool for most build operations as it provides
    comprehensive feedback in one step.

.PARAMETER Configuration
    Build configuration type. Valid values: 'Debug', 'Release'
    Default: 'Release'

.PARAMETER Architecture
    Target architecture for the build. Valid values: 'x64', 'x86', 'ARM', 'ARM64'
    Default: 'x64'

.PARAMETER Clean
    When specified, performs a clean build by deleting existing build artifacts first.
    Default: false (incremental build)

.PARAMETER NoOpenSSL
    Build without OpenSSL support.
    Default: false

.PARAMETER OneCore
    Build for Windows OneCore API subset.
    Default: false

.OUTPUTS
    Returns a consolidated hashtable with:
    - BuildSuccess: Boolean indicating if build succeeded
    - TestSuccess: Boolean indicating if test passed
    - OverallSuccess: Boolean indicating both build and test succeeded
    - BuildExitCode: MSBuild exit code
    - BuildMessage: Build status message
    - TotalArtifacts: Count of artifacts found
    - ExpectedArtifacts: Count of artifacts expected (14)
    - ArtifactsMissing: Array of missing artifacts
    - Errors: Array of parsed error objects
    - Warnings: Array of parsed warning objects
    - LogFile: Path to build log file
    - BuildPath: Path to build output directory
    - Message: Overall summary message

.EXAMPLE
    .\Build-OpenSSH.ps1 -Configuration Release -Architecture x64

    Performs an incremental release build for x64 and tests artifacts.

.EXAMPLE
    .\Build-OpenSSH.ps1 -Configuration Debug -Architecture x64 -Clean

    Performs a clean debug build for x64 and tests artifacts.

.EXAMPLE
    .\Build-OpenSSH.ps1 -Architecture ARM64 -OneCore

    Performs an incremental OneCore release build for ARM64 and tests artifacts.

.NOTES
    - This tool calls Start-OpenSSHBuild.ps1 and Test-OpenSSHBuild.ps1
    - Requires Visual Studio 2019 or later with C++ tools
    - Requires Windows SDK 10.0.17763.0 or later
    - Build artifacts output to: contrib\win32\openssh\{Architecture}\{Configuration}\
    - Build log written to: OpenSSH{Configuration}{Architecture}.log
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [Parameter(Mandatory=$false)]
    [ValidateSet('x64', 'x86', 'ARM', 'ARM64')]
    [string]$Architecture = 'x64',

    [Parameter(Mandatory=$false)]
    [switch]$Clean,

    [Parameter(Mandatory=$false)]
    [switch]$NoOpenSSL,

    [Parameter(Mandatory=$false)]
    [switch]$OneCore
)

$scriptRoot = $PSScriptRoot

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "OpenSSH Build & Test Tool (MCP)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Configuration: $Configuration" -ForegroundColor White
    Write-Host "Architecture:  $Architecture" -ForegroundColor White
    Write-Host "Clean Build:   $Clean" -ForegroundColor White
    Write-Host "No OpenSSL:    $NoOpenSSL" -ForegroundColor White
    Write-Host "OneCore:       $OneCore" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Cyan

    # Step 1: Build
    Write-Host "STEP 1: Building OpenSSH..." -ForegroundColor Cyan
    Write-Host "----------------------------------------`n" -ForegroundColor Cyan

    $buildParams = @{
        Configuration = $Configuration
        Architecture = $Architecture
    }

    if ($Clean) {
        $buildParams['Clean'] = $true
    }

    if ($NoOpenSSL) {
        $buildParams['NoOpenSSL'] = $true
    }

    if ($OneCore) {
        $buildParams['OneCore'] = $true
    }

    $buildScriptPath = Join-Path $scriptRoot "Start-OpenSSHBuild.ps1"
    $buildResult = & $buildScriptPath @buildParams

    if (-not $buildResult.Success) {
        Write-Host "`n⚠ Build failed, skipping test" -ForegroundColor Yellow

        # Return build result with test skipped
        $result = @{
            BuildSuccess = $false
            TestSuccess = $false
            OverallSuccess = $false
            BuildExitCode = $buildResult.ExitCode
            BuildMessage = $buildResult.Message
            TotalArtifacts = 0
            ExpectedArtifacts = 14
            ArtifactsMissing = @()
            Errors = @()
            Warnings = @()
            LogFile = $buildResult.LogFile
            BuildPath = $buildResult.BuildPath
            Message = "Build failed: $($buildResult.Message)"
        }

        return $result
    }

    # Step 2: Test
    Write-Host "`nSTEP 2: Testing Build Artifacts..." -ForegroundColor Cyan
    Write-Host "----------------------------------------`n" -ForegroundColor Cyan

    $testParams = @{
        Configuration = $Configuration
        Architecture = $Architecture
        LogFile = $buildResult.LogFile
    }

    $testScriptPath = Join-Path $scriptRoot "Test-OpenSSHBuild.ps1"
    $testResult = & $testScriptPath @testParams

    # Step 3: Consolidate results
    $overallSuccess = $buildResult.Success -and $testResult.Success

    Write-Host "`n========================================" -ForegroundColor $(if ($overallSuccess) { "Green" } else { "Red" })
    Write-Host "OVERALL RESULT: $(if ($overallSuccess) { 'SUCCESS' } else { 'FAILED' })" -ForegroundColor $(if ($overallSuccess) { "Green" } else { "Red" })
    Write-Host "========================================" -ForegroundColor $(if ($overallSuccess) { "Green" } else { "Red" })

    if ($overallSuccess) {
        Write-Host "✓ Build succeeded" -ForegroundColor Green
        Write-Host "✓ All $($testResult.ExpectedArtifacts) artifacts tested" -ForegroundColor Green
        Write-Host "✓ No errors found" -ForegroundColor Green
    } else {
        if (-not $buildResult.Success) {
            Write-Host "✗ Build failed with exit code $($buildResult.ExitCode)" -ForegroundColor Red
        }
        if ($testResult.ArtifactsMissing.Count -gt 0) {
            Write-Host "✗ $($testResult.ArtifactsMissing.Count) artifacts missing" -ForegroundColor Red
        }
        if ($testResult.Errors.Count -gt 0) {
            Write-Host "✗ $($testResult.Errors.Count) error(s) found" -ForegroundColor Red
        }
    }

    Write-Host "`nBuild artifacts: $($buildResult.BuildPath)" -ForegroundColor White
    Write-Host "Build log:       $($buildResult.LogFile)" -ForegroundColor White

    # Build consolidated message
    $messageParts = @()
    if ($buildResult.Success) {
        $messageParts += "Build succeeded"
    } else {
        $messageParts += "Build failed"
    }

    if ($testResult.Success) {
        $messageParts += "all artifacts tested"
    } else {
        if ($testResult.ArtifactsMissing.Count -gt 0) {
            $messageParts += "$($testResult.ArtifactsMissing.Count) artifacts missing"
        }
        if ($testResult.Errors.Count -gt 0) {
            $messageParts += "$($testResult.Errors.Count) errors"
        }
    }

    $consolidatedMessage = $messageParts -join ", "

    $result = @{
        BuildSuccess = $buildResult.Success
        TestSuccess = $testResult.Success
        OverallSuccess = $overallSuccess
        BuildExitCode = $buildResult.ExitCode
        BuildMessage = $buildResult.Message
        TotalArtifacts = $testResult.TotalArtifacts
        ExpectedArtifacts = $testResult.ExpectedArtifacts
        ArtifactsMissing = $testResult.ArtifactsMissing
        Errors = $testResult.Errors
        Warnings = $testResult.Warnings
        LogFile = $buildResult.LogFile
        BuildPath = $buildResult.BuildPath
        Message = $consolidatedMessage
    }

    return $result

} catch {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "ERROR" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray

    $result = @{
        BuildSuccess = $false
        TestSuccess = $false
        OverallSuccess = $false
        BuildExitCode = -1
        BuildMessage = "Tool error: $($_.Exception.Message)"
        TotalArtifacts = 0
        ExpectedArtifacts = 14
        ArtifactsMissing = @()
        Errors = @()
        Warnings = @()
        LogFile = ""
        BuildPath = ""
        Message = "Build & test tool error: $($_.Exception.Message)"
    }

    return $result
}
