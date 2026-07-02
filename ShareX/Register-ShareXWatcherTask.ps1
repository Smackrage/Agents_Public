<#
.SYNOPSIS
    Registers the ShareX rename watcher as a Scheduled Task that starts at logon.

.DESCRIPTION
    Creates a persistent, hidden background task running Watch-ShareXRename.ps1
    whenever the current user logs in. Disables the default 3-day execution time
    limit (required since the watcher runs an infinite loop) and configures
    automatic restart on failure.

.PARAMETER ScriptPath
    Full path to Watch-ShareXRename.ps1.

.PARAMETER WatchPath
    Full path to the ShareX screenshot folder to watch.

.PARAMETER TaskName
    Name for the Scheduled Task. Default: ShareXWatcher.

.EXAMPLE
    .\Register-ShareXWatcherTask.ps1 -ScriptPath "C:\Users\marti\OneDrive\Desktop\Git Repo\Agents\Agents_Public\ShareX\Watch-ShareXRename.ps1" -WatchPath "C:\Users\marti\Pictures\ShareX"

.NOTES
    Author: Marty
    Date: 2026-07-02
    Version: 1.0
#>

[CmdletBinding()]
Param (
    [Parameter(Mandatory = $True)]
    [ValidateNotNullOrEmpty()]
    [string] $ScriptPath,

    [Parameter(Mandatory = $True)]
    [ValidateNotNullOrEmpty()]
    [string] $WatchPath,

    [Parameter()]
    [string] $TaskName = "ShareXWatcher"
)

If ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Warning "This script was written and tested on PowerShell 5.1. You are running $($PSVersionTable.PSVersion). Some behaviour may differ. Continue? (Y/N)"
    $Continue = Read-Host
    If ($Continue -ne "Y") {
        Return
    }
}

If (-Not (Test-Path -Path $ScriptPath)) {
    Throw "Script not found at: $ScriptPath"
}

$Action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -WatchPath `"$WatchPath`""

$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

$Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -Principal $Principal `
    -Description "Watches ShareX screenshot folder and auto-renames files using Claude Vision. Managed by Watch-ShareXRename.ps1." `
    -Force | Out-Null

Write-Host ""
Write-Host "Scheduled Task registered successfully." -ForegroundColor Green
Write-Host "  Task name : $TaskName"
Write-Host "  Trigger   : At logon for $env:USERNAME"
Write-Host "  Script    : $ScriptPath"
Write-Host "  Watching  : $WatchPath"
Write-Host ""
Write-Host "  To test now without logging off: Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  To view status                 : Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
Write-Host "  To stop the running watcher    : Get-Process powershell | Where-Object { `$_.MainWindowTitle -eq '' } # then Stop-Process, or just log off/on"
Write-Host "  To remove entirely             : Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"