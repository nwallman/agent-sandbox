# PowerShell wrapper for sandbox.sh
# Passes all arguments through to the bash script via Git Bash

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BashScript = "$ScriptDir/sandbox.sh"

# Find Git Bash
$GitBash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $GitBash)) {
    $GitBash = (Get-Command bash -ErrorAction SilentlyContinue).Source
    if (-not $GitBash) {
        Write-Error "Cannot find bash. Install Git for Windows."
        exit 1
    }
}

# Convert Windows path to Unix path for the script
$UnixScript = $BashScript -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
$UnixScript = $UnixScript.ToLower().Substring(0,2) + $UnixScript.Substring(2)

& $GitBash $UnixScript @args
exit $LASTEXITCODE
