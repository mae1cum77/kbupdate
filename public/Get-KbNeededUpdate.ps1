function Get-KbNeededUpdate {
    <#
    .SYNOPSIS
        Replacement for Get-Hotfix, Get-Package, searching the registry and searching CIM for updates

    .DESCRIPTION
        Replacement for Get-Hotfix, Get-Package, searching the registry and searching CIM for updates.

    .PARAMETER Pattern
        Any pattern. But really, a KB pattern is your best bet.

    .PARAMETER ComputerName
        Used to connect to a remote host

    .PARAMETER Credential
        The optional alternative credential to be used when connecting to ComputerName

    .PARAMETER IncludeHidden
        Include KBs that are hidden due to misconfiguration.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Author: Chrissy LeMaire (@cl), netnerds.net
        Copyright: (c) licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .EXAMPLE
        PS C:\> Get-KbNeededUpdate

        Gets all the updates installed on the local machine

    .EXAMPLE
        PS C:\> Get-KbNeededUpdate -ComputerName server01

        Gets all the updates installed on server01

    .EXAMPLE
        PS C:\> Get-KbNeededUpdate | Save-KbUpdate -Path C:\temp

        Gets all the updates installed on server01 that match KB4057119
#>
    [CmdletBinding()]
    param(
        [PSFComputer[]]$ComputerName = $env:COMPUTERNAME,
        [pscredential]$Credential,
        [parameter(ValueFromPipeline)]
        [Alias("FullName")]
        [string]$ScanFilePath,
        [switch]$Force,
        [switch]$EnableException
    )
    begin {
        $scriptblock = {
            param (
                $Computer,
                $ScanFilePath,
                $VerbosePreference
            )

            if ($ScanFilePath) {
                try {
                    If (-not (Test-Path $ScanFilePath -ErrorAction Stop)) {
                        Write-Warning "Windows Update offline scan file, $ScanFilePath, cannot be found on $Computer"
                        return
                    }
                } catch {
                    if (($ScanFilePath).StartsWith("\\") -and $PSItem -match "Denied") {
                        throw "$PSItem. This may be a Kerberos issue caused by the ScanFilePath being on a remote system. Use -Force to copy the catalog to a temporary directory on the remote system."
                    } else {
                        throw $PSItem
                    }
                }
            }

            try {
                Write-Verbose -Message "Processing $computer"
                $session = [type]::GetTypeFromProgID("Microsoft.Update.Session")
                $wua = [activator]::CreateInstance($session)
                if ($ScanFilePath) {
                    Write-Verbose -Message "Registering $ScanFilePath on $computer"
                    try {
                        $progid = [type]::GetTypeFromProgID("Microsoft.Update.ServiceManager")
                        $sm = [activator]::CreateInstance($progid)
                        $packageservice = $sm.AddScanPackageService("Offline Sync Service", $ScanFilePath)
                    } catch {
                        if (($ScanFilePath).StartsWith("\\") -and $PSItem -match "Denied") {
                            throw "$PSItem. This may be ca Kerberos issue. Consider using a Credential in order to avoid a double-hop."
                        } else {
                            throw $PSItem
                        }
                    }
                }
                $searcher = $wua.CreateUpdateSearcher()
                Write-Verbose -Message "Searching for needed updates"
                $wsuskbs = $searcher.Search("IsAssigned=1 and IsHidden=0 and IsInstalled=0").Updates

                foreach ($wsuskb in $wsuskbs) {
                    # iterate the updates in searchresult
                    # it must be force iterated like this
                    $links = @()
                    foreach ($bundle in $wsuskb.BundledUpdates) {
                        foreach ($file in $bundle.DownloadContents) {
                            if ($file.DownloadUrl) {
                                $links += $file.DownloadUrl.Replace("http://download.windowsupdate.com", "https://catalog.s.download.windowsupdate.com")
                            }
                        }
                    }

                    [pscustomobject]@{
                        ComputerName      = $Computer
                        Title             = $wsuskb.Title
                        Id                = ($wsuskb.KBArticleIDs | Select-Object -First 1)
                        UpdateId          = $wsuskb.Identity.UpdateID
                        Description       = $wsuskb.Description
                        LastModified      = $wsuskb.ArrivalDate
                        Size              = $wsuskb.Size
                        Classification    = $wsuskb.UpdateClassificationTitle
                        KBUpdate          = "KB$($wsuskb.KBArticleIDs | Select-Object -First 1)"
                        SupportedProducts = $wsuskb.ProductTitles
                        MSRCNumber        = $alert
                        MSRCSeverity      = $wsuskb.MsrcSeverity
                        RebootBehavior    = $wsuskb.InstallationBehavior.RebootBehavior -eq $true
                        RequestsUserInput = $wsuskb.InstallationBehavior.CanRequestUserInput
                        ExclusiveInstall  = $null
                        NetworkRequired   = $wsuskb.InstallationBehavior.RequiresNetworkConnectivity
                        UninstallNotes    = $wsuskb.UninstallNotes
                        UninstallSteps    = $wsuskb.UninstallSteps
                        Supersedes        = $null #TODO
                        SupersededBy      = $null #TODO
                        Link              = $links
                        InputObject       = $wsuskb
                    }
                }
                try {
                    if ($ScanFilePath -and $packageservice) {
                        Write-Verbose "Unregistering $ScanFilePath ($id) from WUA"
                        $id = $packageservice.ServiceID
                        $null = $sm.RemoveService($id)
                    }
                } catch {
                    Write-Verbose "Failed to unregister $id from WUA"
                }
            } catch {
                if ($PSItem -match "HRESULT: 0x80070005") {
                    Write-Warning "You must run this command as administator in order to perform the task"
                } else {
                    throw $_
                }
            }
        }
    }
    process {
        $completed = 0
        $totalcount = (($ComputerName.Count) + 1)

        if ($IsLinux -or $IsMacOs) {
            Stop-PSFFunction -Message "This command using remoting and only supports Windows at this time" -EnableException:$EnableException
            return
        }
        foreach ($item in $ComputerName) {
            try {
                $computer = $item.ComputerName
                $null = $completed++
                if ($item.IsLocalHost -and -not (Test-ElevationRequirement -ComputerName $computer)) {
                    continue
                }

                if ($ScanFilePath -and $Force -and -not $item.IsLocalhost) {
                    Write-PSFMessage -Level Verbose -Message "Initializing remote session to $computer and getting the path to the temp directory"

                    $scanfile = Get-ChildItem -Path $ScanFilePath
                    $temp = Invoke-PSFCommand -Computer $computer -Credential $Credential -ErrorAction Stop -ScriptBlock {
                        [system.io.path]::GetTempPath()
                    }
                    $filename = Split-Path -Path $ScanFilePath -Leaf
                    $cabpath = Join-PSFPath -Path $temp -Child $filename

                    Write-PSFMessage -Level Verbose -Message "Checking to see if $cabpath already exists on $computer"

                    $exists = Invoke-PSFCommand -Computer $computer -Credential $Credential -ArgumentList $cabpath -ErrorAction Stop -ScriptBlock {
                        Get-ChildItem -Path $args
                    }

                    if ($exists.BaseName -and $scanfile.Length -eq $exists.Length) {
                        Write-PSFMessage -Level Verbose -Message "File exists and is of the same size. Skipping copy"
                    } else {
                        Write-PSFMessage -Level Verbose -Message "File does not exist"
                        if ($Credential) {
                            $PSDefaultParameterValues["Get-PSSession:Credential"] = $Credential
                        }

                        if (-not $remotesession) {
                            $remotesession = Get-PSSession -ComputerName $computer -Verbose | Where-Object { $PsItem.Availability -eq 'Available' -and ($PsItem.Name -match 'WinRM' -or $PsItem.Name -match 'Runspace') } | Select-Object -First 1
                        }

                        if (-not $remotesession) {
                            $remotesession = Get-PSSession -ComputerName $computer | Where-Object { $PsItem.Availability -eq 'Available' } | Select-Object -First 1
                        }

                        if (-not $remotesession) {
                            Stop-PSFFunction -EnableException:$EnableException -Message "Session for $computer can't be found or no runspaces are available. Please file an issue on the GitHub repo at https://github.com/potatoqualitee/kbupdate/issues" -Continue
                        }

                        Write-PSFMessage -Level Verbose "Copying $ScanFilePath to $temp on $computer"
                        $null = Copy-Item -Path $ScanFilePath -Destination $temp -ToSession $remotesession -Force
                    }
                } else {
                    $cabpath = $ScanFilePath
                }

                if ($item.IsLocalHost -and -not (Test-ElevationRequirement -ComputerName $computer)) {
                    continue
                }

                Write-ProgressHelper -TotalSteps $totalcount -StepNumber $completed -Activity "Getting updates" -Message "Processing $computer"
                Invoke-PSFCommand -Computer $computer -Credential $Credential -ErrorAction Stop -ScriptBlock $scriptblock -ArgumentList $computer, $cabpath, $VerbosePreference |
                    Select-Object -Property * -ExcludeProperty PSComputerName, RunspaceId |
                    Select-DefaultView -Property ComputerName, Title, KBUpdate, UpdateId, Description, LastModified, RebootBehavior, RequestsUserInput, NetworkRequired, Link
            } catch {
                Stop-PSFFunction -EnableException:$EnableException -Message "Failure on $computer" -ErrorRecord $PSItem -Continue
            }
        }
    }
}