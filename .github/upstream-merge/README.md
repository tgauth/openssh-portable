# Weekly upstream merge

This folder implements the scheduled upstream integration flow as a
**GitHub Agentic Workflow** with deterministic Windows preparation and
validation around one bounded remediation step.

The current deployment is deliberately limited to
`tgauth/openssh-portable`. It creates or advances `vnext` from
`merge-v10.6P1`, the fork branch behind
[PowerShell/openssh-portable#883](https://github.com/PowerShell/openssh-portable/pull/883).
The workflow opens its review PR inside the fork, from `vnext` back to
`merge-v10.6P1`; it does not update the open PowerShell repository PR.

| File | Purpose |
|---|---|
| [`../workflows/merge-upstream-weekly.md`](../workflows/merge-upstream-weekly.md) | Editable Agentic Workflow source: schedule, job graph, tools, security boundary, and remediation prompt. |
| [`../workflows/merge-upstream-weekly.lock.yml`](../workflows/merge-upstream-weekly.lock.yml) | Generated GitHub Actions workflow. Regenerate with `gh aw compile merge-upstream-weekly --strict`. |
| [`Invoke-WeeklyUpstreamMerge.ps1`](./Invoke-WeeklyUpstreamMerge.ps1) | Deterministically merges clean batches, builds them, and creates a remediation request at the first conflict or build failure. |
| [`Apply-AgentRemediation.ps1`](./Apply-AgentRemediation.ps1) | Validates the agent bundle, recreates the exact state, applies it, builds on Windows, runs full CI, and pushes `vnext`. |

## Job flow

```text
Windows prepare
    |
    +-- no remediation --> push vnext, run full CI, update PR
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
       verify -> apply -> build -> full CI -> push/update PR
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
3. Uses [`Get-CommitGroups.ps1`](../tools/Get-CommitGroups.ps1) in its default
   CI-success mode, so every batch ends at an upstream commit whose CI passed.
   The workflow supplies its trusted GitHub token as `GITHUB_TOKEN`, and
   `-FirstChunkOnly` scans incrementally until it finds that first endpoint
   rather than requiring API budget for the entire outstanding range.
4. Merges up to `max_batches` batches.
5. Builds batches that change `*.c` or `*.h`.
6. Stops at the first conflict or build failure and writes
   `remediation-request.json`.

If no remediation is needed, preparation runs the full CI suite, pushes
`vnext`, uploads the report, and opens or updates the human-review PR.

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
6. Runs the authoritative Windows Release build.
7. Pushes only after validation succeeds.
8. Runs the full CI suite and updates the review PR.

The trusted preparation and continuation jobs are pinned to `windows-2022`
because the current OpenSSH build helper supports Visual Studio through 2022.
Using `windows-latest` may select Visual Studio 18 before the helper recognizes
that toolchain.

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
configuration from pushing branches or opening PRs if the workflow is copied
to `PowerShell/openssh-portable`.

| Secret | Used for | Agent access |
|---|---|---|
| `UPSTREAM_MERGE_TOKEN` | Trusted Windows jobs use it to push `vnext` and create/update the PR. For fork testing, use a `tgauth` user token that can update workflow files. | **None** |

If `UPSTREAM_MERGE_TOKEN` is absent, the jobs fall back to `github.token`.
The generated workflow manifest records this restricted secret and the pinned
action/container dependencies reviewed by `gh aw compile --approve`.

For fork testing, configure `UPSTREAM_MERGE_TOKEN` with permission to write
repository contents and workflow files and to create pull requests. Upstream
batches can modify `.github/workflows/**`; GitHub rejects those pushes when
they use the built-in GitHub App token, even when the job has
`contents: write`. A classic PAT needs `repo` and `workflow`; use the
equivalent repository Contents and Pull requests permissions for a fine-grained
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
- `skip_final_ci` — skip the final full CI suite.

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
