<#
.SYNOPSIS
    Two fixes for CodeBuddy (cbai/*) in a 9router checkout. Windows version.

.DESCRIPTION
    Run from the root of a 9router repo:

        .\patch.ps1

    Applies the patch to the source in place. `npm run dev` and `npm run build`
    pick it up as usual. No install, no environment variables, no build step.

.PARAMETER Check
    Report whether the checkout is patched. Exit 0 = patched, 1 = not patched,
    2 = the patch would not apply (upstream moved).

.PARAMETER Revert
    Put the source back to stock.

.EXAMPLE
    .\patch.ps1

.EXAMPLE
    .\patch.ps1 -Check

.EXAMPLE
    .\patch.ps1 -Revert
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Revert
)

# `irm ... | iex` cannot pass parameters, so the same two actions are reachable
# through environment variables. Keeps one code path for both invocations.
if ($env:NINEROUTER_CHECK  -eq '1') { $Check  = $true }
if ($env:NINEROUTER_REVERT -eq '1') { $Revert = $true }

$ErrorActionPreference = 'Stop'

$Repo       = 'capncodes69/9r-cbgb-patch'
$PatchUrl   = "https://raw.githubusercontent.com/$Repo/main/patches/9r-cbgb-fix.patch"
$LocalPatch = $env:NINEROUTER_LOCAL_PATCH

function Write-Log  { param($m) Write-Host "==> $m" -ForegroundColor Blue }
function Write-Ok   { param($m) Write-Host "  ok $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  !! $m" -ForegroundColor Yellow }
function Write-Dim  { param($m) Write-Host "     $m" -ForegroundColor DarkGray }
function Die        { param($m) Write-Host "  xx $m" -ForegroundColor Red; exit 1 }

Write-Log '9r-cbgb-patch'
Write-Dim "platform: Windows (PowerShell $($PSVersionTable.PSVersion))"

# ── Are we in a 9router checkout? ────────────────────────────────────────────
if (-not (Test-Path 'package.json')) {
    Die 'run this from the root of a 9router checkout (no package.json here)'
}
if (-not (Select-String -Path 'package.json' -Pattern '"9router-app"' -Quiet)) {
    Die 'this does not look like 9router (package.json has no "9router-app")'
}
if (-not (Test-Path 'open-sse/executors/codebuddy-intl.js')) {
    Die 'open-sse/ not found - is this a complete checkout?'
}
Write-Ok "9router checkout: $PWD"

# ── git is required ──────────────────────────────────────────────────────────
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die @'
git not found - it is used to apply and revert the patch.
     Install with:  winget install Git.Git
     Then reopen the terminal so PATH updates.
'@
}

# ── Fetch the patch ──────────────────────────────────────────────────────────
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("9r-cbgb-" + [guid]::NewGuid() + ".patch")
try {
    if ($LocalPatch) {
        Copy-Item $LocalPatch $tmp -Force
    } else {
        try {
            # Invoke-WebRequest honours the system proxy and TLS settings; curl.exe
            # ships with Windows 10+ but is not guaranteed on Server images.
            Invoke-WebRequest -Uri $PatchUrl -OutFile $tmp -UseBasicParsing
        } catch {
            Die "cannot download the patch from $PatchUrl : $($_.Exception.Message)"
        }
    }

    # git apply --check writes to stderr on failure; capture rather than throw.
    function Test-Applied   { & git apply --reverse --check $tmp 2>$null; return ($LASTEXITCODE -eq 0) }
    function Test-Appliable { & git apply --check $tmp 2>$null;         return ($LASTEXITCODE -eq 0) }

    if ($Check) {
        if (Test-Applied)       { Write-Ok 'patched';               exit 0 }
        elseif (Test-Appliable) { Write-Warn 'not patched';         exit 1 }
        else                    { Write-Warn 'not patched, and the patch would not apply (upstream has probably moved)'; exit 2 }
    }

    if ($Revert) {
        if (Test-Applied) {
            & git apply --reverse $tmp
            if ($LASTEXITCODE -ne 0) { Die 'revert failed' }
            Write-Ok 'reverted - source is back to stock'
        } else {
            Write-Ok 'nothing to revert (not patched)'
        }
        exit 0
    }

    # ── Apply ────────────────────────────────────────────────────────────────
    if (Test-Applied) {
        Write-Ok 'already patched - nothing to do'
    } elseif (Test-Appliable) {
        & git apply $tmp
        if ($LASTEXITCODE -ne 0) { Die 'patch failed' }
        Write-Ok 'patch applied'
    } else {
        Die 'the patch does not apply to this checkout. Upstream has probably moved; check for a newer bundle.'
    }

    # ── Verify both fixes landed ─────────────────────────────────────────────
    $probes = @(
        @{ File = 'open-sse/executors/codebuddy-intl.js'; Needle = 'X-Conversation-ID';  What = 'header family' },
        @{ File = 'open-sse/config/errorConfig.js';        Needle = 'request illegal';    What = 'WAF rule' },
        @{ File = 'open-sse/services/combo.js';            Needle = 'providerId';         What = 'combo provider passthrough' }
    )
    foreach ($p in $probes) {
        if (-not (Select-String -Path $p.File -Pattern ([regex]::Escape($p.Needle)) -Quiet)) {
            Die "verification failed: $($p.What) missing from $($p.File)"
        }
    }
    Write-Ok 'both fixes present'

    Write-Host ''
    Write-Log 'Done.'
    Write-Host '  Run it the usual way:'
    Write-Host '    npm run dev'
    Write-Host ''
    Write-Host '  To undo:  .\patch.ps1 -Revert'
}
finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
