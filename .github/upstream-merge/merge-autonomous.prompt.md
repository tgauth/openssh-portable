---
name: merge-autonomous
description: Non-interactive (CI) task prompt for the merge-upstream agent. Used by the weekly upstream-merge GitHub workflow to resolve one specific problem (conflicts or a build break) without any human in the loop.
---
# Autonomous merge task (CI mode)

You are running **headlessly inside a GitHub Actions runner** as the
`merge-upstream` agent. A scheduled workflow has already:

- checked out the `vnext` integration branch,
- started `git merge --no-ff` of an upstream OpenSSH batch, and
- handed this single, focused task to you.

Follow the repository's own merge guidance as your operating manual:

- `.github/agents/merge-upstream.agent.md` — primary operating guide
- `.github/instructions/merge/merge-details.instructions.md` — conflict-resolution patterns and Windows-compatibility decision trees
- `.github/instructions/merge/merge-process-overview.instructions.md` — end-to-end process
- `.github/instructions/build.instructions.md` — build + warning policy

## Task

- **Mode:** `<<MODE>>`  (`conflicts` = resolve current merge conflicts; `build` = fix the current build break)
- **Attempt:** `<<ATTEMPT>>`
- **Batch:** `<<BATCH>>`
- **Details:**

<<DETAILS>>

## Non-negotiable rules for CI mode

1. **Never pause for human input.** There is no human to answer. Do not ask
   questions, do not wait for approval — make the best defensible decision and
   proceed. (This overrides any "wait for user approval" guidance in the
   interactive instructions.)
2. **Stay in scope.** Only address the specific task above:
   - `conflicts` mode: resolve every conflicted file in the working tree and
     stage the results (`git add`). Do **not** run `git commit`,
     `git merge --continue`, or `git merge --abort` — the workflow finalizes the
     merge commit itself. Do **not** start merging additional batches.
   - `build` mode: use `Test-OpenSSHBuild` to parse the latest errors, fix them
     following the established Windows-compatibility patterns (prefer the
     `win32compat` layer; guard with `#ifdef WINDOWS` where appropriate; update
     the Visual Studio project/solution files when the build system changes),
     then rebuild with `Start-OpenSSHBuild` until it succeeds. Leave your fixes
     as **unstaged/uncommitted** working-tree changes — the workflow commits
     them.
3. **Do not push, force-push, open PRs, or touch any branch other than the one
   currently checked out.**
4. **Do not commit** `contrib/win32/openssh/paths.targets` (machine-specific
   churn); the workflow restores it.
5. **Prefer the repository's MCP-equivalent tool scripts** under `.github/tools`
   (`Start-OpenSSHBuild.ps1`, `Test-OpenSSHBuild.ps1`, `Get-ConflictContext.ps1`,
   `Test-MergeConflictMarkers.ps1`, …) over ad-hoc commands.

## Document every decision (required)

Because a human always reviews this run, append a concise, honest record of what
you did and **why** to the decision log file at:

    <<DECISION_LOG>>

For each meaningful decision, append a short Markdown section, for example:

```markdown
### Batch <<BATCH>> — <file or symbol>
- **Situation:** what conflicted / what broke
- **Decision:** what you chose (which side, how you combined them, what you guarded)
- **Rationale:** why this is correct for the Windows fork
- **Confidence:** high | medium | low
- **Follow-up for reviewer:** anything a human should double-check (or "none")
```

Be especially explicit and mark **Confidence: low** whenever you are unsure, had
to guess upstream intent, or dropped/changed Windows-specific behavior. It is
better to flag a risky resolution for the reviewer than to hide it.

## When you cannot finish

If you cannot fully resolve the task on this attempt, still record what you tried
and what remains in the decision log, then stop. The workflow will retry (up to
its attempt cap) and, if still unresolved, stop and hand the branch to a human —
your notes are what they will read first.
