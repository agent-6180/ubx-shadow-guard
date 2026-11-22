# Static checks only. Never executes the utility or touches VSS, services or tasks.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'ubxshadow_guard.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Error $_.Message }
    throw 'PowerShell parser errors detected.'
}

function Get-FunctionText {
    param([Parameter(Mandatory = $true)][string]$Name)
    $match = $ast.Find({
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
    }, $true)
    if ($null -eq $match) { throw "Function missing: $Name" }
    return $match.Extent.Text
}

function Assert-Contains {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) { throw $Message }
}
function Assert-Excludes {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -match $Pattern) { throw $Message }
}

Assert-Excludes $source 'New-ShadowViaVssAdmin|create\x27\s*,\s*\x27shadow' 'Unsupported VSSADMIN create path remains.'
Assert-Excludes $source 'continue\s+2\b' 'Numeric continue statement remains.'
Assert-Contains $source 'MethodOrder\s*=\s*@\(\x27CIM\x27,\x27WMI\x27\)' 'Method order not migrated to CIM/WMI.'

$repair = Get-FunctionText 'Invoke-InstallOrRepair'
foreach ($option in @('Quota','IncludeVolumes','ExcludeVolumes','ForceProtectLikelyBackupVolumes')) {
    Assert-Contains $repair ("RequestedParameters\.ContainsKey\('" + $option + "'\)") "Repair does not preserve supplied-parameter semantics for $option."
}
Assert-Contains $repair 'Remove-StaleVolumeTasks' 'Repair does not clean up stale scheduled tasks.'

$runner = Get-FunctionText 'Invoke-RunOnce'
Assert-Contains $runner 'not eligible under saved policy' 'RunOnce lacks a volume-policy gate.'
Assert-Excludes $runner 'Repair-CoreServices|Set-ShadowStorageQuota' 'RunOnce changes services or VSS quotas.'

$install = Get-FunctionText 'Install-Self'
Assert-Contains $install 'self-copy skipped' 'Installer lacks same-path protection.'

$processor = Get-FunctionText 'Invoke-ExternalCommand'
Assert-Contains $processor 'StandardOutput\.ReadToEndAsync\(' 'No async standard output drain.'
Assert-Contains $processor 'StandardError\.ReadToEndAsync\(' 'No async standard error drain.'

Write-Host 'Shadow Guard syntax and static invariants passed.' -ForegroundColor Green
