$computer = "Happy"
$filterNS = "root\cimv2"
$wmiNS = "root\subscription"
$query = "Select * from __InstanceCreationEvent within 5 where targetinstance isa 'win32_logicaldisk'"

$filterName = "TestFilter"

$filterPath = Set-WmiInstance -Class __EventFilter `
 -ComputerName $computer -Namespace $wmiNS -Arguments `
  @{name=$filterName; EventNameSpace=$filterNS; QueryLanguage="WQL";
    Query=$query}

$consumerPath = Set-WmiInstance -Class CommandLineEventConsumer `
 -ComputerName $computer -Namespace $wmiNS `
 -Arguments @{
 name="TestConsumer"; 
 ExecutablePath= "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
 CommandLineTemplate = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -executionpolicy bypass -file Y:\Dokumente\Computer\Aktive-Scripts\AssignDriveLetters\AutoAssignSeagateExpansionE\AutoAssignDriveLetterSeagateExpansionE.ps1"
 }

Set-WmiInstance -Class __FilterToConsumerBinding -ComputerName $computer `
  -Namespace $wmiNS -arguments @{Filter=$filterPath; Consumer=$consumerPath} |
  out-null