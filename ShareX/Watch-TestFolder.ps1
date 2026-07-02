<#
.SYNOPSIS
    File watcher that waits for files to finish writing before acting on them.

.DESCRIPTION
    Step 2 of building the ShareX rename agent. Extends the step 1 watcher with a
    file-lock-wait mechanism, so large or slow-writing files are not processed until
    the OS has released its write lock on them. Still does not rename or call any API --
    it only proves files are safe to read before step 3 wires in the real logic.

.PARAMETER WatchPath
    Full path to the folder to watch. Defaults to a test folder under Documents.

.PARAMETER LockTimeoutSeconds
    Maximum time to wait for a file's write lock to release before giving up. Default 30.

.EXAMPLE
    .\Watch-TestFolder.ps1
    Watches the default test folder, waiting for files to finish writing before logging them ready.

.NOTES
    Author: Marty
    Date: 2026-07-01
    Version: 1.2
    v1.2: Added Wait-FileReady lock-check logic. Refactored Write-Log to Global scope
          to eliminate duplicate CMTrace-formatting code between main script and event action.
    Press Ctrl+C in the console to stop watching.
#>

[CmdletBinding()]
Param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $WatchPath = "$env:USERPROFILE\Documents\WatcherTest",

    [Parameter()]
    [int] $LockTimeoutSeconds = 30
)

If ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Warning "This script was written and tested on PowerShell 5.1. You are running $($PSVersionTable.PSVersion). Some behaviour may differ. Continue? (Y/N)"
    $Continue = Read-Host
    If ($Continue -ne "Y") {
        Return
    }
}

$ErrorActionPreference = "Stop"
$ScriptStartTime = Get-Date
$LogFile = "$env:USERPROFILE\Documents\WatcherTest_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

<#
.SYNOPSIS
    Writes a CMTrace-compatible log entry to a log file and the console.

.PARAMETER Message
    The message to log.

.PARAMETER LogFile
    Full path to the log file.

.PARAMETER Severity
    1 = Informational (default), 2 = Warning, 3 = Error.
#>
Function Global:Write-Log {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string] $Message,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string] $LogFile,

        [Parameter()]
        [ValidateSet(1, 2, 3)]
        [int] $Severity = 1
    )

    $DateTime = Get-Date
    $DateString = $DateTime.ToString("MM-dd-yyyy")
    $TimeString = $DateTime.ToString("HH:mm:ss.fff")
    $Bias = (Get-TimeZone).BaseUtcOffset.TotalMinutes * -1
    $BiasString = If ($Bias -ge 0) { "+$Bias" } Else { "$Bias" }

    $LogLine = "<![LOG[$Message]LOG]!>" +
               "<time=""$TimeString$BiasString"" " +
               "date=""$DateString"" " +
               "component=""Watch-TestFolder"" " +
               "context="""" " +
               "type=""$Severity"" " +
               "thread=""$($PID)"" " +
               "file="""">"

    Add-Content -Path $LogFile -Value $LogLine -Encoding UTF8

    Switch ($Severity) {
        1 { Write-Host $Message -ForegroundColor Gray }
        2 { Write-Warning $Message }
        3 { Write-Error $Message }
    }
}

<#
.SYNOPSIS
    Waits for a file's write lock to release by repeatedly attempting an exclusive open.

.DESCRIPTION
    Used to detect when another process (e.g. Explorer, ShareX, a browser download) has
    finished writing to a file. While the file is still being written, an exclusive open
    attempt throws an IOException. This function polls until the open succeeds, the file
    disappears, or the timeout is reached.

.PARAMETER FilePath
    Full path to the file to check.

.PARAMETER TimeoutSeconds
    Maximum time to wait before giving up. Default 30.

.PARAMETER PollIntervalMs
    Milliseconds between retry attempts. Default 500.

.OUTPUTS
    [PSCustomObject] with Ready (bool) and Reason (string) properties.
#>
Function Global:Wait-FileReady {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string] $FilePath,

        [Parameter()]
        [int] $TimeoutSeconds = 30,

        [Parameter()]
        [int] $PollIntervalMs = 500
    )

    $WaitStart = Get-Date
    $LastHeartbeat = $WaitStart

    While ($True) {
        If (-Not (Test-Path -Path $FilePath)) {
            Return [PSCustomObject]@{ Ready = $False; Reason = "File no longer exists (removed or renamed before lock released)." }
        }

        Try {
            $Stream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $Stream.Close()
            $Stream.Dispose()
            Return [PSCustomObject]@{ Ready = $True; Reason = "Lock released after $([Math]::Round(((Get-Date) - $WaitStart).TotalSeconds, 1))s." }
        }
        Catch [System.IO.IOException] {
            $Elapsed = (Get-Date) - $WaitStart

            # Heartbeat every ~5 seconds so a long wait doesn't look hung
            If (((Get-Date) - $LastHeartbeat).TotalSeconds -ge 5) {
                Write-Log -Message "Still waiting for lock release on '$(Split-Path $FilePath -Leaf)'. Elapsed: $([Math]::Round($Elapsed.TotalSeconds, 0))s / ${TimeoutSeconds}s." -LogFile $Global:WatcherLogFile -Severity 1
                $LastHeartbeat = Get-Date
            }

            If ($Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                Return [PSCustomObject]@{ Ready = $False; Reason = "Timed out after ${TimeoutSeconds}s waiting for lock release." }
            }

            Start-Sleep -Milliseconds $PollIntervalMs
        }
    }
}

Try {
    If (-Not (Test-Path -Path $WatchPath)) {
        New-Item -ItemType Directory -Path $WatchPath -Force | Out-Null
        Write-Log -Message "Watch folder did not exist. Created: $WatchPath" -LogFile $LogFile -Severity 1
    }

    Write-Log -Message "===== Watch-TestFolder started. User: $env:USERNAME | Computer: $env:COMPUTERNAME | PS Version: $($PSVersionTable.PSVersion) =====" -LogFile $LogFile -Severity 1
    Write-Log -Message "Watching folder: $WatchPath | Lock timeout: ${LockTimeoutSeconds}s" -LogFile $LogFile -Severity 1

    $Global:WatcherLogFile = $LogFile

    $Watcher = New-Object System.IO.FileSystemWatcher
    $Watcher.Path = $WatchPath
    $Watcher.Filter = "*.*"
    $Watcher.IncludeSubdirectories = $False
    $Watcher.EnableRaisingEvents = $True

    $Action = {
        $FilePath = $Event.SourceEventArgs.FullPath
        $FileName = $Event.SourceEventArgs.Name

        Write-Log -Message "Detected Created event for file: $FileName. Waiting for write lock to release..." -LogFile $Global:WatcherLogFile -Severity 1
        Write-Host "New file detected, waiting for it to finish writing: $FileName" -ForegroundColor Yellow

        $LockTimeout = $Event.MessageData
        $Result = Wait-FileReady -FilePath $FilePath -TimeoutSeconds $LockTimeout

        If ($Result.Ready) {
            Write-Log -Message "File ready: $FileName. $($Result.Reason)" -LogFile $Global:WatcherLogFile -Severity 1
            Write-Host "File ready: $FileName" -ForegroundColor Green
        }
        Else {
            Write-Log -Message "File NOT ready: $FileName. $($Result.Reason)" -LogFile $Global:WatcherLogFile -Severity 2
            Write-Host "Gave up waiting on: $FileName -- $($Result.Reason)" -ForegroundColor Red
        }
    }

    # MessageData passes the lock timeout into the event action's separate runspace
    Register-ObjectEvent -InputObject $Watcher -EventName "Created" -Action $Action -SourceIdentifier "TestFolderWatcher" -MessageData $LockTimeoutSeconds | Out-Null

    Write-Log -Message "Watcher registered and active. Drop a file into $WatchPath to test. Press Ctrl+C to stop." -LogFile $LogFile -Severity 1

    While ($True) {
        Start-Sleep -Seconds 1
    }
}
Catch {
    Write-Log -Message "FATAL error on line $($_.InvocationInfo.ScriptLineNumber): $_" -LogFile $LogFile -Severity 3
    Throw
}
Finally {
    Unregister-Event -SourceIdentifier "TestFolderWatcher" -ErrorAction SilentlyContinue
    If ($Watcher) {
        $Watcher.Dispose()
    }
    Write-Log -Message "===== Watch-TestFolder stopped. Elapsed: $((Get-Date) - $ScriptStartTime) =====" -LogFile $LogFile -Severity 1
}