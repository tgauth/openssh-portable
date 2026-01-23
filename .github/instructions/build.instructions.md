---
applyTo: "**/*"
---

# Build Instructions for AI Agents

## Overview
This document provides comprehensive build instructions for OpenSSH-Portable on Windows, specifically tailored for AI agents performing upstream merges.

## Prerequisites Verification

### Check Required Tools
```pwsh
# Verify PowerShell version
$PSVersionTable.PSVersion

# Verify Visual Studio installation
Get-ChildItem "C:\Program Files*\Microsoft Visual Studio\*\*\MSBuild\Current\Bin\msbuild.exe"

# Verify Windows SDK
Get-ChildItem "C:\Program Files*\Windows Kits\10\bin" -Directory

# Verify Git
git --version
```

## Build Process

### Using MCP Build Tools (Recommended)

The repository includes MCP tools that automate the build and error analysis process.

#### Build
Use the Start-OpenSSHBuild MCP tool:
- **MCP Tool Name**: `mcp_openssh-server_Start_OpenSSHBuild`
- **Parameters**:
  - `Configuration` (optional): "Debug" or "Release" (default: "Release")
  - `Architecture` (optional): "x64", "x86", "ARM", "ARM64" (default: "x64")
  - `Clean` (optional): Perform clean build (default: false)

**Examples:**
- Incremental build: `Configuration="Release"`, `Architecture="x64"`
- Clean build: `Configuration="Release"`, `Architecture="x64"`, `Clean=true`

#### Test Existing Build (on failure only)
Use the Test-OpenSSHBuild MCP tool when a build fails:
- **MCP Tool Name**: `mcp_openssh-server_Test_OpenSSHBuild`
- **Parameters**: `Configuration="Release"`, `Architecture="x64"`

## Compilation Error Resolution

### Common Error Categories

#### 1. Missing Preprocessor Definitions
**Symptoms:**
```
error C2065: 'SOME_DEFINE': undeclared identifier
```

**Resolution:**
```pwsh
# Edit config.h.vs file
notepad .\contrib\win32\openssh\config.h.vs

# Add missing definitions (example)
#define SOME_DEFINE 1
```

#### 2. Missing Windows Equivalents
**Symptoms:**
```
error C3861: 'fork': identifier not found
error C3861: 'signal': identifier not found
```

**Resolution Pattern:**
```c
// In source file, add Windows compatibility
#ifdef WINDOWS
    // Use Windows equivalent or win32compat function
    HANDLE process = CreateProcess(...);
#else
    // Original Unix code
    pid_t pid = fork();
#endif
```

#### 3. Build System Inconsistencies
**Symptoms:**
```
error MSB3073: The command exited with code 1
fatal error C1083: Cannot open source file: 'newfile.c'
```

**AI Agent Resolution Process:**
1. **Check Makefile changes:**
   ```bash
   git diff upstream-pwsh/latestw_all upstream/<version> -- Makefile.in
   ```

2. **Identify new/removed source files:**
   ```bash
   # Look for patterns like:
   # ssh_SOURCES = ssh.c readconf.c clientloop.c sshtty.c \
   #               sshconnect.c sshconnect2.c mux.c newfile.c
   ```

3. **Update Visual Studio projects:**
   ```xml
   <!-- Add to appropriate .vcxproj file -->
   <ClCompile Include="newfile.c" />
   ```

4. **Update solution if new binaries added:**
   ```
   # Check for new programs in Makefile:
   # bin_PROGRAMS = ssh sshd ssh-add ssh-keygen ssh-keyscan ssh-copy-id scp sftp sftp-server ssh-pkcs11-helper ssh-sk-helper ssh-agent new-binary
   ```

### Step-by-Step Error Resolution

#### AI Agent Workflow:
1. **Run the build**
   - Use: **Start-OpenSSHBuild** — `mcp_openssh-server_Start_OpenSSHBuild` with `Configuration` and `Architecture`.
2. **If build succeeded**, skip log parsing and proceed.
3. **If build failed**, **parse errors** using **Test-OpenSSHBuild** — `mcp_openssh-server_Test_OpenSSHBuild`.
4. **Categorize error types** (preprocessor, Windows compatibility, build system).
5. **Apply appropriate resolution strategy** (see error categories above) and **rebuild** with Start-OpenSSHBuild.
6. **Commit fixes with detailed message**.

#### Reading Build Logs and Errors (on failure only)
Use the **Test-OpenSSHBuild** MCP tool to read build logs and parse errors **only when the build fails**:
- **MCP Tool Name**: `mcp_openssh-server_Test_OpenSSHBuild`
- **Parameters**: `Configuration="Release"`, `Architecture="x64"`

**Why use this tool:**
- Automatically locates and parses the build log file
- Provides structured error output with file paths, codes, and messages
- Groups errors and warnings for easier analysis
- Works reliably in MCP context where direct file reading may not be available

**DO NOT** attempt to read log files directly with `Get-Content` or similar commands.
**DO NOT** try to locate log files manually.

### Build Tools Invocation Policy

- Use `Start-OpenSSHBuild.ps1` to run the build for each chunk/batch.
- Only if `Start-OpenSSHBuild.ps1` reports the build failed, invoke `Test-OpenSSHBuild.ps1` to parse errors and warnings from the build log.
- Skip `Test-OpenSSHBuild.ps1` when the build succeeded to avoid unnecessary log parsing.

#### Alternative: Direct MSBuild (Terminal Only)
Only use this when running directly in a terminal (not via MCP):
```pwsh
& "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe" .\contrib\win32\openssh\Win32-OpenSSH.sln /p:Configuration=Release /p:Platform=x64 /v:detailed
```

### Important Note: paths.targets File Modification

**The build process automatically modifies `.\contrib\win32\openssh\paths.targets`** to update SDK version paths based on the currently installed Windows SDK. This is normal and expected behavior.

**Before committing any changes:**
```pwsh
# Check if paths.targets was modified by the build
git status .\contrib\win32\openssh\paths.targets

# If it shows as modified, restore it to a clean state
git checkout .\contrib\win32\openssh\paths.targets
```

**Why this happens:**
- MSBuild automatically updates SDK paths to match your local environment
- These changes are environment-specific and should not be committed
- The file will be modified on every build

**AI Agent Workflow:**
- After completing all build fixes and before final commit, restore paths.targets
- Only commit actual code changes, not build-generated path updates

## Project File Management

### Understanding the Project Structure
```
contrib\win32\openssh\
├── Win32-OpenSSH.sln          # Main solution file
├── libssh.vcxproj             # Core SSH library
├── ssh.vcxproj                # SSH client
├── sshd.vcxproj               # SSH server listener handling
├── sshd-auth.vcxproj          # SSH server authentication handling
├── sshd-session.vcxproj       # SSH server session handling
├── ssh-add.vcxproj            # Key agent utility
├── ssh-agent.vcxproj          # Authentication agent
├── ssh-keygen.vcxproj         # Key generation utility
├── ssh-keyscan.vcxproj        # Key scanning utility
└── ssh-pkcs11-helper.vcxproj  # SSH PKCS11 helper
└── ssh-shell-host.vcxproj     # SSH shell host
└── ssh-sk-helper.vcxproj      # SSH SK helper
├── scp.vcxproj                # Secure copy
├── sftp.vcxproj               # Secure file transfer client
└── sftp-server.vcxproj        # Secure file transfer server
```

### Adding New Projects (AI Agent Process)
1. **Identify new binary in Makefile:**
   ```bash
   grep "bin_PROGRAMS\|sbin_PROGRAMS" Makefile.in
   ```

2. **Check Windows applicability:**
   ```bash
   # Skip Unix-only binaries like ssh-keysign
   # Include utilities that work on Windows
   ```

3. **Create new project file:**
   ```pwsh
   # Copy existing similar project
   Copy-Item ssh.vcxproj ssh-newutil.vcxproj
   ```

4. **Update project references:**
   ```xml
   <!-- Update project name, output file, and source files -->
   <PropertyGroup>
     <ProjectName>ssh-newutil</ProjectName>
     <TargetName>ssh-newutil</TargetName>
   </PropertyGroup>
   ```

5. **Add to solution:**
   ```
   # Edit Win32-OpenSSH.sln to include new project
   ```

## Validation and Testing

### Build Verification Using MCP Tools
```pwsh
Use the Start-OpenSSHBuild MCP tool (recommended):
- **MCP Tool Name**: `mcp_openssh-server_Start_OpenSSHBuild`
- **Parameters**: `Configuration="Release"`, `Architecture="x64"`

If the build fails, parse errors with:
- **MCP Tool Name**: `mcp_openssh-server_Test_OpenSSHBuild`
- **Parameters**: `Configuration="Release"`, `Architecture="x64"`
**Expected Output (on failure):**
- Build failure status
- Parsed errors and warnings
- Build log location
```
**Expected Artifacts (14 executables):**
- ssh.exe, sshd.exe, sshd-auth.exe, sshd-session.exe
- ssh-agent.exe, ssh-add.exe, ssh-keygen.exe, ssh-keyscan.exe
- scp.exe, sftp.exe, sftp-server.exe
- ssh-pkcs11-helper.exe, ssh-shellhost.exe, ssh-sk-helper.exe

### Quick Functionality Test
```pwsh
# Verify version reporting
& ".\contrib\win32\openssh\x64\Release\ssh.exe" -V
```

## Troubleshooting Guide

### Build Helper Module Issues
```pwsh
# Force reload module
Remove-Module OpenSSHBuildHelper -Force -ErrorAction SilentlyContinue
Import-Module .\contrib\win32\openssh\OpenSSHBuildHelper.psm1 -Force
```

### Path and Environment Issues
```pwsh
# Verify Visual Studio environment
& "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat"

# Check MSBuild path
where.exe msbuild
```

### Permission Issues
```pwsh
# Ensure running as Administrator if needed
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
{
    Write-Warning "Build may require Administrator privileges"
}
```
