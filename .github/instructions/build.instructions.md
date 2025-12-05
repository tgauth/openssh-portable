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

The repository includes MCP tools that automate the build, verification, and error analysis process.

#### Option 1: Build & Verify (Recommended)
```pwsh
# Complete build and verification in one step
.\.github\tools\Build-OpenSSH.ps1 -Configuration Release -Architecture x64

# Clean build
.\.github\tools\Build-OpenSSH.ps1 -Configuration Release -Architecture x64 -Clean

# Debug build
.\.github\tools\Build-OpenSSH.ps1 -Configuration Debug -Architecture x64
```

**Output includes:**
- Build success/failure status
- All 14 expected artifacts verification
- Parsed compilation errors with file/line/code/message
- Build warnings summary
- Build log location

#### Option 2: Build Only
```pwsh
# Incremental build
.\.github\tools\Start-OpenSSHBuild.ps1 -Configuration Release -Architecture x64

# Clean build
.\.github\tools\Start-OpenSSHBuild.ps1 -Configuration Release -Architecture x64 -Clean
```

#### Option 3: Test Existing Build
```pwsh
# Test artifacts and parse errors from previous build
.\.github\tools\Test-OpenSSHBuild.ps1 -Configuration Release -Architecture x64
```

### Using PowerShell Module Directly (Alternative)

If you need direct access to the build module functions:

#### Step 1: Environment Setup
```pwsh
# Navigate to repository root
cd <repository-root>

# Import build helper module
Import-Module .\contrib\win32\openssh\OpenSSHBuildHelper.psm1 -Force

# Verify module loaded
Get-Command -Module OpenSSHBuildHelper
```

#### Step 2: Initial Build
```pwsh
Start-OpenSSHBuild -Configuration Release -NativeHostArch x64
```

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
1. **Attempt initial build using MCP tool**
   ```pwsh
   .\.github\tools\Build-OpenSSH.ps1 -Configuration Release -Architecture x64
   ```
2. **Review structured error output** from Build-OpenSSH tool
3. **Categorize error types** (preprocessor, Windows compatibility, build system)
4. **Apply appropriate resolution strategy** (see error categories above)
5. **Rebuild and verify** using Build-OpenSSH tool again
6. **Commit fixes with detailed message**

#### Manual Error Analysis Commands (if needed):
```pwsh
# Parse errors manually from log file
.\.github\tools\Test-OpenSSHBuild.ps1 -Configuration Release -Architecture x64

# Direct MSBuild with detailed logging
& "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe" .\contrib\win32\openssh\Win32-OpenSSH.sln /p:Configuration=Release /p:Platform=x64 /v:detailed
```

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
# Recommended: Use Build-OpenSSH which includes testing
.\.github\tools\Build-OpenSSH.ps1 -Configuration Release -Architecture x64

# Or test an existing build
.\.github\tools\Test-OpenSSHBuild.ps1 -Configuration Release -Architecture x64
```

**Expected Output:**
- Success/failure status
- 14 of 14 artifacts found
- Parsed errors and warnings
- Build log location

**Expected Artifacts (14 executables):**
- ssh.exe, sshd.exe, sshd-auth.exe, sshd-session.exe
- ssh-agent.exe, ssh-add.exe, ssh-keygen.exe, ssh-keyscan.exe
- scp.exe, sftp.exe, sftp-server.exe
- ssh-pkcs11-helper.exe, ssh-shellhost.exe, ssh-sk-helper.exe

### Manual Verification (Alternative)
```pwsh
# Check that all expected binaries were built
$buildPath = ".\contrib\win32\openssh\x64\Release"
Get-ChildItem $buildPath -Filter "*.exe" | Select-Object Name

# Expected outputs:
# a binary for each vcxproj file, e.g.
# ssh.vcxproj -> ssh.exe
```

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
