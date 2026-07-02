<#
.SYNOPSIS
    Event-driven ShareX screenshot renamer -- watches a folder and renames new
    screenshots the moment they land, using Claude Vision to describe the content.

.DESCRIPTION
    Watches a ShareX screenshot folder (recursively, including subfolders created after
    the watcher starts) using a FileSystemWatcher. Waits for each file's write lock to
    release before processing, sends it to Claude Vision for a filename-safe description,
    and renames it. Files the API cannot confidently describe are left unrenamed and their
    paths are written to a separate uncertain-files log for manual review.

.PARAMETER WatchPath
    Full path to the ShareX screenshot root folder to watch.

.PARAMETER ApiKey
    Anthropic API key. If not supplied, reads from the ANTHROPIC_API_KEY environment
    variable (process environment first, falling back to a direct registry read for
    reliability under Scheduled Tasks). Never hardcode this in the script.

.PARAMETER LockTimeoutSeconds
    Maximum time to wait for a file's write lock to release before giving up. Default 30.

.EXAMPLE
    .\Watch-ShareXRename.ps1 -WatchPath "C:\Users\Marty\Pictures\ShareX"

.NOTES
    Author: Marty
    Date: 2026-07-02
    Version: 2.2
    v2.2: Added idempotency guard -- skips files already matching our own rename output
          pattern, preventing a re-processing loop if a rename spuriously retriggers a
          Created event (observed during manual testing).
    v2.1: IncludeSubdirectories set to $True to cover ShareX's year-month subfolder
          structure. Added registry fallback for API key read (Scheduled Task reliability).
    v2.0: Wired in Vision API rename logic.
    v1.2: Added Wait-FileReady lock-check logic. Write-Log refactored to Global scope.
    v1.1: Fixed CMTrace time bias double-sign bug (was producing +-600 instead of -600).
    Press Ctrl+C in the console to stop watching (if run interactively).
#>

[CmdletBinding()]
Param (
    [Parameter(Mandatory = $True)]
    [ValidateNotNullOrEmpty()]
    [string] $WatchPath,

    [Parameter()]
    [string] $ApiKey,

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

If (-Not $ApiKey) {
    $ApiKey = $env:ANTHROPIC_API_KEY
}
If (-Not $ApiKey) {
    $ApiKey = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User")
}
If (-Not $ApiKey) {
    Throw "No Anthropic API key found. Set the ANTHROPIC_API_KEY environment variable or pass -ApiKey. Never hardcode the key in this script, especially if it lives in a public repo."
}

$LogFile = Join-Path -Path $WatchPath -ChildPath "ShareXWatcher_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$UncertainLog = Join-Path -Path $WatchPath -ChildPath "ShareXWatcher_Uncertain_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

<#
.SYNOPSIS
    Writes a CMTrace-compatible log entry to a log file and the console.
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
               "component=""Watch-ShareXRename"" " +
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

<#
.SYNOPSIS
    Sends an image to Claude Vision and returns a filename-safe description.

.PARAMETER ImagePath
    Full path to the image file.

.PARAMETER ApiKey
    Anthropic API key.

.PARAMETER MaxTokens
    Maximum tokens for the response.

.OUTPUTS
    [PSCustomObject] with Description [string], Uncertain [bool], RawResponse [string].
#>
Function Global:Get-ImageDescription {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string] $ImagePath,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string] $ApiKey,

        [Parameter()]
        [int] $MaxTokens = 100
    )

    $Extension = (Get-Item -Path $ImagePath).Extension.ToLower()
    $MimeMap = @{
        ".png"  = "image/png"
        ".jpg"  = "image/jpeg"
        ".jpeg" = "image/jpeg"
        ".gif"  = "image/gif"
        ".webp" = "image/webp"
    }
    $MediaType = $MimeMap[$Extension]
    If (-Not $MediaType) {
        Return [PSCustomObject]@{
            Description = $null
            Uncertain   = $True
            RawResponse = "Unsupported file extension: $Extension"
        }
    }

    $ImageBytes = [System.IO.File]::ReadAllBytes($ImagePath)
    $Base64Image = [Convert]::ToBase64String($ImageBytes)

    $SystemPrompt = @"
You are a screenshot description assistant. Your sole job is to produce a concise,
filename-safe description of what a screenshot shows.

Rules:
- Reply with ONLY the description -- no preamble, no punctuation at the end.
- Use Title Case with spaces between words (e.g. Visual Studio Code Python Error).
- Maximum 8 words.
- Only name a specific application or product if you are visually certain (logo,
  distinctive branding, or exact UI text). If inferring from layout alone, use a
  generic term instead (e.g. Chat Application rather than guessing a specific app).
- If you cannot determine what the screenshot depicts with reasonable confidence,
  reply with exactly the word: UNCERTAIN
"@

    $Body = @{
        model      = "claude-sonnet-5"
        max_tokens = $MaxTokens
        system     = $SystemPrompt
        messages   = @(
            @{
                role    = "user"
                content = @(
                    @{
                        type   = "image"
                        source = @{
                            type       = "base64"
                            media_type = $MediaType
                            data       = $Base64Image
                        }
                    },
                    @{
                        type = "text"
                        text = "Describe this screenshot."
                    }
                )
            }
        )
    } | ConvertTo-Json -Depth 10

    $Headers = @{
        "x-api-key"         = $ApiKey
        "anthropic-version" = "2023-06-01"
        "content-type"      = "application/json"
    }

    $Response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post -Headers $Headers -Body $Body

    $RawText = ($Response.content | Where-Object { $_.type -eq "text" } | Select-Object -First 1).text.Trim()

    If ($RawText -ieq "UNCERTAIN" -Or [string]::IsNullOrWhiteSpace($RawText)) {
        Return [PSCustomObject]@{
            Description = $null
            Uncertain   = $True
            RawResponse = $RawText
        }
    }

    $SafeDescription = $RawText -replace '[<>:"/\\|?*]', "" -replace '\s+', " " -replace '^\s+|\s+$', ""

    Return [PSCustomObject]@{
        Description = $SafeDescription
        Uncertain   = $False
        RawResponse = $RawText
    }
}

<#
.SYNOPSIS
    Returns the best available capture date for an image file.
#>
Function Global:Get-CaptureDateFromFile {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string] $FilePath
    )

    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    If ($BaseName -match '(\d{4})-(\d{2})-(\d{2})') {
        Try {
            Return [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
        }
        Catch { <# fall through to file date #> }
    }

    Return (Get-Item -Path $FilePath).CreationTime
}

<#
.SYNOPSIS
    Returns a unique file path, appending _N if a name collision exists.
#>
Function Global:ConvertTo-UniqueFilePath {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string] $Directory,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string] $BaseName,

        [Parameter(Mandatory = $True)]
        [ValidateNotNullOrEmpty()]
        [string] $Extension
    )

    $CandidatePath = Join-Path -Path $Directory -ChildPath "$BaseName$Extension"
    If (-Not (Test-Path -Path $CandidatePath)) {
        Return $CandidatePath
    }

    $Suffix = 1
    Do {
        $CandidatePath = Join-Path -Path $Directory -ChildPath "${BaseName}_$Suffix$Extension"
        $Suffix++
    } While (Test-Path -Path $CandidatePath)

    Return $CandidatePath
}

Try {
    If (-Not (Test-Path -Path $WatchPath)) {
        Throw "Watch path does not exist: $WatchPath"
    }

    Write-Log -Message "===== Watch-ShareXRename started. User: $env:USERNAME | Computer: $env:COMPUTERNAME | PS Version: $($PSVersionTable.PSVersion) =====" -LogFile $LogFile -Severity 1
    Write-Log -Message "Watching folder (recursive): $WatchPath | Lock timeout: ${LockTimeoutSeconds}s" -LogFile $LogFile -Severity 1

    $Global:WatcherLogFile = $LogFile
    $Global:WatcherUncertainLog = $UncertainLog
    $Global:WatcherApiKey = $ApiKey
    $Global:WatcherLockTimeout = $LockTimeoutSeconds
    $Global:SupportedExtensions = @(".png", ".jpg", ".jpeg", ".gif", ".webp")

    $Watcher = New-Object System.IO.FileSystemWatcher
    $Watcher.Path = $WatchPath
    $Watcher.Filter = "*.*"
    $Watcher.IncludeSubdirectories = $True
    $Watcher.EnableRaisingEvents = $True

    $Action = {
        $FilePath = $Event.SourceEventArgs.FullPath
        $FileName = $Event.SourceEventArgs.Name
        $Extension = [System.IO.Path]::GetExtension($FileName).ToLower()

        # Skip non-image files (e.g. our own log files being written into the same folder)
        If ($Global:SupportedExtensions -NotContains $Extension) {
            Return
        }

        # Skip files that already match our own rename output pattern -- prevents
        # re-processing already-renamed files if a rename operation spuriously
        # triggers a Created event (observed during manual testing)
        If ($FileName -match "_\d{4}-\d{2}-\d{2}(_\d+)?\.(png|jpg|jpeg|gif|webp)$") {
            Return
        }

        Write-Log -Message "Detected new screenshot: $FileName. Waiting for write lock to release..." -LogFile $Global:WatcherLogFile -Severity 1
        Write-Host "New screenshot detected, waiting for write to finish: $FileName" -ForegroundColor Yellow

        $LockResult = Wait-FileReady -FilePath $FilePath -TimeoutSeconds $Global:WatcherLockTimeout

        If (-Not $LockResult.Ready) {
            Write-Log -Message "File NOT ready: $FileName. $($LockResult.Reason)" -LogFile $Global:WatcherLogFile -Severity 2
            Add-Content -Path $Global:WatcherUncertainLog -Value $FilePath -Encoding UTF8
            Write-Host "Gave up waiting on: $FileName -- $($LockResult.Reason)" -ForegroundColor Red
            Return
        }

        Write-Log -Message "File ready: $FileName. $($LockResult.Reason) Sending to Vision API..." -LogFile $Global:WatcherLogFile -Severity 1

        Try {
            $AiResult = Get-ImageDescription -ImagePath $FilePath -ApiKey $Global:WatcherApiKey

            If ($AiResult.Uncertain) {
                Write-Log -Message "AI could not confidently describe '$FileName'. Raw response: $($AiResult.RawResponse). File NOT renamed." -LogFile $Global:WatcherLogFile -Severity 2
                Add-Content -Path $Global:WatcherUncertainLog -Value $FilePath -Encoding UTF8
                Write-Host "Uncertain, left unrenamed: $FileName" -ForegroundColor Yellow
                Return
            }

            $DateSuffix = (Get-CaptureDateFromFile -FilePath $FilePath).ToString("yyyy-MM-dd")
            $NewBaseName = "$($AiResult.Description)_$DateSuffix"
            $NewFilePath = ConvertTo-UniqueFilePath -Directory (Split-Path $FilePath -Parent) -BaseName $NewBaseName -Extension $Extension

            Rename-Item -Path $FilePath -NewName (Split-Path $NewFilePath -Leaf)

            Write-Log -Message "RENAMED: '$FileName' -> '$(Split-Path $NewFilePath -Leaf)'" -LogFile $Global:WatcherLogFile -Severity 1
            Write-Host "Renamed: $FileName -> $(Split-Path $NewFilePath -Leaf)" -ForegroundColor Green
        }
        Catch {
            Write-Log -Message "ERROR processing '$FileName': $_" -LogFile $Global:WatcherLogFile -Severity 3
            Write-Host "Error processing $FileName -- see log." -ForegroundColor Red
        }
    }

    Register-ObjectEvent -InputObject $Watcher -EventName "Created" -Action $Action -SourceIdentifier "ShareXWatcher" | Out-Null

    Write-Log -Message "Watcher registered and active. Uncertain log: $UncertainLog" -LogFile $LogFile -Severity 1
    Write-Host "Watching $WatchPath for new screenshots. Press Ctrl+C to stop." -ForegroundColor Cyan

    While ($True) {
        Start-Sleep -Seconds 1
    }
}
Catch {
    Write-Log -Message "FATAL error on line $($_.InvocationInfo.ScriptLineNumber): $_" -LogFile $LogFile -Severity 3
    Throw
}
Finally {
    Unregister-Event -SourceIdentifier "ShareXWatcher" -ErrorAction SilentlyContinue
    If ($Watcher) {
        $Watcher.Dispose()
    }
    Write-Log -Message "===== Watch-ShareXRename stopped. Elapsed: $((Get-Date) - $ScriptStartTime) =====" -LogFile $LogFile -Severity 1
}
