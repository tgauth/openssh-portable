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

1. **Get-CommitGroups MCP Tool** - Groups commits by CI success status
   - **Access**: Available via MCP server (preferred method)
   - **MCP Tool Name**: `mcp_pwsh-mcp-server_Get_CommitGroups`
   - **Direct Script**: `.github/instructions/merge/tools/Get-CommitGroups.ps1` (fallback)
   - **Parameters**:
     - `GitHubTag` (string, optional): GitHub tag to start from (e.g., "V_10_0_P2")
     - `StartCommit` (string, optional): Commit SHA to start from
     - `FirstChunkOnly` (boolean, optional): Stop after finding first successful chunk
   - **Usage via MCP**: Use the MCP tool function directly - it handles all GitHub API calls
   - **Manual Usage**: `Get-Help .\Get-CommitGroups.ps1` for direct script execution

2. **OpenSSHBuildHelper Module** - Build automation
   - Location: `contrib\win32\openssh\OpenSSHBuildHelper.psm1`
   - Key cmdlet: `Start-OpenSSHBuild -Configuration Release -NativeHostArch x64`

3. **Git** - Version control operations
   - Cherry-pick: `git cherry-pick start_commit^..end_commit` (inclusive)
   - Status: `git status`
   - Remotes: `origin`, `upstream-pwsh`, `upstream`

## Workflow Phases

### Phase 0: Research and Planning
**Objective:** Understand the merge scope, requirements, and context

**Steps:**
1. **Read all merge instructions** from `.github/instructions/merge/` folder:
   - `instructions.md` - Overview and general guidelines
   - `research.instructions.md` - Research methodology and analysis requirements
   - `merge.instructions.md` - Detailed merge execution procedures

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
5. Perform baseline build on `latestw_all` branch
6. Use Get-CommitGroups MCP tool to identify commit batches with passing CI

**Success Criteria:**
- Base branch builds successfully
- Commit groups identified with CI status
- Merge branch created

### Phase 2: Incremental Merge
**Objective:** Cherry-pick commits in manageable batches

**Steps:**
1. **Get commit batch** from Get-CommitGroups MCP tool:
   ```pwsh
   # The MCP tool returns structured data with commit details
   # Example output:
   # {
   #   "ChunkNumber": 1,
   #   "StartCommit": "609fe2c",
   #   "EndCommit": "6fb728d",
   #   "StartCommitFull": "609fe2cae2459d721ac11d23cd27b8a94397ef3c",
   #   "EndCommitFull": "6fb728df50c1afd338cb0223a84ce24579577eff",
   #   "CommitCount": 57,
   #   "StartMessage": "upstream: rework the text for -3 to make it clearer what default",
   #   "EndMessage": "Run all tests on Cygwin again."
   # }
   ```

2. **Display batch information for verification:**
   ```pwsh
   Write-Host "Processing Batch $($result.ChunkNumber)"
   Write-Host "Commit Range: $($result.StartCommit)..$($result.EndCommit)"
   Write-Host "Start: [$($result.StartCommit)] $($result.StartMessage)"
   Write-Host "End: [$($result.EndCommit)] $($result.EndMessage)"
   Write-Host "Total commits: $($result.CommitCount)"
   ```

3. Execute: `git cherry-pick start_commit^..end_commit`
4. Resolve conflicts following Windows preservation patterns
5. Stage and continue: `git add .` then `git cherry-pick --continue`
6. Repeat until batch complete

**Conflict Resolution Patterns:**
- **Windows-specific code:** Preserve with `#ifdef WINDOWS`
- **Removed features (e.g., DSA):** Accept upstream removal
- **Build system:** Add/remove files from .vcxproj as needed
- **API compatibility:** Add Windows shims if needed

**Success Criteria:**
- All commits in batch cherry-picked
- No remaining conflict markers
- Branch is in clean state

### Phase 3: Build Resolution
**Objective:** Fix compilation errors and update build system

**Steps:**
1. Attempt build: `Start-OpenSSHBuild -Configuration Release -NativeHostArch x64`
2. Document all compilation errors
3. Fix source code issues:
   - Add missing Windows compatibility defines
   - Update function signatures for Windows
   - Add platform guards where needed
4. Update Visual Studio project files:
   - Add new source files to .vcxproj
   - Remove deleted source files
   - Create projects for new binaries if applicable
5. Rebuild until successful

**Common Build Fixes:**
- Missing source files in .vcxproj files
- Removed files still referenced in projects
- Missing function implementations (add to win32compat)

**Success Criteria:**
- Clean build with no errors
- All expected binaries generated

### Phase 4: Testing
**Objective:** Verify functionality on Windows

**Steps:**
1. Install SSH service: `.\bin\x64\Release\install-sshd.ps1`
2. Start service: `Start-Service sshd`
3. Create test user: `net user testuser <random-pwd> /add`
4. Test SSH connection: `ssh testuser@localhost`
5. Verify basic SSH operations work
6. Clean up: `net user testuser /delete`

**Success Criteria:**
- Service starts without errors
- SSH connections successful

### Phase 5: Iteration
**Objective:** Process remaining commit groups

**Steps:**
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
- [Merge Instructions Overview](../instructions/merge/instructions.md)
- [Research Instructions](../instructions/merge/research.instructions.md)
- [Merge Execution Instructions](../instructions/merge/merge.instructions.md)

### Additional Instructions
- [Build Instructions](../instructions/build.instructions.md)
- [Setup Instructions](../instructions/setup.instructions.md)
- [Testing Instructions](../instructions/testing.instructions.md)

