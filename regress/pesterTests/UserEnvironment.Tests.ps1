If ($PSVersiontable.PSVersion.Major -le 2) {$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path}
Import-Module $PSScriptRoot\CommonUtils.psm1 -Force

$tC = 1
$tI = 0
$suite = "userenvironment"

Describe "E2E scenarios for user environment block" -Tags "CI" {
    BeforeAll {
        if ($OpenSSHTestInfo -eq $null) {
            Throw "`$OpenSSHTestInfo is null. Please run Set-OpenSSHTestEnvironment to set test environments."
        }

        $server  = $OpenSSHTestInfo["Target"]
        $port    = $OpenSSHTestInfo["Port"]
        $ssouser = $OpenSSHTestInfo["SSOUser"]

        $testDir = Join-Path $OpenSSHTestInfo["TestDataPath"] $suite
        if (-not (Test-Path $testDir)) {
            $null = New-Item $testDir -ItemType directory -Force -ErrorAction SilentlyContinue
        }

        # Helper: run a one-liner inside an SSH session as the SSO user using PowerShell.
        function Invoke-RemotePS {
            param([Parameter(Mandatory=$true)][string] $Script)
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
            $out = ssh -p $port -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=$testDir\known_hosts" `
                       "$ssouser@$server" powershell -NoProfile -NonInteractive -EncodedCommand $encoded 2>$null
            if ($out -is [array]) { return ($out -join "`n").Trim() }
            return ($out | Out-String).Trim()
        }
    }

    AfterEach { $tI++ }

    Context "$tC - User environment variables" {
        BeforeAll { $tI = 1 }
        AfterAll  { $tC++ }

        It "$tC.$tI - USERNAME matches the connecting user" {
            $shortName = ($ssouser -split '\\')[-1]
            $remote = Invoke-RemotePS '$env:USERNAME'
            $remote | Should Be $shortName
        }

        It "$tC.$tI - USERPROFILE points to the connecting user's profile" {
            $remote = Invoke-RemotePS '$env:USERPROFILE'
            $remote | Should Not BeNullOrEmpty
            # Reject the LocalSystem / sshd-session fallback profile.
            $remote | Should Not Match 'system32\\config\\systemprofile'
            ($remote -split '\\')[-1] | Should Be (($ssouser -split '\\')[-1])
        }

        It "$tC.$tI - HOMEDRIVE and HOMEPATH are populated" {
            $remote = Invoke-RemotePS '"{0}|{1}" -f $env:HOMEDRIVE, $env:HOMEPATH'
            $parts = $remote -split '\|'
            $parts[0] | Should Match '^[A-Za-z]:$'
            $parts[1] | Should Not BeNullOrEmpty
        }

        It "$tC.$tI - APPDATA and LOCALAPPDATA are populated and per-user" {
            $remote = Invoke-RemotePS '"{0}|{1}" -f $env:APPDATA, $env:LOCALAPPDATA'
            $parts = $remote -split '\|'
            $parts[0] | Should Match 'AppData\\Roaming$'
            $parts[1] | Should Match 'AppData\\Local$'
            $parts[0] | Should Not Match 'system32\\config\\systemprofile'
            $parts[1] | Should Not Match 'system32\\config\\systemprofile'
        }

        It "$tC.$tI - USERDOMAIN is populated and is not WORKGROUP" {
            $remote = Invoke-RemotePS '$env:USERDOMAIN'
            $remote | Should Not BeNullOrEmpty
            $remote | Should Not Be 'WORKGROUP'
        }
    }

    Context "$tC - PATH is the merged System + User PATH (Phase 1 fix)" {
        BeforeAll {
            $tI = 1
            # Write a unique marker into the SSO user's HKCU\Environment\Path
            # from within an SSH session (we are not the user locally, so we
            # cannot edit their HKCU directly without loading the hive).
            $script:pathMarker = "C:\sshtestmarker_$([guid]::NewGuid().ToString('N'))"
            $setScript = @"
`$existing = (Get-ItemProperty -Path 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
if (-not `$existing) { `$existing = '' }
if (-not (`$existing -split ';' -contains '$($script:pathMarker)')) {
    `$new = if (`$existing) { `$existing.TrimEnd(';') + ';$($script:pathMarker)' } else { '$($script:pathMarker)' }
    Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value `$new -Type ExpandString
}
"@
            Invoke-RemotePS $setScript | Out-Null
        }
        AfterAll {
            $clearScript = @"
`$existing = (Get-ItemProperty -Path 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
if (`$existing) {
    `$new = ((`$existing -split ';') | Where-Object { `$_ -ne '$($script:pathMarker)' }) -join ';'
    Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value `$new -Type ExpandString
}
"@
            Invoke-RemotePS $clearScript | Out-Null
            $tC++
        }

        It "$tC.$tI - PATH contains BOTH the system entry and the user marker" {
            $remote   = Invoke-RemotePS '$env:PATH'
            $segments = $remote -split ';'
            ($segments | Where-Object { $_ -match '[Ss]ystem32' }).Count | Should BeGreaterThan 0
            ($segments | Where-Object { $_ -eq $script:pathMarker }).Count | Should BeGreaterThan 0
            $sysIndex    = ($segments | ForEach-Object { $_ }).IndexOf((($segments | Where-Object { $_ -match '[Ss]ystem32' }) | Select-Object -First 1))
            $markerIndex = ($segments | ForEach-Object { $_ }).IndexOf($script:pathMarker)
            $sysIndex    | Should BeGreaterThan -1
            $markerIndex | Should BeGreaterThan -1
            $sysIndex    | Should BeLessThan $markerIndex
        }
    }
}
