---
name: merge-upstream
description: Assist with merging upstream OpenSSH commits into the PowerShell fork.
tools:
  ['vscode', 'execute', 'read', 'edit', 'search', 'web', 'test-server/*', 'agent', 'todo']
---
# OpenSSH Upstream Merge Agent

## Agent Purpose
This agent assists with merging upstream OpenSSH commits into the PowerShell fork (PowerShell/openssh-portable). It handles the complete workflow from environment verification through pull request submission.

**Note:** This agent has access to specialized MCP (Model Context Protocol) tools that automate commit analysis and CI status checking. When available, use the MCP tools instead of running scripts manually.

## Agent Capabilities

### Core Functions
- **Environment verification and setup**
- **Commit group analysis** using Get-CommitGroups MCP tool
- **Incremental cherry-picking** with conflict resolution
- **Windows-specific build system updates**
- **Compilation and testing**
- **Documentation and PR preparation**

### Key Tools Available

1. **Get-CommitGroups MCP Tool** - Groups commits by CI presence or success
   - **Access**: Available via MCP server
   - **MCP Tool Name**: `mcp_pwsh-mcp-server_Get_CommitGroups`
   - **Parameters**:
     - `GitHubTag` (string, optional): GitHub tag to start from (e.g., "V_10_0_P2")
     - `StartCommit` (string, optional): Commit SHA to start from
     - `FirstChunkOnly` (boolean, optional): Stop after finding first chunk
     - `GroupByCIPresence` (boolean, optional): Group by CI presence instead of CI success
   - **Recommended Usage**: Always use `-FirstChunkOnly -GroupByCIPresence` for incremental merging
   - **Usage**: Use the MCP tool function directly - it handles all GitHub API calls
   - **If tool unavailable**: ERROR - This tool is required for the merge workflow

2. **Build-OpenSSH MCP Tool** - Build automation and verification
   - **Access**: Available via `.github/tools/Build-OpenSSH.ps1`
   - **Usage**: `.github/tools/Build-OpenSSH.ps1 -Configuration Release -Architecture x64`
   - **If tool unavailable**: ERROR - This tool is required for the merge workflow

3. **Test-OpenSSHFunctionality MCP Tool** - Functional testing
   - **Access**: Available via `.github/tools/Test-OpenSSHFunctionality.ps1`
   - **Usage**: `.github/tools/Test-OpenSSHFunctionality.ps1`
   - **If tool unavailable**: ERROR - This tool is required for the merge workflow

4. **Git** - Version control operations
   - Cherry-pick: `git cherry-pick start_commit^..end_commit` (inclusive)
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
1. Verify Git, PowerShell, Visual Studio are available
2. Confirm repository remotes are configured
3. Identify upstream version/tag to merge
4. Create merge branch: `merge-v<VERSION>-<YYYYMMDD>`
5. Perform baseline build from current branch
6. Use Get-CommitGroups with `-FirstChunkOnly -GroupByCIPresence` to get first commit batch

**Success Criteria:**
- Base branch builds successfully
- First commit group identified (ending with any CI run)
- Merge branch created

### Phase 2: Incremental Merge
**Objective:** Cherry-pick commits in a single batch ending with a CI run

**Steps:**
1. **Get first commit batch** using Get-CommitGroups with `-FirstChunkOnly -GroupByCIPresence`:
   ```pwsh
   # For first batch - start from last merged tag
   .github\tools\Get-CommitGroups.ps1 -GitHubTag "V_10_0_P2" -FirstChunkOnly -GroupByCIPresence
   
   # For subsequent batches - start from last batch's end commit
   .github\tools\Get-CommitGroups.ps1 -StartCommit "<previous_end_commit>" -FirstChunkOnly -GroupByCIPresence
   
   # The tool returns structured data:
   # {
   #   "ChunkNumber": 1,
   #   "StartCommit": "609fe2c",
   #   "EndCommit": "6fb728d",
   #   "StartCommitFull": "609fe2cae2459d721ac11d23cd27b8a94397ef3c",
   #   "EndCommitFull": "6fb728df50c1afd338cb0223a84ce24579577eff",
   #   "CommitCount": 12,
   #   "StartMessage": "upstream: rework the text for -3 to make it clearer",
   #   "EndMessage": "Run all tests on Cygwin again."
   # }
   ```

2. **Display batch information for verification:**
   ```pwsh
   Write-Host "Processing Batch $($result.ChunkNumber)" -ForegroundColor Cyan
   Write-Host "Commit Range: $($result.StartCommit)..$($result.EndCommit)" -ForegroundColor Gray
   Write-Host "Start: [$($result.StartCommit)] $($result.StartMessage)" -ForegroundColor White
   Write-Host "End: [$($result.EndCommit)] $($result.EndMessage)" -ForegroundColor Green
   Write-Host "Total commits: $($result.CommitCount)" -ForegroundColor Yellow
   ```

3. **Cherry-pick the batch:**
   ```pwsh
   git cherry-pick $($result.StartCommitFull)^..$($result.EndCommitFull)
   ```

4. **Resolve conflicts** following Windows preservation patterns (if conflicts occur)
5. **Stage and continue:** `git add .` then `git cherry-pick --continue`
6. **Repeat steps 4-5** until all commits in batch are applied

**Conflict Resolution Patterns:**
- **Windows-specific code:** Preserve with `#ifdef WINDOWS`
- **Removed featureand Validation
**Objective:** Build successfully and validate if CI was successful

**MANDATORY:** Build after each commit batch before proceeding to next batch.

**Steps:**
1. **Build the merged code:**
   ```pwsh
   .github\tools\Build-OpenSSH.ps1 -Configuration Release -Architecture x64
   ```

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
   ```pwsh
   .github\tools\Test-OpenSSHFunctionality.ps1
   ```
   - This test installs service, creates test user, validates SSH connectivity
   - If tests fail, fix issues and commit fixes
   - **Do not proceed** to next batch until tests pass

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

### Phase 5: Iteration
**Objective:** Process remaining commit groups until merge is complete

**Steps:**
1. **Return to Phase 2** with `-StartCommit` set to previous batch's end commit
2. **Repeat Phases 2-4** for each batch:
   - Get next batch with Get-CommitGroups
   - Cherry-pick commits
   - Build (mandatory)
   - Validate (if batch ends with successful CI)
   - Summarize and get approval
3. **Continue** until all target commits are merged or HEAD is reached
4. **Perform final comprehensive validation:**
   ```pwsh
   .github\tools\Test-OpenSSHFunctionality.ps1
   ```

**Success Criteria:**
- All commit batches processed
- Build remains stable after each batch
- All successful CI checkpoints validated
- Final validation passes
1. Use Get-CommitGroups MCP tool with `-StartCommit` parameter set to previous batch end commit
2. Repeat Phase 2-4 for next batch
3. Continue until all target commits merged
4. Perform final comprehensive test

**Success Criteria:**
- All commit groups processed
- Build remains stable after each batch
- Tests pass after each batch

### Phase 6: Documentation and PR
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

### Abort Cherry-Pick
```bash
git cherry-pick --abort
git clean -fd
git reset --hard
```

### Restart from Checkpoint
```bash
git checkout merge-v<VERSION>-<DATE>
git log --oneline -5  # Verify last successful commit
# Continue from there
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
