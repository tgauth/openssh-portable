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

    Native C coverage on MSVC is collected with Microsoft.CodeCoverage.Console
    (https://learn.microsoft.com/visualstudio/test/microsoft-code-coverage-console-tool),
    the Microsoft-maintained coverage tool that ships with Visual Studio 2022
    (17.3+, Enterprise edition provides native C/C++ support). Unlike a
    debugger-attach tool, it uses *static instrumentation*: the OpenSSH binaries
    are built with the /PROFILE linker switch (see the dedicated coverage build
    job) and rewritten on disk by the `instrument` command, embedding a shared
    session id.

    Collection uses server mode. For each suite we start a background collector
    (`collect --session-id <id> --server-mode`) and then run the suite. Every
    instrumented OpenSSH process that executes while the collector owns the
    session - including sshd.exe running as a Windows *service*, which is not a
    child of our process - rendezvouses with the collector by session id. That
    is why server mode is used rather than a simple child-process wrap: the
    E2E/bash suites drive a real sshd service. `shutdown <id>` flushes each
    suite's .coverage file, which we convert to Cobertura via `merge`.

    The per-suite .coverage files are then merged (`merge ... -f cobertura`),
    which unions per-line hit counts, so a line exercised by two different
    suites is only counted once. That natural de-duplication is what lets us
    aggregate the suites and account for overlap.

    This module intentionally separates *pure* functions (Cobertura parsing,
    line merging, overlap measurement, summary formatting) from the functions
    that shell out to Microsoft.CodeCoverage.Console / MSBuild. The pure
    functions carry the aggregation logic and are covered by
    OpenSSHCodeCoverage.tests.ps1.
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
    The coverage tool records absolute paths for each source file. Those paths
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
    Microsoft.CodeCoverage.Console merge) so the numbers can be diffed /
    archived.
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

#region Microsoft.CodeCoverage.Console orchestration

# Well-known OpenSSH executables that are built with /PROFILE and therefore can
# be statically instrumented. unittest-*.exe are matched separately by wildcard.
$script:OpenSSHCoverageExeNames = @(
    'ssh.exe', 'sshd.exe', 'sshd-session.exe', 'sftp.exe', 'sftp-server.exe',
    'scp.exe', 'ssh-add.exe', 'ssh-agent.exe', 'ssh-keygen.exe',
    'ssh-keyscan.exe', 'ssh-shellhost.exe', 'ssh-sk-helper.exe',
    'ssh-pkcs11-helper.exe'
)

<#
    .SYNOPSIS
    Locates Microsoft.CodeCoverage.Console.exe.

    .DESCRIPTION
    The tool ships with Visual Studio 2022 (17.3+) under
    Common7\IDE\Extensions\Microsoft\CodeCoverage.Console. Native C/C++ coverage
    requires the Enterprise edition. Resolution order: an explicit -Path, the
    current PATH, vswhere-reported VS installations, then a scan of the standard
    install roots.
#>
function Find-CodeCoverageConsole {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Path
    )

    if ($Path) {
        if (Test-Path -LiteralPath $Path) { return (Resolve-Path -LiteralPath $Path).Path }
        throw "Microsoft.CodeCoverage.Console.exe was not found at '$Path'."
    }

    $existing = Get-Command 'Microsoft.CodeCoverage.Console.exe' -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }

    $relative = 'Common7\IDE\Extensions\Microsoft\CodeCoverage.Console\Microsoft.CodeCoverage.Console.exe'

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $roots = & $vswhere -all -prerelease -property installationPath 2>$null
        foreach ($root in $roots) {
            if (-not $root) { continue }
            $candidate = Join-Path $root $relative
            if (Test-Path $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        }
    }

    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $vsRoot = Join-Path $base 'Microsoft Visual Studio'
        if (-not (Test-Path $vsRoot)) { continue }
        $found = Get-ChildItem -Path $vsRoot -Recurse -Filter 'Microsoft.CodeCoverage.Console.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    throw @'
Microsoft.CodeCoverage.Console.exe was not found. It ships with Visual Studio 2022 (17.3 or later); native C/C++ code coverage requires the Enterprise edition. Install the "Code coverage" component, or run on an agent image that includes VS Enterprise (the hosted windows-latest image does).
'@
}

<#
    .SYNOPSIS
    Returns the OpenSSH binaries under a directory that should be instrumented.
#>
function Get-OpenSSHCoverageTarget {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [string] $BinaryDirectory
    )

    if (-not (Test-Path -LiteralPath $BinaryDirectory)) {
        throw "Binary directory '$BinaryDirectory' does not exist."
    }

    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:OpenSSHCoverageExeNames) {
        $p = Join-Path $BinaryDirectory $name
        if (Test-Path -LiteralPath $p) { [void] $targets.Add((Resolve-Path -LiteralPath $p).Path) }
    }
    Get-ChildItem -Path $BinaryDirectory -Filter 'unittest-*.exe' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { [void] $targets.Add($_.FullName) }

    return $targets.ToArray()
}

<#
    .SYNOPSIS
    Copies the static_covrun*.dll runtime next to the instrumented binaries.

    .DESCRIPTION
    An instrumented native binary references static_covrun64.dll at load time.
    The `collect`/`connect` commands add its directory to PATH automatically, but
    the sshd/ssh-agent *services* are launched by the Service Control Manager and
    do not inherit that PATH, so the runtime must sit beside the instrumented
    binaries or the services fail to start.

    The runtime does not live next to Microsoft.CodeCoverage.Console.exe; it ships
    under "<VS install root>\Team Tools\Dynamic Code Coverage Tools\" (with a
    per-architecture subfolder), so the search starts from the VS install root
    inferred from the tool path.
#>
function Copy-CoverageRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $ToolPath,
        [Parameter(Mandatory = $true)] [string] $DestinationDirectory
    )

    $toolDir = Split-Path -Parent $ToolPath

    # The tool lives at <root>\Common7\IDE\Extensions\Microsoft\CodeCoverage.Console;
    # walk up to the VS install root (the parent of the "Common7" segment) so the
    # sibling "Team Tools\Dynamic Code Coverage Tools" folder is in scope.
    $installRoot = $null
    $probe = $toolDir
    while ($probe) {
        if ((Split-Path -Leaf $probe) -eq 'Common7') {
            $installRoot = Split-Path -Parent $probe
            break
        }
        $parent = Split-Path -Parent $probe
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }

    # Prefer the known runtime folder, then fall back to broader recursive scans.
    $runtimes = $null
    if ($installRoot) {
        $dynamicTools = Join-Path $installRoot 'Team Tools\Dynamic Code Coverage Tools'
        if (Test-Path -LiteralPath $dynamicTools) {
            $runtimes = Get-ChildItem -Path $dynamicTools -Recurse -Filter 'static_covrun*.dll' -ErrorAction SilentlyContinue
        }
    }
    if (-not $runtimes) {
        $runtimes = Get-ChildItem -Path $toolDir -Recurse -Filter 'static_covrun*.dll' -ErrorAction SilentlyContinue
    }
    if (-not $runtimes -and $installRoot) {
        $runtimes = Get-ChildItem -Path $installRoot -Recurse -Filter 'static_covrun*.dll' -ErrorAction SilentlyContinue
    }

    if (-not $runtimes) {
        Write-Warning "No static_covrun*.dll found near '$ToolPath'; instrumented service binaries may fail to load."
        return
    }

    # Copy one DLL per file name (the arch variants have distinct names).
    foreach ($rt in ($runtimes | Group-Object Name | ForEach-Object { $_.Group[0] })) {
        Copy-Item -LiteralPath $rt.FullName -Destination $DestinationDirectory -Force
    }
}

<#
    .SYNOPSIS
    Statically instruments a set of native binaries with a shared session id.

    .DESCRIPTION
    Each binary is first restored (best-effort uninstrument) so the function is
    idempotent across repeated CI steps that share an installed OpenSSH
    directory, then instrumented in place. Requires the binaries to have been
    linked with /PROFILE.
#>
function Invoke-CoverageInstrument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string[]] $BinaryPath,
        [Parameter(Mandatory = $true)] [string] $SessionId,
        [string] $ToolPath
    )

    if (-not $ToolPath) { $ToolPath = Find-CodeCoverageConsole }
    $instrumented = New-Object System.Collections.Generic.List[string]

    foreach ($bin in $BinaryPath) {
        if (-not (Test-Path -LiteralPath $bin)) {
            Write-Warning "Instrument target '$bin' not found; skipping."
            continue
        }
        # Restore first so re-running against an already-instrumented binary
        # (e.g. Core step then Bash step) does not fail.
        & $ToolPath uninstrument $bin --nologo 2>$null | Out-Null

        & $ToolPath instrument $bin --session-id $SessionId --nologo | Write-Verbose
        if ($LASTEXITCODE -ne 0) {
            throw "Instrumenting '$bin' failed with exit code $LASTEXITCODE. Ensure it was linked with /PROFILE."
        }
        [void] $instrumented.Add($bin)
    }

    if ($instrumented.Count -eq 0) {
        throw 'No binaries were instrumented; cannot collect coverage.'
    }

    # Drop the coverage runtime next to every directory that holds an
    # instrumented binary.
    $dirs = $instrumented | ForEach-Object { Split-Path -Parent $_ } | Sort-Object -Unique
    foreach ($dir in $dirs) { Copy-CoverageRuntime -ToolPath $ToolPath -DestinationDirectory $dir }

    return $instrumented.ToArray()
}

<#
    .SYNOPSIS
    Restores (uninstruments) a set of native binaries. Best-effort.
#>
function Invoke-CoverageUninstrument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string[]] $BinaryPath,
        [string] $ToolPath
    )
    if (-not $ToolPath) { $ToolPath = Find-CodeCoverageConsole }
    foreach ($bin in $BinaryPath) {
        if (-not (Test-Path -LiteralPath $bin)) { continue }
        & $ToolPath uninstrument $bin --nologo 2>$null | Out-Null
    }
}

<#
    .SYNOPSIS
    Runs a suite under a server-mode coverage collector and returns the
    resulting .coverage plus a per-suite Cobertura report.

    .DESCRIPTION
    Starts `collect --session-id <id> --server-mode` as a background process so
    it owns the session, runs the suite command, then `shutdown <id>` to flush
    the .coverage file. Every instrumented OpenSSH process (including sshd.exe
    started as a service, which is not our child) that executes during the
    window rendezvouses with the collector by session id.
#>
function Invoke-CoverageSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [string] $Program,
        [string[]] $ArgumentList = @(),
        [Parameter(Mandatory = $true)] [string] $SessionId,
        [Parameter(Mandatory = $true)] [string] $OutputDirectory,
        [string] $WorkingDirectory,
        [int] $CollectorReadySeconds = 5,
        [string] $ToolPath
    )

    if (-not $ToolPath) { $ToolPath = Find-CodeCoverageConsole }
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force

    $coverageOut = Join-Path $OutputDirectory "$Name.coverage"
    $coberturaOut = Join-Path $OutputDirectory "$Name.cobertura.xml"
    Remove-Item -LiteralPath $coverageOut -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $coberturaOut -Force -ErrorAction SilentlyContinue

    $collectorLog = Join-Path $OutputDirectory "$Name.collector.log"
    $collector = Start-Process -FilePath $ToolPath -PassThru -NoNewWindow `
        -RedirectStandardOutput $collectorLog `
        -ArgumentList @(
            'collect', '--session-id', $SessionId, '--server-mode',
            '--output', $coverageOut, '--output-format', 'coverage', '--nologo'
        )

    # Let the collector take ownership of the session before we run the suite.
    Start-Sleep -Seconds $CollectorReadySeconds

    $exit = $null
    try {
        if ($WorkingDirectory) { Push-Location $WorkingDirectory }
        & $Program @ArgumentList
        $exit = $LASTEXITCODE
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
        & $ToolPath shutdown $SessionId --nologo 2>$null | Write-Verbose
    }

    if ($collector -and -not $collector.HasExited) {
        $null = $collector.WaitForExit(120000)
    }

    if (Test-Path -LiteralPath $coverageOut) {
        Convert-CoverageReport -InputPath $coverageOut -OutputPath $coberturaOut -Format cobertura -ToolPath $ToolPath | Out-Null
    }
    else {
        Write-Warning "Collector produced no coverage file for suite '$Name'. See $collectorLog."
    }

    [pscustomobject]@{
        Name          = $Name
        ExitCode      = $exit
        CoveragePath  = $coverageOut
        CoberturaPath = $coberturaOut
    }
}

<#
    .SYNOPSIS
    Merges/converts one or more .coverage (or coverage XML) inputs into a single
    report, using the tool's native `merge` command.

    .DESCRIPTION
    `merge` unions per-line hit counts across inputs, so merging every per-suite
    .coverage yields the de-duplicated aggregate. Pass a single input to simply
    convert it to another format. Supported -Format values: cobertura, xml,
    coverage.
#>
function Convert-CoverageReport {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [string[]] $InputPath,
        [Parameter(Mandatory = $true)] [string] $OutputPath,
        [ValidateSet('cobertura', 'xml', 'coverage')]
        [string] $Format = 'cobertura',
        [string] $ToolPath
    )

    if (-not $ToolPath) { $ToolPath = Find-CodeCoverageConsole }

    $inputs = @($InputPath | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if (-not $inputs) { throw 'No coverage inputs found to merge/convert.' }

    $outDir = Split-Path -Parent $OutputPath
    if ($outDir) { $null = New-Item -ItemType Directory -Path $outDir -Force }
    Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue

    $mergeArgs = @('merge') + $inputs + @('--output', $OutputPath, '--output-format', $Format, '--nologo')
    Write-Verbose "Microsoft.CodeCoverage.Console $($mergeArgs -join ' ')"
    & $ToolPath @mergeArgs | Write-Verbose
    if ($LASTEXITCODE -ne 0) {
        throw "Coverage merge/convert failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "Coverage merge/convert did not produce '$OutputPath'."
    }

    return $OutputPath
}

#endregion Microsoft.CodeCoverage.Console orchestration

Export-ModuleMember -Function @(
    'ConvertTo-NormalizedCoverageSourcePath',
    'Import-CoberturaCoverage',
    'Merge-CoverageData',
    'Get-CoverageStatistic',
    'Measure-CoverageOverlap',
    'New-MergedCoberturaReport',
    'Get-CoverageSummary',
    'Format-CoverageSummaryMarkdown',
    'Find-CodeCoverageConsole',
    'Get-OpenSSHCoverageTarget',
    'Copy-CoverageRuntime',
    'Invoke-CoverageInstrument',
    'Invoke-CoverageUninstrument',
    'Invoke-CoverageSession',
    'Convert-CoverageReport'
)
