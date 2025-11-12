<#
.SYNOPSIS
    Log Consolidation Script - Monitors rotating log files and consolidates them into a single file
    
.DESCRIPTION
    This script continuously monitors a source folder for rotating log files (e.g., ADSI.20251111.log)
    and consolidates new content into a single output file. It tracks file positions to avoid
    duplicate processing and handles file truncation scenarios.
    
    CUSTOMIZATION: Modify the CONFIGURATION section below to adjust paths, intervals, and patterns.
    
.PARAMETER OutputFileName
    Name of the consolidated output file (default: "consolidated_adsi.log")
    
.PARAMETER LogPattern
    File pattern to match log files (default: "ADSI*.log")
    
.PARAMETER RetentionDays
    Number of days to retain files in state tracking (default: 14)
    
.PARAMETER PollInterval
    Seconds between folder scans (default: 60)
    
.EXAMPLE
    .\Log_consolidation.ps1
    
.EXAMPLE
    .\Log_consolidation.ps1 -OutputFileName "my_consolidated.log" -PollInterval 30
#>

param(
    [string]$OutputFileName = $null,      # If null, uses Config.OutputFileName
    [string]$LogPattern = $null,          # If null, uses Config.LogPattern
    [int]$RetentionDays = 0,               # If 0, uses Config.RetentionDays
    [int]$PollInterval = 0                # If 0, uses Config.PollInterval
)

# ============================================================================
# CONFIGURATION SECTION - CUSTOMIZE THESE PARAMETERS FOR YOUR ENVIRONMENT
# ============================================================================

$Config = @{
    # ========================================================================
    # PATH CONFIGURATION
    # ========================================================================
    
    # Base directory - Set to $null to use script's directory, or specify absolute path
    # Example: "C:\Logs" or $null (uses script directory)
    BaseDirectory = $null
    
    # Source folder containing rotating log files
    # Relative to BaseDirectory, or absolute path
    # Example: "SourceLogs" or "C:\Logs\SourceLogs"
    SourceFolder = "SourceLogs"
    
    # Output folder for consolidated file
    # Relative to BaseDirectory, or absolute path
    # Example: "Consolidated" or "C:\Logs\Consolidated"
    ConsolidatedFolder = "Consolidated"
    
    # Name of the consolidated output file
    # Example: "consolidated_adsi.log"
    OutputFileName = "consolidated_adsi.log"
    
    # State file name (stores tracking information)
    # Example: "last_state.json"
    StateFileName = "last_state.json"
    
    # ========================================================================
    # FILE PATTERN CONFIGURATION
    # ========================================================================
    
    # Pattern to match log files (supports wildcards)
    # Example: "ADSI*.log", "app_*.log", "*.log"
    LogPattern = "ADSI*.log"
    
    # Regular expression to extract date from filename
    # Default matches: ADSI.yyyyMMdd.log (e.g., ADSI.20251111.log)
    # Modify if your filename format is different
    # Example for "app_2025-11-11.log": 'app_(\d{4}-\d{2}-\d{2})\.log'
    DatePattern = 'ADSI\.(\d{8})\.log'
    
    # Date format in filename (must match DatePattern extraction)
    # Default: "yyyyMMdd" for ADSI.20251111.log
    # Example for "app_2025-11-11.log": "yyyy-MM-dd"
    DateFormat = "yyyyMMdd"
    
    # ========================================================================
    # TIMING CONFIGURATION
    # ========================================================================
    
    # Number of days to retain files in state tracking
    # Files older than this will be removed from tracking
    # Example: 14 (for 2 weeks), 30 (for 1 month)
    RetentionDays = 14
    
    # Seconds between folder scans
    # Lower values = more frequent checks (higher CPU usage)
    # Higher values = less frequent checks (lower CPU usage)
    # Example: 60 (1 minute), 300 (5 minutes), 10 (10 seconds)
    PollInterval = 60
    
    # ========================================================================
    # FILE HANDLING CONFIGURATION
    # ========================================================================
    
    # Maximum retry attempts for file lock operations
    # Increase if you experience frequent lock errors
    MaxRetryAttempts = 3
    
    # Milliseconds to wait between retry attempts
    RetryDelayMs = 150
    
    # File encoding for reading/writing
    # Options: "UTF8", "ASCII", "Unicode", "UTF32"
    FileEncoding = "UTF8"
    
    # ========================================================================
    # LOGGING CONFIGURATION
    # ========================================================================
    
    # Enable verbose output (shows detailed processing information)
    VerboseOutput = $true
    
    # Color-coded console output
    EnableColors = $true
}

# ============================================================================
# END OF CONFIGURATION SECTION
# ============================================================================

# Override config with command-line parameters if provided
if ($OutputFileName) { $Config.OutputFileName = $OutputFileName }
if ($LogPattern) { $Config.LogPattern = $LogPattern }
if ($RetentionDays -gt 0) { $Config.RetentionDays = $RetentionDays }
if ($PollInterval -gt 0) { $Config.PollInterval = $PollInterval }

# ============================================================================
# INITIALIZATION - Build paths from configuration
# ============================================================================

function Initialize-Paths {
    # Determine base directory
    if ($Config.BaseDirectory) {
        $script:BaseDir = $Config.BaseDirectory
    } else {
        # Use $PSScriptRoot if available (PowerShell 3.0+), otherwise fall back to other methods
        if ($PSScriptRoot) {
            $script:BaseDir = $PSScriptRoot
        } elseif ($MyInvocation.MyCommand.Path) {
            $script:BaseDir = Split-Path $MyInvocation.MyCommand.Path -Parent
        } elseif ($MyInvocation.PSScriptRoot) {
            $script:BaseDir = $MyInvocation.PSScriptRoot
        } else {
            # Last resort: use current working directory
            $script:BaseDir = Get-Location | Select-Object -ExpandProperty Path
            Write-Host "Warning: Could not determine script directory. Using current directory: $script:BaseDir" -ForegroundColor Yellow
        }
    }
    
    # Validate and normalize base directory
    if ([string]::IsNullOrWhiteSpace($script:BaseDir)) {
        throw "Cannot determine base directory. Please set Config.BaseDirectory explicitly."
    }
    
    # Normalize the path (resolve relative paths, remove trailing slashes, etc.)
    try {
        $script:BaseDir = [System.IO.Path]::GetFullPath($script:BaseDir)
    } catch {
        throw "Invalid base directory path: $script:BaseDir. Error: $($_.Exception.Message)"
    }
    
    # Build source folder path
    if ([System.IO.Path]::IsPathRooted($Config.SourceFolder)) {
        $script:SourceFolder = $Config.SourceFolder
    } else {
        $script:SourceFolder = Join-Path $BaseDir $Config.SourceFolder
    }
    
    # Build consolidated folder path
    if ([System.IO.Path]::IsPathRooted($Config.ConsolidatedFolder)) {
        $script:ConsolidatedFolder = $Config.ConsolidatedFolder
    } else {
        $script:ConsolidatedFolder = Join-Path $BaseDir $Config.ConsolidatedFolder
    }
    
    # Build consolidated file path
    $script:ConsolidatedFile = Join-Path $ConsolidatedFolder $Config.OutputFileName
    
    # Build state file path
    $script:StateFile = Join-Path $ConsolidatedFolder $Config.StateFileName
    
    # Validate all paths are set
    if ([string]::IsNullOrWhiteSpace($script:SourceFolder)) {
        throw "Source folder path is null or empty. Check Config.SourceFolder setting."
    }
    if ([string]::IsNullOrWhiteSpace($script:ConsolidatedFolder)) {
        throw "Consolidated folder path is null or empty. Check Config.ConsolidatedFolder setting."
    }
    if ([string]::IsNullOrWhiteSpace($script:ConsolidatedFile)) {
        throw "Consolidated file path is null or empty. Check Config.OutputFileName setting."
    }
    if ([string]::IsNullOrWhiteSpace($script:StateFile)) {
        throw "State file path is null or empty. Check Config.StateFileName setting."
    }
    
    # Normalize paths
    try {
        $script:SourceFolder = [System.IO.Path]::GetFullPath($script:SourceFolder)
        $script:ConsolidatedFolder = [System.IO.Path]::GetFullPath($script:ConsolidatedFolder)
        $script:ConsolidatedFile = [System.IO.Path]::GetFullPath($script:ConsolidatedFile)
        $script:StateFile = [System.IO.Path]::GetFullPath($script:StateFile)
    } catch {
        throw "Error normalizing paths: $($_.Exception.Message)"
    }

# Ensure folders exist
    if (!(Test-Path $SourceFolder)) {
        New-Item -ItemType Directory -Path $SourceFolder -Force | Out-Null
        Write-Host "Created source folder: $SourceFolder" -ForegroundColor Yellow
    }
    if (!(Test-Path $ConsolidatedFolder)) {
        New-Item -ItemType Directory -Path $ConsolidatedFolder -Force | Out-Null
        Write-Host "Created consolidated folder: $ConsolidatedFolder" -ForegroundColor Yellow
    }
}

# ============================================================================
# MODULE 1: DATE UTILITIES
# ============================================================================

function Get-DateFromFileName {
    <#
    .SYNOPSIS
        Extracts date string from filename using configured pattern
    #>
    param([string]$FileName)
    
    if ($FileName -match $Config.DatePattern) {
        return $matches[1]
    }
    return $null
}

function Test-DateInRetention {
    <#
    .SYNOPSIS
        Checks if a date string is within the retention period
    #>
    param(
        [string]$DateString,  # Date string extracted from filename
        [int]$Days            # Retention days
    )
    
    try {
        $FileDate = [DateTime]::ParseExact($DateString, $Config.DateFormat, $null)
        $CutoffDate = (Get-Date).AddDays(-$Days)
        return $FileDate -ge $CutoffDate
    } catch {
        return $false
    }
}

# ============================================================================
# MODULE 2: FILE I/O OPERATIONS
# ============================================================================

function Read-NewBytes {
    <#
    .SYNOPSIS
        Reads new content from a file starting at a specific byte offset
        Uses ReadWrite sharing to allow concurrent access
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][long]$Offset
    )
    
    if (!(Test-Path $Path)) { return "" }
    
    $fs = $null
    $sr = $null
    try {
        # Get encoding object
        $encoding = [System.Text.Encoding]::UTF8
        if ($Config.FileEncoding -eq "ASCII") { $encoding = [System.Text.Encoding]::ASCII }
        elseif ($Config.FileEncoding -eq "Unicode") { $encoding = [System.Text.Encoding]::Unicode }
        elseif ($Config.FileEncoding -eq "UTF32") { $encoding = [System.Text.Encoding]::UTF32 }
        
        # Open with ReadWrite sharing to allow concurrent access
        $fs = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        
        if ($Offset -gt 0) {
            $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        }
        
        $sr = New-Object System.IO.StreamReader($fs, $encoding, $true)
        return $sr.ReadToEnd()
        
    } catch {
        if ($Config.VerboseOutput) {
        Write-Host "Warning: Failed to read from ${Path}: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        return ""
    } finally {
        if ($sr -ne $null) { $sr.Close() }
        if ($fs -ne $null) { $fs.Close() }
    }
}

function Append-ContentShared {
    <#
    .SYNOPSIS
        Appends content to a file with retry logic for lock handling
        Uses ReadWrite sharing to allow concurrent access
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Value
    )
    
    if ([string]::IsNullOrEmpty($Value)) { return }
    
    $attempts = 0
    while ($true) {
        $fs = $null
        $sw = $null
        try {
            # Get encoding object
            $encoding = [System.Text.Encoding]::UTF8
            if ($Config.FileEncoding -eq "ASCII") { $encoding = [System.Text.Encoding]::ASCII }
            elseif ($Config.FileEncoding -eq "Unicode") { $encoding = [System.Text.Encoding]::Unicode }
            elseif ($Config.FileEncoding -eq "UTF32") { $encoding = [System.Text.Encoding]::UTF32 }
            
            # Open with ReadWrite sharing
            $fs = New-Object System.IO.FileStream(
                $Path,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            
            $sw = New-Object System.IO.StreamWriter($fs, $encoding)
            $sw.Write($Value)
            $sw.Flush()
            return
            
        } catch {
            $attempts++
            if ($attempts -ge $Config.MaxRetryAttempts) {
                throw
            }
            Start-Sleep -Milliseconds $Config.RetryDelayMs
        } finally {
            if ($sw -ne $null) { $sw.Close() }
            if ($fs -ne $null) { $fs.Close() }
        }
    }
}

# ============================================================================
# MODULE 3: STATE MANAGEMENT
# ============================================================================

function Load-State {
    <#
    .SYNOPSIS
        Loads state from JSON file, tracking file positions and dates
    #>
$State = @{
        files = @{}  # Dictionary: filename -> { size: long, date: string }
        lastUpdate = (Get-Date).ToUniversalTime().ToString("o")
}
    
if (Test-Path $StateFile) {
    try {
        $raw = Get-Content $StateFile -ErrorAction Stop | Out-String
        $parsed = $raw | ConvertFrom-Json
            
            if ($parsed -and $parsed.files) {
                # Convert PSCustomObject to hashtable
                $parsed.files.PSObject.Properties | ForEach-Object {
                    $State.files[$_.Name] = @{
                        size = [long]$_.Value.size
                        date = [string]$_.Value.date
                    }
                }
            }
            
            if ($parsed.lastUpdate) {
                $State.lastUpdate = $parsed.lastUpdate
            }
            
    } catch {
        Write-Host "Warning: State file unreadable; starting fresh. $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

    return $State
}

function Save-State {
    <#
    .SYNOPSIS
        Saves state to JSON file
    #>
    param([hashtable]$State)
    
    $StateToSave = @{
        files = $State.files
        lastUpdate = (Get-Date).ToUniversalTime().ToString("o")
    }
    
    $StateToSave | ConvertTo-Json -Depth 10 | Set-Content -Path $StateFile -Encoding UTF8
}

function Cleanup-OldState {
    <#
    .SYNOPSIS
        Removes files from state that are outside the retention period
    #>
    param([hashtable]$State)
    
    $FilesToRemove = @()
    foreach ($FileName in $State.files.Keys) {
        $FileDate = $State.files[$FileName].date
        if ($FileDate -and !(Test-DateInRetention -DateString $FileDate -Days $Config.RetentionDays)) {
            $FilesToRemove += $FileName
        }
    }
    
    foreach ($FileName in $FilesToRemove) {
        $State.files.Remove($FileName)
        if ($Config.VerboseOutput) {
            Write-Host "Removed old file from state (outside $($Config.RetentionDays) days): $FileName" -ForegroundColor DarkGray
        }
    }
}

# ============================================================================
# MODULE 4: FILE PROCESSING
# ============================================================================

function Process-File {
    <#
    .SYNOPSIS
        Processes a single log file - reads new content and appends to consolidated file
    #>
    param(
        [string]$FilePath,
        [hashtable]$State
    )
    
    $FileName = Split-Path $FilePath -Leaf
    $FileDate = Get-DateFromFileName -FileName $FileName
    
    # Validate date extraction
    if (!$FileDate) {
        if ($Config.VerboseOutput) {
            Write-Host "Skipping file with invalid date format: $FileName" -ForegroundColor Yellow
        }
        return $false
    }
    
    # Check retention period
    if (!(Test-DateInRetention -DateString $FileDate -Days $Config.RetentionDays)) {
        if ($Config.VerboseOutput) {
            Write-Host "Skipping file outside retention period ($($Config.RetentionDays) days): $FileName (date: $FileDate)" -ForegroundColor DarkGray
        }
        return $false
    }
    
    # Verify file exists
    if (!(Test-Path $FilePath)) {
        Write-Host "File not found: $FilePath" -ForegroundColor Yellow
        return $false
    }
    
    $CurrentSize = (Get-Item $FilePath).Length
    $LastSize = 0L
    
    # Get last processed size from state
    if ($State.files.ContainsKey($FileName)) {
        $LastSize = $State.files[$FileName].size
    }
    
    # Detect truncation: if file is smaller than last processed size, start over
    if ($CurrentSize -lt $LastSize) {
        Write-Host "Detected file truncation for $FileName. Resetting last processed size from $LastSize to 0." -ForegroundColor Yellow
        $LastSize = 0
    }
    
    # Read new content if file has grown
    if ($CurrentSize -gt $LastSize) {
        $NewContent = Read-NewBytes -Path $FilePath -Offset $LastSize
        if ($NewContent -and $NewContent.Trim()) {
            Append-ContentShared -Path $ConsolidatedFile -Value $NewContent
            $BytesRead = $CurrentSize - $LastSize
            Write-Host "Appended content from $FileName (date: $FileDate, new bytes: $BytesRead) to $ConsolidatedFile" -ForegroundColor Green
        }
        
        # Update state with new size
        $State.files[$FileName] = @{
            size = $CurrentSize
            date = $FileDate
        }
        return $true
    } else {
        # File hasn't grown, but ensure it's in state
        if (!$State.files.ContainsKey($FileName)) {
            $State.files[$FileName] = @{
                size = $CurrentSize
                date = $FileDate
            }
        }
        return $false
    }
}

# ============================================================================
# MODULE 5: MAIN PROCESSING LOOP
# ============================================================================

function Start-Monitoring {
    <#
    .SYNOPSIS
        Main monitoring loop that continuously scans and processes log files
    #>
    
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Log Consolidation Monitor Starting" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Source folder: $SourceFolder" -ForegroundColor Cyan
    Write-Host "Consolidated file: $ConsolidatedFile" -ForegroundColor Cyan
    Write-Host "Log pattern: $($Config.LogPattern)" -ForegroundColor Cyan
    Write-Host "Retention period: $($Config.RetentionDays) days" -ForegroundColor Cyan
    Write-Host "Poll interval: $($Config.PollInterval) seconds" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Load initial state
    $State = Load-State
    Write-Host "Loaded state: Tracking $($State.files.Count) file(s)" -ForegroundColor Yellow
    Write-Host ""
    
    # Main monitoring loop
    while ($true) {
        try {
            # Clean up old files from state
            Cleanup-OldState -State $State
            
            # Get all matching log files in source folder
            $AllLogFiles = Get-ChildItem -Path $SourceFolder -Filter $Config.LogPattern -ErrorAction SilentlyContinue | 
                Where-Object { !$_.PSIsContainer } | 
                Sort-Object { Get-DateFromFileName -FileName $_.Name }
            
            if ($AllLogFiles.Count -eq 0) {
                if ($Config.VerboseOutput) {
                    Write-Host "No log files found matching pattern '$($Config.LogPattern)' in $SourceFolder" -ForegroundColor Yellow
                }
            } else {
                if ($Config.VerboseOutput) {
                    Write-Host "Found $($AllLogFiles.Count) log file(s). Processing..." -ForegroundColor Cyan
                }
                
                $FilesProcessed = 0
                $NewFilesDetected = 0
                
                # Process each file
                foreach ($LogFile in $AllLogFiles) {
                    $FilePath = $LogFile.FullName
                    $FileName = $LogFile.Name
                    $WasNew = !$State.files.ContainsKey($FileName)
                    
                    if (Process-File -FilePath $FilePath -State $State) {
                        $FilesProcessed++
                        if ($WasNew) {
                            $NewFilesDetected++
                            Write-Host "New file detected and processed: $FileName" -ForegroundColor Magenta
                        }
                    }
                }
                
                if ($FilesProcessed -gt 0) {
                    Write-Host "Processed $FilesProcessed file(s) ($NewFilesDetected new)" -ForegroundColor Green
                } elseif ($Config.VerboseOutput) {
                    Write-Host "No new content in any files" -ForegroundColor DarkGray
                }
            }
            
            # Save state after processing
            Save-State -State $State
            
            # Wait before next scan
            Start-Sleep -Seconds $Config.PollInterval
            
        } catch {
            Write-Host "Error in main loop: $($_.Exception.Message)" -ForegroundColor Red
            if ($Config.VerboseOutput) {
                Write-Host $_.ScriptStackTrace -ForegroundColor Red
            }
            Start-Sleep -Seconds $Config.PollInterval
        }
    }
}

# ============================================================================
# SCRIPT ENTRY POINT
# ============================================================================

# Initialize paths
Initialize-Paths

# Start monitoring
Start-Monitoring
