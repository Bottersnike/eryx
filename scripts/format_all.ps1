param(
    [switch]$ApplyAndAbort,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Git may emit non-fatal warnings on stderr (for example line-ending notices).
# In PowerShell 7+, those can become terminating errors when ErrorActionPreference is Stop.
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

try {
    $repoRoot = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'not a git repo' }
    Set-Location $repoRoot
} catch {
    Write-Error "Unable to determine repository root: $_"
    exit 1
}

# Only operate on files that are already staged for this commit.
$stagedPaths = git diff --cached --name-only --diff-filter=ACMR 2>$null | Where-Object { $_ -ne '' }

$cpp = @(
    $stagedPaths | Where-Object {
        $_ -match '\.(c|cc|cpp|cxx|h|hpp)$'
    }
)

$luau = @(
    $stagedPaths | Where-Object {
        $_ -like '*.luau' `
            -and $_ -notlike 'src/modules/unicode/_data/*' `
            -and $_ -ne 'src/modules/uuid.luau' `
            -and $_ -ne 'src/modules/uuid.test.luau' `
            -and $_ -ne 'src/modules/number.test.luau'
    }
)

$formattedPaths = @($cpp + $luau)

$formattingChanged = $false

if ($cpp) {
    if (Get-Command clang-format -ErrorAction SilentlyContinue) {
        if ($DryRun) {
            Write-Host "Checking C/C++ files with clang-format..."
            foreach ($f in $cpp) {
                $out = & clang-format -output-replacements-xml -- $f 2>$null
                if ($out -match '<replacement ') { Write-Host "Needs format: $f"; $formattingChanged = $true }
            }
        } else {
            Write-Host "Running clang-format on $($cpp.Count) files..."
            & clang-format -i --style=file $cpp
        }
    } else {
        Write-Host "clang-format not found; skipping C/C++ formatting"
    }
}

if ($luau) {
    if (Get-Command stylua -ErrorAction SilentlyContinue) {
        if ($DryRun) {
            Write-Host "Checking .luau files with stylua..."
            # stylua supports --check (non-zero if needs formatting)
            try {
                & stylua --check $luau 2>$null | Out-Null
            } catch {
                Write-Host ".luau files need formatting (stylua --check failed)"; $formattingChanged = $true
            }
        } else {
            Write-Host "Running stylua on $($luau.Count) files..."
            & stylua $luau
        }
    } else {
        Write-Host "stylua not found; skipping .luau formatting"
    }
}

if ($DryRun) {
    if ($formattingChanged) {
        Write-Host "Formatting problems detected (dry-run)." -ForegroundColor Yellow
        exit 2
    } else {
        Write-Host "No formatting problems detected (dry-run)."
        exit 0
    }
} else {
    $modified = @()
    if ($formattedPaths) {
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $modified = @(
                git diff --name-only -- $formattedPaths 2>$null |
                    Where-Object { $_ -ne '' -and $formattedPaths -contains $_ }
            )
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
    }
    if ($modified) {
        Write-Host "Modified files from formatting:"
        $modified | ForEach-Object { Write-Host "  $_" }
        if ($ApplyAndAbort) {
            $oldErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                git add -- $modified
            } finally {
                $ErrorActionPreference = $oldErrorActionPreference
            }
            Write-Host "Staged formatted files. Commit aborted so you can review." -ForegroundColor Yellow
            exit 1
        } else {
            Write-Host "Run 'git add' to stage changes, or run this script with -ApplyAndAbort from a hook." -ForegroundColor Yellow
        }
    } elseif (-not $cpp -and -not $luau) {
        Write-Host "No staged C/C++ or .luau files to format."
    } else {
        Write-Host "No changes from formatting."
    }
}

exit 0
