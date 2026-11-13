#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$driver = Join-Path $PSScriptRoot '..\Invoke-WeeklyUpstreamMerge.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $driver, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0] }
$loop = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.ForStatementAst]
}, $false)
$loopScript = [scriptblock]::Create($loop.Extent.Text)

$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureDir | Out-Null
try {
    $getGroups = Join-Path $fixtureDir 'Get-CommitGroups.ps1'
    @'
param($StartCommit, $EndCommit, [switch]$FirstChunkOnly)
switch ($Scenario) {
    'empty' { return }
    'malformed' { return 'formatted console output' }
    'exit-error' { exit 1 }
    'throw-error' { throw 'CI lookup failed' }
    'multiple' {
        [pscustomobject]@{ EndCommitFull = $EndCommit }
        [pscustomobject]@{ EndCommitFull = $EndCommit }
        return
    }
}
[pscustomobject]@{
    EndCommitFull = $EndCommit
    CommitCount = 109
    EndMessage = 'Final upstream endpoint'
}
'@ | Set-Content -Path $getGroups

    function Write-Log { param($Message, $Level) }
    function Add-Report { param($Text) $script:Reports.Add($Text) }
    function Assert-Git {
        param([Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
        if ($GitArgs[0] -ne 'merge-base') { throw "Unexpected git call: $GitArgs" }
        return $script:CurrentUpstream
    }
    function Resolve-Sha { param($Ref) return ('c' * 40) }
    function Invoke-Git {
        param([Parameter(ValueFromRemainingArguments)][string[]]$GitArgs)
        if ($GitArgs[0] -ne 'merge' -or $GitArgs[-1] -ne $endSha) {
            throw "Unexpected git call: $GitArgs"
        }
        $script:MergeCalls++
        $script:CurrentUpstream = $endSha
        return [pscustomobject]@{ ExitCode = 0; Output = '' }
    }
    function Test-WorkingTreeDirty { return $false }
    function Test-CodeImpact { param($Range) return $false }

    foreach ($scenario in @('valid', 'empty', 'malformed', 'exit-error', 'throw-error', 'multiple', 'caught-up')) {
        $script:NeedsHuman = $false
        $script:BatchesMerged = 0
        $script:MergeCalls = 0
        $script:Reports = [System.Collections.Generic.List[string]]::new()
        $endSha = 'b' * 40
        $script:CurrentUpstream = if ($scenario -eq 'caught-up') { $endSha } else { 'a' * 40 }
        $VNextBranch = 'vnext'
        $MaxBatchesPerRun = 2
        & $loopScript

        if ($scenario -eq 'valid') {
            if ($script:NeedsHuman -or $script:BatchesMerged -ne 1 -or $script:MergeCalls -ne 1) {
                throw "Structured batch result was not merged successfully: $($script:Reports -join '; ')"
            }
        } elseif ($scenario -eq 'caught-up') {
            if ($script:NeedsHuman -or $script:BatchesMerged -ne 0 -or $script:MergeCalls -ne 0) {
                throw 'Already merged endpoint triggered work.'
            }
        } elseif (-not $script:NeedsHuman -or $script:MergeCalls -ne 0 -or
            ($script:Reports -join "`n") -notmatch 'Could not determine the next batch') {
            throw "Batch-selection failure was not reported: $scenario"
        }
        if ($scenario -notin @('valid', 'caught-up') -and
            ($script:Reports -join "`n") -match 'Up to date') {
            throw "Incomplete merge was reported as caught up: $scenario"
        }
    }
    'Passed 7 weekly merge batch-selection scenarios.'
} finally {
    Remove-Item -LiteralPath $getGroups -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixtureDir
}
