# deb2arch

Convert a Debian `.deb` package into a native Arch Linux package (`.pkg.tar.zst`)
inside a disposable Docker container based on `archlinux:latest`.

Nothing is installed on your host: you mount a directory with the `.deb`, run the
container, and get a `.pkg.tar.zst` next to it.

## Contents

| File | Purpose |
|---|---|
| `Dockerfile` | Build environment: Arch Linux, `makepkg`, `yay`, `debtap`, initialized pacman keyring |
| `convert.sh` | Conversion script (container entrypoint) |
| `shim.sh` | Compatibility layer for Debian-only commands used by maintainer scripts (copied into the image, embedded into generated `.install` files) |

## Quick start

```bash
# 1. Build the image
docker build -t deb2arch .

# 2. Convert (the .deb must be in the mounted directory)
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD:/work" \
  -e DEPENDS="glibc gcc-libs zlib" \
  deb2arch /work/mypackage.deb

# 3. Install on Arch
sudo pacman -U mypackage-1.0-1-x86_64.pkg.tar.zst
```

The result is written to the directory of the input file (override with `OUT_DIR`).

## Modes

### `manual` (default)

The script unpacks the `.deb`, reads `control`, generates a `PKGBUILD` and runs
`makepkg`. Everything is deterministic and visible, but **Debian dependencies are
not translated automatically**: pass the Arch equivalents yourself via `DEPENDS`.

What it does:

1. Extracts `control.tar.*` and `data.tar.*` with `bsdtar` (xz, gz, zstd, bz2 all work).
2. Maps metadata to Arch conventions:
   - **Version**: epoch (`1:`) goes to `epoch=`, the Debian revision (`-1ubuntu2`) is dropped,
     `-` and `~` are replaced with `_`; `pkgrel` is always `1`.
   - **Architecture**: `amd64`→`x86_64`, `arm64`→`aarch64`, `armhf`→`armv7h`, `i386`→`i686`, `all`→`any`.
   - **`conffiles`** → `backup=()`, so pacman keeps user-modified configs (`.pacsave` / `.pacnew`).
3. Packs the payload and fixes the filesystem layout: Arch uses merged `/usr`, so
   `/bin`, `/sbin`, `/lib`, `/lib64` and `/usr/sbin` are moved into `/usr/bin` and `/usr/lib`
   (otherwise pacman reports file conflicts).
4. Runs `makepkg --nodeps --skipinteg` with `!strip` (binaries are left untouched).

### `debtap`

```bash
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" \
  -e MODE=debtap deb2arch /work/mypackage.deb
```

Uses [debtap](https://github.com/helixarch/debtap), which translates Debian
dependencies to Arch package names using a database baked into the image at build
time (`debtap -u`). Convenient, but treat it as **experimental**: always review the
generated dependency list (`pacman -Qip <package>`).

## Environment variables

| Variable | Description |
|---|---|
| `DEPENDS` | Space-separated Arch dependencies, e.g. `"glibc gcc-libs zlib"` (manual mode) |
| `PKGNAME` | Override the package name (default: lowercase `Package` from `control`) |
| `OUT_DIR` | Output directory (default: directory of the `.deb`) |
| `MODE` | `manual` (default) or `debtap` |
| `INSTALL_FILE` | Path to your own `.install` file; replaces auto-generation from Debian scripts |
| `NO_SCRIPTS=1` | Do not carry over Debian maintainer scripts |
| `KEEP_APT_SCRIPTS=1` | Also carry over scripts that manage APT repositories/keys (skipped by default) |
| `AUR_DEPS` | AUR packages to install with `yay` inside the container before building |
| `GPG_KEYS` | GPG key IDs to import (for `validpgpkeys` of AUR packages) |
| `TEST_INSTALL=1` | After building, install the package inside the container to check that dependencies resolve |

`AUR_DEPS`, `GPG_KEYS` and `TEST_INSTALL` need network access at run time.
Changes made to the container are discarded on exit (`--rm`).

## Maintainer scripts

Debian `preinst` / `postinst` / `prerm` / `postrm` have no direct equivalent in Arch;
pacman uses a `.install` file with `pre_install`, `post_install`, `pre_upgrade`,
`post_upgrade`, `pre_remove`, `post_remove` functions.

`convert.sh` generates this file automatically, so no per-package work is normally needed:

1. **Scripts run unmodified**, embedded into the `.install` and called with the arguments `dpkg` would use,
   in the same order (`prerm` → `preinst` → unpack → `postrm` → `postinst`):

   | pacman hook | Debian calls |
   |---|---|
   | `pre_install` | `preinst install` |
   | `pre_upgrade` | `prerm upgrade <new>`, then `preinst upgrade <old>` |
   | `post_install` | `postinst configure` |
   | `post_upgrade` | `postrm upgrade <new>`, then `postinst configure <old>` |
   | `pre_remove` | `prerm remove` |
   | `post_remove` | `postrm remove` |

2. **APT scripts are skipped.** A script that references `apt-key`, `/etc/apt/`, `apt.conf.d` or
   `sources.list` is treated as APT repository/key management (typical for vendor packages that register
   their own repo) and is not carried over. Override with `KEEP_APT_SCRIPTS=1`.

3. **Debian-only commands go through `shim.sh`.** While a script runs, a directory of shims is appended to
   `PATH` (a real Arch tool with the same name always wins):

   | Command | Behaviour |
   |---|---|
   | `invoke-rc.d`, `deb-systemd-invoke` | only `stop` is honoured (`systemctl stop`); start/restart are left to the user, per Arch policy |
   | `killall` | falls back to `pkill -x` if `psmisc` is not installed |
   | `adduser`, `addgroup` | best-effort translation to `useradd` / `groupadd` / `usermod -aG` for common flags |
   | `apt-key`, `apt-get`, `apt`, `apt-add-repository`, `update-rc.d`, `deb-systemd-helper`, `dpkg-maintscript-helper`, `ucf`, `ucfr`, `update-alternatives` | no-op with a message on stderr |

4. **Failures are non-fatal.** A script that exits non-zero only prints a warning; it never aborts the pacman transaction.

What the shim layer **cannot** handle (reported at the end of the conversion, review these by hand):
`dpkg*` calls (e.g. `dpkg --compare-versions`), `debconf` / `db_*` functions, `dh_*` helpers.
For such packages write your own `.install` and pass it with `INSTALL_FILE`, or use `NO_SCRIPTS=1`.

Inspect what ended up in the package:

```bash
bsdtar -xOf mypackage-1.0-1-x86_64.pkg.tar.zst .INSTALL
```

Scripts run as root on install, the same trust level as the `.deb` itself, so review them before installing.

Custom `.install` example:

```bash
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" \
  -e DEPENDS="glibc gcc-libs zlib" \
  -e INSTALL_FILE=/work/my-package.install \
  deb2arch /work/mypackage.deb
```

## Finding dependencies

Debian dependencies from `control` do not map 1:1 to Arch package names. Examples:

| Debian | Arch |
|---|---|
| `libc6` | `glibc` |
| `libgcc1`, `libstdc++6` | `gcc-libs` |
| `zlib1g` | `zlib` |
| `libgtk-3-0` | `gtk3` |
| `libnss3` | `nss` |
| `libasound2` | `alsa-lib` |

To see what a binary really needs, install the package and run `ldd` on it, or use `pacman -F <file>`
(after `pacman -Fy`) to find which Arch package provides a missing library.

## Installing over an existing package

If an installed package has the **same name**, `pacman -U` simply replaces it, no need to remove it first.
If the old package has a **different name** and ships the same files, pacman will refuse with
`exists in filesystem`; remove the old one first (`sudo pacman -Rns <old-package>`).

To stop an AUR helper from reinstalling an abandoned package over yours, add it to
`IgnorePkg` in `/etc/pacman.conf`:

```
IgnorePkg = yandex-disk
```

## Troubleshooting

**`failed retrieving file ... Operation too slow` during `docker build`**
A slow mirror. The Dockerfile already ships a mirror list, uses `ParallelDownloads = 1` and retries
each step up to 5 times. You can supply your own (nearby) mirrors:

```bash
docker build --build-arg MIRRORS="https://mirror1.example/archlinux https://mirror2.example/archlinux" -t deb2arch .
```

If it still fails, try `docker build --network=host ...`, or check Docker's MTU / IPv6 settings.

**Signature errors (`unknown trust`, `invalid or corrupted package`)**
The image initializes the keyring (`pacman-key --init/--populate`) and updates `archlinux-keyring`
before the full system upgrade. Rebuild with `docker build --pull --no-cache ...` to get fresh keys.

**Permission denied on the output directory**
The container runs as user `builder` with uid 1000. Run with `--user "$(id -u):$(id -g)"`.
If your uid is not 1000, change `useradd -u 1000` in the Dockerfile to match.

## Limitations

- The `.deb` payload is repackaged, not rebuilt. Binaries must be compatible with the libraries in current Arch
  (`ldd` is your friend); old, closed-source binaries sometimes need older libraries.
- Libraries under `/usr/lib/<triplet>/` (Debian multiarch) are left in place and may need `ldconfig` configuration.
- The license field is set to `custom`; edit the generated `PKGBUILD` logic if you need something else.
- Output package release is always `-1`.
- If a native package exists in the official repos or AUR and is actively maintained, prefer it over a converted `.deb`.

## License

Add the license of your choice here.
