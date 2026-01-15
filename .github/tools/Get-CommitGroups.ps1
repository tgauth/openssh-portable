<#
.SYNOPSIS
    Groups upstream OpenSSH commits into batches based on CI success status or CI presence.

.DESCRIPTION
    This script fetches commits from the openssh/openssh-portable repository on GitHub
    and groups them into batches (chunks) based on CI test results. By default, each chunk
    ends with a commit that has all CI tests passing (success or skipped). Alternatively,
    when using -GroupByCIPresence, each chunk ends with any commit that has CI runs,
    regardless of success or failure.

    The script is designed to help with incremental merging of upstream commits by
    identifying safe stopping points where all tests pass (or where CI exists).

    When the total number of commits exceeds 250 (GitHub API limit), the script
    automatically adjusts to fetch the first 250 commits in chronological order.

.PARAMETER GitHubTag
    The GitHub tag to start from (e.g., "V_10_0_P2"). Cannot be used with -StartCommit.
    The script will find commits after this tag up to HEAD.

.PARAMETER StartCommit
    The commit SHA to start from (e.g., "6fb728df50c1afd338cb0223a84ce24579577eff").
    Cannot be used with -GitHubTag. The script will find commits after this commit up to HEAD.
    This is typically used when continuing from a previously merged commit.

.PARAMETER FirstChunkOnly
    When specified, the script stops after finding the first chunk with a successful CI commit
    (or first chunk with any CI when using -GroupByCIPresence).
    This is useful for incremental processing where you want to merge one batch at a time.

.PARAMETER GroupByCIPresence
    When specified, groups commits by CI presence (any CI run exists) rather than CI success.
    Each chunk ends with a commit that has any CI runs, regardless of pass/fail status.
    Default behavior (without this flag) groups by CI success only.

.OUTPUTS
    Returns an array of chunk objects, each containing:
    - ChunkNumber: Sequential number of the chunk
    - StartIndex/EndIndex: Array indices for the chunk range
    - StartCommit/EndCommit: Short SHA (7 chars) of first and last commits
    - StartCommitFull/EndCommitFull: Full SHA of first and last commits
    - CommitCount: Number of commits in the chunk
    - StartMessage/EndMessage: Commit messages for first and last commits

.EXAMPLE
    .\Get-CommitGroups.ps1 -GitHubTag "V_10_0_P2" -FirstChunkOnly

    Finds the first batch of commits after the V_10_0_P2 tag that ends with passing CI.

.EXAMPLE
    .\Get-CommitGroups.ps1 -StartCommit "6fb728df50c1afd338cb0223a84ce24579577eff" -FirstChunkOnly

    Finds the first batch of commits after the specified commit that ends with passing CI.
    Useful for continuing from where a previous merge left off.

.EXAMPLE
    .\Get-CommitGroups.ps1 -StartCommit "6fb728df50c1afd338cb0223a84ce24579577eff"

    Finds all batches of commits after the specified commit, grouping by CI success.
    Each batch ends with a commit that has passing CI tests.

.EXAMPLE
    .\Get-CommitGroups.ps1 -GitHubTag "V_10_0_P2" -GroupByCIPresence -FirstChunkOnly

    Finds the first batch of commits after the V_10_0_P2 tag that ends with any commit
    that has CI runs (regardless of success or failure).

.NOTES
    - Requires internet access to query GitHub API
    - Set GITHUB_TOKEN environment variable for authenticated API access (5,000 requests/hour)
    - Without token: rate limited with 200ms delay between commits (60 requests/hour)
    - Maximum 250 commits per API call (automatically handled)
    - CI status is checked via GitHub check-runs API with pagination support
    - Default mode: Commits with "success" or "skipped" CI conclusions are considered passing
    - GroupByCIPresence mode: Any commit with CI runs (regardless of result) ends a chunk

.LINK
    https://github.com/openssh/openssh-portable
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$GitHubTag,

    [Parameter(Mandatory=$false)]
    [string]$StartCommit,

    [Parameter(Mandatory=$false)]
    [switch]$FirstChunkOnly,

    [Parameter(Mandatory=$false)]
    [switch]$GroupByCIPresence
)

# Validate parameters
if (-not $GitHubTag -and -not $StartCommit) {
    Write-Error "Either -GitHubTag or -StartCommit must be provided"
    exit 1
}

if ($GitHubTag -and $StartCommit) {
    Write-Error "Cannot specify both -GitHubTag and -StartCommit. Please provide only one."
    exit 1
}

# Configuration
$repo = "openssh/openssh-portable"
$apiBase = "https://api.github.com/repos/$repo"

# Check for GitHub token for authenticated API access
$script:githubToken = $env:GITHUB_TOKEN
if ($script:githubToken) {
    Write-Host "Using authenticated GitHub API (higher rate limits)" -ForegroundColor Green
} else {
    Write-Host "Using unauthenticated GitHub API (rate limited - consider setting GITHUB_TOKEN)" -ForegroundColor Yellow
}

if ($GitHubTag) {
    Write-Host "Fetching commits starting from tag: $GitHubTag" -ForegroundColor Cyan
} else {
    Write-Host "Fetching commits starting from commit: $StartCommit" -ForegroundColor Cyan
}

# Function to get GitHub API headers with optional authentication
function Get-GitHubHeaders {
    $headers = @{
        "User-Agent" = "PowerShell"
        "Accept" = "application/vnd.github+json"
    }
    
    if ($script:githubToken) {
        $headers["Authorization"] = "Bearer $script:githubToken"
    }
    
    return $headers
}

# Get the starting commit SHA
try {
    if ($GitHubTag) {
        $tagInfo = Invoke-RestMethod -Uri "$apiBase/git/refs/tags/$GitHubTag" -Headers (Get-GitHubHeaders)
        $startCommitSha = $tagInfo.object.sha

        # If it's an annotated tag, we need to get the actual commit
        if ($tagInfo.object.type -eq "tag") {
            $tagObject = Invoke-RestMethod -Uri $tagInfo.object.url -Headers (Get-GitHubHeaders)
            $startCommitSha = $tagObject.object.sha
        }

        Write-Host "Tag $GitHubTag points to commit: $startCommitSha" -ForegroundColor Green
    } else {
        # Validate the commit exists
        $commitInfo = Invoke-RestMethod -Uri "$apiBase/commits/$StartCommit" -Headers (Get-GitHubHeaders)
        $startCommitSha = $commitInfo.sha
        Write-Host "Starting from commit: $startCommitSha" -ForegroundColor Green
    }
} catch {
    Write-Error "Failed to retrieve starting commit information: $_"
    exit 1
}

# Function to check CI status for a commit
function Get-CommitCIStatus {
    param(
        [string]$sha,
        [bool]$checkPresenceOnly = $false
    )

    try {
        $allCheckRuns = @()
        $page = 1
        $perPage = 100

        # Fetch all pages of check runs
        do {
            $checkRunsUrl = "$apiBase/commits/$sha/check-runs?per_page=$perPage&page=$page"
            $response = Invoke-RestMethod -Uri $checkRunsUrl -Headers (Get-GitHubHeaders)

            $allCheckRuns += $response.check_runs
            $page++

        } while ($response.check_runs.Count -eq $perPage)

        # Check if there are any check runs
        if ($allCheckRuns.Count -eq 0) {
            return "no_ci"
        }

        # If only checking for presence, return has_ci
        if ($checkPresenceOnly) {
            return "has_ci"
        }

        # Check if all check runs are successful or skipped
        $allSuccessful = $true
        foreach ($checkRun in $allCheckRuns) {
            # Accept "success" or "skipped" as valid conclusions
            if ($checkRun.conclusion -ne "success" -and $checkRun.conclusion -ne "skipped") {
                $allSuccessful = $false
                break
            }
        }

        if ($allSuccessful) {
            return "success"
        } else {
            return "failure"
        }
    } catch {
        Write-Warning "Could not get CI status for commit $sha : $_"
        return "unknown"
    }
}

# Function to get commit details
function Get-CommitDetails {
    param([string]$sha)

    try {
        $commitUrl = "$apiBase/commits/$sha"
        $commit = Invoke-RestMethod -Uri $commitUrl -Headers (Get-GitHubHeaders)
        return @{
            Sha = $commit.sha.Substring(0, 7)
            FullSha = $commit.sha
            Message = $commit.commit.message.Split("`n")[0]
            Author = $commit.commit.author.name
            Date = $commit.commit.author.date
        }
    } catch {
        Write-Warning "Could not get commit details for $sha"
        return $null
    }
}

# Fetch commits starting from the tag using compare API
Write-Host "`nFetching commits from the repository..." -ForegroundColor Cyan

try {
    # Get commits after the starting commit (excluding the start commit itself)
    $allCommits = @()
    $page = 1
    $perPage = 250  # Compare API returns max 250 commits per page

    Write-Host "Fetching commits from $startCommitSha...HEAD" -ForegroundColor Gray

    # The Compare API doesn't support pagination, so we need to use commits API instead
    # to get commits in the correct range with proper pagination
    $compareUrl = "$apiBase/compare/${startCommitSha}...HEAD"
    $comparison = Invoke-RestMethod -Uri $compareUrl -Headers (Get-GitHubHeaders)

    # The Compare API returns commits - need to verify order
    # According to GitHub API docs, commits are in chronological order (oldest first)
    $allCommits = @($comparison.commits)

    # If we hit the 250 commit limit, we need to get the actual first 250 commits
    # by using the oldest commit from this batch as the end point
    if ($comparison.total_commits -gt 250) {
        Write-Host "Warning: Total commits ($($comparison.total_commits)) exceeds API limit (250)." -ForegroundColor Yellow
        Write-Host "Fetching first 250 commits by using oldest commit as endpoint..." -ForegroundColor Cyan

        # Get the oldest commit SHA from the initial batch (first in chronological order)
        $oldestCommitSha = $allCommits[0].sha

        # Now compare from start to this oldest commit to get the actual first 250
        $limitedCompareUrl = "$apiBase/compare/${startCommitSha}...${oldestCommitSha}"
        Write-Host "Comparing $startCommitSha...$oldestCommitSha" -ForegroundColor Gray
        $limitedComparison = Invoke-RestMethod -Uri $limitedCompareUrl -Headers (Get-GitHubHeaders)

        $allCommits = @($limitedComparison.commits)
        Write-Host "Fetched $($allCommits.Count) commits in the corrected range" -ForegroundColor Green
    }

    $startRef = if ($GitHubTag) { "tag $GitHubTag" } else { "commit $StartCommit" }
    Write-Host "Found $($allCommits.Count) commits from $startRef" -ForegroundColor Green
} catch {
    Write-Error "Failed to fetch commits: $_"
    exit 1
}

# Process commits and check CI status
$statusCheckMessage = if ($GroupByCIPresence) { "Checking CI presence for each commit..." } else { "Checking CI status for each commit..." }
Write-Host "`n$statusCheckMessage" -ForegroundColor Cyan

$commitsWithStatus = @()
$chunks = @()
$commitCount = 0
$chunkStart = 0

foreach ($commit in $allCommits) {
    $commitCount++
    Write-Host "Processing commit $commitCount of $($allCommits.Count): $($commit.sha.Substring(0,7))" -ForegroundColor Gray

    $status = Get-CommitCIStatus -sha $commit.sha -checkPresenceOnly $GroupByCIPresence
    $details = Get-CommitDetails -sha $commit.sha

    if ($details) {
        $commitsWithStatus += [PSCustomObject]@{
            Index = $commitCount - 1
            Sha = $details.Sha
            FullSha = $details.FullSha
            Message = $details.Message
            Author = $details.Author
            Date = $details.Date
            CIStatus = $status
        }

        # Check if this commit completes a chunk (based on grouping mode)
        $targetStatus = if ($GroupByCIPresence) { "has_ci" } else { "success" }
        if ($status -eq $targetStatus) {
            $chunkEnd = $commitsWithStatus.Count - 1

            $chunks += [PSCustomObject]@{
                ChunkNumber = $chunks.Count + 1
                StartIndex = $chunkStart
                EndIndex = $chunkEnd
                StartCommit = $commitsWithStatus[$chunkStart].Sha
                EndCommit = $commitsWithStatus[$chunkEnd].Sha
                StartCommitFull = $commitsWithStatus[$chunkStart].FullSha
                EndCommitFull = $commitsWithStatus[$chunkEnd].FullSha
                CommitCount = $chunkEnd - $chunkStart + 1
                StartMessage = $commitsWithStatus[$chunkStart].Message
                EndMessage = $commitsWithStatus[$chunkEnd].Message
            }

            $chunkStart = $commitsWithStatus.Count

            # If FirstChunkOnly is specified, stop after finding the first chunk
            if ($FirstChunkOnly) {
                $chunkFoundMessage = if ($GroupByCIPresence) { "Found first chunk with CI, stopping..." } else { "Found first successful chunk, stopping..." }
                Write-Host $chunkFoundMessage -ForegroundColor Green
                break
            }
        }
    }

    # Rate limiting - only needed for unauthenticated requests
    if (-not $script:githubToken) {
        Start-Sleep -Milliseconds 200
    }
}

# Handle remaining commits that don't end with success (only if not FirstChunkOnly or no chunk found)
if (-not $FirstChunkOnly -and $chunkStart -lt $commitsWithStatus.Count) {
    $chunkEnd = $commitsWithStatus.Count - 1
    $chunks += [PSCustomObject]@{
        ChunkNumber = $chunks.Count + 1
        StartIndex = $chunkStart
        EndIndex = $chunkEnd
        StartCommit = $commitsWithStatus[$chunkStart].Sha
        EndCommit = $commitsWithStatus[$chunkEnd].Sha
        StartCommitFull = $commitsWithStatus[$chunkStart].FullSha
        EndCommitFull = $commitsWithStatus[$chunkEnd].FullSha
        CommitCount = $chunkEnd - $chunkStart + 1
        StartMessage = $commitsWithStatus[$chunkStart].Message
        EndMessage = $commitsWithStatus[$chunkEnd].Message
    }
}

Write-Host "`nGrouping complete." -ForegroundColor Cyan

# Display results
$groupingMode = if ($GroupByCIPresence) { "CI Presence" } else { "CI Success" }
Write-Host "\n========================================" -ForegroundColor Cyan
Write-Host "COMMIT CHUNKS (Grouped by $groupingMode)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

foreach ($chunk in $chunks) {
    Write-Host "Chunk $($chunk.ChunkNumber): $($chunk.CommitCount) commits" -ForegroundColor Yellow
    Write-Host "  Start: $($chunk.StartCommit) - $($chunk.StartMessage)" -ForegroundColor White
    Write-Host "  End:   $($chunk.EndCommit) - $($chunk.EndMessage)" -ForegroundColor Green
    Write-Host "  Commit Pair: ($($chunk.StartCommitFull), $($chunk.EndCommitFull))" -ForegroundColor Magenta
    Write-Host ""
}

Write-Host "`nTotal Chunks: $($chunks.Count)" -ForegroundColor Cyan
Write-Host "Total Commits: $($commitsWithStatus.Count)" -ForegroundColor Cyan

# Output detailed commit list
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "DETAILED COMMIT LIST" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Only show commits that are part of returned chunks
$maxIndex = if ($chunks.Count -gt 0) { $chunks[-1].EndIndex } else { -1 }
foreach ($commit in $commitsWithStatus) {
    if ($commit.Index -le $maxIndex) {
        $statusColor = switch ($commit.CIStatus) {
            "success" { "Green" }
            "has_ci" { "Green" }
            "failure" { "Red" }
            "no_ci" { "Yellow" }
            "pending" { "Yellow" }
            default { "Gray" }
        }

        Write-Host "$($commit.Sha) | $($commit.CIStatus.PadRight(10)) | $($commit.Message.Substring(0, [Math]::Min(60, $commit.Message.Length)))" -ForegroundColor $statusColor
    }
}

# Return the chunks for potential further processing
return $chunks
