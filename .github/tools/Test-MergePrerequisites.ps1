<#
.SYNOPSIS
    MCP tool that verifies all prerequisites for starting an OpenSSH upstream merge.

.DESCRIPTION
    This script performs comprehensive pre-merge setup verification for the OpenSSH
    upstream merge workflow. It checks:
    - Required tools (Git, PowerShell, Visual Studio)
    - Repository configuration (remotes, branch state)
    - Baseline build capability
    - Target version identification
    
    This tool should be run before starting Phase 1 of the merge workflow to ensure
    all prerequisites are met. It prevents wasted effort by catching configuration
    issues early.

.PARAMETER TargetVersion
    The upstream version/tag to merge (e.g., "V_10_0_P2", "V_9_9_P1")
    This can be a tag name or branch name from the upstream repository.

.PARAMETER SkipBaselineBuild
    Skip the baseline build verification step. Use this if you've already
    verified the base branch builds successfully.
    Default: false (baseline build is performed)

.OUTPUTS
    Returns a hashtable with:
    - Success: Boolean indicating all prerequisites passed
    - GitInstalled: Boolean - Git is available
    - PowerShellVersion: String - PowerShell version
    - VSInstalled: Boolean - Visual Studio is available
    - RemotesConfigured: Boolean - All required remotes configured
    - TargetExists: Boolean - Target version/tag exists in upstream
    - WorkingDirClean: Boolean - No uncommitted changes
    - BaselineBuildPassed: Boolean - Base branch builds successfully (if not skipped)
    - FirstChunkIdentified: Boolean - First commit batch identified
    - FirstChunk: Object - First commit batch details from Get-CommitGroups
    - Issues: Array - List of any issues found
    - Message: String - Summary message

.EXAMPLE
    .\Test-MergePrerequisites.ps1 -TargetVersion "V_10_0_P2"

    Verifies all prerequisites for merging upstream V_10_0_P2.

.EXAMPLE
    .\Test-MergePrerequisites.ps1 -TargetVersion "V_10_0_P2" -SkipBaselineBuild

    Verifies prerequisites but skips the baseline build check.

.NOTES
    - This is a Phase 1 Pre-Merge Setup verification tool
    - Should be run before creating the merge branch
    - Requires approximately 2-5 minutes to complete (depending on baseline build)
    - Part of the OpenSSH upstream merge workflow automation
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetVersion,

    [Parameter(Mandatory=$false)]
    [switch]$SkipBaselineBuild
)

$scriptRoot = $PSScriptRoot
$repoRoot = (Get-Item $scriptRoot).Parent.Parent.FullName

$result = @{
    Success = $false
    GitInstalled = $false
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    VSInstalled = $false
    RemotesConfigured = $false
    TargetExists = $false
    WorkingDirClean = $false
    BaselineBuildPassed = $null  # null if skipped
    Issues = @()
    Message = ""
}

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "OpenSSH Merge Prerequisites Check" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Target Version: $TargetVersion" -ForegroundColor White
    Write-Host "Skip Baseline:  $SkipBaselineBuild" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Cyan

    # Change to repository root
    Push-Location $repoRoot

    # Step 1: Verify Git
    Write-Host "[1/8] Checking Git installation..." -ForegroundColor Cyan
    try {
        $gitVersion = git --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $result.GitInstalled = $true
            Write-Host "  ✓ Git installed: $gitVersion" -ForegroundColor Green
        } else {
            $result.Issues += "Git is not installed or not in PATH"
            Write-Host "  ✗ Git not found" -ForegroundColor Red
        }
    } catch {
        $result.Issues += "Git is not installed or not in PATH"
        Write-Host "  ✗ Git not found" -ForegroundColor Red
    }

    # Step 2: Verify PowerShell version
    Write-Host "`n[2/8] Checking PowerShell version..." -ForegroundColor Cyan
    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -ge 5) {
        Write-Host "  ✓ PowerShell $($psVersion.ToString()) (>= 5.0)" -ForegroundColor Green
    } else {
        $result.Issues += "PowerShell version $($psVersion.ToString()) is too old (need >= 5.0)"
        Write-Host "  ✗ PowerShell $($psVersion.ToString()) is too old (need >= 5.0)" -ForegroundColor Red
    }

    # Step 3: Verify Visual Studio
    Write-Host "`n[3/8] Checking Visual Studio installation..." -ForegroundColor Cyan
    $msBuildPaths = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\*\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2019\*\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\*\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\*\MSBuild\Current\Bin\MSBuild.exe"
    )

    $msBuildFound = $false
    foreach ($path in $msBuildPaths) {
        $resolved = Resolve-Path $path -ErrorAction SilentlyContinue
        if ($resolved) {
            $msBuildFound = $true
            $result.VSInstalled = $true
            Write-Host "  ✓ Visual Studio found: $($resolved.Path)" -ForegroundColor Green
            break
        }
    }

    if (-not $msBuildFound) {
        $result.Issues += "Visual Studio 2019 or later not found"
        Write-Host "  ✗ Visual Studio 2019 or later not found" -ForegroundColor Red
    }

    # Step 4: Verify repository remotes
    Write-Host "`n[4/8] Checking repository remotes..." -ForegroundColor Cyan
    if ($result.GitInstalled) {
        $remotes = git remote 2>&1
        $expectedRemotes = @('origin', 'upstream', 'upstream-pwsh')
        $missingRemotes = @()

        foreach ($remote in $expectedRemotes) {
            if ($remotes -contains $remote) {
                $remoteUrl = git remote get-url $remote 2>&1
                Write-Host "  ✓ $remote configured: $remoteUrl" -ForegroundColor Green
            } else {
                $missingRemotes += $remote
                Write-Host "  ✗ $remote not configured" -ForegroundColor Red
            }
        }

        if ($missingRemotes.Count -eq 0) {
            $result.RemotesConfigured = $true
        } else {
            $result.Issues += "Missing remotes: $($missingRemotes -join ', ')"
        }
    } else {
        Write-Host "  ⊘ Skipped (Git not available)" -ForegroundColor Yellow
    }

    # Step 5: Verify target version exists
    Write-Host "`n[5/7] Checking target version exists..." -ForegroundColor Cyan
    if ($result.GitInstalled -and $result.RemotesConfigured) {
        Write-Host "  Fetching from upstream..." -ForegroundColor Gray
        git fetch upstream --tags 2>&1 | Out-Null

        # Check if it's a tag first, then try as a branch
        $tagExists = git rev-parse "$TargetVersion" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $result.TargetExists = $true
            Write-Host "  ✓ Target tag exists: $TargetVersion" -ForegroundColor Green
        } else {
            # Try as a branch
            $branchExists = git rev-parse "upstream/$TargetVersion" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $result.TargetExists = $true
                Write-Host "  ✓ Target branch exists: upstream/$TargetVersion" -ForegroundColor Green
            } else {
                $result.Issues += "Target version/tag '$TargetVersion' not found in upstream"
                Write-Host "  ✗ Target '$TargetVersion' not found" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "  ⊘ Skipped (prerequisites not met)" -ForegroundColor Yellow
    }

    # Step 6: Verify working directory is clean
    Write-Host "`n[6/7] Checking working directory state..." -ForegroundColor Cyan
    if ($result.GitInstalled) {
        $status = git status --porcelain 2>&1
        if ([string]::IsNullOrWhiteSpace($status)) {
            $result.WorkingDirClean = $true
            Write-Host "  ✓ Working directory is clean" -ForegroundColor Green
        } else {
            $result.Issues += "Working directory has uncommitted changes"
            Write-Host "  ✗ Working directory has uncommitted changes" -ForegroundColor Red
            Write-Host "    Run 'git status' to see changes" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⊘ Skipped (Git not available)" -ForegroundColor Yellow
    }

    # Step 7: Baseline build verification
    Write-Host "`n[7/7] Verifying baseline build..." -ForegroundColor Cyan
    if ($SkipBaselineBuild) {
        Write-Host "  ⊘ Skipped (SkipBaselineBuild flag set)" -ForegroundColor Yellow
    } else {
        $currentBranch = git rev-parse --abbrev-ref HEAD 2>&1
        Write-Host "  Current branch: $currentBranch" -ForegroundColor Gray
        Write-Host "  Starting baseline build..." -ForegroundColor Gray

        $buildScriptPath = Join-Path $scriptRoot "Build-OpenSSH.ps1"
        $buildResult = & $buildScriptPath -Configuration Release -Architecture x64

        if ($buildResult.OverallSuccess) {
            $result.BaselineBuildPassed = $true
            Write-Host "  ✓ Baseline build passed" -ForegroundColor Green
            Write-Host "    All $($buildResult.ExpectedArtifacts) artifacts built successfully" -ForegroundColor Gray
        } else {
            $result.BaselineBuildPassed = $false
            $result.Issues += "Baseline build failed: $($buildResult.Message)"
            Write-Host "  ✗ Baseline build failed" -ForegroundColor Red
            Write-Host "    $($buildResult.Message)" -ForegroundColor Yellow
            Write-Host "    Check build log: $($buildResult.LogFile)" -ForegroundColor Yellow
        }
    }

    # Final evaluation
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "PREREQUISITE CHECK SUMMARY" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $criticalChecks = @(
        $result.GitInstalled,
        $result.VSInstalled,
        $result.RemotesConfigured,
        $result.TargetExists,
        $result.WorkingDirClean
    )

    # Baseline build is critical unless skipped
    if (-not $SkipBaselineBuild) {
        $criticalChecks += $result.BaselineBuildPassed
    }

    $result.Success = ($criticalChecks | Where-Object { $_ -eq $false }).Count -eq 0

    if ($result.Success) {
        Write-Host "✓ ALL PREREQUISITES MET" -ForegroundColor Green
        Write-Host "`nYou are ready to begin the merge process:" -ForegroundColor White
        Write-Host "  1. Create merge branch: git checkout -b merge-$TargetVersion-$(Get-Date -Format 'yyyyMMdd')" -ForegroundColor Gray
        Write-Host "  2. Use Get-CommitGroups tool to identify first batch of commits" -ForegroundColor Gray
        Write-Host "  3. Begin cherry-picking commits from first batch" -ForegroundColor Gray
        
        $result.Message = "All prerequisites met. Ready to start merge."
    } else {
        Write-Host "✗ PREREQUISITES NOT MET" -ForegroundColor Red
        Write-Host "`nIssues found:" -ForegroundColor Yellow
        foreach ($issue in $result.Issues) {
            Write-Host "  • $issue" -ForegroundColor Red
        }
        $result.Message = "$($result.Issues.Count) issue(s) found. Fix issues before starting merge."
    }

    Write-Host ""

    return $result

} catch {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "ERROR" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray

    $result.Success = $false
    $result.Issues += "Tool error: $($_.Exception.Message)"
    $result.Message = "Prerequisite check failed with error: $($_.Exception.Message)"

    return $result
} finally {
    Pop-Location
}
