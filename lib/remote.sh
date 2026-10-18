# Shared by install.sh and uninstall.sh: how this computer talks to the device. Sourced, not run.
#
# Nothing the user typed becomes remote shell code. The command the device runs is fixed text; the password travels
# as the first line of ssh's stdin (read there by the shell's read builtin and handed to sudo -S on a pipe), never on
# a command line that ps shows, here or on the device. sshpass takes it from the environment (-e). The payload goes
# into a fresh mktemp -d directory on the device (umask 077), removed when the remote shell exits.

# check_host USER@HOST: a login name and a host name or address, nothing an ssh option or a shell could take apart
check_host() {
    case $1 in *'
'*) ;; *) printf '%s\n' "$1" | LC_ALL=C grep -Eqx '[A-Za-z0-9_][A-Za-z0-9._-]{0,31}@[A-Za-z0-9][A-Za-z0-9.:-]{0,252}' && return 0 ;; esac
    echo "--host wants USER@HOST, for example root@192.168.77.1" >&2
    return 2
}

# remote_cmd HOST SCRIPT [ARG]: the fixed command the device runs. It reads the password line, unpacks the tar
# stream that follows into a new temporary directory and runs SCRIPT from it with the directory and ARG - as root,
# through sudo -S unless the login is root.
remote_cmd() {
    case $2 in ''|*[!A-Za-z0-9._-]*) echo "remote_cmd: bad script name" >&2; return 2 ;; esac
    case ${3:-} in *[!A-Za-z0-9._-]*) echo "remote_cmd: bad argument" >&2; return 2 ;; esac
    case $1 in
        root@*) _run='sh' ;;
        *) _run='printf "%s\n" "$pw" | sudo -S -p "" sh' ;;
    esac
    printf '%s' "umask 077; IFS= read -r pw || exit 1; d=\$(mktemp -d) || exit 1; trap 'rm -rf \"\$d\"' EXIT INT TERM; tar -C \"\$d\" -xf - || exit 1; $_run \"\$d/$2\" \"\$d\" ${3:-}"
}

# remote_run HOST PASSWORD SCRIPT [ARG]: our stdin is the tar stream; the password line goes in front of it
remote_run() {
    _cmd=$(remote_cmd "$1" "$3" "${4:-}") || return 2
    if command -v sshpass >/dev/null 2>&1; then
        { printf '%s\n' "$2"; cat; } | SSHPASS=$2 sshpass -e ssh -o PubkeyAuthentication=no \
            -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -- "$1" "$_cmd"
    else
        { printf '%s\n' "$2"; cat; } | ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -- "$1" "$_cmd"
    fi
}
