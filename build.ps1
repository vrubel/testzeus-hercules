#requires -Version 5
# Build this (lean) TestZeus Hercules fork into an isolated Python venv (Windows).
# ASCII-only on purpose (Windows PowerShell 5.1 reads .ps1 in the system ANSI codepage).
# Mirror of build.sh.
#
# Purpose. You cloned this repo onto a host that ALREADY has Python (>=3.11,<3.14). This script makes
# an isolated venv and installs ONLY Python packages into it, proving the build downloads NO non-Python
# artifact (the Playwright browser, chromadb ONNX model, HuggingFace weights are runtime downloads and
# are blocked here). Self-contained alternative to `make install` (which needs uv and downloads the
# browser with system libs). Any deviation is a LOUD stop with diagnostics.
#
# Usage (from the cloned repo root):
#   powershell -ExecutionPolicy Bypass -File build.ps1
#   $env:HERCULES_VENV='C:\path\to\venv'; .\build.ps1
#   .\build.ps1 C:\path\to\another\checkout
#   .\build.ps1 -Help
#
# Env vars: HERCULES_VENV (venv dir, default <repo>\.venv), PYTHON (donor interpreter, default
#           'python'), PIP_INDEX_URL (honored as usual).

[CmdletBinding()]
param([Parameter(Position = 0)] [string] $Repo = '', [switch] $Help)
$ErrorActionPreference = 'Stop'

function Step($m) { Write-Host "`n-> $m" -ForegroundColor Cyan }
function Info($m) { Write-Host "  [i] $m" }
function Ok($m)   { Write-Host "ok: $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }

$script:REPO = $Repo; $script:VENV = ''; $script:PYBIN = ''; $script:VPY = ''; $script:PIP_LOG = ''

function Diagnostics {
  Write-Host "`n-- DIAGNOSTICS ----------------------------------------" -ForegroundColor White
  Write-Host ("  OS:           " + [System.Environment]::OSVersion.VersionString)
  Write-Host ("  repo:         " + $script:REPO)
  Write-Host ("  venv:         " + $script:VENV)
  Write-Host ("  donor python: " + $script:PYBIN)
  if ($script:VPY -and (Test-Path $script:VPY)) {
    Write-Host ("  venv python:  " + $script:VPY + "  (" + (& $script:VPY -V 2>&1) + ")")
  }
  if ($script:PIP_LOG -and (Test-Path $script:PIP_LOG)) {
    Write-Host ("  --- last 40 lines of pip log (" + $script:PIP_LOG + ") ---")
    Get-Content $script:PIP_LOG -Tail 40 | ForEach-Object { Write-Host "  $_" }
  }
  Write-Host "-------------------------------------------------------" -ForegroundColor White
}
function Fail($m) { Write-Host "`nFAIL: $m" -ForegroundColor Red; Diagnostics; exit 1 }

if ($Help) { Get-Content $PSCommandPath | Select-Object -Skip 1 -First 26 | ForEach-Object { $_ -replace '^#\s?', '' }; exit 0 }

# Script dir = default repo to build (works from any cwd).
if (-not $Repo) { $Repo = $PSScriptRoot }
$PYBIN = if ($env:PYTHON) { $env:PYTHON } else { 'python' }
$script:PYBIN = $PYBIN

$PW_CACHE = if ($env:PLAYWRIGHT_BROWSERS_PATH) { $env:PLAYWRIGHT_BROWSERS_PATH } else { Join-Path $env:USERPROFILE 'AppData\Local\ms-playwright' }
$HF_CACHE = if ($env:HF_HOME) { $env:HF_HOME } else { Join-Path $env:USERPROFILE '.cache\huggingface' }
$PW_PRE = Test-Path $PW_CACHE
$HF_PRE = Test-Path $HF_CACHE

# --- 1. repo tree ----------------------------------------------------------------------------
Step 'Checking the repo tree'
if (-not (Test-Path $Repo)) { Fail "directory not found: $Repo" }
$REPO = (Resolve-Path $Repo).Path; $script:REPO = $REPO
$pyproj = Join-Path $REPO 'pyproject.toml'
if (-not (Test-Path $pyproj)) { Fail "no pyproject.toml in '$REPO' - not a Hercules tree" }
if (-not (Select-String -Path $pyproj -Pattern 'name\s*=\s*"testzeus-hercules"' -Quiet)) { Fail "pyproject.toml in '$REPO' is not testzeus-hercules" }
$VENV = if ($env:HERCULES_VENV) { $env:HERCULES_VENV } else { Join-Path $REPO '.venv' }
$script:VENV = $VENV
Ok "repo: $REPO"
$verLine = (Select-String -Path $pyproj -Pattern '^version' | Select-Object -First 1).Line
Info ("package version: " + ($verLine -replace '.*=\s*', '' -replace '"', ''))

# --- 2. donor interpreter --------------------------------------------------------------------
Step 'Checking host Python (need >=3.11,<3.14)'
$pyCmd = Get-Command $PYBIN -ErrorAction SilentlyContinue
if (-not $pyCmd) { Fail "interpreter '$PYBIN' not found on PATH (set `$env:PYTHON). Install Python 3.11-3.13 from python.org." }
$PYBIN = $pyCmd.Source; $script:PYBIN = $PYBIN
$verCheck = & $PYBIN -c "import sys; v=sys.version_info; print(sys.version.split()[0]); sys.exit(0 if (3,11)<=(v.major,v.minor)<(3,14) else 1)"
if ($LASTEXITCODE -ne 0) { Fail "Python version unsuitable (need >=3.11 and <3.14). Got: $verCheck." }
Ok "Python donor OK ($verCheck at $PYBIN)"

# --- 3. clean venv ---------------------------------------------------------------------------
Step "Creating isolated venv: $VENV"
if (Test-Path $VENV) { Warn 'venv already exists - recreating from scratch'; Remove-Item -Recurse -Force $VENV }
New-Item -ItemType Directory -Force -Path (Split-Path $VENV) | Out-Null
& $PYBIN -m venv $VENV
if ($LASTEXITCODE -ne 0) { Fail "could not create venv at $VENV" }
$VPY = Join-Path $VENV 'Scripts\python.exe'; $script:VPY = $VPY
if (-not (Test-Path $VPY)) { Fail "venv has no python ($VPY) - 'python' may be a Windows Store stub; install real Python from python.org" }
Ok ("venv ready: $VPY (" + (& $VPY -V 2>&1) + ")")

Step 'Upgrading pip/setuptools/wheel in venv'
& $VPY -m pip install --quiet --upgrade pip setuptools wheel
if ($LASTEXITCODE -ne 0) { Fail 'failed to upgrade pip/setuptools/wheel (network/index issue? check PIP_INDEX_URL)' }
Ok (& $VPY -m pip --version)

# --- 4. GUARDS against non-Python downloads --------------------------------------------------
Step 'Blocking any binary/model downloads for the duration of the build'
$env:PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = '1'
$env:PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = '1'
$env:HF_HUB_OFFLINE = '1'; $env:TRANSFORMERS_OFFLINE = '1'; $env:HF_HUB_DISABLE_TELEMETRY = '1'
$env:PIP_NO_INPUT = '1'; $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
Info 'PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1, HF_HUB_OFFLINE=1, TRANSFORMERS_OFFLINE=1 (+ telemetry off)'

# --- 5. dry run: prove "Python packages only" ------------------------------------------------
Step 'Dry run: resolve dependencies and verify EVERYTHING is a Python distribution'
$REPORT  = Join-Path $env:TEMP ('hercules-report-' + [System.Guid]::NewGuid().ToString('N') + '.json')
$PIP_LOG = Join-Path $env:TEMP ('hercules-pip-' + [System.Guid]::NewGuid().ToString('N') + '.log')
$script:PIP_LOG = $PIP_LOG
& $VPY -m pip install --dry-run --report $REPORT --prefer-binary $REPO *> $PIP_LOG
if ($LASTEXITCODE -ne 0) { Get-Content $PIP_LOG | ForEach-Object { Write-Host $_ }; Fail 'dependency resolution failed (see pip log above).' }
$AUDIT_PY = Join-Path $env:TEMP ('hercules-audit-' + [System.Guid]::NewGuid().ToString('N') + '.py')
@'
import json, sys, os
# encoding explicit UTF-8: on Windows the default is cp1252 and pip's JSON report has non-cp1252 bytes.
rep = json.load(open(sys.argv[1], encoding="utf-8"))
items = rep.get("install", [])
PYEXT = (".whl", ".tar.gz", ".tgz", ".zip", ".tar.bz2")
bad, rows = [], []
for it in items:
    meta = it.get("metadata", {})
    name = meta.get("name", "?"); ver = meta.get("version", "?")
    di = it.get("download_info", {}) or {}
    url = di.get("url", ""); low = url.lower()
    if di.get("dir_info") is not None or low.startswith("file://"):
        kind = "local-tree"
    elif di.get("vcs_info") is not None:
        kind = "vcs"
    elif low.endswith(PYEXT):
        kind = "wheel" if low.endswith(".whl") else "sdist"
    else:
        kind = "SUSPICIOUS"; bad.append((name, ver, url))
    fname = os.path.basename(url.split("?")[0]) or url
    rows.append((name, ver, kind, fname))
w = max((len(r[0]) for r in rows), default=4)
print("  packages to install: %d (source - pip index / local tree)" % len(rows))
for name, ver, kind, fname in sorted(rows):
    flag = "  " if kind != "SUSPICIOUS" else ">>"
    print("  %s %-*s  %-14s [%s] %s" % (flag, w, name, ver, kind, fname))
if bad:
    print("\n  NON-Python distributions (forbidden binaries):", file=sys.stderr)
    for name, ver, url in bad:
        print("    %s %s: %s" % (name, ver, url), file=sys.stderr)
    sys.exit(1)
print("  OK: every source is a Python dist (wheel/sdist), local tree or VCS; no stray binaries")
'@ | Set-Content -Path $AUDIT_PY -Encoding ASCII
& $VPY $AUDIT_PY $REPORT
$auditRc = $LASTEXITCODE
Remove-Item $AUDIT_PY -Force -ErrorAction SilentlyContinue
if ($auditRc -ne 0) { Fail 'the install plan contains a NON-Python distribution (details above) - build stopped' }
Ok 'install composition verified - Python packages only'

# --- 6. actual install -----------------------------------------------------------------------
Step 'Installing into the venv (Python packages only, --prefer-binary)'
# Stream to console AND file (Tee), do NOT swallow into the log only. With `*> $PIP_LOG` plus the
# script-wide $ErrorActionPreference='Stop', when pip writes to stderr PowerShell raises a terminating
# NativeCommandError ON THIS LINE - it never reaches the failure handler below, so the user sees a bare
# "ERROR: Exception:" with no cause. `2>&1 | Tee-Object` merges stderr into the pipeline (consumed by
# Tee, so no premature throw), shows the live pip output, and still mirrors it to $PIP_LOG.
& $VPY -m pip install --prefer-binary $REPO 2>&1 | Tee-Object -FilePath $PIP_LOG
if ($LASTEXITCODE -ne 0) { Fail "install failed (full pip output is above and in $PIP_LOG)" }
$built = Select-String -Path $PIP_LOG -Pattern 'Building wheel for (\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique
if ($built) { Info ('built from source (sdist, python): ' + ($built -join ' ')) } else { Info 'all installed as prebuilt wheels' }
Ok 'packages installed'

# --- 7. audit: no non-Python binaries appeared -----------------------------------------------
Step 'Audit: verify the build pulled no browser/models/weights'
$auditFail = $false
$HBIN = Join-Path $VENV 'Scripts\testzeus-hercules.exe'
if (-not (Test-Path $HBIN)) { Warn "entrypoint not found: $HBIN - installed without a console script?"; $auditFail = $true }
# find_spec does NOT execute the heavy __init__ (which boots the engine and prompts for an email);
# inline `python -c` mangles embedded quotes on PS5.1, so write the check to a temp .py file.
$SPEC_PY = Join-Path $env:TEMP ('hercules-spec-' + [System.Guid]::NewGuid().ToString('N') + '.py')
@'
import importlib.util, sys
sys.exit(0 if importlib.util.find_spec("testzeus_hercules") else 1)
'@ | Set-Content -Path $SPEC_PY -Encoding ASCII
& $VPY $SPEC_PY *> $null
$specRc = $LASTEXITCODE
Remove-Item $SPEC_PY -Force -ErrorAction SilentlyContinue
if ($specRc -eq 0) { Ok 'package testzeus_hercules installed and importable (find_spec); entrypoint present' }
else { Warn 'package testzeus_hercules not visible to the venv interpreter - install incomplete'; $auditFail = $true }
if ((-not $PW_PRE) -and (Test-Path $PW_CACHE)) { Warn "the build CREATED a Playwright browser cache: $PW_CACHE - it should not"; $auditFail = $true }
elseif ($PW_PRE) { Info "browser cache $PW_CACHE existed BEFORE the build (not ours) - skipping" }
else { Ok "Playwright browser not downloaded (cache $PW_CACHE absent)" }
if ((-not $HF_PRE) -and (Test-Path $HF_CACHE)) { Warn "the build CREATED a HuggingFace model cache: $HF_CACHE - it should not"; $auditFail = $true }
elseif (-not $HF_PRE) { Ok "HuggingFace models not downloaded (cache $HF_CACHE absent)" }
if (Select-String -Path $PIP_LOG -Pattern 'playwright.*install (chromium|firefox|webkit)|Downloading browser|huggingface.*download|install-deps' -Quiet) {
  Warn "the install log shows binary/browser download traces - check $PIP_LOG"; $auditFail = $true
} else { Ok 'install log has no browser/model/system-lib downloads' }
if ($auditFail) { Fail 'audit found deviations (see [!] above) - build NOT certified clean' }

# --- 8. summary ------------------------------------------------------------------------------
& $VPY -m pip freeze | Set-Content -Path (Join-Path $VENV 'pip-freeze.txt') -Encoding ASCII
Step 'Done'
Ok "Hercules built into $VENV"
Info ("run:  " + $HBIN + " --help   (or activate the venv: " + (Join-Path $VENV 'Scripts\Activate.ps1') + ")")
Info 'browser NOT downloaded - point Hercules at your own Chromium engine (BROWSER_PATH / BROWSER_CHANNEL / CDP_ENDPOINT_URL; HEADLESS=true by default).'
Info ('bundled Chromium, if needed, manually:  ' + (Join-Path $VENV 'Scripts\playwright.exe') + ' install chromium')
Remove-Item $REPORT -Force -ErrorAction SilentlyContinue
