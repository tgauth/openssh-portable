#	Placed in the Public Domain.
#
# Windows-only OpenSSH regression-test helpers (fork-local).
#
# regress/test-exec.sh sources this file near the end, but only when
# $os = windows, so it can override POSIX-only helper functions with
# implementations suited to the native Windows binaries and third party
# emulators.  Keeping this logic here (instead of "if windows" branches inside
# the shared upstream test-exec.sh) keeps that file identical to upstream and
# avoids future merge conflicts.
#
# It relies on functions and variables already defined by test-exec.sh:
# windows_path(), fatal(), trace(), verbose(), $OBJ, $SSHKEYGEN, $SSHADD and
# the $TEST_SSH_* variables exported by
# contrib/win32/openssh/bash_tests_iterator.ps1.

# The native ssh-agent matches PKCS#11/security-key provider paths against a
# compiled-in allowlist ("/usr/lib*/*, ...") that never matches the Windows
# paths used by the emulators, so permit any provider for the agent tests.
if test -z "$EXTRA_AGENT_ARGS"; then
	EXTRA_AGENT_ARGS='-P*'
	export EXTRA_AGENT_ARGS
fi

SOFTHSM2_WIN_VERSION=2.5.0

# Locate (or download) the SoftHSM2-for-Windows portable distribution and
# echo its root directory on stdout.  Returns non-zero if it is unavailable
# (e.g. no network); callers skip the test gracefully in that case.  The
# location may be pre-provisioned via $TEST_SSH_SOFTHSM2_DIR and the download
# source overridden via $SOFTHSM2_URL.
p11_softhsm2_windows_dir() {
	_dflt_url="https://github.com/disig/SoftHSM2-for-Windows/releases/download/v${SOFTHSM2_WIN_VERSION}/SoftHSM2-${SOFTHSM2_WIN_VERSION}-portable.zip"
	_url="${SOFTHSM2_URL:-$_dflt_url}"

	# 1. explicit override
	if [ "x$TEST_SSH_SOFTHSM2_DIR" != "x" ] && \
	    [ -f "${TEST_SSH_SOFTHSM2_DIR}/lib/softhsm2-x64.dll" ]; then
		echo "$TEST_SSH_SOFTHSM2_DIR"
		return 0
	fi
	# 2. cached extraction (removed with $OBJ by the test runner)
	_cache="${OBJ}/softhsm2"
	if [ -f "${_cache}/SoftHSM2/lib/softhsm2-x64.dll" ]; then
		echo "${_cache}/SoftHSM2"
		return 0
	fi
	# 3. download + extract
	mkdir -p "$_cache" 2>/dev/null || return 1
	_zip="${_cache}/softhsm2.zip"
	_zip_win=`windows_path "$_zip"`
	_cache_win=`windows_path "$_cache"`
	trace "downloading SoftHSM2 from $_url"
	powershell.exe -NoProfile -NonInteractive -Command \
	    "\$ErrorActionPreference='Stop'; try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri '$_url' -OutFile '$_zip_win'; Expand-Archive -Force '$_zip_win' '$_cache_win' } catch { exit 1 }" \
	    >/dev/null 2>&1 || return 1
	if [ -f "${_cache}/SoftHSM2/lib/softhsm2-x64.dll" ]; then
		echo "${_cache}/SoftHSM2"
		return 0
	fi
	return 1
}

# Windows replacement for p11_setup() using SoftHSM2-for-Windows.  OpenSSH's
# native binaries understand /cygdrive style paths, but the third party
# softhsm2-util.exe and the softhsm2 module do not, so any path handed to
# them (config file, token dir, key files, module) is converted with
# windows_path.  ssh-keygen -m PKCS8 is used to create keys so that no
# OpenSSL command line tool is required.
p11_setup() {
	_hsm=`p11_softhsm2_windows_dir` || return 1
	SOFTHSM2_UTIL="${_hsm}/bin/softhsm2-util.exe"
	test -f "$SOFTHSM2_UTIL" || return 1
	TEST_SSH_PKCS11=`windows_path "${_hsm}/lib/softhsm2-x64.dll"`
	verbose "using token library $TEST_SSH_PKCS11"
	# softhsm2-util.exe is 32-bit and loads the 32-bit softhsm2.dll module;
	# copy it next to the tool so the loader finds it in the exe directory.
	cp -f "${_hsm}/lib/softhsm2.dll" "${_hsm}/bin/softhsm2.dll" 2>/dev/null

	TEST_SSH_PIN=1234
	TEST_SSH_SOPIN=12345678
	if [ "x$TEST_SSH_SSHPKCS11HELPER" != "x" ]; then
		SSH_PKCS11_HELPER="${TEST_SSH_SSHPKCS11HELPER}"
		export SSH_PKCS11_HELPER
	fi

	# setup environment for softhsm2 token
	SSH_SOFTHSM_DIR=$OBJ/SOFTHSM
	export SSH_SOFTHSM_DIR
	rm -rf $SSH_SOFTHSM_DIR
	TOKEN=$SSH_SOFTHSM_DIR/tokendir
	mkdir -p $TOKEN
	# The config file and token dir are read by the third party module, so
	# they must be in Windows format.  SOFTHSM2_CONF is not translated by
	# Cygwin automatically, so export it in Windows format.
	SOFTHSM2_CONF=`windows_path "$SSH_SOFTHSM_DIR/softhsm2.conf"`
	export SOFTHSM2_CONF
	_token_win=`windows_path "$TOKEN"`
	cat > "$SSH_SOFTHSM_DIR/softhsm2.conf" << EOF
# SoftHSM v2 configuration file
directories.tokendir = ${_token_win}
objectstore.backend = file
log.level = INFO
slots.removable = false
EOF
	"$SOFTHSM2_UTIL" --init-token --free --label token-slot-0 \
	    --pin "$TEST_SSH_PIN" --so-pin "$TEST_SSH_SOPIN" >/dev/null 2>&1 || \
	    { trace "softhsm2-util init-token failed"; return 1; }

	trace "generating keys"
	RSA=${SSH_SOFTHSM_DIR}/RSA
	EC=${SSH_SOFTHSM_DIR}/EC
	# ssh-keygen -m PKCS8 writes an unencrypted PKCS#8 private key that
	# softhsm2-util can import directly (no OpenSSL CLI needed).
	${SSHKEYGEN} -t rsa -b 2048 -q -N '' -m PKCS8 -f "$RSA" || \
	    fatal "ssh-keygen RSA (PKCS8) fail"
	${SSHKEYGEN} -t ecdsa -b 256 -q -N '' -m PKCS8 -f "$EC" || \
	    fatal "ssh-keygen EC (PKCS8) fail"
	rm -f "${RSA}.pub" "${EC}.pub"
	${SSHKEYGEN} -y -f "$RSA" > "${RSA}.pub" || fatal "ssh-keygen -y RSA fail"
	${SSHKEYGEN} -y -f "$EC" > "${EC}.pub" || fatal "ssh-keygen -y EC fail"
	# Import by token label; the slot number is assigned dynamically by
	# --init-token --free.  Key paths must be in Windows format.
	"$SOFTHSM2_UTIL" --token token-slot-0 --label 01 --id 01 \
	    --pin "$TEST_SSH_PIN" --import `windows_path "$RSA"` >/dev/null 2>&1 || \
	    fatal "softhsm import RSA fail"
	"$SOFTHSM2_UTIL" --token token-slot-0 --label 02 --id 02 \
	    --pin "$TEST_SSH_PIN" --import `windows_path "$EC"` >/dev/null 2>&1 || \
	    fatal "softhsm import EC fail"
	PKCS11_OK=yes
	return 0
}

# ssh-add reading the token PIN through the Windows askpass helper
# (askpass_util.exe, provided via $TEST_SSH_ASKPASS by the bash test runner),
# which echoes the value of $ASKPASS_PASSWORD.
p11_ssh_add() {
	env SSH_ASKPASS="$TEST_SSH_ASKPASS" SSH_ASKPASS_REQUIRE=force \
	    ASKPASS_PASSWORD="$TEST_SSH_PIN" ${SSHADD} "$@"
}
