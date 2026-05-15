# Merge Upstream Prompt

Assist with merging the commits from upstream into this branch starting from the provided GitHub tag or commit.

Provide the following when you invoke this prompt:
- Start ref (tag or commit) — REQUIRED (e.g., `upstream/V_9_8_P1` or a commit SHA)
- End ref (commit) — OPTIONAL (default: HEAD - most recent upstream commit)
- CI grouping mode — REQUIRED (`presence` or `success`): controls how `Get-CommitGroups` determines batch boundaries.
  - `presence`: Batches end at any commit that has CI runs (passing or failing). Smaller batches, faster iteration, recommended for most merges.
  - `success`: Batches end only at commits with successful CI. Larger batches, fewer checkpoints, useful when upstream CI is mostly green and you want to minimize batch count.
- Upstream remote — optional (default: `upstream`)
- Windows fork remote — optional (default: `upstream-pwsh`)
- Target branch — optional (default: current branch)

Operating guidance:
- Use and follow merge-upstream.agent.md. Treat it as the primary operating guide.
- Rely on the provided <attachments> for repository overview, setup, build, merge strategy, and testing. Do not re-fetch or re-search them; assume they are already attached in context.
- Use the two-phase merge workflow: (1) incremental `git merge` on a scratch branch with resolution recording via `git rerere` and Save-MergeResolution, then (2) a single `git merge` on the real branch with resolution replay via `git rerere` and Replay-MergeResolutions. This preserves upstream commit history.
- Build using the MCP tools: `mcp_openssh-server_Start_OpenSSHBuild` (Release/x64 by default). If the build fails, analyze with `mcp_openssh-server_Test_OpenSSHBuild`.
- For validation, use `mcp_openssh-server_Test_OpenSSHFunctionality`.
- Apply Windows compatibility strategies as documented (prefer win32compat layer; guard with `#ifdef WINDOWS` when necessary; update VS projects for build system changes).
- Summarize a plan, request approval between batches, and clearly list conflict resolutions and rationale.

Expected outputs per batch:
- Planned commit range and rationale for the batch boundary
- Conflict resolutions (what, why, how), especially Windows-specific handling
- Build result summary and, on failure, parsed errors with applied fixes
- Next-step proposal and explicit ask to proceed

Quick start examples:
- "Merge from tag `upstream/V_9_8_P1` into my current branch."
- "Merge from tag `upstream/V_9_8_P1` to commit `a1b2c3d` into my current branch."
- "Merge starting at commit `3a1b2c3`, upstream remote `upstream`, target current branch."
- "Merge from tag `upstream/V_10_0_P2` to `upstream/V_10_3_P1`."

If the Start ref is not provided, ask for it before proceeding.
If the End ref is not provided, merging will continue to HEAD (most recent upstream commit).
If the CI grouping mode is not provided, ask the user to choose between `presence` (default recommendation) and `success` before invoking `Get-CommitGroups`.
