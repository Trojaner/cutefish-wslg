# cutefish-wslg

Runs the [Cutefish](https://github.com/cutefishos) desktop's applications on
Windows through [WSLg](https://github.com/microsoft/wslg): Files, Terminal,
Text Editor, Settings, System Monitor and Calculator open as ordinary Windows
windows, with their own icons in the taskbar and Start menu, the clipboard
shared with Windows, and the display scale of each monitor.

Cutefish's applications do not start under WSLg as released: its toolkit
requires a Wayland protocol WSLg's compositor lacks. This repository carries
the upstream projects as submodules, the patch that makes them run, and
installers that build and set everything up.

## Install

In PowerShell on Windows 11, with [WSL](https://learn.microsoft.com/windows/wsl/install) 2.4.4 or newer:

```powershell
irm https://raw.githubusercontent.com/trojaner/cutefish-wslg/main/install.ps1 | iex
```

It asks which WSL distribution to install into, an existing one or a new
Debian 13 one, and which channel to build. It then builds the applications
from source inside the distribution, which takes a while the first time
(mostly for Skia, which the toolkit builds).

Without prompts, pass the choices as parameters:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/trojaner/cutefish-wslg/main/install.ps1))) -Distro Ubuntu -Channel stable -NonInteractive
```

or as environment variables, which also work with `irm ... | iex`:

```powershell
$env:CUTEFISH_WSLG_NEW_DISTRO = 1
$env:CUTEFISH_WSLG_NONINTERACTIVE = 1
irm https://raw.githubusercontent.com/trojaner/cutefish-wslg/main/install.ps1 | iex
```

| Parameter | Environment variable | Meaning |
|---|---|---|
| `-Distro <name>` | `CUTEFISH_WSLG_DISTRO` | Install into this existing distribution |
| `-NewDistro` | `CUTEFISH_WSLG_NEW_DISTRO=1` | Create a new Debian 13 distribution |
| `-NewDistroName <name>` | `CUTEFISH_WSLG_NEW_DISTRO_NAME` | Its name; default `Cutefish` |
| `-UserName <name>` | `CUTEFISH_WSLG_USER` | Its user; default your Windows user name |
| `-Channel stable\|nightly` | `CUTEFISH_WSLG_CHANNEL` | What to build; default `stable` |
| `-NonInteractive` | `CUTEFISH_WSLG_NONINTERACTIVE=1` | Never prompt |
| `-SkipWslgConfig` | | Leave `%USERPROFILE%\.wslgconfig` alone |
| `-NoRestart` | | Do not restart the distribution at the end |
| `-ShutdownIfNeeded` | | Run `wsl --shutdown` without asking if WSLg restarts without its shared memory (see [Known limitations](#known-limitations)) |
| `-Repository`, `-Ref` | | Install from another clone, branch or tag |

`Get-Help .\install.ps1 -Full` describes them in full.

### Channels

Cutefish has no releases yet, so:

- **stable** builds the upstream commits the submodules in [`upstream/`](upstream)
  pin, which this repository's patches are tested against.
- **nightly** builds the newest commit of every upstream project. The patches
  may not apply to it yet; the installer stops and says so if they do not.

### Distributions

Debian 13 and Ubuntu 26.04 or newer. Older releases lack the Wayland
libraries Cutefish needs. A distribution created with `-NewDistro` is Debian 13
with systemd on and a user of your choosing; with `-NonInteractive` that user
has no password and uses `sudo` without one.

## What it changes

In the distribution:

- the Cutefish packages it builds: `cutefish-toolkit`, `cutefish-framework`,
  the icon theme, the wallpapers and the six applications, plus what they
  depend on, the build tools, Noto fonts and `dbus-user-session`;
- PNG copies of the applications' icons in `/usr/share/pixmaps`, where WSLg
  looks for them, listed in `/var/lib/cutefish-wslg/pixmaps`;
- systemd turned on in `/etc/wsl.conf`, if it was not; the applications need
  the session bus it brings;
- if upstream's APT repository `download.cutefish.org` is configured, a pin
  in `/etc/apt/preferences.d/cutefish-wslg` that keeps its unpatched toolkit
  out;
- this repository in `/var/lib/cutefish-wslg/src`, and the build workspace and
  a Skia cache in `/var/cache/cutefish-wslg`.

On Windows, these options in `%USERPROFILE%\.wslgconfig`, under
`[system-distro-env]`; they apply to every WSL distribution once it restarts:

| Option | Why |
|---|---|
| `WESTON_RDP_FRACTIONAL_HI_DPI_SCALING_ROUNDUP=true` | Give Linux windows each monitor's scale, rounded; by default WSLg rounds it down, so at 175% they render at 1x and look tiny |
| `WESTON_RDP_COPY_WARNING_TITLE=false` | No `[WARN:COPY MODE]` in front of window titles |
| `WESTON_RDPRAIL_SHELL_BLEND_OVERLAY_ICON_APPLIST=false` | No penguin badge over the Start menu icons |
| `WESTON_RDPRAIL_SHELL_BLEND_OVERLAY_ICON_TASKBAR=false` | No penguin badge over the taskbar icons |

## Update and uninstall

Run the installer again to rebuild, for instance with `-Channel nightly` for
the newest upstream commits.

To remove what it installed in a distribution:

```powershell
wsl -d <distro> -u root -- /var/lib/cutefish-wslg/src/linux/install.sh --uninstall --yes
```

then remove the options above from `%USERPROFILE%\.wslgconfig` if no other
distribution needs them. A distribution created with `-NewDistro` goes with
`wsl --unregister <name>`.

## Known limitations

- **Whole-number scales only.** WSLg tells Linux applications only an integer
  scale per monitor, so with the rounding option a 175% monitor renders at
  2x, about 14% larger than Windows applications, and 125% at 1x. Every
  window stays sharp.
- **No drag and drop** between Windows and Linux applications; WSLg does not
  support it. Copy and paste works both ways.
- **Translucent areas show what is behind them.** Some applications, such as
  the Calculator's display, draw over a background blur that Cutefish's own
  compositor provides and WSLg does not.
- **One systemd distribution with a user session at a time.** WSL's
  distributions share one cgroup tree, so a second distribution running
  systemd fails to start the user session of the same UID, and its
  applications lose their session bus. Stop the others with
  `wsl --terminate <name>`.
- **Empty windows after Explorer restarts.** WSLg's remote-application client
  stops drawing windows when Explorer restarts; `wsl --terminate <distro>`
  brings them back.
- **Empty windows from every Linux application** in a distribution, with
  `rdp_allocate_shared_memory: Failed to open ... Input/output error` in its
  `/mnt/wslg/weston.log`: WSLg lost its shared memory and its fallback draws
  nothing ([microsoft/WSL#40618](https://github.com/microsoft/WSL/issues/40618)).
  `wsl --shutdown` brings it back. Restarting one distribution can bring it
  about, so the installer checks after its restart and offers the shutdown,
  or runs it with `-ShutdownIfNeeded`.

## How it works

Two [patches to the toolkit](patches/cutefish-toolkit) make the applications
run well under WSLg:

1. The toolkit refuses to start without `wp_fractional_scale_manager_v1`,
   which WSLg's Weston does not offer. The patch makes fractional scaling
   optional and has windows follow the integer `wl_output.scale` of the
   monitors they are on instead, changing as they move between monitors.
   Where fractional scaling is offered, nothing changes.
2. Mesa reaches WSL's GPU through its `d3d12` driver, but without a DRM
   device recent Mesa, as in Ubuntu 26.04, does not pick it and renders in
   software. Where WSL's `/dev/dxg` exists, the toolkit sets
   `GALLIUM_DRIVER=d3d12` before starting EGL, unless it is set already; set
   it to `llvmpipe` to render in software.

[`install.ps1`](install.ps1) prepares the distribution and WSLg, then runs
[`linux/install.sh`](linux/install.sh) in the distribution as root. That
copies each pinned submodule into a workspace (or fetches upstream's newest
commit for nightly), applies `patches/<project>/*.patch` with `git am`, and
builds and installs Debian packages with upstream's own
[`packaging/debian/build.sh`](https://github.com/cutefishos/packaging).
[`linux/cutefish-wslg-icons`](linux/cutefish-wslg-icons) then renders the
icons WSLg shows.

### Moving the pins

```sh
git submodule update --init
git -C upstream/cutefish-toolkit fetch origin && git -C upstream/cutefish-toolkit checkout origin/HEAD
# Apply the patches, resolving conflicts, then write them out again:
git -C upstream/cutefish-toolkit am "$PWD"/patches/cutefish-toolkit/*.patch
rm patches/cutefish-toolkit/*.patch
git -C upstream/cutefish-toolkit format-patch --no-signature -o "$PWD/patches/cutefish-toolkit" origin/HEAD
git -C upstream/cutefish-toolkit checkout --detach origin/HEAD
git add upstream patches
```

CI checks that the patches apply to the pinned commits and lints both
installers.

## License

BSD-3-Clause, as Cutefish; see [LICENSE](LICENSE). The upstream projects in
`upstream/` carry their own licenses.
