#!/usr/bin/env xonsh
"""
Build xonsh winget package.

Builds a standalone Windows installer for the xonsh shell and generates
winget manifest files for submission to microsoft/winget-pkgs.

Usage:
    xonsh build.xsh [OPTIONS] COMMAND [ARGS]...

Commands:
    build       Build xonsh distribution (Python embeddable + pip)
    installer   Create Windows installer (Inno Setup)
    manifest    Generate winget manifest files
    validate    Validate winget manifests
    all         Run full pipeline: build -> installer -> manifest
    clean       Remove build artifacts
    info        Show build environment and check prerequisites
"""

import click
import hashlib
import jinja2
import json
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from importlib.metadata import version as pkg_version
from pathlib import Path

# ---------------------------------------------------------------------------
# Xonsh configuration
# ---------------------------------------------------------------------------
$RAISE_SUBPROC_ERROR = True

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parent if '__file__' in dir() else Path('.').resolve()
BUILD_DIR = ROOT / 'build'
DIST_DIR = ROOT / 'dist'
MANIFESTS_DIR = ROOT / 'manifests'
TEMPLATES_DIR = ROOT / 'templates'

PACKAGE_ID = 'Xonsh.Xonsh'
MANIFEST_SCHEMA_VER = '1.9.0'
APP_GUID = '{{F2A5C3E1-7B89-4D62-A1C4-9E8F0D2B3A56}'

PYPI_JSON_URL = 'https://pypi.org/pypi/xonsh/json'
DEFAULT_PYTHON_VER = '3.14.3'
PYTHON_EMBED_URL = 'https://www.python.org/ftp/python/{pyver}/python-{pyver}-embed-{arch_suffix}.zip'
GET_PIP_URL = 'https://bootstrap.pypa.io/get-pip.py'

GITHUB_RELEASE_URL = 'https://github.com/xonsh/xonsh/releases/download/{ver}/xonsh-{ver}-win-{arch}-setup.exe'


# ---------------------------------------------------------------------------
# Template engine
# ---------------------------------------------------------------------------

def _jinja_env():
    """Create Jinja2 environment.

    Uses custom comment delimiters ({## ##}) to avoid conflict with
    Inno Setup preprocessor syntax ({#MyAppName}).
    """
    return jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(TEMPLATES_DIR)),
        keep_trailing_newline=True,
        comment_start_string='{##',
        comment_end_string='##}',
    )


def _render(template_name, **kwargs):
    """Render a Jinja2 template by name."""
    env = _jinja_env()
    tmpl = env.get_template(template_name)
    return tmpl.render(**kwargs)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _get_latest_version():
    """Fetch latest xonsh version from PyPI."""
    with urllib.request.urlopen(PYPI_JSON_URL) as resp:
        data = json.loads(resp.read())
    return data['info']['version']


def _sha256(filepath):
    """Compute SHA256 hash of a file."""
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while True:
            chunk = f.read(8192)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest().upper()


def _find_iscc():
    """Find Inno Setup 6 compiler (ISCC.exe)."""
    candidates = []
    for env_var in ('ProgramFiles(x86)', 'ProgramFiles'):
        base = os.environ.get(env_var, '')
        if base:
            for ver in ('6', '5'):
                candidates.append(Path(base) / f'Inno Setup {ver}' / 'ISCC.exe')
    for p in candidates:
        if p.exists():
            return p
    found = shutil.which('ISCC') or shutil.which('iscc')
    if found:
        return Path(found)
    return None


def _fix_scripts(scripts_dir):
    """Replace pip .exe launchers with relocatable .cmd wrappers.

    pip hardcodes the absolute build-time path to python.exe inside
    the .exe launchers it creates in Scripts/.  After the distribution
    is moved to another machine (via the installer), those paths are
    wrong and every launcher fails with "Unable to create process".

    We replace them with .cmd files that use %~dp0 (the directory of
    the .cmd itself) to locate python.exe via a relative path.
    """
    wrappers = {
        'xonsh':  '-m xonsh',
        'pip':    '-m pip',
        'xpip':   '-m xonsh.xpip',
    }
    for name, args in wrappers.items():
        exe = scripts_dir / f'{name}.exe'
        if exe.exists():
            exe.unlink()
        cmd = scripts_dir / f'{name}.cmd'
        cmd.write_text(f'@"%~dp0..\\python.exe" {args} %*\r\n', encoding='utf-8')


def _generate_iss(version, arch, source_dir, output_dir, output_name):
    """Render Inno Setup .iss script from template."""
    license_file = source_dir / 'license.txt'
    return _render(
        'xonsh_setup.iss.j2',
        version=version,
        arch=arch,
        app_guid=APP_GUID,
        source_dir=str(source_dir),
        output_dir=str(output_dir),
        output_filename=output_name,
        license_file=str(license_file) if license_file.exists() else '',
    )


# ---------------------------------------------------------------------------
# Manifest generators
# ---------------------------------------------------------------------------

def _write_manifest(dest, template_name, filename, **kwargs):
    """Render a manifest template and write it to dest/filename."""
    text = _render(template_name, **kwargs)
    path = dest / filename
    path.write_text(text, encoding='utf-8')
    return path


def _write_version_manifest(dest, version):
    return _write_manifest(
        dest, 'manifests/version.yaml.j2', f'{PACKAGE_ID}.yaml',
        package_id=PACKAGE_ID, version=version,
        manifest_version=MANIFEST_SCHEMA_VER,
    )


def _write_locale_manifest(dest, version):
    return _write_manifest(
        dest, 'manifests/locale.en-US.yaml.j2', f'{PACKAGE_ID}.locale.en-US.yaml',
        package_id=PACKAGE_ID, version=version,
        manifest_version=MANIFEST_SCHEMA_VER,
    )


def _write_installer_manifest(dest, version, arch, url, sha256):
    return _write_manifest(
        dest, 'manifests/installer.yaml.j2', f'{PACKAGE_ID}.installer.yaml',
        package_id=PACKAGE_ID, version=version, arch=arch,
        url=url, sha256=sha256,
        manifest_version=MANIFEST_SCHEMA_VER,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

@click.group()
def cli():
    """Build xonsh winget package.

    Builds a standalone Windows installer for the xonsh shell and generates
    winget manifest files for submission to microsoft/winget-pkgs.
    """
    pass


# ---- build ---------------------------------------------------------------

@cli.command()
@click.option('--version', 'ver', default=None,
              help='xonsh version to build (default: latest from PyPI).')
@click.option('--arch', default='x64', type=click.Choice(['x64', 'x86']),
              help='Target architecture.')
@click.option('--python-version', 'pyver', default=DEFAULT_PYTHON_VER,
              show_default=True,
              help='Python version for the embeddable package.')
@click.option('--git', 'use_git', is_flag=True, default=False,
              help='Install xonsh from latest commit on main (xonsh/xonsh).')
@click.pass_context
def build(ctx, ver, arch, pyver, use_git):
    """Build xonsh distribution using Python embeddable package.

    Downloads the official Python embeddable zip from python.org, enables
    pip and site-packages, then installs xonsh[full].  The result is a
    fully functional Python+xonsh distribution where `xpip install` works.

    Use --git to build from the latest commit on xonsh/xonsh main branch
    instead of a PyPI release.
    """
    if use_git:
        if ver is None:
            ver = 'dev'
        click.echo(f'  Installing from git (xonsh/xonsh main)')
    elif ver is None:
        click.echo('Fetching latest xonsh version from PyPI...')
        ver = _get_latest_version()
        click.echo(f'  Latest version: {ver}')

    click.echo(f'\n==> Building xonsh {ver} ({arch}, Python {pyver})\n')

    build_dir = BUILD_DIR / f'{ver}-{arch}'
    build_dir.mkdir(parents=True, exist_ok=True)

    xonsh_dist = build_dir / 'dist' / 'xonsh'

    # 1. Download Python embeddable package
    arch_suffix = 'amd64' if arch == 'x64' else 'win32'
    embed_filename = f'python-{pyver}-embed-{arch_suffix}.zip'
    embed_url = PYTHON_EMBED_URL.format(pyver=pyver, arch_suffix=arch_suffix)
    embed_zip = build_dir / embed_filename

    if not embed_zip.exists():
        click.echo(f'[1/5] Downloading {embed_filename}...')
        try:
            urllib.request.urlretrieve(embed_url, str(embed_zip))
        except Exception as exc:
            raise click.ClickException(
                f'Failed to download {embed_url}\n{exc}\n'
                f'Check that Python {pyver} embeddable package exists for {arch}.'
            )
    else:
        click.echo(f'[1/5] Using cached {embed_filename}')

    # 2. Extract into dist/xonsh/
    click.echo('[2/5] Extracting Python embeddable package...')
    if xonsh_dist.exists():
        shutil.rmtree(xonsh_dist)
    xonsh_dist.mkdir(parents=True)
    with zipfile.ZipFile(str(embed_zip)) as zf:
        zf.extractall(str(xonsh_dist))

    # 3. Enable site-packages and install pip
    click.echo('[3/5] Enabling pip and site-packages...')
    pth_files = list(xonsh_dist.glob('python*._pth'))
    if not pth_files:
        raise click.ClickException('python*._pth not found in embeddable package.')
    pth_file = pth_files[0]
    pth_content = pth_file.read_text(encoding='utf-8')
    pth_content = pth_content.replace('#import site', 'Lib\\site-packages\nimport site')
    pth_file.write_text(pth_content, encoding='utf-8')

    get_pip = build_dir / 'get-pip.py'
    if not get_pip.exists():
        urllib.request.urlretrieve(GET_PIP_URL, str(get_pip))
    python_exe = str(xonsh_dist / 'python.exe')
    $[@(python_exe) @(str(get_pip)) --no-warn-script-location --quiet]

    # 4. Install xonsh[full] + setuptools/wheel (needed for xpip install from sdist)
    if use_git:
        click.echo(f'[4/5] Installing xonsh from git...')
        xonsh_spec = 'xonsh[full] @ git+https://github.com/xonsh/xonsh.git@main'
    else:
        click.echo(f'[4/5] Installing xonsh=={ver}...')
        xonsh_spec = f'xonsh[full]=={ver}'
    $[@(python_exe) -m pip install setuptools wheel click pyyaml @(xonsh_spec) --no-warn-script-location --quiet]

    # 5. Fix scripts and finalize
    click.echo('[5/5] Finalizing...')
    scripts_dir = xonsh_dist / 'Scripts'
    _fix_scripts(scripts_dir)
    click.echo('  Replaced .exe launchers with relocatable .cmd wrappers')

    license_file = xonsh_dist / 'license.txt'
    if not license_file.exists():
        try:
            license_url = f'https://raw.githubusercontent.com/xonsh/xonsh/{ver}/license'
            urllib.request.urlretrieve(license_url, str(license_file))
        except Exception:
            license_url = 'https://raw.githubusercontent.com/xonsh/xonsh/main/license'
            urllib.request.urlretrieve(license_url, str(license_file))

    click.echo(f'\n  Build complete.')
    click.echo(f'  Output:  {xonsh_dist}')
    click.echo(f'  Python:  {pyver} ({arch})')
    click.echo(f'  Test:    {xonsh_dist / "Scripts" / "xonsh.exe"} --version')
    click.echo(f'  xpip:    {xonsh_dist / "Scripts" / "xonsh.exe"} -c "xpip install lolcat"')

    # Hint for the next step
    click.echo(f'\n  Next:    xonsh build.xsh installer --version {ver}')
    iscc = _find_iscc()
    if iscc is None:
        click.echo(
            '\n  WARNING: Inno Setup not found — required for the installer step.\n'
            '  Download: https://github.com/jrsoftware/issrc/releases/download/is-6_7_1/innosetup-6.7.1.exe\n'
            '  All releases: https://jrsoftware.org/isdl.php'
        )


# ---- installer ------------------------------------------------------------

@cli.command()
@click.option('--version', 'ver', required=True, help='xonsh version.')
@click.option('--arch', default='x64', type=click.Choice(['x64', 'x86']),
              help='Target architecture.')
@click.pass_context
def installer(ctx, ver, arch):
    """Create Windows installer using Inno Setup."""
    iscc = _find_iscc()
    if iscc is None:
        raise click.ClickException(
            'Inno Setup compiler (ISCC.exe) not found.\n'
            'Download: https://github.com/jrsoftware/issrc/releases/download/is-6_7_1/innosetup-6.7.1.exe\n'
            'All releases: https://jrsoftware.org/isdl.php'
        )

    source_dir = BUILD_DIR / f'{ver}-{arch}' / 'dist' / 'xonsh'
    if not source_dir.exists():
        raise click.ClickException(
            f'Build output not found at {source_dir}.\n'
            f'Run "xonsh build.xsh build --version {ver}" first.'
        )

    DIST_DIR.mkdir(parents=True, exist_ok=True)
    output_name = f'xonsh-{ver}-win-{arch}-setup'

    click.echo(f'\n==> Creating installer for xonsh {ver} ({arch})\n')

    # Generate .iss script
    iss_content = _generate_iss(ver, arch, source_dir, DIST_DIR, output_name)
    iss_path = BUILD_DIR / f'{ver}-{arch}' / 'xonsh_setup.iss'
    iss_path.write_text(iss_content, encoding='utf-8')
    click.echo(f'  ISS script: {iss_path}')

    # Compile
    click.echo('  Compiling installer...')
    try:
        $[@(str(iscc)) @(str(iss_path))]
    except subprocess.CalledProcessError:
        raise click.ClickException('Inno Setup compilation failed. See output above.')

    installer_path = DIST_DIR / f'{output_name}.exe'
    sha = _sha256(installer_path)
    click.echo(f'\n  Installer: {installer_path}')
    click.echo(f'  Size:      {installer_path.stat().st_size / 1024 / 1024:.1f} MB')
    click.echo(f'  SHA256:    {sha}')


# ---- manifest -------------------------------------------------------------

@cli.command()
@click.option('--version', 'ver', required=True, help='xonsh version.')
@click.option('--arch', default='x64', type=click.Choice(['x64', 'x86']),
              help='Target architecture.')
@click.option('--installer-path', 'inst_path', default=None,
              type=click.Path(exists=True),
              help='Path to the installer .exe (default: dist/xonsh-VER-win-ARCH-setup.exe).')
@click.option('--url', default=None,
              help='Public HTTPS download URL for the installer.')
@click.pass_context
def manifest(ctx, ver, arch, inst_path, url):
    """Generate winget manifest files (multi-file format)."""
    if inst_path is None:
        inst_path = DIST_DIR / f'xonsh-{ver}-win-{arch}-setup.exe'
    inst_path = Path(inst_path)
    if not inst_path.exists():
        raise click.ClickException(
            f'Installer not found: {inst_path}\n'
            f'Run "xonsh build.xsh installer --version {ver}" first.'
        )

    sha = _sha256(inst_path)

    if url is None:
        url = GITHUB_RELEASE_URL.format(ver=ver, arch=arch)
        click.echo(f'  Using default URL: {url}')

    manifest_dir = MANIFESTS_DIR / 'x' / 'xonsh' / 'xonsh' / ver
    manifest_dir.mkdir(parents=True, exist_ok=True)

    click.echo(f'\n==> Generating winget manifests for xonsh {ver}\n')

    f1 = _write_version_manifest(manifest_dir, ver)
    f2 = _write_locale_manifest(manifest_dir, ver)
    f3 = _write_installer_manifest(manifest_dir, ver, arch, url, sha)

    click.echo(f'  {f1.name}')
    click.echo(f'  {f2.name}')
    click.echo(f'  {f3.name}')
    click.echo(f'\n  SHA256: {sha}')
    click.echo(f'  Output: {manifest_dir}')


# ---- validate -------------------------------------------------------------

@cli.command()
@click.option('--version', 'ver', required=True, help='xonsh version.')
@click.pass_context
def validate(ctx, ver):
    """Validate winget manifest files with `winget validate`."""
    manifest_dir = MANIFESTS_DIR / 'x' / 'xonsh' / 'xonsh' / ver
    if not manifest_dir.exists():
        raise click.ClickException(
            f'Manifests not found: {manifest_dir}\n'
            f'Run "xonsh build.xsh manifest --version {ver}" first.'
        )

    click.echo(f'\n==> Validating manifests in {manifest_dir}\n')
    try:
        $[winget validate @(str(manifest_dir))]
        click.echo('\nValidation passed.')
    except FileNotFoundError:
        raise click.ClickException(
            'winget CLI not found.\n'
            'Install from https://github.com/microsoft/winget-cli/releases'
        )
    except subprocess.CalledProcessError:
        raise click.ClickException('Manifest validation failed. See output above.')


# ---- all ------------------------------------------------------------------

@cli.command('all')
@click.option('--version', 'ver', default=None,
              help='xonsh version (default: latest from PyPI).')
@click.option('--arch', default='x64', type=click.Choice(['x64', 'x86']),
              help='Target architecture.')
@click.option('--url', default=None,
              help='Public HTTPS download URL for the installer.')
@click.pass_context
def build_all(ctx, ver, arch, url):
    """Run full pipeline: build -> installer -> manifest -> validate."""
    if ver is None:
        click.echo('Fetching latest xonsh version from PyPI...')
        ver = _get_latest_version()
        click.echo(f'  Latest version: {ver}')

    click.echo(f'\n{"=" * 50}')
    click.echo(f'  Full build pipeline — xonsh {ver} ({arch})')
    click.echo(f'{"=" * 50}\n')

    # Step 1 — Python embeddable + xonsh
    ctx.invoke(build, ver=ver, arch=arch, pyver=DEFAULT_PYTHON_VER)
    click.echo()

    # Step 2 — Inno Setup installer
    ctx.invoke(installer, ver=ver, arch=arch)
    click.echo()

    # Step 3 — winget manifests
    ctx.invoke(manifest, ver=ver, arch=arch, inst_path=None, url=url)
    click.echo()

    # Step 4 — validate (optional)
    try:
        ctx.invoke(validate, ver=ver)
    except (click.ClickException, Exception) as exc:
        click.echo(f'  Validation skipped: {exc}', err=True)

    click.echo(f'\n{"=" * 50}')
    click.echo(f'  Build complete!')
    click.echo(f'  Installer: dist/xonsh-{ver}-win-{arch}-setup.exe')
    click.echo(f'  Manifests: manifests/x/xonsh/xonsh/{ver}/')
    click.echo(f'{"=" * 50}')


# ---- clean ----------------------------------------------------------------

@cli.command()
def clean():
    """Remove all build artifacts (build/, dist/, manifests/)."""
    for d in (BUILD_DIR, DIST_DIR, MANIFESTS_DIR):
        if d.exists():
            click.echo(f'  Removing {d.relative_to(ROOT)}/ ...')
            shutil.rmtree(d)
    click.echo('  Clean complete.')


# ---- info -----------------------------------------------------------------

@cli.command()
def info():
    """Show build environment and check prerequisites."""
    click.echo(f'\n=== xonsh-winget build environment ===\n')
    click.echo(f'  Project dir : {ROOT}')
    click.echo(f'  Build dir   : {BUILD_DIR}')
    click.echo(f'  Dist dir    : {DIST_DIR}')
    click.echo(f'  Templates   : {TEMPLATES_DIR}')
    click.echo()

    # Python
    click.echo(f'  Python      : {sys.executable}')
    click.echo(f'                {sys.version.split(chr(10))[0]}')

    # xonsh
    try:
        import xonsh
        click.echo(f'  xonsh       : {xonsh.__version__}')
    except ImportError:
        click.echo(f'  xonsh       : NOT INSTALLED')

    # click
    click.echo(f'  click       : {pkg_version("click")}')

    # jinja2
    click.echo(f'  Jinja2      : {pkg_version("jinja2")}')

    # Inno Setup
    iscc = _find_iscc()
    click.echo(f'  Inno Setup  : {iscc or "NOT FOUND"}')

    # winget
    winget = shutil.which('winget')
    click.echo(f'  winget CLI  : {winget or "NOT FOUND"}')

    # Templates
    click.echo()
    n = sum(1 for _ in TEMPLATES_DIR.rglob('*.j2')) if TEMPLATES_DIR.exists() else 0
    click.echo(f'  Templates   : {n} .j2 files found')

    # PyPI
    try:
        latest = _get_latest_version()
        click.echo(f'  Latest xonsh on PyPI: {latest}')
    except Exception as exc:
        click.echo(f'  Latest xonsh on PyPI: ERROR ({exc})')

    click.echo()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    cli()
