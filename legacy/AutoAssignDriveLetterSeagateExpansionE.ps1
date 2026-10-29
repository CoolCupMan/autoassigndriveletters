$driveLetter = "E:"

$diskdrive = gwmi win32_diskdrive | ?{($_.interfacetype -eq "USB") -and $_.serialnumber.trim() -eq "NAASPZ2N"}
$letters = $diskdrive | %{gwmi -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID=`"$($_.DeviceID.replace('\','\\'))`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition"} |  %{gwmi -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=`"$($_.DeviceID)`"} WHERE AssocClass = Win32_LogicalDiskToPartition"} | %{$_. deviceid} 
$drive = gwmi win32_volume | ? {$letters -contains ($_.name -replace "\\")}

if ($drive.DriveLetter -ne $driveLetter)
    {
        $drive.DriveLetter = $driveLetter
        $drive.Put()
    }