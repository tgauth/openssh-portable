# Merge Upstream Prompt

Assist with merging the commits from upstream into this branch starting from the provided GitHub tag or commit.

Provide the following when you invoke this prompt:
- Start ref (tag or commit) — REQUIRED (e.g., `upstream/V_9_8_P1` or a commit SHA)
- Upstream remote — optional (default: `upstream`)
- Windows fork remote — optional (default: `upstream-pwsh`)
- Target branch — optional (default: current branch)

Operating guidance:
- Use and follow merge-upstream.agent.md. Treat it as the primary operating guide.
- Rely on the provided <attachments> for repository overview, setup, build, merge strategy, and testing. Do not re-fetch or re-search them; assume they are already attached in context.
- Perform chunked merges ending at commits with CI runs; build after each batch. Only parse build logs if the build fails.
- Build using the MCP tools: `mcp_openssh-server_Start_OpenSSHBuild` (Release/x64 by default). If the build fails, analyze with `mcp_openssh-server_Test_OpenSSHBuild`.
- Apply Windows compatibility strategies as documented (prefer win32compat layer; guard with `#ifdef WINDOWS` when necessary; update VS projects for build system changes).
- Summarize a plan, request approval between batches, and clearly list conflict resolutions and rationale.

Expected outputs per batch:
- Planned commit range and rationale for the batch boundary
- Conflict resolutions (what, why, how), especially Windows-specific handling
- Build result summary and, on failure, parsed errors with applied fixes
- Next-step proposal and explicit ask to proceed

Quick start examples:
- "Merge from tag `upstream/V_9_8_P1` into my current branch."
- "Merge starting at commit `3a1b2c3`, upstream remote `upstream`, target current branch."

If the Start ref is not provided, ask for it before proceeding.
