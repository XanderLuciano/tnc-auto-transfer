# Heidenhain TNCcmd Automatic File Transfer

> **Version:** 1.1.0 | **Date:** 2026-03-16 | **Author:** [Xander Luciano](https://notes.xanderluciano.com/heidenhain-tnccmd-auto-transfer)

Scripts for automatically sending files to Heidenhain CNC controllers over the network.

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.2.0 | 2026-03-21 | Added support for subdirectories, UNC paths, and overwriting existing programs on the machine |
| 1.1.0 | 2026-03-16 | Added dual watcher modes (Synchronous/Asynchronous), fixed event handling reliability, improved code structure |
| 1.0.0 | 2026-03-12 | Initial release with folder watcher and batch file scripts |

---

## What is TNCcmd?

**TNCcmd** is a command-line tool included with Heidenhain's free **TNCremo** software package. It allows automated file transfers between a PC and Heidenhain CNC controllers over the network.

### Supported Controllers
- TNC 320, TNC 620, TNC 640
- iTNC 530
- TNC 426, TNC 430
- Other Heidenhain controls with network capability

### Protocol
- **LSV2** (over TCP/IP, default port 19000)
- Binary and ASCII transfer modes supported

---

## Prerequisites

### 1. Install TNCremo (Free)

Download from Heidenhain:
- **Official download**: https://www.heidenhain.com/products/cnc-controls/software/tncremo
- Create a free account if required
- During installation, TNCcmd.exe is included automatically
- Default install location: `C:\Program Files (x86)\HEIDENHAIN\TNCremo\`

### 2. Network Connectivity

- CNC machine must be on the same network as your PC
- Machine needs a configured IP address
- Firewall must allow TCP port 19000 (LSV2 protocol)

### 3. CNC Controller Requirements

- Controller must have network option enabled
- DNC (Remote Data Transfer) must be activated
- Check with your machine manufacturer if unsure

---

## Quick Start

1. Download both scripts below
2. Edit the configuration variables at the top (machine IP, folders)
3. Create a `WatchFolder` subfolder next to the script
4. Run the PowerShell script — it watches for new files and auto-uploads them

---

## Script 1: PowerShell Folder Watcher (Recommended)

**Best for**: Continuous automated monitoring

### Features

- **Two watcher modes** — choose the best approach for your environment:
  - **Asynchronous (default)**: Non-blocking, handles rapid file creation, uses event queue
  - **Synchronous**: Simple and reliable, blocks during file transfer
- Watches a folder in real-time for new files
- Automatically transfers files as soon as they appear
- **Retry logic** — If file is locked on controller, retries up to 150 times (30s intervals)
- Handles file locking (waits for files to finish copying)
- Optional: Delete source files or move to "Processed" folder
- Failed transfers moved to "Failed" folder after max retries
- Handles duplicate filenames (adds timestamp)
- Detailed logging
- Processes existing files on startup

### Watcher Mode Selection

At the top of the script, set the `$WatcherMode` variable:

```powershell
$WatcherMode = "Asynchronous"  # Options: "Synchronous" or "Asynchronous"
```

| Mode | Pros | Cons | Best For |
|------|------|------|----------|
| **Asynchronous** | Non-blocking, handles rapid file drops, won't miss files during transfers | Slightly more complex | Production environments, frequent file drops |
| **Synchronous** | Simple, reliable, no scope issues | Blocks during transfer (can't detect new files while transferring) | Infrequent file drops, simple setups |

### Configuration

Edit these variables at the top of the script:

```powershell
$WatcherMode = "Asynchronous"          # "Synchronous" or "Asynchronous"
$MachineIP = "192.168.1.100"           # Your machine's IP address
$WatchFolder = ".\WatchFolder"         # Folder to watch (relative to script or absolute). Support subdirectories and preserves their structure. 
$DestinationFolder = "TNC:\"           # Destination on CNC machine. Any watched subdirectories will be mirrored to this location. 
$FileFilter = "*.*"                    # File types to watch
$MoveToProcessedFolder = $true         # Move files after successful transfer
$MoveToFailedFolder = $true            # Move files to Failed after max retries

# Retry settings (for locked files on controller)
$MaxRetries = 150                      # Maximum retry attempts
$RetryDelaySeconds = 30                # Seconds between retries
```

### Folder Structure

```
WatchFolder/
├── (incoming files)      # Drop files here
├── Processed/            # Successful transfers go here
└── Failed/               # Failed after max retries
```

### Usage

```powershell
# Option 1: Right-click > Run with PowerShell

# Option 2: From PowerShell command line
.\TNCcmd-FolderWatcher.ps1

# Option 3: If execution policy blocks it
powershell -ExecutionPolicy Bypass -File "C:\path\to\TNCcmd-FolderWatcher.ps1"
```

### Full Script: TNCcmd-FolderWatcher.ps1

```powershell
#Requires -Version 5.1
<#
================================================================================
  TNCcmd Folder Watcher
  Version: 1.1.0
  Date:    2026-03-16
  Author:  Xander Luciano
  Docs:    https://notes.xanderluciano.com/heidenhain-tnccmd-auto-transfer
================================================================================

.SYNOPSIS
    Watches a folder for new files and automatically sends them to a Heidenhain CNC machine using TNCcmd.

.DESCRIPTION
    This script monitors a specified folder for newly created files and automatically
    transfers them to a Heidenhain CNC controller over the network using the TNCcmd
    command-line tool (part of TNCremo software package).
    
    Two watching modes are available:
    - Synchronous (WaitForChanged): Simple, reliable, blocks during file processing
    - Asynchronous (Event Queue): Non-blocking, handles rapid file creation

.PREREQUISITES
    1. TNCremo must be installed on this PC
       - Download free from: https://www.heidenhain.com/products/cnc-controls/software/tncremo
       - During installation, TNCcmd.exe is included automatically
       
    2. Network connectivity to the CNC machine
       - Machine must be on the same network or reachable via IP
       - Default port is 19000 (LSV2 protocol)
       
    3. CNC controller must have network/DNC option enabled
       - Check with machine manufacturer or Heidenhain support

.NOTES
    Author: Generated for Heidenhain TNC controllers
    Compatible Controllers: TNC 320, TNC 620, TNC 640, iTNC 530, TNC 426/430, and others
    Protocol: LSV2 (over TCP/IP)
    
.EXAMPLE
    .\TNCcmd-FolderWatcher.ps1
    
    Runs the folder watcher with default settings. Press Ctrl+C to stop.
#>

# ============================================================================
# CONFIGURATION - Edit these variables to match your setup
# ============================================================================

# ------------------------------
# WATCHER MODE
# ------------------------------
# Choose how the script monitors for file changes:
#
# "Synchronous"  - Uses WaitForChanged() in a loop
#                  + Simple and reliable
#                  + No scope/variable issues
#                  - Blocks during file transfer (can't detect new files while transferring)
#                  Best for: Infrequent file drops, simple setups
#
# "Asynchronous" - Uses event-based monitoring with a queue
#                  + Non-blocking (continues detecting files during transfers)
#                  + Handles rapid file creation
#                  - Slightly more complex
#                  Best for: Frequent file drops, production environments

$WatcherMode = "Asynchronous"  # Options: "Synchronous" or "Asynchronous"

# ------------------------------
# MACHINE CONNECTION
# ------------------------------

# Machine IP address - Change this to your CNC machine's IP
$MachineIP = "192.168.1.100"

# Destination folder on the CNC machine
# - TNC:\ is the root of the machine's storage
# - Common paths: TNC:\nc_prog\, TNC:\Programs\, TNC:\
$DestinationFolder = "TNC:\"

# Connection timeout in seconds
$ConnectionTimeout = 30

# ------------------------------
# FOLDER SETTINGS
# ------------------------------

# Watch folder path
# - Use ".\WatchFolder" for a subfolder next to this script
# - Use $PSScriptRoot for the same folder as the script
# - Or specify a full path like "C:\NCPrograms\ToMachine"
$WatchFolder = ".\WatchFolder"
# - To include subdirectories and preserve their structure, set $IncludeSubdirectories = $true
# - To enable overwrite of existing files on the control (ex. for updating an existing program) use $DeleteBeforeTransfer  = $true 


# File filter - which files to watch for
# - "*.h" for Heidenhain NC programs only
# - "*.H" for uppercase extension
# - "*.*" for all files
$FileFilter = "*.*"

# ------------------------------
# TRANSFER OPTIONS
# ------------------------------

$UseBinaryMode = $true           # Use /b flag for binary transfer (recommended)
$ConvertNCPrograms = $false      # Use /c flag to convert .H/.I files during transfer
$DeleteAfterTransfer = $false    # Delete source file after successful transfer
$MoveToProcessedFolder = $true   # Move files to "Processed" subfolder after transfer
$MoveToFailedFolder = $true      # Move files to "Failed" subfolder after max retries

# ------------------------------
# RETRY SETTINGS
# ------------------------------

# For locked files on controller (file open in editor, etc.)
$MaxRetries = 150                # Maximum retry attempts
$RetryDelaySeconds = 30          # Seconds between retries

# ------------------------------
# LOGGING
# ------------------------------

$EnableLogging = $true
$LogFile = ".\TNCcmd-Watcher.log"

# ------------------------------
# TNCcmd PATH
# ------------------------------

# TNCcmd.exe path (usually auto-detected)
$TNCcmdPath = "C:\Program Files (x86)\HEIDENHAIN\TNCremo\TNCcmd.exe"

# ============================================================================
# END OF CONFIGURATION
# ============================================================================

# Resolve paths to absolute paths
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
$WatchFolder = if ([System.IO.Path]::IsPathRooted($WatchFolder)) { $WatchFolder } else { Join-Path $ScriptDir $WatchFolder }
$LogFile = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $ScriptDir $LogFile }

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    switch ($Level) {
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default   { Write-Host $logMessage }
    }
    
    # File logging
    if ($EnableLogging) {
        Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
    }
}

function Test-TNCcmd {
    # Check if TNCcmd.exe exists
    if (-not (Test-Path $TNCcmdPath)) {
        # Try alternate locations
        $alternatePaths = @(
            "C:\Program Files\HEIDENHAIN\TNCremo\TNCcmd.exe",
            "C:\Program Files (x86)\HEIDENHAIN\TNCremoNT\TNCcmd.exe",
            "${env:ProgramFiles}\HEIDENHAIN\TNCremo\TNCcmd.exe",
            "${env:ProgramFiles(x86)}\HEIDENHAIN\TNCremo\TNCcmd.exe"
        )
        
        foreach ($path in $alternatePaths) {
            if (Test-Path $path) {
                $script:TNCcmdPath = $path
                Write-Log "Found TNCcmd at: $path"
                return $true
            }
        }
        
        Write-Log "TNCcmd.exe not found! Please install TNCremo from Heidenhain." "ERROR"
        Write-Log "Download from: https://www.heidenhain.com/products/cnc-controls/software/tncremo" "ERROR"
        return $false
    }
    
    Write-Log "TNCcmd found at: $TNCcmdPath"
    return $true
}

function Test-MachineConnection {
    param([string]$IP)
    
    Write-Log "Testing connection to machine at $IP..."
    
    # First do a simple ping test
    $ping = Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $ping) {
        Write-Log "Cannot ping machine at $IP - check network connection" "WARNING"
        # Continue anyway - some machines block ping but allow LSV2
    }
    
    # Try a TNCcmd connection test
    $cmdFile = [System.IO.Path]::GetTempFileName()
    try {
        @"
CONNECT -I $IP
EXIT
"@ | Set-Content $cmdFile -Encoding ASCII
        
        $result = cmd.exe /c "`"$TNCcmdPath`" < `"$cmdFile`"" 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0 -or $result -notmatch "error|failed|timeout") {
            Write-Log "Connection test successful!" "SUCCESS"
            return $true
        } else {
            Write-Log "Connection test failed: $result" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Connection test error: $_" "ERROR"
        return $false
    }
    finally {
        Remove-Item $cmdFile -ErrorAction SilentlyContinue
    }
}

function Test-RetryableError {
    param([string]$ErrorOutput)
    
    # Patterns that indicate the file is temporarily locked/busy (should retry)
    $retryPatterns = @(
        "locked",
        "in use",
        "access denied",
        "busy",
        "cannot access",
        "being used",
        "sharing violation",
        "file is open",
        "write protected",
        "protection",
        "timeout",
        "connection lost",
        "connection reset"
    )
    
    foreach ($pattern in $retryPatterns) {
        if ($ErrorOutput -match $pattern) {
            return $true
        }
    }
    return $false
}

function Wait-FileReady {
    <#
    .SYNOPSIS
        Waits for a file to be fully written and released by other processes.
    #>
    param(
        [string]$FilePath,
        [int]$TimeoutSeconds = 30
    )
    
    $waited = 0
    while ($waited -lt $TimeoutSeconds) {
        try {
            # Try to open file with exclusive access
            $stream = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
            $stream.Close()
            $stream.Dispose()
            return $true
        }
        catch {
            Start-Sleep -Seconds 1
            $waited++
        }
    }
    return $false
}

function Send-FileToMachine {
    <#
    .SYNOPSIS
        Transfers a file to the CNC machine with retry logic.
    .OUTPUTS
        Hashtable with Success (bool) and Retryable (bool) properties.
    #>
    param(
        [string]$SourceFile,
        [string]$DestinationPath,
        [int]$Attempt = 1
    )
    
    $fileName = [System.IO.Path]::GetFileName($SourceFile)
    $destFile = $DestinationPath.TrimEnd('\', '/') + '\' + $fileName
    
    if ($Attempt -eq 1) {
        Write-Log "Transferring: $fileName -> $destFile"
    } else {
        Write-Log "Retry attempt $Attempt/$MaxRetries for: $fileName"
    }
    
    # Build the PUT command with options
    $putOptions = ""
    if ($UseBinaryMode) { $putOptions += " /b" }
    if ($ConvertNCPrograms) { $putOptions += " /c" }
    
    # Direct command-line execution
    $arguments = @(
        "PUT"
        "`"$SourceFile`""
        "`"$destFile`""
        $putOptions.Trim()
        "-I"
        $MachineIP
    ) -join " "
    
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $TNCcmdPath
        $psi.Arguments = $arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit($ConnectionTimeout * 1000)
        
        $exitCode = $process.ExitCode
        $combinedOutput = "$stdout $stderr".ToLower()
        
        # Success case
        if ($exitCode -eq 0 -and $stderr -eq "") {
            if ($Attempt -gt 1) {
                Write-Log "Transfer successful after $Attempt attempts: $fileName" "SUCCESS"
            } else {
                Write-Log "Transfer successful: $fileName" "SUCCESS"
            }
            return @{ Success = $true; Retryable = $false }
        }
        
        # Check if this is a retryable error (file locked, etc.)
        $isRetryable = Test-RetryableError -ErrorOutput $combinedOutput
        
        if ($isRetryable -and $Attempt -lt $MaxRetries) {
            Write-Log "File appears locked on controller. Waiting ${RetryDelaySeconds}s before retry... (attempt $Attempt/$MaxRetries)" "WARNING"
            if ($stdout) { Write-Log "Output: $stdout" "WARNING" }
            if ($stderr) { Write-Log "Error: $stderr" "WARNING" }
            
            Start-Sleep -Seconds $RetryDelaySeconds
            return Send-FileToMachine -SourceFile $SourceFile -DestinationPath $DestinationPath -Attempt ($Attempt + 1)
        }
        elseif ($isRetryable) {
            # Max retries reached for a retryable error
            Write-Log "Transfer failed after $MaxRetries attempts (file locked): $fileName" "ERROR"
            if ($stdout) { Write-Log "Output: $stdout" "ERROR" }
            if ($stderr) { Write-Log "Error: $stderr" "ERROR" }
            return @{ Success = $false; Retryable = $true }
        }
        else {
            # Non-retryable error (bad path, permission issue, etc.)
            Write-Log "Transfer failed for $fileName (Exit: $exitCode) - non-retryable error" "ERROR"
            if ($stdout) { Write-Log "Output: $stdout" "ERROR" }
            if ($stderr) { Write-Log "Error: $stderr" "ERROR" }
            return @{ Success = $false; Retryable = $false }
        }
    }
    catch {
        Write-Log "Transfer exception for ${fileName}: $_" "ERROR"
        
        # Treat exceptions as potentially retryable (network issues, etc.)
        if ($Attempt -lt $MaxRetries) {
            Write-Log "Retrying after exception... Waiting ${RetryDelaySeconds}s (attempt $Attempt/$MaxRetries)" "WARNING"
            Start-Sleep -Seconds $RetryDelaySeconds
            return Send-FileToMachine -SourceFile $SourceFile -DestinationPath $DestinationPath -Attempt ($Attempt + 1)
        }
        return @{ Success = $false; Retryable = $true }
    }
}

function Move-ProcessedFile {
    <#
    .SYNOPSIS
        Handles post-transfer file movement (delete, move to processed, or move to failed).
    #>
    param(
        [string]$FilePath,
        [bool]$Success
    )
    
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $parentDir = [System.IO.Path]::GetDirectoryName($FilePath)
    
    if ($Success) {
        if ($DeleteAfterTransfer) {
            Remove-Item $FilePath -Force -ErrorAction SilentlyContinue
            Write-Log "Deleted source file: $fileName"
        }
        elseif ($MoveToProcessedFolder) {
            $processedPath = Join-Path $parentDir "Processed\$fileName"
            
            # Handle duplicate filenames
            if (Test-Path $processedPath) {
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                $extension = [System.IO.Path]::GetExtension($fileName)
                $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $processedPath = Join-Path $parentDir "Processed\${baseName}_${timestamp}${extension}"
            }
            
            Move-Item $FilePath $processedPath -Force -ErrorAction SilentlyContinue
            Write-Log "Moved to Processed: $fileName"
        }
    }
    else {
        if ($MoveToFailedFolder) {
            $failedPath = Join-Path $parentDir "Failed\$fileName"
            
            # Handle duplicate filenames
            if (Test-Path $failedPath) {
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                $extension = [System.IO.Path]::GetExtension($fileName)
                $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $failedPath = Join-Path $parentDir "Failed\${baseName}_${timestamp}${extension}"
            }
            
            Move-Item $FilePath $failedPath -Force -ErrorAction SilentlyContinue
            Write-Log "Moved to Failed folder: $fileName" "ERROR"
        }
    }
}

function Process-SingleFile {
    <#
    .SYNOPSIS
        Processes a single file: wait for ready, transfer, move to appropriate folder.
    #>
    param([string]$FilePath)
    
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    
    # Verify file still exists
    if (-not (Test-Path $FilePath)) {
        Write-Log "File no longer exists, skipping: $fileName" "WARNING"
        return
    }
    
    # Wait for file to be fully written
    Write-Log "Waiting for file to be ready: $fileName"
    $ready = Wait-FileReady -FilePath $FilePath -TimeoutSeconds 30
    
    if (-not $ready) {
        Write-Log "File still locked after 30s, skipping: $fileName" "WARNING"
        return
    }
    
    # Transfer the file
    $result = Send-FileToMachine -SourceFile $FilePath -DestinationPath $DestinationFolder
    
    # Handle post-transfer file movement
    Move-ProcessedFile -FilePath $FilePath -Success $result.Success
}

function Initialize-WatchFolder {
    <#
    .SYNOPSIS
        Creates watch folder and subfolders if they don't exist.
    #>
    
    # Create watch folder if it doesn't exist
    if (-not (Test-Path $WatchFolder)) {
        Write-Log "Creating watch folder: $WatchFolder"
        New-Item -Path $WatchFolder -ItemType Directory -Force | Out-Null
    }
    
    # Create processed folder if needed
    if ($MoveToProcessedFolder) {
        $processedFolder = Join-Path $WatchFolder "Processed"
        if (-not (Test-Path $processedFolder)) {
            New-Item -Path $processedFolder -ItemType Directory -Force | Out-Null
        }
    }
    
    # Create failed folder if needed
    if ($MoveToFailedFolder) {
        $failedFolder = Join-Path $WatchFolder "Failed"
        if (-not (Test-Path $failedFolder)) {
            New-Item -Path $failedFolder -ItemType Directory -Force | Out-Null
        }
    }
}

function Process-ExistingFiles {
    <#
    .SYNOPSIS
        Processes any files that already exist in the watch folder on startup.
    #>
    
    $existingFiles = Get-ChildItem -Path $WatchFolder -Filter $FileFilter -File -ErrorAction SilentlyContinue
    
    if ($existingFiles.Count -gt 0) {
        Write-Log "Found $($existingFiles.Count) existing file(s) in watch folder"
        foreach ($file in $existingFiles) {
            Write-Log "Processing existing file: $($file.Name)"
            Process-SingleFile -FilePath $file.FullName
        }
        Write-Log "Finished processing existing files"
        Write-Log ""
    }
}

function Start-SynchronousWatcher {
    <#
    .SYNOPSIS
        Monitors folder using synchronous WaitForChanged() method.
        Simple and reliable, but blocks during file processing.
    #>
    
    Write-Log "Starting SYNCHRONOUS watcher (WaitForChanged mode)"
    Write-Log ""
    
    # Create the FileSystemWatcher
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $WatchFolder
    $watcher.Filter = $FileFilter
    $watcher.IncludeSubdirectories = $false
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName
    
    try {
        while ($true) {
            # Wait for a file creation event (1 second timeout for responsiveness)
            $result = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::Created, 1000)
            
            if (-not $result.TimedOut) {
                $filePath = Join-Path $WatchFolder $result.Name
                Write-Log ""
                Write-Log "New file detected: $($result.Name)"
                
                # Small delay to ensure file write is complete
                Start-Sleep -Milliseconds 500
                
                # Process the file
                Process-SingleFile -FilePath $filePath
                
                Write-Log ""
                Write-Log "Waiting for files... (Press Ctrl+C to stop)"
            }
        }
    }
    finally {
        $watcher.Dispose()
        Write-Log "Synchronous watcher stopped."
    }
}

function Start-AsynchronousWatcher {
    <#
    .SYNOPSIS
        Monitors folder using event-based asynchronous method with a queue.
        Non-blocking, handles rapid file creation without missing events.
    #>
    
    Write-Log "Starting ASYNCHRONOUS watcher (Event Queue mode)"
    Write-Log ""
    
    # Thread-safe queue for detected files
    $global:FileQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    
    # Create the FileSystemWatcher
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $WatchFolder
    $watcher.Filter = $FileFilter
    $watcher.IncludeSubdirectories = $false
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName
    $watcher.EnableRaisingEvents = $true
    
    # Event handler - just queues the file path (fast, no scope issues)
    $action = {
        $filePath = $Event.SourceEventArgs.FullPath
        $global:FileQueue.Enqueue($filePath)
    }
    
    # Register event handler
    $eventJob = Register-ObjectEvent -InputObject $watcher -EventName Created -Action $action -SourceIdentifier "FileCreated"
    
    try {
        while ($true) {
            # Process any files in the queue
            $filePath = $null
            while ($global:FileQueue.TryDequeue([ref]$filePath)) {
                $fileName = [System.IO.Path]::GetFileName($filePath)
                Write-Log ""
                Write-Log "New file detected: $fileName"
                
                # Small delay to ensure file write is complete
                Start-Sleep -Milliseconds 500
                
                # Process the file
                Process-SingleFile -FilePath $filePath
                
                Write-Log ""
                Write-Log "Waiting for files... (Press Ctrl+C to stop)"
            }
            
            # Small sleep to prevent CPU spinning
            # This keeps PowerShell responsive to events while not burning CPU
            Start-Sleep -Milliseconds 200
        }
    }
    finally {
        # Cleanup
        Unregister-Event -SourceIdentifier "FileCreated" -ErrorAction SilentlyContinue
        Remove-Job -Name "FileCreated" -Force -ErrorAction SilentlyContinue
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
        Write-Log "Asynchronous watcher stopped."
    }
}

function Start-FolderWatcher {
    <#
    .SYNOPSIS
        Main entry point - initializes and starts the folder watcher.
    #>
    
    Write-Log "=============================================="
    Write-Log "Heidenhain TNCcmd Folder Watcher v1.1.0"
    Write-Log "=============================================="
    Write-Log "Watcher Mode:    $WatcherMode"
    Write-Log "Machine IP:      $MachineIP"
    Write-Log "Watch Folder:    $WatchFolder"
    Write-Log "Destination:     $DestinationFolder"
    Write-Log "File Filter:     $FileFilter"
    Write-Log "Retry Settings:  $MaxRetries attempts, ${RetryDelaySeconds}s delay"
    Write-Log "=============================================="
    
    # Initialize folders
    Initialize-WatchFolder
    
    # Process any existing files
    Process-ExistingFiles
    
    Write-Log "Waiting for files... (Press Ctrl+C to stop)"
    Write-Log ""
    
    # Start the appropriate watcher based on configuration
    switch ($WatcherMode) {
        "Synchronous" {
            Start-SynchronousWatcher
        }
        "Asynchronous" {
            Start-AsynchronousWatcher
        }
        default {
            Write-Log "Invalid WatcherMode: $WatcherMode. Use 'Synchronous' or 'Asynchronous'." "ERROR"
            exit 1
        }
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

# Clear screen and show header
Clear-Host
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Heidenhain TNCcmd Automatic File Transfer - Folder Watcher   " -ForegroundColor Cyan
Write-Host "  Mode: $WatcherMode" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Verify TNCcmd is installed
if (-not (Test-TNCcmd)) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# Optional: Test connection to machine (uncomment to enable)
# if (-not (Test-MachineConnection -IP $MachineIP)) {
#     Write-Log "Cannot connect to machine. Check IP address and network." "ERROR"
#     Write-Host "Press any key to exit..."
#     $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
#     exit 1
# }

# Start the folder watcher
try {
    Start-FolderWatcher
}
catch {
    Write-Log "Fatal error: $_" "ERROR"
    exit 1
}
```

---

## Script 2: Simple Batch File Alternative

**Best for**: Manual transfers or scheduled tasks (runs once and exits)

### Full Script: TNCcmd-SendFile.bat

```batch
@echo off
REM ============================================================================
REM  TNCcmd Simple File Transfer
REM  Version: 1.0.0
REM  Date:    2026-03-12
REM  Author:  Xander Luciano
REM ============================================================================
REM Heidenhain TNCcmd - Simple File Transfer Batch Script
REM ============================================================================
REM This is a simpler alternative to the PowerShell watcher.
REM It sends all files from a folder to the CNC machine when run.
REM 
REM Usage: 
REM   - Edit the settings below
REM   - Double-click to run, or schedule with Windows Task Scheduler
REM   - For continuous monitoring, use the PowerShell script instead
REM ============================================================================

REM ====================== CONFIGURATION ======================================

REM Machine IP address
set MACHINE_IP=192.168.1.100

REM Source folder (folder containing files to send)
REM Use %~dp0 for the same folder as this batch file
set SOURCE_FOLDER=%~dp0WatchFolder

REM Destination folder on the CNC machine
set DEST_FOLDER=TNC:\

REM File pattern to send (*.h for NC programs, *.* for all)
set FILE_PATTERN=*.*

REM TNCcmd.exe location
set TNCCMD="C:\Program Files (x86)\HEIDENHAIN\TNCremo\TNCcmd.exe"

REM Transfer mode: /b for binary (recommended), /c for convert NC programs
set TRANSFER_MODE=/b

REM Delete files after successful transfer? (YES or NO)
set DELETE_AFTER=NO

REM ====================== END CONFIGURATION ==================================

echo.
echo ============================================
echo  Heidenhain TNCcmd File Transfer
echo ============================================
echo  Machine: %MACHINE_IP%
echo  Source:  %SOURCE_FOLDER%
echo  Dest:    %DEST_FOLDER%
echo ============================================
echo.

REM Check if TNCcmd exists
if not exist %TNCCMD% (
    echo ERROR: TNCcmd.exe not found at %TNCCMD%
    echo Please install TNCremo from Heidenhain website.
    echo.
    pause
    exit /b 1
)

REM Check if source folder exists
if not exist "%SOURCE_FOLDER%" (
    echo Creating source folder: %SOURCE_FOLDER%
    mkdir "%SOURCE_FOLDER%"
)

REM Create processed folder
if not exist "%SOURCE_FOLDER%\Processed" (
    mkdir "%SOURCE_FOLDER%\Processed"
)

REM Count files
set FILE_COUNT=0
for %%f in ("%SOURCE_FOLDER%\%FILE_PATTERN%") do (
    if exist "%%f" set /a FILE_COUNT+=1
)

if %FILE_COUNT%==0 (
    echo No files found in %SOURCE_FOLDER%
    echo.
    pause
    exit /b 0
)

echo Found %FILE_COUNT% file(s) to transfer...
echo.

REM Process each file
for %%f in ("%SOURCE_FOLDER%\%FILE_PATTERN%") do (
    if exist "%%f" (
        echo Transferring: %%~nxf
        
        REM Execute the transfer
        %TNCCMD% PUT "%%f" "%DEST_FOLDER%%%~nxf" %TRANSFER_MODE% -I %MACHINE_IP%
        
        if %ERRORLEVEL%==0 (
            echo   SUCCESS: %%~nxf transferred
            
            if /i "%DELETE_AFTER%"=="YES" (
                del "%%f"
                echo   Deleted source file
            ) else (
                move "%%f" "%SOURCE_FOLDER%\Processed\" >nul 2>&1
                echo   Moved to Processed folder
            )
        ) else (
            echo   FAILED: %%~nxf - Error code %ERRORLEVEL%
        )
        echo.
    )
)

echo ============================================
echo  Transfer complete
echo ============================================
echo.
pause
```

---

## TNCcmd Command Reference

### Basic Commands

```bash
# Connect to machine
TNCcmd.exe CONNECT -I 192.168.1.100

# Upload file to machine
TNCcmd.exe PUT "C:\file.h" "TNC:\file.h" -I 192.168.1.100

# Upload with binary mode (recommended)
TNCcmd.exe PUT "C:\file.h" "TNC:\file.h" /b -I 192.168.1.100

# Download file from machine
TNCcmd.exe GET "TNC:\file.h" "C:\file.h" -I 192.168.1.100

# Create directory on machine
TNCcmd.exe MKDIR "TNC:\MyFolder" -I 192.168.1.100

# List files on machine
TNCcmd.exe DIR "TNC:\*.*" -I 192.168.1.100
```

### Command-Line Options

| Option | Description |
|--------|-------------|
| `-I <IP>` | Machine IP address |
| `-P <port>` | Port number (default 19000) |
| `/b` | Binary transfer mode (recommended) |
| `/c` | Convert NC programs (.H, .I) during transfer |
| `-C <name>` | Connection name from TNCremo |

### Machine Paths

The CNC machine uses paths starting with `TNC:\`:
- `TNC:\` - Root directory
- `TNC:\nc_prog\` - Common program folder
- `TNC:\table\` - Tables folder
- `TNC:\Programs\` - Another common location

**Note**: Path structure varies by controller model and configuration.

---

## Common File Types

| Extension | Description |
|-----------|-------------|
| `.H` | Heidenhain conversational NC program |
| `.I` | ISO/DIN NC program |
| `.T` | Tool table |
| `.D` | Datum/fixture table |
| `.TCH` | TNCguide technology data |

---

## Troubleshooting

### "TNCcmd.exe not found"
- Install TNCremo from the Heidenhain website
- Check the installation path in the script configuration

### "Connection timeout" or "Cannot connect"
1. Verify machine IP address is correct
2. Ping the machine: `ping 192.168.1.100`
3. Check firewall allows port 19000
4. Verify machine's network settings
5. Ensure DNC option is enabled on controller

### "Access denied" or "File locked" errors
- The PowerShell script will automatically retry for up to 75 minutes (150 attempts × 30 seconds)
- Machine may require DNC to be enabled manually
- Check machine's security/access settings
- Some operations require the machine to be in specific mode

### Files not transferring
- Check file extensions match the filter
- Verify source files aren't locked by another program
- Check the log file for error details

### PowerShell script won't run
```powershell
# Allow script execution (run as Administrator)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Or run with bypass
powershell -ExecutionPolicy Bypass -File ".\TNCcmd-FolderWatcher.ps1"
```

### File watcher doesn't detect pasted files (v1.0.0 issue)
**Fixed in v1.1.0** — The original async event handler had scope issues that could cause it to miss events. Solutions:
1. **Upgrade to v1.1.0** (recommended)
2. Set `$WatcherMode = "Synchronous"` for simpler event handling
3. Use the new async queue mode (default in v1.1.0) which properly decouples detection from processing

---

## Running as a Windows Service

For 24/7 operation, you can run the PowerShell script as a Windows Service using NSSM:

1. Download NSSM: https://nssm.cc/
2. Install as service:
   ```cmd
   nssm install TNCcmdWatcher "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
   nssm set TNCcmdWatcher AppParameters "-ExecutionPolicy Bypass -File C:\path\to\TNCcmd-FolderWatcher.ps1"
   nssm set TNCcmdWatcher AppDirectory "C:\path\to"
   nssm start TNCcmdWatcher
   ```

---

## Using Task Scheduler

1. Open Task Scheduler
2. Create Basic Task
3. Set trigger (e.g., "At startup" for continuous monitoring)
4. Action: Start a program
5. Program: `powershell.exe`
6. Arguments: `-ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\TNCcmd-FolderWatcher.ps1"`

---

## Resources

- **TNCremo Download**: https://www.heidenhain.com/products/cnc-controls/software/tncremo
- **Heidenhain Support**: https://www.heidenhain.com/service-support
- **LSV2 Protocol Info**: Included in TNCremo documentation
