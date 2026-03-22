#Requires -Version 5.1
<#
================================================================================
  TNCcmd Folder Watcher
  Version: 1.2.0
  Date:    2026-03-19
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
# - Or specify a full path like "C:\NCPrograms\ToMachine" or a UNC path like "\\Server\Share\Folder"

# File filter - which files to watch for
# - "*.h" for Heidenhain NC programs only
# - "*.H" for uppercase extension
# - "*.*" for all files
$FileFilter = "*.*"

# Include subdirectories - watch for files in subfolders recursively
# - $true:  Monitors all subfolders, preserving folder structure on CNC destination
# - $false: Only monitors files placed directly in the watch folder
$IncludeSubdirectories = $true

# ------------------------------
# TRANSFER OPTIONS
# ------------------------------

$UseBinaryMode = $true           # Use /b flag for binary transfer (recommended)
$ConvertNCPrograms = $false      # Use /c flag to convert .H/.I files during transfer
$DeleteBeforeTransfer = $true    # DEL existing file on controller before PUT (ensures clean overwrite)
                                 # NOTE: Overwriting files that are OPEN on the controller requires
                                 #       TNCcmdPlus (purchased USB dongle + Option #18 HEIDENHAIN DNC).
                                 #       With TNCcmd Essential, open files will retry until closed.
$DeleteAfterTransfer = $true    # Delete source file after successful transfer
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
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    switch ($Level) {
        "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        "DEBUG"   { Write-Host $logMessage -ForegroundColor DarkGray }
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
    # Includes Heidenhain LSV2 error codes from TNCcmd
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
        "connection reset",
        "e20001721",       # File cannot be opened (file open on controller)
        "e20001724",       # File cannot be deleted (write-protected or open)
        "e2000172d",       # File access not possible
        "e2000173b",       # No write-access
        "e2000173c",       # NC still active: Function cannot be executed
        "e2000175a"        # Transmission still active
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

function Remove-RemoteFile {
    <#
    .SYNOPSIS
        Attempts to delete a file on the CNC controller via TNCcmd DEL command.
        Used before PUT to ensure a clean overwrite. Failures are non-fatal.
    .OUTPUTS
        $true if DEL succeeded or file didn't exist, $false if file is locked/open.
    #>
    param(
        [string]$RemoteFilePath
    )
    
    $arguments = "DEL `"$RemoteFilePath`" -I $MachineIP"
    
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
        
        $combinedOutput = "$stdout $stderr".ToLower()
        
        if ($process.ExitCode -eq 0 -and $stderr -eq "") {
            Write-Log "DEL succeeded: $RemoteFilePath" "DEBUG"
            return $true
        }
        
        # File doesn't exist - that's fine, PUT will create it
        if ($combinedOutput -match "e20001720|does not exist") {
            Write-Log "File does not exist on controller (will be created): $RemoteFilePath" "DEBUG"
            return $true
        }
        
        # File is locked/open on controller - DEL can't help, PUT will also fail
        if ($combinedOutput -match "e20001724|cannot be deleted|e20001721|cannot be opened") {
            Write-Log "File is open/locked on controller, cannot delete before overwrite: $RemoteFilePath" "WARNING"
            return $false
        }
        
        # Other error - log but continue with PUT anyway
        Write-Log "DEL returned unexpected result (proceeding with PUT): $combinedOutput" "WARNING"
        return $true
    }
    catch {
        Write-Log "DEL exception (proceeding with PUT): $_" "WARNING"
        return $true
    }
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
    
    # Delete existing file before PUT to ensure clean overwrite
    if ($DeleteBeforeTransfer -and $Attempt -eq 1) {
        $delResult = Remove-RemoteFile -RemoteFilePath $destFile
        if (-not $delResult) {
            Write-Log "File is locked on controller - will attempt PUT anyway (retry logic will handle)" "WARNING"
        }
    }
    
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
    
    # Compute relative path from watch folder for subfolder structure preservation
    $watchBase = $WatchFolder.TrimEnd('\', '/')
    $relativePath = $FilePath.Substring($watchBase.Length + 1)
    $relativeDir = [System.IO.Path]::GetDirectoryName($relativePath)
    
    if ($Success) {
        if ($DeleteAfterTransfer) {
            Remove-Item $FilePath -Force -ErrorAction SilentlyContinue
            Write-Log "Deleted source file: $fileName"
        }
        elseif ($MoveToProcessedFolder) {
            # Preserve subfolder structure inside Processed folder
            $processedBase = Join-Path $WatchFolder "Processed"
            if ($relativeDir) {
                $processedBase = Join-Path $processedBase $relativeDir
                if (-not (Test-Path $processedBase)) {
                    New-Item -Path $processedBase -ItemType Directory -Force | Out-Null
                }
            }
            $processedPath = Join-Path $processedBase $fileName
            
            # Handle duplicate filenames
            if (Test-Path $processedPath) {
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                $extension = [System.IO.Path]::GetExtension($fileName)
                $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $processedPath = Join-Path $processedBase "${baseName}_${timestamp}${extension}"
            }
            
            Move-Item $FilePath $processedPath -Force -ErrorAction SilentlyContinue
            Write-Log "Moved to Processed: $relativePath"
        }
    }
    else {
        if ($MoveToFailedFolder) {
            # Preserve subfolder structure inside Failed folder
            $failedBase = Join-Path $WatchFolder "Failed"
            if ($relativeDir) {
                $failedBase = Join-Path $failedBase $relativeDir
                if (-not (Test-Path $failedBase)) {
                    New-Item -Path $failedBase -ItemType Directory -Force | Out-Null
                }
            }
            $failedPath = Join-Path $failedBase $fileName
            
            # Handle duplicate filenames
            if (Test-Path $failedPath) {
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                $extension = [System.IO.Path]::GetExtension($fileName)
                $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $failedPath = Join-Path $failedBase "${baseName}_${timestamp}${extension}"
            }
            
            Move-Item $FilePath $failedPath -Force -ErrorAction SilentlyContinue
            Write-Log "Moved to Failed folder: $relativePath" "ERROR"
        }
    }
}

function New-RemoteDirectory {
    <#
    .SYNOPSIS
        Creates a directory tree on the CNC machine using TNCcmd MKDIR.
        Creates each intermediate directory level so parent folders are
        guaranteed to exist before children. Silently succeeds if a
        directory already exists.
    .PARAMETER RemotePath
        Full remote path, e.g. "TNC:\nc_prog\Outpost\Hinge Stop"
    .PARAMETER BasePath
        The portion of the path that already exists on the controller,
        e.g. "TNC:\nc_prog". Only directories below this are created.
    #>
    param(
        [string]$RemotePath,
        [string]$BasePath = $DestinationFolder
    )
    
    # Normalise separators and trim trailing slashes
    $base = $BasePath.TrimEnd('\', '/').Replace('/', '\')
    $full = $RemotePath.TrimEnd('\', '/').Replace('/', '\')
    
    # Nothing to create if the path equals the base
    if ($full -eq $base) { return }
    
    # Get the relative portion (e.g. "Outpost\Hinge Stop")
    $relative = $full.Substring($base.Length + 1)
    $parts = $relative -split '\\'
    
    # Create each directory level using direct command-line execution
    # (same approach as Send-FileToMachine for maximum compatibility)
    $current = $base
    foreach ($part in $parts) {
        $current = "$current\$part"
        
        $arguments = "MKDIR `"$current`" -I $MachineIP"
        
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
            
            if ($process.ExitCode -eq 0) {
                Write-Log "Created remote directory: $current" "SUCCESS"
            } else {
                # MKDIR returns an error if directory already exists - that's OK
                Write-Log "MKDIR '$current' returned exit $($process.ExitCode) (may already exist)" "WARNING"
                if ($stderr) { Write-Log "  MKDIR stderr: $stderr" "WARNING" }
            }
        }
        catch {
            Write-Log "MKDIR exception for '$current': $_" "WARNING"
        }
    }
}

function Process-SingleFile {
    <#
    .SYNOPSIS
        Processes a single file: wait for ready, transfer, move to appropriate folder.
        Supports subfolder structure - preserves relative paths on CNC destination.
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
    
    # Compute destination path, preserving subfolder structure
    $watchBase = $WatchFolder.TrimEnd('\', '/')
    $relativePath = $FilePath.Substring($watchBase.Length + 1)
    $relativeDir = [System.IO.Path]::GetDirectoryName($relativePath)
    
    if ($relativeDir) {
        # File is in a subfolder - mirror the structure on the CNC
        $destPath = $DestinationFolder.TrimEnd('\', '/') + '\' + $relativeDir.Replace('/', '\')
        Write-Log "Creating remote directory: $destPath"
        New-RemoteDirectory -RemotePath $destPath
    } else {
        $destPath = $DestinationFolder
    }
    
    # Transfer the file
    $result = Send-FileToMachine -SourceFile $FilePath -DestinationPath $destPath
    
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
    
    $gciParams = @{
        Path        = $WatchFolder
        Filter      = $FileFilter
        File        = $true
        ErrorAction = 'SilentlyContinue'
    }
    if ($IncludeSubdirectories) { $gciParams['Recurse'] = $true }
    
    # Exclude files already in Processed or Failed folders
    $existingFiles = Get-ChildItem @gciParams | Where-Object {
        $rel = $_.FullName.Substring($WatchFolder.TrimEnd('\', '/').Length + 1)
        $rel -notmatch '^(Processed|Failed)(\\|/)'
    }
    
    if ($existingFiles.Count -gt 0) {
        Write-Log "Found $($existingFiles.Count) existing file(s) in watch folder"
        foreach ($file in $existingFiles) {
            $rel = $file.FullName.Substring($WatchFolder.TrimEnd('\', '/').Length + 1)
            Write-Log "Processing existing file: $rel"
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
    $watcher.IncludeSubdirectories = $IncludeSubdirectories
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName
    
    try {
        while ($true) {
            # Wait for a file creation event (1 second timeout for responsiveness)
            $result = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::Created, 1000)
            
            if (-not $result.TimedOut) {
                # Skip files created in Processed or Failed subfolders
                if ($result.Name -match '^(Processed|Failed)(\\|/)') { continue }
                
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
    $watcher.IncludeSubdirectories = $IncludeSubdirectories
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName
    $watcher.EnableRaisingEvents = $true
    
    # Event handler - just queues the file path (fast, no scope issues)
    # Skips files created in Processed or Failed subfolders
    $action = {
        $name = $Event.SourceEventArgs.Name
        if ($name -notmatch '^(Processed|Failed)(\\|/)') {
            $filePath = $Event.SourceEventArgs.FullPath
            $global:FileQueue.Enqueue($filePath)
        }
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
    Write-Log "Heidenhain TNCcmd Folder Watcher v1.2.0"
    Write-Log "=============================================="
    Write-Log "Watcher Mode:    $WatcherMode"
    Write-Log "Machine IP:      $MachineIP"
    Write-Log "Watch Folder:    $WatchFolder"
    Write-Log "Destination:     $DestinationFolder"
    Write-Log "File Filter:     $FileFilter"
    Write-Log "Subdirectories:  $IncludeSubdirectories"
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
