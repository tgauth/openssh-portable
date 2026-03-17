<#
.SYNOPSIS
    Replays saved conflict resolutions from the merge resolution log onto
    currently conflicted files.

.DESCRIPTION
    MCP-compatible tool for the real-branch phase of the scratch-branch merge
    workflow. Reads .git/merge-resolution-log.json (populated during the scratch
    phase by Save-MergeResolution.ps1) and attempts to apply saved resolutions
    to files that are currently in a conflicted state (UU/AA/etc. in git status).

    For each conflicted file that has a matching entry in the log, the tool writes
    the saved resolved content and stages the file with git add.

    Files not found in the log are reported as unmatched so the agent can resolve
    them manually.

.PARAMETER DryRun
    When specified, reports what would be applied without modifying any files.

.OUTPUTS
    Hashtable with:
      Success        [bool]      Whether the operation completed without errors
      Message        [string]    Human-readable summary
      ResolvedFiles  [string[]]  Files successfully resolved from the log
      UnmatchedFiles [string[]]  Conflicted files with no log entry
      FailedFiles    [string[]]  Files where replay was attempted but failed
      LogPath        [string]    Absolute path to the resolution log

.EXAMPLE
    # Replay all saved resolutions onto current merge conflicts
    # MCP Tool: mcp_openssh-server_Replay_MergeResolutions

.EXAMPLE
    # Preview what would be replayed without modifying files
    # MCP Tool: mcp_openssh-server_Replay_MergeResolutions
    # DryRun=true
#>

param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Git process helper (same pattern as Invoke-Git.ps1) ──────────────────────

function Invoke-GitCommand {
    param([string[]]$Arguments)

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName               = 'git'
    $processInfo.Arguments              = ($Arguments | ForEach-Object {
        if ($_ -match '\s') { "`"$_`"" } else { $_ }
    }) -join ' '
    $processInfo.UseShellExecute        = $false
    $processInfo.CreateNoWindow         = $true
    $processInfo.RedirectStandardInput  = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError  = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    $process.Start() | Out-Null
    $process.StandardInput.Close()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $completed = $process.WaitForExit(30000)

    if (-not $completed) {
        $process.Kill()
        return @{
            ExitCode = -1
            Success  = $false
            Output   = ''
            Error    = "git $($Arguments -join ' ') timed out after 30 seconds"
        }
    }

    return @{
        ExitCode = $process.ExitCode
        Success  = ($process.ExitCode -eq 0)
        Output   = $stdoutTask.GetAwaiter().GetResult().TrimEnd()
        Error    = $stderrTask.GetAwaiter().GetResult().TrimEnd()
    }
}

# ── Locate and read the resolution log ───────────────────────────────────────

$gitDir = Join-Path (Get-Location) '.git'
$logPath = Join-Path $gitDir 'merge-resolution-log.json'

if (-not (Test-Path $logPath)) {
    return @{
        Success        = $false
        Message        = 'No resolution log found at .git/merge-resolution-log.json. Run the scratch-branch phase first.'
        ResolvedFiles  = @()
        UnmatchedFiles = @()
        FailedFiles    = @()
        LogPath        = $logPath
    }
}

$log = Get-Content -Raw $logPath | ConvertFrom-Json

if (-not $log.resolutions -or $log.resolutions.Count -eq 0) {
    return @{
        Success        = $true
        Message        = 'Resolution log is empty — no saved resolutions to replay.'
        ResolvedFiles  = @()
        UnmatchedFiles = @()
        FailedFiles    = @()
        LogPath        = $logPath
    }
}

# ── Build a lookup of saved resolutions keyed by file path ───────────────────
# If multiple entries exist for the same file (across batches), use the latest one.

$resolutionMap = @{}
foreach ($entry in $log.resolutions) {
    $resolutionMap[$entry.file] = $entry
}

# ── Get currently conflicted files from git status ───────────────────────────

$statusResult = Invoke-GitCommand -Arguments @('status', '--porcelain')
$conflictedFiles = @()
if ($statusResult.Output) {
    $conflictedFiles = ($statusResult.Output -split "`n") |
        Where-Object { $_ -match '^(UU|AA|DD|AU|UA|DU|UD)\s' } |
        ForEach-Object { $_.Substring(3).Trim() }
}

if ($conflictedFiles.Count -eq 0) {
    return @{
        Success        = $true
        Message        = 'No conflicted files found — nothing to replay.'
        ResolvedFiles  = @()
        UnmatchedFiles = @()
        FailedFiles    = @()
        LogPath        = $logPath
    }
}

# ── Replay resolutions ──────────────────────────────────────────────────────

$resolvedFiles  = [System.Collections.Generic.List[string]]::new()
$unmatchedFiles = [System.Collections.Generic.List[string]]::new()
$failedFiles    = [System.Collections.Generic.List[string]]::new()

foreach ($file in $conflictedFiles) {
    if (-not $resolutionMap.ContainsKey($file)) {
        $unmatchedFiles.Add($file)
        continue
    }

    $entry = $resolutionMap[$file]

    if ($DryRun) {
        $resolvedFiles.Add($file)
        continue
    }

    try {
        # Decode the saved resolved content and write it to the file
        $contentBytes = [System.Convert]::FromBase64String($entry.resolved_content_base64)
        $fullFilePath = Join-Path (Get-Location) $file
        [System.IO.File]::WriteAllBytes($fullFilePath, $contentBytes)

        # Stage the resolved file
        $addResult = Invoke-GitCommand -Arguments @('add', $file)
        if (-not $addResult.Success) {
            $failedFiles.Add($file)
            continue
        }

        $resolvedFiles.Add($file)
    } catch {
        $failedFiles.Add($file)
    }
}

# ── Return result ────────────────────────────────────────────────────────────

$dryRunNote = if ($DryRun) { ' (DRY RUN — no files modified)' } else { '' }
$message = "Replay complete${dryRunNote}: $($resolvedFiles.Count) resolved, " +
           "$($unmatchedFiles.Count) unmatched, $($failedFiles.Count) failed " +
           "(out of $($conflictedFiles.Count) conflicted files)."

return @{
    Success        = ($failedFiles.Count -eq 0)
    Message        = $message
    ResolvedFiles  = $resolvedFiles.ToArray()
    UnmatchedFiles = $unmatchedFiles.ToArray()
    FailedFiles    = $failedFiles.ToArray()
    LogPath        = $logPath
}
