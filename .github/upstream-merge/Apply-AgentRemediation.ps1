#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolkitDir,
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$BundleDir,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$OriginRemote = 'origin',
    [string]$VNextBranch = 'vnext',
    [string]$TargetBranch = 'merge-v10.6P1',
    [switch]$SkipFinalCI
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$needsHuman = $false
$ciStatus = 'skipped'
$dependenciesReady = $false

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Host "[$((Get-Date).ToString('u'))] [$Level] $Message"
}

function Set-StepOutput {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_OUTPUT) {
        "$Name=$Value" | Add-Content -Path $env:GITHUB_OUTPUT
    }
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    $output = @(& git @GitArgs 2>&1)
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host "    $_" }
    [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join "`n") }
}

function Assert-Git {
    param([Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
    $result = Invoke-Git @GitArgs
    if ($result.ExitCode -ne 0) {
        throw "git $($GitArgs -join ' ') failed: $($result.Output)"
    }
}

function Add-Report {
    param([string]$Text)
    Add-Content -Path $ReportPath -Value $Text
}

function Mark-NeedsHuman {
    param([string]$Reason)
    $script:needsHuman = $true
    Write-Log $Reason 'ERROR'
    Add-Report ""
    Add-Report "## Agentic remediation: NEEDS HUMAN"
    Add-Report ""
    Add-Report $Reason
}

function Initialize-BuildDependencies {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Architecture
    )

    if ($script:dependenciesReady) {
        return
    }

    $installScript = Join-Path $ToolkitDir 'tools\Install-VcpkgDependencies.ps1'
    $installParams = @{
        Architecture = @($Architecture)
        RepositoryRoot = $RepositoryRoot
        Bootstrap = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        $installParams.BinaryCache = Join-Path $env:RUNNER_TEMP 'vcpkg-binary-cache'
    }
    $installResult = & $installScript @installParams
    if (-not $installResult.Success) {
        $details = @($installResult.Errors) -join "`n"
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = [string]$installResult.Message
        }
        throw "vcpkg dependency installation failed.`n$details"
    }
    $script:dependenciesReady = $true
}

function Invoke-ValidatedBuild {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Architecture
    )

    Initialize-BuildDependencies -RepositoryRoot $RepositoryRoot -Architecture $Architecture

    $buildScript = Join-Path $ToolkitDir 'tools\Start-OpenSSHBuild.ps1'
    $buildResult = & $buildScript -Configuration Release -Architecture $Architecture `
        -RepositoryRoot $RepositoryRoot
    $analysisScript = Join-Path $ToolkitDir 'tools\Test-OpenSSHBuild.ps1'
    $analysisResult = & $analysisScript -Configuration Release -Architecture $Architecture `
        -RepositoryRoot $RepositoryRoot -LogFile $buildResult.LogFile

    if (-not $buildResult.Success -or -not $analysisResult.Success) {
        $errors = @($analysisResult.Errors | Select-Object -First 30 | ForEach-Object { $_.RawLine })
        $details = if ($errors.Count -gt 0) { $errors -join "`n" } else { [string]$buildResult.Message }
        throw "Release/$Architecture build failed after applying remediation.`n$details`nBuild log: $($buildResult.LogFile)"
    }
}

if (-not (Test-Path $ReportPath)) {
    Set-Content -Path $ReportPath -Value "## Weekly upstream merge run`n" -Encoding utf8
}

try {
    if (-not (Test-Path $RequestPath)) {
        throw "Preparation did not produce remediation-request.json."
    }
    if (-not (Test-Path (Join-Path $BundleDir 'result.json'))) {
        throw "The agent did not produce result.json."
    }

    $request = Get-Content -Raw $RequestPath | ConvertFrom-Json
    $result = Get-Content -Raw (Join-Path $BundleDir 'result.json') | ConvertFrom-Json
    if ($request.schemaVersion -ne 1 -or $result.schemaVersion -ne 1) {
        throw "Unsupported remediation bundle schema."
    }
    if ($result.status -ne 'resolved') {
        throw "Agent reported '$($result.status)': $($result.summary)"
    }
    foreach ($name in 'mode', 'expectedHead', 'batchEnd') {
        if ($result.$name -ne $request.$name) {
            throw "Remediation $name does not match the preparation request."
        }
    }

    if (-not (& git config user.email)) {
        & git config user.email 'openssh-merge-bot@users.noreply.github.com'
        & git config user.name 'OpenSSH Upstream Merge Bot'
    }

    $upstreamRemote = 'upstream'
    & git remote get-url $upstreamRemote 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Assert-Git remote set-url $upstreamRemote $request.upstreamUrl
    } else {
        Assert-Git remote add $upstreamRemote $request.upstreamUrl
    }
    Assert-Git fetch $upstreamRemote '--prune' '--tags'

    Assert-Git fetch $OriginRemote '--prune' $VNextBranch
    Assert-Git checkout -B $VNextBranch "$OriginRemote/$VNextBranch"
    $actualHead = (& git rev-parse HEAD).Trim()
    if ($actualHead -ne $request.expectedHead) {
        throw "vnext moved: expected $($request.expectedHead), found $actualHead."
    }

    if ($request.mode -eq 'conflicts') {
        Invoke-Git merge '--no-ff' '--no-edit' $request.batchEnd | Out-Null
        $currentConflicts = @(& git diff --name-only --diff-filter=U)
        $expectedConflicts = @($request.conflictedFiles | Sort-Object)
        if (Compare-Object $expectedConflicts ($currentConflicts | Sort-Object)) {
            Invoke-Git merge --abort | Out-Null
            throw "The recreated conflict set differs from the request."
        }

        $resolvedPath = Join-Path $BundleDir 'resolved-files.json'
        if (-not (Test-Path $resolvedPath)) {
            Invoke-Git merge --abort | Out-Null
            throw "Conflict remediation did not include resolved-files.json."
        }
        $resolved = Get-Content -Raw $resolvedPath | ConvertFrom-Json
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $resolved.files) {
            $relative = [string]$entry.path
            if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
                throw "Unsafe remediation path: $relative"
            }
            if ($expectedConflicts -notcontains $relative -or -not $seen.Add($relative)) {
                throw "Unexpected or duplicate resolved file: $relative"
            }
            if ($entry.action -eq 'delete') {
                Remove-Item -LiteralPath $relative -Force -ErrorAction SilentlyContinue
                Assert-Git add '--all' '--' $relative
            } elseif ($entry.action -eq 'write') {
                $bytes = [Convert]::FromBase64String([string]$entry.contentBase64)
                $parent = Split-Path -Parent $relative
                if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                [IO.File]::WriteAllBytes((Join-Path (Get-Location) $relative), $bytes)
                Assert-Git add '--' $relative
            } else {
                throw "Unsupported action '$($entry.action)' for $relative."
            }
        }
        if ($seen.Count -ne $expectedConflicts.Count -or @(& git diff --name-only --diff-filter=U).Count -ne 0) {
            throw "The remediation bundle did not resolve every expected conflict."
        }
        Assert-Git commit '--no-edit'
    } elseif ($request.mode -eq 'build') {
        $patchPath = Join-Path $BundleDir 'remediation.patch'
        if (-not (Test-Path $patchPath) -or (Get-Item $patchPath).Length -eq 0) {
            throw "Build remediation did not include a non-empty remediation.patch."
        }
        Assert-Git apply '--index' '--whitespace=error-all' $patchPath
        & git checkout -- 'contrib/win32/openssh/paths.targets' 2>$null
        Assert-Git commit -m "CI: build fixes for upstream batch $($request.batch)"
    } else {
        throw "Unsupported remediation mode '$($request.mode)'."
    }

    $repositoryRoot = (& git rev-parse --show-toplevel).Trim()
    Invoke-ValidatedBuild -RepositoryRoot $repositoryRoot -Architecture $request.architecture

    Assert-Git push $OriginRemote "${VNextBranch}:${VNextBranch}"
    Add-Report ""
    Add-Report "## Agentic remediation: validated"
    Add-Report ""
    Add-Report "- Mode: ``$($request.mode)``"
    Add-Report "- Batch: $($request.batch)"
    Add-Report "- Result: $($result.summary)"
    $decisionLog = Join-Path $BundleDir 'decision-log.md'
    if (Test-Path $decisionLog) {
        Add-Report ""
        Add-Report (Get-Content -Raw $decisionLog)
    }

    if (-not $SkipFinalCI) {
        $testScript = Join-Path $ToolkitDir 'tools\Invoke-OpenSSHTests.ps1'
        $ciResult = & $testScript -Configuration Release -Architecture $request.architecture `
            -RepositoryRoot $repositoryRoot
        if ($ciResult.Success) {
            $ciStatus = 'passed'
            Add-Report "## Full CI: passed"
        } else {
            $ciStatus = 'failed'
            Mark-NeedsHuman "Full CI failed after the remediation was applied."
        }
    }
} catch {
    Mark-NeedsHuman $_.Exception.Message
    if (Test-Path .git\MERGE_HEAD) {
        Invoke-Git merge --abort | Out-Null
    }
}

Set-StepOutput needs_human ($(if ($needsHuman) { 'true' } else { 'false' }))
Set-StepOutput ci_status $ciStatus
Set-StepOutput vnext_branch $VNextBranch
Set-StepOutput target_branch $TargetBranch
Set-StepOutput report_path $ReportPath

if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value (Get-Content -Raw $ReportPath)
}

if ($needsHuman) { exit 2 }
