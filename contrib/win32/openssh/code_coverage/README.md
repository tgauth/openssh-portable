# Win32-OpenSSH code coverage

Tooling to produce a **C code coverage estimate** for the Windows solution
(`contrib\win32\openssh\Win32-OpenSSH.sln`) across all three test suites that
ship with this repository, and to **aggregate** them into a single
de-duplicated number that accounts for overlap between the suites.

## Files

| File | Purpose |
|------|---------|
| `OpenSSHCodeCoverage.psm1` | Module. Pure aggregation/overlap helpers **and** Microsoft.CodeCoverage.Console orchestration. |
| `OpenSSHCodeCoverage.tests.ps1` | Pester 5 tests for the pure helpers (no build required). |
| `Invoke-OpenSSHCodeCoverage.ps1` | Local end-to-end driver: build → run suites under coverage → merge → summarize. |
| `Invoke-AzDOCodeCoverage.ps1` | CI entry point: run one suite (Core/Bash) under coverage against an installed OpenSSH dir, then merge. |

All files live in `contrib\win32\openssh\code_coverage\`.

## Why Microsoft.CodeCoverage.Console

[Microsoft.CodeCoverage.Console](https://learn.microsoft.com/visualstudio/test/microsoft-code-coverage-console-tool)
is the Microsoft-maintained coverage tool that ships with Visual Studio 2022
(17.3+). Native C/C++ coverage requires the **Enterprise** edition (the hosted
`windows-latest` Azure DevOps image includes it). It:

- collects **native C/C++** line coverage via **static instrumentation** — the
  binaries are built with the `/PROFILE` linker switch and rewritten on disk by
  the `instrument` command,
- supports **server mode** (`collect --session-id <id> --server-mode`): every
  instrumented process that runs while the collector owns the session reports
  in by session id — including `sshd.exe` running as a Windows **service**,
  which is *not* a child of the collector,
- emits `.coverage` (re-mergeable) and, via `merge`, **Cobertura XML**.

Server mode is why coverage captures the E2E/bash suites: those drive a real
sshd service plus `ssh.exe`/`sftp.exe` clients, none of which are children of a
single wrapped process.

## How aggregation and overlap work

Each suite is measured independently and produces its own `.coverage` +
Cobertura report. The `.coverage` files are then merged natively
(`merge ... -f cobertura`). Merging **unions per-line hit counts**, so a line
exercised by two suites is counted exactly once in the combined total — that is
the de-duplication that makes the aggregate honest.

The pure helpers additionally quantify the redundancy:

```
SumCoveredLines      = covered lines summed across suites (double counts overlap)
CombinedCoveredLines = covered lines after merge (each line once)   <- the estimate
OverlapLines         = SumCoveredLines - CombinedCoveredLines
```

## Usage

Requires: Visual Studio 2022 **Enterprise** (17.3+) — provides both the build
tools and `Microsoft.CodeCoverage.Console.exe` for native coverage — and the
test-suite prerequisites (Cygwin for the bash suite, Pester for E2E — the
existing helpers install these). The local driver builds `Debug` with
`/PROFILE` automatically (via the linker `LINK` env var) so the binaries can be
instrumented.

```powershell
cd contrib\win32\openssh\code_coverage

# All suites, Debug build (recommended for accurate line mapping):
.\Invoke-OpenSSHCodeCoverage.ps1 -Configuration Debug

# A single suite against an already-built tree:
.\Invoke-OpenSSHCodeCoverage.ps1 -Configuration Debug -Suite Unit -SkipBuild

# Custom output location:
.\Invoke-OpenSSHCodeCoverage.ps1 -Configuration Debug -OutputDirectory C:\cov
```

### Output artifacts (under `-OutputDirectory`, default `.\coverage`)

```
unit\unit.coverage,  unit\unit.cobertura.xml       per-suite (unit tests)
e2e\e2e.coverage,    e2e\e2e.cobertura.xml         per-suite (Pester E2E)
bash\bash.coverage,  bash\bash.cobertura.xml       per-suite (bash tests)
merged\merged.cobertura.xml                        combined, de-duplicated (native merge)
coverage-summary.json                              machine-readable summary
coverage-summary.md                                per-suite + combined + overlap table
```

Example `coverage-summary.md`:

```
| Suite | Covered | Total | Line % |
|-------|--------:|------:|-------:|
| unit  |    4210 | 20144 |  20.9% |
| e2e   |    9633 | 20144 |  47.8% |
| bash  |   11002 | 20144 |  54.6% |
| **Combined (deduped)** | **13120** | **20144** | **65.1%** |

## Overlap between suites
- Sum of per-suite covered lines: 24845
- Combined (de-duplicated) covered lines: 13120
- Overlapping covered lines: 11725 (47.19% of the sum)
```

## Validating the helpers

The aggregation/overlap logic is unit tested and does **not** require a build,
Microsoft.CodeCoverage.Console, or the OpenSSH suites:

```powershell
Invoke-Pester -Path .\OpenSSHCodeCoverage.tests.ps1 -Output Detailed
```

## Continuous integration (Azure DevOps)

Coverage is wired into `.azdo/ci.yml` as two dedicated, **PR-only, non-gating**
jobs (they never run on branch builds, where CodeQL already competes for the
~60 min agent budget, and `continueOnError: true` so they never block a merge):

1. **Build Coverage Package (x64 Debug + /PROFILE)** — a Build-stage job that
   builds the solution `Debug|x64` with `/PROFILE` injected via the linker
   `LINK` env var (no `.vcxproj` edits), publishing `Win32-OpenSSH-Coverage-x64`
   and `UnitTests-Coverage-x64` (binaries + PDBs). It runs in parallel with the
   normal Release build, so it does not eat into the coverage job's budget.
2. **Win32-OpenSSH Code Coverage** — a Test-stage job that installs the coverage
   build to `C:\OpenSSH`, then runs `Invoke-AzDOCodeCoverage.ps1 -Suite Core`
   (setup + unit + E2E) and `-Suite Bash`. Each invocation instruments the
   installed binaries, runs the suite under a server-mode collector, converts to
   Cobertura, and aggregates every per-suite report. It publishes the merged
   Cobertura via `PublishCodeCoverageResults@2` and uploads the full
   `Win32-OpenSSH-CodeCoverage` artifact (per-suite reports + summaries).

The suites run the exact CI entry points (`Invoke-OpenSSHTests`,
`Invoke-OpenSSHBashTestsOnly`), so coverage reflects what CI already exercises.

## Notes

- A **Debug** build is used for coverage so line mapping is accurate; optimized
  Release builds can fold/reorder/strip lines and understate coverage.
- Native C/C++ coverage requires **Visual Studio 2022 Enterprise** and binaries
  linked with `/PROFILE`; the coverage build job and local driver handle both.
- Coverage is scoped to OpenSSH source files at report time (paths are
  normalized to the repository root), so third-party/system code is excluded.
- The tooling reuses the existing suite entry points, so it measures exactly what
  CI already runs.
