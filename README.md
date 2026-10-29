# AutoAssignDriveLetters

Gives a USB stick, external drive or internal data drive the same drive letter every
time it is connected. Windows decides drive letters on its own; this tool sets them back.

It is a general version of the old `AutoAssignDriveLetterSeagateExpansionE.ps1`, which only
handled one disk (serial `NAASPZ2N` → `E:`). The originals are in [`legacy/`](legacy).

## What it does

- **Choose drives from a list or type the ID yourself.** The menu shows every connected
  drive with its letter, bus (USB, SATA, NVMe…), model, serial number, label and size. Type the
  `#` of a drive, or type a serial number or volume GUID directly, the same way you would
  answer a PowerShell `Read-Host` prompt. Typing works for drives that are not plugged in.
- **Uses the ID that does not change.** By default a drive is recognised by its **disk
  hardware serial number** (the same value the old script used), so the rule works on any PC
  and after reformatting. Cheap sticks without a serial number use the disk `UniqueId`. You can
  also choose the **volume GUID**, which only works on the current PC.
- **Several drives per installation.** Each drive gets its own rule (device → letter). For
  disks with more than one partition you can pick the partition.
- **Starts at boot.** It installs a Scheduled Task (`\AutoAssignDriveLetters\…`) that runs as
  SYSTEM at startup. The task watches for drives being plugged in (`Win32_VolumeChangeEvent`)
  and also checks again every 30 seconds by default. If it stops, Task Scheduler restarts it.
- **Unique instance ID for parallel installations.** Each installation is an *instance* with
  its own 8-character ID. Each instance has its own folder
  (`%ProgramData%\AutoAssignDriveLetters\<ID>\`), config, log, scheduled task and entry in
  *Apps & features*, so several can be installed side by side without interfering.
- **Version number** is stored in the exe's file properties, shown in *Apps & features*, in the
  menu header and by `-Version`.
- **Force option**: if another device already holds the letter, the rule can move that device
  to a free letter. The Windows/system/page-file volume is never touched.
- **Asks for administrator rights itself**, so `RunPS1AsAdmin.bat` is no longer needed.
- **Removes the old setup**: menu item `L` / `-RemoveLegacy` deletes the old WMI subscription
  (`TestFilter` / `TestConsumer`) created by `WMIConsumerSEE.ps1`.

## Quick start

1. Download `AutoAssignDriveLetters.exe` from the latest
   [GitHub Actions build](../../actions) (artifact) or from *Releases* (for tagged versions),
   or build it yourself (see below).
2. Double-click it and allow the administrator prompt.
3. `1` → pick your drive from the list, or type its serial → enter the letter (e.g. `E`).
4. `7` → install autostart. You can then delete the downloaded exe, because a copy now lives in
   `%ProgramData%\AutoAssignDriveLetters\<ID>\`.

To change settings later, run the exe again (the downloaded one or the installed copy), or
use *Apps & features → AutoAssignDriveLetters → Modify*.

### Menu

```
 1) Add drive (select from connected drives or type serial)
 2) Show rules
 3) Remove rule
 4) Enable / disable rule
 5) Show connected drives
 6) Apply rules now
 7) Install / update autostart (runs at every boot)
 8) Uninstall this instance
 9) Rename instance / change check interval
 I) Switch instance or create a new one (parallel installation)
 L) Remove old WMI script version (TestFilter/TestConsumer)
 0) Exit
```

## Command line

For scripts and silent installs:

```bash
AutoAssignDriveLetters.exe -AddSerial NAASPZ2N -Letter E -Name "Seagate Expansion" -Install -RemoveLegacy
```

A second, independent installation alongside the first:

```bash
AutoAssignDriveLetters.exe -NewInstance -AddSerial 4C530001230101115084 -Letter S -Force -Install
```

| Parameter | Meaning |
|---|---|
| `-InstanceId <id>` | Use this instance (default: the only one, or the one whose folder the exe is in) |
| `-NewInstance` | Create a new, additional instance |
| `-List` | List connected drives with serials and volume GUIDs |
| `-ListInstances` | List installed instances |
| `-AddSerial <serial>` / `-AddVolume <guid>` | Add a rule; requires `-Letter X`. Optional: `-Partition n`, `-Name`, `-Force` |
| `-RemoveRule <id>` | Remove a rule |
| `-Apply` | Apply all rules once |
| `-Install` | Install or update the instance and its boot task |
| `-Uninstall [-KeepConfig]` | Remove the task, the Apps & features entry and, unless `-KeepConfig` is given, the instance folder |
| `-RemoveLegacy` | Remove the old WMI subscription |
| `-Status` | Show instance, task and rule status |
| `-Monitor` | Background loop (used by the scheduled task) |
| `-Version`, `-Help` | Show the version or the help |

## Files

```
%ProgramData%\AutoAssignDriveLetters\<ID>\
    AutoAssignDriveLetters.exe   installed copy that the task runs
    config.json                  rules (editable; the running task reloads it automatically)
    log.txt                      log; rotated at 1 MB
```

Example `config.json`:

```json
{
  "InstanceId": "3F9A01C2",
  "Name": "Instance 3F9A01C2",
  "AppVersion": "2.0.0",
  "PollSeconds": 30,
  "Rules": [
    {
      "Id": "A1B2C3",
      "Name": "Seagate Expansion HDD",
      "MatchType": "DiskSerial",
      "MatchValue": "NAASPZ2N",
      "PartitionNumber": 0,
      "DriveLetter": "E",
      "Force": false,
      "Enabled": true
    }
  ]
}
```

`MatchType` is `DiskSerial`, `DiskUniqueId` or `VolumeGuid`. `PartitionNumber` `0` means the
largest volume on the disk.

## Building

On Windows:

```bash
powershell -ExecutionPolicy Bypass -File build.ps1
```

This installs [PS2EXE](https://github.com/MScholtes/PS2EXE) if needed and writes
`dist\AutoAssignDriveLetters.exe` plus a `.sha256` file. The exe is built with
`requireAdmin`, and its version comes from `$Script:AppVersion` in
`src\AutoAssignDriveLetters.ps1`. Change that value to release a new version. The GitHub
Actions workflow builds the exe on every push, and on a `v*` tag it attaches the exe to a
GitHub release.

To run the script without compiling it, use `AutoAssignDriveLetters.cmd`.

Requires Windows 8 / Server 2012 or newer (uses the Storage module: `Get-Disk`,
`Get-Partition`) and Windows PowerShell 5.1, which ships with Windows 10/11.

> Some antivirus products flag PS2EXE-built executables because PS2EXE is also used for
> malware. If that happens, use the `.cmd`/`.ps1` version or add an exclusion.
