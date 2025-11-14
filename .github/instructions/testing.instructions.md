---
applyTo: "**/*"
---

# Testing Instructions for AI Agents

## Overview
This document provides comprehensive testing procedures for validating OpenSSH-Portable merges on Windows. Testing should be performed after successful compilation to ensure functionality is preserved.

## Test Environment Setup

### Prerequisites Check
```pwsh
# Verify Windows version compatibility
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion

# Check if running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
{
    Write-Warning "Administrative privileges required for service installation"
}

# Verify build artifacts exist
$buildPath = ".\contrib\win32\openssh\x64\Release"
Test-Path "$buildPath\sshd.exe" -and (Test-Path "$buildPath\ssh.exe")
```

### Service Installation and Configuration

#### Step 1: Install SSH Service
```pwsh
# Navigate to build directory
cd .\contrib\win32\openssh\x64\Release

# Install SSH server service with PowerShell script
.\install-sshd.ps1

# Verify service installation
Get-Service sshd -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType
```

#### Step 2: Configure SSH Service
```pwsh
# Start SSH service
Start-Service sshd

# Verify service is running
Get-Service sshd | Select-Object Name, Status
```

#### Step 3: Configure Windows Firewall (if needed)
```pwsh
# Allow SSH through Windows Firewall
New-NetFirewallRule -DisplayName "SSH Server (sshd)" -Direction Inbound -Port 22 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
```

## Basic Functionality Tests

### Test 1: SSH Client Connection
```pwsh
# Test local connection (most basic test)
$username = $env:USERNAME
$hostname = "localhost"

Write-Host "Testing SSH connection: ssh $username@$hostname"

# Basic connection test
.\ssh.exe $username@$hostname "echo 'SSH connection successful'"
```

**Expected Output:**
```
SSH connection successful
```

## Error Diagnosis and Troubleshooting

### Run SSH Server in Debug Mode
```pwsh
# Enable SSH daemon debug logging
Stop-Service sshd
.\sshd.exe -ddd

# In another terminal, test connection with verbose client logging
.\ssh.exe -vvv $username@$hostname
```

### Common Issues and Solutions

#### Issue 1: Service Won't Start
**Symptoms:**
- Service fails to start
- Event log shows service errors

**Diagnosis:**
```pwsh
# Check event logs
Get-WinEvent -LogName System | Where-Object {$_.ProviderName -eq "Service Control Manager" -and $_.Id -eq 7034} | Select-Object -First 5

# Check sshd configuration
.\sshd.exe -T
```

**Common Solutions:**
- Verify configuration file syntax

#### Issue 2: Connection Timeouts
**Symptoms:**
- SSH client hangs
- Connection timeout errors

**Diagnosis:**
```pwsh
# Check network connectivity
Test-NetConnection -ComputerName localhost -Port 22

# Check Windows Firewall rules
Get-NetFirewallRule | Where-Object {$_.DisplayName -like "*SSH*"}
```

## Success Criteria

**Testing is successful when:**
- [ ] All expected executables are present after build
- [ ] SSH service installs and starts without errors
- [ ] Basic SSH connection to localhost succeeds


## AI Agent Guidelines

1. **Run tests incrementally** during the merge process, not just at the end
2. **Document any test failures** and their resolutions in commit messages
3. **Pay special attention to Windows-specific functionality** that might be affected by upstream changes
4. **Always clean up test artifacts** and services after testing
5. **Report any new functionality** that needs additional testing procedures

## Test Environment Cleanup

```pwsh
# Clean up test environment
Stop-Service sshd -ErrorAction SilentlyContinue
.\uninstall-sshd.ps1

# Remove firewall rule
Remove-NetFirewallRule -DisplayName "SSH Server (sshd)" -ErrorAction SilentlyContinue

Write-Host "Test environment cleaned up"
```
