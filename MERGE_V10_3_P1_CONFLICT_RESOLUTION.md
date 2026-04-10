# Merge V_10_3_P1 Conflict Resolution Notes

Date: 2026-04-10

## Workflow Summary

- Scratch branch: scratch-merge-v10.3P1-20260410
- Clean branch: merge-v10.3P1-20260410
- Upstream target: V_10_3_P1 (peeled commit 2d98db98331803cbb820211b2fb0d31a6e71e58e)
- Strategy used:
  - Resolve incrementally on scratch branch with build verification after each batch.
  - Perform one full merge on clean branch.
  - Resolve clean branch conflicts by copying already-resolved files from scratch.
  - Apply minimal post-merge fix commits.

## Conflict Resolution Strategy Patterns

### 1. Release-generated files: accept upstream

Used for add/add or generated-content conflicts where upstream release artifacts are authoritative.

Representative files:
- ChangeLog
- config.h.in
- configure
- moduli.0
- scp.0
- sftp-server.0
- sftp.0
- ssh-add.0
- ssh-agent.0
- ssh-keygen.0
- ssh-keyscan.0
- ssh-keysign.0
- ssh-pkcs11-helper.0
- ssh-sk-helper.0
- ssh.0
- ssh_config.0
- sshd.0
- sshd_config.0

### 2. .gitignore: combine

Kept existing fork-specific ignore coverage and merged upstream additions (for example *~), avoiding regressions in Windows fork ignore behavior.

### 3. Regress script combine for Windows behavior

File:
- regress/sftp-cmds.sh

Resolution:
- Took upstream helper refactor.
- Preserved fork-specific Windows shell-output matching behavior to keep test compatibility.

### 4. Clean branch conflicts: copy from scratch

For the final single merge on clean branch, unresolved files were copied directly from scratch branch resolved versions, matching the requested process and preserving the reviewed conflict outcomes.

## Build Fixes Applied

### Header indirection/fallback compatibility fixes

Files:
- contrib/win32/win32compat/inc/sys/stat.h
- contrib/win32/win32compat/inc/fcntl.h
- contrib/win32/win32compat/inc/time.h
- contrib/win32/win32compat/inc/sys/types.h

Resolution:
- Added guarded fallbacks to standard CRT headers when generated header-map macros were not usable in this environment.

### Missing compatibility wrapper headers for new includes

Added files:
- contrib/win32/win32compat/inc/glob.h
- contrib/win32/win32compat/inc/sys/queue.h
- contrib/win32/win32compat/inc/sys/tree.h
- contrib/win32/win32compat/inc/ifaddrs.h
- contrib/win32/win32compat/inc/netgroup.h
- contrib/win32/win32compat/inc/paths.h
- contrib/win32/win32compat/inc/util.h

### Source/build integration adjustments

Files:
- scp.c
- sftp-usergroup.h
- contrib/win32/openssh/libssh.vcxproj
- contrib/win32/openssh/unittest-*.vcxproj (multiple)
- servconf.h
- sshd-session.c

Resolution:
- Fixed Windows compile-scope issue in scp command execution path.
- Ensured glob_t declarations are visible where required.
- Synced project file source lists with current upstream/fork code split.
- Applied type alignment in servconf struct field.
- Corrected the Windows split-session privsep state flow so the post-auth `sshd-session -z` child reads the saved identification-exchange state before the authenticated user context.

## Validation Results

### Build validation

- Scratch branch: build successful after fixes.
- Clean branch: build successful after copying scratch resolutions and applying post-merge fixes.
- Parsed result: all 14 expected artifacts present, no compile/link errors.

### Warning status

- Warning set remained at the known baseline pattern (C4047 sites in clientloop/serverloop).
- No additional warning category delta was introduced by merge resolution/fix commits.

### Functionality test

- Validation scenario used: `entra-id-debug-localhost`.
- Ran `sshd.exe -ddd` elevated and validated with the rebuilt `ssh.exe` against `localhost`.
- Result after the follow-up `sshd-session.c` fix: public-key authentication succeeded, `whoami` executed successfully, and the session exited with status 0.
- Observed command output: `NORTHAMERICA+tessgauthier`.

## Notes for Review

Reviewers should focus on:
- Combined resolution behavior in .gitignore and regress/sftp-cmds.sh.
- Windows compatibility header fallbacks and wrapper headers.
- VCXPROJ synchronization changes for source/include expectations.
- Clean branch post-merge sync commit that copies scratch-proven results.
