---
name: Weekly upstream merge
description: Incrementally merge successful upstream OpenSSH batches into vnext with bounded agentic remediation and deterministic Windows validation.

on:
  schedule:
    - cron: "0 8 * * 1"
  workflow_dispatch:
    inputs:
      upstream_ref:
        description: "Upstream ref to merge up to (blank = upstream default branch tip)"
        required: false
        default: ""
      max_batches:
        description: "Max batches to merge in this run"
        required: false
        default: "4"
      max_agent_attempts:
        description: "Max reasoning attempts inside the bounded remediation"
        required: false
        default: "3"
      skip_agent:
        description: "Deterministic dry-run: do not run remediation"
        type: boolean
        required: false
        default: false
      skip_final_ci:
        description: "Skip the final full CI suite"
        type: boolean
        required: false
        default: false

concurrency:
  group: weekly-upstream-merge
  cancel-in-progress: false
  job-discriminator: ${{ github.run_id }}

permissions:
  contents: read
  copilot-requests: write

engine: copilot
timeout-minutes: 60

tools:
  edit:
  bash:
    - git
    - jq
    - base64
    - python3
    - mkdir
    - cat
    - printf

checkout:
  fetch-depth: 0

jobs:
  prepare:
    name: Prepare deterministic merge
    if: github.repository == 'tgauth/openssh-portable'
    runs-on: windows-latest
    timeout-minutes: 360
    permissions:
      contents: write
      pull-requests: write
    outputs:
      batches_merged: ${{ steps.merge.outputs.batches_merged }}
      remediation_required: ${{ steps.merge.outputs.remediation_required }}
      needs_human: ${{ steps.merge.outputs.needs_human }}
      ci_status: ${{ steps.merge.outputs.ci_status }}
      vnext_branch: ${{ steps.merge.outputs.vnext_branch }}
      target_branch: ${{ steps.merge.outputs.target_branch }}
    env:
      UPSTREAM_REMOTE: upstream
      UPSTREAM_URL: https://github.com/openssh/openssh-portable.git
      VNEXT_BRANCH: vnext
      TARGET_BRANCH: merge-v10.6P1
      ARCHITECTURE: x64
      GH_TOKEN: ${{ secrets.UPSTREAM_MERGE_TOKEN || github.token }}
      GITHUB_TOKEN: ${{ secrets.UPSTREAM_MERGE_TOKEN || github.token }}
      INPUT_UPSTREAM_REF: ${{ inputs.upstream_ref }}
      INPUT_MAX_BATCHES: ${{ inputs.max_batches || '4' }}
      INPUT_MAX_AGENT_ATTEMPTS: ${{ inputs.max_agent_attempts || '3' }}
      INPUT_SKIP_AGENT: ${{ inputs.skip_agent || false }}
      INPUT_SKIP_FINAL_CI: ${{ inputs.skip_final_ci || false }}
    steps:
      - name: Checkout workflow branch
        uses: actions/checkout@v7
        with:
          fetch-depth: 0
          token: ${{ secrets.UPSTREAM_MERGE_TOKEN || github.token }}

      - name: Stage merge toolkit
        shell: pwsh
        run: |
          $dst = Join-Path $env:RUNNER_TEMP 'merge-toolkit'
          New-Item -ItemType Directory -Force -Path $dst | Out-Null
          Copy-Item -Recurse -Force '.github/tools' (Join-Path $dst 'tools')
          Copy-Item -Force '.github/upstream-merge/Invoke-WeeklyUpstreamMerge.ps1' $dst
          Copy-Item -Force '.github/upstream-merge/Apply-AgentRemediation.ps1' $dst
          "TOOLKIT_DIR=$dst" | Out-File -FilePath $env:GITHUB_ENV -Append

      - name: Configure upstream remote
        shell: pwsh
        run: |
          gh auth setup-git
          if ((git remote) -notcontains $env:UPSTREAM_REMOTE) {
            git remote add $env:UPSTREAM_REMOTE $env:UPSTREAM_URL
          } else {
            git remote set-url $env:UPSTREAM_REMOTE $env:UPSTREAM_URL
          }
          git fetch $env:UPSTREAM_REMOTE --prune --tags

      - name: Prepare merge or remediation request
        id: merge
        continue-on-error: true
        shell: pwsh
        run: |
          $args = @(
            '-ToolkitDir', $env:TOOLKIT_DIR,
            '-UpstreamRemote', $env:UPSTREAM_REMOTE,
            '-VNextBranch', $env:VNEXT_BRANCH,
            '-TargetBranch', $env:TARGET_BRANCH,
            '-Architecture', $env:ARCHITECTURE,
            '-MaxBatchesPerRun', $env:INPUT_MAX_BATCHES,
            '-MaxAgentAttempts', $env:INPUT_MAX_AGENT_ATTEMPTS,
            '-UpstreamRef', $env:INPUT_UPSTREAM_REF,
            '-ReportPath', (Join-Path $env:RUNNER_TEMP 'merge-report.md'),
            '-RemediationRequestPath', (Join-Path $env:RUNNER_TEMP 'remediation-request.json')
          )
          if ($env:INPUT_SKIP_AGENT -eq 'true') { $args += '-SkipAgent' }
          if ($env:INPUT_SKIP_FINAL_CI -eq 'true') { $args += '-SkipFinalCI' }
          & pwsh -NoProfile -File (Join-Path $env:TOOLKIT_DIR 'Invoke-WeeklyUpstreamMerge.ps1') @args
          exit $LASTEXITCODE

      - name: Upload preparation state
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: upstream-merge-preparation
          path: |
            ${{ runner.temp }}/merge-report.md
            ${{ runner.temp }}/remediation-request.json
          if-no-files-found: warn
          retention-days: 7

      - name: Reject unexpected preparation failure
        if: always() && steps.merge.outcome == 'failure' && steps.merge.outputs.needs_human != 'true'
        shell: pwsh
        run: |
          Write-Host '::error::The preparation driver failed before producing a bounded result.'
          exit 1

      - name: Upload deterministic run report
        if: always() && steps.merge.outputs.remediation_required != 'true'
        uses: actions/upload-artifact@v7
        with:
          name: weekly-upstream-merge-report
          path: ${{ runner.temp }}/merge-report.md
          if-no-files-found: warn

      - name: Open or update review pull request
        if: steps.merge.outputs.remediation_required != 'true' && steps.merge.outputs.batches_merged != '' && steps.merge.outputs.batches_merged != '0'
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.UPSTREAM_MERGE_TOKEN || github.token }}
          VNEXT_BRANCH: ${{ steps.merge.outputs.vnext_branch }}
          TARGET_BRANCH: ${{ steps.merge.outputs.target_branch }}
          NEEDS_HUMAN: ${{ steps.merge.outputs.needs_human }}
          CI_STATUS: ${{ steps.merge.outputs.ci_status }}
          REPORT_PATH: ${{ runner.temp }}/merge-report.md
        run: |
          $body = (Test-Path $env:REPORT_PATH) ? (Get-Content -Raw $env:REPORT_PATH) : 'No report produced.'
          $flag = ($env:NEEDS_HUMAN -eq 'true') ? 'ATTENTION NEEDED' : 'ready for review'
          $title = "Weekly upstream merge into $env:VNEXT_BRANCH (CI: $env:CI_STATUS) - $flag"
          $existing = gh pr list --head $env:VNEXT_BRANCH --base $env:TARGET_BRANCH --state open --json number --jq '.[0].number'
          if ([string]::IsNullOrWhiteSpace($existing)) {
            $body | gh pr create --head $env:VNEXT_BRANCH --base $env:TARGET_BRANCH --title $title --body-file -
          } else {
            $body | gh pr edit $existing --title $title --body-file -
          }

      - name: Reflect deterministic status
        if: always() && steps.merge.outputs.remediation_required != 'true'
        shell: pwsh
        env:
          NEEDS_HUMAN: ${{ steps.merge.outputs.needs_human }}
        run: |
          if ($env:NEEDS_HUMAN -eq 'true') {
            Write-Host '::warning::The merge needs human attention.'
            exit 1
          }

  agent:
    needs: prepare
    if: needs.prepare.outputs.remediation_required == 'true'
    timeout-minutes: 75

  continue-remediation:
    name: Validate and apply remediation
    needs: [prepare, agent, detection, publish_remediation]
    if: always() && needs.prepare.outputs.remediation_required == 'true'
    runs-on: windows-latest
    timeout-minutes: 360
    permissions:
      contents: write
      pull-requests: write
    env:
      VNEXT_BRANCH: vnext
      TARGET_BRANCH: merge-v10.6P1
      GH_TOKEN: ${{ secrets.UPSTREAM_MERGE_TOKEN || github.token }}
      INPUT_SKIP_FINAL_CI: ${{ inputs.skip_final_ci || false }}
    steps:
      - name: Checkout workflow branch
        uses: actions/checkout@v7
        with:
          fetch-depth: 0
          token: ${{ secrets.UPSTREAM_MERGE_TOKEN || github.token }}

      - name: Download preparation state
        uses: actions/download-artifact@v8
        with:
          name: upstream-merge-preparation
          path: ${{ runner.temp }}/merge-input

      - name: Download agent remediation
        continue-on-error: true
        uses: actions/download-artifact@v8
        with:
          name: upstream-merge-remediation
          path: ${{ runner.temp }}/agent-remediation

      - name: Stage merge toolkit
        shell: pwsh
        run: |
          gh auth setup-git
          $dst = Join-Path $env:RUNNER_TEMP 'merge-toolkit'
          New-Item -ItemType Directory -Force -Path $dst | Out-Null
          Copy-Item -Recurse -Force '.github/tools' (Join-Path $dst 'tools')
          Copy-Item -Force '.github/upstream-merge/Apply-AgentRemediation.ps1' $dst
          "TOOLKIT_DIR=$dst" | Out-File -FilePath $env:GITHUB_ENV -Append

      - name: Apply and validate agent remediation
        id: apply
        continue-on-error: true
        shell: pwsh
        run: |
          $args = @(
            '-ToolkitDir', $env:TOOLKIT_DIR,
            '-RequestPath', (Join-Path $env:RUNNER_TEMP 'merge-input/remediation-request.json'),
            '-BundleDir', (Join-Path $env:RUNNER_TEMP 'agent-remediation'),
            '-ReportPath', (Join-Path $env:RUNNER_TEMP 'merge-input/merge-report.md'),
            '-VNextBranch', $env:VNEXT_BRANCH,
            '-TargetBranch', $env:TARGET_BRANCH
          )
          if ($env:INPUT_SKIP_FINAL_CI -eq 'true') { $args += '-SkipFinalCI' }
          & pwsh -NoProfile -File (Join-Path $env:TOOLKIT_DIR 'Apply-AgentRemediation.ps1') @args
          exit $LASTEXITCODE

      - name: Upload final report
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: weekly-upstream-merge-report
          path: ${{ runner.temp }}/merge-input/merge-report.md
          if-no-files-found: warn

      - name: Open or update review pull request
        if: always()
        shell: pwsh
        env:
          GH_TOKEN: ${{ secrets.UPSTREAM_MERGE_TOKEN || github.token }}
          NEEDS_HUMAN: ${{ steps.apply.outputs.needs_human || 'true' }}
          CI_STATUS: ${{ steps.apply.outputs.ci_status || 'not-run' }}
          REPORT_PATH: ${{ runner.temp }}/merge-input/merge-report.md
        run: |
          git fetch origin --prune
          git rev-parse --verify --quiet "origin/$env:VNEXT_BRANCH"
          if ($LASTEXITCODE -ne 0) {
            Write-Host '::warning::vnext was not pushed; the report artifact is the handoff.'
            exit 0
          }
          $ahead = git rev-list --count "origin/$env:TARGET_BRANCH..origin/$env:VNEXT_BRANCH"
          if ($LASTEXITCODE -ne 0 -or [int]$ahead -eq 0) {
            Write-Host '::warning::vnext has no commits beyond the target branch; no pull request can be opened.'
            exit 0
          }
          $body = (Test-Path $env:REPORT_PATH) ? (Get-Content -Raw $env:REPORT_PATH) : 'No report produced.'
          $flag = ($env:NEEDS_HUMAN -eq 'true') ? 'ATTENTION NEEDED' : 'ready for review'
          $title = "Weekly upstream merge into $env:VNEXT_BRANCH (CI: $env:CI_STATUS) - $flag"
          $existing = gh pr list --head $env:VNEXT_BRANCH --base $env:TARGET_BRANCH --state open --json number --jq '.[0].number'
          if ([string]::IsNullOrWhiteSpace($existing)) {
            $body | gh pr create --head $env:VNEXT_BRANCH --base $env:TARGET_BRANCH --title $title --body-file -
          } else {
            $body | gh pr edit $existing --title $title --body-file -
          }

      - name: Reflect remediation status
        if: always()
        shell: pwsh
        env:
          NEEDS_HUMAN: ${{ steps.apply.outputs.needs_human || 'true' }}
        run: |
          if ($env:NEEDS_HUMAN -eq 'true') {
            Write-Host '::warning::Remediation could not be completed; see the report artifact for the schema, apply, build, or CI failure.'
            exit 1
          }

safe-outputs:
  jobs:
    publish-remediation:
      description: Publish exactly one bounded upstream-merge remediation bundle for deterministic Windows validation.
      runs-on: ubuntu-latest
      artifacts:
        - /tmp/gh-aw/agent/remediation/
      inputs:
        status:
          description: Must be resolved when a complete bundle is ready, otherwise unresolved.
          required: true
          type: choice
          options: [resolved, unresolved]
        summary:
          description: Concise description of the result or remaining blocker.
          required: true
          type: string
      steps:
        - name: Validate and stage remediation bundle
          shell: bash
          run: |
            set -euo pipefail
            root="$(dirname "$GH_AW_AGENT_OUTPUT")"
            source_dir="$root/agent/remediation"
            item_count="$(jq '[.items[] | select(.type == "publish_remediation")] | length' "$GH_AW_AGENT_OUTPUT")"
            test "$item_count" -eq 1
            test -f "$source_dir/result.json"
            mkdir -p "$RUNNER_TEMP/upstream-merge-remediation"
            cp -R "$source_dir/." "$RUNNER_TEMP/upstream-merge-remediation/"

        - name: Upload remediation bundle
          uses: actions/upload-artifact@v7
          with:
            name: upstream-merge-remediation
            path: ${{ runner.temp }}/upstream-merge-remediation
            if-no-files-found: error
            retention-days: 7

steps:
  - name: Download preparation state
    uses: actions/download-artifact@v4
    with:
      name: upstream-merge-preparation
      path: /tmp/gh-aw/agent/input

  - name: Recreate the requested repository state
    shell: bash
    run: |
      set -euo pipefail
      request=/tmp/gh-aw/agent/input/remediation-request.json
      test -f "$request"
      expected_head="$(jq -r .expectedHead "$request")"
      batch_end="$(jq -r .batchEnd "$request")"
      mode="$(jq -r .mode "$request")"
      upstream_url="$(jq -r .upstreamUrl "$request")"
      git remote remove upstream 2>/dev/null || true
      git remote add upstream "$upstream_url"
      git fetch upstream --prune --tags
      git fetch origin "+refs/heads/vnext:refs/remotes/origin/vnext"
      git checkout --detach "$expected_head"
      git config --local user.email 'openssh-merge-bot@users.noreply.github.com'
      git config --local user.name 'OpenSSH Upstream Merge Bot'
      if [ "$mode" = conflicts ]; then
        git merge --no-ff --no-commit "$batch_end" || test -n "$(git diff --name-only --diff-filter=U)"
      fi
      mkdir -p /tmp/gh-aw/agent/remediation
---

# Resolve one bounded upstream-merge failure

The deterministic Windows preparation job stopped at the first operation that
needed reasoning. Read `/tmp/gh-aw/agent/input/remediation-request.json` and
resolve only that request. The repository has already been checked out at the
request's exact `expectedHead`; for conflict mode, the same merge has also been
recreated.

You may make up to the request's `maxAttempts` focused reasoning/editing passes.
Do not push, commit, create branches, open pull requests, or broaden the task.
Do not modify `contrib/win32/openssh/paths.targets`.

## Required output

Create `/tmp/gh-aw/agent/remediation/result.json` with:

```json
{
  "schemaVersion": 1,
  "status": "resolved",
  "mode": "conflicts",
  "expectedHead": "<exact request value>",
  "batchEnd": "<exact request value>",
  "summary": "<concise result>"
}
```

Use `"status": "unresolved"` when you cannot produce a defensible complete
solution. Always create `/tmp/gh-aw/agent/remediation/decision-log.md` describing
the situation, decision, rationale, confidence, and reviewer follow-up.

For **conflicts**:

1. Resolve every path listed in `conflictedFiles` and stage the result.
2. Do not commit the merge.
3. Create `/tmp/gh-aw/agent/remediation/resolved-files.json`:

```json
{
  "schemaVersion": 1,
  "files": [
    {"path": "relative/path", "action": "write", "contentBase64": "..."},
    {"path": "deleted/path", "action": "delete"}
  ]
}
```

Include every requested conflicted path exactly once and no other paths.

For **build**:

1. Use the captured `buildLog`, source, and Windows compatibility patterns to
   make the smallest defensible source fix.
2. Do not claim to have rebuilt on Linux; the continuation job performs the
   authoritative Windows build.
3. Write the proposed changes with:
   `git diff --binary > /tmp/gh-aw/agent/remediation/remediation.patch`.

Finally call `publish_remediation` exactly once with the same status and a
concise summary. The Windows continuation job independently verifies the
manifest, immutable SHAs, paths, patch, build, and full CI. Missing, malformed,
unsafe, timed-out, or unvalidated output becomes a bounded `needs-human`
handoff rather than waiting or retrying indefinitely.
