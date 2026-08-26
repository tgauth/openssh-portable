# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
    OpenSSHCodeCoverage.psm1

    Helpers to estimate C code coverage of the Win32-OpenSSH solution
    (contrib\win32\openssh\Win32-OpenSSH.sln) across the three test suites
    that ship with this repository:

      * unit tests  (regress\unittests\*, built as unittest-*.exe)
      * Pester E2E  (regress\pesterTests\*.Tests.ps1)
      * bash tests  (regress\*.sh, driven by bash_tests_iterator.ps1)

    Native C coverage on MSVC is collected with OpenCppCoverage
    (https://github.com/OpenCppCoverage/OpenCppCoverage). OpenCppCoverage
    attaches to a process *and its children* using the debug PDBs, so a single
    coverage session captures every ssh.exe / sshd.exe / sftp.exe etc. that a
    test spawns. Each suite is run under its own coverage session and exported
    as a binary (.cov) file plus a Cobertura XML report. The binary files are
    then merged natively by OpenCppCoverage, which unions per-line hit counts -
    so a line exercised by two different suites is only counted once. That
    natural de-duplication is what lets us aggregate the suites and account for
    overlap.

    This module intentionally separates *pure* functions (Cobertura parsing,
    line merging, overlap measurement, summary formatting) from the functions
    that shell out to OpenCppCoverage / MSBuild. The pure functions carry the
    aggregation logic and are covered by OpenSSHCodeCoverage.tests.ps1.
#>

$ErrorActionPreference = 'Stop'

# Repository root is four levels up from contrib\win32\openssh\code_coverage.
$script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path

#region Pure helpers (unit tested)

<#
    .SYNOPSIS
    Normalizes a source-file path emitted in a coverage report to a stable,
    repository-relative, forward-slash path.

    .DESCRIPTION
    OpenCppCoverage records absolute paths for each source file. Those paths
    differ between machines (developer box vs. CI agent) and use backslashes.
    To merge reports produced on different machines - and to present readable
    results - we strip the repository root (or the well-known CI checkout
    prefixes) and normalize separators.
#>
function ConvertTo-NormalizedCoverageSourcePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $RawPath,

        # Repository root to strip. Defaults to this checkout's root.
        [string] $RepositoryRoot = $script:RepositoryRoot
    )

    if ([string]::IsNullOrWhiteSpace($RawPath)) {
        return $RawPath
    }

    # Normalize separators first so every later comparison is forward-slash.
    $normalized = $RawPath -replace '\\', '/'

    # Strip a provided repository root if the path lives underneath it.
    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $root = ($RepositoryRoot -replace '\\', '/').TrimEnd('/')
        if ($root -and $normalized.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $normalized = $normalized.Substring($root.Length)
        }
    }

    # Strip well-known CI checkout prefixes:
    #   Azure Pipelines / GitHub Actions Windows: D:/a/<repo>/<repo>/
    #   GitHub Actions Linux:                     /home/runner/work/<repo>/<repo>/
    #   GitHub Actions macOS:                     /Users/runner/work/<repo>/<repo>/
    $ciPatterns = @(
        '(?i)^[a-z]:/a/[^/]+/[^/]+/',
        '(?i)^/home/[^/]+/work/[^/]+/[^/]+/',
        '(?i)^/Users/[^/]+/work/[^/]+/[^/]+/'
    )
    foreach ($pattern in $ciPatterns) {
        $normalized = [regex]::Replace($normalized, $pattern, '')
    }

    return $normalized.TrimStart('/')
}

<#
    .SYNOPSIS
    Imports a Cobertura XML file into a coverage map.

    .DESCRIPTION
    Returns a hashtable keyed by normalized source path. Each value is itself a
    hashtable mapping line number (int) to hit count (int). This is the shape
    consumed by Merge-CoverageData / Get-CoverageStatistic.
#>
function Import-CoberturaCoverage {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $RepositoryRoot = $script:RepositoryRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cobertura report not found: $Path"
    }

    [xml] $xml = Get-Content -LiteralPath $Path -Raw
    $map = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($class in $xml.SelectNodes('//class')) {
        $file = $class.GetAttribute('filename')
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        $key = ConvertTo-NormalizedCoverageSourcePath -RawPath $file -RepositoryRoot $RepositoryRoot

        if (-not $map.ContainsKey($key)) {
            $map[$key] = @{}
        }
        $lines = $map[$key]

        foreach ($line in $class.SelectNodes('lines/line')) {
            $number = [int] $line.GetAttribute('number')
            $hits = [int] $line.GetAttribute('hits')
            if ($lines.ContainsKey($number)) {
                # Same line can appear more than once (e.g. inlined). Keep the max.
                if ($hits -gt $lines[$number]) { $lines[$number] = $hits }
            }
            else {
                $lines[$number] = $hits
            }
        }
    }

    return $map
}

<#
    .SYNOPSIS
    Merges any number of coverage maps into one, summing hit counts per line.

    .DESCRIPTION
    This is the aggregation primitive. Where two suites cover the same file and
    line, the hit counts are summed - the line ends up covered exactly once in
    the merged map (its hit count is > 0), which is precisely how overlap is
    absorbed. Lines unique to a single suite are carried through untouched.
#>
function Merge-CoverageData {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [hashtable[]] $CoverageMap
    )

    $merged = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($map in $CoverageMap) {
        if ($null -eq $map) { continue }
        foreach ($file in $map.Keys) {
            if (-not $merged.ContainsKey($file)) {
                $merged[$file] = @{}
            }
            $target = $merged[$file]
            foreach ($number in $map[$file].Keys) {
                $hits = [int] $map[$file][$number]
                if ($target.ContainsKey($number)) {
                    $target[$number] = [int] $target[$number] + $hits
                }
                else {
                    $target[$number] = $hits
                }
            }
        }
    }

    return $merged
}

<#
    .SYNOPSIS
    Computes line-coverage statistics for a coverage map.
#>
function Get-CoverageStatistic {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $CoverageMap,

        # Optional label carried through onto the result (e.g. suite name).
        [string] $Name
    )

    [int] $totalLines = 0
    [int] $coveredLines = 0
    $files = New-Object System.Collections.Generic.List[object]

    foreach ($file in ($CoverageMap.Keys | Sort-Object)) {
        $lines = $CoverageMap[$file]
        [int] $fileTotal = $lines.Count
        [int] $fileCovered = 0
        foreach ($number in $lines.Keys) {
            if ([int] $lines[$number] -gt 0) { $fileCovered++ }
        }
        $totalLines += $fileTotal
        $coveredLines += $fileCovered
        $files.Add([pscustomobject]@{
            File         = $file
            TotalLines   = $fileTotal
            CoveredLines = $fileCovered
            LineRate     = if ($fileTotal -gt 0) { [math]::Round($fileCovered / $fileTotal, 4) } else { 0 }
        })
    }

    [pscustomobject]@{
        Name         = $Name
        TotalLines   = $totalLines
        CoveredLines = $coveredLines
        LineRate     = if ($totalLines -gt 0) { [math]::Round($coveredLines / $totalLines, 4) } else { 0 }
        Percent      = if ($totalLines -gt 0) { [math]::Round(100 * $coveredLines / $totalLines, 2) } else { 0 }
        Files        = $files
    }
}

<#
    .SYNOPSIS
    Measures how much the suites overlap.

    .DESCRIPTION
    Given the per-suite coverage maps, returns:
      * SumCoveredLines      - naive sum of covered lines across suites
      * CombinedCoveredLines - covered lines after merging (de-duplicated)
      * OverlapLines         - SumCoveredLines - CombinedCoveredLines, i.e. the
                               number of (file,line) coverage records that were
                               claimed by more than one suite
      * OverlapPercent       - OverlapLines as a percentage of SumCoveredLines
    The combined figure is the honest aggregate coverage number; the overlap
    figure quantifies redundant coverage between the suites.
#>
function Measure-CoverageOverlap {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable[]] $CoverageMap
    )

    [int] $sumCovered = 0
    foreach ($map in $CoverageMap) {
        if ($null -eq $map) { continue }
        $stat = Get-CoverageStatistic -CoverageMap $map
        $sumCovered += $stat.CoveredLines
    }

    $merged = Merge-CoverageData -CoverageMap $CoverageMap
    $combined = (Get-CoverageStatistic -CoverageMap $merged).CoveredLines
    $overlap = $sumCovered - $combined

    [pscustomobject]@{
        SumCoveredLines      = $sumCovered
        CombinedCoveredLines = $combined
        OverlapLines         = $overlap
        OverlapPercent       = if ($sumCovered -gt 0) { [math]::Round(100 * $overlap / $sumCovered, 2) } else { 0 }
    }
}

<#
    .SYNOPSIS
    Writes a coverage map back out as a minimal Cobertura XML report.

    .DESCRIPTION
    Used to persist the helper-merged aggregate (independent of the native
    OpenCppCoverage merge) so the numbers can be diffed / archived.
#>
function New-MergedCoberturaReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $CoverageMap,

        [Parameter(Mandatory = $true)]
        [string] $OutputPath
    )

    $stat = Get-CoverageStatistic -CoverageMap $CoverageMap
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $timestamp = [int][double]::Parse((Get-Date -UFormat %s), $inv)
    $lineRateStr = $stat.LineRate.ToString($inv)

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = [System.Text.Encoding]::UTF8

    $writer = [System.Xml.XmlWriter]::Create($OutputPath, $settings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('coverage')
        $writer.WriteAttributeString('line-rate', $lineRateStr)
        $writer.WriteAttributeString('branch-rate', '0')
        $writer.WriteAttributeString('lines-covered', ([string]$stat.CoveredLines))
        $writer.WriteAttributeString('lines-valid', ([string]$stat.TotalLines))
        $writer.WriteAttributeString('version', '0')
        $writer.WriteAttributeString('timestamp', ([string]$timestamp))

        $writer.WriteStartElement('packages')
        $writer.WriteStartElement('package')
        $writer.WriteAttributeString('name', 'Win32-OpenSSH')
        $writer.WriteAttributeString('line-rate', $lineRateStr)
        $writer.WriteStartElement('classes')

        foreach ($file in ($CoverageMap.Keys | Sort-Object)) {
            $lines = $CoverageMap[$file]
            [int] $fileTotal = $lines.Count
            [int] $fileCovered = 0
            foreach ($n in $lines.Keys) { if ([int] $lines[$n] -gt 0) { $fileCovered++ } }
            $rate = if ($fileTotal -gt 0) { [math]::Round($fileCovered / $fileTotal, 4) } else { 0 }

            $writer.WriteStartElement('class')
            $writer.WriteAttributeString('name', (Split-Path -Leaf $file))
            $writer.WriteAttributeString('filename', $file)
            $writer.WriteAttributeString('line-rate', ([double]$rate).ToString($inv))
            $writer.WriteStartElement('lines')
            foreach ($n in ($lines.Keys | Sort-Object { [int]$_ })) {
                $writer.WriteStartElement('line')
                $writer.WriteAttributeString('number', ([string]$n))
                $writer.WriteAttributeString('hits', ([string][int]$lines[$n]))
                $writer.WriteEndElement()
            }
            $writer.WriteEndElement() # lines
            $writer.WriteEndElement() # class
        }

        $writer.WriteEndElement() # classes
        $writer.WriteEndElement() # package
        $writer.WriteEndElement() # packages
        $writer.WriteEndElement() # coverage
        $writer.WriteEndDocument()
    }
    finally {
        $writer.Flush()
        $writer.Close()
    }

    return $OutputPath
}

<#
    .SYNOPSIS
    Builds a human/machine readable summary object from per-suite statistics,
    the combined statistic and the overlap measurement.
#>
function Get-CoverageSummary {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject[]] $SuiteStatistic,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $CombinedStatistic,

        [Parameter(Mandatory = $true)]
        [pscustomobject] $Overlap
    )

    [pscustomobject]@{
        GeneratedOn = (Get-Date).ToString('o')
        Suites      = @($SuiteStatistic | ForEach-Object {
            [pscustomobject]@{
                Name         = $_.Name
                TotalLines   = $_.TotalLines
                CoveredLines = $_.CoveredLines
                Percent      = $_.Percent
            }
        })
        Combined    = [pscustomobject]@{
            TotalLines   = $CombinedStatistic.TotalLines
            CoveredLines = $CombinedStatistic.CoveredLines
            Percent      = $CombinedStatistic.Percent
        }
        Overlap     = $Overlap
    }
}

<#
    .SYNOPSIS
    Renders a coverage summary as a Markdown table string.
#>
function Format-CoverageSummaryMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Summary
    )

    $sb = New-Object System.Text.StringBuilder
    [void] $sb.AppendLine('# Win32-OpenSSH code coverage estimate')
    [void] $sb.AppendLine('')
    [void] $sb.AppendLine("Generated: $($Summary.GeneratedOn)")
    [void] $sb.AppendLine('')
    [void] $sb.AppendLine('| Suite | Covered | Total | Line % |')
    [void] $sb.AppendLine('|-------|--------:|------:|-------:|')
    foreach ($suite in $Summary.Suites) {
        [void] $sb.AppendLine("| $($suite.Name) | $($suite.CoveredLines) | $($suite.TotalLines) | $($suite.Percent)% |")
    }
    [void] $sb.AppendLine("| **Combined (deduped)** | **$($Summary.Combined.CoveredLines)** | **$($Summary.Combined.TotalLines)** | **$($Summary.Combined.Percent)%** |")
    [void] $sb.AppendLine('')
    [void] $sb.AppendLine('## Overlap between suites')
    [void] $sb.AppendLine('')
    [void] $sb.AppendLine("- Sum of per-suite covered lines: $($Summary.Overlap.SumCoveredLines)")
    [void] $sb.AppendLine("- Combined (de-duplicated) covered lines: $($Summary.Overlap.CombinedCoveredLines)")
    [void] $sb.AppendLine("- Overlapping covered lines: $($Summary.Overlap.OverlapLines) ($($Summary.Overlap.OverlapPercent)% of the sum)")
    return $sb.ToString()
}

#endregion Pure helpers

#region OpenCppCoverage orchestration

<#
    .SYNOPSIS
    Ensures OpenCppCoverage is installed and returns the path to its exe.
#>
function Install-OpenCppCoverage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch] $Force
    )

    $existing = Get-Command 'OpenCppCoverage.exe' -ErrorAction SilentlyContinue
    if ($existing -and -not $Force) {
        return $existing.Source
    }

    $defaultPath = Join-Path $env:ProgramFiles 'OpenCppCoverage\OpenCppCoverage.exe'
    if ((Test-Path $defaultPath) -and -not $Force) {
        return $defaultPath
    }

    $choco = Get-Command 'choco.exe' -ErrorAction SilentlyContinue
    if (-not $choco) {
        throw 'OpenCppCoverage is not installed and Chocolatey is unavailable. Install OpenCppCoverage from https://github.com/OpenCppCoverage/OpenCppCoverage/releases and re-run.'
    }

    Write-Verbose 'Installing OpenCppCoverage via Chocolatey...'
    & $choco.Source install opencppcoverage -y --no-progress | Write-Verbose

    $found = Get-Command 'OpenCppCoverage.exe' -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    if (Test-Path $defaultPath) { return $defaultPath }

    throw 'Failed to locate OpenCppCoverage after installation.'
}

<#
    .SYNOPSIS
    Runs an arbitrary command under OpenCppCoverage, exporting a binary (.cov)
    and a Cobertura XML report scoped to the OpenSSH sources and modules.
#>
function Invoke-CoverageSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [string] $Program,
        [string[]] $ArgumentList = @(),
        [Parameter(Mandatory = $true)] [string] $OutputDirectory,
        [string] $SourceRoot = $script:RepositoryRoot,
        [string] $ModuleFilter,
        [string] $WorkingDirectory,
        [string] $OpenCppCoveragePath
    )

    if (-not $OpenCppCoveragePath) { $OpenCppCoveragePath = Install-OpenCppCoverage }
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force

    $binaryOut = Join-Path $OutputDirectory "$Name.cov"
    $coberturaOut = Join-Path $OutputDirectory "$Name.cobertura.xml"

    $occArgs = @(
        '--sources', $SourceRoot,
        '--export_type', "binary:$binaryOut",
        '--export_type', "cobertura:$coberturaOut",
        '--cover_children',
        '--quiet'
    )
    if ($ModuleFilter) { $occArgs += @('--modules', $ModuleFilter) }
    if ($WorkingDirectory) { $occArgs += @('--working_dir', $WorkingDirectory) }
    $occArgs += '--'
    $occArgs += $Program
    $occArgs += $ArgumentList

    Write-Verbose "OpenCppCoverage $($occArgs -join ' ')"
    & $OpenCppCoveragePath @occArgs
    $exit = $LASTEXITCODE

    [pscustomobject]@{
        Name         = $Name
        ExitCode     = $exit
        BinaryPath   = $binaryOut
        CoberturaPath = $coberturaOut
    }
}

<#
    .SYNOPSIS
    Merges binary (.cov) exports natively with OpenCppCoverage, producing a
    combined Cobertura XML and (optionally) an HTML report. This is the
    authoritative merged report; the pure helpers produce the same numbers and
    add the overlap breakdown.
#>
function Merge-CoverageBinary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string[]] $BinaryPath,
        [Parameter(Mandatory = $true)] [string] $OutputDirectory,
        [switch] $Html,
        [string] $OpenCppCoveragePath
    )

    if (-not $OpenCppCoveragePath) { $OpenCppCoveragePath = Install-OpenCppCoverage }
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force

    $coberturaOut = Join-Path $OutputDirectory 'merged.cobertura.xml'
    Remove-Item -LiteralPath $coberturaOut -Force -ErrorAction SilentlyContinue

    $occArgs = @()
    foreach ($bin in $BinaryPath) {
        if (Test-Path $bin) { $occArgs += @('--input_coverage', $bin) }
    }
    if (-not $occArgs) { throw 'No binary coverage inputs found to merge.' }

    $occArgs += @('--export_type', "cobertura:$coberturaOut")
    if ($Html) {
        $htmlOut = Join-Path $OutputDirectory 'html'
        # OpenCppCoverage refuses to write into an existing HTML export
        # directory, so clear any report from a previous run first.
        Remove-Item -LiteralPath $htmlOut -Recurse -Force -ErrorAction SilentlyContinue
        $occArgs += @('--export_type', "html:$htmlOut")
    }
    $occArgs += '--quiet'

    Write-Verbose "OpenCppCoverage $($occArgs -join ' ')"
    & $OpenCppCoveragePath @occArgs | Write-Verbose
    if ($LASTEXITCODE -ne 0) {
        throw "OpenCppCoverage merge failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $coberturaOut)) {
        throw "OpenCppCoverage merge did not produce $coberturaOut."
    }

    return $coberturaOut
}

#endregion OpenCppCoverage orchestration

Export-ModuleMember -Function @(
    'ConvertTo-NormalizedCoverageSourcePath',
    'Import-CoberturaCoverage',
    'Merge-CoverageData',
    'Get-CoverageStatistic',
    'Measure-CoverageOverlap',
    'New-MergedCoberturaReport',
    'Get-CoverageSummary',
    'Format-CoverageSummaryMarkdown',
    'Install-OpenCppCoverage',
    'Invoke-CoverageSession',
    'Merge-CoverageBinary'
)
