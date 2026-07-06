# ShareX Auto-Rename Agent — Implementation Guide

## What this does

Watches a ShareX screenshot folder (including all year-month subfolders) and automatically
renames each new screenshot using an AI-generated description of its content, in the format:
`Description Of Content_YYYY-MM-DD.png`. Runs continuously in the background, starting
automatically at user logon. Files the AI can't confidently describe are left unrenamed and
logged separately for manual review.

## Prerequisites

- Windows 11
- PowerShell 5.1 or later (Windows PowerShell or PowerShell 7+ both work)
- ShareX installed and already saving screenshots to a known folder
- An Anthropic API key (see "Getting an API key" below)
- VS Code recommended for editing, but not required to run the scripts

## Getting an API key

1. Go to `platform.claude.com` and sign up or log in
2. Settings → Billing → add a payment method (required before any request will succeed;
   API usage is billed per token, separate from any Claude.ai subscription)
3. Settings → API Keys → Create Key → give it a descriptive name
4. Copy the key immediately — it starts with `sk-ant-` and is shown only once

## Step 1 — Set the API key as an environment variable

Never hardcode the key in the script or commit it to any repository, public or private.

In a terminal:

```powershell
setx ANTHROPIC_API_KEY "sk-ant-your-key-here"
```

Close and fully reopen the terminal/VS Code afterwards — `setx` writes to the registry but
existing sessions won't pick it up until restarted.

Verify it worked in a new terminal:

```powershell
$env:ANTHROPIC_API_KEY
```

## Step 2 — Find the real ShareX screenshot folder

Check ShareX itself: **Task Settings → Output → Screenshots folder**. ShareX typically
organises captures into year-month subfolders (e.g. `2026-07`, `2026-06`) under that root —
the scripts below are built to watch recursively, so this structure is handled automatically.

## Step 3 — Save the watcher script

Save the script below as `Watch-ShareXRename.ps1` in a folder of your choice (e.g. a private
Git repo, or a plain scripts folder).

```powershell
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
    Version: 2.3
    v2.3: ShareXWatcher.log is now a single persistent file (no per-run timestamp in the
          name). Write-Log auto-rotates it to ShareXWatcher.lo_ once it reaches 5MB,
          replacing any previous .lo_ so only one rotated copy is ever kept.
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

$LogFile = Join-Path -Path $WatchPath -ChildPath "ShareXWatcher.log"
$UncertainLog = Join-Path -Path $WatchPath -ChildPath "ShareXWatcher_Uncertain_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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
        [int] $Severity = 1,

        [Parameter()]
        [long] $MaxSizeBytes = 5MB
    )

    Try {
        If ((Test-Path -LiteralPath $LogFile) -And (Get-Item -LiteralPath $LogFile).Length -ge $MaxSizeBytes) {
            $ArchivePath = [System.IO.Path]::ChangeExtension($LogFile, "lo_")
            Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
            Rename-Item -LiteralPath $LogFile -NewName (Split-Path -Path $ArchivePath -Leaf) -Force
            $Message = "Log reached $([Math]::Round($MaxSizeBytes / 1MB, 0))MB and was rotated to " +
                "$(Split-Path -Path $ArchivePath -Leaf) (previous rotated copy, if any, was replaced). $Message"
        }
    }
    Catch {
        Write-Warning "Log rotation check failed for '$LogFile': $_"
    }

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

    Add-Content -LiteralPath $LogFile -Value $LogLine -Encoding UTF8

    Switch ($Severity) {
        1 { Write-Host $Message -ForegroundColor Gray }
        2 { Write-Warning $Message }
        3 { Write-Error $Message }
    }
}

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

        $LockResult = Wait-FileReady -FilePath $FilePath -TimeoutSeconds $Global:WatcherLockTimeout

        If (-Not $LockResult.Ready) {
            Write-Log -Message "File NOT ready: $FileName. $($LockResult.Reason)" -LogFile $Global:WatcherLogFile -Severity 2
            Add-Content -Path $Global:WatcherUncertainLog -Value $FilePath -Encoding UTF8
            Return
        }

        Write-Log -Message "File ready: $FileName. $($LockResult.Reason) Sending to Vision API..." -LogFile $Global:WatcherLogFile -Severity 1

        Try {
            $AiResult = Get-ImageDescription -ImagePath $FilePath -ApiKey $Global:WatcherApiKey

            If ($AiResult.Uncertain) {
                Write-Log -Message "AI could not confidently describe '$FileName'. Raw response: $($AiResult.RawResponse). File NOT renamed." -LogFile $Global:WatcherLogFile -Severity 2
                Add-Content -Path $Global:WatcherUncertainLog -Value $FilePath -Encoding UTF8
                Return
            }

            $DateSuffix = (Get-CaptureDateFromFile -FilePath $FilePath).ToString("yyyy-MM-dd")
            $NewBaseName = "$($AiResult.Description)_$DateSuffix"
            $NewFilePath = ConvertTo-UniqueFilePath -Directory (Split-Path $FilePath -Parent) -BaseName $NewBaseName -Extension $Extension

            Rename-Item -Path $FilePath -NewName (Split-Path $NewFilePath -Leaf)

            Write-Log -Message "RENAMED: '$FileName' -> '$(Split-Path $NewFilePath -Leaf)'" -LogFile $Global:WatcherLogFile -Severity 1
        }
        Catch {
            Write-Log -Message "ERROR processing '$FileName': $_" -LogFile $Global:WatcherLogFile -Severity 3
        }
    }

    Register-ObjectEvent -InputObject $Watcher -EventName "Created" -Action $Action -SourceIdentifier "ShareXWatcher" | Out-Null

    Write-Log -Message "Watcher registered and active. Uncertain log: $UncertainLog" -LogFile $LogFile -Severity 1

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
```

## Step 3a — Add a .gitignore if this lives in a Git repo

If the scripts folder is (or will be) tracked in Git, add a `.gitignore` at the repo root
before your first commit — a backstop against ever committing log files or local config,
even though the scripts themselves never contain secrets directly.

```gitignore
# Log files generated by the watcher scripts
*.log
*.lo_
ShareXWatcher_*.log
ShareXWatcher_Uncertain_*.log
WatcherTest_*.log

# Local environment / secrets -- never commit API keys or config containing them
.env
*.env
appsettings.local.json
secrets.json

# OS/editor noise
.vscode/
Thumbs.db
desktop.ini
```

## Step 4 — Test it manually before automating anything

Run from a terminal in the folder where the script is saved:

```powershell
.\Watch-ShareXRename.ps1 -WatchPath "C:\Users\Marty\Pictures\ShareX"
```

Take a real screenshot with ShareX. Confirm in the console (or the log file) that it walks
through: detected → waiting for lock → ready → sent to Vision → renamed (or flagged
uncertain). Test a handful of different screenshot types before moving on — different apps,
different content — to get a feel for description quality.

Press `Ctrl+C` to stop.

## Step 5 — Save the Scheduled Task registration script

Save this as `Register-ShareXWatcherTask.ps1` in the same folder.

```powershell
<#
.SYNOPSIS
    Registers the ShareX rename watcher as a Scheduled Task that starts at logon.

.DESCRIPTION
    Creates a persistent, hidden background task running Watch-ShareXRename.ps1 whenever
    the current user logs in. Disables the default 3-day execution time limit (required
    since the watcher runs an infinite loop) and configures automatic restart on failure.

.PARAMETER ScriptPath
    Full path to Watch-ShareXRename.ps1.

.PARAMETER WatchPath
    Full path to the ShareX screenshot folder to watch.

.PARAMETER TaskName
    Name for the Scheduled Task. Default: ShareXWatcher.

.EXAMPLE
    .\Register-ShareXWatcherTask.ps1 -ScriptPath "C:\Scripts\Watch-ShareXRename.ps1" -WatchPath "C:\Users\Marty\Pictures\ShareX"

.NOTES
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
Write-Host "  To remove entirely             : Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
```

## Step 6 — Register the Scheduled Task

```powershell
.\Register-ShareXWatcherTask.ps1 -ScriptPath "C:\Scripts\Watch-ShareXRename.ps1" -WatchPath "C:\Users\Marty\Pictures\ShareX"
```

(use full, real paths for both parameters)

## Step 7 — Test the task

Without rebooting:

```powershell
Start-ScheduledTask -TaskName 'ShareXWatcher'
```

Take a screenshot, confirm a new log file appears in the watch folder root and updates as
expected. Then log off and back on once to confirm the actual "at logon" trigger fires
correctly on its own — a manual start working doesn't prove the trigger itself is configured
right.

## Notes and known considerations

- **API billing is separate from any Claude.ai subscription** — this draws from a prepaid,
  usage-based API balance, not a Pro/Max/Team plan.
- **Never commit the API key to any Git repository**, public or private — it's read from an
  environment variable only, never hardcoded in either script.
- **Model string may go stale over time** — `claude-sonnet-5` is current as of this guide;
  if you see a `not_found_error` referencing the model, check Anthropic's current model
  list and update the `model` line in `Get-ImageDescription`.
- **If the ShareX folder is OneDrive-synced**, newly created screenshots are unaffected, but
  older files that OneDrive has made "online-only" (cloud icon, not yet downloaded locally)
  could behave unexpectedly if the watcher ever needs to touch them — not an issue for new
  captures, just worth knowing.
- **Uncertain files are left unrenamed** and their paths logged to the
  `ShareXWatcher_Uncertain_*.log` file for manual review — this is by design, not a bug.
- **Repository visibility** — set the repo to private if it isn't already. Before making it
  public (if that's ever a goal), run a full history check for leaked secrets:
  `git log --all -p -- "**/*.ps1" | Select-String "sk-ant-"` (PowerShell) — empty output
  means no API key has ever been committed on any branch. A `.gitignore` prevents future
  leaks but does not retroactively clean history; if a key is ever found in history, revoke
  and regenerate it rather than relying on a rewritten commit alone.
