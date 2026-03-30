param(
    [switch]$ApplyAndAbort,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

try {
    $repoRoot = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'not a git repo' }
    Set-Location $repoRoot
} catch {
    Write-Error "Unable to determine repository root: $_"
    exit 1
}

$cpp = git ls-files '*.c' '*.cpp' '*.cc' '*.cxx' '*.h' '*.hpp' 2>$null | Where-Object { $_ -ne '' }
$luau = git ls-files '*.luau' 2>$null | Where-Object { $_ -ne '' }

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
    $modified = git ls-files -m 2>$null
    if ($modified) {
        Write-Host "Modified files from formatting:"
        $modified | ForEach-Object { Write-Host "  $_" }
        if ($ApplyAndAbort) {
            git add $modified
            Write-Host "Staged formatted files. Aborting commit so you can review." -ForegroundColor Yellow
            exit 1
        } else {
            Write-Host "Run 'git add' to stage changes, or run this script with -ApplyAndAbort from a hook." -ForegroundColor Yellow
        }
    } else {
        Write-Host "No changes from formatting."
    }
}

exit 0
