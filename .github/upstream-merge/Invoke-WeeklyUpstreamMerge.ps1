#requires -Version 7.0
<#
.SYNOPSIS
    Autonomous, agent-assisted weekly merge of upstream OpenSSH commits into a
    long-lived `vnext` integration branch.

.DESCRIPTION
    This is the non-interactive (CI) driver for the merge process that is
    normally run by the `merge-upstream` VS Code Copilot Chat agent. It is
    designed to run headlessly inside GitHub Actions on a Windows runner.

    High level flow (one scheduled run):
      1. Fetch upstream + origin.
      2. Ensure the long-lived `vnext` branch exists (created off the target
         branch, e.g. latestw_all, on first run; reused thereafter).
      3. Repeatedly:
           a. Ask Get-CommitGroups for the next mergeable batch of upstream
              commits (CI-presence grouping) that is not yet on `vnext`.
           b. `git merge --no-ff` that batch's endpoint into `vnext`.
           c. If there are conflicts, invoke the merge agent (Copilot CLI) to
              resolve them, retrying up to -MaxAgentAttempts times. Every
              decision the agent makes is written to the run's decision log.
           d. Complete the merge commit.
           e. If the batch touched C sources/headers, build; if the build
              fails, invoke the agent to fix it (again capped at
              -MaxAgentAttempts). Commit any build fixes.
         ...until upstream is fully merged or -MaxBatchesPerRun is reached, or a
         step needs human help (conflicts/build still broken after the cap).
      4. If anything was merged and builds are green, run the FULL CI suite once.
      5. Push `vnext` and write a Markdown report (used as the PR body).

    The script NEVER merges `vnext` into the target branch and NEVER force-pushes
    anything. Its output is always reviewed by a human via the pull request the
    workflow opens/updates.

    Merging `vnext` -> target on an upstream release is intentionally a separate,
    manual process.

.NOTES
    The intelligent steps (conflict resolution, build-fix authoring) are
    delegated to the on-repo `merge-upstream` agent through the GitHub Copilot
    CLI. If the CLI is unavailable or -SkipAgent is set, those steps are skipped
    and the run is flagged as needing human attention instead of failing hard.
#>
[CmdletBinding()]
param(
    # Git remote pointing at openbsd/openssh upstream (openssh/openssh-portable).
    [string]$UpstreamRemote = 'upstream',

    # Upstream ref to merge UP TO. Defaults to the upstream default branch tip.
    [string]$UpstreamRef = '',

    # Long-lived branch changes are accumulated on, week over week.
    [string]$VNextBranch = 'vnext',

    # Branch vnext is created from on first run and that the review PR targets.
    [string]$TargetBranch = 'latestw_all',

    # origin remote (the fork we push vnext to).
    [string]$OriginRemote = 'origin',

    # Safety cap: how many batches to merge in a single scheduled run.
    [ValidateRange(1, 50)]
    [int]$MaxBatchesPerRun = 4,

    # How many times to let the agent retry a single failing step before we stop
    # and hand off to a human.
    [ValidateRange(1, 10)]
    [int]$MaxAgentAttempts = 3,

    # Build architecture for per-batch validation and the final CI run.
    [string]$Architecture = 'x64',

    # Directory holding a self-contained copy of the merge toolkit
    # (.github/tools scripts, agent + instruction files, and the autonomous
    # prompt). Staged by the workflow before any branch switching so the tools
    # survive checkouts of vnext.
    [Parameter(Mandatory)]
    [string]$ToolkitDir,

    # Where to write the Markdown run report (becomes the PR body).
    [string]$ReportPath = 'merge-report.md',

    # Skip the agentic steps entirely (deterministic dry-run / local testing).
    [switch]$SkipAgent,

    # Skip the final full CI suite (useful for fast local iteration).
    [switch]$SkipFinalCI
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

$script:Report = [System.Text.StringBuilder]::new()
$script:NeedsHuman = $false
$script:BatchesMerged = 0
$script:DecisionLog = Join-Path ([System.IO.Path]::GetTempPath()) "merge-decisions-$([guid]::NewGuid().ToString('N')).md"
Set-Content -Path $script:DecisionLog -Value "# Agent decision log`n" -Encoding utf8

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('u')
    Write-Host "[$ts] [$Level] $Message"
}

function Add-Report {
    param([string]$Text)
    [void]$script:Report.AppendLine($Text)
}

function Set-StepOutput {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_OUTPUT) {
        # Multi-line safe output using a random delimiter.
        $delim = "ghout_$([guid]::NewGuid().ToString('N'))"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name<<$delim`n$Value`n$delim"
    }
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)] [string[]]$GitArgs)
    Write-Log "git $($GitArgs -join ' ')" 'GIT'
    $out = & git @GitArgs 2>&1
    $code = $LASTEXITCODE
    if ($out) { $out | ForEach-Object { Write-Host "    $_" } }
    return [pscustomobject]@{ ExitCode = $code; Output = ($out -join "`n") }
}

function Assert-Git {
    param([Parameter(ValueFromRemainingArguments)] [string[]]$GitArgs)
    $r = Invoke-Git @GitArgs
    if ($r.ExitCode -ne 0) { throw "git $($GitArgs -join ' ') failed (exit $($r.ExitCode)): $($r.Output)" }
    return $r.Output
}

function Resolve-Sha {
    param([string]$Ref)
    return (Assert-Git rev-parse $Ref).Trim()
}

function Get-ToolPath {
    param([string]$Name)
    $p = Join-Path $ToolkitDir "tools\$Name"
    if (-not (Test-Path $p)) { throw "Required tool script not found in toolkit: $p" }
    return $p
}

function Test-CodeImpact {
    # Returns $true if any *.c or *.h changed in the given range.
    param([string]$Range)
    $files = (& git diff --name-only $Range 2>$null)
    foreach ($f in $files) {
        if ($f -match '\.(c|h)$') { return $true }
    }
    return $false
}

function Test-WorkingTreeDirty {
    $s = & git status --porcelain
    return -not [string]::IsNullOrWhiteSpace(($s -join ''))
}

function Test-ConflictsRemain {
    # True while unresolved conflicts are present (unmerged index entries or
    # leftover conflict markers detected by the repo's own checker).
    $unmerged = & git diff --name-only --diff-filter=U
    if (-not [string]::IsNullOrWhiteSpace(($unmerged -join ''))) { return $true }

    $marker = Get-ToolPath 'Test-MergeConflictMarkers.ps1'
    try {
        $res = & pwsh -NoProfile -File $marker -Path '.' 2>$null
        # The tool returns an object with .Success; treat parse failure as clean.
        if ($res -and ($res | Where-Object { $_.PSObject.Properties.Name -contains 'Success' })) {
            $obj = $res | Select-Object -Last 1
            return -not [bool]$obj.Success
        }
    } catch { Write-Log "conflict-marker check failed: $_" 'WARN' }
    return $false
}

function Invoke-MergeAgent {
    <#
        Delegates a focused, autonomous task to the merge-upstream agent via the
        GitHub Copilot CLI. Returns $true if the CLI ran, $false if unavailable
        or skipped. The caller re-checks repository state afterward to decide
        success.
    #>
    param(
        [Parameter(Mandatory)][string]$Task,   # short description for logging
        [Parameter(Mandatory)][string]$Prompt  # full instruction text
    )

    if ($SkipAgent) {
        Write-Log "Agent skipped (-SkipAgent) for task: $Task" 'WARN'
        return $false
    }

    $copilot = Get-Command copilot -ErrorAction SilentlyContinue
    if (-not $copilot) {
        Write-Log "GitHub Copilot CLI ('copilot') not found on PATH; cannot run agent for: $Task" 'WARN'
        return $false
    }

    Write-Log "Invoking merge agent for task: $Task"
    try {
        # Non-interactive, single programmatic turn. --allow-all-tools lets the
        # agent run git/build/test just as it would locally. The prompt itself
        # forbids pausing for human input.
        & $copilot.Source -p $Prompt `
            --allow-all-tools `
            --log-level error 2>&1 | ForEach-Object { Write-Host "    [agent] $_" }
        Write-Log "Agent turn finished for: $Task"
        return $true
    } catch {
        Write-Log "Agent invocation errored for '$Task': $_" 'WARN'
        return $false
    }
}

function Read-AgentPromptTemplate {
    $p = Join-Path $ToolkitDir 'merge-autonomous.prompt.md'
    if (-not (Test-Path $p)) { throw "Autonomous prompt template not found: $p" }
    return (Get-Content -Raw $p)
}

function Build-AgentPrompt {
    param(
        [string]$Mode,
        [int]$Attempt,
        [int]$Batch,
        [string]$Details
    )
    $t = Read-AgentPromptTemplate
    $t = $t.Replace('<<MODE>>', $Mode)
    $t = $t.Replace('<<ATTEMPT>>', "$Attempt of $MaxAgentAttempts")
    $t = $t.Replace('<<BATCH>>', "$Batch")
    $t = $t.Replace('<<DETAILS>>', $Details)
    $t = $t.Replace('<<DECISION_LOG>>', $script:DecisionLog)
    return $t
}

# --------------------------------------------------------------------------
# Setup
# --------------------------------------------------------------------------

Write-Log "Weekly upstream merge starting."
Write-Log "Upstream=$UpstreamRemote  Target=$TargetBranch  VNext=$VNextBranch  MaxBatches=$MaxBatchesPerRun  MaxAgentAttempts=$MaxAgentAttempts"

# Identity for merge/commit operations in CI.
if (-not (& git config user.email)) {
    & git config user.email 'openssh-merge-bot@users.noreply.github.com'
    & git config user.name  'OpenSSH Upstream Merge Bot'
}
& git config merge.conflictStyle diff3 | Out-Null

Assert-Git fetch $OriginRemote '--prune' | Out-Null
Assert-Git fetch $UpstreamRemote '--prune' '--tags' | Out-Null

# Resolve the upstream endpoint we are merging up to.
if ([string]::IsNullOrWhiteSpace($UpstreamRef)) {
    # Default: the upstream default branch tip.
    $UpstreamRef = "$UpstreamRemote/master"
    & git rev-parse --verify --quiet $UpstreamRef | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $UpstreamRef = (Assert-Git symbolic-ref "refs/remotes/$UpstreamRemote/HEAD").Trim() -replace '^refs/remotes/', ''
    }
}
$endSha = Resolve-Sha $UpstreamRef
Write-Log "Upstream endpoint: $UpstreamRef ($endSha)"

# Ensure vnext exists and is checked out, tracking origin/vnext if present.
$vnextRemote = "$OriginRemote/$VNextBranch"
& git rev-parse --verify --quiet $vnextRemote | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Log "Reusing existing $vnextRemote"
    Assert-Git checkout -B $VNextBranch $vnextRemote | Out-Null
} else {
    $base = "$OriginRemote/$TargetBranch"
    Write-Log "Creating new $VNextBranch from $base"
    Assert-Git checkout -B $VNextBranch $base | Out-Null
}

# --------------------------------------------------------------------------
# Batch merge loop
# --------------------------------------------------------------------------

$getGroups = Get-ToolPath 'Get-CommitGroups.ps1'

Add-Report "## Weekly upstream merge run"
Add-Report ""
Add-Report "- Upstream endpoint: ``$UpstreamRef`` (``$($endSha.Substring(0,12))``)"
Add-Report "- Target branch: ``$TargetBranch``"
Add-Report "- Integration branch: ``$VNextBranch``"
Add-Report ""

for ($i = 1; $i -le $MaxBatchesPerRun; $i++) {

    # Last upstream commit already on vnext = merge-base(vnext, upstreamRef).
    $startSha = (Assert-Git merge-base $VNextBranch $endSha).Trim()
    if ($startSha -eq $endSha) {
        Write-Log "vnext already contains upstream endpoint. Nothing left to merge."
        Add-Report "**Up to date** - no upstream commits remaining."
        break
    }

    Write-Log "[$i/$MaxBatchesPerRun] Selecting next batch from $($startSha.Substring(0,12))..$($endSha.Substring(0,12))"
    $chunk = $null
    try {
        $chunk = & pwsh -NoProfile -File $getGroups `
            -StartCommit $startSha -EndCommit $endSha -FirstChunkOnly -GroupByCIPresence |
            Select-Object -Last 1
    } catch {
        Write-Log "Get-CommitGroups failed: $_" 'ERROR'
        $script:NeedsHuman = $true
        Add-Report "> Could not determine the next batch (Get-CommitGroups failed): $_"
        break
    }

    if (-not $chunk -or -not $chunk.EndCommitFull) {
        Write-Log "No further batch returned; treating as caught up."
        break
    }

    $batchEnd = $chunk.EndCommitFull
    $rangeForImpact = "$startSha..$batchEnd"
    Write-Log "Batch #${i}: $($chunk.CommitCount) commits, ending at $($batchEnd.Substring(0,12)) - $($chunk.EndMessage)"

    Add-Report "### Batch $i - $($chunk.CommitCount) commit(s)"
    Add-Report ""
    Add-Report "- Range: ``$($startSha.Substring(0,12))`` -> ``$($batchEnd.Substring(0,12))``"
    Add-Report "- Endpoint message: $($chunk.EndMessage)"

    # ---- Merge ------------------------------------------------------------
    $merge = Invoke-Git merge '--no-ff' '--no-edit' $batchEnd
    $conflicted = ($merge.ExitCode -ne 0) -and (Test-ConflictsRemain)

    if ($conflicted) {
        Write-Log "Batch #$i produced conflicts; engaging agent."
        $resolved = $false
        for ($a = 1; $a -le $MaxAgentAttempts; $a++) {
            $files = (& git diff --name-only --diff-filter=U) -join "`n"
            $prompt = Build-AgentPrompt -Mode 'conflicts' -Attempt $a -Batch $i `
                -Details "Unresolved conflicted files:`n$files"
            [void](Invoke-MergeAgent -Task "resolve conflicts (attempt $a)" -Prompt $prompt)
            if (-not (Test-ConflictsRemain)) { $resolved = $true; break }
            Write-Log "Conflicts remain after attempt $a." 'WARN'
        }

        if (-not $resolved) {
            Write-Log "Conflicts unresolved after $MaxAgentAttempts attempts. Aborting batch and stopping." 'ERROR'
            Invoke-Git merge --abort | Out-Null
            $script:NeedsHuman = $true
            Add-Report "- Conflicts could not be resolved automatically after $MaxAgentAttempts attempts. **Human help needed.**"
            break
        }
        Add-Report "- Conflicts resolved by agent (see decision log)."
    }

    # Finalize the merge commit (works for both clean and resolved-conflict cases).
    if ((Test-WorkingTreeDirty) -or ($merge.ExitCode -ne 0)) {
        Assert-Git add -A | Out-Null
        # --no-edit keeps git's generated merge message with all upstream SHAs.
        Invoke-Git commit '--no-edit' | Out-Null
    }

    # ---- Build validation (only if compiled sources changed) --------------
    if (Test-CodeImpact $rangeForImpact) {
        Write-Log "Batch #$i touched C/H sources; building for validation."
        $buildScript = Get-ToolPath 'Start-OpenSSHBuild.ps1'
        $built = $false
        for ($a = 1; $a -le $MaxAgentAttempts; $a++) {
            & pwsh -NoProfile -File $buildScript -Configuration Release -Architecture $Architecture 2>&1 |
                ForEach-Object { Write-Host "    [build] $_" }
            if ($LASTEXITCODE -eq 0) { $built = $true; break }

            Write-Log "Build failed on batch #$i (attempt $a); engaging agent." 'WARN'
            $prompt = Build-AgentPrompt -Mode 'build' -Attempt $a -Batch $i `
                -Details "The Release/$Architecture build failed after merging this batch. Use Test-OpenSSHBuild to parse errors, fix them following Windows compatibility patterns, and rebuild."
            if (-not (Invoke-MergeAgent -Task "fix build (attempt $a)" -Prompt $prompt)) { break }
        }

        if (-not $built) {
            Write-Log "Build still failing after $MaxAgentAttempts attempts. Stopping." 'ERROR'
            $script:NeedsHuman = $true
            Add-Report "- Build failed and could not be fixed automatically after $MaxAgentAttempts attempts. **Human help needed.**"
            # Keep the merge commit so a human can pick up from vnext.
            break
        }

        # Never commit the machine-specific paths.targets churn.
        & git checkout -- 'contrib/win32/openssh/paths.targets' 2>$null
        if (Test-WorkingTreeDirty) {
            Assert-Git add -A | Out-Null
            Invoke-Git commit -m "CI: build fixes for upstream batch $i" | Out-Null
            Add-Report "- Build fixes applied and committed."
        }
        Add-Report "- Release/$Architecture build succeeded."
    } else {
        Write-Log "Batch #$i changed no C/H sources; skipping build validation."
        Add-Report "- No compiled sources changed; build validation skipped."
    }

    $script:BatchesMerged++
    Add-Report ""
}

# --------------------------------------------------------------------------
# Final full CI suite (once, if we merged anything and nothing is broken)
# --------------------------------------------------------------------------

$ciStatus = 'skipped'
if ($script:BatchesMerged -gt 0 -and -not $script:NeedsHuman -and -not $SkipFinalCI) {
    Write-Log "Running full CI suite after merging $($script:BatchesMerged) batch(es)."
    $testScript = Get-ToolPath 'Invoke-OpenSSHTests.ps1'
    & pwsh -NoProfile -File $testScript -Configuration Release -Architecture $Architecture 2>&1 |
        ForEach-Object { Write-Host "    [ci] $_" }
    if ($LASTEXITCODE -eq 0) {
        $ciStatus = 'passed'
        Add-Report "## Full CI: passed"
    } else {
        $ciStatus = 'failed'
        $script:NeedsHuman = $true
        Add-Report "## Full CI: FAILED - see workflow logs and test artifacts. **Human review needed.**"
    }
} elseif ($SkipFinalCI) {
    Add-Report "## Full CI: skipped (-SkipFinalCI)"
} elseif ($script:BatchesMerged -eq 0) {
    Add-Report "## Full CI: skipped (no batches merged)"
} else {
    Add-Report "## Full CI: skipped (earlier step needs human attention)"
}

# --------------------------------------------------------------------------
# Push + report
# --------------------------------------------------------------------------

if ($script:BatchesMerged -gt 0) {
    Write-Log "Pushing $VNextBranch to $OriginRemote."
    $push = Invoke-Git push $OriginRemote "${VNextBranch}:${VNextBranch}"
    if ($push.ExitCode -ne 0) {
        Write-Log "Push failed: $($push.Output)" 'ERROR'
        $script:NeedsHuman = $true
        Add-Report "> Failed to push ``$VNextBranch``: $($push.Output)"
    }
}

# Append the agent decision log to the report.
Add-Report ""
Add-Report "---"
Add-Report ""
Add-Report "## Agent decision log"
Add-Report ""
if (Test-Path $script:DecisionLog) {
    Add-Report (Get-Content -Raw $script:DecisionLog)
}

Set-Content -Path $ReportPath -Value $script:Report.ToString() -Encoding utf8
Write-Log "Report written to $ReportPath"

Set-StepOutput 'batches_merged' "$($script:BatchesMerged)"
Set-StepOutput 'needs_human' ($(if ($script:NeedsHuman) { 'true' } else { 'false' }))
Set-StepOutput 'ci_status' $ciStatus
Set-StepOutput 'vnext_branch' $VNextBranch
Set-StepOutput 'target_branch' $TargetBranch
Set-StepOutput 'report_path' $ReportPath

if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $script:Report.ToString()
}

Write-Log "Done. batches_merged=$($script:BatchesMerged) needs_human=$($script:NeedsHuman) ci_status=$ciStatus"

# Exit non-zero only to signal the run needs attention; the workflow still opens
# the review PR. Push/loop already recorded everything in the report.
if ($script:NeedsHuman) { exit 2 }
exit 0
