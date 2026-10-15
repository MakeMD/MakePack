# Helper: UIA-invoke a button by name prefix in a given process. Runs in its own process because Invoke on a
# button that opens a modal dialog does not return until the dialog closes.
param([int]$ProcId, [string]$NameEscaped)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AT = [System.Windows.Automation.AutomationElement]
$name = [regex]::Unescape($NameEscaped)
foreach ($w in $AT::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
    if ($w.Current.ProcessId -ne $ProcId) { continue }
    $c = New-Object System.Windows.Automation.PropertyCondition($AT::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $b = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $c) | Where-Object { $_.Current.Name -like ($name + '*') } | Select-Object -First 1
    if ($b) { $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); break }
}
