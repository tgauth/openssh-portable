---
applyTo: ".github/instructions/merge/**"
---

# Merge-Specific Agent Communication Guidelines

## Overview
This document provides specific communication templates and guidelines for AI agents performing upstream merge operations. These guidelines **supplement** the high-level agent communication principles defined in [agent-communication.instructions.md](../agent-communication.instructions.md).

**Key Points:**
- The high-level communication guidelines apply to ALL merge interactions
- This document adds merge-specific templates and formats
- Tool output templates are **MUST use** (exact format required)
- Batch summary templates are **SHOULD include** (flexible adaptation allowed)

## MCP Tool Output Templates

These templates define the **exact format** agents MUST use when communicating tool results to users.

### 1. Start-OpenSSHBuild Tool Output

**MUST use this format when reporting build results.**

#### Success Scenario:
```
Build completed successfully. All 14 executables were created:
- ssh.exe, sshd.exe, sshd-auth.exe, sshd-session.exe
- ssh-agent.exe, ssh-add.exe, ssh-keygen.exe, ssh-keyscan.exe
- scp.exe, sftp.exe, sftp-server.exe
- ssh-pkcs11-helper.exe, ssh-shellhost.exe, ssh-sk-helper.exe

Configuration: Release | Architecture: x64
```

#### Failure Scenario:
```
Build failed with compilation errors. Analyzing the build log to identify issues.

[After running Test-OpenSSHBuild]
Found X compilation errors:
- [file.c]: [brief error description]
- [file.c]: [brief error description]

I'll resolve these errors now.
```

### 2. Test-OpenSSHBuild Tool Output

**MUST use this format when reporting build error analysis.**

#### When Build Failed:
```
Build error analysis complete:

Compilation Errors (X):
- [filename.c] (Line Y): [Error code] - [Brief description]
- [filename.c] (Line Y): [Error code] - [Brief description]

Warnings (X):
- [filename.c] (Line Y): [Warning description]

Error Categories:
- Missing preprocessor definitions: X
- Windows compatibility issues: X
- Build system inconsistencies: X
```

#### When Build Succeeded:
```
No need to analyze build errors - the build completed successfully.
```

**Note:** Only invoke Test-OpenSSHBuild when Start-OpenSSHBuild reports failure.

### 3. Test-OpenSSHFunctionality Tool Output

**MUST use this format when reporting functionality test results.**

#### Success Scenario:
```
Functionality testing completed successfully!

Test Results:
✅ Administrator privileges verified
✅ Test user created: [username]
✅ SSH service installed successfully
✅ SSH service started successfully
✅ Firewall rule configured
✅ SSH connection test passed
✅ Command execution verified: "echo hello world" returned expected output

All test resources cleaned up.
```

#### Failure Scenario:
```
Functionality testing failed.

Test Progress:
✅ Administrator privileges verified
✅ Test user created: [username]
❌ SSH service installation failed

Error: [Error message from tool]

The test environment has been cleaned up. I'll investigate the service installation issue.
```

#### Partial Success Scenario:
```
Functionality testing completed with warnings.

Test Results:
✅ Administrator privileges verified
✅ Test user created: [username]
✅ SSH service installed successfully
✅ SSH service started successfully
⚠️ Firewall rule configuration skipped (SkipFirewall=true)
✅ SSH connection test passed
✅ Command execution verified

Note: Firewall was not configured as requested. Ensure firewall rules exist if testing remote connections.
```

## Commit Batch Summary Template

**SHOULD include these elements** when summarizing a commit batch. Adapt the format and detail level based on context.

### Template Structure:

```
Processing batch [N] ([X] commits from [start_hash] to [end_hash])

Key Changes:
- [Category 1]: [Brief description]
- [Category 2]: [Brief description]
- [Category 3]: [Brief description]

Files Modified: [X] files
Conflicts: [X] conflicts ([resolved/pending])

[Additional context if needed]
```

### Example - Simple Batch:
```
Processing batch 1 (8 commits from a1b2c3d to e4f5a6b)

Key Changes:
- Security fixes: Updated bounds checking in buffer handling
- Bug fixes: Corrected memory leak in session cleanup
- Documentation: Updated protocol specification comments

Files Modified: 12 files
Conflicts: 2 conflicts (resolved)
```

### Example - Complex Batch:
```
Processing batch 3 (15 commits from 7h8i9j0 to k1l2m3n)

Key Changes:
- Build system: Added new source files for MLKEM support
- Authentication: Enhanced certificate validation logic
- Process management: Modified daemon initialization (requires Windows adaptation)
- Configuration: Added 3 new preprocessor definitions

Files Modified: 28 files
Conflicts: 7 conflicts (5 resolved, 2 require manual review)

Note: The daemon initialization changes use fork() which needs Windows CreateProcess() equivalent.
```

### Example - Minimal Batch:
```
Processing batch 5 (3 commits from x7y8z9 to a0b1c2)

Key Changes:
- Minor documentation updates
- Code formatting corrections

Files Modified: 4 files
Conflicts: None
```

## Progress Update Templates

**SHOULD include these elements** when communicating progress at different workflow phases. Adapt wording to context.

### Pre-Merge Analysis Phase:
```
Analyzing upstream changes from [last_merge_tag] to [target_version]...

Found [X] commits to merge:
- [X] security fixes (HIGH PRIORITY)
- [X] bug fixes
- [X] feature additions
- [X] build system changes

Grouping commits into batches for incremental merging.
```

### Conflict Resolution Phase:
```
Resolving [X] conflicts in [filename]:

- Conflict 1: [Brief description] → [Resolution strategy]
- Conflict 2: [Brief description] → [Resolution strategy]

[X] conflicts resolved, [Y] remaining.
```

### Build Fixes Phase:
```
Applying build fixes for iteration [N]:

- Added Windows compatibility header to [file.c]
- Updated config.h.vs with [X] new definitions
- Added [source_file.c] to [project.vcxproj]

Rebuilding...
```

### Testing Phase:
```
Running functionality tests to validate the merge...

[Use Test-OpenSSHFunctionality template from above]
```

### Cleanup Phase:
```
Finalizing the merge:

✅ Restored paths.targets to clean state
✅ Verified [X] commits applied successfully
✅ All builds passing
✅ Functionality tests passing

Ready to commit and push.
```

## Special Scenarios

### When Seeking User Approval:
```
Batch [N] is ready for review:

Summary:
- [X] commits merged successfully
- Build: ✅ Passed
- Tests: ✅ Passed
- Conflicts: [X] resolved

Changes include: [brief list]

May I proceed with the next batch?
```

### When Requesting Manual Intervention:
```
I've encountered a complex conflict that requires manual review:

File: [filename]
Issue: [Description of the conflict complexity]
Context: [Why automated resolution isn't appropriate]

Recommendation: [Suggested approach]

Please advise on how to proceed.
```

### When Reporting Critical Issues:
```
⚠️ CRITICAL: [Issue type detected]

Details:
- [Specific problem]
- [Impact assessment]
- [Affected components]

This requires immediate attention before proceeding with the merge.
```

## Integration with Pseudocode

When implementing pseudocode patterns from merge-details.instructions.md, use these communication approaches:

### update_progress() → Chat Message
```pseudocode
# Pseudocode:
update_progress("Build Fixes", "IN_PROGRESS", "Applied 3 fixes")

# Agent Implementation (via chat):
"Applying build fixes (iteration 2): Added 3 Windows compatibility changes. Rebuilding now..."
```

### generate_test_report() → Structured Chat Message
```pseudocode
# Pseudocode:
report = generate_test_report(test_results)

# Agent Implementation (via chat):
[Use Test-OpenSSHFunctionality template from above]
```

### log() → Contextual Chat Message
```pseudocode
# Pseudocode:
log(f"Skipping {binary} - Unix only")

# Agent Implementation (via chat):
"Skipping ssh-keysign.exe - Unix-only binary not applicable to Windows build."
```

## Best Practices for Merge Communication

1. **Always include commit hashes** when referencing specific commits (first 7 characters)
2. **Use file links** when referencing specific files: [filename](path/to/filename)
3. **Categorize changes** by type (security, bug fix, feature, build system, etc.)
4. **Highlight Windows-specific considerations** that required special handling
5. **Provide commit counts** to show progress and scope
6. **Be specific about conflict types** and resolution strategies used
7. **Report before and after** major operations (build, test, etc.)
8. **Update after each batch** to maintain transparency
9. **Use consistent terminology** aligned with the instruction files
10. **Mark critical items** with appropriate indicators (⚠️, ✅, ❌)

## Summary

- **Tool templates are REQUIRED** - Use exact formats for MCP tool output summaries
- **Batch templates are RECOMMENDED** - Include suggested elements but adapt to context
- **Supplement high-level guidelines** - All general communication principles still apply
- **Maintain transparency** - Keep users informed throughout the merge process
- **Be consistent** - Use standard terminology and formatting patterns
