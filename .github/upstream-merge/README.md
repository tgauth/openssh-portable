# Weekly upstream merge (automated)

This folder holds the automation that turns the interactive **`merge-upstream`**
VS Code Copilot Chat agent into a scheduled GitHub Actions workflow.

| File | Purpose |
|---|---|
| [`../workflows/merge-upstream-weekly.yml`](../workflows/merge-upstream-weekly.yml) | The GitHub Actions workflow (schedule + manual dispatch). |
| [`Invoke-WeeklyUpstreamMerge.ps1`](./Invoke-WeeklyUpstreamMerge.ps1) | Non-interactive driver that orchestrates the whole run. |
| [`merge-autonomous.prompt.md`](./merge-autonomous.prompt.md) | CI-mode prompt handed to the agent (Copilot CLI) for one focused fix. |

## What it does

Once per week the workflow:

1. Fetches `upstream` (openssh/openssh-portable) and `origin`.
2. Ensures a long-lived **`vnext`** integration branch exists — created from
   **`latestw_all`** on the first run, then reused and added to every week.
3. Merges the next batch(es) of upstream commits into `vnext`
   (`git merge --no-ff`), where a batch is chosen by
   [`Get-CommitGroups.ps1`](../tools/Get-CommitGroups.ps1) using CI-presence
   grouping. Up to `MaxBatchesPerRun` batches per run (default **4**).
4. For each batch:
   - **Conflicts** → the `merge-upstream` agent resolves them, retrying up to
     `MaxAgentAttempts` (default **3**). If still unresolved, the batch is
     aborted and the run stops for a human.
   - **Simple validation** → if the batch touched `*.c`/`*.h`, it builds
     (`Start-OpenSSHBuild.ps1`). Build breaks are fixed agentically (same retry
     cap). Batches that only touch docs/scripts skip the build.
5. After the week's batches are in and green, runs the **full CI suite**
   ([`Invoke-OpenSSHTests.ps1`](../tools/Invoke-OpenSSHTests.ps1)) once.
6. Pushes `vnext` and opens/updates a **pull request `vnext` → `latestw_all`**
   whose body is the full run report + agent decision log.

Every run — success or failure — is **always reviewed by a human** via that PR.
The workflow never merges the PR and never force-pushes.

Promoting `vnext` → `latestw_all` on an upstream release is a **separate, manual
process** and is intentionally not automated here.

## Runner & tooling

- Runs on GitHub-hosted **`windows-latest`**, mirroring the Azure DevOps
  pipeline in [`.azdo/ci.yml`](../../.azdo/ci.yml) (Visual Studio + vcpkg).
- Reuses the existing merge tool scripts in [`.github/tools`](../tools) — the
  same ones the VS Code agent calls via its MCP server, just invoked directly.
- The intelligent steps go through the **GitHub Copilot CLI**
  (`@github/copilot`), driven by [`merge-autonomous.prompt.md`](./merge-autonomous.prompt.md)
  and the on-repo merge instructions/agent definitions.

## ⚠️ Scheduling caveat

GitHub only fires a `schedule:` trigger from a repository's **default branch**
(`latestw_all`). While this workflow lives only on `latestw_all_copilot`, the
weekly cron will **not** fire automatically — run it manually with the
**Run workflow** button (`workflow_dispatch`) against `latestw_all_copilot`.
Once `latestw_all_copilot` is merged into `latestw_all`, the weekly schedule
activates on its own.

## Required secrets

| Secret | Used for | Fallback |
|---|---|---|
| `COPILOT_CLI_TOKEN` | Authenticates the Copilot CLI (needs Copilot access). | `github.token` (may lack Copilot entitlement → agent steps no-op). |
| `UPSTREAM_MERGE_TOKEN` | Push `vnext` + open the PR; a PAT/app token lets the push re-trigger downstream checks. | `github.token`. |

If `COPILOT_CLI_TOKEN` is missing or the CLI can't run, the agentic steps are
skipped and the run is flagged **needs human** rather than failing hard.

## Manual dispatch inputs

- `upstream_ref` — merge up to a specific upstream ref (blank = upstream tip).
- `max_batches` — batches to merge this run (default 4).
- `max_agent_attempts` — agent retries per failing step (default 3).
- `skip_agent` — deterministic dry-run; skips all agent calls.
- `skip_final_ci` — skip the final full CI suite.

## Local dry-run

From a Windows checkout that has the toolkit (e.g. `latestw_all_copilot`):

```powershell
# Stage a toolkit dir the same way the workflow does, then:
pwsh -NoProfile -File .github/upstream-merge/Invoke-WeeklyUpstreamMerge.ps1 `
    -ToolkitDir <staged-toolkit-dir> `
    -SkipAgent -SkipFinalCI -MaxBatchesPerRun 1
```

`-SkipAgent` keeps it fully deterministic (no Copilot calls); it will merge only
cleanly-merging batches and flag anything that needs the agent.
