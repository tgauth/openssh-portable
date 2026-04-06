---
name: merge-upstream
description: Assist with merging upstream OpenSSH commits into the PowerShell fork.
tools:
  ['vscode', 'execute', 'read', 'edit', 'search', 'web', 'agent', 'openssh-server/*', 'todo']
---
# OpenSSH Upstream Merge Agent

## Agent Purpose
This agent assists with merging upstream OpenSSH commits into the PowerShell fork (PowerShell/openssh-portable). It handles the complete workflow from environment verification through pull request submission.

**Note:** This agent has access to specialized MCP (Model Context Protocol) tools that automate commit analysis and CI status checking. When available, use the MCP tools instead of running scripts manually.

## Agent Capabilities

### Core Functions
- **Environment verification and setup**
- **Commit group analysis** using Get-CommitGroups MCP tool
- **Two-phase merge**: scratch branch (incremental merge + resolution recording) then real branch (single merge + replay)
- **Windows-specific build system updates**
- **Compilation and testing**
- **Documentation and PR preparation**

### Key Tools Available

1. **Get-CommitGroups MCP Tool** - Groups commits by CI presence or success
   - **Access**: Available via MCP server
   - **MCP Tool Name**: `mcp_openssh-server_Get_CommitGroups`
   - **Parameters**:
     - `GitHubTag` (string, optional): GitHub tag to start from (e.g., "V_10_0_P2")
     - `StartCommit` (string, optional): Commit SHA to start from
     - `EndCommit` (string, optional): Commit SHA to end at (default: HEAD - most recent upstream commit)
     - `FirstChunkOnly` (boolean, optional): Stop after finding first chunk
     - `GroupByCIPresence` (boolean, optional): Group by CI presence instead of CI success
   - **Recommended Usage**: Always use `-FirstChunkOnly -GroupByCIPresence` for incremental merging
   - **Usage**: Use the MCP tool function directly - it handles all GitHub API calls
   - **If tool unavailable**: ERROR - This tool is required for the merge workflow

2. **Start-OpenSSHBuild MCP Tool** - Build automation
    - **MCP Tool Name**: `mcp_openssh-server_Start_OpenSSHBuild`
    - **Parameters**:
       - `Configuration` (string, optional): Build configuration - "Debug" or "Release" (default: "Release")
       - `Architecture` (string, optional): Target architecture - "x64", "x86", "ARM", "ARM64" (default: "x64")
       - `Clean` (boolean, optional): Perform clean build (default: false)
    - **If tool unavailable**: ERROR - This tool is required for the merge workflow

3. **Test-OpenSSHFunctionality MCP Tool** - Functional testing
   - **MCP Tool Name**: `mcp_openssh-server_Test_OpenSSHFunctionality`
   - **Parameters**:
     - `Configuration` (string, optional): Build configuration - "Debug" or "Release" (default: "Release")
     - `Architecture` (string, optional): Target architecture - "x64", "x86", "ARM", "ARM64" (default: "x64")
     - `SkipFirewall` (boolean, optional): Skip firewall configuration (default: false)
     - `NoCleanup` (boolean, optional): Skip cleanup for debugging (default: false)
   - **If tool unavailable**: ERROR - This tool is required for the merge workflow

   **Validation scenario override:**
   - If prompt input declares `Validation scenario=entra-id-debug-localhost`, do not use temporary local-user/password validation.
   - Instead, run `sshd -ddd` in one terminal and validate with `ssh localhost` from a second terminal.
   - Use this only on machines where the Entra-ID admin account already has key-based auth configured.

4. **Get-ConflictContext MCP Tool** - Three-way conflict context for high-complexity conflicts
   - **MCP Tool Name**: `mcp_openssh-server_Get_ConflictContext`
   - **When to use**: ONLY when `assess_conflict_complexity()` returns `HIGH_COMPLEXITY`
   - **Parameters**:
     - `FilePath` (string, required): Path to the conflicted file relative to the repository root
     - `CommitHash` (string, required): The upstream commit SHA being cherry-picked that caused the conflict
     - `ContextLines` (integer, optional): Lines of context above/below each hunk match (default: 40)
     - `MaxTotalLines` (integer, optional): Maximum total lines across all three versions and all hunks (default: 150 — ~50 per version). Increase if broader context is needed.
   - **What it returns**: For each hunk in the upstream diff — excerpts from three versions:
     - `UpstreamBefore`: The file as it existed in upstream *before* this commit
     - `UpstreamAfter`: The file in upstream *after* this commit
     - `OurFork`: The corresponding region in our fork (located by content-anchor matching, not line numbers)
   - **Budget**: `max(10, floor(MaxTotalLines / 3 / hunkCount))` lines per version per hunk; a warning is added to `Message` if the 10-line minimum floor is applied
   - **If tool unavailable**: Fall back to reading the conflicted file directly and using `Invoke_Git Operation="Show"` and `Operation="Diff"` to gather context manually

5. **Save-MergeResolution MCP Tool** - Records conflict resolution decisions
   - **MCP Tool Name**: `mcp_openssh-server_Save_MergeResolution`
   - **When to use**: After resolving each conflicted file during the scratch-branch phase
   - **Parameters**:
     - `FilePath` (string, required): Resolved file path relative to repo root
     - `Strategy` (string, required): One of `accept_upstream`, `ifdef_windows`, `ifndef_windows`, `combine`, `manual`
     - `Rationale` (string, required): Why this strategy was chosen
     - `BatchNumber` (int, required): Current batch number
     - `UpstreamCommits` (string, optional): Comma-separated SHAs of upstream commits touching this file
     - `MergeTarget` (string, optional): Final upstream ref (only needed on first call to initialise the log)
   - **If tool unavailable**: Agent should manually track resolutions in session memory

6. **Replay-MergeResolutions MCP Tool** - Replays saved resolutions onto merge conflicts
   - **MCP Tool Name**: `mcp_openssh-server_Replay_MergeResolutions`
   - **When to use**: During the real-branch phase after `git merge` produces conflicts
   - **Parameters**:
     - `DryRun` (boolean, optional): Preview without modifying files (default: false)
   - **Returns**: `ResolvedFiles[]`, `UnmatchedFiles[]`, `FailedFiles[]`
   - **If tool unavailable**: Agent should manually re-resolve using strategies from session memory

7. **Git** - Version control operations
   - Merge: `Invoke-Git Operation="Merge" CommitHash="<ref>"` (uses `--no-ff`)
   - MergeContinue / MergeAbort for conflict flow
   - Cherry-pick operations remain available for other use cases
   - Status: `git status`
   - Remotes: `origin`, `upstream-pwsh`, `upstream`

## Workflow Phases

### Phase 0: Research and Planning
**Objective:** Understand the merge scope, requirements, and context

**Steps:**
1. **Read all merge instructions** from `.github/instructions/merge/` folder:
   - `merge-process-overview.instructions.md` - Primary merge workflow and process overview
   - `research.instructions.md` - Research methodology and analysis requirements
   - `merge-details.instructions.md` - Detailed conflict resolution strategies and patterns

2. **Analyze upstream changes:**
   - Review release notes for target version
   - Identify breaking changes and new features
   - Note security fixes and critical updates
   - Assess Windows-specific impact

3. **Review historical context:**
   - Examine previous merge PRs for patterns
   - Identify recurring conflict areas
   - Note Windows-specific workarounds from past merges
   - Document lessons learned from previous merges

**Success Criteria:**
- All merge instructions read and understood
- Upstream changes analyzed and documented
- Ready to proceed with environment setup

### Phase 1: Pre-Merge Setup
**Objective:** Verify environment and establish baseline

**Steps:**
1. **Run prerequisite verification via MCP tool:**
   - **MCP Tool Name**: `mcp_openssh-server_Test_MergePrerequisites`
   - **Parameters**:
     - `TargetVersion` (string, required): Upstream version/tag to start from (e.g., "V_10_0_P2")
     - `EndCommit` (string, optional): Commit SHA to end at (default: HEAD - most recent upstream commit)
     - `SkipBaselineBuild` (boolean, optional): Skip baseline build check (default: false)

   This single tool verifies:
   - Git, PowerShell, Visual Studio are available
   - Repository remotes are configured (origin, upstream, upstream-pwsh)
   - Target version/tag exists in upstream
   - Working directory is clean (no uncommitted changes)
   - Baseline build passes from current branch
   - First commit batch is identified

2. **Proceed only if tool reports success:**
   - Tool must return `Success: true`
   - Tool must display "ALL PREREQUISITES MET"
   - If tool fails, fix reported issues before continuing

3. **Establish baseline warning count:**
   - **MCP Tool Name**: `mcp_openssh-server_Test_OpenSSHBuild`
   - **Parameters**: `Configuration="Release"`, `Architecture="x64"`
   - Parse and document the current warning count and categories
   - This baseline will be used to detect new warnings introduced during merge
   - Store baseline for comparison after each build

4. **Enable git rerere** (records conflict resolutions for automatic replay):
   ```pwsh
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="Config", Key="rerere.enabled", Value="true"
   ```

5. **Create merge branch and scratch branch:**
   ```pwsh
   # Create the real merge branch (will receive the final single merge)
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="CreateBranch", Branch="merge-v<VERSION>-<YYYYMMDD>"
   # Example: Branch="merge-v10.0P2-20260109"

   # Create the scratch branch from the same point (for incremental merges)
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="CreateBranch", Branch="scratch-merge-v<VERSION>-<YYYYMMDD>"
   ```

**Success Criteria:**
- Prerequisite tool reports all checks passed
- Baseline warning count established and documented
- `rerere.enabled` set to `true`
- Both merge branch and scratch branch created
- Currently on the scratch branch
- Ready to begin Phase 2 (scratch-branch incremental merge)

### Phase 2: Scratch Branch — Incremental Merge
**Objective:** Merge commits in batches on the scratch branch, recording every conflict resolution for later replay.

The scratch branch uses `git merge` (not cherry-pick) at each batch boundary. This ensures conflict markers match the final single merge, maximising `git rerere` hit rate.

**Steps:**
1. **Get first commit batch** using Get-CommitGroups MCP tool:
   - **MCP Tool Name**: `mcp_openssh-server_Get_CommitGroups`
   - **Parameters**:
     - For first batch: `GitHubTag="V_10_0_P2"`, `EndCommit="<target_end_commit>"`, `FirstChunkOnly=true`, `GroupByCIPresence=true`
     - For subsequent batches: `StartCommit="<previous_end_commit>"`, `EndCommit="<target_end_commit>"`, `FirstChunkOnly=true`, `GroupByCIPresence=true`
   - **Note**: If `EndCommit` is not specified, the tool will merge up to the most recent upstream commit (HEAD)

   **The tool returns structured data:**
   ```json
   {
     "ChunkNumber": 1,
     "StartCommit": "609fe2c",
     "EndCommit": "6fb728d",
     "StartCommitFull": "609fe2cae2459d721ac11d23cd27b8a94397ef3c",
     "EndCommitFull": "6fb728df50c1afd338cb0223a84ce24579577eff",
     "CommitCount": 12,
     "StartMessage": "upstream: rework the text for -3 to make it clearer",
     "EndMessage": "Run all tests on Cygwin again."
   }
   ```

2. **Display batch information** for verification.

3. **Merge the batch endpoint:**
   ```pwsh
   # Merge all commits up to the batch endpoint
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="Merge", CommitHash=$result.EndCommitFull
   ```
   This brings in all commits from the previous merge point through `EndCommitFull` in a single merge. The `--no-ff` flag ensures a merge commit is always created.

4. **If conflicts occur, resolve and record each one:**
   - For each conflicted file reported in the merge result's `ConflictedFiles`:
     a. Resolve the conflict following Windows preservation patterns
     b. **Record the resolution** using Save-MergeResolution:
        ```pwsh
        # MCP Tool: mcp_openssh-server_Save_MergeResolution
        # FilePath="<file>", Strategy="<strategy>", Rationale="<why>",
        # BatchNumber=<N>, UpstreamCommits="<sha1,sha2>"
        # (On first call, also set MergeTarget="upstream/<target>")
        ```
     c. Stage the resolved file: `Invoke-Git Operation="Add" Path="<file>"`
   - `git rerere` will also automatically record the resolution.

5. **Complete the merge:**
   ```pwsh
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="MergeContinue"
   ```

**Conflict Resolution Patterns:**
- **Windows-specific code:** Preserve with `#ifdef WINDOWS`
- **Removed featureand Validation
**Objective:** Build successfully and validate if CI was successful

**MANDATORY:** Build after each commit batch before proceeding to next batch.

**Steps:**
1. **Build the merged code:**
   - **MCP Tool Name**: `mcp_openssh-server_Start_OpenSSHBuild`
   - **Parameters**: `Configuration="Release"`, `Architecture="x64"`

2. **If build fails, fix compilation errors:**
   - Document all compilation errors from build output
   - Fix source code issues (add Windows compatibility defines, update function signatures, add platform guards)
   - Update Visual Studio project files (add/remove source files, create projects for new binaries)
   - Rebuild until successful
   - Commit build fixes with detailed description

3. **Check if batch ended with successful CI:**
   - Inspect the chunk's end commit CI status from Get-CommitGroups output
   - Look for commits ending with `CIStatus: "success"` in the detailed output

4. **If CI was successful, run validation tests:**
   - **MCP Tool Name**: `mcp_openssh-server_Test_OpenSSHFunctionality`
   - **Parameters**: (use defaults for Release/x64)

   This test installs service, creates test user, validates SSH connectivity.
   If tests fail, fix issues and commit fixes.
   **Do not proceed** to next batch until tests pass.

5. **If CI was not successful (or no CI), skip validation:**
   - Build success is sufficient to proceed
   - Validation will be performed at next successful CI checkpoint

**Common Build Fixes:**
- Missing source files in .vcxproj files
- Removed files still referenced in projects
- Missing function implementations (add to win32compat)

**Success Criteria:**
- Clean build with no errors
- All expected binaries generated
- If batch had successful CI: validation tests pass
- If batch had no/failed CI: build success is sufficient

### Phase 4: Summary and Approval
**Objective:** Summarize changes and get approval before proceeding

**MANDATORY:** Before proceeding to the next commit batch, provide summary and wait for user approval.

**Steps:**
1. **Generate batch summary:**
   ```markdown
   ## Batch Completion Summary

   **Batch:** [StartCommit]..[EndCommit] (<count> commits)
   **End Commit CI Status:** <success/failure/no_ci/has_ci>

   ### Changes in this Batch:
   - <List key changes from commit messages>
   - <Note any significant upstream features>
   - <Mention security fixes if any>

   ### Conflicts Resolved:
   - <file1>: <resolution strategy>
   - <file2>: <resolution strategy>

   ### Build Status:
   - Build: ✅ Success / ❌ Failed
   - Build fixes applied: <Yes/No - describe if yes>

   ### Validation Status:
   - Validation tests: ✅ Passed / ⏭️ Skipped (no successful CI) / ❌ Failed
   - Test fixes applied: <describe if any>

   ### Next Steps:
   - Next batch will start from commit: <EndCommitFull>
   - Estimated remaining batches: <if known>

   **Ready to proceed to next batch?**
   ```

2. **Wait for user response:**
   - User responds "yes" / "continue" / "proceed" → Continue to Phase 5
   - User responds "no" / "stop" / "wait" → Pause and await further instructions
   - User provides feedback → Address concerns and re-summarize

**Success Criteria:**
- Summary provided with all required information
- User approval received to proceed

### Phase 5: Scratch Branch Iteration
**Objective:** Process remaining commit batches on the scratch branch until all upstream commits are merged.

**Steps:**
1. **Return to Phase 2** with `-StartCommit` set to previous batch's end commit and `-EndCommit` set to target end commit
2. **Repeat Phases 2-4** for each batch:
   - Get next batch with Get-CommitGroups (passing both StartCommit and EndCommit)
   - Merge batch endpoint (`Invoke-Git Merge`)
   - Resolve conflicts and record with Save-MergeResolution
   - Build (mandatory)
   - Validate (if batch ends with successful CI)
   - Summarize and get approval
3. **Continue** until the target end commit is reached (or HEAD if no end commit was specified)
4. **Final scratch-branch validation:**
   - **MCP Tool Name**: `mcp_openssh-server_Test_OpenSSHFunctionality`
   - **Parameters**: (use defaults for Release/x64)

**Success Criteria:**
- All commit batches processed on scratch branch
- Build remains stable after each batch
- All successful CI checkpoints validated
- Resolution log (`.git/merge-resolution-log.json`) contains all conflict resolutions
- Ready to proceed to real-branch single merge

### Phase 6: Real Branch — Single Merge
**Objective:** Produce clean history on the real merge branch with a single merge commit preserving all upstream SHAs.

**Steps:**
1. **Switch to the real merge branch:**
   ```pwsh
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="Checkout", Target="merge-v<VERSION>-<YYYYMMDD>"
   ```

2. **Perform a single merge** of the final upstream target:
   ```pwsh
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="Merge", CommitHash="<final-upstream-commit-or-tag>"
   ```
   This creates one merge commit. `git rerere` will automatically apply resolutions it recorded during the scratch phase.

3. **Replay remaining resolutions** from the log:
   ```pwsh
   # MCP Tool: mcp_openssh-server_Replay_MergeResolutions
   # (no parameters needed — reads from .git/merge-resolution-log.json)
   ```
   The tool reports:
   - `ResolvedFiles`: Files auto-resolved from the log
   - `UnmatchedFiles`: Conflicted files not in the log (resolve manually)
   - `FailedFiles`: Files where replay failed (resolve manually)

4. **Resolve any remaining unmatched conflicts:**
   - Use the resolution log's strategies and rationale as guidance
   - These are typically files where the merge produced different conflict regions than the scratch-branch merge

5. **Complete the merge:**
   ```pwsh
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="MergeContinue"
   ```

6. **Apply build fixes** as separate commits after the merge commit:
   - Review build fixes from the scratch branch
   - Apply the same fixes (config.h.vs updates, .vcxproj changes, etc.)
   - Commit with descriptive messages
   - **CRITICAL: Restore paths.targets before committing:**
     ```pwsh
     # MCP Tool: mcp_openssh-server_Invoke_Git
     # Operation="Checkout", Target=".\contrib\win32\openssh\paths.targets"
     ```

7. **Build and validate on the real branch:**
   - Build: `mcp_openssh-server_Start_OpenSSHBuild` (Release/x64)
   - Check warnings: `mcp_openssh-server_Test_OpenSSHBuild`
   - Validate: `mcp_openssh-server_Test_OpenSSHFunctionality`

8. **Clean up scratch branch:**
   ```pwsh
   # The scratch branch is no longer needed
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="Checkout", Target="merge-v<VERSION>-<YYYYMMDD>"
   # Then delete scratch: git branch -D scratch-merge-v<VERSION>-<YYYYMMDD>
   ```

**Success Criteria:**
- Real branch has exactly one merge commit (plus build fix commits)
- All upstream commits appear in the DAG with original SHAs
- `git log --first-parent` shows a clean merge history
- Build succeeds and functionality tests pass
- Scratch branch deleted

### Phase 7: Documentation and PR
**Objective:** Document changes and submit for review

**Steps:**
1. Review all merge commits for clarity
2. Document major conflict resolutions
3. Note any Windows-specific changes
4. Push branch: `git push origin merge-v<VERSION>-<DATE>`
5. Create PR with comprehensive description
6. Add labels and request reviewers

**PR Description Template:**
```markdown
## Merge OpenSSH <VERSION>

This PR merges upstream OpenSSH commits from <START> through <END>.

### Commit Groups
- Batch 1: <start> to <end> (<count> commits)
- Batch 2: <start> to <end> (<count> commits)
...

### Major Changes
- [List significant upstream changes]

### Windows-Specific Resolutions
- [List Windows compatibility fixes]
- [List build system updates]

### Testing
- [x] Builds successfully (x64)
- [x] Service starts and runs
- [x] SSH connections work
- [x] Basic operations verified

### Known Issues
- [List any known limitations or issues]
```

**Success Criteria:**
- PR created with complete description
- All CI checks passing
- Reviewers assigned

## Decision Points

### When to Use Commit Groups
- **High complexity merge:** >100 commits, significant changes
- **Medium complexity merge:** 50-100 commits, moderate changes
- **Low complexity merge:** <50 commits, minor changes → single merge OK

### Conflict Resolution Strategy
**Always preserve:**
- Windows-specific functionality in `#ifdef WINDOWS` blocks
- Security fixes from upstream
- Build system integrity

**Accept upstream for:**
- Removed deprecated features (e.g., DSA)
- Algorithm updates
- API modernization

**Combine when:**
- Both sides add different functionality
- Windows needs additional compatibility code
- Upstream changes affect Windows-specific code

## Key Files to Monitor

### Frequently Modified
- `config.h` / `config.h.vs` - Configuration defines
- `*.vcxproj` - Visual Studio project files
- `contrib/win32/win32compat/*` - Windows compatibility layer

### Conflict Hotspots
- Authentication code (`auth*.c`)
- Platform-specific code (`platform*.c`)

## Recovery Procedures

### Abort Merge
```bash
git merge --abort
git clean -fd
git reset --hard
```

### Abort Cherry-Pick (if used outside merge workflow)
```bash
git cherry-pick --abort
git clean -fd
git reset --hard
```

### Restart Scratch Branch
```bash
# Delete the scratch branch and recreate from the merge branch
git checkout merge-v<VERSION>-<DATE>
git branch -D scratch-merge-v<VERSION>-<DATE>
git checkout -b scratch-merge-v<VERSION>-<DATE>
# Re-enable rerere if needed
git config rerere.enabled true
```

### Restart from Checkpoint
```bash
git checkout merge-v<VERSION>-<DATE>
git log --oneline -5  # Verify last successful state
# Continue from there (or recreate scratch branch)
```

### Build Failure Recovery
1. Check build log: `contrib\win32\openssh\OpenSSHReleasex64.log`
2. Search for "error C" or "error LNK"
3. Fix errors in order (compilation before linking)
4. Commit fixes separately for clarity

## Best Practices

### Commit Organization
- One logical fix per commit
- Clear commit messages explaining Windows-specific changes
- Reference upstream commit SHAs when applicable

### Testing Between Batches
- Build after each batch
- Quick smoke test (service start, simple connection)
- Full test only after all batches complete

### Documentation
- Comment complex conflict resolutions in code
- Note Windows-specific workarounds
- Link to upstream issues/PRs when relevant

## Success Metrics
- ✅ All commits from target range merged
- ✅ Clean build with no warnings
- ✅ All tests passing
- ✅ SSH service functional
- ✅ PR approved and merged
- ✅ No regressions reported in first 48 hours

## Reference Links

### Repository Links
- [Upstream OpenSSH](https://github.com/openssh/openssh-portable)
- [PowerShell Fork](https://github.com/PowerShell/openssh-portable)

### Instruction Documents (Phase 0 Required Reading)
- [Merge Process Overview](../instructions/merge/merge-process-overview.instructions.md)
- [Research Instructions](../instructions/merge/research.instructions.md)
- [Merge Details Instructions](../instructions/merge/merge-details.instructions.md)

### Additional Instructions
- [Build Instructions](../instructions/build.instructions.md)
- [Setup Instructions](../instructions/setup.instructions.md)
- [Testing Instructions](../instructions/testing.instructions.md)
