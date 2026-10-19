#!/bin/sh
# Take call audio off the device again: mu300-extra remove audio there - the extra out of every system, what it had
# replaced back (NAME.builtin), and the firmware it had put there (your own stays). Reboot afterwards: most of the
# drivers cannot be unloaded.
#
#   ./uninstall.sh [--host USER@IP] [--password PW]
set -eu
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/remote.sh"
HOST=root@192.168.77.1
PW=ubuntu
while [ $# -gt 0 ]; do
    case $1 in
        --host) HOST=$2; shift 2 ;;
        --password) PW=$2; shift 2 ;;
        *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done
check_host "$HOST" || exit 2
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT INT TERM
printf '#!/bin/sh\nexport PATH="$PATH:/opt/mu300/bin:/usr/sbin:/sbin"\nmu300-extra remove audio\n' > "$S/remote-uninstall.sh"
COPYFILE_DISABLE=1 tar -C "$S" -cf - remote-uninstall.sh | remote_run "$HOST" "$PW" remote-uninstall.sh
