# mu300-audio

Call audio for the ZTE F50 (MU300) and ZTE U30 Air running [mu300-linux](https://github.com/dikeckaan/mu300-linux)
on its **vendor 5.4 kernel**: the audio of a cellular call goes through the Unisoc audio DSP (AGDSP), to a
**Bluetooth headset** or to the AP's own taps on the call (play into it, record from it).

This repository holds what mu300-linux does not ship for 5.4: the 23 prebuilt audio drivers with their patches, the
installer and uninstaller, the Bluetooth hands-free helper and the two small ALSA tools the call scripts run. The
call scripts themselves (`mu300-voice`, `mu300-audio-dsp`) are part of mu300-linux and are used as the release
ships them.

**On the mainline kernels (6.18, 7.2) you do not need this repository:** the same audio stack, ported, is built into
every mu300-linux release ([FINDINGS 188](https://github.com/dikeckaan/mu300-linux/blob/main/docs/FINDINGS.md)).
There you only supply the firmware (`mu300-audio-dsp install FILE` on the device, then reboot).

No proprietary file is in this repository. You supply the DSP firmware yourself, from your own phone or its official
firmware package, and `.gitignore` keeps firmware images and vendor XMLs out of it.

## Status

* Measured on an F50 on the 5.4 kernel (OpenWrt) with the ZTE Voyage 41S DSP image: the sound card and the DSP come
  up on every boot, and a call carries audio through the AP taps. The other side heard a melody played into the call,
  the downlink was recorded, and `mu300-voice echo` played the caller's voice back to them
  (mu300-linux [FINDINGS 24d, 24e](https://github.com/dikeckaan/mu300-linux/blob/main/docs/FINDINGS.md)).
* The Bluetooth headset route is built and its link handling tested, but a whole call on a headset under Linux has
  not been measured yet.
* Neither board has a speaker, earpiece or microphone: the headset or the taps are the only outputs.

## Devices and systems

* ZTE F50 (MU300) and ZTE U30 Air (UMS9620 / Unisoc T760) running **mu300-linux v2026.10.18.1 or later**, with
  **Ubuntu 24.04 or OpenWrt**.
* **Kernel 5.4** (`5.4.254-gb50db5b6224c`, the vendor kernel of the releases). Ubuntu 26.04 cannot run 5.4: use
  Ubuntu 24.04 or OpenWrt, or a mainline kernel (see above).
* A computer with `ssh` and `tar` (Linux or macOS; `sshpass` saves the password prompts, `python3` is needed only
  for `--params` XMLs).

## The firmware (you supply it)

One file: the audio DSP image of a **UMS9620 / T760** phone. The image measured on an F50 is the **ZTE Voyage 41S**
image (远航 41S):

* **6291456 bytes** (6 MiB);
* its header starts with `SharkL5_AUDCP_` (for example `SharkL5_AUDCP_2022Y_VER_2548`; "SharkL5" is Unisoc's
  lineage name, and it is right for this SoC);
* sha256 `378ceea7…b937` (in full: `378ceea78dbf013e10625e71efd6fab487d727e371884ae8daf078da2828b937`).

`install.sh` tells you whether your file is that one. A different UMS9620 / T760 image is installed too, but it is
**untested**. Do **not** use the Motorola Moto G35 image (`QogirN6Pro_AUDCP_DSP_lit_dm.bin`): it is built for other
memory addresses and took an F50 down hard enough to fall back to Android.

Unisoc phones keep the image in the partitions **`l_agdsp_a`** / **`l_agdsp_b`**.

* **From your own rooted phone** (Magisk or similar):

      adb shell su -c 'dd if=/dev/block/by-name/l_agdsp_a of=/sdcard/l_agdsp_a.img'
      adb pull /sdcard/l_agdsp_a.img
      head -c 6291456 l_agdsp_a.img > agdsp.img      # the partition may be larger than the image

* **From the phone maker's official firmware package** (a Unisoc `.pac` file): unpack it with a PAC unpacker and take
  the file the package maps to `l_agdsp` (about 6 MiB, with `_AUDCP_` in its first bytes). Use only the official
  package for a device you own.

Keep the file outside this repository, or under `firmware/`, which git ignores.

### DSP parameter files (optional)

`audio_structure.xml`, `dsp_vbc.xml`, `cvs.xml` from `/odm/etc/audio_params/sprd/` (or
`/vendor/etc/audio_params/sprd/`) of a UMS9620 device. A U30 Air has its own under Android:

    adb shell su -c 'cp /odm/etc/audio_params/sprd/{audio_structure,dsp_vbc,cvs}.xml /sdcard/'
    adb pull /sdcard/audio_structure.xml; adb pull /sdcard/dsp_vbc.xml; adb pull /sdcard/cvs.xml

Put them in one directory and pass it as `--params`; `tools/vbc-profile` turns them into the blobs the kernel loads.
Without them the DSP runs the call on its built-in defaults (that is how the measured calls ran).

## Install

1. On the device, switch to kernel 5.4 and reboot (this downloads the 5.4 boot image of your release, so the device
   needs internet):

       ssh root@192.168.77.1          # OpenWrt; ubuntu@192.168.77.1 and sudo on Ubuntu
       mu300-update kernel 5.4
       reboot

2. On your computer, from a clone of this repository:

       git clone https://github.com/dikeckaan/mu300-audio && cd mu300-audio
       ./install.sh --firmware ~/agdsp.img --host root@192.168.77.1
       # optional: --params DIR (the XMLs above), --headset AA:BB:CC:DD:EE:FF (a paired headset, see below)

   `--host ubuntu@192.168.77.1` for Ubuntu (it uses `sudo`); `--password` if yours is not `ubuntu`. The firmware is
   checked here first (size, `AUDCP` header, sha256), so nothing on the device changes for a wrong file. A later run
   without `--firmware` keeps the image already installed.

3. Reboot the device, then check:

       mu300-audio-dsp status     # cards: sprdphone-sc2730; dsp: running - it answered
       mu300-voice status

What goes where (everything it replaces is backed up first, under `/var/lib/mu300-audio/backup`, on OpenWrt
`/etc/mu300/audio/backup` because its `/var` is tmpfs):

| what | where |
|---|---|
| the 23 audio drivers | `/lib/modules/5.4.254-gb50db5b6224c/audio/` |
| `pcmhost`, `ctlset`, `mu300-hfp` | `/opt/mu300/bin/` |
| the firmware (its sha256 in `/etc/mu300/agdsp.sha256`) | `/lib/firmware/agdsp.bin` |
| the parameter blobs, if given | `/lib/firmware/{audio_structure,dsp_vbc,cvs}` |
| settings (headset address, output, volume) | `/etc/mu300/voice.conf` |
| the call follower (`mu300-voice watch`) | `mu300-voice.service` (Ubuntu) / `/etc/init.d/mu300-voice` (OpenWrt) |

`mu300-audio-dsp` (loads the drivers and starts the DSP at boot) and `mu300-voice` (follows calls and routes them)
come with mu300-linux. The first versions of this installer put their own, older copies of the two over the
release's; a new install keeps the release's copies or puts them back (or, if it cannot, asks you to update).

A release update (`mu300-update`) installs a new system image, which does not bring this stack's tools: run
`install.sh` again afterwards. The update keeps `/lib/firmware` and `/etc/mu300`, so `--firmware` is not needed
again.

## Bluetooth headset

Pair it once, on the device:

    bluetoothctl
      power on
      scan on                  # put the headset in pairing mode; wait for its address
      pairable on
      discoverable on          # only for this step
      pair AA:BB:CC:DD:EE:FF
      trust AA:BB:CC:DD:EE:FF
      discoverable off
      pairable off
      scan off
      quit

Put the address in `/etc/mu300/voice.conf` (`BT_HEADSET=...`, or `--headset` at install) and restart the follower
(`systemctl restart mu300-voice` on Ubuntu, `/etc/init.d/mu300-voice restart` on OpenWrt).

The device connects to the headset at the start of every call and lets it go when the call ends, so the headset
should be on and not connected to another phone. Its button answers an incoming call and hangs up. Narrowband audio
(CVSD, 8 kHz) only.

Security: `mu300-hfp` never listens for connections. It connects out, only to the address in `voice.conf`, only if
BlueZ holds a link key for it, and only over an authenticated, encrypted link. The headset's AT commands go through
a strict allow-list: answering and hanging up run two fixed `mu300-at` commands, dialling and voice dial are refused,
and nothing the headset sends reaches the modem. Logs never carry a full phone number, and no call history is kept.

## Try it

Use a free service number (your carrier's voicemail or balance line), never an emergency number.

    mu300-at 'ATD<number>;'        # or answer an incoming call: mu300-at ATA
    mu300-voice status             # scene: running
    logread -f | grep mu300-voice  # OpenWrt;  journalctl -fu mu300-voice on Ubuntu
    mu300-at AT+CHUP

Without a headset, the AP taps show whether the DSP moves call audio:

    mu300-voice audio start dsp    # during a call
    mu300-voice tone               # the other side hears a melody
    mu300-voice echo 5             # they hear themselves 5 s later: both directions at once
    mu300-voice audio stop

## Uninstall

    ./uninstall.sh --host root@192.168.77.1

removes every file `install.sh` put on the device and restores what it had replaced. Reboot afterwards. Back to a
mainline kernel: `mu300-update kernel 7.2` (or `6.18`) and reboot.

## Troubleshooting

* **No `sprdphone` card in `mu300-audio-dsp status`**: the drivers did not bind; see
  `dmesg | grep -i -E 'asoc|audio'`. A reboot after the install is needed.
* **`dsp: no reply`**: the DSP did not run the image. Compare `/etc/mu300/agdsp.sha256` with the measured one. An
  image built for other addresses does not answer, or takes the board down.
* **`no Hands-Free service found`**: the headset is off, out of range, connected to another phone, or not paired
  (`bluetoothctl info <address>` should say `Paired: yes`, `Trusted: yes`).
* **The board fell back to Android**: `su -c mu300-linux` in Android arms Linux again; then `./uninstall.sh`, or
  `mu300-update kernel 7.2` to leave 5.4.

Reports go to the [mu300-linux issues](https://github.com/dikeckaan/mu300-linux/issues), with `dmesg`,
`mu300-audio-dsp status` and `mu300-voice status` (check that they carry no phone number before you post them).

## Layout

| path | what |
|---|---|
| `install.sh`, `uninstall.sh`, `lib/remote.sh` | run on your computer; they talk to the device over ssh (the password goes to `sshpass` and `sudo` on stdin or in the environment, never on a command line; the payload goes into a fresh `mktemp -d` directory) |
| `device/` | what goes on the device: the static tools, the service files, the device half of the installer |
| `kernel/modules/5.4.254-gb50db5b6224c/` | the 23 drivers, built with the patches below |
| `kernel/patches/` | the 5.4 audio driver patches |
| `src/` | sources of `pcmhost`, `ctlset`, `mu300-hfp` (static arm64; `build.sh` in each, needs Docker) |
| `tools/vbc-profile/` | parameter XML to kernel blob converter |
| `tests/` | the installer's local checks: `python3 -m unittest discover tests` |

To rebuild the drivers, use `kernel/build-audio.sh` in mu300-linux: it fetches the same driver sources at a pinned
revision, applies the same seven patches and builds the same 23 modules against the release's 5.4 kernel.

## Credits

* **kano (kanoqwq)** found that a ZTE Voyage 41S DSP image makes an F50 carry calls on a Bluetooth headset under
  Android, and got cellular call audio working on Linux on the Rongyue E5 (UMS9621, the same DSP and drivers) in
  [e5-linux](https://github.com/kanoqwq/e5-linux) (MIT, © 2026 Enceka). The voice start sequence, the downlink
  unmute, the Bluetooth ordering and kernel patches 0013, 0016, 0017, 0019 and 0020 of e5-linux are ported here;
  each ported piece names its e5-linux commit.
* **Enceka**: [linux-lts-e5](https://github.com/Enceka/linux-lts-e5), the E5's 6.18 port, which the mainline port in
  mu300-linux drew on.
* Unisoc wrote the audio drivers (GPL-2.0).

## Licence

Two licences, see [LICENSE](LICENSE):

* **GPL-2.0** ([kernel/COPYING](kernel/COPYING)) for `kernel/patches/` and the modules in `kernel/modules/`. They
  derive from Unisoc's GPL-2.0 audio driver sources for 5.4, as published in realme's kernel source release
  ([realme_C51_C53_Narzo-N53-AndroidT-kernel-source](https://github.com/realme-kernel-opensource/realme_C51_C53_Narzo-N53-AndroidT-kernel-source),
  `kernel_modules/kernel5.4/audio_driver`, the revision pinned in mu300-linux's `kernel/build-audio.sh`).
* **MIT** for the scripts and tools (`install.sh`, `uninstall.sh`, `device/`, `src/`, `tools/`, `tests/`), the same
  as mu300-linux.

The AGDSP firmware and the vendor parameter files belong to Unisoc / ZTE. They are not in this repository and must
not be added to it.
