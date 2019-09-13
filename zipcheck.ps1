
[CmdletBinding(DefaultParameterSetName = 'input')]
param (
    <#              Input Settings              #>
    # The File or Folder you wish to sanitise
    [Parameter(Position = 0, ParameterSetName = "input")][String] $File,
    [switch] $recurse, 
    [switch] $unpackZip,
 

    <#              Logging Settings                #>
    # Perform logging for this execution
    [Switch] $log = $true,
    # The specific log file to log to. This is useless unless the log switch is used
    [String] $logfile = ".\test-unpack.log",
    # Show absolutely all log messages. This will create much larger logs
    [Switch] $showDebug = $false,
    # How big can a log file get before it's shuffled
    [int] $MaxLogFileSize = 10MB,
    # Max number of log files created by the script
    [int] $LogHistory = 5
)

$_startTime = get-date

## Setup Log functions
function shuffle-logs ($MaxSize, $LogFile = $script:logfile, $MaxFiles = $script:LogHistory) {
    if (!(Test-Path $LogFile)) {
        return # if the log file doesn't exist then we don't need to do anything
    }
    elseif ((Get-Item $logfile).Length -le $MaxSize) {
        return # the log file is still too small
    }

    # Get the name of the file
    $n = ((Split-Path -Leaf -Resolve $logFile) -split '\.')[-2]

    # Find all the files that fit that name
    $logfiles = Get-ChildItem (split-path $LogFile) -Filter "$n.*log"
    
    # When moving files make sure nothing else is accessing them. This is a bit of overkill but could be necessary.
    if ($mtx.WaitOne(500)) {
        # Shuffle the file numbers up
        ($MaxFiles - 1)..1 | ForEach-Object {
            move-item "$n.$_.log" "$n.$($_+1).log" -Force -ErrorAction SilentlyContinue
        }
        $timestamp = Get-Date -format "yy-MM-dd HH:mm:ss.fff"
        $logMessage = ("LOG SHUFFLE " + $timestamp + "   Continued in next log file")
        $logMessage | Out-File -FilePath $LogFile -Force -Append
        move-item $logFile "$n.1.log" 
    
        # Start a new file
        new-item -ItemType file -Path $LogFile | Out-Null;

        [void]$mtx.ReleaseMutex()
    }
}

# Create a mutex for the rest of the execution
$mtx = New-Object System.Threading.Mutex($false, "LoggerMutex")

# Enum to show what type of log it should be
Enum LEnum {
    Trace
    Warning
    Debug
    Error
    Question # Use this to show a prompt for user input
    Message # This is the log type that's printed and coloured
}

<#
    logfunction. Default params will log to file with date 
    https://www.sapien.com/blog/2015/01/05/enumerators-in-windows-powershell-5-0/
#>
function log ([String] $Stage, [LEnum] $Type = [LEnum]::Trace, [String] $String, [System.ConsoleColor] $Colour, [String] $Logfile = $script:logfile) {
    # Return instantly if this isn't output and we're not logging
    if (!$script:log -and @([LEnum]::Message, [LEnum]::Question, [LEnum]::Warning, [LEnum]::Error) -notcontains $type) { return }
    # Return instantly if this is a debug message and we're not showing debug
    if (!$script:showDebug -and $type -eq [Lenum]::Debug) { return }
 
    shuffle-logs $script:MaxLogFileSize $Logfile

    # Deal with the colouring and metadata
    switch ($Type) {
        "Message" {  
            $1 = 'I'
            $display = $true
            $Colour = ($null, $Colour, 'WHITE' -ne $null)[0]
            break
        }
        "Question" {
            $1 = 'Q'
            $display = $true
            $Colour = ($null, $Colour, 'CYAN' -ne $null)[0]
            break
        }
        "Debug" {  
            $1 = 'D'
            break
        }
        "Error" {  
            $1 = 'E'
            $Colour = ($null, $Colour, 'RED' -ne $null)[0]
            $display = $true
            $String = "ERROR: $string"
            break
        }
        "Warning" {  
            $1 = 'W'
            $Colour = ($null, $Colour, 'YELLOW' -ne $null)[0]
            $display = $true
            $String = "Warning: $string"
            break
        }
        Default {
            # Trace enums are default. 
            $1 = 'T'
        }
    }

    # If we need to display the message check that we're not meant to be silent
    if ($display -and -not $silent) {
        # Error messages require a black background to stand out and mirror powershell's native errors
        if ($type -eq [LEnum]::Error) {
            write-host $String -foregroundcolor $Colour -BackgroundColor 'Black'
        }
        else {
            write-host $String -foregroundcolor $Colour
        }
    }
    
    # Check whether we're meant to log to file
    if (!$script:log) {
        return
    }
    else {    
        # assemble log message!
        $stageSection = $(0..5 | % { $s = '' } { $s += @(' ', $Stage[$_])[[bool]$Stage[$_]] } { $s })
        $timestamp = Get-Date -format "yy-MM-dd HH:mm:ss.fff"
        $logMessage = ($1 + " " + $stageSection.toUpper() + " " + $timestamp + "   " + $String)
        try {
            # This try is to deal specifically when we've destroyed the mutex.
            if ($mtx.WaitOne()) {
                # use Powershell native code. .NET functions don't offer enough improvement here.
                $logMessage | Out-File -Filepath $Logfile -Append
                [void]$mtx.ReleaseMutex()
            } 
            # consider doing something here like: 
            # if waiting x ms then continue but build a buffer. Check each time the buffer is added to until a max is reached and wait to add that
            # Sometimes the mutex might have been destroyed already (like when we're finishing up) so work with what we've got
        }
        catch [ObjectDisposedException] {
            "$logMessage - NoMutex" | Out-File -FilePath $logFile -Append
        }
    }
}

function replace-null ($valIfNull, [Parameter(ValueFromPipeline = $true)]$TestVal) {
    return ($null, $TestVal, $valIfNull -ne $null)[0]
}

function Get-FileEncoding {
    # This function is only included here to preserve this as a single file.
    # Original Source: http://blog.vertigion.com/post/110022387292/powershell-get-fileencoding
    [CmdletBinding()]
    param (
        [Alias("PSPath")]
        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [String]$Path,

        [Parameter(Mandatory = $False)]
        [System.Text.Encoding]$DefaultEncoding = [System.Text.Encoding]::ASCII
    )
    process {
        [Byte[]]$bom = Get-Content -Encoding Byte -ReadCount 4 -TotalCount 4 -Path $Path
        $encoding_found = $false
        foreach ($encoding in [System.Text.Encoding]::GetEncodings().GetEncoding()) {
            $preamble = $encoding.GetPreamble()
            if ($preamble -and $bom) {
                foreach ($i in 0..$preamble.Length) {
                    if ($preamble[$i] -ne $bom[$i]) {
                        break
                    }
                    elseif ($i -eq $preable.Length) {
                        $encoding_found = $encoding
                    }
                }
            }
        }
        if (!$encoding_found) {
            $encoding_found = $DefaultEncoding
        }
        $encoding_found
    }
}

function Get-MimeType() {
    # This function is only included here to preserve this as a single file.
    # From https://gallery.technet.microsoft.com/scriptcenter/PowerShell-Function-to-6429566c#content
    param([parameter(Mandatory = $true, ValueFromPipeline = $true)][ValidateNotNullorEmpty()][System.IO.FileInfo]$CheckFile) 
    begin { 
        Add-Type -AssemblyName "System.Web"         
        [System.IO.FileInfo]$check_file = $CheckFile 
        [string]$mime_type = $null 
    } 
    process { 
        if (test-path $check_file) {  
            $mime_type = [System.Web.MimeMapping]::GetMimeMapping($check_file.FullName)  
        }
        else { 
            $mime_type = "false" 
        } 
    } 
    end { return $mime_type } 
}


function Manage-Job ([System.Collections.Queue] $jobQ, [int] $MaxJobs, [int] $ProgressStart, [int] $ProgressEnd) {
    log timing trace "[START] Managing Job Execution"
    log manjob trace "Clearing all background jobs (again just in case)"
    Get-Job | Stop-Job
    Get-job | Remove-Job

    $totalJobs = $jobQ.count
    $ProgressInterval = ($ProgressEnd - $ProgressStart) / $totalJobs
    # While there are still jobs to deploy or there are jobs still running
    While ($jobQ.Count -gt 0 -or $(get-job -State "Running").count -gt 0) {
        $JobsRunning = $(Get-Job -State 'Running').count

        # For each job started and each child of those jobs
        ForEach ($Job in Get-Job) {
            ForEach ($Child in $Job.ChildJobs) {
                ## Get the latest progress object of the job
                $Progress = $Child.Progress[$Child.Progress.Count - 1]
                
                ## If there is a progress object returned write progress
                If ($Progress.Activity -ne $Null) {
                    Write-Progress -Activity $Job.Name -Status $Progress.StatusDescription -PercentComplete $Progress.PercentComplete -ID $Job.ID -ParentId $_tp
                    log manjob trace "Job '$($job.name)' is at $($Progress.PercentComplete)%"
                }
                
                ## If this child is complete then stop writing progress
                If ($Progress.PercentComplete -eq 100 -or $Progress.PercentComplete -eq -1) {
                    log manjob trace "Job '$($Job.name)' has finished"

                    #Update total progress
                    $perc = $ProgressStart + $ProgressInterval * ($totalJobs - $jobQ.count)
                    Write-Progress -Activity "Sanitising" -Id $_tp -PercentComplete $perc

                    Write-Progress -Activity $Job.Name -Status $Progress.StatusDescription  -PercentComplete $Progress.PercentComplete -ID $Job.ID -ParentId $_tp -Complete
                    ## Clear all progress entries so we don't process it again
                    $Child.Progress.Clear()
                }
            }
        }
        
        if ($JobsRunning -lt $MaxJobs -and $jobQ.Count -gt 0) {
            $NumJobstoRun = @(($MaxJobs - $JobsRunning), $jobQ.Count)[$jobQ.Count -lt ($MaxJobs - $JobsRunning)]
            log manjob trace "We've completed some jobs, we need to start $NumJobstoRun more"
            1..$NumJobstoRun | ForEach-Object {
                log manjob trace "iteration: $_ of $NumJobstoRun"
                if ($jobQ.Count -eq 0) {
                    log manjob trace "There are 0 jobs left. Skipping the loop"
                    return
                }
                $j = $jobQ.Dequeue()
                # Provide some context to the job's environment variable
                $JobDateId = "{0:x}" -f [int64]([datetime]::UtcNow - (get-date "1/1/1970")).TotalMilliseconds
                # Provide the name of the job and then the 'jobid' (which is just the date in hex and then shortened)
                $j[3][-1] += $j[0]; $j[3][-1] += ([char[]]$JobDateId[-6..-1] -join '')
                Start-Job -Name $j[0] -InitializationScript $j[1] -ScriptBlock $j[2] -ArgumentList $j[3] | Out-Null
                log manjob trace "Started Job named '$($j[0])'. There are $($jobQ.Count) jobs remaining"
            }
        }

        ## Setting for loop processing speed
        Start-Sleep -Milliseconds 500
    }

    # Ensure all progress bars are cleared
    ForEach ($Job in Get-Job) {
        Write-Progress -Activity $Job.Name -ID $Job.ID -ParentId $_tp -Complete
    }
    log timing trace "[END] Managing Job Execution"
}

function Sanitising-Stripper ( $finalKeyList, $files, [string] $OutputFolder, [string] $rootFolder, [String] $killerFlags, [bool] $inPlace, [int] $PCompleteStart, [int] $PCompleteEnd) {
    log timing trace "[START] Sanitising File(s)"
    $q = New-Object System.Collections.Queue

    # used to resolve https://github.com/cavejay/Strippy/issues/39
    # if the switch flagged then nothing will come through
    if ($script:noHeaderInOutput) {
        $script:config.SanitisedFileFirstLine = ''
    }

    # Sanitise each of the files with the final keylist and output them with Save-file
    ForEach ($file in $files) {
        $name = "Sanitising $(Get-PathTail $file $rootFolder)"
        $ScriptBlock = {
            PARAM($file, $finalKeyList, $firstline, $OutputFolder, $rootFolder, $killerFlags, $inPlace, $_env)
            $script:log, $script:showDebug, $script:logfile, $script:MaxLogFileSize, $script:LogHistory, $script:JobName, $script:JobId = $_env

            log-job-start

            if ($killerFlags) {
                log SanStr trace "Filtering out lines that match $killerFlags"
                $content = [IO.file]::ReadAllLines($file) -notmatch $killerFlags -join "`r`n"
            }
            else {
                $content = [IO.file]::ReadAllLines($file) -join "`r`n"
            }
            log SanStr trace "Loaded in content of $file"

            $sanitisedOutput = Sanitise $firstline $finalKeyList $content $file
            log SanStr trace "Sanitised content of $file"

            $exportedFileName = Save-File $file $sanitisedOutput $rootFolder $OutputFolder $inPlace
            log SanStr trace "Exported $file to $exportedFileName"

            $exportedFileName
        }
        $ArgumentList = $file, $finalKeyList, $script:Config.SanitisedFileFirstline, $OutputFolder, $(@($null, $rootFolder)[$files.Count -gt 1]), $killerFlags, $inPlace, $_env
        $q.Enqueue($($name, $JobFunctions, $ScriptBlock, $ArgumentList))
    }
    Manage-Job $q $MaxThreads $PCompleteStart $PCompleteEnd
    log SanStr trace "Sanitising jobs are finished. Files should be exported"

    # Collect the names of all the sanitised files
    $jobs = Get-Job -State Completed
    $sanitisedFilenames = @()
    ForEach ($job in $jobs) {
        $fn = Receive-Job -Keep -Job $job
        $sanitisedFilenames += $fn
    }
    log SanStr trace "Sanitised file names are:`n$sanitisedFilenames"

    # Clean up the jobs
    Get-Job | Remove-Job | Out-Null
    
    log timing trace "[END] Sanitising File(s)"
    return $sanitisedFilenames
}


function zip-unpacker ([String[]]$ZipFiles, $Depth = 1) {
    log timing trace "[START] ZIP Unpacker (D$depth)"

    # ensure $zipfiles are all .zip files
    $zipfiles = $ZipFiles | ForEach-Object { get-item $_ } |  Where-Object -Property Extension -EQ '.zip' | Select-Object -ExpandProperty fullname
    log unzipr trace "Looking to unpack $($zipfiles.Length) files: `"$($zipfiles -join '", "')`""

    $unpackedFolders = @()

    # unpack them all
    foreach ($archive in $zipfiles) {
        $extractedTo = make-archiveFolder $archive
        $unpackedFolders += $extractedTo.fullname
        Expand-Archive -Path $archive -DestinationPath $extractedTo
    }

    log unzipr trace "Successfully unpacked archives to: `"$($unpackedFolders -join '", "')`""

    # if depth is 1 we've gone as far as we should otherwise lets go deeper
    if ($Depth -gt 1) {
        # analyse their unpacked contents
        $childrenZipFiles = Get-ChildItem $unpackedFolders -Recurse:$script:Recurse | Where-Object -Property Extension -EQ '.zip' | Select-Object -ExpandProperty FullName
        

        # if we need to go deeper, go again (recursively)
        if ((, $childrenZipFiles).Length -gt 0) {
            log unzipr trace "$($childrenZipFiles.length) additional log file(s) were found at depth '$depth'. Recursing deeper"
            log unzipr debug "Files to unzip next iteration: $($childrenZipFiles -join ', ')"
            zip-unpacker $childrenZipFiles -Depth ($depth - 1)
        }
    }

    log timing trace "[End] ZIP Unpacker (D$depth)"
}

function zip-cleaner () {

}

log main trace '                  ==================================                         '
log main trace '==================                                  ========================='
log main trace '                  ==================================                         '

$file = 'C:\users\michael.ball\Desktop\tmp\Dynatrace_Support_Archive_88229d42-c39e-4825-b180-44099bc5cbd4 (1).zip'

log main message "Unpacking $file"

remove-item -force -Recurse "C:\users\michael.ball\Desktop\tmp\Dynatrace_Support_Archive_88229d42-c39e-4825-b180-44099bc5cbd4_(1)-zip"

function make-archiveFolder ([Parameter(ValueFromPipeline = $true)]$archive) {
    log timing trace "[START] Generate Archive Folder name"
    [System.IO.FileSystemInfo]$file = [System.IO.FileSystemInfo] (get-item $archive)
    
    $unpackedDir = Join-Path -Path $file.DirectoryName -ChildPath "$($file.baseName)-zip"
    $unpackedDir = $unpackedDir -replace ' ', '_'
    
    if (!(Test-Path -Path $unpackedDir -PathType Container)) {
        log mkahdr message "Created previously non-existent dir '$unpackedDir' for contents of archive '$archive'"
        New-Item -Path $unpackedDir -ItemType Directory -Force | Out-Null
    }

    log timing trace "[End] Generate Archive Folder name"
    return get-item $unpackedDir
}

$files = @()

# File is a .zip
if ((get-item $file).Extension -eq '.zip') {
    
    # Unpack the top level zip
    $_file = $file
    [System.IO.FileSystemInfo]$file = [System.IO.FileSystemInfo] (get-item $_file)
    $unpackedDir = make-archiveFolder $file

    log main message "New output dir: $unpackedDir"

    if ($script:Recurse) {
        # unpack the files
        zip-unpacker (, $file) -Depth 5

        $files = Get-ChildItem -Path $unpackedDir -Depth 10
    }
    else {
        # only unpack the first layer
        zip-unpacker (, $file) -Depth 1 -outputDir $unpackedDir

        $files = Get-ChildItem -Path $unpackedDir -Depth 1
    }

} 
#Folder contains zips
elseif (Test-Path -Path $file -PathType Container) {
    $files = Get-ChildItem -Recurse:$script:Recurse -Depth 10 -Path $file

    # if we should unpack zips and there are some
    if ($script:unpackZip -and ($files | Where-Object -Property Extension -EQ '.zip' | Measure-Object -Line) -gt 0) {
        $zipfiles = $files | Where-Object -Property Extension -EQ '.zip'

        zip-unpacker $zipfiles -Depth @(1, 5)[$script:Recurse]
    }
}

exit

# Filter out files that have been marked as sanitised or look suspiscious based on the get-filencoding or get-mimetype functions
log ioproc trace "Filter out files that aren't sanitisable"
$files = $files | Where-Object {
    $val = ( @('us-ascii', 'utf-8') -contains ( Get-FileEncoding $_.FullName ).BodyName ) -and -not
    ( $(Get-MimeType -CheckFile $_.FullName) -match "image") -and -not
    ( $_.name -like '*.sanitised.*')

    if (!$val) {
        log ioproc trace "$($_.FullName) will not be sanitised"
    }
    $val
} | ForEach-Object { $_.FullName }
log ioproc debug "$($files.Length) Files left after filtering: `"$($files -join ', ')`""

# If we didn't find any files clean up and exit
log ioproc trace "Checking number of files after filtering"
if ( $files.Length -eq 0 ) {
    log ioproc trace "0 files left after filtering. Script will now exit"
    log ioproc error "Could not find any appropriate files to sanitise in $File"
    Clean-Up
}

# Declare which files we'd like to process
$filesToProcess = $files

$filesToProcess