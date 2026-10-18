#!/bin/sh
# Take call audio off the device again: every file install.sh put there is removed, and what it replaced comes back
# from the backup device/remote-install.sh made (/var/lib/mu300-audio, on OpenWrt /etc/mu300/audio).
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
# the device half (device/remote-uninstall.sh, with device/state.sh) goes into a fresh temporary directory there
COPYFILE_DISABLE=1 tar -C "$HERE/device" -cf - remote-uninstall.sh state.sh | remote_run "$HOST" "$PW" remote-uninstall.sh
