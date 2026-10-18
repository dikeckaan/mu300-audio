# Sourced by remote-install.sh and remote-uninstall.sh (as root on the device): where the install keeps its list of
# files and its backups, and the checks that make them safe to act on. The list says which paths uninstall removes
# and restores as root, so it is read only from a directory root alone can write, and only paths install.sh can
# put there count; anything else in it is refused.

KREL_AUDIO=5.4.254-gb50db5b6224c
# /var/lib on Ubuntu; on OpenWrt /var is /tmp (tmpfs, and /tmp is world-writable), so /etc/mu300/audio there
if [ -f /etc/openwrt_release ]; then STATE=/etc/mu300/audio; else STATE=/var/lib/mu300-audio; fi
BK=$STATE/backup
MANIFEST=$STATE/installed
# the owner state files must have: root, or (for tests only) MU300_AUDIO_STATE_UID
STATE_UID=${MU300_AUDIO_STATE_UID:-0}

# owned PATH: exists, is not a symlink, belongs to STATE_UID and nobody else can write it
owned() {
    [ -e "$1" ] && [ ! -L "$1" ] || return 1
    # shellcheck disable=SC2046
    set -- $(ls -ldn "$1")
    case $1 in ?????w*|????????w*) return 1 ;; esac
    [ "$3" = "$STATE_UID" ]
}

# trusted_path PATH: PATH and every directory above it are owned (the root directory is taken as given)
trusted_path() {
    _p=$1
    while [ -n "$_p" ] && [ "$_p" != / ]; do
        owned "$_p" || { echo "refusing $1: $_p is not root's alone (owner, mode or a symlink)" >&2; return 1; }
        _p=${_p%/*}
    done
}

# state_ok: STATE (if it exists) and the list in it can be trusted; a missing STATE is fine (nothing installed)
state_ok() {
    [ -e "$STATE" ] || return 0
    trusted_path "$STATE" || return 1
    [ ! -e "$MANIFEST" ] || trusted_path "$MANIFEST"
}

# allowed PATH: one of the paths install.sh installs, written exactly
allowed() {
    case $1 in
        "/lib/modules/$KREL_AUDIO/audio" | \
        /opt/mu300/bin/pcmhost | /opt/mu300/bin/ctlset | /opt/mu300/bin/mu300-hfp | \
        /opt/mu300/bin/mu300-voice | /opt/mu300/bin/mu300-audio-dsp | \
        /lib/firmware/agdsp.bin | /lib/firmware/audio_structure | /lib/firmware/dsp_vbc | /lib/firmware/cvs | \
        /etc/mu300/agdsp.sha256 | /etc/mu300/voice.conf | \
        /etc/systemd/system/mu300-voice.service | /etc/init.d/mu300-voice) return 0 ;;
    esac
    return 1
}

# manifest_ok: every line of the list is an allowed path
manifest_ok() {
    [ -f "$MANIFEST" ] || return 0
    while IFS= read -r _l || [ -n "$_l" ]; do
        allowed "$_l" || { echo "refusing $MANIFEST: it lists a path install.sh never installs" >&2; return 1; }
    done < "$MANIFEST"
}
