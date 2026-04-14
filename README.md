<p align="center">
    <img src="./xonsh-winget-pic.png" width='100px'>
</p>

# xonsh-winget

Build system for creating a [winget](https://learn.microsoft.com/windows/package-manager/) package for the [xonsh](https://xon.sh) shell.
**No administrator privileges required** — the installer is user-scoped and installs to `%LOCALAPPDATA%\Programs\xonsh`.

The pipeline bundles xonsh into a portable Python distribution (via the official [Python embeddable package](https://docs.python.org/3/using/windows.html#the-embeddable-package) + Inno Setup) and generates multi-file winget manifest YAML ready for submission to [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs).

## Install xonsh

Download installer from [Releases page](https://github.com/xonsh/xonsh-winget/releases).

## Build

### Prerequisites

First of all to build Xonsh WinGet install Git, Python 3.11+ and Inno Setup 6 ([Download](https://github.com/jrsoftware/issrc/releases/download/is-6_7_1/innosetup-6.7.1.exe) / [All releases](https://jrsoftware.org/isdl.php)).

Then install all Python dependencies:

```bash
git clone https://github.com/xonsh/xonsh-winget
cd xonsh-winget
pip install -e .
```

### Use build tool

```bash
# Check system info
xonsh build.xsh info

# Full pipeline — builds distribution, creates installer, generates manifests
xonsh build.xsh all --version 0.22.8  # Build release.
xonsh build.xsh all --git  # Build latest commit from xonsh/xonsh repository.

# Or step by step:
xonsh build.xsh build     --version 0.22.8          # Python embed + xonsh
xonsh build.xsh installer --version 0.22.8          # Inno Setup
xonsh build.xsh manifest  --version 0.22.8          # winget YAML
xonsh build.xsh validate  --version 0.22.8          # winget validate
```

### Commands

#### `build`

Builds a xonsh distribution based on the Python embeddable package.

```
xonsh build.xsh build [--version VER] [--arch x64|x86] [--python-version PYVER]
```

- Downloads the official Python embeddable zip from python.org
- Enables `site-packages` and installs `pip` via `get-pip.py`
- Installs `xonsh[full]` (with prompt\_toolkit, pygments, etc.)
- Output: `build/<ver>-<arch>/dist/xonsh/` — a self-contained Python+xonsh directory

The result is a **fully functional Python environment**. After installation users can run `xpip install <package>` to add Python packages.

If `--version` is omitted, the latest version is fetched from PyPI.

#### `installer`

Creates a Windows installer using Inno Setup.

```
xonsh build.xsh installer --version VER [--arch x64|x86]
```

- Generates an Inno Setup `.iss` script from a Jinja2 template
- Compiles it with `ISCC.exe`
- Installs to `%LOCALAPPDATA%\Programs\xonsh` (user-scoped, no admin required)
- Supports silent mode (`/VERYSILENT`), adds `Scripts\` to user PATH
- Output: `dist/xonsh-<ver>-win-<arch>-setup.exe`

Requires Inno Setup 6 to be installed. The script auto-detects `ISCC.exe` in standard locations.

#### `manifest`

Generates winget manifest files in multi-file format.

```
xonsh build.xsh manifest --version VER [--arch x64|x86] [--installer-path FILE] [--url URL]
```

- Produces three YAML files (version, defaultLocale, installer) under `manifests/x/xonsh/xonsh/<ver>/`
- Computes SHA256 of the installer automatically
- `--url` defaults to `https://github.com/xonsh/xonsh/releases/download/<ver>/xonsh-<ver>-win-<arch>-setup.exe`

#### `validate`

Validates generated manifests against the winget schema.

```
xonsh build.xsh validate --version VER
```

Runs `winget validate` on the manifest directory. Requires the winget CLI.

#### `all`

Full pipeline: `build` -> `installer` -> `manifest` -> `validate`.

```
xonsh build.xsh all [--version VER] [--arch x64|x86] [--url URL]
```

#### `clean`

Removes all build artifacts (`build/`, `dist/`, `manifests/`).

```
xonsh build.xsh clean
```

#### `info`

Shows build environment and checks prerequisites.

```
xonsh build.xsh info
```

### What each step does

1. **build** — Downloads the Python embeddable package, enables `site-packages`, installs pip and `xonsh[full]`. The result is a real Python environment where `xpip install` works.

2. **installer** — Wraps the build output in an Inno Setup installer. The resulting `.exe`:
   - Installs to `%LOCALAPPDATA%\Programs\xonsh` (no admin needed)
   - Supports silent install: `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-`
   - Adds `Scripts\` to user PATH (xonsh, pip, xpip are there)
   - Registers in Add/Remove Programs

3. **manifest** — Generates the three YAML files required by winget-pkgs:
   - `Xonsh.Xonsh.yaml` (version)
   - `Xonsh.Xonsh.locale.en-US.yaml` (metadata, tags, description)
   - `Xonsh.Xonsh.installer.yaml` (download URL, SHA256, install switches)

#### What the user gets after `winget install xonsh`

```
%LOCALAPPDATA%\Programs\xonsh\
├── python.exe                  # Embedded Python
├── python3XX.dll
├── python3XX._pth
├── Lib\site-packages\          # Full site-packages (writable)
│   ├── xonsh\
│   ├── prompt_toolkit\
│   ├── pygments\
│   ├── pip\
│   └── ...
├── Scripts\                    # Entry points (on PATH)
│   ├── xonsh.exe               # <-- user runs this
│   ├── pip.exe
│   └── ...
└── license.txt
```

`xpip install lolcat` works because `Lib\site-packages\` is writable.


## See also

### winget documentation
- [Windows Package Manager overview](https://learn.microsoft.com/windows/package-manager/)
- [Create your package manifest](https://learn.microsoft.com/windows/package-manager/package/manifest)
- [Submit your manifest to the repository](https://learn.microsoft.com/windows/package-manager/package/repository)
- [winget validate command](https://learn.microsoft.com/windows/package-manager/winget/validate)
- [Manifest schema reference (version)](https://learn.microsoft.com/windows/package-manager/package/manifest?tabs=version)
- [Manifest schema reference (installer)](https://learn.microsoft.com/windows/package-manager/package/manifest?tabs=installer)
- [Manifest schema reference (locale)](https://learn.microsoft.com/windows/package-manager/package/manifest?tabs=locale)

### winget-pkgs repository
- [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) — community package repository
- [winget-pkgs contribution guide](https://github.com/microsoft/winget-pkgs/blob/master/CONTRIBUTING.md)
- [Manifest schema docs](https://github.com/microsoft/winget-pkgs/tree/master/doc/manifest)

### winget tools
- [microsoft/winget-create](https://github.com/microsoft/winget-create) — manifest creation tool
- [microsoft/winget-cli](https://github.com/microsoft/winget-cli) — winget CLI source

### Build tools
- [Inno Setup](https://jrsoftware.org/isinfo.php) — Windows installer creator
- [Inno Setup documentation](https://jrsoftware.org/ishelp/)
- [Python embeddable package](https://docs.python.org/3/using/windows.html#the-embeddable-package) — official minimal Python distribution
- [get-pip.py](https://pip.pypa.io/en/stable/installation/#ensurepip) — pip bootstrap installer
