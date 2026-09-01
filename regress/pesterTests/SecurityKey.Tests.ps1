If ($PSVersiontable.PSVersion.Major -le 2) {$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path}
Import-Module $PSScriptRoot\CommonUtils.psm1 -Force
$tC = 1
$tI = 0
$suite = "securitykey"

Describe "E2E scenarios for FIDO/U2F security key authentication" -Tags "CI" {
    # sk-dummy.dll is OpenSSH's own software FIDO/U2F authenticator, built
    # from regress/misc/sk-dummy and shipped next to the OpenSSH binaries for
    # testing.  It lets us exercise the security-key (-sk) code paths without a
    # physical authenticator.  Enrollment and signing must both go through this
    # middleware (the built-in internal provider would talk to real hardware),
    # so it is passed explicitly via -w / SecurityKeyProvider.  If it is not
    # present there is nothing to exercise and every case is skipped.
    $skProvider = $null
    if (($OpenSSHTestInfo -ne $null) -and $OpenSSHTestInfo['OpenSSHBinPath']) {
        $candidate = Join-Path $OpenSSHTestInfo['OpenSSHBinPath'] "sk-dummy.dll"
        if (Test-Path $candidate) { $skProvider = $candidate }
    }
    $skUnavailable = ($skProvider -eq $null)
    $sk_types = @("ed25519-sk", "ecdsa-sk")

    BeforeAll {
        if($OpenSSHTestInfo -eq $null)
        {
            Throw "`$OpenSSHTestInfo is null. Please run Set-OpenSSHTestEnvironment to set test environments."
        }
        $server = $OpenSSHTestInfo["Target"]
        $port = $OpenSSHTestInfo["Port"]
        $pubKeyUser = $OpenSSHTestInfo["PubKeyUser"]
        $pubKeyUserProfile = $OpenSSHTestInfo["PubKeyUserProfile"]

        $testDir = Join-Path $OpenSSHTestInfo["TestDataPath"] $suite
        if(-not (Test-Path $testDir -PathType Container))
        {
            $null = New-Item $testDir -ItemType directory -Force -ErrorAction SilentlyContinue
        }

        $pubKeyUserSshPath = Join-Path $pubKeyUserProfile .ssh
        $authorizedKeyPath = Join-Path $pubKeyUserSshPath authorized_keys
    }

    AfterEach { $tI++ }

    foreach ($kt in $sk_types)
    {
        Context "$tC - security key type $kt" {
            BeforeAll { $tI = 1 }
            AfterAll {
                if ($authorizedKeyPath -and (Test-Path $authorizedKeyPath))
                {
                    Remove-Item $authorizedKeyPath -Force -ErrorAction SilentlyContinue
                }
                $tC++
            }

            It "$tC.$tI - enroll $kt key using sk-dummy provider" -Skip:$skUnavailable {
                $keyPath = Join-Path $testDir "sk_$kt"
                Remove-Item "$keyPath*" -Force -ErrorAction SilentlyContinue
                ssh-keygen -t $kt -w $skProvider -f $keyPath -N '""'
                $LASTEXITCODE | Should Be 0
                $keyPath | Should Exist
                "$keyPath.pub" | Should Exist
                # The public key must be recorded as a security-key type.
                (Get-Content "$keyPath.pub") | Should Match "sk-"
            }

            It "$tC.$tI - authenticate with $kt security key" -Skip:$skUnavailable {
                $keyPath = Join-Path $testDir "sk_$kt"
                if (-not (Test-Path $keyPath))
                {
                    ssh-keygen -t $kt -w $skProvider -f $keyPath -N '""'
                }

                # Authorize only this security key for the pubkey test user.
                if (-not (Test-Path $pubKeyUserSshPath -PathType Container))
                {
                    New-Item $pubKeyUserSshPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                Copy-Item "$keyPath.pub" $authorizedKeyPath -Force -ErrorAction SilentlyContinue
                Repair-AuthorizedKeyPermission -FilePath $authorizedKeyPath -confirm:$false
                Repair-UserKeyPermission -FilePath $keyPath -confirm:$false

                $o = ssh -p $port -i $keyPath -o SecurityKeyProvider=$skProvider `
                    $pubKeyUser@$server echo 1234
                $o | Should Be "1234"
            }

            It "$tC.$tI - reject unauthorized $kt security key" -Skip:$skUnavailable {
                # Negative control: proves the successful authentication above is
                # genuinely gated on the authorized key, and not a case of sshd
                # accepting any security key (or the test passing blindly).  We
                # authorize one enrolled key and then attempt to log in with a
                # *different* enrolled key that is not in authorized_keys; that
                # attempt must be refused.
                $authKey = Join-Path $testDir "sk_$kt"
                $otherKey = Join-Path $testDir "sk_${kt}_unauth"
                if (-not (Test-Path $authKey))
                {
                    ssh-keygen -t $kt -w $skProvider -f $authKey -N '""'
                }
                Remove-Item "$otherKey*" -Force -ErrorAction SilentlyContinue
                ssh-keygen -t $kt -w $skProvider -f $otherKey -N '""'

                # Authorize ONLY $authKey for the pubkey test user.
                if (-not (Test-Path $pubKeyUserSshPath -PathType Container))
                {
                    New-Item $pubKeyUserSshPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                Copy-Item "$authKey.pub" $authorizedKeyPath -Force -ErrorAction SilentlyContinue
                Repair-AuthorizedKeyPermission -FilePath $authorizedKeyPath -confirm:$false
                Repair-UserKeyPermission -FilePath $authKey -confirm:$false
                Repair-UserKeyPermission -FilePath $otherKey -confirm:$false

                # Sanity: the authorized key still works, so a rejection below
                # cannot be caused by a broken daemon/setup (which would make the
                # negative assertion pass for the wrong reason).
                $good = ssh -p $port -i $authKey -o SecurityKeyProvider=$skProvider `
                    $pubKeyUser@$server echo 1234
                $good | Should Be "1234"

                # The unauthorized key must be refused.  Force pubkey-only with
                # no interactive/password fallback so ssh fails fast instead of
                # prompting, exits non-zero, and prints no marker on stdout.
                $out = ssh -p $port -i $otherKey -o SecurityKeyProvider=$skProvider `
                    -o BatchMode=yes -o PreferredAuthentications=publickey `
                    -o PasswordAuthentication=no `
                    $pubKeyUser@$server echo 1234 2>$null
                $LASTEXITCODE | Should Not Be 0
                $out | Should Not Be "1234"
            }
        }
    }
}
