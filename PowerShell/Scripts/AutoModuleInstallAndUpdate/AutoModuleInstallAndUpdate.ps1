
<#PSScriptInfo
.VERSION 0.8.1.7
.GUID 7f59e8ee-e3bd-4d72-88fe-24caf387e6f6
.AUTHOR Brian Lalancette (@brianlala)
.DESCRIPTION Automatically installs or updates PowerShell modules from the PowerShell Gallery
.COMPANYNAME Microsoft
.COPYRIGHT 2019-2020 Brian Lalancette
.TAGS NuGet PowerShellGet
.LICENSEURI
.PROJECTURI https://github.com/Microsoft/PFE/tree/master/PowerShell/Scripts/AutoModuleInstallAndUpdate
.ICONURI
.EXTERNALMODULEDEPENDENCIES PowerShellGet
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

<#
.SYNOPSIS
    Automatically installs or updates PowerShell modules from the PowerShell Gallery
.PARAMETER Confirm
    Prompts prior to updating any existing modules or cleaning up files left over from old versions of modules.
.PARAMETER ModulesToCheck
    Allows you to include an optional comma-delimited list (array) of modules to install or update.
.PARAMETER ModulesAndVersionsToCheck
    Accepts a hash table containing name-value pairs of modules and specific desired versions. To request the latest available version of a particular module, leave its value as an empty set of double quotes.
.PARAMETER UpdateExistingInstalledModules
    Switch that indicates whether we should look for updates to any modules that are already installed on the current system. Disabled by default.
.PARAMETER AllowPrerelease
    Switch that indicates whether to allow installing or updating to prerelease module versions. Disabled by default.
.PARAMETER IncludeAnyManuallyInstalledModules
    Switch that specifies we should attempt to update any modules that weren't originally installed from the PowerShell Gallery. Disabled by default.
.PARAMETER KeepPriorModuleVersions
    Switch indicating that older versions of any updated/installed modules should be left in place. By default, any old module versions detected are uninstalled and removed from the file system.
.PARAMETER Repository
    Allows you to specify a non-default PowerShell repository. If omitted, uses whatever the system default is (usually the PowerShell Gallery (PSGallery))
.EXAMPLE
    AutoModuleInstallAndUpdate.ps1 -Confirm:$false -ModulesToCheck Az,MSOnline -Verbose
    This will check and if necessary install/update both the Az and MSOnline modules to the latest published (non-prerelease) version, without prompting for confirmation.
.EXAMPLE
    AutoModuleInstallAndUpdate.ps1 -ModulesAndVersionsToCheck @{SharePointDSC = "3.4.0.0"; xCredSSP = "1.3.0.0"; xPSDesiredStateConfiguration = ""} -Verbose
    This will check and if necessary install/update SharePointDSC version 3.4.0.0, xCredSSP version 1.3.0.0, and the latest version of xPSDesiredStateConfiguration, with verbose output.
.EXAMPLE
    AutoModuleInstallAndUpdate.ps1 -Confirm:$false -UpdateExistingInstalledModules -IncludeAnyManuallyInstalledModules
    This command will effectively attempt a full unattended update of all PowerShell modules currently detected on the system, regardless of whether they were installed from the PowerShell Gallery.
.LINK
    https://github.com/Microsoft/PFE

.LINK
    https://www.powershellgallery.com/packages/AutoModuleInstallAndUpdate
.NOTES
    Created & maintained by Brian Lalancette (@brianlala), 2017-2019.
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)][bool]$Confirm = $true,
    [Parameter(Mandatory = $false, ParameterSetName = 'Latest')][ValidateNotNullOrEmpty()][array]$ModulesToCheck,
    [Parameter(Mandatory = $false, ParameterSetName = 'Versioned')][ValidateNotNullOrEmpty()][hashtable]$ModulesAndVersionsToCheck,
    [Parameter(Mandatory = $false, ParameterSetName = 'Latest')][switch]$UpdateExistingInstalledModules = $false,
    [Parameter(Mandatory = $false)][switch]$AllowPrerelease = $false,
    [Parameter(Mandatory = $false, ParameterSetName = 'Latest')][switch]$IncludeAnyManuallyInstalledModules = $false,
    [Parameter(Mandatory = $false)][switch]$KeepPriorModuleVersions = $false,
    [Parameter(Mandatory = $false)][string]$Repository = $null
)

# If -IncludeAnyManuallyInstalledModules was specified then this implies -UpdateExistingInstalledModules
if ($IncludeAnyManuallyInstalledModules -and (!$UpdateExistingInstalledModules))
{
    Write-Verbose -Message " - `"IncludeAnyManuallyInstalledModules`" specified; assuming `"UpdateExistingInstalledModules`" as well."
    $UpdateExistingInstalledModules = $true
}
$Host.UI.RawUI.BackgroundColor = "Black"
$Host.UI.RawUI.ForegroundColor = "White"
$originalWindowTitle = $Host.UI.RawUI.WindowTitle

#requires -RunAsAdministrator
#requires -Version 5

# Clean up old variables
Remove-Variable -Name modulesInstalled -Scope Global -Force -ErrorAction SilentlyContinue
Remove-Variable -Name modulesUpdated -Scope Global -Force -ErrorAction SilentlyContinue
Remove-Variable -Name modulesUnchanged -Scope Global -Force -ErrorAction SilentlyContinue
Remove-Variable -Name modulesRemoved -Scope Global -Force -ErrorAction SilentlyContinue

# Force TLS 1.2 (new requirement for the PowerShell Gallery)
Write-Output " - Forcing TLS 1.2..."
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# If we didn't specify a modules-with-versions hash table to check on the command line, create an empty hash table that we can add items to later
if ($null -eq $ModulesAndVersionsToCheck)
{
    [hashtable]$ModulesAndVersionsToCheck = @{}
    if ($ModulesToCheck.Count -ge 1)
    {
        # Add each item in the $ModulesToCheck array to the $ModulesAndVersionsToCheck hash table, with blank version to specify the latest available
        foreach ($ModuleName in $ModulesToCheck)
        {
            $ModulesAndVersionsToCheck[$ModuleName] = "" # Empty quotes for latest available version
        }
    }
}
elseif ($null -ne $ModulesToCheck -or $null -ne $ModulesAndVersionsToCheck)
{
    # We want to make sure that if we have specifically included modules to check that they're checked even if they were manually installed
    $updateModulesEvenIfManuallyInstalled = $true
}
if ($UpdateExistingInstalledModules)
{
    foreach ($existingInstalledModule in ((Get-Module -ListAvailable | Where-Object ModuleBase -like "$env:ProgramFiles\WindowsPowerShell\Modules\*")))
    {
        Write-Verbose -Message " - Adding existing installed module '$($existingInstalledModule.Name)' to list of modules to update."
        $ModulesAndVersionsToCheck[$($existingInstalledModule.Name)] = "" # Empty quotes for latest available version
    }
}

try
{
    #region Pre-Checks
    if ($null -eq (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue))
    {
        # Install NuGet
        Write-Output " - Installing NuGet..."
        Install-PackageProvider -Name NuGet -Force -ForceBootstrap | Out-Null
    }
    if ($VerbosePreference -eq "Continue")
    {
        $verboseParameter = @{Verbose = $true}
        Write-Verbose -Message " - `"Verbose`" parameter specified."
        $noNewLineSwitch = @{}
    }
    else
    {
        $verboseParameter = @{}
        $noNewLineSwitch = @{NoNewLine = $true}
    }
    if ($Confirm)
    {
        $confirmParameter = @{Confirm = $true}
        Write-Host -ForegroundColor Yellow " - `"Confirm:`$true`" parameter specified or implied. Use -Confirm:`$false to skip confirmation prompts."
    }
    else
    {
        $confirmParameter = @{Confirm = $false}
    }
    if ($AllowPrerelease -eq $true)
    {
        $allowPrereleaseParameter = @{AllowPrerelease = $true}
    }
    else
    {
        $allowPrereleaseParameter = @{}
    }
    if (!([string]::IsNullOrEmpty($Repository)))
    {
        $repositoryParameter = @{Repository = $Repository}
    }
    else
    {
        $repositoryParameter = @{}
    }
    #endregion
    if (($UpdateExistingInstalledModules) -or ($ModulesAndVersionsToCheck.Count -ge 1))
    {
        Write-Output " - Checking for requested PowerShell modules..."
        # Because SkipPublisherCheck, AllowClobber and AcceptLicense parameters don't seem to be supported on Win2012R2 let's set whether the parameters are specified here
        if (Get-Command -Name Install-Module -ParameterName AllowClobber -ErrorAction SilentlyContinue)
        {
            $allowClobberParameter = @{AllowClobber = $true}
        }
        else
        {
            $allowClobberParameter = @{}
        }
        if (Get-Command -Name Install-Module -ParameterName SkipPublisherCheck -ErrorAction SilentlyContinue)
        {
            $skipPublisherCheckParameter = @{SkipPublisherCheck = $true}
        }
        else
        {
            $skipPublisherCheckParameter = @{}
        }
        if (Get-Command -Name Install-Module -ParameterName AcceptLicense -ErrorAction SilentlyContinue)
        {
            $AcceptLicenseParameter = @{AcceptLicense = $true}
        }
        else
        {
            $AcceptLicenseParameter = @{}
        }
        Write-Verbose -Message " - `$ModulesAndVersionsToCheck.Keys: $($ModulesAndVersionsToCheck.Keys | Sort-Object)"
        foreach ($moduleToCheck in ($ModulesAndVersionsToCheck.Keys | Sort-Object))
        {
            Write-Host -ForegroundColor Cyan "  - Module: '$moduleToCheck'..."
            $Host.UI.RawUI.WindowTitle = "Checking '$moduleToCheck'..."
            if ([string]::IsNullOrEmpty($ModulesAndVersionsToCheck.$moduleToCheck))
            {
                $requiredVersion = "latest available"
                $requiredVersionParameter = @{}
            }
            else
            {
                $requiredVersion = $ModulesAndVersionsToCheck.$moduleToCheck
                $requiredVersionParameter = @{RequiredVersion = $requiredVersion}
            }

            [array]$installedModuleVersions = Get-Module -ListAvailable -FullyQualifiedName $moduleToCheck
            if ($null -eq $installedModuleVersions -and ($null -eq (Get-InstalledModule -Name $moduleToCheck @requiredVersionParameter -ErrorAction SilentlyContinue)))
            {
                # Install requested module since it wasn't detected
                $onlineModule = Find-Module -Name $moduleToCheck -ErrorAction SilentlyContinue @requiredVersionParameter
                if ($onlineModule)
                {
                    Write-Host -ForegroundColor DarkYellow  "   - Module '$moduleToCheck' not present. Installing version $($onlineModule.Version)..." @noNewLineSwitch
                    $Host.UI.RawUI.WindowTitle = "Installing '$moduleToCheck'..."
                    # Clear our error variable first
                    Remove-Variable -Name err -ErrorAction SilentlyContinue
                    Install-Module -Name $moduleToCheck -ErrorAction Inquire -ErrorVariable err -Force @allowClobberParameter @skipPublisherCheckParameter @verboseParameter @requiredVersionParameter @acceptLicenseParameter
                    # Only declare success if we didn't get an error and our error variable is not set
                    if ($? -and !$err)
                    {
                        Write-Host -ForegroundColor Green "  Done."
                        [array]$global:modulesInstalled += "$moduleToCheck version $($onlineModule.Version)"
                    }
                }
                else
                {
                    Write-Host -ForegroundColor Yellow "   - Module '$moduleToCheck' $($requiredVersion -replace 'latest version','') not present, and was not found in the PowerShell Gallery for installation/update."
                    [array]$global:modulesUnchanged += $moduleToCheck
                }
                $Host.UI.RawUI.WindowTitle = $originalWindowTitle
            }
            else
            {
                $installedModule = Get-InstalledModule -Name $moduleToCheck -ErrorAction SilentlyContinue @requiredVersionParameter
                if ($installedModule)
                {
                    # If we were successful in querying the module this way it was probably originally installed from the Gallery
                    $installedModuleWasFromGallery = $true
                }
                else # Was probably pre-installed or installed manually
                {
                    # Grab the newest version in case there are multiple
                    $installedModule = ($installedModuleVersions | Sort-Object -Property Version -Descending)[0]
                    $installedModuleWasFromGallery = $false
                }
                if ($requiredVersion -ne $($installedModule.Version))
                {
                    # Look for online updates to or specific version of already-installed requested module
                    Write-Host "   - Module '$moduleToCheck' version $($installedModule.Version) is already installed. Looking for $requiredVersion version..." @noNewLineSwitch
                }
                $onlineModule = Find-Module -Name $moduleToCheck @allowPrereleaseParameter @repositoryParameter -ErrorAction SilentlyContinue @requiredVersionParameter
                if ($null -eq $onlineModule)
                {
                    Write-Host -ForegroundColor Yellow "Not found in the PowerShell Gallery!"
                    [array]$global:modulesUnchanged += $moduleToCheck
                }
                else
                {
                    # Get the last module
                    Write-Verbose -Message "  - Version $($onlineModule.version) of '$moduleToCheck' found in the gallery."
                    if ($installedModule.Version -eq $onlineModule.version)
                    {
                        # Online and local versions match; no action required
                        Write-Host -ForegroundColor Gray "$moduleToCheck version $($installedModule.Version) already installed."
                        [array]$global:modulesUnchanged += $moduleToCheck
                    }
                    else
                    {
                        Write-Host -ForegroundColor Magenta "$($requiredVersion -replace "latest available","Newer version $($onlineModule.Version)") found!"
                        if ($installedModule -and $installedModuleWasFromGallery)
                        {
                            # Update to newest online version using PowerShellGet
                            Write-Host "   - Updating module '$moduleToCheck'..." @noNewLineSwitch
                            $Host.UI.RawUI.WindowTitle = "Updating '$moduleToCheck'..."
                            # Clear our error variable first
                            Remove-Variable -Name err -ErrorAction SilentlyContinue
                            Update-Module -Name $moduleToCheck -ErrorAction Inquire -ErrorVariable err -Force @confirmParameter @verboseParameter @allowPrereleaseParameter @requiredVersionParameter @acceptLicenseParameter
                            if ($? -and !$err)
                            {
                                Write-Host -ForegroundColor Green "  Done."
                                [array]$global:modulesUpdated += "$moduleToCheck to version $($onlineModule.Version)"
                            }
                        }
                        else
                        {
                            # Update won't work as it appears the module wasn't installed using the PS Gallery initially, so let's try a straight install if IncludeAnyManuallyInstalledModules was specified
                            if ($IncludeAnyManuallyInstalledModules -or $updateModulesEvenIfManuallyInstalled)
                            {
                                Write-Host "   - Installing '$moduleToCheck'..." @noNewLineSwitch
                                # Clear our error variable first
                                Remove-Variable -Name err -ErrorAction SilentlyContinue
                                Install-Module -Name $moduleToCheck -ErrorAction Inquire -ErrorVariable err -Force @allowClobberParameter @skipPublisherCheckParameter @confirmParameter @verboseParameter @allowPrereleaseParameter @acceptLicenseParameter @repositoryParameter
                                # Only declare success if we didn't get an error and our error variable is not set
                                if ($? -and !$err)
                                {
                                    Write-Host -ForegroundColor Green "  Done."
                                    [array]$global:modulesUpdated += "$moduleToCheck to version $($onlineModule.Version)"
                                }
                            }
                            else
                            {
                                Write-Verbose -Message "  - Not updating/installing '$moduleToCheck' as it wasn't originally installed from the Gallery and `"IncludeAnyManuallyInstalledModules`" not specified."
                            }
                        }
                        $Host.UI.RawUI.WindowTitle = $originalWindowTitle
                    }
                    # Now check if we have more than one version installed and remove prior versions unless we've specified otherwise
                    Write-Verbose -Message "  - Checking for multiple versions of '$moduleToCheck'..."
                    [array]$installedModuleVersions = Get-Module -ListAvailable -FullyQualifiedName $moduleToCheck -ErrorAction SilentlyContinue
                    $installedModuleVersions += Get-InstalledModule -Name $moduleToCheck -AllVersions -ErrorAction SilentlyContinue @allowPrereleaseParameter
                    if ($installedModuleVersions.Count -gt 1)
                    {
                        if ($KeepPriorModuleVersions)
                        {
                            Write-Verbose -Message "  - NOT removing prior version(s) of '$moduleToCheck' as `"KeepPriorModuleVersions`" was specified."
                        }
                        else
                        {
                            # Remove all non-current module versions including ones that weren't put there via the PowerShell Gallery
                            [array]$oldModules = $installedModuleVersions | Where-Object {$_.Version -ne $onlineModule.Version} | Select-Object -Unique
                            if ($oldModules.Count -ge 1)
                            {
                                Write-Verbose -Message "  - Older versions of module '$moduleToCheck' found ($($oldModules.Count))."
                            }
                            foreach ($oldModule in $oldModules | Where-Object {$_.Name -ne "PackageManagement" -and $_.Name -ne "PowerShellGet"}) # Don't want to risk accidentally blowing away the main modules needed for updating...
                            {
                                Write-Host "   - Uninstalling old version $($oldModule.Version) of '$($oldModule.Name)'..." @noNewLineSwitch
                                $Host.UI.RawUI.WindowTitle = "Uninstalling old version of '$($oldModule.Name)'..."
                                Uninstall-Module -Name $oldModule.Name -RequiredVersion $oldModule.Version -Force -ErrorAction SilentlyContinue @verboseParameter @allowPrereleaseParameter
                                if ($?)
                                {
                                    Write-Host -ForegroundColor Green "  Done."
                                    [array]$global:modulesRemoved += "$($oldModule.Name) version $($oldModule.Version)"
                                }
                                # Unload the old module in case it was automatically loaded in this console
                                if (Get-Module -Name $oldModule.Name -ErrorAction SilentlyContinue)
                                {
                                    Write-Host "   - Unloading prior loaded version $($oldModule.Version) of '$($oldModule.Name)'..." @noNewLineSwitch
                                    Remove-Module -Name $oldModule.Name -Force -ErrorAction Inquire @verboseParameter
                                    if ($?) {Write-Host -ForegroundColor Green "  Done."}
                                }
                                # Set the old module's root directory depending on whether it was installed from the Gallery or not
                                $oldModuleBase = $oldModule.InstalledLocation
                                if ([string]::IsNullOrEmpty($oldModuleBase))
                                {
                                    # Probably not installed from the Gallery so use ModuleBase instead
                                    $oldModuleBase = $oldModule.ModuleBase
                                }
                                # Make sure that the root directory of the old module is in its own subdirectory that matches its version, otherwise we might be blowing away the top-level directory along with the new version we just installed
                                if ((Split-Path -Path $oldModuleBase -Leaf -ErrorAction SilentlyContinue) -eq $oldModule.Version)
                                {
                                    if (Test-Path -Path $oldModuleBase -ErrorAction SilentlyContinue)
                                    {
                                        Write-Host "   - Removing old module files from $($oldModuleBase)..." @noNewLineSwitch
                                        $Host.UI.RawUI.WindowTitle = "Cleaning up old version of '$($oldModule.Name)'..."
                                        Remove-Item -Path $oldModuleBase -Recurse -ErrorAction SilentlyContinue @confirmParameter @verboseParameter
                                        if ($?) {Write-Host -ForegroundColor Green "Done."}
                                        else
                                        {
                                            Write-Output "."
                                        }
                                    }
                                    else
                                    {
                                        Write-Verbose -Message "   - Nothing remaining found to remove at $($oldModuleBase)."
                                    }
                                    # Check if the old module directory is still present for some reason
                                    if (Test-Path -Path $oldModuleBase -ErrorAction SilentlyContinue)
                                    {
                                        Write-Warning -Message "Some or all of the path '$($oldModuleBase)' could not be removed - check permissions on this location."
                                    }
                                    else
                                    {
                                        Write-Verbose -Message "  - Successfully removed prior version $($oldModule.Version) of '$($oldModule.Name)' from $($oldModuleBase)."
                                    }
                                    $Host.UI.RawUI.WindowTitle = $originalWindowTitle
                                }
                                else
                                {
                                    Write-Verbose -Message "   - Skipping removal of old '$($oldModule.Name)' files from $oldModuleBase."
                                }
                            }
                        }
                    }
                }
            }
        }
        $installedModule = Get-InstalledModule -Name $moduleToCheck -ErrorAction SilentlyContinue
        if ($null -eq $installedModule)
        {
            # Module was not installed from the Gallery, so we look for it an alternate way
            $installedModule = Get-Module -Name $moduleToCheck -ListAvailable | Sort-Object -Property Version | Select-Object -Last 1
        }
        Write-Host -ForegroundColor Cyan "  - Done checking/installing module '$moduleToCheck'."
        Write-Output "  --"
        # Clean up the variables
        Remove-Variable -Name installedModules -ErrorAction SilentlyContinue
        Remove-Variable -Name installedModule -ErrorAction SilentlyContinue
        Remove-Variable -Name oldModules -ErrorAction SilentlyContinue
        Remove-Variable -Name oldModule -ErrorAction SilentlyContinue
        Remove-Variable -Name onlineModule -ErrorAction SilentlyContinue
        Write-Host -ForegroundColor DarkCyan " - Done checking/installing requested modules."
        Write-Output "  --"
    }
    else
    {
        Write-Output " - Nothing to do! Specify -UpdateExistingInstalledModules, -ModulesToCheck or -ModulesAndVersionsToCheck to perform module checks/installs/updates."
    }
}
catch
{
    Write-Host -ForegroundColor Red $_.Exception
    Write-Error "Unable to download/install '$moduleToCheck' - check Internet access etc."
}
finally
{
    if ($global:modulesInstalled.Count -ge 1)
    {
        Write-Host -ForegroundColor Cyan " - Modules Installed:"
        foreach ($moduleInstalled in $global:modulesInstalled | Select-Object -Unique)
        {
            Write-Host -ForegroundColor Green "  - $moduleInstalled"
        }
    }
    if ($global:modulesUpdated.Count -ge 1)
    {
        Write-Host -ForegroundColor Cyan " - Modules Updated:"
        foreach ($moduleUpdated in $global:modulesUpdated | Select-Object -Unique)
        {
            Write-Host -ForegroundColor Magenta "  - $moduleUpdated"
        }
    }
    if ($global:modulesRemoved.Count -ge 1)
    {
        Write-Host -ForegroundColor Cyan " - Module Versions Uninstalled/Removed:"
        foreach ($moduleRemoved in $global:modulesRemoved | Select-Object -Unique)
        {
            Write-Host -ForegroundColor DarkGreen "  - $moduleRemoved"
        }
    }
    if ($global:modulesUnchanged.Count -ge 1)
    {
        Write-Host -ForegroundColor Cyan " - Modules Unchanged:"
        foreach ($moduleUnchanged in $global:modulesUnchanged | Select-Object -Unique)
        {
            Write-Host -ForegroundColor Gray "  - $moduleUnchanged"
        }
    }
    if (!$global:modulesInstalled -and !$global:modulesUpdated)
    {
        Write-Host -ForegroundColor Gray " - No modules were installed or updated."
    }
    $Host.UI.RawUI.WindowTitle = $originalWindowTitle
}
