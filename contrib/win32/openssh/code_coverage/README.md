# Win32-OpenSSH code coverage

Tooling to produce a **C code coverage estimate** for the Windows solution
(`contrib\win32\openssh\Win32-OpenSSH.sln`) across all three test suites that
ship with this repository, and to **aggregate** them into a single
de-duplicated number that accounts for overlap between the suites.

## Files

| File | Purpose |
|------|---------|
| `OpenSSHCodeCoverage.psm1` | Module. Pure aggregation/overlap helpers **and** OpenCppCoverage orchestration. |
| `OpenSSHCodeCoverage.tests.ps1` | Pester 5 tests for the pure helpers (no build required). |
| `Invoke-OpenSSHCodeCoverage.ps1` | Local end-to-end driver: build → run suites under coverage → merge → summarize. |
| `Invoke-AzDOCodeCoverage.ps1` | CI entry point: run one suite (Core/Bash) under coverage against an installed OpenSSH dir, then merge. |

All files live in `contrib\win32\openssh\code_coverage\`.

## Why OpenCppCoverage

[OpenCppCoverage](https://github.com/OpenCppCoverage/OpenCppCoverage) is the
standard open-source, MSVC-compatible C/C++ coverage tool for Windows. It:

- reads the debug **PDBs** to map executed instructions back to source lines
  (no special build flags or instrumentation needed — just a Debug build),
- with `--cover_children`, attaches to a launched process **and every child it
  spawns**, so monitoring the test harness captures every `ssh.exe`,
  `sshd.exe`, `sftp.exe`, `unittest-*.exe`, etc. the tests launch,
- exports **binary** (`.cov`, re-mergeable), **Cobertura XML**, and **HTML**.

## How aggregation and overlap work

Each suite is measured independently and produces its own `.cov` + Cobertura
report. The `.cov` files are then merged natively by OpenCppCoverage. Merging
**unions per-line hit counts**, so a line exercised by two suites is counted
exactly once in the combined total — that is the de-duplication that makes the
aggregate honest.

The pure helpers additionally quantify the redundancy:

```
SumCoveredLines      = covered lines summed across suites (double counts overlap)
CombinedCoveredLines = covered lines after merge (each line once)   <- the estimate
OverlapLines         = SumCoveredLines - CombinedCoveredLines
```

## Usage

Requires: Visual Studio build tools (to build the solution), Chocolatey (to
auto-install OpenCppCoverage), and the test-suite prerequisites (Cygwin for the
bash suite, Pester for E2E — the existing helpers install these).

```powershell
cd contrib\win32\openssh\code_coverage

# All suites, Debug build (recommended for accurate PDBs):
.\Invoke-OpenSSHCodeCoverage.ps1 -Configuration Debug

# A single suite against an already-built tree:
.\Invoke-OpenSSHCodeCoverage.ps1 -Configuration Debug -Suite Unit -SkipBuild

# Custom output location:
.\Invoke-OpenSSHCodeCoverage.ps1 -Configuration Debug -OutputDirectory C:\cov
```

### Output artifacts (under `-OutputDirectory`, default `.\coverage`)

```
unit\unit.cov,  unit\unit.cobertura.xml       per-suite (unit tests)
e2e\e2e.cov,    e2e\e2e.cobertura.xml         per-suite (Pester E2E)
bash\bash.cov,  bash\bash.cobertura.xml       per-suite (bash tests)
merged\merged.cobertura.xml                   combined, de-duplicated (native merge)
merged\html\                                  browsable HTML report
coverage-summary.json                         machine-readable summary
coverage-summary.md                           per-suite + combined + overlap table
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
OpenCppCoverage, or the OpenSSH suites:

```powershell
Invoke-Pester -Path .\OpenSSHCodeCoverage.tests.ps1 -Output Detailed
```

## Continuous integration (Azure DevOps)

`.azdo/ci.yml` runs a non-gating **Win32-OpenSSH Code Coverage** job in the
Test stage, in parallel with the existing test jobs. It:

1. downloads the build artifacts (which include `.pdb` symbols) and unit tests,
   and installs OpenSSH to `C:\OpenSSH`,
2. runs `Invoke-AzDOCodeCoverage.ps1 -Suite Core` (setup + unit + E2E) and then
   `-Suite Bash`, each under OpenCppCoverage,
3. merges the per-suite `.cov` files, then publishes the merged Cobertura report
   via `PublishCodeCoverageResults@2` and uploads the full
   `Win32-OpenSSH-CodeCoverage` artifact (per-suite reports, HTML, summaries).

The job is marked `continueOnError: true` so coverage never blocks a merge. The
suites run the exact CI entry points (`Invoke-OpenSSHTests`,
`Invoke-OpenSSHBashTestsOnly`), so coverage reflects what CI already exercises.

## Notes

- Use a **Debug** configuration locally for the most faithful line mapping.
  Release with full optimizations can fold/reorder lines and understate
  coverage; CI measures the Release artifacts it already produces.
- Coverage is scoped to repository sources via `--sources <repo root>` and to the
  built binaries via `--modules <bin dir>`, so third-party/system code is excluded.
- The tooling reuses the existing suite entry points, so it measures exactly what
  CI already runs.
