<#
.SYNOPSIS
    UBXShadowGuard - VSS Shadow Copy scheduler and repair utility. v0.5.0

.DESCRIPTION
    Creates and maintains hourly VSS shadow copies for fixed local Windows volumes.
    Designed for Windows 10/11 and Windows Server 2019+.
    Build: v0.5.0 - maintenance fixes and Windows PowerShell 5.1 compatible runner.

    Defaults:
      - 10% shadow storage quota per protected volume
      - hourly snapshots, 24 hours/day
      - CIM first
      - WMI object method fallback (no vssadmin creation dependency)
      - no WMIC dependency
      - per-volume scheduled tasks running as SYSTEM
      - C:\Source\UBXShadowGuard config/logging/install location

.NOTES
    Run from elevated PowerShell.

    Repository : https://github.com/agent-6180/ubx-shadow-guard
    Maintainer : Steve Panovski (@agent-6180)
    Organization: UBX Cloud - https://www.ubxcloud.com
    ASCII art  : New UBX wordmark for this script; not a verified copy of
                 Philip Simjanovski's original 2026 UBX ASCII logo.
    Attribution: Original ASCII logo design credited by the project owner to
                 Philip (Phillip) Simjanovski, 2026. Original art not located.
    Licensing  : No open-source license declared. See NOTICE.md in repository.
    Safety     : VSS snapshots are not a substitute for independent backups.
                 Changing shadow storage quotas can evict existing snapshots.

.EXAMPLES
    .\ubxshadow_guard.ps1 -Install
    .\ubxshadow_guard.ps1 -Status
    .\ubxshadow_guard.ps1 -Repair
    .\ubxshadow_guard.ps1 -RunOnce -Volume C:
    .\ubxshadow_guard.ps1 -Uninstall
#>

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [switch]$Install,

    [Parameter(ParameterSetName = 'RunOnce', Mandatory = $true)]
    [switch]$RunOnce,

    [Parameter(ParameterSetName = 'Status', Mandatory = $true)]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Repair', Mandatory = $true)]
    [switch]$Repair,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory = $true)]
    [switch]$Uninstall,

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Repair')]
    [string]$Quota = '10%',

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Repair')]
    [string[]]$IncludeVolumes = @(),

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Repair')]
    [string[]]$ExcludeVolumes = @(),

    [Parameter(ParameterSetName = 'RunOnce', Mandatory = $true)]
    [string]$Volume,

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Repair')]
    [switch]$NoInitialSnapshot,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$DeleteConfig,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$ResetShadowStorage,

    [Parameter(ParameterSetName = 'Install')]
    [Parameter(ParameterSetName = 'Repair')]
    [switch]$ForceProtectLikelyBackupVolumes
)

# Capture caller-supplied options so a -Repair preserves saved policy.
$script:RequestedParameters = @{}
foreach ($key in $PSBoundParameters.Keys) {
    $script:RequestedParameters[$key] = $PSBoundParameters[$key]
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$AppName = 'UBXShadowGuard'
$RootPath = 'C:\Source'
$BasePath = Join-Path $RootPath $AppName
$LogPath = Join-Path $BasePath 'Logs'
$ConfigPath = Join-Path $BasePath 'config.json'
$StatePath = Join-Path $BasePath 'state.json'
$InstalledScriptPath = Join-Path $BasePath 'ubxshadow_guard.ps1'
$TaskPrefix = 'UBXShadowGuard_'
$EventSource = 'UBXShadowGuard'

# Replacement text-only UBX wordmark. Not the verified 2026 Philip Simjanovski original.
function Show-UBXBanner {
    $wordmark = @'
 _   _ ____  __  __
| | | | __ ) \ \/ /
| | | |  _ \  \  /
| |_| | |_) | /  \
 \___/|____/ /_/\_\
       C L O U D
'@
    Write-Host $wordmark -ForegroundColor Cyan
    Write-Host 'UBX Shadow Guard | https://github.com/agent-6180/ubx-shadow-guard' -ForegroundColor Gray
}

function New-DirectoryIfMissing {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Initialize-AppFolders {
    New-DirectoryIfMissing -Path $RootPath
    New-DirectoryIfMissing -Path $BasePath
    New-DirectoryIfMissing -Path $LogPath
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO',
        [switch]$NoConsole
    )

    Initialize-AppFolders

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'
    $line = "[$timestamp][$Level] $Message"
    $file = Join-Path $LogPath ("{0}-{1}.log" -f $AppName, (Get-Date -Format 'yyyyMMdd'))

    Add-Content -Path $file -Value $line -Encoding UTF8

    if (-not $NoConsole) {
        switch ($Level) {
            'OK'    { Write-Host $line -ForegroundColor Green }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'ERROR' { Write-Host $line -ForegroundColor Red }
            default { Write-Host $line -ForegroundColor Gray }
        }
    }
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator rights are required. Start PowerShell as Administrator.'
    }
}

function Ensure-EventSource {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            New-EventLog -LogName Application -Source $EventSource -ErrorAction Stop
        }
    } catch {
        Write-Log "Could not create event source ${EventSource}. Continuing with file logging only. $($_.Exception.Message)" 'WARN'
    }
}

function Write-AppEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Information','Warning','Error')][string]$EntryType = 'Information',
        [int]$EventId = 1000
    )

    try {
        Ensure-EventSource
        Write-EventLog -LogName Application -Source $EventSource -EntryType $EntryType -EventId $EventId -Message $Message -ErrorAction Stop
    } catch {
        # File logging is primary. Avoid recursive event-log failures.
    }
}

function Normalize-VolumeName {
    param([Parameter(Mandatory = $true)][string]$InputVolume)

    $v = $InputVolume.Trim()

    if ($v.Length -eq 1 -and $v -match '^[A-Za-z]$') {
        $v = "${v}:"
    }

    if ($v.Length -eq 2 -and $v -match '^[A-Za-z]:$') {
        return $v.ToUpperInvariant()
    }

    if ($v.Length -eq 3 -and $v -match '^[A-Za-z]:\\$') {
        return $v.Substring(0,2).ToUpperInvariant()
    }

    return $v
}

function Normalize-VolumeList {
    param([string[]]$Volumes)

    $out = @()

    foreach ($item in $Volumes) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }

        $out += (Normalize-VolumeName -InputVolume $item)
    }

    return @($out)
}

function Get-DefaultConfig {
    [ordered]@{
        Version = 1
        Quota = '10%'
        SnapshotIntervalHours = 1
        IncludeVolumes = @()
        ExcludeVolumes = @()
        ExcludedVolumeLabels = @('Veeam','Backup','Repository','Repo','Scratch','Temp','Cache','Pagefile','SQLTemp')
        ForceProtectLikelyBackupVolumes = $false
        PreferCachedMethod = $true
        MethodOrder = @('CIM','WMI')
        LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$DefaultObject
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $DefaultObject
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $DefaultObject
        }

        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "Could not read JSON file ${Path}. Using defaults. $($_.Exception.Message)" 'WARN'
        return $DefaultObject
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object
    )

    Initialize-AppFolders
    $Object | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-Config {
    $default = Get-DefaultConfig
    $config = Read-JsonFile -Path $ConfigPath -DefaultObject $default
    if ($config -is [System.Collections.IDictionary]) {
        $config = [pscustomobject]$config
    }

    foreach ($key in $default.Keys) {
        if (-not ($config.PSObject.Properties.Name -contains $key)) {
            $config | Add-Member -NotePropertyName $key -NotePropertyValue $default[$key]
        }
    }

    return $config
}

function Save-Config {
    param([Parameter(Mandatory = $true)]$Config)

    $Config.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Write-JsonFile -Path $ConfigPath -Object $Config
}

function Get-State {
    $default = [ordered]@{
        Version = 1
        Volumes = @{}
        LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    $state = Read-JsonFile -Path $StatePath -DefaultObject $default

    if (-not ($state.PSObject.Properties.Name -contains 'Volumes') -or $null -eq $state.Volumes) {
        $state | Add-Member -NotePropertyName Volumes -NotePropertyValue @{} -Force
    }

    return $state
}

function Save-State {
    param([Parameter(Mandatory = $true)]$State)

    $State.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Write-JsonFile -Path $StatePath -Object $State
}

function Set-VolumeState {
    param(
        [Parameter(Mandatory = $true)][string]$VolumeName,
        [AllowNull()][string]$LastGoodMethod,
        [bool]$LastSuccess,
        [string]$LastMessage,
        [Nullable[int]]$LastReturnValue = $null
    )

    $state = Get-State
    $volKey = Normalize-VolumeName -InputVolume $VolumeName

    if ($state.Volumes -is [System.Management.Automation.PSCustomObject]) {
        $hash = @{}
        foreach ($p in $state.Volumes.PSObject.Properties) {
            $hash[$p.Name] = $p.Value
        }
        $state.Volumes = $hash
    }

    $state.Volumes[$volKey] = [ordered]@{
        Volume = $volKey
        LastGoodMethod = $LastGoodMethod
        LastSuccess = $LastSuccess
        LastMessage = $LastMessage
        LastReturnValue = $LastReturnValue
        LastRunUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    Save-State -State $state
}

function Get-VolumeStateEntry {
    param([Parameter(Mandatory = $true)][string]$VolumeName)

    $state = Get-State
    $volKey = Normalize-VolumeName -InputVolume $VolumeName

    if ($state.Volumes -is [System.Management.Automation.PSCustomObject]) {
        $prop = $state.Volumes.PSObject.Properties[$volKey]

        if ($prop) {
            return $prop.Value
        }

        return $null
    }

    if ($state.Volumes.ContainsKey($volKey)) {
        return $state.Volumes[$volKey]
    }

    return $null
}

function Test-CimHealth {
    try {
        Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Log "CIM health check failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Ensure-ServiceRunning {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('Automatic','Manual')][string]$StartupType = 'Manual',
        [switch]$AllowFailure
    )

    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop

        if ($svc.StartType -eq 'Disabled') {
            Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        } elseif ($svc.StartType -ne $StartupType -and $Name -in @('Schedule','winmgmt')) {
            Set-Service -Name $Name -StartupType $StartupType -ErrorAction SilentlyContinue
        }

        $svc = Get-Service -Name $Name -ErrorAction Stop

        if ($svc.Status -ne 'Running') {
            Start-Service -Name $Name -ErrorAction Stop
        }

        Write-Log "Service ${Name} is running." 'OK'
        return $true
    } catch {
        $msg = "Service ${Name} could not be started or configured: $($_.Exception.Message)"

        if ($AllowFailure) {
            Write-Log $msg 'WARN'
            return $false
        }

        throw $msg
    }
}

function Repair-CoreServices {
    Write-Log 'Checking core services.' 'INFO'

    Ensure-ServiceRunning -Name 'Schedule' -StartupType 'Automatic' | Out-Null
    Ensure-ServiceRunning -Name 'winmgmt' -StartupType 'Automatic' | Out-Null
    Ensure-ServiceRunning -Name 'VSS' -StartupType 'Manual' | Out-Null
    Ensure-ServiceRunning -Name 'swprv' -StartupType 'Manual' -AllowFailure | Out-Null
}

function Get-OsSupportInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $caption = [string]$os.Caption
    $build = [int]$os.BuildNumber
    $isServer = $caption -match 'Server'
    $supported = $false

    if ($isServer) {
        $supported = $build -ge 17763
    } else {
        $supported = $build -ge 10240
    }

    [pscustomobject]@{
        Caption = $caption
        Version = [string]$os.Version
        Build = $build
        IsServer = $isServer
        SupportedTarget = $supported
    }
}

function Get-ProtectableVolumes {
    param([Parameter(Mandatory = $true)]$Config)

    $include = @(Normalize-VolumeList -Volumes @($Config.IncludeVolumes))
    $exclude = @(Normalize-VolumeList -Volumes @($Config.ExcludeVolumes))

    $volumes = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
        Where-Object {
            $_.DriveType -eq 3 -and
            -not [string]::IsNullOrWhiteSpace($_.DeviceID)
        }

    $selected = @()

    foreach ($v in $volumes) {
        $device = Normalize-VolumeName -InputVolume $v.DeviceID
        $label = [string]$v.VolumeName

        if ($include.Count -gt 0 -and $include -notcontains $device) {
            continue
        }

        if ($exclude -contains $device) {
            continue
        }

        if (-not [bool]$Config.ForceProtectLikelyBackupVolumes) {
            foreach ($bad in @($Config.ExcludedVolumeLabels)) {
                if (-not [string]::IsNullOrWhiteSpace($bad) -and $label -match [regex]::Escape($bad)) {
                    Write-Log "Skipping ${device} because volume label '${label}' matches excluded label '${bad}'. Use -ForceProtectLikelyBackupVolumes to override." 'WARN'
                    continue 2
                }
            }
        }

        if ([int64]$v.Size -lt 10737418240) {
            Write-Log "Skipping ${device} because volume is smaller than 10 GB." 'WARN'
            continue
        }

        $selected += [pscustomobject]@{
            DeviceID = $device
            VolumeName = $label
            SizeBytes = [int64]$v.Size
            FreeBytes = [int64]$v.FreeSpace
            FileSystem = [string]$v.FileSystem
        }
    }

    return @($selected)
}

function ConvertTo-ProcessArgumentString {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $escaped = @()

    foreach ($arg in $Arguments) {
        if ($null -eq $arg) {
            continue
        }

        $a = [string]$arg

        if ($a -match '[\s"]') {
            $a = '"' + ($a -replace '"','\"') + '"'
        }

        $escaped += $a
    }

    return ($escaped -join ' ')
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-ProcessArgumentString -Arguments $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    [void]$p.Start()

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()

    $p.WaitForExit()

    [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut = $stdout.Trim()
        StdErr = $stderr.Trim()
        Combined = (($stdout, $stderr) -join "`n").Trim()
    }
}

function Test-QuotaValue {
    param([Parameter(Mandatory = $true)][string]$Quota)

    if ($Quota -match '^([1-9][0-9]?|100)%$') {
        return $true
    }

    if ($Quota -match '^[1-9][0-9]*(KB|MB|GB|TB)$') {
        return $true
    }

    if ($Quota -eq 'UNBOUNDED') {
        return $true
    }

    return $false
}

function Set-ShadowStorageQuota {
    param(
        [Parameter(Mandatory = $true)][string]$VolumeName,
        [Parameter(Mandatory = $true)][string]$Quota
    )

    $vol = Normalize-VolumeName -InputVolume $VolumeName

    if (-not (Test-QuotaValue -Quota $Quota)) {
        throw "Invalid quota '${Quota}'. Use values like 10%, 50GB, 500MB, or UNBOUNDED."
    }

    Write-Log "Setting shadow storage quota for ${vol} to ${Quota}." 'INFO'

    $resize = Invoke-ExternalCommand -FilePath 'vssadmin.exe' -Arguments @(
        'resize',
        'shadowstorage',
        "/for=$vol",
        "/on=$vol",
        "/maxsize=$Quota"
    )

    if ($resize.ExitCode -eq 0) {
        Write-Log "Shadow storage quota configured for ${vol}." 'OK'
        return $true
    }

    Write-Log "Primary shadowstorage resize failed for ${vol}. Exit $($resize.ExitCode). $($resize.Combined)" 'WARN'

    $add = Invoke-ExternalCommand -FilePath 'vssadmin.exe' -Arguments @(
        'add',
        'shadowstorage',
        "/for=$vol",
        "/on=$vol",
        "/maxsize=$Quota"
    )

    if ($add.ExitCode -eq 0) {
        Write-Log "Shadow storage quota added for ${vol}." 'OK'
        return $true
    }

    Write-Log "Shadowstorage add also failed for ${vol}. Exit $($add.ExitCode). $($add.Combined)" 'WARN'
    return $false
}

function Convert-ShadowReturnValueToText {
    param([AllowNull()][int]$ReturnValue)

    switch ($ReturnValue) {
        0  { return 'Success' }
        1  { return 'Access denied' }
        2  { return 'Invalid argument' }
        3  { return 'Specified volume not found' }
        4  { return 'Specified volume not supported' }
        5  { return 'Unsupported shadow copy context' }
        6  { return 'Insufficient storage' }
        7  { return 'Volume in use' }
        8  { return 'Maximum number of shadow copies reached' }
        9  { return 'Another shadow copy operation is already in progress' }
        10 { return 'Shadow copy provider vetoed operation' }
        11 { return 'Shadow copy provider not registered' }
        12 { return 'Shadow copy provider failure' }
        default { return "Unknown return value ${ReturnValue}" }
    }
}

function New-ShadowViaCim {
    param([Parameter(Mandatory = $true)][string]$VolumeName)

    $vol = Normalize-VolumeName -InputVolume $VolumeName
    $volumeArg = "${vol}\"

    $r = Invoke-CimMethod `
        -ClassName Win32_ShadowCopy `
        -MethodName Create `
        -Arguments @{
            Volume = $volumeArg
            Context = 'ClientAccessible'
        } `
        -ErrorAction Stop

    [pscustomobject]@{
        Method = 'CIM'
        Success = ([int]$r.ReturnValue -eq 0)
        ReturnValue = [int]$r.ReturnValue
        ShadowID = [string]$r.ShadowID
        Message = Convert-ShadowReturnValueToText -ReturnValue ([int]$r.ReturnValue)
    }
}

function New-ShadowViaWmiLastResort {
    param([Parameter(Mandatory = $true)][string]$VolumeName)

    $vol = Normalize-VolumeName -InputVolume $VolumeName
    $volumeArg = "${vol}\"

    $class = Get-WmiObject -List Win32_ShadowCopy -ErrorAction Stop
    $r = $class.Create($volumeArg, 'ClientAccessible')

    [pscustomobject]@{
        Method = 'WMI'
        Success = ([int]$r.ReturnValue -eq 0)
        ReturnValue = [int]$r.ReturnValue
        ShadowID = [string]$r.ShadowID
        Message = Convert-ShadowReturnValueToText -ReturnValue ([int]$r.ReturnValue)
    }
}

function Get-MethodOrderForVolume {
    param(
        [Parameter(Mandatory = $true)][string]$VolumeName,
        [Parameter(Mandatory = $true)]$Config
    )

    # Ignore obsolete VSSADMIN values in older on-disk configuration.
    $base = @($Config.MethodOrder | Where-Object { $_ -in @('CIM','WMI') })

    if ($base.Count -eq 0) {
        $base = @('CIM','WMI')
    }

    # WMI is always last resort.
    $base = @($base | Where-Object { $_ -ne 'WMI' }) + @('WMI')
    $base = @($base | Select-Object -Unique)

    if ([bool]$Config.PreferCachedMethod) {
        $entry = Get-VolumeStateEntry -VolumeName $VolumeName

        if ($entry -and $entry.LastSuccess -eq $true -and -not [string]::IsNullOrWhiteSpace($entry.LastGoodMethod)) {
            $cached = [string]$entry.LastGoodMethod

            if ($base -contains $cached -and $cached -ne 'WMI') {
                $base = @($cached) + @($base | Where-Object { $_ -ne $cached })
            }
        }
    }

    return $base
}

function New-AdaptiveShadowCopy {
    param(
        [Parameter(Mandatory = $true)][string]$VolumeName,
        [Parameter(Mandatory = $true)]$Config
    )

    $vol = Normalize-VolumeName -InputVolume $VolumeName
    $methods = Get-MethodOrderForVolume -VolumeName $vol -Config $Config
    $errors = @()

    foreach ($method in $methods) {
        try {
            Write-Log "Attempting shadow copy for ${vol} using ${method}." 'INFO'

            switch ($method) {
                'CIM'      { $r = New-ShadowViaCim -VolumeName $vol }
                'WMI'      { $r = New-ShadowViaWmiLastResort -VolumeName $vol }
                default    { continue }
            }

            if ($r.Success) {
                Write-Log "Shadow copy created for ${vol} using $($r.Method). $($r.Message)" 'OK'
                Set-VolumeState -VolumeName $vol -LastGoodMethod $r.Method -LastSuccess $true -LastMessage $r.Message -LastReturnValue $r.ReturnValue
                Write-AppEvent -Message "Shadow copy created for ${vol} using $($r.Method)." -EntryType Information -EventId 1100
                return $true
            }

            $msg = "${method} failed for ${vol}. Return $($r.ReturnValue): $($r.Message)"
            Write-Log $msg 'WARN'
            $errors += $msg

            if ($r.ReturnValue -in @(6,8,9,10,11,12)) {
                Repair-CoreServices
            }
        } catch {
            $msg = "${method} exception for ${vol}: $($_.Exception.Message)"
            Write-Log $msg 'WARN'
            $errors += $msg
        }
    }

    $final = "All shadow creation methods failed for ${vol}. $($errors -join ' | ')"
    Write-Log $final 'ERROR'
    Set-VolumeState -VolumeName $vol -LastGoodMethod $null -LastSuccess $false -LastMessage $final
    Write-AppEvent -Message $final -EntryType Error -EventId 9100

    return $false
}

function Get-TaskNameForVolume {
    param([Parameter(Mandatory = $true)][string]$VolumeName)

    $vol = Normalize-VolumeName -InputVolume $VolumeName
    return "$TaskPrefix$($vol -replace ':','')"
}

function Register-VolumeTask {
    param([Parameter(Mandatory = $true)][string]$VolumeName)

    $vol = Normalize-VolumeName -InputVolume $VolumeName
    $taskName = Get-TaskNameForVolume -VolumeName $vol

    if (-not (Test-Path -LiteralPath $InstalledScriptPath)) {
        throw "Installed script not found at ${InstalledScriptPath}. Run -Install first."
    }

    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$InstalledScriptPath`" -RunOnce -Volume $vol"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg

    $triggers = @()

    foreach ($hour in 0..23) {
        $at = (Get-Date -Hour $hour -Minute 0 -Second 0)
        $triggers += New-ScheduledTaskTrigger -Daily -At $at
    }

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $triggers `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    Write-Log "Registered scheduled task ${taskName} for ${vol}." 'OK'
}

function Remove-VolumeTasks {
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like "$TaskPrefix*"
    }

    foreach ($t in $tasks) {
        try {
            Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction Stop
            Write-Log "Removed scheduled task $($t.TaskName)." 'OK'
        } catch {
            Write-Log "Failed to remove scheduled task $($t.TaskName): $($_.Exception.Message)" 'WARN'
        }
    }
}

function Install-Self {
    Initialize-AppFolders

    $current = $PSCommandPath

    if ([string]::IsNullOrWhiteSpace($current)) {
        throw 'Cannot determine current script path. Save the script to disk before running -Install.'
    }

    $sourceFull = [System.IO.Path]::GetFullPath($current)
    $targetFull = [System.IO.Path]::GetFullPath($InstalledScriptPath)

    if ([string]::Equals($sourceFull, $targetFull, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Log "Already running from ${InstalledScriptPath}; self-copy skipped." 'INFO'
        return
    }

    Copy-Item -LiteralPath $sourceFull -Destination $InstalledScriptPath -Force
    Write-Log "Installed utility to ${InstalledScriptPath}." 'OK'
}

function Show-Status {
    Assert-Admin
    Initialize-AppFolders

    $config = Get-Config
    $state = Get-State
    $null = $state
    $os = Get-OsSupportInfo

    Write-Host ''
    Write-Host "=== ${AppName} Status ===" -ForegroundColor Cyan
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host "OS: $($os.Caption) build $($os.Build)"
    Write-Host "Supported target: $($os.SupportedTarget)"
    Write-Host "Config: ${ConfigPath}"
    Write-Host "State:  ${StatePath}"
    Write-Host "Log:    ${LogPath}"
    Write-Host "Quota:  $($config.Quota)"
    Write-Host ''

    Write-Host 'Services:' -ForegroundColor Cyan

    foreach ($serviceName in @('Schedule','winmgmt','VSS','swprv')) {
        try {
            $s = Get-Service -Name $serviceName -ErrorAction Stop
            Write-Host ("  {0,-10} {1,-10} {2}" -f $s.Name, $s.Status, $s.StartType)
        } catch {
            Write-Host ("  {0,-10} Missing" -f $serviceName)
        }
    }

    Write-Host ''
    Write-Host 'Protected candidate volumes:' -ForegroundColor Cyan

    $volumes = @(Get-ProtectableVolumes -Config $config)

    foreach ($v in $volumes) {
        $entry = Get-VolumeStateEntry -VolumeName $v.DeviceID

        if ($entry) {
            $last = "$($entry.LastSuccess) via $($entry.LastGoodMethod) at $($entry.LastRunUtc)"
        } else {
            $last = 'Never run'
        }

        Write-Host ("  {0,-4} Label='{1}' SizeGB={2:N1} FreeGB={3:N1} Last={4}" -f $v.DeviceID, $v.VolumeName, ($v.SizeBytes/1GB), ($v.FreeBytes/1GB), $last)
    }

    Write-Host ''
    Write-Host 'Scheduled tasks:' -ForegroundColor Cyan

    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like "$TaskPrefix*"
    }

    foreach ($t in $tasks) {
        try {
            $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -ErrorAction Stop
            Write-Host ("  {0,-24} State={1,-8} LastRun={2} LastResult={3}" -f $t.TaskName, $t.State, $info.LastRunTime, $info.LastTaskResult)
        } catch {
            Write-Host "  $($t.TaskName) State=$($t.State)"
        }
    }

    Write-Host ''
    Write-Host 'Shadow storage:' -ForegroundColor Cyan

    $r = Invoke-ExternalCommand -FilePath 'vssadmin.exe' -Arguments @('list','shadowstorage')

    if ($r.Combined) {
        Write-Host $r.Combined
    }
}

function Invoke-InstallOrRepair {
    param([switch]$IsRepair)

    Assert-Admin
    Initialize-AppFolders
    Ensure-EventSource

    $os = Get-OsSupportInfo
    Write-Log "Detected OS: $($os.Caption), build $($os.Build)." 'INFO'

    if (-not $os.SupportedTarget) {
        Write-Log 'This OS is outside the declared support target. Continuing best-effort.' 'WARN'
    }

    Repair-CoreServices

    if (-not (Test-CimHealth)) {
        Write-Log 'CIM is unhealthy after service repair. Continuing with vssadmin/WMI fallback where possible.' 'WARN'
    }

    Install-Self

    $config = Get-Config

    # Only options explicitly passed by the caller replace saved configuration.
    if ($script:RequestedParameters.ContainsKey('Quota')) {
        $config.Quota = $Quota
    }
    if ($script:RequestedParameters.ContainsKey('IncludeVolumes')) {
        $config.IncludeVolumes = @(Normalize-VolumeList -Volumes $IncludeVolumes)
    }
    if ($script:RequestedParameters.ContainsKey('ExcludeVolumes')) {
        $config.ExcludeVolumes = @(Normalize-VolumeList -Volumes $ExcludeVolumes)
    }
    if ($script:RequestedParameters.ContainsKey('ForceProtectLikelyBackupVolumes')) {
        $config.ForceProtectLikelyBackupVolumes = [bool]$ForceProtectLikelyBackupVolumes
    }

    # Preserve PreferCachedMethod; migrate only removed, invalid method.
    $config.MethodOrder = @('CIM','WMI')
    if (-not (Test-QuotaValue -Quota $config.Quota)) {
        throw "Saved shadow storage quota '$($config.Quota)' is invalid."
    }

    Save-Config -Config $config

    $volumes = @(Get-ProtectableVolumes -Config $config)

    if ($volumes.Count -eq 0) {
        throw 'No protectable fixed local volumes were found after include/exclude filtering.'
    }

    foreach ($v in $volumes) {
        Write-Log "Configuring $($v.DeviceID) label='$($v.VolumeName)' sizeGB=$([math]::Round($v.SizeBytes/1GB,1))." 'INFO'

        [void](Set-ShadowStorageQuota -VolumeName $v.DeviceID -Quota $config.Quota)

        Register-VolumeTask -VolumeName $v.DeviceID

        if (-not $NoInitialSnapshot) {
            [void](New-AdaptiveShadowCopy -VolumeName $v.DeviceID -Config $config)
        }
    }

    if ($IsRepair) {
        $mode = 'Repair'
    } else {
        $mode = 'Install'
    }

    Write-Log "${mode} complete." 'OK'
    Write-AppEvent -Message "${AppName} ${mode} complete." -EntryType Information -EventId 1001
}

function Invoke-RunOnce {
    Assert-Admin
    Initialize-AppFolders

    $config = Get-Config
    $vol = Normalize-VolumeName -InputVolume $Volume

    Repair-CoreServices

    [void](Set-ShadowStorageQuota -VolumeName $vol -Quota $config.Quota)

    $ok = New-AdaptiveShadowCopy -VolumeName $vol -Config $config

    if (-not $ok) {
        exit 2
    }
}

function Invoke-Uninstall {
    Assert-Admin
    Initialize-AppFolders

    Remove-VolumeTasks

    if ($ResetShadowStorage) {
        $config = Get-Config
        $volumes = Get-ProtectableVolumes -Config $config

        foreach ($v in $volumes) {
            Write-Log "ResetShadowStorage requested. Leaving existing shadow copies intact, setting quota to 10% for $($v.DeviceID)." 'WARN'
            [void](Set-ShadowStorageQuota -VolumeName $v.DeviceID -Quota '10%')
        }
    }

    if ($DeleteConfig) {
        try {
            Remove-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
            Write-Log 'Deleted config and state files.' 'OK'
        } catch {
            Write-Log "Failed to delete config/state: $($_.Exception.Message)" 'WARN'
        }
    }

    Write-Log 'Uninstall complete. Existing shadow copies were not deleted.' 'OK'
}

# Show branding only for interactive management commands, not hourly SYSTEM jobs.
if ($PSCmdlet.ParameterSetName -ne 'RunOnce') {
    Show-UBXBanner
}

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Install'   { Invoke-InstallOrRepair }
        'Repair'    { Invoke-InstallOrRepair -IsRepair }
        'RunOnce'   { Invoke-RunOnce }
        'Status'    { Show-Status }
        'Uninstall' { Invoke-Uninstall }
        default     { Invoke-InstallOrRepair }
    }
} catch {
    try {
        Write-Log $_.Exception.Message 'ERROR'
        Write-AppEvent -Message $_.Exception.Message -EntryType Error -EventId 9000
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }

    exit 1
}
