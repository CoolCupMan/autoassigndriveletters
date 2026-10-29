<#
.SYNOPSIS
    Builds dist\AutoAssignDriveLetters.exe from src\AutoAssignDriveLetters.ps1 with PS2EXE.
    The version number is taken from $Script:AppVersion in the script.
#>
[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dist')
)
$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'src\AutoAssignDriveLetters.ps1'

# Fail early on syntax errors.
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors) {
    $errors | ForEach-Object { Write-Host "$($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    throw 'Syntax errors in the script.'
}

$match = Select-String -LiteralPath $source -Pattern "\`$Script:AppVersion\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'" | Select-Object -First 1
if (-not $match) { throw 'AppVersion not found in script.' }
$version = $match.Matches[0].Groups[1].Value

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$output = Join-Path $OutputDir 'AutoAssignDriveLetters.exe'

$ps2exe = @{
    inputFile    = $source
    outputFile   = $output
    requireAdmin = $true
    title        = 'AutoAssignDriveLetters'
    description  = 'Keeps fixed drive letters for USB sticks, external and internal drives'
    product      = 'AutoAssignDriveLetters'
    company      = 'AutoAssignDriveLetters'
    copyright    = "(c) $((Get-Date).Year)"
    version      = "$version.0"
}
$icon = Join-Path $PSScriptRoot 'assets\icon.ico'
if (Test-Path $icon) { $ps2exe.iconFile = $icon }

Invoke-ps2exe @ps2exe
if (-not (Test-Path $output)) { throw 'PS2EXE did not produce an exe.' }

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $output).Hash
Set-Content -LiteralPath "$output.sha256" -Value "$hash  AutoAssignDriveLetters.exe" -Encoding ASCII
Write-Host "Built $output (version $version, SHA256 $hash)" -ForegroundColor Green
