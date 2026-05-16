# AlmaLinux 9 Live ISO Builder

Builds a bootable, RAM-resident AlmaLinux 9 live ISO from a configured
reference system. The ISO boots entirely into RAM (`rd.live.ram=1`) so the
USB drive can be removed once the boot completes. No persistence — every
runtime change is discarded on reboot.

## How it works

Two AlmaLinux-specific pieces of tooling do the heavy lifting:

- **Kickstart** is Red Hat's unattended-install format — a text file that
  scripts everything an interactive installer would otherwise ask for
  (disk layout, packages, users, post-install commands). There are two
  kickstarts in this repo. [`kickstart/baseline.ks`](kickstart/baseline.ks)
  drives the initial AlmaLinux install on the reference machine so it
  always starts from a reproducible state.
  [`kickstart/live.ks.template`](kickstart/live.ks.template) is the
  recipe `livemedia-creator` consumes when it assembles the live ISO.
  Scripting both ends keeps the build repeatable and removes the
  hand-clicked installer steps that would otherwise drift between runs.
- **A Dockerfile-based builder** is used because the ISO build pulls in
  RHEL-family tooling — `lorax`, `livemedia-creator`, `anaconda`,
  `pykickstart` — that only ships for RHEL/CentOS/AlmaLinux. Wrapping
  those tools in an `almalinux:9` container means the builder host
  itself doesn't have to be AlmaLinux: anywhere Docker runs (Ubuntu,
  Fedora, macOS with Docker Desktop, etc.) can produce the ISO without
  installing RHEL-specific packages on the host. Pinning the versions in
  the Dockerfile also makes the build environment reproducible across
  operator machines.

You need two machines on the same network:

- A **builder host** with Docker installed (Linux or macOS — anything
  that can run an `almalinux:9` container). This is where the final ISO
  is produced.
- A **reference machine** (bare metal or VM) where you install
  AlmaLinux 9 from scratch and configure it to look exactly like what
  end users should boot into: installed packages, dotfiles, wallpaper,
  autologin, custom Plymouth theme, etc.

**Note:** _The kickstart is a convenience, not a requirement._ If you need a
different partition layout, a different filesystem, encrypted disks,
extra mount points, a non-default desktop spin, or any other
installer-time tweak that `baseline.ks` doesn't cover, you can install
AlmaLinux 9.7 by hand using the normal interactive installer instead.
The only hard constraint is the **9.7** minor release — the live ISO
build is pinned to 9.7 (see [Notes / gotchas](#notes--gotchas)), so the
reference system must match. As long as you finish with a working
AlmaLinux 9.7 desktop and a non-root user you can log in as, the
remaining steps (`customize-boot.sh`, `snapshot.sh`) don't care how the
system was installed.

The build is a handoff between the two. The builder host runs
`scripts/builder-host.sh`, which serves every needed artifact over plain
HTTP at the project root and prints copy-paste commands with the
builder's LAN IP already filled in. The reference machine pulls those
artifacts on demand, and the final snapshot travels back via `scp`:

```
  ┌──────────────┐                            ┌────────────────────┐
  │ Reference VM │ 1. inst.ks=…/baseline.ks   │ Builder host       │
  │              │◄──────── HTTP ─────────────│ (python -m         │
  │  AlmaLinux 9 │                            │  http.server +     │
  │  installer   │ 2. customize-boot.sh,      │  Docker + lorax)   │
  │      +       │    snapshot.sh,            │                    │
  │  customized  │    boot-config.conf        │                    │
  │  desktop     │◄──────── HTTP ─────────────│                    │
  │              │                            │ 4. build-iso.sh    │
  │              │ 3. snapshot tarball,       │    → live ISO in   │
  │              │    users.conf, policy.conf │      data/output/  │
  │              │─────────  scp  ───────────►│                    │
  └──────────────┘                            └────────────────────┘
```

The stages (machine each step runs on shown in brackets):

1. *[Builder Machine]* **Serve.** Run `scripts/builder-host.sh`. It
   starts a `python3 -m http.server` at the project root, makes a
   `data/dropbox/` directory, and prints the URLs and `scp` line the
   reference machine will need.
2. *[Reference Machine]* **Provision.** Boot the AlmaLinux 9 installer
   with `inst.ks=http://<builder>/kickstart/baseline.ks`. The kickstart
   installs a minimal GNOME desktop, creates a `localadmin` user, and
   reboots.
3. *[Reference Machine]* **Customize.** Log in and shape the system:
   install extra packages, drop binaries into `/opt`, tweak dconf, set
   GDM autologin, etc. Then run `customize-boot.sh` to install a
   Plymouth theme and patch GRUB.
4. *[Reference Machine]* **Snapshot.** `snapshot.sh` tarballs the parts
   of the reference that carry the customization (`/home`, `/opt`,
   `/etc/dconf`, `/etc/gdm`, `/etc/plymouth`, `/etc/default/grub`, …)
   and auto-generates `users.conf` and `policy.conf` from the live
   system.
5. *[Reference Machine → Builder Machine]* **Return.** `scp` the three
   artifacts — tarball plus the two configs — back to `data/dropbox/`
   on the builder.
6. *[Builder Machine]* **Bake.** `build-iso.sh` substitutes the tarball
   (base64-encoded), the users, and the policy into
   `kickstart/live.ks.template`, validates it, then runs
   `livemedia-creator` inside a lorax container to produce the final
   ISO under `data/output/`.

The resulting ISO is **RAM-resident**: once it finishes loading, the
USB stick can be removed, and every byte the user touches lives in
memory. There is no persistent write path. A reboot returns the system
to exactly the snapshot you took on the reference machine. That
property is what the whole flow exists to deliver — fleet workstations
that come up identically every morning regardless of what the previous
user did.

## Repository layout

```
almalinux9-live-builder/
├── README.md                   # This file
├── Dockerfile                  # almalinux:9 build container with lorax
├── scripts/
│   ├── build-iso.sh            # Docker-based ISO builder
│   ├── builder-host.sh         # Serves all hosted artifacts over HTTP
│   ├── customize-boot.sh       # Configures Plymouth / GRUB splash on the reference
│   └── snapshot.sh             # Captures reference state + auto-generates configs
├── kickstart/
│   ├── baseline.ks             # Hosted kickstart that builds the reference system
│   └── live.ks.template        # Live ISO kickstart template (placeholders)
├── config/
│   └── boot-config.conf        # Input file for customize-boot.sh
├── examples/
│   ├── users.conf.example
│   ├── policy.conf.example
│   └── boot-config.conf.example
└── data/                       # Runtime state (gitignored)
    ├── build/                  # Temp build artifacts
    ├── dropbox/                # Where the reference scps the snapshot tarball
    └── output/                 # Final ISO lands here
```

## Host requirements

The build host only needs Docker — no RHEL-specific tooling:

* Docker Engine 20.10+ (works on Debian/Ubuntu, Fedora, AlmaLinux, macOS
  with Docker Desktop, etc.)
* Minimum 15 GB free disk space
* Minimum 8 GB RAM
* bash 4 or later

## End-to-end workflow

> **Trust assumption:** this workflow assumes the LAN between the
> reference machine and the builder is trusted. The `curl | sudo bash`
> pattern executes arbitrary code fetched from the builder. Do not use
> this flow over an untrusted network.

There are two operator paths. The **HTTP-hosted path** below is the
recommended primary flow — the builder host serves every artifact over
HTTP, the reference machine pulls them directly, and the snapshot tarball
travels back via `scp`. There is also a [manual-copy fallback](#manual-copy-fallback)
for air-gapped or USB-shuttling scenarios.

### 0. Start the artifact server on the builder

```
./scripts/builder-host.sh           # default: bind 0.0.0.0:8000
```

`builder-host.sh` auto-detects this machine's LAN IP, makes a
`data/dropbox/` directory under the project root, then runs
`python3 -m http.server` from the project root. It also prints copy-paste-ready commands for the
reference machine, with the builder IP filled in (look for the URLs in
its output). Override with `--port`, `--bind`, `--advertised-host`, or
`--dropbox` if needed.

Leave it running in the foreground — Ctrl-C stops it cleanly.

### 1. Provision the reference system

Boot the AlmaLinux 9 installer on the reference machine (bare metal or
VM). At the boot prompt append:

```
inst.ks=http://<builder>:8000/kickstart/baseline.ks
```

The kickstart pulls from official AlmaLinux US mirrors and creates a
`localadmin` user (UID 1000, password `changeme`, forced to change on
first login).

### 2. Customize the reference system

Log in as `localadmin`, install whatever extra software you need
(`sudo dnf install …`), drop binaries into `/opt`, configure dotfiles,
wallpapers, dconf settings, GDM autologin, etc. Then configure the boot
splash:

```
cd /tmp
wget http://<builder>:8000/config/boot-config.conf
vi boot-config.conf                                       # edit theme, etc.
curl -fsSL http://<builder>:8000/scripts/customize-boot.sh -o customize-boot.sh
sudo bash customize-boot.sh                               # picks up ./boot-config.conf
```

`customize-boot.sh`:

* installs Plymouth if missing
* installs any custom Plymouth theme directory
* sets the Plymouth default theme
* updates `/etc/default/grub` (`GRUB_TIMEOUT`, `GRUB_CMDLINE_LINUX`,
  background, gfxmode)
* regenerates `/boot/grub2/grub.cfg` (and the UEFI grub.cfg if present)
* runs `dracut -f --regenerate-all` so the theme is in the initramfs
* logs everything to `/tmp/customize-boot.log` (kept out of `/var/log`
  so the log never bleeds into a snapshot/live ISO)

`--config` defaults to `./boot-config.conf` in the current directory, so
the workflow above works without an explicit flag.

### 3. Snapshot the reference system

From a directory with at least a few GB free (the tarball can be large):

```
cd /var/tmp
curl -fsSL http://<builder>:8000/scripts/snapshot.sh | sudo bash
```

`--output-dir` defaults to `$PWD/build-inputs`, so this produces:

* `build-inputs/system-snapshot.tar.gz` — `/home`, `/opt`, `/etc/skel`,
  `/etc/dconf/{db,profile}`, `/etc/gdm`, `/etc/systemd/logind.conf`,
  `/etc/profile.d`, `/etc/plymouth`, `/etc/default/grub`,
  `/usr/share/plymouth/themes`
* `build-inputs/MANIFEST.txt` — list of captured paths with sizes/mtimes
* `build-inputs/users.conf` — auto-generated from `/etc/passwd`
  (UIDs ≥ 1000). Every password is `CHANGE_ME` — **edit before building**.
* `build-inputs/policy.conf` — auto-generated from current dconf and
  logind state (screen blank, screen lock, lockout, suspend, screensaver,
  GDM autologin).

The script warns if the tarball exceeds 500 MB and if it sees machine-
specific state (static NM connections, hostname, etc.).

### 4. Return the artifacts to the builder

From the reference machine:

```
scp build-inputs/system-snapshot.tar.gz \
    build-inputs/users.conf \
    build-inputs/policy.conf \
    <you>@<builder>:<path-to>/almalinux9-live-builder/data/dropbox/
```

`builder-host.sh` prints the exact `scp` line with `$USER`, the builder
IP, and the dropbox path pre-filled.

**scp account:** scp from the reference machine to the **same user
account that runs `builder-host.sh`** on the builder. The dropbox
directory is created mode `0755` owned by that user, so files dropped
in as that user are immediately readable by `build-iso.sh` (which runs
as the same operator). Using a different account on the builder side
can land files that `build-iso.sh` cannot read.

### 5. Build the ISO

Back on the builder, edit `data/dropbox/users.conf` to replace every
`CHANGE_ME` with a real password, then:

```
./scripts/build-iso.sh \
    --snapshot ./data/dropbox/system-snapshot.tar.gz \
    --template ./kickstart/live.ks.template \
    --users    ./data/dropbox/users.conf \
    --policy   ./data/dropbox/policy.conf \
    --output   almalinux9-live-custom.iso
```

Optional flags:

* `--hostname <name>`         (default `livecd`)
* `--desktop gnome|kde`       (default `gnome`)
* `--extra-packages a,b,c`    extra RPMs to install
* `--image <name:tag>`        Docker image name (default
                              `almalinux9-live-builder:latest`)
* `--rebuild-image`           force rebuild of the Docker image

What `build-iso.sh` does:

1. Verifies Docker is installed and the daemon is reachable.
2. Builds the Docker image from `Dockerfile` if missing or
   `--rebuild-image` is set.
3. Base64-encodes the snapshot tarball.
4. Generates a user-creation bash block from `users.conf`.
5. Generates a dconf + logind policy block from `policy.conf`.
6. Resolves `--desktop` to the right package group.
7. Substitutes all `%%…%%` placeholders in `kickstart/live.ks.template`
   to produce `data/build/iso-build.*/live.ks`.
8. Runs `ksvalidator` (inside the container) against `live.ks`.
9. Invokes `livemedia-creator --no-virt --make-iso --iso-only …` inside
   the container, with the build dir and `data/output/` mounted as volumes.
10. Promotes the resulting ISO to `data/output/<name>.iso`.

On failure it prints the last 50 lines of `data/output/lorax.log` and
exits non-zero. Temp directories under `data/build/iso-build.*` are
cleaned up on exit via a `trap`.

### 6. Test the ISO

UEFI:

```
qemu-system-x86_64 -enable-kvm -m 4096 \
    -cdrom data/output/almalinux9-live-custom.iso \
    -bios /usr/share/OVMF/OVMF_CODE.fd
```

Legacy BIOS:

```
qemu-system-x86_64 -enable-kvm -m 4096 \
    -cdrom data/output/almalinux9-live-custom.iso
```

Or upload to Proxmox / VirtualBox / VMware and boot.

### 7. Deploy to USB

```
sudo dd if=data/output/almalinux9-live-custom.iso \
        of=/dev/sdX bs=4M status=progress oflag=sync
```

Then on the target machine:

1. Disable Secure Boot in BIOS.
2. Boot from USB.
3. Wait for the full RAM load to complete (a Plymouth progress bar runs).
4. Remove the USB drive.
5. Use the system normally — everything is in RAM and discarded on
   reboot.

## Manual-copy fallback

If the reference machine can't reach the builder over HTTP/SSH (air-gapped
labs, USB-shuttling between sites, etc.), skip `builder-host.sh` and
move files by hand:

1. Copy `kickstart/baseline.ks` to any HTTP server reachable by the
   AlmaLinux 9 installer, or burn it onto the install media at
   `/ks.cfg`. Boot the installer with `inst.ks=...` as usual.
2. After install, copy `scripts/customize-boot.sh`,
   `config/boot-config.conf`, and `scripts/snapshot.sh` to the reference
   machine via USB. Run:

   ```bash
   sudo ./customize-boot.sh --config ./boot-config.conf
   sudo ./snapshot.sh --output-dir ./build-inputs/
   ```

3. Copy `./build-inputs/` back to the builder (USB, scp, whatever),
   review/edit `users.conf` and `policy.conf`, then run
   `./scripts/build-iso.sh` as in [step 5](#5-build-the-iso).

## File reference

### `boot-config.conf`

| Key                          | Meaning                                                  | Default      |
|------------------------------|----------------------------------------------------------|--------------|
| `plymouth_theme`             | Plymouth theme name                                      | (required)   |
| `plymouth_custom_theme_dir`  | Directory with a custom theme to install                 | (empty)      |
| `grub_timeout`               | GRUB menu timeout, seconds                               | `3`          |
| `grub_background`            | Path to GRUB background image                            | (empty)      |
| `show_kernel_messages`       | `true` → `loglevel=7`; `false` → `loglevel=3`            | `false`      |
| `show_progress_bar`          | Pass `splash rhgb` on cmdline                            | `true`       |
| `splash_resolution`          | Hint for `GRUB_GFXMODE`, e.g. `1920x1080`                | (empty)      |
| `boot_quiet`                 | Pass `quiet` on cmdline                                  | `true`       |

### `users.conf`

```
username:uid:shell:groups:password
```

`groups` is comma-separated; the first entry is treated as the primary
group. `password=CHANGE_ME` is rejected by `build-iso.sh`.

### `policy.conf`

| Key                              | Meaning                          | Default |
|----------------------------------|----------------------------------|---------|
| `screen_blank_timeout_seconds`   | dconf `idle-delay`               | `300`   |
| `screen_lock_enabled`            | dconf screensaver lock           | `true`  |
| `auto_lockout_timeout_seconds`   | dconf `lock-delay`               | `600`   |
| `suspend_enabled`                | logind + dconf suspend           | `false` |
| `screensaver_enabled`            | dconf `idle-activation-enabled`  | `true`  |
| `gdm_autologin_enabled`          | GDM autologin on/off             | `false` |
| `gdm_autologin_user`             | autologin user (when enabled)    | (empty) |

## Notes / gotchas

* The kickstart embeds the snapshot tarball as base64 inside the `%post`
  section. This is required because the `livemedia-creator` chroot cannot
  reach host paths directly.
* `rd.live.ram=1` is what makes the USB removable after boot. Don't strip
  it.
* The live image locks the root account; only users defined in
  `users.conf` can log in.
* The Dockerfile pins `lorax`/`anaconda`/`pykickstart` via build-args.
  Bump them deliberately when AlmaLinux updates.
* AlmaLinux minor release is pinned to **9.7** in both
  [`kickstart/baseline.ks`](kickstart/baseline.ks) and [`kickstart/live.ks.template`](kickstart/live.ks.template)
  via explicit `--baseurl=https://repo.almalinux.org/almalinux/9.7/...`
  lines. To bump to 9.8, 9.9, etc., edit the URLs in **both** files
  together — they must stay in lockstep so the reference system and the
  live ISO are built from the same minor release.
* `build-iso.sh` uses `set -euo pipefail` and a single `trap cleanup
  EXIT`. The temp build dir under `data/build/iso-build.*` is always
  cleaned up, even on failure.
* Script logs: `snapshot.sh` → `/var/log/snapshot.log`,
  `customize-boot.sh` → `/tmp/customize-boot.log` (deliberately not in
  `/var/log` so it doesn't bleed into snapshots), `build-iso.sh` →
  stdout. All log lines carry UTC timestamps.

## Building incrementally

Recommended order if you're modifying or debugging:

1. Get `snapshot.sh` working on a known-good reference VM and verify the
   generated `users.conf`/`policy.conf` look right.
2. Then `customize-boot.sh` — boot the reference VM and confirm the
   Plymouth splash and GRUB menu look right.
3. Then `build-iso.sh` placeholder substitution only — temporarily comment
   out the `docker run … livemedia-creator` step and inspect the generated
   `live.ks` and the `ksvalidator` output.
4. Finally enable the full container-based ISO build.
