<#
.SYNOPSIS
    MCP tool to test OpenSSH build artifacts and parse build errors.

.DESCRIPTION
    This script tests that all expected OpenSSH executables were built successfully
    and parses the build log file for any compilation or linker errors using regex patterns.

    Expected artifacts (14 executables):
    - ssh.exe, sshd.exe, sshd-auth.exe, sshd-session.exe
    - ssh-agent.exe, ssh-add.exe, ssh-keygen.exe, ssh-keyscan.exe
    - scp.exe, sftp.exe, sftp-server.exe
    - ssh-pkcs11-helper.exe, ssh-shellhost.exe, ssh-sk-helper.exe

.PARAMETER Configuration
    Build configuration type that was used. Valid values: 'Debug', 'Release'
    Default: 'Release'

.PARAMETER Architecture
    Target architecture that was built. Valid values: 'x64', 'x86', 'ARM', 'ARM64'
    Default: 'x64'

.PARAMETER LogFile
    Optional path to the build log file. If not specified, uses default pattern:
    OpenSSH{Configuration}{Architecture}.log in repository root.

.OUTPUTS
    Returns a hashtable with:
    - Success: Boolean indicating if all artifacts present and no errors
    - ArtifactsFound: Array of executables that exist
    - ArtifactsMissing: Array of expected executables that are missing
    - TotalArtifacts: Count of artifacts found
    - ExpectedArtifacts: Count of artifacts expected (14)
    - Errors: Array of parsed error objects with file, line, code, message
    - Warnings: Array of parsed warning objects
    - LogFile: Path to log file analyzed
    - Message: Summary message

.EXAMPLE
    .\Test-OpenSSHBuild.ps1 -Configuration Release -Architecture x64

    Tests release build artifacts for x64 architecture.

.EXAMPLE
    .\Test-OpenSSHBuild.ps1 -Configuration Debug -Architecture x86 -LogFile "C:\build\custom.log"

    Tests debug build artifacts for x86 using a custom log file location.

.NOTES
    - Expected build artifact location: contrib\win32\openssh\{Architecture}\{Configuration}\
    - Error parsing regex: ^(?<file>.*?)\((?<line>\d+)[,)].*?error (?<code>(C|LNK)\d+): (?<message>.*)$
    - Warning parsing regex: ^(?<file>.*?)\((?<line>\d+)[,)].*?warning (?<code>(C|LNK)\d+): (?<message>.*)$
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [Parameter(Mandatory=$false)]
    [ValidateSet('x64', 'x86', 'ARM', 'ARM64')]
    [string]$Architecture = 'x64',

    [Parameter(Mandatory=$false)]
    [string]$LogFile
)

# Determine repository root (go up from .github\tools to repo root)
$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptRoot)

# Define expected artifacts (14 executables)
$expectedArtifacts = @(
    "ssh.exe",
    "sshd.exe",
    "sshd-auth.exe",
    "sshd-session.exe",
    "ssh-agent.exe",
    "ssh-add.exe",
    "ssh-keygen.exe",
    "ssh-keyscan.exe",
    "scp.exe",
    "sftp.exe",
    "sftp-server.exe",
    "ssh-pkcs11-helper.exe",
    "ssh-shellhost.exe",
    "ssh-sk-helper.exe"
)

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "OpenSSH Build Test Tool (MCP)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Configuration: $Configuration" -ForegroundColor White
    Write-Host "Architecture:  $Architecture" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Cyan

    # Define build output path
    $buildPath = Join-Path $repoRoot "contrib\win32\openssh\$Architecture\$Configuration"

    if (-not (Test-Path $buildPath)) {
        Write-Host "Build path does not exist: $buildPath" -ForegroundColor Red

        $result = @{
            Success = $false
            ArtifactsFound = @()
            ArtifactsMissing = $expectedArtifacts
            TotalArtifacts = 0
            ExpectedArtifacts = $expectedArtifacts.Count
            Errors = @()
            Warnings = @()
            LogFile = $LogFile
            Message = "Build path does not exist: $buildPath"
        }

        return $result
    }

    Write-Host "Build path: $buildPath" -ForegroundColor Gray

    # Check for artifacts
    Write-Host "`nChecking for expected artifacts..." -ForegroundColor Cyan

    $artifactsFound = @()
    $artifactsMissing = @()

    foreach ($artifact in $expectedArtifacts) {
        $artifactPath = Join-Path $buildPath $artifact
        if (Test-Path $artifactPath) {
            $artifactsFound += $artifact
            Write-Host "  ✓ $artifact" -ForegroundColor Green
        } else {
            $artifactsMissing += $artifact
            Write-Host "  ✗ $artifact (MISSING)" -ForegroundColor Red
        }
    }

    Write-Host "`nArtifacts: $($artifactsFound.Count) of $($expectedArtifacts.Count) found" -ForegroundColor $(if ($artifactsMissing.Count -eq 0) { "Green" } else { "Yellow" })

    # Parse build log if available
    $errors = @()
    $warnings = @()

    if (-not $LogFile) {
        $LogFile = Join-Path $repoRoot "OpenSSH$Configuration$Architecture.log"
    }

    if (Test-Path $LogFile) {
        Write-Host "`nParsing build log: $LogFile" -ForegroundColor Cyan

        $logContent = Get-Content $LogFile -ErrorAction SilentlyContinue

        if ($logContent) {
            # Error regex: file(line) : error CODE: message
            # Example: c:\path\file.c(123): error C2065: 'identifier' : undeclared identifier
            $errorRegex = '^(?<file>.*?)\((?<line>\d+)[,)].*?error (?<code>(C|LNK)\d+): (?<message>.*)$'

            # Warning regex: similar pattern for warnings
            $warningRegex = '^(?<file>.*?)\((?<line>\d+)[,)].*?warning (?<code>(C|LNK)\d+): (?<message>.*)$'

            foreach ($line in $logContent) {
                # Check for errors
                if ($line -match $errorRegex) {
                    $errors += [PSCustomObject]@{
                        File = $matches['file']
                        Line = [int]$matches['line']
                        Code = $matches['code']
                        Message = $matches['message']
                        RawLine = $line
                    }
                }
                # Check for warnings
                elseif ($line -match $warningRegex) {
                    $warnings += [PSCustomObject]@{
                        File = $matches['file']
                        Line = [int]$matches['line']
                        Code = $matches['code']
                        Message = $matches['message']
                        RawLine = $line
                    }
                }
            }

            if ($errors.Count -gt 0) {
                Write-Host "`nFound $($errors.Count) error(s) in build log:" -ForegroundColor Red
                foreach ($e in $errors) {
                    Write-Host "  $($e.File)($($e.Line)): error $($e.Code): $($e.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host "`n✓ No errors found in build log" -ForegroundColor Green
            }

            if ($warnings.Count -gt 0) {
                Write-Host "`nFound $($warnings.Count) warning(s) in build log:" -ForegroundColor Yellow
                foreach ($warning in $warnings | Select-Object -First 10) {
                    Write-Host "  $($warning.File)($($warning.Line)): warning $($warning.Code): $($warning.Message)" -ForegroundColor Yellow
                }
                if ($warnings.Count -gt 10) {
                    Write-Host "  ... and $($warnings.Count - 10) more warnings" -ForegroundColor Gray
                }
            }
        } else {
            Write-Host "Log file is empty or could not be read" -ForegroundColor Yellow
        }
    } else {
        Write-Host "`nBuild log not found: $LogFile" -ForegroundColor Yellow
    }

    # Determine overall success
    $success = ($artifactsMissing.Count -eq 0) -and ($errors.Count -eq 0)

    # Build summary message
    if ($success) {
        $message = "All $($expectedArtifacts.Count) artifacts built successfully with no errors"
    } elseif ($artifactsMissing.Count -gt 0 -and $errors.Count -gt 0) {
        $message = "$($artifactsMissing.Count) artifacts missing and $($errors.Count) error(s) found"
    } elseif ($artifactsMissing.Count -gt 0) {
        $message = "$($artifactsMissing.Count) artifacts missing"
    } else {
        $message = "$($errors.Count) error(s) found in build log"
    }

    Write-Host "`n========================================" -ForegroundColor $(if ($success) { "Green" } else { "Red" })
    Write-Host $(if ($success) { "TEST PASSED" } else { "TEST FAILED" }) -ForegroundColor $(if ($success) { "Green" } else { "Red" })
    Write-Host "========================================" -ForegroundColor $(if ($success) { "Green" } else { "Red" })
    Write-Host $message -ForegroundColor White

    $result = @{
        Success = $success
        ArtifactsFound = $artifactsFound
        ArtifactsMissing = $artifactsMissing
        TotalArtifacts = $artifactsFound.Count
        ExpectedArtifacts = $expectedArtifacts.Count
        Errors = $errors
        Warnings = $warnings
        LogFile = $LogFile
        Message = $message
    }

    return $result

} catch {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "ERROR" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray

    $result = @{
        Success = $false
        ArtifactsFound = @()
        ArtifactsMissing = $expectedArtifacts
        TotalArtifacts = 0
        ExpectedArtifacts = $expectedArtifacts.Count
        Errors = @()
        Warnings = @()
        LogFile = $LogFile
        Message = "Test tool error: $($_.Exception.Message)"
    }

    return $result
}
