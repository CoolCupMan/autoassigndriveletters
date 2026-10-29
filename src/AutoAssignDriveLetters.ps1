#Requires -Version 5.1
<#
.SYNOPSIS
    AutoAssignDriveLetters - always give the same drive letter to a USB stick,
    external or internal drive, identified by its hardware serial number.

.DESCRIPTION
    Run without parameters to open the interactive menu. There you pick a drive
    from the list of connected devices (or type a serial number / volume GUID
    yourself), choose the drive letter and install the background task.

    Each installation is an "instance" with its own unique ID, configuration,
    log and scheduled task, so several installations can run side by side.

    The background task starts at boot as SYSTEM, applies all rules and then
    waits for volume arrival events (plus a periodic re-check) to re-apply them
    whenever a device is plugged in.

.EXAMPLE
    AutoAssignDriveLetters.exe
    Opens the interactive menu.

.EXAMPLE
    AutoAssignDriveLetters.exe -AddSerial NAASPZ2N -Letter E -Install
    Pins the disk with serial NAASPZ2N to E: and installs the boot task.
#>
[CmdletBinding()]
param(
    [string]$InstanceId,
    [switch]$NewInstance,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Apply,
    [switch]$Monitor,
    [switch]$List,
    [switch]$ListInstances,
    [switch]$Status,
    [string]$AddSerial,
    [string]$AddVolume,
    [string]$Letter,
    [int]$Partition = 0,
    [string]$Name,
    [switch]$Force,
    [string]$RemoveRule,
    [switch]$RemoveLegacy,
    [switch]$KeepConfig,
    [switch]$Version,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 otherwise serialises some arrays as {"value":[...],"Count":n}.
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$Script:AppName     = 'AutoAssignDriveLetters'
$Script:AppVersion  = '2.0.0'
$Script:AppRoot     = Join-Path $env:ProgramData $Script:AppName
$Script:TaskPath    = "\$($Script:AppName)\"
$Script:UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$Script:ScriptPath  = $PSCommandPath
$Script:LogFile     = $null
$Script:RuleState   = @{}

# ---------------------------------------------------------------------------
# General helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    if ($Script:LogFile) {
        try {
            if ((Test-Path -LiteralPath $Script:LogFile) -and (Get-Item -LiteralPath $Script:LogFile).Length -gt 1MB) {
                Move-Item -LiteralPath $Script:LogFile -Destination "$($Script:LogFile).old" -Force
            }
            Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8
        } catch { }
    }
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Returns how this program is running: as compiled .exe or as .ps1 script.
function Get-SelfInfo {
    $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $leaf = [IO.Path]::GetFileNameWithoutExtension($processPath)
    if ($leaf -in @('powershell', 'pwsh', 'powershell_ise')) {
        return [pscustomobject]@{ IsExe = $false; Path = $Script:ScriptPath; HostPath = $processPath }
    }
    return [pscustomobject]@{ IsExe = $true; Path = $processPath; HostPath = $processPath }
}

# Builds the executable + argument string to start a copy of this program.
function Get-LaunchCommand {
    param([string]$ProgramPath, [string]$Arguments, [bool]$IsExe)
    if ($IsExe) {
        return [pscustomobject]@{ File = $ProgramPath; Args = $Arguments }
    }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return [pscustomobject]@{
        File = $ps
        Args = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" {1}' -f $ProgramPath, $Arguments).Trim()
    }
}

function ConvertTo-ArgumentString {
    param([System.Collections.IDictionary]$Bound)
    $parts = foreach ($key in $Bound.Keys) {
        $value = $Bound[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { "-$key" }
        } else {
            '-{0} "{1}"' -f $key, $value
        }
    }
    return ($parts -join ' ')
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Prompt $hint").Trim()
        if (-not $answer) { return $Default }
        if ($answer -match '^(y|yes|j|ja)$') { return $true }
        if ($answer -match '^(n|no|nein)$') { return $false }
    }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N1} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} B' -f $Bytes
}

function ConvertTo-DriveLetter {
    param([string]$Value)
    if ($Value -match '^\s*([A-Za-z]):?\\?\s*$') { return $Matches[1].ToUpperInvariant() }
    return $null
}

function ConvertTo-VolumeGuidPath {
    param([string]$Value)
    if ($Value -match '\{?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}?') {
        return '\\?\Volume{' + $Matches[1].ToLowerInvariant() + '}\'
    }
    return $null
}

# ---------------------------------------------------------------------------
# Instances and configuration
# ---------------------------------------------------------------------------
function Get-InstanceDir { param([string]$Id) Join-Path $Script:AppRoot $Id }
function Get-ConfigPath  { param([string]$Id) Join-Path (Get-InstanceDir $Id) 'config.json' }
function Get-TaskName    { param([string]$Id) "$($Script:AppName)_$Id" }

function New-InstanceIdString {
    return [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
}

function Test-InstanceIdString {
    param([string]$Id)
    return ($Id -match '^[A-Za-z0-9_-]{1,32}$')
}

function New-Config {
    param([string]$Id)
    return [pscustomobject]@{
        InstanceId   = $Id
        Name         = "Instance $Id"
        AppVersion   = $Script:AppVersion
        PollSeconds  = 30
        Rules        = @()
    }
}

function Read-Config {
    param([string]$Id)
    $path = Get-ConfigPath $Id
    if (-not (Test-Path -LiteralPath $path)) { return (New-Config $Id) }
    $cfg = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $cfg.Rules = @($cfg.Rules | Where-Object { $_ })
    if (-not ($cfg.PSObject.Properties.Name -contains 'PollSeconds')) {
        $cfg | Add-Member -NotePropertyName PollSeconds -NotePropertyValue 30
    }
    return $cfg
}

function Save-Config {
    param($Config)
    $dir = Get-InstanceDir $Config.InstanceId
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Config.AppVersion = $Script:AppVersion
    $json = ConvertTo-Json -InputObject $Config -Depth 6
    [IO.File]::WriteAllText((Get-ConfigPath $Config.InstanceId), $json, (New-Object Text.UTF8Encoding($false)))
}

function Get-Instances {
    if (-not (Test-Path -LiteralPath $Script:AppRoot)) { return @() }
    $result = foreach ($dir in Get-ChildItem -LiteralPath $Script:AppRoot -Directory) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName 'config.json')) {
            try { Read-Config $dir.Name } catch { }
        }
    }
    return @($result)
}

function Get-InstanceTask {
    param([string]$Id)
    return Get-ScheduledTask -TaskPath $Script:TaskPath -TaskName (Get-TaskName $Id) -ErrorAction SilentlyContinue
}

# Picks the instance this run works on.
function Resolve-Instance {
    param([string]$RequestedId, [bool]$CreateNew, [bool]$Interactive)

    if ($RequestedId) {
        if (-not (Test-InstanceIdString $RequestedId)) { throw "Invalid instance ID '$RequestedId' (allowed: A-Z, 0-9, _ and -, max. 32 characters)." }
        return $RequestedId
    }
    if ($CreateNew) { return (New-InstanceIdString) }

    # Started from an installed instance folder: use that instance.
    $self = Get-SelfInfo
    if ($self.Path) {
        $selfDir = Split-Path -Parent $self.Path
        $localConfig = Join-Path $selfDir 'config.json'
        if (Test-Path -LiteralPath $localConfig) {
            return (Split-Path -Leaf $selfDir)
        }
    }

    $instances = @(Get-Instances)
    if ($instances.Count -eq 0) { return (New-InstanceIdString) }
    if ($instances.Count -eq 1) { return $instances[0].InstanceId }
    if (-not $Interactive) {
        throw "Several instances are installed ($(@($instances | ForEach-Object InstanceId) -join ', ')). Specify one with -InstanceId."
    }
    return (Select-InstanceInteractive -AllowNew $true)
}

function Select-InstanceInteractive {
    param([bool]$AllowNew)
    $instances = @(Get-Instances)
    Write-Host ''
    Write-Host 'Installed instances:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $instances.Count; $i++) {
        $task = Get-InstanceTask $instances[$i].InstanceId
        $state = if ($task) { $task.State } else { 'no task' }
        Write-Host ('  {0}) {1}  {2}  ({3} rule(s), task: {4})' -f ($i + 1), $instances[$i].InstanceId, $instances[$i].Name, @($instances[$i].Rules).Count, $state)
    }
    if ($AllowNew) { Write-Host '  N) Create a new instance (parallel installation)' }
    while ($true) {
        $answer = (Read-Host 'Select instance').Trim()
        if ($AllowNew -and $answer -match '^[nN]$') { return (New-InstanceIdString) }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $instances.Count) {
            return $instances[$n - 1].InstanceId
        }
    }
}

# ---------------------------------------------------------------------------
# Device discovery
# ---------------------------------------------------------------------------

# Lists every volume on every disk together with all identifiers that can be
# used to recognise it again (disk serial, disk unique ID, volume GUID).
function Get-ConnectedVolumes {
    $wmiSerials = @{}
    foreach ($d in @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue)) {
        if ($null -ne $d.SerialNumber) { $wmiSerials[[int]$d.Index] = ([string]$d.SerialNumber).Trim() }
    }

    $volumes = foreach ($disk in @(Get-Disk -ErrorAction SilentlyContinue)) {
        $diskSerial = if ($disk.SerialNumber) { ([string]$disk.SerialNumber).Trim() } else { '' }
        $wmiSerial  = if ($wmiSerials.ContainsKey([int]$disk.Number)) { $wmiSerials[[int]$disk.Number] } else { '' }
        foreach ($part in @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)) {
            $guidPath = @($part.AccessPaths | Where-Object { $_ -like '\\?\Volume{*' }) | Select-Object -First 1
            if (-not $guidPath) { continue }   # MSR and other partitions without a volume
            $vol = $part | Get-Volume -ErrorAction SilentlyContinue
            $letter = if ($part.DriveLetter -and [char]$part.DriveLetter -ne [char]0) { ([string]$part.DriveLetter).ToUpperInvariant() } else { '' }
            [pscustomobject]@{
                DiskNumber      = [int]$disk.Number
                BusType         = [string]$disk.BusType
                Model           = ([string]$disk.FriendlyName).Trim()
                DiskSerial      = $diskSerial
                WmiSerial       = $wmiSerial
                DiskUniqueId    = [string]$disk.UniqueId
                PartitionNumber = [int]$part.PartitionNumber
                VolumeGuid      = ([string]$guidPath).ToLowerInvariant()
                DriveLetter     = $letter
                Label           = if ($vol) { [string]$vol.FileSystemLabel } else { '' }
                FileSystem      = if ($vol) { [string]$vol.FileSystem } else { '' }
                Size            = [double]$part.Size
                IsSystemVolume  = [bool]($part.IsBoot -or $part.IsSystem -or ($letter -and "$($letter):" -eq $env:SystemDrive))
            }
        }
    }
    return @($volumes | Sort-Object @{ Expression = { $_.BusType -ne 'USB' } }, DiskNumber, PartitionNumber)
}

# The best "always there" identifier of a disk: its serial number, or the
# disk UniqueId for cheap sticks that do not report a serial number.
function Get-PreferredDiskId {
    param($Volume)
    if ($Volume.DiskSerial) { return [pscustomobject]@{ Type = 'DiskSerial';   Value = $Volume.DiskSerial } }
    if ($Volume.WmiSerial)  { return [pscustomobject]@{ Type = 'DiskSerial';   Value = $Volume.WmiSerial } }
    if ($Volume.DiskUniqueId) { return [pscustomobject]@{ Type = 'DiskUniqueId'; Value = $Volume.DiskUniqueId } }
    return [pscustomobject]@{ Type = 'VolumeGuid'; Value = $Volume.VolumeGuid }
}

function Show-VolumeTable {
    param([object[]]$Volumes)
    $i = 0
    $rows = foreach ($v in $Volumes) {
        $i++
        $id = (Get-PreferredDiskId $v).Value
        if ($id.Length -gt 28) { $id = $id.Substring(0, 25) + '...' }
        [pscustomobject]@{
            '#'       = $i
            Letter    = if ($v.DriveLetter) { "$($v.DriveLetter):" } else { '-' }
            Bus       = $v.BusType
            Disk      = $v.DiskNumber
            Part      = $v.PartitionNumber
            Model     = if ($v.Model.Length -gt 26) { $v.Model.Substring(0, 26) } else { $v.Model }
            'Serial / ID' = $id
            Label     = $v.Label
            FS        = $v.FileSystem
            Size      = Format-Size $v.Size
            Note      = if ($v.IsSystemVolume) { 'system (locked)' } else { '' }
        }
    }
    if (-not $rows) { Write-Host '  No volumes found.' -ForegroundColor Yellow; return }
    # Explicit columns: Format-Table shows only the first 10 properties otherwise.
    $rows | Format-Table -Property '#', Letter, Bus, Disk, Part, Model, 'Serial / ID', Label, FS, Size, Note -AutoSize |
        Out-String -Width 200 | Write-Host
}

# ---------------------------------------------------------------------------
# Drive letter handling
# ---------------------------------------------------------------------------
function Get-UsedLetters {
    $used = @()
    $used += @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue | ForEach-Object { ([string]$_.DeviceID).Substring(0, 1) })
    $used += @(Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object { ([string]$_.DriveLetter).Substring(0, 1) })
    $used += @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1) })
    return @($used | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object -Unique)
}

function Get-FreeLetter {
    param([string[]]$Exclude = @())
    $used = Get-UsedLetters
    foreach ($c in [char[]](68..90)) {   # D..Z
        $s = [string]$c
        if ($used -notcontains $s -and $Exclude -notcontains $s) { return $s }
    }
    return $null
}

function Get-WmiVolume {
    param([string]$VolumeGuid)
    $filter = "DeviceID='{0}'" -f $VolumeGuid.Replace('\', '\\')
    return Get-CimInstance -ClassName Win32_Volume -Filter $filter -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-LetterOwner {
    param([string]$DriveLetter)
    $vol = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$($DriveLetter):'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vol) { return [pscustomobject]@{ Kind = 'Volume'; Volume = $vol; Description = "$($vol.Label) $($vol.DeviceID)".Trim() } }
    if ((Get-UsedLetters) -contains $DriveLetter) {
        return [pscustomobject]@{ Kind = 'Other'; Volume = $null; Description = 'network, subst or card-reader drive' }
    }
    return $null
}

function Set-VolumeLetter {
    param([string]$VolumeGuid, [string]$DriveLetter)
    $target = "$($DriveLetter):"
    $wmiVol = Get-WmiVolume $VolumeGuid
    if ($wmiVol) {
        try {
            Set-CimInstance -InputObject $wmiVol -Property @{ DriveLetter = $target } -ErrorAction Stop
            return
        } catch {
            Write-Log "Win32_Volume could not set ${target}: $($_.Exception.Message) - trying Storage API." 'WARN'
        }
    }
    $part = Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { @($_.AccessPaths | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() }) -contains $VolumeGuid } |
        Select-Object -First 1
    if (-not $part) { throw "Partition for $VolumeGuid not found." }
    if ($part.DriveLetter -and [char]$part.DriveLetter -ne [char]0) {
        $part | Set-Partition -NewDriveLetter $DriveLetter
    } else {
        $part | Add-PartitionAccessPath -AccessPath "$target\"
    }
}

function Find-RuleTarget {
    param($Rule, [object[]]$Volumes)
    $value = [string]$Rule.MatchValue
    switch ($Rule.MatchType) {
        'VolumeGuid'   { $guid = ConvertTo-VolumeGuidPath $value; $c = @($Volumes | Where-Object { $_.VolumeGuid -eq $guid }) }
        'DiskUniqueId' { $c = @($Volumes | Where-Object { $_.DiskUniqueId -eq $value }) }
        default        { $c = @($Volumes | Where-Object { ($_.DiskSerial -and $_.DiskSerial -eq $value) -or ($_.WmiSerial -and $_.WmiSerial -eq $value) }) }
    }
    if ([int]$Rule.PartitionNumber -gt 0) { $c = @($c | Where-Object { $_.PartitionNumber -eq [int]$Rule.PartitionNumber }) }
    # Without a partition number the largest data volume of the disk is used.
    return ($c | Where-Object { -not $_.IsSystemVolume } | Sort-Object Size -Descending | Select-Object -First 1)
}

function Set-RuleState {
    param($Rule, [string]$State, [string]$Message, [string]$Level = 'INFO')
    if ($Script:RuleState[$Rule.Id] -ne $State) {
        $Script:RuleState[$Rule.Id] = $State
        Write-Log $Message $Level
    }
}

function Invoke-ApplyRules {
    param($Config)
    $rules = @($Config.Rules | Where-Object { $_.Enabled })
    if ($rules.Count -eq 0) { return }
    $reserved = @($rules | ForEach-Object { ([string]$_.DriveLetter).ToUpperInvariant() })
    $volumes = @(Get-ConnectedVolumes)

    foreach ($rule in $rules) {
        $want = ([string]$rule.DriveLetter).ToUpperInvariant()
        $label = "'$($rule.Name)' [$($rule.MatchType)=$($rule.MatchValue)]"
        $target = Find-RuleTarget -Rule $rule -Volumes $volumes
        if (-not $target) {
            Set-RuleState $rule 'absent' "$label is not connected."
            continue
        }
        if ($target.DriveLetter -eq $want) {
            Set-RuleState $rule 'ok' "$label has ${want}:" 'OK'
            continue
        }

        $owner = Get-LetterOwner $want
        if ($owner) {
            $canMove = $rule.Force -and $owner.Kind -eq 'Volume' -and -not $owner.Volume.BootVolume -and
                       -not $owner.Volume.SystemVolume -and -not $owner.Volume.PageFilePresent -and
                       "${want}:" -ne $env:SystemDrive
            if (-not $canMove) {
                Set-RuleState $rule "blocked:$want" "$label cannot get ${want}: - letter is used by $($owner.Description). Enable 'Force' on the rule to move the other volume away." 'WARN'
                continue
            }
            $spare = Get-FreeLetter -Exclude $reserved
            if (-not $spare) {
                Set-RuleState $rule 'noletter' "$label cannot get ${want}: - no free letter to move $($owner.Description) to." 'WARN'
                continue
            }
            try {
                Set-CimInstance -InputObject $owner.Volume -Property @{ DriveLetter = "$($spare):" } -ErrorAction Stop
                Write-Log "Moved $($owner.Description) from ${want}: to ${spare}: to free the letter." 'WARN'
            } catch {
                Set-RuleState $rule "blocked:$want" "$label could not move $($owner.Description) away from ${want}: - $($_.Exception.Message)" 'ERROR'
                continue
            }
        }

        try {
            $from = if ($target.DriveLetter) { "$($target.DriveLetter):" } else { 'no letter' }
            Set-VolumeLetter -VolumeGuid $target.VolumeGuid -DriveLetter $want
            $Script:RuleState[$rule.Id] = 'ok'
            Write-Log "$label changed from $from to ${want}:" 'OK'
            $volumes = @(Get-ConnectedVolumes)
        } catch {
            Set-RuleState $rule "error:$($_.Exception.Message)" "$label could not be set to ${want}: - $($_.Exception.Message)" 'ERROR'
        }
    }
}

# ---------------------------------------------------------------------------
# Background monitor (runs from the scheduled task)
# ---------------------------------------------------------------------------
function Start-Monitor {
    param([string]$Id)
    $mutex = New-Object Threading.Mutex($false, "Global\$($Script:AppName)_$Id")
    if (-not $mutex.WaitOne(0)) {
        Write-Log "Monitor for instance $Id is already running." 'WARN'
        return
    }
    try {
        $configPath = Get-ConfigPath $Id
        $config = Read-Config $Id
        $configTime = if (Test-Path -LiteralPath $configPath) { (Get-Item -LiteralPath $configPath).LastWriteTimeUtc } else { [datetime]::MinValue }
        Write-Log "Monitor started (version $($Script:AppVersion), instance $Id, $(@($config.Rules).Count) rule(s))."

        $source = "$($Script:AppName)_VolumeChange_$Id"
        $hasEvents = $false
        try {
            Register-CimIndicationEvent -ClassName Win32_VolumeChangeEvent -SourceIdentifier $source -ErrorAction Stop | Out-Null
            $hasEvents = $true
        } catch {
            Write-Log "Volume events unavailable, using polling only: $($_.Exception.Message)" 'WARN'
        }

        while ($true) {
            try {
                if (Test-Path -LiteralPath $configPath) {
                    $t = (Get-Item -LiteralPath $configPath).LastWriteTimeUtc
                    if ($t -ne $configTime) {
                        $configTime = $t
                        $config = Read-Config $Id
                        $Script:RuleState = @{}
                        Write-Log "Configuration reloaded ($(@($config.Rules).Count) rule(s))."
                    }
                }
                Invoke-ApplyRules $config
            } catch {
                Write-Log "Apply failed: $($_.Exception.Message)" 'ERROR'
            }

            $poll = [Math]::Max(5, [int]$config.PollSeconds)
            if ($hasEvents) {
                $evt = Wait-Event -SourceIdentifier $source -Timeout $poll
                if ($evt) {
                    Start-Sleep -Seconds 2   # let Windows finish mounting
                    Get-Event -SourceIdentifier $source -ErrorAction SilentlyContinue | Remove-Event
                }
            } else {
                Start-Sleep -Seconds $poll
            }
        }
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Install / uninstall
# ---------------------------------------------------------------------------
function Install-Instance {
    param($Config)
    $id = $Config.InstanceId
    $dir = Get-InstanceDir $id
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Save-Config $Config

    $taskName = Get-TaskName $id
    $existing = Get-InstanceTask $id
    if ($existing) {
        Stop-ScheduledTask -TaskPath $Script:TaskPath -TaskName $taskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # Copy the program into the instance folder so the task does not depend on
    # the download location (or on a drive that might itself get a new letter).
    $self = Get-SelfInfo
    if (-not $self.Path) { throw 'Cannot determine the program path.' }
    $ext = if ($self.IsExe) { '.exe' } else { '.ps1' }
    $installed = Join-Path $dir "$($Script:AppName)$ext"
    if ([IO.Path]::GetFullPath($self.Path) -ne [IO.Path]::GetFullPath($installed)) {
        Copy-Item -LiteralPath $self.Path -Destination $installed -Force
    }

    $run = Get-LaunchCommand -ProgramPath $installed -Arguments "-Monitor -InstanceId $id" -IsExe $self.IsExe
    $action = New-ScheduledTaskAction -Execute $run.File -Argument $run.Args -WorkingDirectory $dir
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $system = ([Security.Principal.SecurityIdentifier]'S-1-5-18').Translate([Security.Principal.NTAccount]).Value
    $principal = New-ScheduledTaskPrincipal -UserId $system -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $Script:TaskPath -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force `
        -Description "$($Script:AppName) $($Script:AppVersion) - instance $id ($($Config.Name)). Keeps drive letters of selected drives fixed." | Out-Null

    # Entry in "Apps & features" so the instance can be removed like any program.
    $menu = Get-LaunchCommand -ProgramPath $installed -Arguments "-InstanceId $id" -IsExe $self.IsExe
    $remove = Get-LaunchCommand -ProgramPath $installed -Arguments "-Uninstall -InstanceId $id" -IsExe $self.IsExe
    $key = Join-Path $Script:UninstallKey $taskName
    New-Item -Path $key -Force | Out-Null
    $values = @{
        DisplayName     = "$($Script:AppName) ($($Config.Name), $id)"
        DisplayVersion  = $Script:AppVersion
        Publisher       = $Script:AppName
        InstallLocation = $dir
        DisplayIcon     = $installed
        UninstallString = ('"{0}" {1}' -f $remove.File, $remove.Args)
        ModifyPath      = ('"{0}" {1}' -f $menu.File, $menu.Args.Replace('-WindowStyle Hidden ', ''))
        InstallDate     = (Get-Date -Format 'yyyyMMdd')
    }
    foreach ($k in $values.Keys) { New-ItemProperty -Path $key -Name $k -Value $values[$k] -PropertyType String -Force | Out-Null }
    New-ItemProperty -Path $key -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null

    Start-ScheduledTask -TaskPath $Script:TaskPath -TaskName $taskName
    Write-Log "Instance $id installed to $dir - task '$($Script:TaskPath)$taskName' runs at every boot and was started now." 'OK'
}

function Uninstall-Instance {
    param([string]$Id, [bool]$DeleteFiles)
    $taskName = Get-TaskName $Id
    if (Get-InstanceTask $Id) {
        Stop-ScheduledTask -TaskPath $Script:TaskPath -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskPath $Script:TaskPath -TaskName $taskName -Confirm:$false
        Write-Log "Scheduled task $taskName removed." 'OK'
    }
    $key = Join-Path $Script:UninstallKey $taskName
    if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force }

    $dir = Get-InstanceDir $Id
    if ($DeleteFiles -and (Test-Path -LiteralPath $dir)) {
        $Script:LogFile = $null
        $self = Get-SelfInfo
        $runningFromDir = $self.Path -and ([IO.Path]::GetFullPath($self.Path)).StartsWith([IO.Path]::GetFullPath($dir), [StringComparison]::OrdinalIgnoreCase)
        if ($runningFromDir) {
            # We cannot delete our own executable while it runs: let cmd do it after we exit.
            Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -WindowStyle Hidden `
                -ArgumentList "/c ping 127.0.0.1 -n 4 >nul & rmdir /s /q `"$dir`""
        } else {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
        Write-Log "Instance folder $dir removed." 'OK'
    }
    Write-Log "Instance $Id uninstalled." 'OK'
}

# Removes the old WMI permanent event subscription (TestFilter/TestConsumer)
# created by the previous script version.
function Remove-LegacyWmiSubscription {
    $ns = 'root/subscription'
    $consumers = @(Get-CimInstance -Namespace $ns -ClassName CommandLineEventConsumer -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLineTemplate -match 'AutoAssignDriveLetter' })
    if ($consumers.Count -eq 0) { Write-Log 'No old WMI subscription found.'; return }
    foreach ($consumer in $consumers) {
        $bindings = @(Get-CimInstance -Namespace $ns -ClassName __FilterToConsumerBinding -ErrorAction SilentlyContinue |
            Where-Object { $_.Consumer.Name -eq $consumer.Name })
        foreach ($binding in $bindings) {
            $filterName = $binding.Filter.Name
            $binding | Remove-CimInstance
            Get-CimInstance -Namespace $ns -ClassName __EventFilter -Filter "Name='$filterName'" -ErrorAction SilentlyContinue | Remove-CimInstance
            Write-Log "Removed old WMI filter '$filterName'." 'OK'
        }
        $consumer | Remove-CimInstance
        Write-Log "Removed old WMI consumer '$($consumer.Name)'." 'OK'
    }
}

# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------
function New-Rule {
    param([string]$MatchType, [string]$MatchValue, [int]$PartitionNumber, [string]$DriveLetter, [string]$RuleName, [bool]$ForceLetter)
    return [pscustomobject]@{
        Id              = [guid]::NewGuid().ToString('N').Substring(0, 6).ToUpperInvariant()
        Name            = if ($RuleName) { $RuleName } else { $MatchValue }
        MatchType       = $MatchType
        MatchValue      = $MatchValue
        PartitionNumber = $PartitionNumber
        DriveLetter     = $DriveLetter
        Force           = $ForceLetter
        Enabled         = $true
    }
}

function Add-ConfigRule {
    param($Config, $Rule)
    # One letter per device and one device per letter, otherwise rules would fight.
    $Config.Rules = @(@($Config.Rules | Where-Object {
        $_.DriveLetter -ne $Rule.DriveLetter -and
        -not ($_.MatchType -eq $Rule.MatchType -and $_.MatchValue -eq $Rule.MatchValue -and [int]$_.PartitionNumber -eq [int]$Rule.PartitionNumber)
    }) + $Rule)
    Save-Config $Config
    Write-Log "Rule $($Rule.Id) saved: '$($Rule.Name)' [$($Rule.MatchType)=$($Rule.MatchValue)$(if ($Rule.PartitionNumber) { ", partition $($Rule.PartitionNumber)" })] -> $($Rule.DriveLetter):" 'OK'
}

function Show-Rules {
    param($Config)
    $rules = @($Config.Rules)
    if ($rules.Count -eq 0) { Write-Host '  No rules configured yet.' -ForegroundColor Yellow; return }
    $volumes = @(Get-ConnectedVolumes)
    $rows = foreach ($r in $rules) {
        $t = Find-RuleTarget -Rule $r -Volumes $volumes
        [pscustomobject]@{
            Id        = $r.Id
            Name      = $r.Name
            Letter    = "$($r.DriveLetter):"
            Match     = $r.MatchType
            Value     = $r.MatchValue
            Part      = if ($r.PartitionNumber) { $r.PartitionNumber } else { 'auto' }
            Force     = $r.Force
            Enabled   = $r.Enabled
            Connected = if ($t) { if ($t.DriveLetter) { "yes, now $($t.DriveLetter):" } else { 'yes, no letter' } } else { 'no' }
        }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

function Read-DriveLetterInteractive {
    param($Config, [string]$Suggested)
    $used = Get-UsedLetters
    $free = @([char[]](68..90) | ForEach-Object { [string]$_ } | Where-Object { $used -notcontains $_ })
    Write-Host ("Free letters right now: {0}" -f ($free -join ' ')) -ForegroundColor DarkGray
    while ($true) {
        $raw = Read-Host "Drive letter to assign [$Suggested]"
        if (-not $raw.Trim()) { $raw = $Suggested }
        $l = ConvertTo-DriveLetter $raw
        if (-not $l) { Write-Host 'Please type a single letter, e.g. E' -ForegroundColor Yellow; continue }
        if ("${l}:" -eq $env:SystemDrive -or $l -in @('A', 'B')) { Write-Host "$l is not allowed." -ForegroundColor Yellow; continue }
        $other = @($Config.Rules | Where-Object { $_.DriveLetter -eq $l })
        if ($other.Count -gt 0 -and -not (Read-YesNo "Rule '$($other[0].Name)' already uses ${l}: - replace it?" $false)) { continue }
        return $l
    }
}

function Add-RuleInteractive {
    param($Config)
    $volumes = @(Get-ConnectedVolumes)
    Write-Host ''
    Write-Host 'Connected drives (USB first):' -ForegroundColor Cyan
    Show-VolumeTable $volumes
    Write-Host 'Type the # of a drive above, or type a serial number / volume GUID yourself'
    Write-Host '(useful for a drive that is not plugged in right now). Empty = cancel.'
    $selection = (Read-Host 'Selection').Trim()
    if (-not $selection) { return }

    $n = 0
    $partitionNumber = 0
    $suggestedLetter = $null
    $defaultName = $null
    $currentLetter = $null
    if ([int]::TryParse($selection, [ref]$n) -and $n -ge 1 -and $n -le $volumes.Count) {
        $vol = $volumes[$n - 1]
        if ($vol.IsSystemVolume) { Write-Host 'The Windows system volume cannot be managed.' -ForegroundColor Red; return }
        $preferred = Get-PreferredDiskId $vol
        Write-Host ''
        Write-Host 'Identify the drive by:'
        Write-Host "  1) $($preferred.Type) '$($preferred.Value)'  - hardware ID, works on every PC (recommended)"
        Write-Host "  2) Volume GUID '$($vol.VolumeGuid)'  - this PC only, changes if the drive is reformatted"
        $how = (Read-Host 'Choice [1]').Trim()
        if ($how -eq '2') {
            $matchType = 'VolumeGuid'; $matchValue = $vol.VolumeGuid
        } else {
            $matchType = $preferred.Type; $matchValue = $preferred.Value
            $siblings = @($volumes | Where-Object { $_.DiskNumber -eq $vol.DiskNumber -and -not $_.IsSystemVolume })
            if ($siblings.Count -gt 1 -or $matchType -eq 'VolumeGuid') { $partitionNumber = $vol.PartitionNumber }
        }
        $defaultName = if ($vol.Label) { "$($vol.Model) ($($vol.Label))" } else { $vol.Model }
        $currentLetter = $vol.DriveLetter
        $suggestedLetter = $vol.DriveLetter
    } elseif (ConvertTo-VolumeGuidPath $selection) {
        $matchType = 'VolumeGuid'; $matchValue = ConvertTo-VolumeGuidPath $selection
    } else {
        $matchType = 'DiskSerial'; $matchValue = $selection
        $known = @($volumes | Where-Object { $_.DiskSerial -eq $selection -or $_.WmiSerial -eq $selection })
        if ($known.Count -eq 0) {
            $known = @($volumes | Where-Object { $_.DiskUniqueId -eq $selection })
            if ($known.Count -gt 0) { $matchType = 'DiskUniqueId' }
        }
        if ($known.Count -gt 0) {
            Write-Host "Found: $($known[0].Model) (disk $($known[0].DiskNumber))" -ForegroundColor Green
            $defaultName = $known[0].Model
        } else {
            Write-Host 'This drive is not connected right now - the rule will apply once it is plugged in.' -ForegroundColor Yellow
        }
        $p = (Read-Host 'Partition number (Enter = automatic, largest volume of the disk)').Trim()
        $pn = 0
        if ($p -and [int]::TryParse($p, [ref]$pn)) { $partitionNumber = $pn }
    }

    if (-not $suggestedLetter) { $suggestedLetter = Get-FreeLetter -Exclude @($Config.Rules | ForEach-Object { $_.DriveLetter }) }
    $driveLetter = Read-DriveLetterInteractive -Config $Config -Suggested $suggestedLetter

    $owner = Get-LetterOwner $driveLetter
    if ($owner -and $driveLetter -ne $currentLetter) {
        Write-Host "${driveLetter}: is currently used by $($owner.Description)." -ForegroundColor Yellow
    }
    $forceLetter = Read-YesNo "If ${driveLetter}: is taken by another drive, move that drive to a free letter? (Force)" $false

    if (-not $defaultName) { $defaultName = $matchValue }
    $ruleName = (Read-Host "Name for this rule [$defaultName]").Trim()
    if (-not $ruleName) { $ruleName = $defaultName }

    $rule = New-Rule -MatchType $matchType -MatchValue $matchValue -PartitionNumber $partitionNumber -DriveLetter $driveLetter -RuleName $ruleName -ForceLetter $forceLetter
    Add-ConfigRule $Config $rule
    if (Read-YesNo 'Apply now?' $true) { $Script:RuleState = @{}; Invoke-ApplyRules $Config }
}

function Remove-RuleInteractive {
    param($Config)
    Show-Rules $Config
    if (@($Config.Rules).Count -eq 0) { return }
    $id = (Read-Host 'Id of the rule to remove (Empty = cancel)').Trim()
    if (-not $id) { return }
    Remove-ConfigRule $Config $id
}

function Remove-ConfigRule {
    param($Config, [string]$Id)
    $before = @($Config.Rules).Count
    $Config.Rules = @($Config.Rules | Where-Object { $_.Id -ne $Id })
    if (@($Config.Rules).Count -eq $before) { Write-Log "No rule with Id '$Id'." 'WARN'; return }
    Save-Config $Config
    Write-Log "Rule $Id removed." 'OK'
}

function Switch-RuleInteractive {
    param($Config)
    Show-Rules $Config
    if (@($Config.Rules).Count -eq 0) { return }
    $id = (Read-Host 'Id of the rule to enable/disable (Empty = cancel)').Trim()
    $rule = @($Config.Rules | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
    if (-not $rule) { return }
    $rule.Enabled = -not $rule.Enabled
    Save-Config $Config
    Write-Log "Rule $id is now $(if ($rule.Enabled) { 'enabled' } else { 'disabled' })." 'OK'
}

function Show-Status {
    param($Config)
    $id = $Config.InstanceId
    $task = Get-InstanceTask $id
    Write-Host ''
    Write-Host "$($Script:AppName) $($Script:AppVersion)" -ForegroundColor Cyan
    Write-Host "  Instance : $id ($($Config.Name))"
    Write-Host "  Folder   : $(Get-InstanceDir $id)"
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo
        Write-Host "  Task     : $($Script:TaskPath)$(Get-TaskName $id) - $($task.State), last run $($info.LastRunTime)"
    } else {
        Write-Host '  Task     : not installed (rules are only applied manually)' -ForegroundColor Yellow
    }
    Write-Host '  Rules    :'
    Show-Rules $Config
}

function Show-Help {
    @"
$($Script:AppName) $($Script:AppVersion)

Without parameters the interactive menu opens.

  -InstanceId <id>        Work on this instance (default: the only one / the one in the exe folder)
  -NewInstance            Create a new, additional instance (parallel installation)
  -List                   List connected drives with serial numbers and volume GUIDs
  -ListInstances          List installed instances
  -AddSerial <serial>     Add rule for the disk with this serial number (or disk UniqueId)
  -AddVolume <guid>       Add rule for this volume GUID
     -Letter <X>          ...drive letter to assign (required with -AddSerial/-AddVolume)
     -Partition <n>       ...partition number on the disk (default: largest volume)
     -Name <text>         ...description of the rule
     -Force               ...move another drive away if it occupies the letter
  -RemoveRule <id>        Remove a rule
  -Apply                  Apply all rules once
  -Install                Install / update: copy to ProgramData and run at every boot
  -Uninstall [-KeepConfig] Remove the boot task (and the instance folder)
  -RemoveLegacy           Remove the old WMI subscription (TestFilter/TestConsumer)
  -Status                 Show instance, task and rule status
  -Monitor                Run the background monitor (used by the scheduled task)
  -Version                Print the version

Examples:
  $($Script:AppName).exe -AddSerial NAASPZ2N -Letter E -Name "Seagate Expansion" -Install
  $($Script:AppName).exe -NewInstance -AddSerial 4C530001 -Letter S -Install
"@ | Write-Host
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
function Show-Menu {
    param([string]$Id)
    $config = Read-Config $Id
    while ($true) {
        $task = Get-InstanceTask $config.InstanceId
        $taskState = if ($task) { "installed, $($task.State)" } else { 'not installed' }
        Write-Host ''
        Write-Host ('=' * 64) -ForegroundColor DarkCyan
        Write-Host " $($Script:AppName) $($Script:AppVersion)" -ForegroundColor Cyan
        Write-Host " Instance $($config.InstanceId) - $($config.Name)  |  boot task: $taskState"
        Write-Host ('=' * 64) -ForegroundColor DarkCyan
        Write-Host '  1) Add drive (select from connected drives or type serial)'
        Write-Host '  2) Show rules'
        Write-Host '  3) Remove rule'
        Write-Host '  4) Enable / disable rule'
        Write-Host '  5) Show connected drives'
        Write-Host '  6) Apply rules now'
        Write-Host '  7) Install / update autostart (runs at every boot)'
        Write-Host '  8) Uninstall this instance'
        Write-Host '  9) Rename instance / change check interval'
        Write-Host '  I) Switch instance or create a new one (parallel installation)'
        Write-Host '  L) Remove old WMI script version (TestFilter/TestConsumer)'
        Write-Host '  0) Exit'
        $choice = (Read-Host 'Choice').Trim().ToUpperInvariant()
        try {
            switch ($choice) {
                '1' { Add-RuleInteractive $config }
                '2' { Show-Rules $config }
                '3' { Remove-RuleInteractive $config }
                '4' { Switch-RuleInteractive $config }
                '5' { Show-VolumeTable @(Get-ConnectedVolumes) }
                '6' { $Script:RuleState = @{}; Invoke-ApplyRules $config }
                '7' {
                    if (@($config.Rules).Count -eq 0 -and -not (Read-YesNo 'No rules configured yet. Install anyway?' $false)) { break }
                    Install-Instance $config
                }
                '8' {
                    if (Read-YesNo "Really uninstall instance $($config.InstanceId)?" $false) {
                        $delete = Read-YesNo 'Also delete its configuration and log?' $true
                        Uninstall-Instance -Id $config.InstanceId -DeleteFiles $delete
                        return
                    }
                }
                '9' {
                    $newName = (Read-Host "Instance name [$($config.Name)]").Trim()
                    if ($newName) { $config.Name = $newName }
                    $poll = (Read-Host "Re-check interval in seconds, in addition to plug-in events [$($config.PollSeconds)]").Trim()
                    $pv = 0
                    if ($poll -and [int]::TryParse($poll, [ref]$pv) -and $pv -ge 5) { $config.PollSeconds = $pv }
                    Save-Config $config
                    if ($task) { Write-Host 'Run 7) to update the task name in Apps & features.' -ForegroundColor DarkGray }
                }
                'I' {
                    $newId = Select-InstanceInteractive -AllowNew $true
                    $config = Read-Config $newId
                    $Script:LogFile = Join-Path (Get-InstanceDir $newId) 'log.txt'
                    $Script:RuleState = @{}
                }
                'L' { Remove-LegacyWmiSubscription }
                '0' { return }
                default { }
            }
        } catch {
            Write-Log $_.Exception.Message 'ERROR'
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ($Help) { Show-Help; exit 0 }
if ($Version) { Write-Output $Script:AppVersion; exit 0 }

if (-not (Test-IsAdmin)) {
    # Relaunch elevated with the same parameters.
    $self = Get-SelfInfo
    $launch = Get-LaunchCommand -ProgramPath $self.Path -Arguments (ConvertTo-ArgumentString $PSBoundParameters) -IsExe $self.IsExe
    $launchArgs = $launch.Args.Replace('-WindowStyle Hidden ', '')
    try {
        if ($launchArgs) { Start-Process -FilePath $launch.File -ArgumentList $launchArgs -Verb RunAs }
        else { Start-Process -FilePath $launch.File -Verb RunAs }
        exit 0
    } catch {
        Write-Host 'Administrator rights are required.' -ForegroundColor Red
        exit 1
    }
}

$hasAction = $Install -or $Uninstall -or $Apply -or $Monitor -or $List -or $ListInstances -or $Status -or
             $AddSerial -or $AddVolume -or $RemoveRule -or $RemoveLegacy

try {
    if ($ListInstances) {
        $all = @(Get-Instances)
        if ($all.Count -eq 0) { Write-Host 'No instances installed.' }
        foreach ($inst in $all) {
            $task = Get-InstanceTask $inst.InstanceId
            Write-Host ('{0}  {1}  rules: {2}  task: {3}' -f $inst.InstanceId, $inst.Name, @($inst.Rules).Count, $(if ($task) { $task.State } else { 'none' }))
        }
        exit 0
    }
    if ($List) { Show-VolumeTable @(Get-ConnectedVolumes); exit 0 }
    if ($RemoveLegacy -and -not ($Install -or $Uninstall -or $Apply -or $AddSerial -or $AddVolume -or $RemoveRule -or $Status)) {
        Remove-LegacyWmiSubscription; exit 0
    }

    $id = Resolve-Instance -RequestedId $InstanceId -CreateNew $NewInstance.IsPresent -Interactive (-not $hasAction -or $Install)
    $Script:LogFile = Join-Path (Get-InstanceDir $id) 'log.txt'
    if (-not (Test-Path -LiteralPath (Get-InstanceDir $id))) {
        if ($Uninstall -or $Monitor) { throw "Instance '$id' does not exist." }
        New-Item -ItemType Directory -Path (Get-InstanceDir $id) -Force | Out-Null
    }

    if ($Monitor) { Start-Monitor $id; exit 0 }
    if ($Uninstall) { Uninstall-Instance -Id $id -DeleteFiles (-not $KeepConfig); exit 0 }

    $config = Read-Config $id
    if (-not (Test-Path -LiteralPath (Get-ConfigPath $id))) { Save-Config $config }

    if ($AddSerial -or $AddVolume) {
        $l = ConvertTo-DriveLetter $Letter
        if (-not $l) { throw '-Letter <X> is required with -AddSerial / -AddVolume.' }
        if ("${l}:" -eq $env:SystemDrive) { throw "$l is the system drive." }
        if ($AddVolume) {
            $guid = ConvertTo-VolumeGuidPath $AddVolume
            if (-not $guid) { throw "'$AddVolume' is not a volume GUID." }
            $rule = New-Rule -MatchType 'VolumeGuid' -MatchValue $guid -PartitionNumber $Partition -DriveLetter $l -RuleName $Name -ForceLetter $Force.IsPresent
        } else {
            $type = 'DiskSerial'
            $known = @(Get-ConnectedVolumes | Where-Object { $_.DiskUniqueId -eq $AddSerial.Trim() })
            if ($known.Count -gt 0) { $type = 'DiskUniqueId' }
            $rule = New-Rule -MatchType $type -MatchValue $AddSerial.Trim() -PartitionNumber $Partition -DriveLetter $l -RuleName $Name -ForceLetter $Force.IsPresent
        }
        Add-ConfigRule $config $rule
    }
    if ($RemoveRule) { Remove-ConfigRule $config $RemoveRule }
    if ($RemoveLegacy) { Remove-LegacyWmiSubscription }
    if ($Install) { Install-Instance $config }
    if ($Apply) { Invoke-ApplyRules $config }
    if ($Status) { Show-Status $config }

    if (-not $hasAction) { Show-Menu $id }
    exit 0
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    if (-not $hasAction) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
