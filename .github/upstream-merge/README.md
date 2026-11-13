# Weekly upstream merge

This folder implements the scheduled upstream integration flow as a
**GitHub Agentic Workflow** with deterministic Windows preparation and
validation around one bounded remediation step.

The current deployment is deliberately limited to
`tgauth/openssh-portable`. It creates or advances `vnext` from
`merge-v10.6P1`, the fork branch behind
[PowerShell/openssh-portable#883](https://github.com/PowerShell/openssh-portable/pull/883).
This workflow only updates `vnext` and publishes diagnostic artifacts; it does
not look up, create, or update pull requests. Porting the validated tree to a
clean working branch without the agent's incremental commit history and
opening a PR belong to a separate workflow/task.

| File | Purpose |
|---|---|
| [`../workflows/merge-upstream-weekly.md`](../workflows/merge-upstream-weekly.md) | Editable Agentic Workflow source: schedule, job graph, tools, security boundary, and remediation prompt. |
| [`../workflows/merge-upstream-weekly.lock.yml`](../workflows/merge-upstream-weekly.lock.yml) | Generated GitHub Actions workflow. Regenerate with `gh aw compile merge-upstream-weekly --strict`. |
| [`Invoke-WeeklyUpstreamMerge.ps1`](./Invoke-WeeklyUpstreamMerge.ps1) | Deterministically merges clean batches, builds them, and creates a remediation request at the first conflict or build failure. |
| [`Apply-AgentRemediation.ps1`](./Apply-AgentRemediation.ps1) | Validates the agent bundle, recreates the exact state, applies it, builds on Windows, and pushes `vnext`; full CI is deferred. |

## Job flow

```text
Windows prepare
    |
    +-- no remediation --> optional full CI, push vnext, upload report
    |
    `-- remediation request
            |
            v
       sandboxed agent
       (read-only token)
            |
            v
       threat detection
            |
            v
       bounded artifact
            |
            v
       Windows continuation
       verify -> apply -> build -> push vnext -> upload report
```

The workflow never waits for another workflow run or polls an external agent.
All dependencies are part of one compiled GitHub Actions job graph. Agent
failure, timeout, missing output, malformed output, SHA drift, unsafe paths,
patch rejection, or validation failure produces a bounded failed run and a
`needs-human` report instead of an indefinite wait.

## Deterministic preparation

The preparation job:

1. Fetches `origin` and `upstream`.
2. Creates or reuses the long-lived **`vnext`** branch based on
   **`merge-v10.6P1`** in `tgauth/openssh-portable`.
3. Merges the current `origin/latestw_all` into `vnext` so an existing
   integration branch receives newer Windows build and compatibility changes,
   including toolchain updates, before upstream batches are selected.
4. Uses [`Get-CommitGroups.ps1`](../tools/Get-CommitGroups.ps1) in its default
   CI-success mode, so every batch ends at an upstream commit whose CI passed.
   The workflow supplies its trusted GitHub token as `GITHUB_TOKEN`, and
   `-FirstChunkOnly` scans incrementally until it finds that first endpoint
   rather than requiring API budget for the entire outstanding range.
5. Merges up to `max_batches` batches.
6. Enables the same vcpkg MSBuild integration used by the Azure DevOps build,
   installs the manifest-pinned dependencies using the GitHub-hosted runner's
   vcpkg clone, verifies the LibreSSL header, import library, and DLL after
   installation and immediately around MSBuild, then builds the base sync and
   batches that change `*.c` or `*.h`.
7. Stops at the first conflict or build failure and writes
   `remediation-request.json`.

Batch selection runs in-process to preserve the returned PowerShell objects.
An empty, malformed, or failed selection is a human-attention handoff while
upstream commits remain, never evidence that `vnext` is caught up. Only reaching
the selected upstream endpoint establishes that the merge is up to date.
Run `.\.github\upstream-merge\tests\Test-WeeklyUpstreamMerge.ps1` for the
isolated batch-selection regression checks (no merges, builds, or API calls).

If no remediation is needed and changes were integrated, preparation runs the
full CI suite once after the batch loop unless `skip_final_ci` is enabled,
then pushes `vnext` and uploads the report. CI does not run after each batch;
`max_batches` controls how many batches can accumulate before that final run.
Every attempted build is checked with `Test-OpenSSHBuild.ps1`; parsed errors
are included in the report or remediation request, and the diagnostic MSBuild
log is uploaded as a separate workflow artifact. Dependency validation reports
candidate paths when vcpkg produces an unexpected directory layout and
distinguishes install-time failures from files that disappear during MSBuild.

If remediation is required, preparation pushes the exact `vnext` head first.
The request records immutable values including `expectedHead`, `batchEnd`,
mode, batch number, expected conflicted paths, architecture, and the captured
build log.

## Agent boundary and output contract

The agent job runs in the GitHub Agentic Workflows firewall with:

- A read-only repository token.
- No branch push or PR credential.
- A fixed command allowlist.
- One remediation request.
- Threat detection before output is released.

The agent writes only text artifacts under
`/tmp/gh-aw/agent/remediation/`:

- `result.json` — schema version, status, mode, immutable SHAs, and summary.
- `decision-log.md` — situation, decision, rationale, confidence, and reviewer
  follow-up.
- Conflict mode: `resolved-files.json`, containing every expected conflicted
  path exactly once with base64 file content or a deletion marker.
- Build mode: `remediation.patch`, generated with `git diff --binary`.

The `publish_remediation` safe-output job transfers those files. It does not
apply them or receive the branch write credential.

## Deterministic continuation

The continuation job always treats the bundle as untrusted. It:

1. Verifies schema, status, mode, `expectedHead`, and `batchEnd`.
2. Refuses to proceed if `vnext` moved after preparation.
3. In conflict mode, recreates the merge and requires the conflict set to match
   exactly before writing only the requested paths.
4. In build mode, applies the patch with index and whitespace validation.
5. Rejects absolute paths, traversal, duplicate paths, unexpected files,
   missing files, unresolved conflicts, and empty patches.
6. Enables vcpkg MSBuild integration, installs and validates the manifest-pinned
   dependencies, checks them again immediately before and after the
   authoritative Windows Release build, and parses and uploads its diagnostic
   log.
7. Pushes only after validation succeeds.
8. Defers full CI and uploads the report. A later dispatch resumes from the
   repaired `vnext` head and runs full CI once its deterministic batch loop
   completes without another remediation handoff.

The workflow permits one agentic remediation boundary per run. After a
successful remediation, any additional upstream batches are picked up by the
next scheduled or manual run. Runs with no remediation still process up to the
configured batch cap.

## Security and credentials

The Agentic Workflow uses `copilot-requests: write` for managed Copilot
inference. It no longer installs Copilot CLI manually and no longer uses
`--allow-all-tools`.

The preparation job is guarded by
`github.repository == 'tgauth/openssh-portable'`. This prevents the testing
configuration from pushing branches if the workflow is copied
to `PowerShell/openssh-portable`.

| Secret | Used for | Agent access |
|---|---|---|
| `UPSTREAM_MERGE_TOKEN` | Trusted Windows jobs use it to push `vnext`. For fork testing, use a `tgauth` user token that can update workflow files. | **None** |

If `UPSTREAM_MERGE_TOKEN` is absent, the jobs fall back to `github.token`.
The generated workflow manifest records this restricted secret and the pinned
action/container dependencies reviewed by `gh aw compile --approve`.

For fork testing, configure `UPSTREAM_MERGE_TOKEN` with permission to write
repository contents and workflow files. No Pull requests write permission is
required by this workflow. Upstream
batches can modify `.github/workflows/**`; GitHub rejects those pushes when
they use the built-in GitHub App token, even when the job has
`contents: write`. A classic PAT needs `repo` and `workflow`; use the
equivalent repository Contents and Workflows permissions for a fine-grained
token if its workflow-file policy permits the update.

## Scheduling caveat

GitHub only fires `schedule:` from the repository default branch
(`latestw_all`). Before this workflow reaches that branch, use
`workflow_dispatch` for testing.

## Manual inputs

- `upstream_ref` — merge through a specific upstream ref; blank uses the
  upstream default branch tip.
- `max_batches` — maximum deterministic batches in a run; default 4.
- `max_agent_attempts` — maximum focused reasoning/edit passes allowed by the
  remediation prompt; default 3.
- `skip_agent` — never enter remediation; conflicts or build failures become
  immediate human handoffs.
- `skip_final_ci` — skip the once-per-run full CI suite after deterministic
  batches (default false). Remediation runs continue to defer full CI.

## Updating the workflow

Edit the Markdown source, not the generated lock file:

```powershell
gh aw compile merge-upstream-weekly --strict
```

When the compiler reports new restricted secrets, actions, containers, or
redirects, review each change and then explicitly approve the manifest:

```powershell
gh aw compile merge-upstream-weekly --strict --approve
```

Commit the Markdown source, lock file, `.github/aw/actions-lock.json`, and
`.gitattributes` together.
