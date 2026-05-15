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
The merge process uses a **two-phase approach** to preserve upstream commit history while keeping conflict resolution manageable:

1. **Scratch branch** — All work happens here: incremental `git merge` at batch boundaries, conflict resolution, build fixes, and full CI test suite runs after each batch.
2. **Real merge branch** — Created from the same starting commit as the scratch branch, after all scratch-branch work is complete. A single `git merge` of the final upstream target is performed; any conflicts are resolved by copying the already-resolved files from the scratch branch (`git checkout scratch-branch -- <file>`). This produces one merge commit with all upstream SHAs intact and a tree that matches the validated scratch-branch state.

No `git rerere` recording, no resolution log, and no Save/Replay tooling is required.

The process consists of several interconnected phases:

1. **[Setup Phase](#setup-phase)** - Repository configuration and preparation
2. **[Research Phase](#research-phase)** - Understanding changes and conflicts
3. **[Scratch Branch Phase](#scratch-branch-phase)** - Incremental merging, conflict resolution, build fixes, validation
4. **[Real Branch Phase](#real-branch-phase)** - Single merge with conflict resolution by copy from scratch branch
5. **[Build Phase](#build-phase)** - Resolving compilation issues
6. **[Testing Phase](#testing-phase)** - Validating functionality
7. **[Submission Phase](#submission-phase)** - Creating the Pull Request

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
    # MCP Tool: mcp_openssh-server_Invoke_Git
    # Operation="Config", Key="core.editor", Value="true"
    ```

3. **Create the scratch branch only (record the starting commit):**
    ```pwsh
    # Note the current HEAD — this is the starting commit. The real merge
    # branch will be created from this same commit in the Real Branch Phase.
    # MCP Tool: mcp_openssh-server_Invoke_Git
    # Operation="Log", Range="-1"

    # Create the scratch branch (all work happens here)
    # MCP Tool: mcp_openssh-server_Invoke_Git
    # Operation="CreateBranch", Branch="scratch-merge-v<VERSION>-<YYYYMMDD>"
    ```

### Scratch Branch Phase
4. **Identify merge range and group commits:**
    Use the Get-CommitGroups MCP tool with `-FirstChunkOnly` and a user-selected CI grouping mode.

   **CI grouping mode (user input required):**
   Before invoking the tool, confirm with the user which mode to use:
   - `presence` (recommended) → `GroupByCIPresence=true`: batches end at any commit with CI runs (passing or failing). Smaller batches, more frequent build/test checkpoints.
   - `success` → `GroupByCIPresence=false`: batches end only at commits with successful CI. Larger batches, fewer checkpoints.

   Do not assume a default — ask the user if not provided. Use the same value for every `Get-CommitGroups` call in the merge.

   **MCP Tool Name**: `mcp_openssh-server_Get_CommitGroups`

   **Parameters**:
   - `GitHubTag` (string, optional): Start from last merged tag (e.g., "V_10_0_P2")
   - `StartCommit` (string, optional): Start from specific commit SHA
   - `EndCommit` (string, optional): End at specific commit SHA (default: HEAD - most recent upstream commit)
   - `FirstChunkOnly` (boolean): Set to `true`
   - `GroupByCIPresence` (boolean): Set per the user-selected CI grouping mode above

   **Example for first batch**:
   - Find the last upstream tag in the fork
   - Call tool with `GitHubTag=<last-upstream-tag>`, `EndCommit=<target-end-commit>`, `FirstChunkOnly=true`, `GroupByCIPresence=<user_choice>`
   - Omit `EndCommit` to merge all commits up to HEAD (most recent upstream commit)
   - With `GroupByCIPresence=true`, this gets commits ending with any commit that has CI runs; with `false`, only commits with successful CI

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

   Display batch details for verification, then proceed with merging.

   **After completing steps below, get next batch**:
   - Call tool with `StartCommit=<end-commit-sha>`, `EndCommit=<target-end-commit>`, `FirstChunkOnly=true`, `GroupByCIPresence=<user_choice>` (use the same mode chosen for the first batch)
   - Continue this process until the target end commit is reached (or HEAD if no end commit specified)

5. **Execute batch merge on scratch branch:**

   Merge the batch's end commit to bring in all commits in the range at once:

   ```pwsh
   # Merge all commits up to the batch endpoint
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="Merge", CommitHash=$result.EndCommitFull
   ```

   This uses `--no-ff` to always create a merge commit checkpoint.

7. **Resolve merge conflicts directly:**
    **📖 Detailed Instructions** ([Merge Details](./merge-details.instructions.md)):

   - Resolve conflicts in place for all conflicted files
   - Follow established Windows compatibility patterns
   - Reference previous merge PRs for similar conflicts
   - The resolved files on the scratch branch are the source of truth that will be copied to the real merge branch in the Real Branch Phase. No resolution log or rerere recording is needed.

8. **Complete the merge after resolution:**
   ```pwsh
   # Stage all resolved files using Invoke-Git MCP tool:
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="Add", Path="."

   # Continue merge using Invoke-Git MCP tool:
   # MCP Tool: mcp_openssh-server_Invoke_Git
   # Operation="MergeContinue"
   ```

9. **Build after completing the batch (only if the batch touched compiled sources):**
     **Gating rule:** Build and validation steps (this step and step 10) are only required for batches whose commit range touches at least one C source or header file (`*.c` or `*.h`). For batches that only modify non-compiled files (e.g., `*.md`, man pages, `regress/*.sh`, `.github/**`, documentation), skip steps 9 and 10 and proceed to step 11; note in the batch summary that build/validation were skipped because no compiled sources changed.

     Detect code impact with:
     ```pwsh
     # MCP Tool: mcp_openssh-server_Invoke_Git
     # Operation="Diff", Range="<previous_batch_end>..<current_batch_end>", NameOnly=true
     ```
     If any returned path matches `*.c` or `*.h`, perform the build below. Otherwise, skip to step 11.

     Use the Start-OpenSSHBuild MCP tool:
     - **MCP Tool Name**: `mcp_openssh-server_Start_OpenSSHBuild`
     - **Parameters**: `Configuration="Release"`, `Architecture="x64"`

     **ALWAYS check warnings after build (success or failure):**
     - **Use Test-OpenSSHBuild MCP tool to parse errors and warnings**:
         - **MCP Tool Name**: `mcp_openssh-server_Test_OpenSSHBuild`
         - **Parameters**: `Configuration="Release"`, `Architecture="x64"`
     - **DO NOT** try to read log files directly with `Get-Content` or locate them manually

     If build failed:
     - Fix issues based on parsed error output
     - Rebuild and verify

     If build succeeded:
     - Compare warnings against baseline established in Phase 1
     - If new warnings detected:
       - Categorize warnings (deprecated APIs, type conversions, potential bugs, etc.)
       - Report to user with warning details and categories
       - Request user decision: fix warnings or proceed
       - Wait for user approval before continuing
       - If user approves proceeding, update baseline to include new warnings

     **CRITICAL: Before committing, restore paths.targets**:
     ```pwsh
     # MCP Tool: mcp_openssh-server_Invoke_Git
     # Operation="Checkout", Target=".\contrib\win32\openssh\paths.targets"
     ```
     Commit any build fixes separately with descriptive messages (only actual code changes)

10. **Run full CI validation after every batch that was built (mandatory when build ran):**
    If step 9 was skipped (no `*.c`/`*.h` changes in the batch), skip this step as well.
    Otherwise, run the full OpenSSH CI suite regardless of upstream CI status for the batch endpoint.
    - **MCP Tool Name**: `mcp_openssh-server_Invoke_OpenSSHTests`
    - **Parameters**: `Configuration="Release"`, `Architecture="x64"`, `TestSuite="All"`

    If any suite fails:
    - Capture failing suite details from tool output
    - Re-run only the failing suite to iterate faster (`TestSuite="Unit"`, `TestSuite="Bash"`, or `TestSuite="E2E"`)
    - For a single failing bash case, use `TestSuite="Bash"` and `BashTestFilePath="<absolute-path-to-test.sh>"`
    - Fix issues and re-run full suite before proceeding to the next batch

11. **Provide summary and get approval:**
    - Summarize batch changes, conflicts resolved, build status, and full CI suite status (Unit/Bash/E2E)
    - Wait for user approval before proceeding to next batch
    - Document next steps (starting commit for next batch)
    - After all batches complete on the scratch branch, proceed to the Real Branch Phase

### Real Branch Phase
12. **Create the real merge branch from the original starting commit** (recorded in step 3 of Initial Preparation):
    ```pwsh
    # Check out the original starting commit
    # MCP Tool: mcp_openssh-server_Invoke_Git
    # Operation="Checkout", Target="<starting_commit>"

    # Create the real merge branch from there
    # MCP Tool: mcp_openssh-server_Invoke_Git
    # Operation="CreateBranch", Branch="merge-v<VERSION>-<YYYYMMDD>"
    ```

13. **Perform a single merge** of the final upstream target:
    ```pwsh
    # MCP Tool: mcp_openssh-server_Invoke_Git
    # Operation="Merge", CommitHash="<final-upstream-commit-or-tag>"
    ```
    This creates one merge commit covering all upstream commits in the range.

14. **Resolve conflicts by copying the resolved files from the scratch branch:**
    For each conflicted file, replace it with the already-resolved version from the scratch branch and stage it:
    ```pwsh
    # In a terminal (no dedicated MCP wrapper needed):
    git checkout scratch-merge-v<VERSION>-<YYYYMMDD> -- <conflicted_file>

    # Then stage:
    # MCP Tool: mcp_openssh-server_Invoke_Git
    # Operation="Add", Path="<conflicted_file>"
    ```
    **Simplest variant:** copy every file the merge touched (resolved + non-resolved) from the scratch branch in one command, guaranteeing the merge commit's tree exactly matches the scratch branch's tip:
    ```pwsh
    # After the merge reports conflicts (do NOT abort):
    git checkout scratch-merge-v<VERSION>-<YYYYMMDD> -- .
    git add -A
    ```

15. **Complete the merge and apply build fixes:**
    ```pwsh
    # MCP Tool: mcp_openssh-server_Invoke_Git
    # Operation="MergeContinue"
    ```
    If you used the per-file copy in step 14, replay the build-fix commits made on the scratch branch (cherry-pick or re-apply) as separate commits after the merge commit. If you used the whole-tree copy, the build fixes are already included in the merge commit's tree.

16. **Final build and validation** on the real branch.

---

## Build Phase

**📖 Detailed Instructions:** [Build Instructions](../build.instructions.md)

7. **Initial build attempt:**
   Use the Start-OpenSSHBuild MCP tool:
   - **MCP Tool Name**: `mcp_openssh-server_Start_OpenSSHBuild`
   - **Parameters**: `Configuration="Release"`, `Architecture="x64"`

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
    # MCP Tool: mcp_openssh-server_Invoke_Git
    # Operation="Commit"
    # Message="Fix compilation errors for <VERSION>
    #
    # Changes:
    # - Updated config.h.vs with <new definitions>
    # - Added Windows equivalent for <function>
    # - Updated project files for <binary changes>"
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
    # MCP Tool: mcp_openssh-server_Invoke_Git
    # Operation="Commit"
    # Message="Fix runtime issues for <VERSION>
    #
    # Issues resolved:
    # - <specific problem and solution>"
    ```

---

## Submission Phase

### Creating the Pull Request
14. **Push to fork:**
    ```pwsh
    # MCP Tool: mcp_openssh-server_Invoke_Git
    # Operation="Push", Remote="origin", Branch="merge-v<VERSION>-<DATE>"
    ```

15. **Create Pull Request:**
    - Target: `PowerShell/openssh-portable:<branch>` (typically the branch you started from, e.g., latestw_all)
    - Title: `Merge upstream OpenSSH <VERSION>`
    - Include comprehensive description of changes and resolutions

16. **Normalize upstream workflow triggers for Windows fork:**
    - Ensure merged upstream workflow files under `.github/workflows/*.yml` are dispatch-only in this fork.
    - Keep `workflow_dispatch` enabled and disable automatic triggers (`push`, `pull_request`, `schedule`) unless explicitly required for this fork.
    - Preserve trigger blocks as commented context where practical so future re-syncs are straightforward.

17. **Address CI/test failures:**
    - Monitor automated tests
    - Fix any Windows-specific test failures
    - Ensure all checks pass

18. **Request review:**
    - Tag appropriate PowerShell team reviewers
    - Provide context for complex conflict resolutions

---

## Success Criteria

**The merge is complete when:**
- [ ] All merge conflicts resolved with documented reasoning
- [ ] Solution builds successfully on Windows
- [ ] Basic SSH connection test passes
- [ ] All CI tests pass
- [ ] Upstream workflow triggers normalized to dispatch-only for this fork
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
