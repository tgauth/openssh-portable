<#
.SYNOPSIS
    Records a conflict resolution entry to the merge resolution log.

.DESCRIPTION
    MCP-compatible tool that saves details about how a conflicted file was resolved
    during the scratch-branch phase of the merge workflow. The resolution — including
    the resolved file content, strategy, and rationale — is appended to a JSON log
    at .git/merge-resolution-log.json.

    This log is consumed by Replay-MergeResolutions.ps1 during the real-branch
    single-merge phase to automatically re-apply known resolutions.

.PARAMETER FilePath
    Path to the resolved file, relative to the repository root.

.PARAMETER Strategy
    The resolution strategy used. One of:
      accept_upstream  — Took the upstream change completely
      ifdef_windows    — Wrapped with #ifdef WINDOWS / #else / #endif
      ifndef_windows   — Excluded with #ifndef WINDOWS
      combine          — Combined upstream and Windows changes
      manual           — Custom resolution not fitting other categories

.PARAMETER Rationale
    Free-text explanation of why this resolution strategy was chosen.

.PARAMETER BatchNumber
    The batch number (from Get-CommitGroups) that this resolution belongs to.

.PARAMETER UpstreamCommits
    Comma-separated list of upstream commit SHAs that touched this file in this batch.

.PARAMETER MergeTarget
    The final upstream ref being merged (e.g. "upstream/V_10_1_P1"). Only needed on
    the first invocation to initialise the log header. Ignored if log already exists.

.OUTPUTS
    Hashtable with:
      Success  [bool]    Whether the entry was saved
      Message  [string]  Human-readable summary
      LogPath  [string]  Absolute path to the resolution log file

.EXAMPLE
    # Record a resolution after resolving auth.c
    # MCP Tool: mcp_openssh-server_Save_MergeResolution
    # FilePath="auth.c", Strategy="ifdef_windows", Rationale="Wrapped PAM code",
    # BatchNumber=1, UpstreamCommits="abc1234,def5678"

.EXAMPLE
    # Record the first resolution (initialises log with MergeTarget)
    # MCP Tool: mcp_openssh-server_Save_MergeResolution
    # FilePath="channels.c", Strategy="accept_upstream", Rationale="Security fix",
    # BatchNumber=1, UpstreamCommits="abc1234", MergeTarget="upstream/V_10_1_P1"
#>

param(
    [Parameter(Mandatory)]
    [string]$FilePath,

    [Parameter(Mandatory)]
    [ValidateSet('accept_upstream', 'ifdef_windows', 'ifndef_windows', 'combine', 'manual')]
    [string]$Strategy,

    [Parameter(Mandatory)]
    [string]$Rationale,

    [Parameter(Mandatory)]
    [int]$BatchNumber,

    [string]$UpstreamCommits = '',

    [string]$MergeTarget = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Locate the log file inside .git ──────────────────────────────────────────

$gitDir = Join-Path (Get-Location) '.git'
if (-not (Test-Path $gitDir)) {
    return @{
        Success = $false
        Message = 'Not inside a git repository — .git directory not found.'
        LogPath = ''
    }
}

$logPath = Join-Path $gitDir 'merge-resolution-log.json'

# ── Read or initialise the log ───────────────────────────────────────────────

if (Test-Path $logPath) {
    $log = Get-Content -Raw $logPath | ConvertFrom-Json
} else {
    $log = [PSCustomObject]@{
        merge_target = if ($MergeTarget) { $MergeTarget } else { 'unknown' }
        created_at   = (Get-Date -Format 'o')
        resolutions  = @()
    }
}

# ── Read the resolved file and compute hash ──────────────────────────────────

$fullFilePath = Join-Path (Get-Location) $FilePath
if (-not (Test-Path $fullFilePath)) {
    return @{
        Success = $false
        Message = "Resolved file not found: ${FilePath}"
        LogPath = $logPath
    }
}

$fileBytes   = [System.IO.File]::ReadAllBytes($fullFilePath)
$sha256      = [System.Security.Cryptography.SHA256]::Create()
$hashBytes   = $sha256.ComputeHash($fileBytes)
$hashString  = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
$contentB64  = [System.Convert]::ToBase64String($fileBytes)

# ── Parse upstream commits ───────────────────────────────────────────────────

$commitList = if ($UpstreamCommits) {
    ($UpstreamCommits -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else {
    @()
}

# ── Build the entry ──────────────────────────────────────────────────────────

$entry = [PSCustomObject]@{
    file                     = $FilePath
    batch_number             = $BatchNumber
    upstream_commits         = $commitList
    strategy                 = $Strategy
    rationale                = $Rationale
    resolved_content_sha256  = $hashString
    resolved_content_base64  = $contentB64
    recorded_at              = (Get-Date -Format 'o')
}

# ── Append and save ──────────────────────────────────────────────────────────

# ConvertFrom-Json returns a fixed-size array; convert to a list so we can add
$existingResolutions = [System.Collections.Generic.List[object]]::new()
if ($log.resolutions) {
    foreach ($r in $log.resolutions) {
        $existingResolutions.Add($r)
    }
}
$existingResolutions.Add($entry)
$log.resolutions = $existingResolutions.ToArray()

$log | ConvertTo-Json -Depth 10 | Set-Content -Path $logPath -Encoding utf8

return @{
    Success = $true
    Message = "Resolution recorded for '${FilePath}' (batch ${BatchNumber}, strategy: ${Strategy}). Log has $($log.resolutions.Count) entries."
    LogPath = $logPath
}
