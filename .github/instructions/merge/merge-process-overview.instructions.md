---
applyTo: "**/*"
---

# OpenSSH-Portable: Merge From Upstream Instructions

## Overview
This documentation provides comprehensive instructions for merging OpenBSD's OpenSSH-Portable changes into the PowerShell team's Windows-compatible fork. It is designed to be used by both human developers and AI agents to complete a full merge process that results in a ready-to-merge Pull Request.

## Prerequisites
Ensure the following tools are installed and configured before proceeding:
- **Git**
- **PowerShell**
- **Visual Studio** with:
  - Latest C/C++ development tools
  - Latest Windows 10/11 SDK

## Process Overview
The merge process uses a **chunked approach** to reduce complexity and improve success rates. Instead of merging entire upstream versions at once, commits are processed in small batches ending with commits that have CI runs. Each batch is built and optionally validated before proceeding to the next.

The process consists of several interconnected phases:

1. **[Setup Phase](#setup-phase)** - Repository configuration and preparation
2. **[Research Phase](#research-phase)** - Understanding changes and conflicts
3. **[Merge Phase](#merge-phase)** - Performing chunked commit merging
4. **[Build Phase](#build-phase)** - Resolving compilation issues
5. **[Testing Phase](#testing-phase)** - Validating functionality
6. **[Submission Phase](#submission-phase)** - Creating the Pull Request

## Setup Phase

**📖 Detailed Instructions:** [Setup Instructions](../setup.instructions.md)

**Quick Overview:**
1. Clone your fork of the openssh-portable repository
2. Configure upstream remotes (PowerShell team fork + original OpenSSH)
3. Fetch latest changes

## Research Phase

**📖 Detailed Instructions:** [Research Instructions](./research.instructions.md)

**Key Resources:**
- **Upstream Release Notes:** [OpenSSH Release Notes](https://www.openssh.com/releasenotes.html)
- **Previous Merge PRs:** such as https://github.com/PowerShell/openssh-portable/pull/737

## Merge Phase

### Initial Preparation
1. **Verify prerequisites and baseline**
   Use the Test-MergePrerequisites MCP tool:
   ```pwsh
   # Run prerequisite check via MCP tool
   # MCP Tool Name: mcp_openssh-server_Test_MergePrerequisites
   # Parameters: TargetVersion (required), SkipBaselineBuild (optional)

   # Example invocation (replace <VERSION> with target like "V_10_0_P2"):
   # The MCP tool will verify:
   # - Git, PowerShell, Visual Studio installed
   # - Repository remotes configured (origin, upstream, upstream-pwsh)
   # - Target version exists in upstream
   # - Working directory is clean

   # Proceed only if tool reports "ALL PREREQUISITES MET"
   ```

2. **Configure git:**
    ```pwsh
    git config core.editor true
    ```

3. **Create merge branch from current branch:**
   ```pwsh
   git checkout -b merge-v<VERSION>-<DATE>
   # Example: merge-v9.8-20241010
   ```

### Perform Merge with Grouped Commits
4. **Identify merge range and group commits:**
    Use the Get-CommitGroups MCP tool with `-FirstChunkOnly -GroupByCIPresence`

   **MCP Tool Name**: `mcp_openssh-server_Get_CommitGroups`

   **Parameters**:
   - `GitHubTag` (string, optional): Start from last merged tag (e.g., "V_10_0_P2")
   - `StartCommit` (string, optional): Start from specific commit SHA
   - `FirstChunkOnly` (boolean): Set to `true`
   - `GroupByCIPresence` (boolean): Set to `true`

   **Example for first batch**:
   - Find the last upstream tag in the fork
   - Call tool with `GitHubTag=<last-upstream-tag>`, `FirstChunkOnly=true`, `GroupByCIPresence=true`
   - This gets commits ending with any commit that has CI runs (not just successful CI)

   **Example output:**
   ```json
   {
     "ChunkNumber": 1,
     "StartCommit": "609fe2c",
     "EndCommit": "6fb728d",
     "StartCommitFull": "609fe2cae2459d721ac11d23cd27b8a94397ef3c",
     "EndCommitFull": "6fb728df50c1afd338cb0223a84ce24579577eff",
     "CommitCount": 57,
     "StartMessage": "upstream: rework the text for -3 to make it clearer what default",
     "EndMessage": "Run all tests on Cygwin again."
   }
   ```

   Display batch details for verification, then proceed with cherry-picking.

   **After completing steps below, get next batch**:
   - Call tool with `StartCommit=<end-commit-sha>`, `FirstChunkOnly=true`, `GroupByCIPresence=true`
   - Continue this process until the upstream's HEAD has been successfully merged

5. **Execute chunked merge (commit-by-commit within the chunk):**

   **Important:** Even though commits are *grouped* into chunks for planning/CI boundaries, **cherry-pick each commit individually** within the chunk and **build after each commit**. This catches Windows-specific build breaks early and makes it clear which upstream commit introduced a regression.

   ```pwsh
   # For each chunk (start..end), enumerate and cherry-pick commits one at a time.
   # Then build after EACH commit.
   #
   # Example for a single chunk:
   $chunkStart = $result.StartCommitFull
   $chunkEnd   = $result.EndCommitFull
   $commits = git rev-list --reverse "$chunkStart^..$chunkEnd"

   foreach ($commit in $commits) {
       Write-Host "Cherry-picking commit: $commit"
       git cherry-pick $commit

    # Build after every commit to attribute failures precisely.
    # Use MCP Tool: mcp_openssh-server_Start_OpenSSHBuild
    # Parameters: Configuration="Release", Architecture="x64"
   }
   ```

7. **Resolve merge conflicts (per commit):**
    **📖 Detailed Instructions** ([Merge Details](./merge-details.instructions.md)):

   - Resolve conflicts for the current commit only
   - Use three-way comparison tools
   - Follow established Windows compatibility patterns
   - Reference previous merge PRs for similar conflicts

8. **Continue cherry-picking after resolution:**
   ```pwsh
   # After resolving conflicts for current commit
   git add .
   git cherry-pick --continue

   # Then continue with remaining commits in batch
   # Repeat process for next batch if needed
   ```

9. **Build after completing the batch:**
     Use the Start-OpenSSHBuild MCP tool:
     - **MCP Tool Name**: `mcp_openssh-server_Start_OpenSSHBuild`
     - **Parameters**: `Configuration="Release"`, `Architecture="x64"`

     If build fails:
     - **Use Test-OpenSSHBuild MCP tool to read the build log and parse errors**:
         - **MCP Tool Name**: `mcp_openssh-server_Test_OpenSSHBuild`
         - **Parameters**: `Configuration="Release"`, `Architecture="x64"`
     - **DO NOT** try to read log files directly with `Get-Content` or locate them manually
     - Fix issues based on parsed error output
     - Rebuild and verify
     - Commit any build fixes separately with descriptive messages

10. **Validate if batch ended with successful CI:**
    Check the end commit's CI status from Get-CommitGroups output.
    If CI was successful, run validation:
    - **MCP Tool Name**: `mcp_openssh-server_Test_OpenSSHFunctionality`
    - **Parameters**: (use defaults for Release/x64)

    If no CI or failed CI, skip validation (build success is sufficient).

11. **Provide summary and get approval:**
    - Summarize batch changes, conflicts resolved, build status, validation status
    - Wait for user approval before proceeding to next batch
    - Document next steps (starting commit for next batch)
---

## Build Phase

**📖 Detailed Instructions:** [Build Instructions](../build.instructions.md)

7. **Initial build attempt:**
   ```pwsh
   Start-OpenSSHBuild -Configuration Release -NativeHostArch x64
   ```

8. **Resolve compilation errors (iterative process):**

   **Common Areas to Check:**
   - **config.h.vs updates:** New preprocessor definitions
   - **Function signatures:** Windows equivalents for Unix functions
   - **Build system changes:** Makefile vs Visual Studio projects
   - **New dependencies:** Windows compatibility verification

9. **Update Visual Studio projects:**
   - Check Makefile for added/removed binaries
   - Create/update .vcxproj files as needed
   - Update Win32-OpenSSH.sln solution file
   - Ensure Windows-applicable binaries only

10. **Commit build fixes:**
    ```pwsh
    git commit -m "Fix compilation errors for <VERSION>

    Changes:
    - Updated config.h.vs with <new definitions>
    - Added Windows equivalent for <function>
    - Updated project files for <binary changes>"
    ```

---

## Testing Phase

**📖 Detailed Instructions:** [Testing Instructions](../testing.instructions.md)

11. **Basic functionality test:**
    ```pwsh
    # Set up SSH service (see testing.instructions.md)
    ssh.exe <username>@localhost
    ```

12. **Troubleshoot connection issues:**
    - Enable verbose logging
    - Check service configuration
    - Use debugger if necessary
    - Verify certificate/key handling

13. **Commit any test fixes:**
    ```pwsh
    git commit -m "Fix runtime issues for <VERSION>

    Issues resolved:
    - <specific problem and solution>"
    ```

---

## Submission Phase

### Creating the Pull Request
14. **Push to fork:**
    ```pwsh
    git push origin merge-v<VERSION>-<DATE>
    ```

15. **Create Pull Request:**
    - Target: `PowerShell/openssh-portable:<branch>` (typically the branch you started from, e.g., latestw_all)
    - Title: `Merge upstream OpenSSH <VERSION>`
    - Include comprehensive description of changes and resolutions

16. **Address CI/test failures:**
    - Monitor automated tests
    - Fix any Windows-specific test failures
    - Ensure all checks pass

17. **Request review:**
    - Tag appropriate PowerShell team reviewers
    - Provide context for complex conflict resolutions

---

## Success Criteria

**The merge is complete when:**
- [ ] All merge conflicts resolved with documented reasoning
- [ ] Solution builds successfully on Windows
- [ ] Basic SSH connection test passes
- [ ] All CI tests pass
- [ ] PR approved and ready for merge

---

## AI Agent Resources

AI agents should utilize these additional resources:

- **[Reference Analysis](./research.instructions.md)** - Intelligence gathering protocols
- **[Merge Details](./merge-details.instructions.md)** - Comprehensive merge process, conflict resolution, and automation algorithms
- **[Testing Instructions](../testing.instructions.md)** - Detailed validation procedures

**For AI Agents:**
1. **Start with this overview** - Follow the phases and track progress commit-by-commit
2. **Follow decision trees** - Refer to AI agent instructions for algorithmic guidance
3. **Document everything** - Maintain detailed commit messages and resolution rationale
4. **Use automated testing** - Leverage provided test scripts for validation
5. **Escalate when needed** - If complexity exceeds capabilities, document and request human intervention

**Success Criteria Check:**
The merge process is successful when an AI agent can complete all phases independently and produce a Pull Request that meets all quality standards without human intervention.
