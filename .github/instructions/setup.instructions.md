---
applyTo: "**/*"
---

# Repository Setup Instructions for AI Agents

## Initial Repository Setup

### Step 1: Clone Your Fork
```pwsh
# Replace 'your-username' with actual GitHub username
git clone https://github.com/your-username/openssh-portable.git
cd openssh-portable
```

### Step 2: Add Upstream Repositories
```pwsh
# Add PowerShell team's fork as upstream-pwsh
git remote add upstream-pwsh https://github.com/PowerShell/openssh-portable.git

# Add original OpenSSH repository as upstream
git remote add upstream https://github.com/openssh/openssh-portable.git
```

### Step 3: Verify Remote Configuration
```pwsh
git remote -v
# Expected output:
# origin          https://github.com/your-username/openssh-portable.git (fetch)
# origin          https://github.com/your-username/openssh-portable.git (push)
# upstream        https://github.com/openssh/openssh-portable.git (fetch)
# upstream        https://github.com/openssh/openssh-portable.git (push)
# upstream-pwsh   https://github.com/PowerShell/openssh-portable.git (fetch)
# upstream-pwsh   https://github.com/PowerShell/openssh-portable.git (push)
```

### Step 4: Initial Fetch
```pwsh
git fetch --all
```

## Branch Strategy

### Understanding the Branch Structure
- **upstream-pwsh/latestw_all**: Main Windows-compatible branch (base for merges)
- **upstream/master**: Latest upstream OpenSSH development
- **upstream/V_X_Y_PZ**: Tagged releases (merge targets)

### Verification Commands
```pwsh
# List all branches
git branch -r

# Check current branch
git branch
```

### Step 5: Clone VCPkg Repository
```pwsh
# In the same parent directory as openssh-portable
git clone https://github.com/Microsoft/vcpkg.git
```

### Step 6: Setup VCPkg Integration with MSBuild
```pwsh
cd vcpkg
.\bootstrap-vcpkg.bat
.\vcpkg.exe integrate install
```

## AI Agent Checklist

Before proceeding to merge:
- [ ] Repository cloned successfully
- [ ] All three remotes configured (origin, upstream, upstream-pwsh)
- [ ] Can fetch from all remotes without errors
- [ ] Can see upstream-pwsh/latestw_all branch
- [ ] Can see upstream target version/branch
- [ ] Working directory is clean (`git status` shows no uncommitted changes)

## Troubleshooting

### Common Issues
1. **Authentication errors**: Ensure GitHub credentials are configured
2. **Network issues**: Check proxy settings if behind corporate firewall
3. **Branch not found**: Verify branch/tag names are correct
