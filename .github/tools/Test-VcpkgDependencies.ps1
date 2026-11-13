<#
.SYNOPSIS
    Verifies the vcpkg artifacts consumed by the Win32-OpenSSH build.

.DESCRIPTION
    Confirms that the nested triplet layout produced for the Visual Studio
    build contains the LibreSSL header, import library, and runtime DLL.
    When an artifact is missing, candidate paths below vcpkg_installed are
    included to diagnose an unexpected installation layout.

.PARAMETER Architecture
    Build architecture whose `<arch>-custom` triplet should be validated.

.PARAMETER RepositoryRoot
    Repository root containing contrib/win32/openssh/vcpkg_installed.

.OUTPUTS
    A PSCustomObject with Success, Triplet, ExpectedRoot, Files,
    MissingFiles, CandidatePaths, and Diagnostic.
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('x64', 'x86', 'ARM', 'ARM64')]
    [string]$Architecture = 'x64',

    [Parameter(Mandatory=$false)]
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $repoRoot = (Get-Item $scriptRoot).Parent.Parent.FullName
} else {
    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
        throw "RepositoryRoot does not exist: $RepositoryRoot"
    }
    $repoRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
}

$triplet = "$($Architecture.ToLowerInvariant())-custom"
$installedDir = Join-Path $repoRoot 'contrib\win32\openssh\vcpkg_installed'
$expectedRoot = Join-Path $installedDir "$triplet\$triplet"
$requirements = @(
    @{ RelativePath = 'include\openssl\opensslv.h'; Name = 'opensslv.h' },
    @{ RelativePath = 'lib\libcrypto.lib'; Name = 'libcrypto.lib' },
    @{ RelativePath = 'bin\libcrypto.dll'; Name = 'libcrypto.dll' }
)

$files = [System.Collections.Generic.List[object]]::new()
$missing = [System.Collections.Generic.List[string]]::new()
foreach ($requirement in $requirements) {
    $path = Join-Path $expectedRoot $requirement.RelativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $item = Get-Item -LiteralPath $path
        $files.Add([pscustomobject]@{
            RelativePath = $requirement.RelativePath
            Path = $item.FullName
            Exists = $true
            Length = $item.Length
            LastWriteTimeUtc = $item.LastWriteTimeUtc
        })
    } else {
        $missing.Add($requirement.RelativePath)
        $files.Add([pscustomobject]@{
            RelativePath = $requirement.RelativePath
            Path = $path
            Exists = $false
            Length = $null
            LastWriteTimeUtc = $null
        })
    }
}

$candidates = [System.Collections.Generic.List[string]]::new()
if ($missing.Count -gt 0 -and (Test-Path -LiteralPath $installedDir -PathType Container)) {
    $missingNames = @($requirements |
        Where-Object { $missing -contains $_.RelativePath } |
        ForEach-Object { $_.Name } |
        Select-Object -Unique)
    foreach ($candidate in Get-ChildItem -LiteralPath $installedDir -Recurse -File -ErrorAction SilentlyContinue) {
        if ($missingNames -contains $candidate.Name) {
            $candidates.Add($candidate.FullName)
        }
    }
}

$success = $missing.Count -eq 0
$diagnosticLines = [System.Collections.Generic.List[string]]::new()
if ($success) {
    $diagnosticLines.Add("Verified vcpkg dependencies at $expectedRoot.")
    foreach ($file in $files) {
        $diagnosticLines.Add("$($file.RelativePath): $($file.Length) bytes, modified $($file.LastWriteTimeUtc.ToString('o')).")
    }
} else {
    $diagnosticLines.Add("Required vcpkg dependencies are missing from $expectedRoot.")
    foreach ($relativePath in $missing) {
        $diagnosticLines.Add("Missing: $relativePath")
    }
    if ($candidates.Count -gt 0) {
        $diagnosticLines.Add('Candidate paths found under vcpkg_installed:')
        foreach ($candidate in $candidates) {
            $diagnosticLines.Add($candidate)
        }
    } else {
        $diagnosticLines.Add('No candidate paths were found under vcpkg_installed.')
    }
}

[pscustomobject]@{
    Success = $success
    Triplet = $triplet
    ExpectedRoot = $expectedRoot
    Files = @($files)
    MissingFiles = @($missing)
    CandidatePaths = @($candidates)
    Diagnostic = $diagnosticLines -join "`n"
}
