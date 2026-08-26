Import-Module $PSScriptRoot\CommonUtils.psm1 -Force

# Regression test for PowerShell/Win32-OpenSSH#1694: sshd must unload the user
# registry hive after a session ends, otherwise open handles on NTUSER.DAT /
# UsrClass.dat leak and the user profile can no longer be deleted.
Describe "User profile hive is unloaded after a session (issue #1694)" -Tags "CI" {
    BeforeAll {
        if ($OpenSSHTestInfo -eq $null) {
            Throw "`$OpenSSHTestInfo is null. Please run Set-OpenSSHTestEnvironment to set test environments."
        }

        $server = $OpenSSHTestInfo["Target"]
        $port = $OpenSSHTestInfo["Port"]
        $user = $OpenSSHTestInfo["PasswdUser"]
        $password = $OpenSSHTestInfo["TestAccountPW"]

        # The profile is only loaded (and therefore unloaded) when sshd runs as
        # SYSTEM. Skip when the test daemon runs under another account.
        $skip = $true
        $svcName = $OpenSSHTestInfo["SshdServiceName"]
        if ($svcName) {
            $svc = Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartName -match '^(LocalSystem|NT AUTHORITY\\SYSTEM)$') { $skip = $false }
        } else {
            # task-based test daemon is registered as SYSTEM
            $skip = $false
        }

        # resolve the user's SID so we can look for its loaded hive under HKEY_USERS
        $userSid = $null
        try {
            $userSid = (New-Object System.Security.Principal.NTAccount($user)).Translate(
                [System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            $skip = $true
        }

        Add-PasswordSetting -Pass $password

        function Test-HiveLoaded { param([string]$Sid) Test-Path "Registry::HKEY_USERS\$Sid" }
    }

    AfterAll {
        Remove-PasswordSetting
    }

    It "unloads the user hive once the session child exits" -skip:$skip {
        $o = ssh -p $port -o "StrictHostKeyChecking=no" "$user@$server" "cmd /c echo profileunloadtest"
        $LASTEXITCODE | Should Be 0
        $o | Should Match "profileunloadtest"

        # the session child is reaped asynchronously; give it a moment to unload
        $loaded = $true
        for ($i = 0; $i -lt 40; $i++) {
            if (-not (Test-HiveLoaded -Sid $userSid)) { $loaded = $false; break }
            Start-Sleep -Milliseconds 500
        }

        $loaded | Should Be $false
    }
}
