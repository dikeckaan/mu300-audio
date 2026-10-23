# mu300-audio

Call audio for the ZTE F50 (MU300) and ZTE U30 Air running [mu300-linux](https://github.com/dikeckaan/mu300-linux):
the audio of a cellular call goes through the Unisoc audio DSP (AGDSP), to a **Bluetooth headset** or to the AP's
own taps on the call (play into it, record from it).

This repository holds the whole call-audio stack, for **every kernel mu300-linux ships** (the vendor 5.4 and the
mainline 6.18, 7.2 and 7.3): the drivers (sources, patches, and the build against each kernel's exact build), the call
scripts `mu300-audio-dsp` and `mu300-voice`, the tools `pcmhost`, `ctlset` and `mu300-hfp`, their services, and
their tests. mu300-linux itself carries none of it since its FINDINGS 194: on the device it is the **audio extra**,

    sudo mu300-extra install audio

the same way the VPN module is `mu300-extra install vpn`.

No proprietary file is in this repository or in any of its releases. The DSP firmware is fetched on the device at
install time and used only if its sha256 is the pinned one (below), or you bring your own.

## Status

* Measured on an F50 on the 5.4 kernel (OpenWrt) with the ZTE Voyage 41S DSP image: the sound card and the DSP come
  up on every boot, and a call carries audio through the AP taps. The other side heard a melody played into the call,
  the downlink was recorded, and `mu300-voice echo` played the caller's voice back to them
  (mu300-linux [FINDINGS 24d, 24e](https://github.com/dikeckaan/mu300-linux/blob/main/docs/FINDINGS.md)). On 6.18 and
  7.2 the same stack, ported, answers too (FINDINGS 188).
* The Bluetooth headset route is built and its link handling tested, but a whole call on a headset under Linux has
  not been measured yet.
* Neither board has a speaker, earpiece or microphone: the headset or the taps are the only outputs.

## Install

On the device (Ubuntu or OpenWrt, a mu300-linux release after v2026.10.19.1), online:

    sudo mu300-extra install audio         # the drivers of the kernel this device uses, and the DSP firmware
    mu300-audio-dsp status                 # cards: sprdphone-sc2730; dsp: running - it answered
    mu300-voice status

That takes `mu300-audio-KERNEL.tar.gz` of this repository's latest release for the kernel the device uses
(`mu300-update kernel` says which), checks it against the release's `SHA256SUMS`, puts it on the Linux partition
(`/mnt/mu300-disk/extra/audio`, shared by both systems, kept by updates) and links it into every installed system:
`/opt/mu300/bin/{mu300-audio-dsp,mu300-voice,pcmhost,ctlset,mu300-hfp}`, the services (`mu300-audio`, which brings
the sound card and the DSP up at boot, and `mu300-voice`, the call follower), `/etc/modprobe.d/mu300-audio.conf`. The
sound card and the DSP start right away; no reboot is needed.

* **Firmware**: fetched with it, from [mu300-audio-firmware](https://github.com/dikeckaan/mu300-audio-firmware)
  (`v1.0/agdsp.bin`), and installed only if its sha256 is exactly
  `378ceea78dbf013e10625e71efd6fab487d727e371884ae8daf078da2828b937` (the ZTE Voyage 41S image measured on an F50),
  into every system that has none (`/lib/firmware/agdsp.bin`). A firmware a system has already is never touched.
  `MU300_AUDIO_FIRMWARE=none` fetches none; `MU300_AUDIO_FIRMWARE=/path/to/your.img` installs your own image instead
  (1 to 6 MiB, an `AUDCP` header; see "Your own firmware").
* **Offline**: copy `mu300-audio-KERNEL.tar.gz`, the release's `SHA256SUMS` and `agdsp.bin` into one directory on the
  device, then `sudo mu300-extra install audio --from DIR`. Or from a computer: `./install.sh` (below).
* **Kernel switches**: `mu300-update kernel 7.2` installs the audio extra of 7.2 along with the kernel (offline: put
  `mu300-audio-7.2.tar.gz` and `SHA256SUMS` into `/mnt/mu300-disk/.mu300-update/audio/` first). If it cannot be had,
  the kernel switch still happens and call audio waits until `mu300-extra install audio`.
* **Updates**: `mu300-update apply` brings the audio extra of the kernel the device uses up to this repository's
  latest release.
* **Remove**: `sudo mu300-extra remove audio` takes it out of every system and puts back what it had replaced (a
  system's own `mu300-voice`, say, kept as `NAME.builtin`), and the firmware it had put there. Reboot afterwards: most
  of the drivers cannot be unloaded.
* `mu300-extra status audio` shows the release and the kernel it is for.

### Coming from mu300-linux v2026.10.19.1 or older

Those releases carried the stack themselves (the mainline drivers and the scripts in the images; on 5.4 the drivers
came from an older version of this repository's `install.sh`). The first update to a release without it
(`mu300-update apply`) sees that the device uses call audio - a DSP firmware is installed - and installs the audio
extra by itself, before the systems are switched, from this repository (or, offline, from
`/mnt/mu300-disk/.mu300-update/audio/`). When it cannot have it, the update goes on and ends with a loud notice, and
`mu300-update check` keeps saying so until `sudo mu300-extra install audio` was run. The firmware stays where it was.

Files of the old 5.4 installer (`/opt/mu300/bin/pcmhost`, `ctlset`, `mu300-hfp`, its `mu300-voice` service) are moved
aside to `NAME.builtin` when the extra is linked, and come back if it is removed. A call follower that was disabled
stays disabled.

### From a computer (`install.sh`)

For a device without internet, or one still on v2026.10.19.1 (its `mu300-extra` does not know `audio` by name: it
installs it as an extra of your own):

    ./install.sh --host root@192.168.77.1                 # OpenWrt; ubuntu@... on Ubuntu (it uses sudo)
    # --from DIR: release files you have (a release's, or tools/make-extra.sh's out/release); --release TAG: that one
    # --firmware FILE: your own image; --no-firmware; --headset AA:BB:CC:DD:EE:FF (a paired headset)
    ./uninstall.sh --host root@192.168.77.1

Everything is checked here first (the tarballs against `SHA256SUMS`, the firmware's hash or header) and again on the
device; the password goes to `sshpass` and `sudo` on stdin or in the environment, never on a command line.

## Your own firmware

One file: the audio DSP image of a **UMS9620 / T760** phone. The measured one is the **ZTE Voyage 41S** (远航 41S)
image: **6291456 bytes**, its header starts with `SharkL5_AUDCP_` ("SharkL5" is Unisoc's lineage name, and it is
right for this SoC), sha256 above. A different UMS9620 / T760 image may work, but is untested. Do **not** use the
Motorola Moto G35 image (`QogirN6Pro_AUDCP_DSP_lit_dm.bin`): it is built for other memory addresses and took an F50
down hard enough to fall back to Android.

Unisoc phones keep the image in the partitions **`l_agdsp_a`** / **`l_agdsp_b`**:

    adb shell su -c 'dd if=/dev/block/by-name/l_agdsp_a of=/sdcard/l_agdsp_a.img'
    adb pull /sdcard/l_agdsp_a.img
    head -c 6291456 l_agdsp_a.img > agdsp.img      # the partition may be larger than the image

or take the file an official Unisoc `.pac` package maps to `l_agdsp` (about 6 MiB, `_AUDCP_` in its first bytes). On
the device: `mu300-audio-dsp install agdsp.img`, or `MU300_AUDIO_FIRMWARE=agdsp.img mu300-extra install audio`.

### DSP parameter files (optional)

`audio_structure.xml`, `dsp_vbc.xml`, `cvs.xml` from `/odm/etc/audio_params/sprd/` of a UMS9620 device;
`tools/vbc-profile` turns them into the blobs the kernel loads from `/lib/firmware/{audio_structure,dsp_vbc,cvs}`
(`mu300-audio-dsp profiles`). Without them the DSP runs the call on its built-in defaults (that is how the measured
calls ran).

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

Put the address in `/etc/mu300/voice.conf` (`BT_HEADSET=...`; `/etc/mu300/voice.conf.example` has the settings) and
restart the follower (`systemctl restart mu300-voice` on Ubuntu, `/etc/init.d/mu300-voice restart` on OpenWrt).

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

## Troubleshooting

* **`drivers: none - ... built for another build of it`**: the extra's drivers were built against another build of
  this kernel release (another mu300-linux release's), and are not loaded: a driver built against another
  configuration would read the kernel's structures at the wrong offsets. Update the extra (`mu300-extra install
  audio`); the release notes name the mu300-linux release each tarball is built for.
* **`drivers: none - the audio extra has drivers for ...`**: the kernel changed without the extra:
  `mu300-extra install audio`.
* **No `sprdphone` card in `mu300-audio-dsp status`**: the drivers did not bind; see `dmesg | grep -i -E 'asoc|audio'`.
* **`dsp: no reply`**: the DSP did not run the image. Compare `/etc/mu300/agdsp.sha256` with the measured one. An
  image built for other addresses does not answer, or takes the board down.
* **`no Hands-Free service found`**: the headset is off, out of range, connected to another phone, or not paired
  (`bluetoothctl info <address>` should say `Paired: yes`, `Trusted: yes`).

Reports go to the [mu300-linux issues](https://github.com/dikeckaan/mu300-linux/issues), with `dmesg`,
`mu300-audio-dsp status` and `mu300-voice status` (check that they carry no phone number before you post them).

## How the drivers are built

A kernel module has to be built against the kernel it is loaded into: on 5.4 the kernel checks the CRC of every
symbol a module uses (modversions); on 6.18 and 7.2 nothing checks, and a module built against another configuration
loads and then reads the kernel's structures at the wrong offsets. So the drivers here are built against the
**build kit** of each kernel of a mu300-linux release: what an out-of-tree module needs from that exact build
(headers, scripts, `.config`, `Module.symvers`; on mainline also `vmlinux` without its DWARF for the modules' BTF,
the modem stack's headers and exports, and the kernel's `virt-dma`). `kernel/kits/make-kit-*.sh` makes the kits from
the release's own build trees, once per mu300-linux release; they are the assets of the `kits-<release>` releases
here, and `kernel/kits/kits.lock` pins each by sha256, with the sha256 of its configuration's settings.

    sh kernel/build.sh 6.18       # downloads kit-6.18.tar.xz, checks it, builds in Docker: out/modules/6.18/
    for t in pcmhost ctlset hfp; do sh src/$t/build.sh; done   # out/bin/, static arm64
    sh tools/make-extra.sh out/release v1.0.0                  # the release files

The build runs natively on arm64 (an Apple Silicon Mac, GitHub's `ubuntu-24.04-arm`), in the toolchain images
mu300-linux builds its kernels with (`kernel/5.4/Dockerfile`: clang 12; `kernel/mainline/Dockerfile`: gcc 15). It
checks that every module is there with the kernel's vermagic and its patches. When the kits were made, the checks
were: on 5.4 all 10889 symbol CRCs the release's own modules carry match the kit's `Module.symvers`; on 6.18 and 7.2
the modem module rebuilt from the kit's tree is byte for byte the release's, and the audio drivers built from the
kits are byte for byte the ones mu300-linux v2026.10.19.1 shipped, apart from the GNU build-id note.

On the device, `mu300-audio-dsp` loads a set only when its `KERNEL` file names the running kernel's own
configuration (the sha256 of `/proc/config.gz`'s settings): a mu300-linux release that changes a kernel's
configuration, or moves a kernel to a new stable release (a new `uname -r`), needs a new release here, built against
its kits.

Such a release keeps the earlier builds too. `kits.lock` may hold more than one line for a kernel: the build of the
newest mu300-linux release first, then the builds before it (6.18.58 and 7.2.12 from mu300-linux v2026.10.23.2 on,
with the 6.18.57 and 7.2.11 builds beside them). `kernel/build.sh KEY` builds them all, and the tarball carries the
earlier set beside the current one, as `modules/<release>+<the first 12 digits of its CONFIG>/`. `mu300-audio-dsp`
loads whichever set fits the running kernel. One tarball then works on a device before and after its mu300-linux
update: the latest release here can come out before that mu300-linux release is promoted, and a device updated
later (or one that could not fetch the new extra during its update) still finds a set. The earlier line goes once
no supported mu300-linux release has that build.

**7.3** (mainline Linux 7.3, mu300-linux's fourth kernel, from v2026.10.22.1 on): its kit is made
from that mu300-linux release's own 7.3 build tree (`make-kit-mainline.sh 7.3 7.3 TAG`; a mainline release's tree is
`linux-7.3`, its kernel release `7.3.0`), like the others. 7.3 put the IIO consumer API into a symbol namespace, so
the headset driver imports `IIO_CONSUMER` there.

**What stays in the kernel** (mu300-linux), because no module can do it: the DSP's memory reserved at boot
(`CONFIG_OF_RESERVED_MEM_ADD`, mu300-linux's `of-reserved-mem-add` patch for 5.4 and `0022` for mainline: memory has to
be reserved before the page allocator owns it), and the ALSA/ASoC/dmaengine core options the drivers link against
(`SND_SOC`, `SND_SOC_SPRD` for the compress layer, `SND_DYNAMIC_MINORS`, `SND_CTL_INPUT_VALIDATION`, `DMADEVICES`; on
5.4 the vendor configuration has them already).

### Releases

Actions > Release > Run workflow on `main`, with the tag (`vMAJOR.MINOR.PATCH`): tests, the tools, the drivers of
every kernel of `kits.lock`, `tools/make-extra.sh`, and the release with `mu300-audio-5.4.tar.gz`,
`mu300-audio-6.18.tar.gz`, `mu300-audio-7.2.tar.gz`, `mu300-audio-7.3.tar.gz`, `VERSIONS` and `SHA256SUMS`. A tag pushed by hand makes a
prerelease of its commit (to test on devices: `MU300_AUDIO_URL=https://github.com/dikeckaan/mu300-audio/releases/download/TAG
mu300-extra install audio`); `mu300-extra` takes the latest full release.

## Layout

| path | what |
|---|---|
| `device/bin/` | `mu300-audio-dsp` (drivers, firmware, DSP), `mu300-voice` (calls, routes, headset) |
| `device/service/`, `device/etc/` | the services (systemd, procd), `modprobe.d`, `voice.conf.example` |
| `hooks/link`, `hooks/unlink` | the extra into a system and out of it (mu300-extra and mu300-update run them) |
| `kernel/5.4/` | Unisoc's 5.4 drivers as published (`audio_driver/`, `SOURCE`), the patches, the build |
| `kernel/mainline/` | the mainline port (`sprd_audio/`), the build |
| `kernel/kits/` | `kits.lock`, and the scripts that make the kits from a release's build trees |
| `kernel/build.sh` | the drivers of one kernel, against its kit |
| `src/` | `pcmhost`, `ctlset`, `mu300-hfp` (static arm64; `build.sh` in each, needs Docker) |
| `tools/make-extra.sh` | the release files |
| `tools/vbc-profile/` | parameter XML to kernel blob converter |
| `install.sh`, `uninstall.sh`, `lib/`, `device/remote-install.sh` | from a computer, over ssh |
| `tests/` | `cd tests && python3 -m unittest discover -s .` |

## Credits

* **kano (kanoqwq)** found that a ZTE Voyage 41S DSP image makes an F50 carry calls on a Bluetooth headset under
  Android, and got cellular call audio working on Linux on the Rongyue E5 (UMS9621, the same DSP and drivers) in
  [e5-linux](https://github.com/kanoqwq/e5-linux) (MIT, © 2026 Enceka). The voice start sequence, the downlink
  unmute, the Bluetooth ordering and kernel patches 0013, 0016, 0017, 0019 and 0020 of e5-linux are ported here;
  each ported piece names its e5-linux commit.
* **Enceka**: [linux-lts-e5](https://github.com/Enceka/linux-lts-e5), the E5's 6.18 port, which the mainline port
  drew on (and its AGCP DMA driver).
* Unisoc wrote the audio drivers (GPL-2.0).

## Licence

Two licences, see [LICENSE](LICENSE): **GPL-2.0** ([kernel/COPYING](kernel/COPYING)) for the drivers - their sources,
patches and builds - and the build kits; **MIT** for the scripts, tools and tests. The AGDSP firmware and the vendor
parameter files belong to Unisoc / ZTE. They are not in this repository or its releases and must not be added.
