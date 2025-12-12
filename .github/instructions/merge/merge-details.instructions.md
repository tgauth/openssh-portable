---
applyTo: "**/*"
---

# Merge Instructions for AI Agents

## Overview
This AI-specific documentation provides comprehensive instructions and algorithmic frameworks that AI agents can use to systematically approach the OpenSSH merge process with minimal human intervention while maintaining high quality and consistency. It combines conflict resolution strategies with automated decision-making processes.

**Key Approach: Chunked Merging**
Instead of merging entire upstream versions at once, this framework implements a chunked approach that:
- Processes commits in small batches (a couple commits that end with a commit that passed CI)
- Validates CI success for each batch using GitHub API
- Allows for incremental progress and easier rollback
- Reduces complexity of conflict resolution
- Enables better testing and validation at each step

## Decision Framework for AI Agents

### Pre-Merge Analysis Algorithm
```pseudocode
FUNCTION analyze_upstream_changes(target_version):
    // Step 1: Find last merged commit and determine range
    last_upstream_commit = find_last_upstream_commit_in_fork()
    commit_range = get_commit_range(last_upstream_commit, target_version)

    // Step 2: Fetch and analyze release notes
    release_notes = fetch_release_notes(target_version)
    risk_factors = []

    FOR EACH change IN release_notes:
        IF change.contains(["signal", "fork", "pipe", "process", "daemon", "service"]):
            risk_factors.append({type: "PROCESS_MANAGEMENT", change: change})
        IF change.contains(["auth", "pam", "kerberos", "gssapi"]):
            risk_factors.append({type: "AUTHENTICATION", change: change})
        IF change.contains(["build", "makefile", "configure", "autotools"]):
            risk_factors.append({type: "BUILD_SYSTEM", change: change})
        IF change.contains(["security", "cve", "vulnerability"]):
            risk_factors.append({type: "SECURITY", change: change, priority: "HIGH"})
```

### Conflict Resolution Decision Tree
```pseudocode
FUNCTION resolve_conflict(file_path, conflict_content):
    conflict_type = analyze_conflict_type(conflict_content)

    SWITCH conflict_type:
        CASE "SECURITY_FIX":
            // Always accept upstream security fixes
            RETURN accept_upstream(conflict_content)

        CASE "BUILD_SYSTEM_CHANGE":
            // Need to update Visual Studio projects
            upstream_changes = extract_upstream_changes(conflict_content)
            RETURN combine_with_windows_build_system(upstream_changes)

        CASE "PROCESS_MANAGEMENT":
            // Unix fork/exec vs Windows CreateProcess
            IF contains_fork_or_exec(conflict_content):
                RETURN wrap_with_platform_ifdef(conflict_content)
            ELSE:
                RETURN analyze_compatibility(conflict_content)

        CASE "AUTHENTICATION":
            // PAM/Kerberos vs Windows auth
            RETURN preserve_windows_auth_with_upstream_features(conflict_content)

        CASE "CONFIGURATION":
            // config.h vs config.h.vs changes
            new_defines = extract_new_defines(conflict_content)
            RETURN update_config_h_vs(new_defines)

        DEFAULT:
            // Use historical pattern matching
            similar_resolutions = find_similar_conflicts(file_path, conflict_content)
            RETURN apply_similar_resolution_pattern(similar_resolutions[0])
```

## Information Sources and Analysis

### Primary References
- [Upstream release notes](https://www.openssh.com/releasenotes.html) - Pay special attention when merging new versions
- [Previous merge PRs](../instructions.md#referencesmd) - Review conflict resolution patterns
- Commit history and messages - Use `git log --oneline upstream/<version>` to understand changes
- Local repository file comparison - Use 3-way diff tools

### Analysis Commands
```pwsh
# View commit details for understanding changes
git show <commit-hash>

# Compare files between branches
git diff upstream-pwsh/latestw_all upstream/<version> -- <filepath>
```

## Conflict Resolution Strategies

### 1. Taking Upstream Changes
**When to use:** Security fixes, bug fixes, feature improvements that don't conflict with Windows functionality.

```c
// Example: Accept upstream security patch
<<<<<<< HEAD
// Windows-specific code
=======
// New upstream security fix
>>>>>>> upstream/V_X_Y_PZ
```
**Resolution:** Take the upstream change completely.

### 2. Combining Changes with Preprocessor Directives
**When to use:** Upstream changes that conflict with Windows-specific functionality but both are needed.

```c
// Example: Combining platform-specific implementations
#ifdef WINDOWS
    // Windows-specific implementation
    return windows_specific_function();
#else
    // Upstream Unix implementation
    return unix_specific_function();
#endif /* WINDOWS */
```

### 3. Excluding Changes with #ifndef WINDOWS
**When to use:** Upstream changes are not applicable to Windows or would break Windows functionality.

```c
// Example: Excluding Unix-only functionality
#ifndef WINDOWS
    // Unix-only code that doesn't apply to Windows
    setup_unix_specific_feature();
#endif /* !WINDOWS */
```

## Automated Conflict Resolution Patterns

### Pattern 1: Platform-Specific Code Wrapping
```c
// Input conflict:
<<<<<<< HEAD
void windows_specific_function() {
    // Windows implementation
}
=======
void unix_specific_function() {
    // New upstream Unix implementation
}
>>>>>>> upstream/version

// AI Resolution:
#ifdef WINDOWS
void windows_specific_function() {
    // Windows implementation
}
#else
void unix_specific_function() {
    // New upstream Unix implementation
}
#endif /* WINDOWS */
```

### Pattern 2: Configuration File Updates
```pseudocode
FUNCTION update_config_h_vs(upstream_config_changes):
    config_vs_path = "./contrib/win32/openssh/config.h.vs"
    current_config = read_file(config_vs_path)

    FOR EACH define IN upstream_config_changes:
        IF define.is_windows_compatible():
            IF define NOT IN current_config:
                add_define_to_config_vs(define, determine_windows_value(define))
        ELSE:
            // Add comment explaining why it's not included
            add_comment_to_config_vs(f"// {define.name} - Unix only, not applicable to Windows")

    write_file(config_vs_path, current_config)
```

### Pattern 3: Build System Synchronization
```pseudocode
FUNCTION sync_build_system():
    makefile_changes = get_makefile_changes()

    FOR EACH binary IN makefile_changes.new_binaries:
        IF binary.is_windows_applicable():
            create_visual_studio_project(binary)
            add_to_solution_file(binary)
        ELSE:
            log(f"Skipping {binary} - Unix only")

    FOR EACH binary IN makefile_changes.removed_binaries:
        remove_visual_studio_project(binary)
        remove_from_solution_file(binary)

    FOR EACH source_file IN makefile_changes.new_source_files:
        target_project = determine_target_project(source_file)
        add_source_to_project(target_project, source_file)
```

## Common Conflict Patterns

### File System Operations
- **Fork/exec calls** → Use Windows process creation APIs
- **Signal handling** → Use Windows event mechanisms
- **File permissions** → Adapt to Windows ACL model

### Build System Changes
- **Makefile additions** → Update Visual Studio project files
- **New dependencies** → Check Windows compatibility
- **Compiler flags** → Translate to MSVC equivalents

### Configuration Changes
- **New config options** → Add to `./contrib/win32/openssh/config.h.vs`
- **Feature detection** → Verify Windows support
- **Default values** → Adjust for Windows environment

## Resolution Workflow

### For Each Conflict:
1. **Analyze the change**
   ```bash
   git show upstream/<version> -- <conflicted-file>
   ```

2. **Check previous resolutions**
   - Search previous merge PRs for similar conflicts
   - Look for patterns in Windows-specific handling

3. **Choose resolution strategy**
   - Upstream change: Complete replacement
   - Combined: Add preprocessor directives
   - Excluded: Use `#ifndef WINDOWS`

4. **Test the resolution**
   - Ensure code compiles
   - Verify simple ssh connection to local host works
   - Check that upstream functionality is preserved where applicable

5. **Document the decision**
   - Add comments explaining the Windows-specific handling
   - Note in commit message why this approach was chosen

## Build Validation Automation

### Iterative Build and Fix Process
```pseudocode
FUNCTION automated_build_fix():
    MAX_ITERATIONS = 10
    iteration = 0

    WHILE iteration < MAX_ITERATIONS:
        build_result = attempt_build()

        IF build_result.success:
            RETURN SUCCESS

        errors = parse_build_errors(build_result.output)
        fixes_applied = []

        FOR EACH error IN errors:
            fix = determine_fix_strategy(error)
            IF fix:
                apply_fix(fix)
                fixes_applied.append(fix)

        IF fixes_applied.empty():
            RETURN MANUAL_INTERVENTION_REQUIRED

        commit_build_fixes(fixes_applied, f"Build fixes iteration {iteration + 1}")
        iteration += 1

    RETURN MAX_ITERATIONS_EXCEEDED

FUNCTION determine_fix_strategy(error):
    SWITCH error.type:
        CASE "MISSING_INCLUDE":
            RETURN add_windows_include(error.missing_header)
        CASE "UNDEFINED_FUNCTION":
            RETURN add_windows_equivalent(error.function_name)
        CASE "MISSING_DEFINE":
            RETURN add_to_config_h_vs(error.define_name)
        CASE "MISSING_SOURCE_FILE":
            RETURN add_source_to_project(error.file_name)
        DEFAULT:
            RETURN null
```

## Testing Automation Framework

### Automated Test Execution
```pseudocode
FUNCTION execute_test_suite():
    test_results = {}

    // Phase 1: Build verification
    test_results["build"] = verify_build_artifacts()
    IF NOT test_results["build"].success:
        RETURN test_results

    // Phase 2: Service setup
    test_results["service_setup"] = setup_ssh_service()
    IF NOT test_results["service_setup"].success:
        RETURN test_results

    // Phase 3: Basic connectivity
    test_results["connectivity"] = test_basic_ssh_connection()

    // Cleanup
    cleanup_test_environment()

    RETURN test_results

FUNCTION generate_test_report(test_results):
    report = "# Automated Test Results\n\n"

    FOR EACH category, result IN test_results:
        status = result.success ? "✅ PASS" : "❌ FAIL"
        report += f"## {category}: {status}\n"

        IF NOT result.success:
            report += f"Error: {result.error}\n"
            report += f"Suggested Fix: {result.suggested_fix}\n"

    RETURN report
```

## Error Recovery Strategies

### Automatic Rollback Points
```pseudocode
FUNCTION create_checkpoint(phase_name):
    current_commit = get_current_commit_hash()
    checkpoints[phase_name] = current_commit
    tag_commit(f"checkpoint-{phase_name}", current_commit)

FUNCTION rollback_to_checkpoint(phase_name):
    IF phase_name IN checkpoints:
        reset_to_commit(checkpoints[phase_name])
        RETURN SUCCESS
    ELSE:
        RETURN CHECKPOINT_NOT_FOUND

// Usage in main workflow
create_checkpoint("pre-merge")
execute_merge()

IF merge_conflicts_too_complex():
    rollback_to_checkpoint("pre-merge")
    request_manual_intervention()
```

### Conflict Complexity Assessment
```pseudocode
FUNCTION assess_conflict_complexity(conflicts):
    complexity_score = 0

    FOR EACH conflict IN conflicts:
        // File-based scoring
        IF conflict.file.ends_with(".c", ".h"):
            complexity_score += 2
        IF conflict.file.contains("auth", "pam", "kerberos"):
            complexity_score += 5
        IF conflict.file == "config.h":
            complexity_score += 3

        // Content-based scoring
        lines_in_conflict = conflict.content.split('\n').length
        complexity_score += lines_in_conflict * 0.1

        // Pattern-based scoring
        IF conflict.content.contains("fork", "exec", "signal"):
            complexity_score += 10
        IF conflict.content.contains("WIN32", "WINDOWS", "#ifdef"):
            complexity_score -= 2  // Already has platform guards

    IF complexity_score > 50:
        RETURN "HIGH_COMPLEXITY"
    ELIF complexity_score > 20:
        RETURN "MEDIUM_COMPLEXITY"
    ELSE:
        RETURN "LOW_COMPLEXITY"
```

## Anti-Patterns to Avoid

### ❌ Don't Remove Upstream Code
```c
// WRONG: This will cause future merge conflicts
// Completely removing upstream additions
```

### ❌ Don't Modify Upstream Logic Without Guards
```c
// WRONG: Modifying upstream code without preprocessor protection
upstream_function_with_windows_modifications();
```

### ✅ Do Use Preprocessor Guards
```c
// CORRECT: Preserve upstream code with conditional compilation
#ifdef WINDOWS
    windows_alternative();
#else
    upstream_function();
#endif
```

## Progress Tracking and Reporting

### Automated Progress Updates
```pseudocode
FUNCTION update_progress(phase, status, details):
    progress_entry = {
        timestamp: current_timestamp(),
        phase: phase,
        status: status,  // SUCCESS, FAILURE, IN_PROGRESS
        details: details,
        commit_hash: get_current_commit_hash()
    }

    append_to_progress_log(progress_entry)

    IF status == "FAILURE":
        generate_failure_report(phase, details)
        suggest_recovery_actions(phase, details)

FUNCTION generate_merge_summary():
    summary = {
        total_conflicts: count_resolved_conflicts(),
        build_iterations: count_build_fix_iterations(),
        test_results: get_final_test_results(),
        time_elapsed: calculate_total_time(),
        commits_created: count_commits_since_start(),
        complexity_rating: assess_overall_complexity()
    }

    RETURN format_summary_report(summary)
```

## Integration with Development Workflow

### Pull Request Preparation
```pseudocode
FUNCTION prepare_pull_request():
    // Generate comprehensive commit history
    commit_history = get_commits_since_branch_creation()

    // Create PR description
    pr_description = f"""
# Merge OpenSSH {target_version} to Windows Fork

## Summary
{generate_merge_summary()}

## Conflict Resolutions
{generate_conflict_resolution_summary()}

## Testing Results
{generate_test_report(final_test_results)}

## Files Modified
{list_modified_files()}

## Breaking Changes
{identify_breaking_changes()}
"""

    RETURN {
        title: f"Merge upstream OpenSSH {target_version}",
        description: pr_description,
        labels: ["upstream-merge", determine_complexity_label()],
        assignees: get_default_reviewers()
    }
```

## Commit Message Template

```
Resolve merge conflicts for <upstream-version>

Major conflict resolutions:
- <file1>: Combined upstream <feature> with Windows <implementation> using #ifdef
- <file2>: Excluded upstream <unix-feature> with #ifndef WINDOWS due to <reason>
- <file3>: Accepted upstream <bugfix> completely

Reasoning: <brief explanation of overall strategy>
```

## Troubleshooting

### If Unsure About a Conflict:
1. Check if the upstream change addresses a CVE or security issue (prioritize)
2. Look for similar code patterns elsewhere in the Windows codebase
3. Consult the OpenSSH-portable issue tracker for context
4. When in doubt, use conditional compilation to preserve both approaches

### Testing Your Resolution:
- Build the project after each major conflict resolution
- Run ssh connection to local host to ensure basic functionality
- Check that removed functionality wasn't critical to Windows operation