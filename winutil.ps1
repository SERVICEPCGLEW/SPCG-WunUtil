<#
.NOTES
    Author         : Service PC Glew @servicepcglew
    Runspace Author: @DeveloperDurp
    GitHub         : https://github.com/servicepcglew
    Version        : 26.05.21
#>

param (
    [string]$Config,
    [switch]$Noui,
    [switch]$Offline
)

if ($Config) {
    $PARAM_CONFIG = $Config
}

$PARAM_NOUI = $false
if ($Noui) {
    $PARAM_NOUI = $true
}

$PARAM_OFFLINE = $false
if ($Offline) {
    $PARAM_OFFLINE = $true
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "WinUtil is unable to run on your system, powershell execution is restricted by security policies" -ForegroundColor Red
    return
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "Winutil needs to be run as Administrator. Attempting to relaunch."
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://servicepcglew-winutil.pages.dev/winutil.ps1))) $($argList -join ' ')"
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    break
}

# Load DLLs
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.PSScriptRoot = $PSScriptRoot
$sync.version = "26.05.21"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.preferences = @{}
$sync.ProcessRunning = $false
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
$sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
$sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()
$sync.currentTab = "Instalar"
$sync.selectedAppsStackPanel
$sync.selectedAppsPopup

$dateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

# Set the path for the winutil directory
$winutildir = "$env:LocalAppData\winutil"
New-Item $winutildir -ItemType Directory -Force | Out-Null

$logdir = "$winutildir\logs"
New-Item $logdir -ItemType Directory -Force | Out-Null
Start-Transcript -Path "$logdir\winutil_$dateTime.log" -Append -NoClobber | Out-Null

# Set PowerShell window title
$Host.UI.RawUI.WindowTitle = "WinUtil (Admin)"
clear-host
    function Add-SelectedAppsMenuItem {
        <#
        .SYNOPSIS
            This is a helper function that generates and adds the Menu Items to the Selected Apps Popup.

        .Parameter name
            The actual Name of an App like "Chrome" or "Brave"
            This name is contained in the "Content" property inside the applications.json
        .PARAMETER key
            The key which identifies an app object in applications.json
            For Chrome this would be "WPFInstallchrome" because "WPFInstall" is prepended automatically for each key in applications.json
        #>

        param ([string]$name, [string]$key)

        $selectedAppGrid = New-Object Windows.Controls.Grid

        $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "*"}))
        $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "30"}))

        # Sets the name to the Content as well as the Tooltip, because the parent Popup Border has a fixed width and text could "overflow".
        # With the tooltip, you can still read the whole entry on hover
        $selectedAppLabel = New-Object Windows.Controls.Label
        $selectedAppLabel.Content = $name
        $selectedAppLabel.ToolTip = $name
        $selectedAppLabel.HorizontalAlignment = "Left"
        $selectedAppLabel.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        [System.Windows.Controls.Grid]::SetColumn($selectedAppLabel, 0)
        $selectedAppGrid.Children.Add($selectedAppLabel)

        $selectedAppRemoveButton = New-Object Windows.Controls.Button
        $selectedAppRemoveButton.FontFamily = "Segoe MDL2 Assets"
        $selectedAppRemoveButton.Content = [string]([char]0xE711)
        $selectedAppRemoveButton.HorizontalAlignment = "Center"
        $selectedAppRemoveButton.Tag = $key
        $selectedAppRemoveButton.ToolTip = "Remove the App from Selection"
        $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::StyleProperty, "HoverButtonStyle")

        # Highlight the Remove icon on Hover
        $selectedAppRemoveButton.Add_MouseEnter({ $this.Foreground = "Red" })
        $selectedAppRemoveButton.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor") })
        $selectedAppRemoveButton.Add_Click({
            $sync.($this.Tag).isChecked = $false # On click of the remove button, we only have to uncheck the corresponding checkbox. This will kick of all necessary changes to update the UI
        })
        [System.Windows.Controls.Grid]::SetColumn($selectedAppRemoveButton, 1)
        $selectedAppGrid.Children.Add($selectedAppRemoveButton)
        # Add new Element to Popup
        $sync.selectedAppsstackPanel.Children.Add($selectedAppGrid)
    }
function Find-AppsByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Apps on the Install Tab and hides all entries that do not match the string

        .PARAMETER SearchString
            The string to be searched for
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$SearchString = ""
    )
    # Reset the visibility if the search string is empty or the search is cleared
    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        $sync.ItemsControl.Items | ForEach-Object {
            # Each item is a StackPanel container
            $_.Visibility = [Windows.Visibility]::Visible

            if ($_.Children.Count -ge 2) {
                $categoryLabel = $_.Children[0]
                $wrapPanel = $_.Children[1]

                # Keep category label visible
                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                # Respect the collapsed state of categories (indicated by + prefix)
                if ($categoryLabel.Content -like "+*") {
                    $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                } else {
                    $wrapPanel.Visibility = [Windows.Visibility]::Visible
                }

                # Show all apps within the category
                $wrapPanel.Children | ForEach-Object {
                    $_.Visibility = [Windows.Visibility]::Visible
                }
            }
        }
        return
    }

    # Perform search
    $sync.ItemsControl.Items | ForEach-Object {
        # Each item is a StackPanel container with Children[0] = label, Children[1] = WrapPanel
        if ($_.Children.Count -ge 2) {
            $categoryLabel = $_.Children[0]
            $wrapPanel = $_.Children[1]
            $categoryHasMatch = $false

            # Keep category label visible
            $categoryLabel.Visibility = [Windows.Visibility]::Visible

            # Search through apps in this category
            $wrapPanel.Children | ForEach-Object {
                $appEntry = $sync.configs.applicationsHashtable.$($_.Tag)
                if ($appEntry.Content -like "*$SearchString*" -or $appEntry.Description -like "*$SearchString*") {
                    # Show the App and mark that this category has a match
                    $_.Visibility = [Windows.Visibility]::Visible
                    $categoryHasMatch = $true
                }
                else {
                    $_.Visibility = [Windows.Visibility]::Collapsed
                }
            }

            # If category has matches, show the WrapPanel and update the category label to expanded state
            if ($categoryHasMatch) {
                $wrapPanel.Visibility = [Windows.Visibility]::Visible
                $_.Visibility = [Windows.Visibility]::Visible
                # Update category label to show expanded state (-)
                if ($categoryLabel.Content -like "+*") {
                    $categoryLabel.Content = $categoryLabel.Content -replace "^\+ ", "- "
                }
            } else {
                # Hide the entire category container if no matches
                $_.Visibility = [Windows.Visibility]::Collapsed
            }
        }
    }
}
function Find-TweaksByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Tweaks on the Tweaks Tab and hides all entries that do not match the search string

        .PARAMETER SearchString
            The string to be searched for
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$SearchString = ""
    )

    # Reset the visibility if the search string is empty or the search is cleared
    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        # Show all categories
        $tweakspanel = $sync.Form.FindName("tweakspanel")
        $tweakspanel.Children | ForEach-Object {
            $_.Visibility = [Windows.Visibility]::Visible

            # Foreach category section, show all items
            if ($_ -is [Windows.Controls.Border]) {
                $_.Visibility = [Windows.Visibility]::Visible

                # Find ItemsControl
                $dockPanel = $_.Child
                if ($dockPanel -is [Windows.Controls.DockPanel]) {
                    $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] }
                    if ($itemsControl) {
                        # Show items in the category
                        foreach ($item in $itemsControl.Items) {
                            if ($item -is [Windows.Controls.Label]) {
                                $item.Visibility = [Windows.Visibility]::Visible
                            } elseif ($item -is [Windows.Controls.DockPanel] -or
                                      $item -is [Windows.Controls.StackPanel]) {
                                $item.Visibility = [Windows.Visibility]::Visible
                            }
                        }
                    }
                }
            }
        }
        return
    }

    # Search for matching tweaks when search string is not null
    $tweakspanel = $sync.Form.FindName("tweakspanel")

    $tweakspanel.Children | ForEach-Object {
        $categoryBorder = $_
        $categoryVisible = $false

        if ($_ -is [Windows.Controls.Border]) {
            # Find the ItemsControl
            $dockPanel = $_.Child
            if ($dockPanel -is [Windows.Controls.DockPanel]) {
                $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] }
                if ($itemsControl) {
                    $categoryLabel = $null

                    # Process all items in the ItemsControl
                    for ($i = 0; $i -lt $itemsControl.Items.Count; $i++) {
                        $item = $itemsControl.Items[$i]

                        if ($item -is [Windows.Controls.Label]) {
                            $categoryLabel = $item
                            $item.Visibility = [Windows.Visibility]::Collapsed
                        } elseif ($item -is [Windows.Controls.DockPanel]) {
                            $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1
                            $label = $item.Children | Where-Object { $_ -is [Windows.Controls.Label] } | Select-Object -First 1

                            if ($label -and ($label.Content -like "*$SearchString*" -or $label.ToolTip -like "*$SearchString*")) {
                                $item.Visibility = [Windows.Visibility]::Visible
                                if ($categoryLabel) { $categoryLabel.Visibility = [Windows.Visibility]::Visible }
                                $categoryVisible = $true
                            } else {
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }
                        } elseif ($item -is [Windows.Controls.StackPanel]) {
                            # StackPanel which contain checkboxes or other elements
                            $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1

                            if ($checkbox -and ($checkbox.Content -like "*$SearchString*" -or $checkbox.ToolTip -like "*$SearchString*")) {
                                $item.Visibility = [Windows.Visibility]::Visible
                                if ($categoryLabel) { $categoryLabel.Visibility = [Windows.Visibility]::Visible }
                                $categoryVisible = $true
                            } else {
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }
                        }
                    }
                }
            }

            # Set the visibility based on if any item matched
            $categoryBorder.Visibility = if ($categoryVisible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }

        }
    }
}
function Get-LocalizedYesNo {
    <#
    .SYNOPSIS
    This function runs choice.exe and captures its output to extract yes no in a localized Windows

    .DESCRIPTION
    The function retrieves the output of the command 'cmd /c "choice <nul 2>nul"' and converts the default output for Yes and No
    in the localized format, such as "Yes=<first character>, No=<second character>".

    .EXAMPLE
    $yesNoArray = Get-LocalizedYesNo
    Write-Host "Yes=$($yesNoArray[0]), No=$($yesNoArray[1])"
    #>

    # Run choice and capture its options as output
    # The output shows the options for Yes and No as "[Y,N]?" in the (partially) localized format.
    # eg. English: [Y,N]?
    # Dutch: [Y,N]?
    # German: [J,N]?
    # French: [O,N]?
    # Spanish: [S,N]?
    # Italian: [S,N]?
    # Russian: [Y,N]?

    $line = cmd /c "choice <nul 2>nul"
    $charactersArray = @()
    $regexPattern = '([a-zA-Z])'
    $charactersArray = [regex]::Matches($line, $regexPattern) | ForEach-Object { $_.Groups[1].Value }

    Write-Debug "According to takeown.exe local Yes is $charactersArray[0]"
    # Return the array of characters
    return $charactersArray

  }
function Get-WinUtilSelectedPackages
{
     <#
    .SYNOPSIS
        Sorts given packages based on installer preference and availability.

    .OUTPUTS
        Hashtable. Key = Package Manager, Value = ArrayList of packages to install
    #>
    param (
        [Parameter(Mandatory=$true)]
        $PackageList,
        [Parameter(Mandatory=$true)]
        [PackageManagers]$Preference
    )

    if ($PackageList.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    $packages = [System.Collections.Hashtable]::new()
    $packagesWinget = [System.Collections.ArrayList]::new()
    $packagesChoco = [System.Collections.ArrayList]::new()
    $packages[[PackageManagers]::Winget] = $packagesWinget
    $packages[[PackageManagers]::Choco] = $packagesChoco

    Write-Debug "Checking packages using Preference '$($Preference)'"

    foreach ($package in $PackageList) {
        switch ($Preference) {
            "Choco" {
                if ($package.choco -eq "na") {
                    Write-Debug "$($package.content) has no Choco value."
                    $null = $packagesWinget.add($($package.winget))
                    Write-Host "Queueing $($package.winget) for WinGet..."
                } else {
                    $null = $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey..."
                }
                break
            }
            "Winget" {
                if ($package.winget -eq "na") {
                    Write-Debug "$($package.content) has no WinGet value."
                    $null = $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey..."
                } else {
                    $null = $packagesWinget.add($($package.winget))
                    Write-Host "Queueing $($package.winget) for WinGet..."
                }
                break
            }
        }
    }

    return $packages
}
Function Get-WinUtilToggleStatus {
    <#

    .SYNOPSIS
        Pulls the registry keys for the given toggle switch and checks whether the toggle should be checked or unchecked

    .PARAMETER ToggleSwitch
        The name of the toggle to check

    .OUTPUTS
        Boolean to set the toggle's status to

    #>

    Param($ToggleSwitch)

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry

    try {
        if (($ToggleSwitchReg.path -imatch "hku") -and !(Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            $null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)
            if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) {
                Write-Debug "HKU drive created successfully."
            } else {
                Write-Debug "Failed to create HKU drive."
            }
        }
    } catch {
        Write-Error "An error occurred regarding the HKU Drive: $_"
        return $false
    }

    if ($ToggleSwitchReg) {
        $count = 0

        foreach ($regentry in $ToggleSwitchReg) {
            try {
                if (!(Test-Path $regentry.Path)) {
                    New-Item -Path $regentry.Path -Force | Out-Null
                }
                $regstate = (Get-ItemProperty -path $regentry.Path).$($regentry.Name)
                if ($regstate -eq $regentry.Value) {
                    $count += 1
                    Write-Debug "$($regentry.Name) is true (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
                } else {
                    Write-Debug "$($regentry.Name) is false (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
                }
                if ($null -eq $regstate) {
                    switch ($regentry.DefaultState) {
                        "true" {
                            $regstate = $regentry.Value
                            $count += 1
                        }
                        "false" {
                            $regstate = $regentry.OriginalValue
                        }
                        default {
                            Write-Error "Entry for $($regentry.Name) does not exist and no DefaultState is defined."
                            $regstate = $regentry.OriginalValue
                        }
                    }
                }
            } catch {
                Write-Error "An unexpected error occurred: $_"
            }
        }

        if ($count -eq $ToggleSwitchReg.Count) {
            Write-Debug "$($ToggleSwitchReg.Name) is true (count: $count)"
            return $true
        } else {
            Write-Debug "$($ToggleSwitchReg.Name) is false (count: $count)"
            return $false
        }
    } else {
        return $false
    }
}
function Get-WinUtilVariables {

    <#
    .SYNOPSIS
        Gets every form object of the provided type

    .OUTPUTS
        List containing every object that matches the provided type
    #>
    param (
        [Parameter()]
        [string[]]$Type
    )
    $keys = ($sync.keys).where{ $_ -like "WPF*" }
    if ($Type) {
        $output = $keys | ForEach-Object {
            try {
                $objType = $sync["$psitem"].GetType().Name
                if ($Type -contains $objType) {
                    Write-Output $psitem
                }
            } catch {
                <#I am here so errors don't get outputted for a couple variables that don't have the .GetType() attribute#>
            }
        }
        return $output
    }
    return $keys
}
function Get-WPFObjectName {
    <#
        .SYNOPSIS
            This is a helper function that generates an objectname with the prefix WPF that can be used as a Powershell Variable after compilation.
            To achieve this, all characters that are not a-z, A-Z or 0-9 are simply removed from the name.

        .PARAMETER type
            The type of object for which the name should be generated. (e.g. Label, Button, CheckBox...)

        .PARAMETER name
            The name or description to be used for the object. (invalid characters are removed)

        .OUTPUTS
            A string that can be used as a object/variable name in powershell.
            For example: WPFLabelMicrosoftTools

        .EXAMPLE
            Get-WPFObjectName -type Label -name "Microsoft Tools"
    #>

    param(
        [Parameter(Mandatory, position=0)]
        [string]$type,

        [Parameter(position=1)]
        [string]$name
    )

    $Output = $("WPF"+$type+$name) -replace '[^a-zA-Z0-9]', ''
    return $Output
}
function Hide-WPFInstallAppBusy {
    <#
    .SYNOPSIS
        Hides the busy overlay in the install app area of the WPF form.
        This is used to indicate that an install or uninstall has finished.
    #>
    Invoke-WPFUIThread -ScriptBlock {
        $sync.InstallAppAreaOverlay.Visibility = [Windows.Visibility]::Collapsed
        $sync.InstallAppAreaBorder.IsEnabled = $true
        $sync.InstallAppAreaScrollViewer.Effect.Radius = 0
    }
}
    function Initialize-InstallAppArea {
        <#
            .SYNOPSIS
                Creates a [Windows.Controls.ScrollViewer] containing a [Windows.Controls.ItemsControl] which is setup to use Virtualization to only load the visible elements for performance reasons.
                This is used as the parent object for all category and app entries on the install tab
                Used to as part of the Install Tab UI generation

                Also creates an overlay with a progress bar and text to indicate that an install or uninstall is in progress

            .PARAMETER TargetElement
                The element to which the AppArea should be added

        #>
        param($TargetElement)
        $targetGrid = $sync.Form.FindName($TargetElement)
        $null = $targetGrid.Children.Clear()

        # Create the outer Border for the aren where the apps will be placed
        $Border = New-Object Windows.Controls.Border
        $Border.VerticalAlignment = "Stretch"
        $Border.SetResourceReference([Windows.Controls.Control]::StyleProperty, "BorderStyle")
        $sync.InstallAppAreaBorder = $Border

        # Add a ScrollViewer, because the ItemsControl does not support scrolling by itself
        $scrollViewer = New-Object Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalAlignment = 'Stretch'
        $scrollViewer.VerticalAlignment = 'Stretch'
        $scrollViewer.CanContentScroll = $true
        $sync.InstallAppAreaScrollViewer = $scrollViewer
        $Border.Child = $scrollViewer

        # Initialize the Blur Effect for the ScrollViewer, which will be used to indicate that an install/uninstall is in progress
        $blurEffect = New-Object Windows.Media.Effects.BlurEffect
        $blurEffect.Radius = 0
        $scrollViewer.Effect = $blurEffect

        ## Create the ItemsControl, which will be the parent of all the app entries
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'
        $scrollViewer.Content = $itemsControl

        # Use WrapPanel to create dynamic columns based on AppEntryWidth and window width
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.WrapPanel])
        $factory.SetValue([Windows.Controls.WrapPanel]::OrientationProperty, [Windows.Controls.Orientation]::Horizontal)
        $factory.SetValue([Windows.Controls.WrapPanel]::HorizontalAlignmentProperty, [Windows.HorizontalAlignment]::Left)
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Add the Border containing the App Area to the target Grid
        $targetGrid.Children.Add($Border) | Out-Null

        $overlay = New-Object Windows.Controls.Border
        $overlay.CornerRadius = New-Object Windows.CornerRadius(10)
        $overlay.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallOverlayBackgroundColor")
        $overlay.Visibility = [Windows.Visibility]::Collapsed

        # Also add the overlay to the target Grid on top of the App Area
        $targetGrid.Children.Add($overlay) | Out-Null
        $sync.InstallAppAreaOverlay = $overlay

        $overlayText = New-Object Windows.Controls.TextBlock
        $overlayText.Text = "Installing apps..."
        $overlayText.HorizontalAlignment = 'Center'
        $overlayText.VerticalAlignment = 'Center'
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
        $overlayText.Background = "Transparent"
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "HeaderFontSize")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontFamilyProperty, "MainFontFamily")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontWeightProperty, "MainFontWeight")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::MarginProperty, "MainMargin")
        $sync.InstallAppAreaOverlayText = $overlayText

        $progressbar = New-Object Windows.Controls.ProgressBar
        $progressbar.Name = "ProgressBar"
        $progressbar.Width = 250
        $progressbar.Height = 50
        $sync.ProgressBar = $progressbar

        # Add a TextBlock overlay for the progress bar text
        $progressBarTextBlock = New-Object Windows.Controls.TextBlock
        $progressBarTextBlock.Name = "progressBarTextBlock"
        $progressBarTextBlock.FontWeight = [Windows.FontWeights]::Bold
        $progressBarTextBlock.FontSize = 16
        $progressBarTextBlock.Width = $progressbar.Width
        $progressBarTextBlock.Height = $progressbar.Height
        $progressBarTextBlock.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "ProgressBarTextColor")
        $progressBarTextBlock.TextTrimming = "CharacterEllipsis"
        $progressBarTextBlock.Background = "Transparent"
        $sync.progressBarTextBlock = $progressBarTextBlock

        # Create a Grid to overlay the text on the progress bar
        $progressGrid = New-Object Windows.Controls.Grid
        $progressGrid.Width = $progressbar.Width
        $progressGrid.Height = $progressbar.Height
        $progressGrid.Margin = "0,10,0,10"
        $progressGrid.Children.Add($progressbar) | Out-Null
        $progressGrid.Children.Add($progressBarTextBlock) | Out-Null

        $overlayStackPanel = New-Object Windows.Controls.StackPanel
        $overlayStackPanel.Orientation = "Vertical"
        $overlayStackPanel.HorizontalAlignment = 'Center'
        $overlayStackPanel.VerticalAlignment = 'Center'
        $overlayStackPanel.Children.Add($overlayText) | Out-Null
        $overlayStackPanel.Children.Add($progressGrid) | Out-Null

        $overlay.Child = $overlayStackPanel

        return $itemsControl
    }
function Initialize-InstallAppEntry {
    <#
        .SYNOPSIS
            Creates the app entry to be placed on the install tab for a given app
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Apps should be placed
        .PARAMETER appKey
            The Key of the app inside the $sync.configs.applicationsHashtable
    #>
        param(
            [Windows.Controls.WrapPanel]$TargetElement,
            $appKey
        )

        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.Style = $sync.Form.Resources.AppEntryBorderStyle
        $border.Tag = $appKey
        $border.ToolTip = $Apps.$appKey.description
        $border.Add_MouseEnter({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        })
        $border.Add_MouseLeave({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        })
        $border.Add_MouseRightButtonUp({
            # Store the selected app in a global variable so it can be used in the popup
            $sync.appPopupSelectedApp = $this.Tag
            # Set the popup position to the current mouse position
            $sync.appPopup.PlacementTarget = $this
            $sync.appPopup.IsOpen = $true
        })

        $checkBox = New-Object Windows.Controls.CheckBox
        # Sanitize the name for WPF
        $checkBox.Name = $appKey -replace '-', '_'
        # Store the original appKey in Tag
        $checkBox.Tag = $appKey
        $checkbox.Style = $sync.Form.Resources.AppEntryCheckboxStyle
        $checkbox.Add_Checked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        })

        $checkbox.Add_Unchecked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        })

        # Create the TextBlock for the application name
        $appName = New-Object Windows.Controls.TextBlock
        $appName.Style = $sync.Form.Resources.AppEntryNameStyle
        $appName.Text = $Apps.$appKey.content

        # Change color to Green if FOSS
        if ($Apps.$appKey.foss -eq $true) {
            $appName.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "FOSSColor")
            $appName.FontWeight = "Bold"
        }

        # Add the name to the Checkbox
        $checkBox.Content = $appName

        # Add accessibility properties to make the elements screen reader friendly
        $checkBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $Apps.$appKey.content)
        $border.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $Apps.$appKey.content)

        $border.Child = $checkBox
        # Add the border to the corresponding Category
        $TargetElement.Children.Add($border) | Out-Null
        return $checkbox
    }
function Initialize-InstallCategoryAppList {
    <#
        .SYNOPSIS
            Clears the Target Element and sets up a "Loading" message. This is done, because loading of all apps can take a bit of time in some scenarios
            Iterates through all Categories and Apps and adds them to the UI
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Categories and Apps should be placed
        .PARAMETER Apps
            The Hashtable of Apps to be added to the UI
            The Categories are also extracted from the Apps Hashtable

    #>
        param(
            $TargetElement,
            $Apps
        )

        # Pre-group apps by category
        $appsByCategory = @{}
        foreach ($appKey in $Apps.Keys) {
            $category = $Apps.$appKey.Category
            if (-not $appsByCategory.ContainsKey($category)) {
                $appsByCategory[$category] = @()
            }
            $appsByCategory[$category] += $appKey
        }
        foreach ($category in $($appsByCategory.Keys | Sort-Object)) {
            # Create a container for category label + apps
            $categoryContainer = New-Object Windows.Controls.StackPanel
            $categoryContainer.Orientation = "Vertical"
            $categoryContainer.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $categoryContainer.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            [System.Windows.Automation.AutomationProperties]::SetName($categoryContainer, $Category)

            # Bind Width to the ItemsControl's ActualWidth to force full-row layout in WrapPanel
            $binding = New-Object Windows.Data.Binding
            $binding.Path = New-Object Windows.PropertyPath("ActualWidth")
            $binding.RelativeSource = New-Object Windows.Data.RelativeSource([Windows.Data.RelativeSourceMode]::FindAncestor, [Windows.Controls.ItemsControl], 1)
            [void][Windows.Data.BindingOperations]::SetBinding($categoryContainer, [Windows.FrameworkElement]::WidthProperty, $binding)

            # Add category label to container
            $toggleButton = New-Object Windows.Controls.Label
            $toggleButton.Content = "- $Category"
            $toggleButton.Tag = "CategoryToggleButton"
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "LabelboxForegroundColor")
            $toggleButton.Cursor = [System.Windows.Input.Cursors]::Hand
            $toggleButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            $sync.$Category = $toggleButton

            # Add click handler to toggle category visibility
            $toggleButton.Add_MouseLeftButtonUp({
                param($sender, $e)

                # Find the parent StackPanel (categoryContainer)
                $categoryContainer = $sender.Parent
                if ($categoryContainer -and $categoryContainer.Children.Count -ge 2) {
                    # The WrapPanel is the second child
                    $wrapPanel = $categoryContainer.Children[1]

                    # Toggle visibility
                    if ($wrapPanel.Visibility -eq [Windows.Visibility]::Visible) {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                        # Change - to +
                        $sender.Content = $sender.Content -replace "^- ", "+ "
                    } else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                        # Change + to -
                        $sender.Content = $sender.Content -replace "^\+ ", "- "
                    }
                }
            })

            $null = $categoryContainer.Children.Add($toggleButton)

            # Add wrap panel for apps to container
            $wrapPanel = New-Object Windows.Controls.WrapPanel
            $wrapPanel.Orientation = "Horizontal"
            $wrapPanel.HorizontalAlignment = "Left"
            $wrapPanel.VerticalAlignment = "Top"
            $wrapPanel.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $wrapPanel.Visibility = [Windows.Visibility]::Visible
            $wrapPanel.Tag = "CategoryWrapPanel_$category"

            $null = $categoryContainer.Children.Add($wrapPanel)

            # Add the entire category container to the target element
            $null = $TargetElement.Items.Add($categoryContainer)

            # Add apps to the wrap panel
            $appsByCategory[$category] | Sort-Object | ForEach-Object {
                $sync.$_ = $(Initialize-InstallAppEntry -TargetElement $wrapPanel -AppKey $_)
            }
        }
    }
function Install-WinUtilChoco {

    <#

    .SYNOPSIS
        Installs Chocolatey if it is not already installed

    #>
    if ((Test-WinUtilPackageManager -choco) -eq "installed") {
        return
    }

    Write-Host "Chocolatey is not installed. Installing now..."
    Invoke-WebRequest -Uri https://community.chocolatey.org/install.ps1 -UseBasicParsing | Invoke-Expression
}
function Install-WinUtilProgramChoco {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    if ($Action -eq 'Install') {
        Start-Process -FilePath choco -ArgumentList "install $Programs -y" -NoNewWindow -Wait
    } else {
        Start-Process -FilePath choco -ArgumentList "uninstall $Programs -y" -NoNewWindow -Wait
    }
}
Function Install-WinUtilProgramWinget {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    # Helper to print lines with progress bar coloring (DarkYellow/Orange) override
    function Write-WinUtilLine {
        param (
            [string]$Line,
            [string]$Color
        )
        if ($Line) {
            if ($Line -match "█|░|(\d+%)") {
                Write-Host $Line -ForegroundColor DarkYellow
            } elseif ($Color) {
                Write-Host $Line -ForegroundColor $Color
            } else {
                Write-Host $Line
            }
        }
    }

    if ($Action -eq 'Install') {
        foreach ($program in $Programs) {
            if ($program -eq "9NKSQGP7F2NH" -or $program -eq "9NBDXK71NK08") {
                Write-Host "Instalando '$program' desde la Microsoft Store..."
                $output = winget install $program --accept-package-agreements --accept-source-agreements --source msstore --silent 2>&1
            } else {
                Write-Host "Instalando '$program' desde winget..."
                $output = winget install $program --accept-package-agreements --accept-source-agreements --source winget --silent 2>&1
            }

            $isAlreadyInstalled = $false
            $hasSuccessKeywords = $false
            foreach ($line in $output) {
                if ($line -match "ya está instalado|ya instalado|ninguna actualizaci|no hay versiones m.s recientes|already installed|no upgrade available|no newer package version") {
                    $isAlreadyInstalled = $true
                }
                if ($line -match "instalado correctamente|actualizado correctamente|successfully installed|successfully upgraded|exitosamente|iniciado correctamente") {
                    $hasSuccessKeywords = $true
                }
            }

            if ($isAlreadyInstalled) {
                foreach ($line in $output) {
                    Write-WinUtilLine -Line $line
                }
            } elseif ($LASTEXITCODE -eq 0 -or $hasSuccessKeywords) {
                foreach ($line in $output) {
                    Write-WinUtilLine -Line $line -Color "Green"
                }
            } else {
                foreach ($line in $output) {
                    Write-WinUtilLine -Line $line -Color "Red"
                }
            }
        }
    } else {
        # For each program, detect if it was installed from msstore or winget and use the correct source
        foreach ($program in $Programs) {
            $installedEntry = $Sync.InstalledPrograms | Where-Object { 
                $_.Id -eq $program -or 
                ($program -eq "9NKSQGP7F2NH" -and $_.Id -like "*5319275A.WhatsAppDesktop*") -or 
                ($program -eq "9NBDXK71NK08" -and $_.Id -like "*5319275A.51895FA4EA97F*") 
            } | Select-Object -First 1

            if ($installedEntry -and ($installedEntry.Source -eq "msstore" -or $installedEntry.Id -like "MSIX\*")) {
                Write-Host "Desinstalando '$program' desde la Microsoft Store..."
                $output = winget uninstall $program --source msstore --silent 2>&1
            } else {
                Write-Host "Desinstalando '$program' desde winget..."
                $output = winget uninstall $program --source winget --silent 2>&1
            }

            $isAlreadyUninstalled = $false
            $hasSuccessKeywords = $false
            foreach ($line in $output) {
                if ($line -match "no se encontró ningún paquete instalado|no se encontr. ning.n paquete instalado|not found|not installed") {
                    $isAlreadyUninstalled = $true
                }
                if ($line -match "desinstalado correctamente|successfully uninstalled|exitosamente|eliminado correctamente") {
                    $hasSuccessKeywords = $true
                }
            }

            if ($isAlreadyUninstalled) {
                foreach ($line in $output) {
                    Write-WinUtilLine -Line $line
                }
            } elseif ($LASTEXITCODE -eq 0 -or $hasSuccessKeywords) {
                foreach ($line in $output) {
                    Write-WinUtilLine -Line $line -Color "Green"
                }
            } else {
                foreach ($line in $output) {
                    Write-WinUtilLine -Line $line -Color "Red"
                }
            }
        }
    }
}
function Install-WinUtilWinget {
    <#

    .SYNOPSIS
        Installs WinGet if not already installed.

    .DESCRIPTION
        installs winGet if needed
    #>
    if ((Test-WinUtilPackageManager -winget) -eq "installed") {
        return
    }

    Write-Host "WinGet is not installed. Installing now..." -ForegroundColor Red

    Install-PackageProvider -Name NuGet -Force
    Install-Module -Name Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager -AllUsers
}
function Invoke-WinUtilAssets {
  param (
      $type,
      $Size,
      [switch]$render
  )

  # Create the Viewbox and set its size
  $LogoViewbox = New-Object Windows.Controls.Viewbox
  $LogoViewbox.Width = $Size
  $LogoViewbox.Height = $Size

  # Create a Canvas to hold the paths
  $canvas = New-Object Windows.Controls.Canvas
  $canvas.Width = 100
  $canvas.Height = 100

  # Define a scale factor for the content inside the Canvas
  $scaleFactor = $Size / 100

  # Apply a scale transform to the Canvas content
  $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
  $canvas.LayoutTransform = $scaleTransform

  switch ($type) {
      'logo' {
          $customLogoPath = ""
          if ($sync.PSScriptRoot) {
              $customLogoPath = "$($sync.PSScriptRoot)\logo.png"
          } elseif ($PSScriptRoot) {
              $customLogoPath = "$PSScriptRoot\logo.png"
          } else {
              $customLogoPath = ".\logo.png"
          }

          if (Test-Path $customLogoPath) {
              try {
                  $logoBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                  $logoBitmap.BeginInit()
                  $logoBitmap.UriSource = [Uri]$customLogoPath
                  $logoBitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                  $logoBitmap.EndInit()

                  if ($render) {
                      return $logoBitmap
                  }

                  $logoImage = New-Object System.Windows.Controls.Image
                  $logoImage.Source = $logoBitmap
                  $logoImage.Stretch = [System.Windows.Media.Stretch]::Uniform
                  
                  # Set high quality scaling so the raster logo scales beautifully and remains crisp
                  [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($logoImage, [System.Windows.Media.BitmapScalingMode]::HighQuality)
                  
                  # Adjust the Viewbox height to match the official logo.png aspect ratio (839x564)
                  $LogoViewbox.Height = $Size * (564 / 839)
                  $LogoViewbox.Child = $logoImage
                  return $LogoViewbox
              } catch {
                  Write-Debug "Could not load logo.png: $_"
              }
          }
      }
      'checkmark' {
          $canvas.Width = 512
          $canvas.Height = 512

          $scaleFactor = $Size / 2.54
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 1.27,0 A 1.27,1.27 0 1,0 1.27,2.54 A 1.27,1.27 0 1,0 1.27,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#39ba00")

          # Define the checkmark path
          $checkmarkPathData = "M 0.873 1.89 L 0.41 1.391 A 0.17 0.17 0 0 1 0.418 1.151 A 0.17 0.17 0 0 1 0.658 1.16 L 1.016 1.543 L 1.583 1.013 A 0.17 0.17 0 0 1 1.599 1 L 1.865 0.751 A 0.17 0.17 0 0 1 2.105 0.759 A 0.17 0.17 0 0 1 2.097 0.999 L 1.282 1.759 L 0.999 2.022 L 0.874 1.888 Z"
          $checkmarkPath = New-Object Windows.Shapes.Path
          $checkmarkPath.Data = [Windows.Media.Geometry]::Parse($checkmarkPathData)
          $checkmarkPath.Fill = [Windows.Media.Brushes]::White

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($checkmarkPath) | Out-Null
      }
      'warning' {
          $canvas.Width = 512
          $canvas.Height = 512

          # Define a scale factor for the content inside the Canvas
          $scaleFactor = $Size / 512  # Adjust scaling based on the canvas size
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 256,0 A 256,256 0 1,0 256,512 A 256,256 0 1,0 256,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#f41b43")

          # Define the exclamation mark path
          $exclamationPathData = "M 256 307.2 A 35.89 35.89 0 0 1 220.14 272.74 L 215.41 153.3 A 35.89 35.89 0 0 1 251.27 116 H 260.73 A 35.89 35.89 0 0 1 296.59 153.3 L 291.86 272.74 A 35.89 35.89 0 0 1 256 307.2 Z"
          $exclamationPath = New-Object Windows.Shapes.Path
          $exclamationPath.Data = [Windows.Media.Geometry]::Parse($exclamationPathData)
          $exclamationPath.Fill = [Windows.Media.Brushes]::White

          # Get the bounds of the exclamation mark path
          $exclamationBounds = $exclamationPath.Data.Bounds

          # Calculate the center position for the exclamation mark path
          $exclamationCenterX = ($canvas.Width - $exclamationBounds.Width) / 2 - $exclamationBounds.X
          $exclamationPath.SetValue([Windows.Controls.Canvas]::LeftProperty, $exclamationCenterX)

          # Define the rounded rectangle at the bottom (dot of exclamation mark)
          $roundedRectangle = New-Object Windows.Shapes.Rectangle
          $roundedRectangle.Width = 80
          $roundedRectangle.Height = 80
          $roundedRectangle.RadiusX = 30
          $roundedRectangle.RadiusY = 30
          $roundedRectangle.Fill = [Windows.Media.Brushes]::White

          # Calculate the center position for the rounded rectangle
          $centerX = ($canvas.Width - $roundedRectangle.Width) / 2
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::LeftProperty, $centerX)
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::TopProperty, 324.34)

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($exclamationPath) | Out-Null
          $canvas.Children.Add($roundedRectangle) | Out-Null
      }
      default {
          Write-Host "Invalid type: $type"
      }
  }

  # Add the Canvas to the Viewbox
  $LogoViewbox.Child = $canvas

  if ($render) {
      # Measure and arrange the canvas to ensure proper rendering
      $canvas.Measure([Windows.Size]::new($canvas.Width, $canvas.Height))
      $canvas.Arrange([Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
      $canvas.UpdateLayout()

      # Initialize RenderTargetBitmap correctly with dimensions
      $renderTargetBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($canvas.Width, $canvas.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)

      # Render the canvas to the bitmap
      $renderTargetBitmap.Render($canvas)

      # Create a BitmapFrame from the RenderTargetBitmap
      $bitmapFrame = [Windows.Media.Imaging.BitmapFrame]::Create($renderTargetBitmap)

      # Create a PngBitmapEncoder and add the frame
      $bitmapEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
      $bitmapEncoder.Frames.Add($bitmapFrame)

      # Save to a memory stream
      $imageStream = New-Object System.IO.MemoryStream
      $bitmapEncoder.Save($imageStream)
      $imageStream.Position = 0

      # Load the stream into a BitmapImage
      $bitmapImage = [Windows.Media.Imaging.BitmapImage]::new()
      $bitmapImage.BeginInit()
      $bitmapImage.StreamSource = $imageStream
      $bitmapImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmapImage.EndInit()

      return $bitmapImage
  } else {
      return $LogoViewbox
  }
}
Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        InvokeWinUtilCurrentSystem -Checkbox "winget"

    #>

    param(
        $CheckBox
    )
    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).choco -split ";")
            if ($dependencies -in $apps) {
                Write-Output $psitem.name
            }
        }
    }

    if ($checkbox -eq "winget") {

        $originalEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        $rawOutput = winget list
        [Console]::OutputEncoding = $originalEncoding

        $sepIndex = -1
        for ($i = 0; $i -lt $rawOutput.Count; $i++) {
            if ($rawOutput[$i] -match '^[- ]+$' -and $rawOutput[$i] -match '-{10,}') {
                $sepIndex = $i
                break
            }
        }

        if ($sepIndex -gt 0) {
            $headerLine = $rawOutput[$sepIndex - 1]
            $matches = [regex]::Matches($headerLine, "\S+")
            $cols = @()
            foreach ($m in $matches) {
                $cols += [PSCustomObject]@{
                    Name  = $m.Value
                    Index = $m.Index
                }
            }
            for ($c = 0; $c -lt $cols.Count; $c++) {
                if ($c -lt $cols.Count - 1) {
                    $cols[$c] | Add-Member -NotePropertyName Length -NotePropertyValue ($cols[$c+1].Index - $cols[$c].Index)
                } else {
                    $cols[$c] | Add-Member -NotePropertyName Length -NotePropertyValue -1
                }
            }

            $Sync.InstalledPrograms = @()
            for ($i = $sepIndex + 1; $i -lt $rawOutput.Count; $i++) {
                $line = $rawOutput[$i]
                if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^<') {
                    continue
                }
                $obj = [PSCustomObject]@{}
                for ($c = 0; $c -lt $cols.Count; $c++) {
                    $idx = $cols[$c].Index
                    $len = $cols[$c].Length
                    if ($idx -ge $line.Length) {
                        $val = ""
                    } elseif ($len -eq -1) {
                        $val = $line.Substring($idx).Trim()
                    } else {
                        $val = $line.Substring($idx, [Math]::Min($len, $line.Length - $idx)).Trim()
                    }

                    $propName = switch ($c) {
                        0 { "Name" }
                        1 { "Id" }
                        2 { "Version" }
                        3 { if ($cols.Count -eq 4) { "Source" } else { "Available" } }
                        4 { "Source" }
                    }
                    $obj | Add-Member -NotePropertyName $propName -NotePropertyValue $val
                }
                $Sync.InstalledPrograms += $obj
            }
        } else {
            $Sync.InstalledPrograms = @()
        }

        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $appKey = $psitem.Key
            $appConfig = $sync.configs.applications.$appKey
            $dependencies = @($appConfig.winget -split ";")
            $dep = $dependencies[-1]
            $content = $appConfig.content

            $isInstalled = $false
            if ($dep) {
                $isInstalled = ($sync.InstalledPrograms | Where-Object {
                    $_.Id -eq $dep -or 
                    $_.Id -like "$dep.*" -or
                    ($dep.Contains(".") -and $_.Id -like "*$($dep.Split('.')[-1])*") -or
                    $_.Name -eq $content -or
                    ($content -and $content.Length -ge 4 -and $_.Name.Replace(" ", "").ToLower().Contains($content.Replace(" ", "").ToLower())) -or
                    ($content -and $content.Length -ge 4 -and $content.Replace(" ", "").ToLower().Contains($_.Name.Replace(" ", "").ToLower())) -or
                    ($appKey -eq "WPFInstalladobe" -and $_.Name -like "*Adobe Acrobat*") -or
                    ($dep -eq "9NKSQGP7F2NH" -and $_.Id -like "*5319275A.WhatsAppDesktop*") -or
                    ($dep -eq "9NBDXK71NK08" -and $_.Id -like "*5319275A.51895FA4EA97F*")
                }) -ne $null
            }

            if ($isInstalled) {
                Write-Output $psitem.name
            }
        }
    }

    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $appxKeys = $entry.appx
            $invokeScript = $entry.InvokeScript
            $entryType = $entry.Type

            if ($registryKeys -or $serviceKeys) {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path) {
                                $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            } else {
                if ($invokeScript -or $appxKeys) {
                    Write-Debug "Skipping $Config in Get Installed: no detectable registry, scheduled task, or service state."
                }
            }
        }
    }
}
function Invoke-WinUtilExplorerUpdate {
     <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>
    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        Invoke-WPFRunspace -ScriptBlock {
            # Define the Win32 type only if it doesn't exist
            if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@
            }

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2

            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE,
                [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 100,
                [ref]([IntPtr]::Zero))
        }
    } elseif ($action -eq "restart") {
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}
function Invoke-WinUtilFeatureInstall {
    <#

    .SYNOPSIS
        Converts all the values from the tweaks.json and routes them to the appropriate function

    #>

    param(
        $CheckBox
    )

    if($sync.configs.feature.$CheckBox.feature) {
        Foreach( $feature in $sync.configs.feature.$CheckBox.feature ) {
            try {
                Write-Host "Installing $feature"
                Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
            } catch {
                if ($CheckBox.Exception.Message -like "*requires elevation*") {
                    Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" }
                } else {

                    Write-Warning "Unable to Install $feature due to unhandled exception."
                    Write-Warning $CheckBox.Exception.StackTrace
                }
            }
        }
    }
    if($sync.configs.feature.$CheckBox.InvokeScript) {
        Foreach( $script in $sync.configs.feature.$CheckBox.InvokeScript ) {
            try {
                $Scriptblock = [scriptblock]::Create($script)

                Write-Host "Running Script for $CheckBox"
                Invoke-Command $scriptblock -ErrorAction stop
            } catch {
                if ($CheckBox.Exception.Message -like "*requires elevation*") {
                    Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" }
                } else {
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" }
                    Write-Warning "Unable to Install $feature due to unhandled exception."
                    Write-Warning $CheckBox.Exception.StackTrace
                }
            }
        }
    }
}
function Invoke-WinUtilFontScaling {
    <#

    .SYNOPSIS
        Applies UI and font scaling for accessibility

    .PARAMETER ScaleFactor
        Sets the scaling from 0.75 and 2.0.
        Default is 1.0 (100% - no scaling)

    .EXAMPLE
        Invoke-WinUtilFontScaling -ScaleFactor 1.25
        # Applies 125% scaling
    #>

    param (
        [double]$ScaleFactor = 1.0
    )

    # Validate if scale factor is within the range
    if ($ScaleFactor -lt 0.75 -or $ScaleFactor -gt 2.0) {
        Write-Warning "Scale factor must be between 0.75 and 2.0. Using 1.0 instead."
        $ScaleFactor = 1.0
    }

    # Define an array for resources to be scaled
    $fontResources = @(
        # Fonts
        "FontSize",
        "ButtonFontSize",
        "HeaderFontSize",
        "TabButtonFontSize",
        "ConfigTabButtonFontSize",
        "IconFontSize",
        "SettingsIconFontSize",
        "CloseIconFontSize",
        "AppEntryFontSize",
        "SearchBarTextBoxFontSize",
        "SearchBarClearButtonFontSize",
        "CustomDialogFontSize",
        "CustomDialogFontSizeHeader",
        "ConfigUpdateButtonFontSize",
        # Buttons and UI
        "CheckBoxBulletDecoratorSize",
        "ButtonWidth",
        "ButtonHeight",
        "TabButtonWidth",
        "TabButtonHeight",
        "IconButtonSize",
        "AppEntryWidth",
        "SearchBarWidth",
        "SearchBarHeight",
        "CustomDialogWidth",
        "CustomDialogHeight",
        "CustomDialogLogoSize",
        "ToolTipWidth"
    )

    # Apply scaling to each resource
    foreach ($resourceName in $fontResources) {
        try {
            # Get the default font size from the theme configuration
            $originalValue = $sync.configs.themes.shared.$resourceName
            if ($originalValue) {
                # Convert string to double since values are stored as strings
                $originalValue = [double]$originalValue
                # Calculates and applies the new font size
                $newValue = [math]::Round($originalValue * $ScaleFactor, 1)
                $sync.Form.Resources[$resourceName] = $newValue
                Write-Debug "Scaled $resourceName from original $originalValue to $newValue (factor: $ScaleFactor)"
            }
        }
        catch {
            Write-Warning "Failed to scale resource $resourceName : $_"
        }
    }

    # Update the font scaling percentage displayed on the UI
    if ($sync.FontScalingValue) {
        $percentage = [math]::Round($ScaleFactor * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    }

    Write-Debug "Font scaling applied with factor: $ScaleFactor"
}


function Invoke-WinUtilInstallPSProfile {
    if (-not (Get-Command wt)) {
        Write-Host "Windows Terminal not found installing..."
        Install-WinUtilWinget
        winget install Microsoft.WindowsTerminal --source winget --silent
    }

    if (-not (Get-Command pwsh)) {
        Write-Host "Powershell 7 not found installing..."
        Install-WinUtilWinget
        winget install Microsoft.PowerShell --source winget --silent
    }

    wt new-tab pwsh -NoExit -Command "irm https://github.com/servicepcglew/powershell-profile/raw/main/setup.ps1 | iex"
}
function Write-Win11ISOLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("HH:mm:ss")
    $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
        $current = $sync["WPFWin11ISOStatusLog"].Text
        if ($current -eq "Ready. Please select a Windows 11 ISO to begin.") {
            $sync["WPFWin11ISOStatusLog"].Text = "[$ts] $Message"
        } else {
            $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $Message"
        }
        $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
        $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
    })
}

function Invoke-WinUtilISOBrowse {
    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Title            = "Select Windows 11 ISO"
    $dlg.Filter           = "ISO files (*.iso)|*.iso|All files (*.*)|*.*"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $isoPath    = $dlg.FileName
    $fileSizeGB = [math]::Round((Get-Item $isoPath).Length / 1GB, 2)

    $sync["WPFWin11ISOPath"].Text           = $isoPath
    $sync["WPFWin11ISOFileInfo"].Text       = "File size: $fileSizeGB GB"
    $sync["WPFWin11ISOFileInfo"].Visibility = "Visible"
    $sync["WPFWin11ISOMountSection"].Visibility       = "Visible"
    $sync["WPFWin11ISOVerifyResultPanel"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility      = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility      = "Collapsed"

    Write-Win11ISOLog "ISO selected: $isoPath  ($fileSizeGB GB)"
}

function Invoke-WinUtilISOMountAndVerify {
    $isoPath = $sync["WPFWin11ISOPath"].Text

    if ([string]::IsNullOrWhiteSpace($isoPath) -or $isoPath -eq "No ISO selected...") {
        [System.Windows.MessageBox]::Show("Please select an ISO file first.", "No ISO Selected", "OK", "Warning")
        return
    }

    Write-Win11ISOLog "Mounting ISO: $isoPath"
    Set-WinUtilProgressBar -Label "Mounting ISO..." -Percent 10

    try {
        Mount-DiskImage -ImagePath $isoPath

        do {
            Start-Sleep -Milliseconds 500
        } until ((Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter)

        $driveLetter = (Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter + ":"
        Write-Win11ISOLog "Mounted at drive $driveLetter"

        Set-WinUtilProgressBar -Label "Verifying ISO contents..." -Percent 30

        $wimPath = Join-Path $driveLetter "sources\install.wim"
        $esdPath = Join-Path $driveLetter "sources\install.esd"

        if (-not (Test-Path $wimPath) -and -not (Test-Path $esdPath)) {
            Dismount-DiskImage -ImagePath $isoPath
            Write-Win11ISOLog "ERROR: install.wim/install.esd not found - not a valid Windows ISO."
            [System.Windows.MessageBox]::Show(
                "This does not appear to be a valid Windows ISO.`n`ninstall.wim / install.esd was not found.",
                "Invalid ISO", "OK", "Error")
            Set-WinUtilProgressBar -Label "" -Percent 0
            return
        }

        $activeWim = if (Test-Path $wimPath) { $wimPath } else { $esdPath }

        Set-WinUtilProgressBar -Label "Reading image metadata..." -Percent 55
        $imageInfo = Get-WindowsImage -ImagePath $activeWim | Select-Object ImageIndex, ImageName

        if (-not ($imageInfo | Where-Object { $_.ImageName -match "Windows 11" })) {
            Dismount-DiskImage -ImagePath $isoPath
            Write-Win11ISOLog "ERROR: No 'Windows 11' edition found in the image."
            [System.Windows.MessageBox]::Show(
                "No Windows 11 edition was found in this ISO.`n`nOnly official Windows 11 ISOs are supported.",
                "Not a Windows 11 ISO", "OK", "Error")
            Set-WinUtilProgressBar -Label "" -Percent 0
            return
        }

        $sync["Win11ISOImageInfo"] = $imageInfo

        $sync["WPFWin11ISOMountDriveLetter"].Text = "Mounted at: $driveLetter   |   Image file: $(Split-Path $activeWim -Leaf)"
        $sync["WPFWin11ISOEditionComboBox"].Dispatcher.Invoke([action]{
            $sync["WPFWin11ISOEditionComboBox"].Items.Clear()
            foreach ($img in $imageInfo) {
                [void]$sync["WPFWin11ISOEditionComboBox"].Items.Add("$($img.ImageIndex): $($img.ImageName)")
            }
            if ($sync["WPFWin11ISOEditionComboBox"].Items.Count -gt 0) {
                $proIndex = -1
                for ($i = 0; $i -lt $sync["WPFWin11ISOEditionComboBox"].Items.Count; $i++) {
                    if ($sync["WPFWin11ISOEditionComboBox"].Items[$i] -match "Windows 11 Pro(?![\w ])") {
                        $proIndex = $i; break
                    }
                }
                $sync["WPFWin11ISOEditionComboBox"].SelectedIndex = if ($proIndex -ge 0) { $proIndex } else { 0 }
            }
        })
        $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Visible"

        $sync["Win11ISODriveLetter"] = $driveLetter
        $sync["Win11ISOWimPath"]     = $activeWim
        $sync["Win11ISOImagePath"]   = $isoPath
        $sync["WPFWin11ISOModifySection"].Visibility = "Visible"

        Set-WinUtilProgressBar -Label "ISO verified" -Percent 100
        Write-Win11ISOLog "ISO verified OK.  Editions found: $($imageInfo.Count)"
    } catch {
        Write-Win11ISOLog "ERROR during mount/verify: $_"
        [System.Windows.MessageBox]::Show(
            "An error occurred while mounting or verifying the ISO:`n`n$_",
            "Error", "OK", "Error")
    } finally {
        Start-Sleep -Milliseconds 800
        Set-WinUtilProgressBar -Label "" -Percent 0
    }
}

function Invoke-WinUtilISOModify {
    $isoPath     = $sync["Win11ISOImagePath"]
    $driveLetter = $sync["Win11ISODriveLetter"]
    $wimPath     = $sync["Win11ISOWimPath"]

    if (-not $isoPath) {
        [System.Windows.MessageBox]::Show(
            "No verified ISO found. Please complete Steps 1 and 2 first.",
            "Not Ready", "OK", "Warning")
        return
    }

    $selectedItem     = $sync["WPFWin11ISOEditionComboBox"].SelectedItem
    $selectedWimIndex = 1
    if ($selectedItem -and $selectedItem -match '^(\d+):') {
        $selectedWimIndex = [int]$Matches[1]
    } elseif ($sync["Win11ISOImageInfo"]) {
        $selectedWimIndex = $sync["Win11ISOImageInfo"][0].ImageIndex
    }
    $selectedEditionName = if ($selectedItem) { ($selectedItem -replace '^\d+:\s*', '') } else { "Unknown" }
    Write-Win11ISOLog "Selected edition: $selectedEditionName (Index $selectedWimIndex)"

    $sync["WPFWin11ISOModifyButton"].IsEnabled = $false
    $sync["Win11ISOModifying"] = $true

    $existingWorkDir = Get-Item -Path (Join-Path $env:TEMP "WinUtil_Win11ISO*") |
        Where-Object { $_.PSIsContainer } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    $workDir = if ($existingWorkDir) {
        Write-Win11ISOLog "Reusing existing temp directory: $($existingWorkDir.FullName)"
        $existingWorkDir.FullName
    } else {
        Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    }

    $autounattendContent = if ($WinUtilAutounattendXml) {
        $WinUtilAutounattendXml
    } else {
        $toolsXml = Join-Path $PSScriptRoot "..\..\tools\autounattend.xml"
        if (Test-Path $toolsXml) { Get-Content $toolsXml -Raw } else { "" }
    }

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $injectDrivers = $sync["WPFWin11ISOInjectDrivers"].IsChecked -eq $true

    $runspace.SessionStateProxy.SetVariable("sync",                $sync)
    $runspace.SessionStateProxy.SetVariable("isoPath",             $isoPath)
    $runspace.SessionStateProxy.SetVariable("driveLetter",         $driveLetter)
    $runspace.SessionStateProxy.SetVariable("wimPath",             $wimPath)
    $runspace.SessionStateProxy.SetVariable("workDir",             $workDir)
    $runspace.SessionStateProxy.SetVariable("selectedWimIndex",    $selectedWimIndex)
    $runspace.SessionStateProxy.SetVariable("selectedEditionName", $selectedEditionName)
    $runspace.SessionStateProxy.SetVariable("autounattendContent", $autounattendContent)
    $runspace.SessionStateProxy.SetVariable("injectDrivers",       $injectDrivers)

    $isoScriptFuncDef   = "function Invoke-WinUtilISOScript {`n" + ${function:Invoke-WinUtilISOScript}.ToString() + "`n}"
    $win11ISOLogFuncDef = "function Write-Win11ISOLog {`n"       + ${function:Write-Win11ISOLog}.ToString()       + "`n}"
    $runspace.SessionStateProxy.SetVariable("isoScriptFuncDef",   $isoScriptFuncDef)
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($isoScriptFuncDef))
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        try {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
            })

            Log "Creating working directory: $workDir"
            $isoContents = Join-Path $workDir "iso_contents"
            $mountDir    = Join-Path $workDir "wim_mount"
            New-Item -ItemType Directory -Path $isoContents, $mountDir -Force
            SetProgress "Copying ISO contents..." 10

            Log "Copying ISO contents from $driveLetter to $isoContents..."
            & robocopy $driveLetter $isoContents /E /NFL /NDL /NJH /NJS
            Log "ISO contents copied."
            SetProgress "Mounting install.wim..." 25

            $localWim = Join-Path $isoContents "sources\install.wim"
            if (-not (Test-Path $localWim)) { $localWim = Join-Path $isoContents "sources\install.esd" }
            Set-ItemProperty -Path $localWim -Name IsReadOnly -Value $false

            Log "Mounting install.wim (Index ${selectedWimIndex}: $selectedEditionName) at $mountDir..."
            Mount-WindowsImage -ImagePath $localWim -Index $selectedWimIndex -Path $mountDir
            SetProgress "Modifying install.wim..." 45

            Log "Applying WinUtil modifications to install.wim..."
            Invoke-WinUtilISOScript -ScratchDir $mountDir -ISOContentsDir $isoContents -AutoUnattendXml $autounattendContent -InjectCurrentSystemDrivers $injectDrivers -Log { param($m) Log $m }

            SetProgress "Cleaning up component store (WinSxS)..." 56
            Log "Running DISM component store cleanup (/ResetBase)..."
            & dism /English "/image:$mountDir" /Cleanup-Image /StartComponentCleanup /ResetBase | ForEach-Object { Log $_ }
            Log "Component store cleanup complete."

            SetProgress "Saving modified install.wim..." 65
            Log "Dismounting and saving install.wim. This will take several minutes..."
            Dismount-WindowsImage -Path $mountDir -Save
            Log "install.wim saved."

            SetProgress "Removing unused editions from install.wim..." 70
            Log "Exporting edition '$selectedEditionName' (Index $selectedWimIndex) to a single-edition install.wim..."
            $exportWim = Join-Path $isoContents "sources\install_export.wim"
            Export-WindowsImage -SourceImagePath $localWim -SourceIndex $selectedWimIndex -DestinationImagePath $exportWim
            Remove-Item -Path $localWim -Force
            Rename-Item -Path $exportWim -NewName "install.wim" -Force
            $localWim = Join-Path $isoContents "sources\install.wim"
            Log "Unused editions removed. install.wim now contains only '$selectedEditionName'."

            SetProgress "Dismounting source ISO..." 80
            Log "Dismounting original ISO..."
            Dismount-DiskImage -ImagePath $isoPath

            $sync["Win11ISOWorkDir"]     = $workDir
            $sync["Win11ISOContentsDir"] = $isoContents

            SetProgress "Modification complete" 100
            Log "install.wim modification complete. Choose an output option in Step 4."

            $sync["WPFWin11ISOOutputSection"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"
            })
        } catch {
            Log "ERROR during modification: $_"

            try {
                if (Test-Path $mountDir) {
                    $mountedImages = Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mountDir }
                    if ($mountedImages) {
                        Log "Cleaning up: dismounting install.wim (discarding changes)..."
                        Dismount-WindowsImage -Path $mountDir -Discard
                    }
                }
            } catch { Log "Warning: could not dismount install.wim during cleanup: $_" }

            try {
                $mountedISO = Get-DiskImage -ImagePath $isoPath
                if ($mountedISO -and $mountedISO.Attached) {
                    Log "Cleaning up: dismounting source ISO..."
                    Dismount-DiskImage -ImagePath $isoPath
                }
            } catch { Log "Warning: could not dismount ISO during cleanup: $_" }

            try {
                if (Test-Path $workDir) {
                    Log "Cleaning up: removing temp directory $workDir..."
                    Remove-Item -Path $workDir -Recurse -Force
                }
            } catch { Log "Warning: could not remove temp directory during cleanup: $_" }

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "An error occurred during install.wim modification:`n`n$_",
                    "Modification Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOModifying"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOModifyButton"].IsEnabled = $true
                if ($sync["WPFWin11ISOOutputSection"].Visibility -ne "Visible") {
                    $sync["WPFWin11ISOSelectSection"].Visibility = "Visible"
                    $sync["WPFWin11ISOMountSection"].Visibility  = "Visible"
                    $sync["WPFWin11ISOModifySection"].Visibility = "Visible"
                }
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOCheckExistingWork {
    if ($sync["Win11ISOContentsDir"] -and (Test-Path $sync["Win11ISOContentsDir"])) { return }

    # Check if ISO modification is currently in progress
    if ($sync["Win11ISOModifying"]) {
        return
    }

    $existingWorkDir = Get-Item -Path (Join-Path $env:TEMP "WinUtil_Win11ISO*") |
        Where-Object { $_.PSIsContainer } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $existingWorkDir) { return }

    $isoContents = Join-Path $existingWorkDir.FullName "iso_contents"
    if (-not (Test-Path $isoContents)) { return }

    $sync["Win11ISOWorkDir"]     = $existingWorkDir.FullName
    $sync["Win11ISOContentsDir"] = $isoContents

    $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"

    $modified = $existingWorkDir.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
    Write-Win11ISOLog "Existing working directory found: $($existingWorkDir.FullName)"
    Write-Win11ISOLog "Last modified: $modified - Skipping Steps 1-3 and resuming at Step 4."
    Write-Win11ISOLog "Click 'Clean & Reset' if you want to start over with a new ISO."

    [System.Windows.MessageBox]::Show(
        "A previous WinUtil ISO working directory was found:`n`n$($existingWorkDir.FullName)`n`n(Last modified: $modified)`n`nStep 4 (output options) has been restored so you can save the already-modified image.`n`nClick 'Clean & Reset' in Step 4 if you want to start over.",
        "Existing Work Found", "OK", "Info")
}

function Invoke-WinUtilISOCleanAndReset {
    $workDir = $sync["Win11ISOWorkDir"]

    if ($workDir -and (Test-Path $workDir)) {
        $confirm = [System.Windows.MessageBox]::Show(
            "This will delete the temporary working directory:`n`n$workDir`n`nAnd reset the interface back to the start.`n`nContinue?",
            "Clean & Reset", "YesNo", "Warning")
        if ($confirm -ne "Yes") { return }
    }

    $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $false

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",    $sync)
    $runspace.SessionStateProxy.SetVariable("workDir", $workDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        try {
            if ($workDir) {
                $mountDir = Join-Path $workDir "wim_mount"
                try {
                    $mountedImages = Get-WindowsImage -Mounted |
                                     Where-Object { $_.Path -like "$workDir*" }
                    if ($mountedImages) {
                        foreach ($img in $mountedImages) {
                            Log "Dismounting WIM at: $($img.Path) (discarding changes)..."
                            SetProgress "Dismounting WIM image..." 3
                            Dismount-WindowsImage -Path $img.Path -Discard
                            Log "WIM dismounted successfully."
                        }
                    } elseif (Test-Path $mountDir) {
                        Log "No mounted WIM reported by Get-WindowsImage. Running DISM /Cleanup-Wim as a precaution..."
                        SetProgress "Running DISM cleanup..." 3
                        & dism /English /Cleanup-Wim | ForEach-Object { Log $_ }
                    }
                } catch {
                    Log "Warning: could not dismount WIM cleanly. Attempting DISM /Cleanup-Wim fallback: $_"
                    try { & dism /English /Cleanup-Wim | ForEach-Object { Log $_ } }
                    catch { Log "Warning: DISM /Cleanup-Wim also failed: $_" }
                }
            }

            if ($workDir -and (Test-Path $workDir)) {
                Log "Scanning files to delete in: $workDir"
                SetProgress "Scanning files..." 5

                $allFiles = @(Get-ChildItem -Path $workDir -File -Recurse -Force)
                $allDirs  = @(Get-ChildItem -Path $workDir -Directory -Recurse -Force |
                    Sort-Object { $_.FullName.Length } -Descending)
                $total   = $allFiles.Count
                $deleted = 0

                Log "Found $total files to delete."

                foreach ($f in $allFiles) {
                    try { Remove-Item -Path $f.FullName -Force } catch { Log "WARNING: could not delete $($f.FullName): $_" }
                    $deleted++
                    if ($deleted % 100 -eq 0 -or $deleted -eq $total) {
                        $pct = [math]::Round(($deleted / [Math]::Max($total, 1)) * 85) + 5
                        SetProgress "Deleting files in $($f.Directory.Name)... ($deleted / $total)" $pct
                    }
                }

                foreach ($d in $allDirs) {
                    try { Remove-Item -Path $d.FullName -Force } catch {}
                }

                try { Remove-Item -Path $workDir -Recurse -Force } catch {}

                if (Test-Path $workDir) {
                    Log "WARNING: some items could not be deleted in $workDir"
                } else {
                    Log "Temp directory deleted successfully."
                }
            } else {
                Log "No temp directory found - resetting UI."
            }

            SetProgress "Resetting UI..." 95
            Log "Resetting interface..."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["Win11ISOWorkDir"]     = $null
                $sync["Win11ISOContentsDir"] = $null
                $sync["Win11ISOImagePath"]   = $null
                $sync["Win11ISODriveLetter"] = $null
                $sync["Win11ISOWimPath"]     = $null
                $sync["Win11ISOImageInfo"]   = $null
                $sync["Win11ISOUSBDisks"]    = $null

                $sync["WPFWin11ISOPath"].Text                   = "No ISO selected..."
                $sync["WPFWin11ISOFileInfo"].Visibility          = "Collapsed"
                $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Collapsed"
                $sync["WPFWin11ISOOptionUSB"].Visibility         = "Collapsed"
                $sync["WPFWin11ISOOutputSection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility      = "Collapsed"
                $sync["WPFWin11ISOSelectSection"].Visibility     = "Visible"
                $sync["WPFWin11ISOModifyButton"].IsEnabled       = $true
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled   = $true

                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0

                $sync["WPFWin11ISOStatusLog"].Text   = "Ready. Please select a Windows 11 ISO to begin."
            })
        } catch {
            Log "ERROR during Clean & Reset: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOExport {
    $contentsDir = $sync["Win11ISOContentsDir"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show(
            "No modified ISO content found.  Please complete Steps 1-3 first.",
            "Not Ready", "OK", "Warning")
        return
    }

    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Title            = "Save Modified Windows 11 ISO"
    $dlg.Filter           = "ISO files (*.iso)|*.iso"
    $dlg.FileName         = "Win11_Modified_$(Get-Date -Format 'yyyyMMdd').iso"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $outputISO = $dlg.FileName

    # Locate oscdimg.exe (Windows ADK or winget per-user install)
    $oscdimg = Get-ChildItem "C:\Program Files (x86)\Windows Kits" -Recurse -Filter "oscdimg.exe" |
               Select-Object -First 1 -ExpandProperty FullName
    if (-not $oscdimg) {
        $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                   Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                   Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $oscdimg) {
        Write-Win11ISOLog "oscdimg.exe not found. Attempting to install via winget..."
        try {
            # First ensure winget is installed and operational
            Install-WinUtilWinget

            $winget = Get-Command winget
            $result = & $winget install -e --id Microsoft.OSCDIMG --accept-package-agreements --accept-source-agreements
            Write-Win11ISOLog "winget output: $result"
            $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                       Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                       Select-Object -First 1 -ExpandProperty FullName
        } catch {
            Write-Win11ISOLog "winget not available or install failed: $_"
        }

        if (-not $oscdimg) {
            Write-Win11ISOLog "oscdimg.exe still not found after install attempt."
            [System.Windows.MessageBox]::Show(
                "oscdimg.exe could not be found or installed automatically.`n`nPlease install it manually:`n  winget install -e --id Microsoft.OSCDIMG`n`nOr install the Windows ADK from:`nhttps://learn.microsoft.com/windows-hardware/get-started/adk-install",
                "oscdimg Not Found", "OK", "Warning")
            return
        }
        Write-Win11ISOLog "oscdimg.exe installed successfully."
    }

    $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $false

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)
    $runspace.SessionStateProxy.SetVariable("outputISO",   $outputISO)
    $runspace.SessionStateProxy.SetVariable("oscdimg",     $oscdimg)

    $win11ISOLogFuncDef = "function Write-Win11ISOLog {`n" + ${function:Write-Win11ISOLog}.ToString() + "`n}"
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        try {
            Write-Win11ISOLog "Exporting to ISO: $outputISO"
            SetProgress "Building ISO..." 10

            $bootData    = "2#p0,e,b`"$contentsDir\boot\etfsboot.com`"#pEF,e,b`"$contentsDir\efi\microsoft\boot\efisys.bin`""
            $oscdimgArgs = @("-m", "-o", "-u2", "-udfver102", "-bootdata:$bootData", "-l`"CTOS_MODIFIED`"", "`"$contentsDir`"", "`"$outputISO`"")

            Write-Win11ISOLog "Running oscdimg..."

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = $oscdimg
            $psi.Arguments              = $oscdimgArgs -join " "
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $proc.Start()

            # Stream stdout line-by-line as oscdimg runs
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ($line.Trim()) { Write-Win11ISOLog $line }
            }

            $proc.WaitForExit()

            # Flush any stderr after process exits
            $stderr = $proc.StandardError.ReadToEnd()
            foreach ($line in ($stderr -split "`r?`n")) {
                if ($line.Trim()) { Write-Win11ISOLog "[stderr]$line" }
            }

            if ($proc.ExitCode -eq 0) {
                SetProgress "ISO exported" 100
                Write-Win11ISOLog "ISO exported successfully: $outputISO"
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show("ISO exported successfully!`n`n$outputISO", "Export Complete", "OK", "Info")
                })
            } else {
                Write-Win11ISOLog "oscdimg exited with code $($proc.ExitCode)."
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show(
                        "oscdimg exited with code $($proc.ExitCode).`nCheck the status log for details.",
                        "Export Error", "OK", "Error")
                })
            }
        } catch {
            Write-Win11ISOLog "ERROR during ISO export: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("ISO export failed:`n`n$_", "Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}
function Invoke-WinUtilISOScript {
    <#
    .SYNOPSIS
        Applies WinUtil modifications to a mounted Windows 11 install.wim image.

    .DESCRIPTION
        Removes AppX bloatware and OneDrive, optionally injects all drivers exported from
        the running system into install.wim and boot.wim (controlled by the
        -InjectCurrentSystemDrivers switch), applies offline registry tweaks (hardware
        bypass, privacy, OOBE, telemetry, update suppression), deletes CEIP/WU
        scheduled-task definition files, and optionally writes autounattend.xml to the ISO
        root and removes the support\ folder from the ISO contents directory.

        All setup scripts embedded in the autounattend.xml <Extensions><File> nodes are
        written directly into the WIM at their target paths under C:\Windows\Setup\Scripts\
        to ensure they survive Windows Setup stripping unrecognised-namespace XML elements
        from the Panther copy of the answer file.

        Mounting/dismounting the WIM is the caller's responsibility (e.g. Invoke-WinUtilISO).

    .PARAMETER ScratchDir
        Mandatory. Full path to the directory where the Windows image is currently mounted.

    .PARAMETER ISOContentsDir
        Optional. Root directory of the extracted ISO contents. When supplied,
        autounattend.xml is written here and the support\ folder is removed.

    .PARAMETER AutoUnattendXml
        Optional. Full XML content for autounattend.xml. If empty, the OOBE bypass
        file is skipped and a warning is logged.

    .PARAMETER InjectCurrentSystemDrivers
        Optional. When $true, exports all drivers from the running system and injects
        them into install.wim and boot.wim index 2 (Windows Setup PE).
        Defaults to $false.

    .PARAMETER Log
        Optional ScriptBlock for progress/status logging. Receives a single [string] argument.

    .EXAMPLE
        Invoke-WinUtilISOScript -ScratchDir "C:\Temp\wim_mount"

    .EXAMPLE
        Invoke-WinUtilISOScript `
            -ScratchDir      $mountDir `
            -ISOContentsDir  $isoRoot `
            -AutoUnattendXml (Get-Content .\tools\autounattend.xml -Raw) `
            -Log             { param($m) Write-Host $m }

    .NOTES
        Author  : Service PC Glew @servicepcglew
        GitHub  : https://github.com/servicepcglew
    #>
    param (
        [Parameter(Mandatory)][string]$ScratchDir,
        [string]$ISOContentsDir = "",
        [string]$AutoUnattendXml = "",
        [bool]$InjectCurrentSystemDrivers = $false,
        [scriptblock]$Log = { param($m) Write-Output $m }
    )

    $adminSID   = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])

    function Set-ISOScriptReg {
        param ([string]$path, [string]$name, [string]$type, [string]$value)
        try {
            & reg add $path /v $name /t $type /d $value /f
            & $Log "Set registry value: $path\$name"
        } catch {
            & $Log "Error setting registry value: $_"
        }
    }

    function Remove-ISOScriptReg {
        param ([string]$path)
        try {
            & reg delete $path /f
            & $Log "Removed registry key: $path"
        } catch {
            & $Log "Error removing registry key: $_"
        }
    }

    function Add-DriversToImage {
        param ([string]$MountPath, [string]$DriverDir, [string]$Label = "image", [scriptblock]$Logger)
        & dism /English "/image:$MountPath" /Add-Driver "/Driver:$DriverDir" /Recurse |
            ForEach-Object { & $Logger "  dism[$Label]: $_" }
    }

    function Invoke-BootWimInject {
        param ([string]$BootWimPath, [string]$DriverDir, [scriptblock]$Logger)
        Set-ItemProperty -Path $BootWimPath -Name IsReadOnly -Value $false
        $mountDir = Join-Path $env:TEMP "WinUtil_BootMount_$(Get-Random)"
        New-Item -Path $mountDir -ItemType Directory -Force
        try {
            & $Logger "Mounting boot.wim (index 2) for driver injection..."
            Mount-WindowsImage -ImagePath $BootWimPath -Index 2 -Path $mountDir
            Add-DriversToImage -MountPath $mountDir -DriverDir $DriverDir -Label "boot" -Logger $Logger
            & $Logger "Saving boot.wim..."
            Dismount-WindowsImage -Path $mountDir -Save
            & $Logger "boot.wim driver injection complete."
        } catch {
            & $Logger "Warning: boot.wim driver injection failed: $_"
            try { Dismount-WindowsImage -Path $mountDir -Discard } catch {}
        } finally {
            Remove-Item -Path $mountDir -Recurse -Force
        }
    }

    # ── 1. Remove provisioned AppX packages ──────────────────────────────────
    & $Log "Removing provisioned AppX packages..."

    $packages = & dism /English "/image:$ScratchDir" /Get-ProvisionedAppxPackages |
        ForEach-Object { if ($_ -match 'PackageName : (.*)') { $matches[1] } }

    $packagePrefixes = @(
        'Clipchamp.Clipchamp',
        'Microsoft.BingNews',
        'Microsoft.BingSearch',
        'Microsoft.BingWeather',
        'Microsoft.GetHelp',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes',
        'Microsoft.OutlookForWindows',
        'Microsoft.Paint',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.StartExperiencesApp',
        'Microsoft.Todos',
        'Microsoft.Windows.DevHome',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.ZuneMusic',
        'MicrosoftCorporationII.QuickAssist',
        'MSTeams'
    )

    $packages | Where-Object { $pkg = $_; $packagePrefixes | Where-Object { $pkg -like "*$_*" } } |
        ForEach-Object { & dism /English "/image:$ScratchDir" /Remove-ProvisionedAppxPackage "/PackageName:$_" }

    # ── 2. Inject current system drivers (optional) ───────────────────────────
    if ($InjectCurrentSystemDrivers) {
        & $Log "Exporting all drivers from running system..."
        $driverExportRoot = Join-Path $env:TEMP "WinUtil_DriverExport_$(Get-Random)"
        New-Item -Path $driverExportRoot -ItemType Directory -Force
        try {
            Export-WindowsDriver -Online -Destination $driverExportRoot

            & $Log "Injecting current system drivers into install.wim..."
            Add-DriversToImage -MountPath $ScratchDir -DriverDir $driverExportRoot -Label "install" -Logger $Log
            & $Log "install.wim driver injection complete."

            if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
                $bootWim = Join-Path $ISOContentsDir "sources\boot.wim"
                if (Test-Path $bootWim) {
                    & $Log "Injecting current system drivers into boot.wim..."
                    Invoke-BootWimInject -BootWimPath $bootWim -DriverDir $driverExportRoot -Logger $Log
                } else {
                    & $Log "Warning: boot.wim not found - skipping boot.wim driver injection."
                }
            }
        } catch {
            & $Log "Error during driver export/injection: $_"
        } finally {
            Remove-Item -Path $driverExportRoot -Recurse -Force
        }
    } else {
        & $Log "Driver injection skipped."
    }

    # ── 3. Registry tweaks ────────────────────────────────────────────────────
    & $Log "Loading offline registry hives..."
    reg load HKLM\zCOMPONENTS "$ScratchDir\Windows\System32\config\COMPONENTS"
    reg load HKLM\zDEFAULT    "$ScratchDir\Windows\System32\config\default"
    reg load HKLM\zNTUSER     "$ScratchDir\Users\Default\ntuser.dat"
    reg load HKLM\zSOFTWARE   "$ScratchDir\Windows\System32\config\SOFTWARE"
    reg load HKLM\zSYSTEM     "$ScratchDir\Windows\System32\config\SYSTEM"

    & $Log "Bypassing system requirements..."
    Set-ISOScriptReg 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'  'SV1' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'  'SV2' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck'       'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck'       'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck'   'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck'       'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\MoSetup'   'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

    & $Log "Disabling sponsored apps..."
    Set-ISOScriptReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled'  'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled'     'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled'  'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed'      'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled'    'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled'          'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled'    'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\MRT'           'DontOfferThroughWUAU' 'REG_DWORD' '1'
    Remove-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
    Remove-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent'       'REG_DWORD' '1'

    & $Log "Enabling local accounts on OOBE..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'

    if ($AutoUnattendXml) {
        try {
            $xmlDoc = [xml]::new()
            $xmlDoc.LoadXml($AutoUnattendXml)

            $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
            $nsMgr.AddNamespace("sg", "https://schneegans.de/windows/unattend-generator/")

            $fileNodes = $xmlDoc.SelectNodes("//sg:File", $nsMgr)
            if ($fileNodes -and $fileNodes.Count -gt 0) {
                foreach ($fileNode in $fileNodes) {
                    $absPath  = $fileNode.GetAttribute("path")
                    $relPath  = $absPath -replace '^[A-Za-z]:[/\\]', ''
                    $destPath = Join-Path $ScratchDir $relPath
                    New-Item -Path (Split-Path $destPath -Parent) -ItemType Directory -Force

                    $ext = [IO.Path]::GetExtension($destPath).ToLower()
                    $encoding = switch ($ext) {
                        { $_ -in '.ps1', '.xml' }        { [System.Text.Encoding]::UTF8 }
                        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new($false, $true) }
                        default                          { [System.Text.Encoding]::Default }
                    }
                    [System.IO.File]::WriteAllBytes($destPath, ($encoding.GetPreamble() + $encoding.GetBytes($fileNode.InnerText.Trim())))
                    & $Log "Pre-staged setup script: $relPath"
                }
            } else {
                & $Log "Warning: no <Extensions><File> nodes found in autounattend.xml - setup scripts not pre-staged."
            }
        } catch {
            & $Log "Warning: could not pre-stage setup scripts from autounattend.xml: $_"
        }

        if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
            $isoDest = Join-Path $ISOContentsDir "autounattend.xml"
            Set-Content -Path $isoDest -Value $AutoUnattendXml -Encoding UTF8 -Force
            & $Log "Written autounattend.xml to ISO root ($isoDest)."
        }
    } else {
        & $Log "Warning: autounattend.xml content is empty - skipping OOBE bypass file."
    }

    & $Log "Disabling reserved storage..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'

    & $Log "Disabling BitLocker device encryption..."
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'

    & $Log "Disabling Chat icon..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    Set-ISOScriptReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

    & $Log "Disabling OneDrive folder backup..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 'REG_DWORD' '1'

    & $Log "Disabling telemetry..."
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection'  'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'

    & $Log "Preventing installation of DevHome and Outlook..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate'      'workCompleted' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate'      'workCompleted' 'REG_DWORD' '1'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'

    & $Log "Disabling Copilot..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'      'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Edge'                   'HubsSidebarEnabled'          'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer'       'DisableSearchBoxSuggestions' 'REG_DWORD' '1'

    & $Log "Disabling Windows Update during OOBE (re-enabled on first logon via FirstLogon.ps1)..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate'              'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions'                 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'UseWUServer'               'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'    'DisableWindowsUpdateAccess' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'    'WUServer'                  'REG_SZ'    'http://localhost:8080'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'    'WUStatusServer'            'REG_SZ'    'http://localhost:8080'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' 'workCompleted' 'REG_DWORD' '1'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Services\BITS'         'Start' 'REG_DWORD' '4'
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv'     'Start' 'REG_DWORD' '4'
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc'       'Start' 'REG_DWORD' '4'
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSvc' 'Start' 'REG_DWORD' '4'

    & $Log "Preventing installation of Teams..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'

    & $Log "Preventing installation of new Outlook..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'

    & $Log "Unloading offline registry hives..."
    reg unload HKLM\zCOMPONENTS
    reg unload HKLM\zDEFAULT
    reg unload HKLM\zNTUSER
    reg unload HKLM\zSOFTWARE
    reg unload HKLM\zSYSTEM

    # ── 4. Delete scheduled task definition files ─────────────────────────────
    & $Log "Deleting scheduled task definition files..."
    $tasksPath = "$ScratchDir\Windows\System32\Tasks"
    Remove-Item "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program"                  -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater"               -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Chkdsk\Proxy"                                            -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting"                  -Force
    Remove-Item "$tasksPath\Microsoft\Windows\InstallService"                                          -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\UpdateOrchestrator"                                      -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\UpdateAssistant"                                         -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\WaaSMedic"                                               -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\WindowsUpdate"                                           -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\WindowsUpdate"                                                   -Recurse -Force
    & $Log "Scheduled task files deleted."

    # ── 5. Remove ISO support folder ─────────────────────────────────────────
    if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
        & $Log "Removing ISO support\ folder..."
        Remove-Item -Path (Join-Path $ISOContentsDir "support") -Recurse -Force
        & $Log "ISO support\ folder removed."
    }
}
function Invoke-WinUtilISORefreshUSBDrives {
    $combo    = $sync["WPFWin11ISOUSBDriveComboBox"]
    $removable = @(Get-Disk | Where-Object { $_.BusType -eq "USB" } | Sort-Object Number)

    $combo.Items.Clear()

    if ($removable.Count -eq 0) {
        $combo.Items.Add("No USB drives detected.")
        $combo.SelectedIndex = 0
        $sync["Win11ISOUSBDisks"] = @()
        Write-Win11ISOLog "No USB drives detected."
        return
    }

    foreach ($disk in $removable) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 1)
        $combo.Items.Add("Disk $($disk.Number): $($disk.FriendlyName)  [$sizeGB GB] - $($disk.PartitionStyle)")
    }
    $combo.SelectedIndex = 0
    Write-Win11ISOLog "Found $($removable.Count) USB drive(s)."
    $sync["Win11ISOUSBDisks"] = $removable
}

function Invoke-WinUtilISOWriteUSB {
    $contentsDir = $sync["Win11ISOContentsDir"]
    $usbDisks    = $sync["Win11ISOUSBDisks"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show("No modified ISO content found. Please complete Steps 1-3 first.", "Not Ready", "OK", "Warning")
        return
    }

    $combo = $sync["WPFWin11ISOUSBDriveComboBox"]
    $selectedIndex = $combo.SelectedIndex
    $selectedItemText = [string]$combo.SelectedItem
    $usbDisks = @($usbDisks)

    $targetDisk = $null
    if ($selectedIndex -ge 0 -and $selectedIndex -lt $usbDisks.Count) {
        $targetDisk = $usbDisks[$selectedIndex]
    } elseif ($selectedItemText -match 'Disk\s+(\d+):') {
        $selectedDiskNum = [int]$matches[1]
        $targetDisk = $usbDisks | Where-Object { $_.Number -eq $selectedDiskNum } | Select-Object -First 1
    }

    if (-not $targetDisk) {
        [System.Windows.MessageBox]::Show("Please select a USB drive from the dropdown.", "No Drive Selected", "OK", "Warning")
        return
    }

    $diskNum    = $targetDisk.Number
    $sizeGB     = [math]::Round($targetDisk.Size / 1GB, 1)

    $confirm = [System.Windows.MessageBox]::Show(
        "ALL data on Disk $diskNum ($($targetDisk.FriendlyName), $sizeGB GB) will be PERMANENTLY ERASED.`n`nAre you sure you want to continue?",
        "Confirm USB Erase", "YesNo", "Warning")

    if ($confirm -ne "Yes") {
        Write-Win11ISOLog "USB write cancelled by user."
        return
    }

    $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $false
    Write-Win11ISOLog "Starting USB write to Disk $diskNum..."

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("diskNum",     $diskNum)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        function Get-FreeDriveLetter {
            $used = (Get-PSDrive -PSProvider FileSystem).Name
            foreach ($c in [char[]](68..90)) {
                if ($used -notcontains [string]$c) { return $c }
            }
            return $null
        }

        try {
            SetProgress "Formatting USB drive..." 10

            # Phase 1: Clean disk via diskpart (retry once if the drive is not yet ready)
            $dpFile1 = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
            "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1 -Encoding ASCII
            Log "Running diskpart clean on Disk $diskNum..."
            $dpCleanOut = diskpart /s $dpFile1
            $dpCleanOut | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile1 -Force

            if (($dpCleanOut -join ' ') -match 'device is not ready') {
                Log "Disk $diskNum was not ready; waiting 5 seconds and retrying clean..."
                Start-Sleep -Seconds 5
                Update-Disk -Number $diskNum
                $dpFile1b = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
                "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1b -Encoding ASCII
                diskpart /s $dpFile1b | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
                Remove-Item $dpFile1b -Force
            }

            # Phase 2: Initialize as GPT
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum
            $diskObj = Get-Disk -Number $diskNum
            if ($diskObj.PartitionStyle -eq 'RAW') {
                Initialize-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum initialized as GPT."
            } else {
                Set-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum converted to GPT (was $($diskObj.PartitionStyle))."
            }

            # Phase 3: Create FAT32 partition via diskpart, then format with Format-Volume
            # (diskpart's 'format' command can fail with "no volume selected" on fresh/never-formatted drives)
            $volLabel = "W11-" + (Get-Date).ToString('yyMMdd')
            $dpFile2  = Join-Path $env:TEMP "winutil_diskpart2_$(Get-Random).txt"
            $maxFat32PartitionMB = 32768
            $diskSizeMB = [int][Math]::Floor((Get-Disk -Number $diskNum).Size / 1MB)
            $createPartitionCommand = "create partition primary"
            if ($diskSizeMB -gt $maxFat32PartitionMB) {
                $createPartitionCommand = "create partition primary size=$maxFat32PartitionMB"
                Log "Disk $diskNum is $diskSizeMB MB; creating FAT32 partition capped at $maxFat32PartitionMB MB (32 GB)."
            }

            @(
                "select disk $diskNum"
                $createPartitionCommand
                "exit"
            ) | Set-Content -Path $dpFile2 -Encoding ASCII
            Log "Creating partitions on Disk $diskNum..."
            diskpart /s $dpFile2 | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile2 -Force

            SetProgress "Formatting USB partition..." 25
            Start-Sleep -Seconds 3
            Update-Disk -Number $diskNum

            $partitions = Get-Partition -DiskNumber $diskNum
            Log "Partitions on Disk $diskNum after creation: $($partitions.Count)"
            foreach ($p in $partitions) {
                Log "  Partition $($p.PartitionNumber)  Type=$($p.Type)  Letter=$($p.DriveLetter)  Size=$([math]::Round($p.Size/1MB))MB"
            }

            $winpePart = $partitions | Where-Object { $_.Type -eq "Basic" } | Select-Object -Last 1
            if (-not $winpePart) {
                throw "Could not find the Basic partition on Disk $diskNum after creation."
            }

            # Format using Format-Volume (reliable on fresh drives; diskpart format fails
            # with 'no volume selected' when the partition has never been formatted before)
            Log "Formatting Partition $($winpePart.PartitionNumber) as FAT32 (label: $volLabel)..."
            Get-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber |
                Format-Volume -FileSystem FAT32 -NewFileSystemLabel $volLabel -Force -Confirm:$false
            Log "Partition $($winpePart.PartitionNumber) formatted as FAT32."

            SetProgress "Assigning drive letters..." 30
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum

            try { Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -AccessPath "$($winpePart.DriveLetter):" } catch {}
            $usbLetter = Get-FreeDriveLetter
            if (-not $usbLetter) { throw "No free drive letters (D-Z) available to assign to the USB data partition." }
            Set-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -NewDriveLetter $usbLetter
            Log "Assigned drive letter $usbLetter to WINPE partition (Partition $($winpePart.PartitionNumber))."
            Start-Sleep -Seconds 2

            $usbDrive = "${usbLetter}:"
            $retries = 0
            while (-not (Test-Path $usbDrive) -and $retries -lt 6) {
                $retries++
                Log "Waiting for $usbDrive to become accessible (attempt $retries/6)..."
                Start-Sleep -Seconds 2
            }
            if (-not (Test-Path $usbDrive)) { throw "Drive $usbDrive is not accessible after letter assignment." }
            Log "USB data partition: $usbDrive"

            $contentSizeBytes = (Get-ChildItem -LiteralPath $contentsDir -File -Recurse -Force | Measure-Object -Property Length -Sum).Sum
            if (-not $contentSizeBytes) { $contentSizeBytes = 0 }
            $usbVolume = Get-Volume -DriveLetter $usbLetter
            $partitionCapacityBytes = [int64]$usbVolume.Size
            $partitionFreeBytes = [int64]$usbVolume.SizeRemaining

            $contentSizeGB = [math]::Round($contentSizeBytes / 1GB, 2)
            $partitionCapacityGB = [math]::Round($partitionCapacityBytes / 1GB, 2)
            $partitionFreeGB = [math]::Round($partitionFreeBytes / 1GB, 2)

            Log "Source content size: $contentSizeGB GB. USB partition capacity: $partitionCapacityGB GB, free: $partitionFreeGB GB."

            if ($contentSizeBytes -gt $partitionCapacityBytes) {
                throw "ISO content ($contentSizeGB GB) is larger than the USB partition capacity ($partitionCapacityGB GB). Use a larger USB drive or reduce image size."
            }

            if ($contentSizeBytes -gt $partitionFreeBytes) {
                throw "Insufficient free space on USB partition. Required: $contentSizeGB GB, available: $partitionFreeGB GB."
            }

            SetProgress "Copying Windows 11 files to USB..." 45

            # Copy files; split install.wim if > 4 GB (FAT32 limit)
            $installWim = Join-Path $contentsDir "sources\install.wim"
            if (Test-Path $installWim) {
                $wimSizeMB = [math]::Round((Get-Item $installWim).Length / 1MB)
                if ($wimSizeMB -gt 3800) {
                    Log "install.wim is $wimSizeMB MB - splitting for FAT32 compatibility... This will take several minutes."
                    $splitDest = Join-Path $usbDrive "sources\install.swm"
                    New-Item -ItemType Directory -Path (Split-Path $splitDest) -Force
                    Split-WindowsImage -ImagePath $installWim -SplitImagePath $splitDest -FileSize 3800 -CheckIntegrity
                    Log "install.wim split complete."
                    Log "Copying remaining files to USB..."
                    & robocopy $contentsDir $usbDrive /E /XF install.wim /NFL /NDL /NJH /NJS
                } else {
                    & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
                }
            } else {
                & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
            }

            SetProgress "Finalising USB drive..." 90
            Log "Files copied to USB."
            SetProgress "USB write complete" 100
            Log "USB drive is ready for use."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "USB drive created successfully!`n`nYou can now boot from this drive to install Windows 11.",
                    "USB Ready", "OK", "Info")
            })
        } catch {
            Log "ERROR during USB write: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("USB write failed:`n`n$_", "USB Write Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}
function Invoke-WinUtilScript {
    <#

    .SYNOPSIS
        Invokes the provided scriptblock. Intended for things that can't be handled with the other functions.

    .PARAMETER Name
        The name of the scriptblock being invoked

    .PARAMETER scriptblock
        The scriptblock to be invoked

    .EXAMPLE
        $Scriptblock = [scriptblock]::Create({"Write-output 'Hello World'"})
        Invoke-WinUtilScript -ScriptBlock $scriptblock -Name "Hello World"

    #>
    param (
        $Name,
        [scriptblock]$scriptblock
    )

    try {
        Write-Host "Running Script for $Name"
        Invoke-Command $scriptblock -ErrorAction Stop
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Warning "The specified command was not found."
        Write-Warning $PSItem.Exception.message
    } catch [System.Management.Automation.RuntimeException] {
        Write-Warning "A runtime exception occurred."
        Write-Warning $PSItem.Exception.message
    } catch [System.Security.SecurityException] {
        Write-Warning "A security exception occurred."
        Write-Warning $PSItem.Exception.message
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied. You do not have permission to perform this operation."
        Write-Warning $PSItem.Exception.message
    } catch {
        # Generic catch block to handle any other type of exception
        Write-Warning "Unable to run script for $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
    }

}
Function Invoke-WinUtilSponsors {
    <#
    .SYNOPSIS
        Lists Sponsors from ServicePCGlew
    .DESCRIPTION
        Lists Sponsors from ServicePCGlew
    .EXAMPLE
        Invoke-WinUtilSponsors
    .NOTES
        This function is used to list sponsors from ServicePCGlew
    #>
    try {
        # Define the URL and headers
        $url = "https://github.com/sponsors/ServicePCGlew"
        $headers = @{
            "User-Agent" = "Chrome/58.0.3029.110"
        }

        # Fetch the webpage content
        try {
            $html = Invoke-RestMethod -Uri $url -Headers $headers
        } catch {
            Write-Output $_.Exception.Message
            exit
        }

        # Use regex to extract the content between "Current sponsors" and "Past sponsors"
        $currentSponsorsPattern = '(?s)(?<=Current sponsors).*?(?=Past sponsors)'
        $currentSponsorsHtml = [regex]::Match($html, $currentSponsorsPattern).Value

        # Use regex to extract the sponsor usernames from the alt attributes in the "Current Sponsors" section
        $sponsorPattern = '(?<=alt="@)[^"]+'
        $sponsors = [regex]::Matches($currentSponsorsHtml, $sponsorPattern) | ForEach-Object { $_.Value }

        # Exclude "ServicePCGlew" from the sponsors
        $sponsors = $sponsors | Where-Object { $_ -ne "ServicePCGlew" }

        # Return the sponsors
        return $sponsors
    } catch {
        Write-Error "An error occurred while fetching or processing the sponsors: $_"
        return $null
    }
}
function Invoke-WinUtilSSHServer {
    <#
    .SYNOPSIS
        Enables OpenSSH server to remote into your windows device
    #>

    # Install the OpenSSH Server feature if not already installed
    if ((Get-WindowsCapability -Name OpenSSH.Server -Online).State -ne "Installed") {
        Write-Host "Enabling OpenSSH Server... This will take a long time"
        Add-WindowsCapability -Name OpenSSH.Server -Online
    }

    Write-Host "Starting the services"

    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    Set-Service -Name ssh-agent -StartupType Automatic
    Start-Service -Name ssh-agent

    #Adding Firewall rule for port 22
    Write-Host "Setting up firewall rules"
    if (-not ((Get-NetFirewallRule -Name 'sshd').Enabled)) {
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        Write-Host "Firewall rule for OpenSSH Server created and enabled."
    }

    # Check for the authorized_keys file
    $sshFolderPath = "$Home\.ssh"
    $authorizedKeysPath = "$sshFolderPath\authorized_keys"

    if (-not (Test-Path -Path $sshFolderPath)) {
        Write-Host "Creating ssh directory..."
        New-Item -Path $sshFolderPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $authorizedKeysPath)) {
        Write-Host "Creating authorized_keys file..."
        New-Item -Path $authorizedKeysPath -ItemType File -Force
        Write-Host "authorized_keys file created at $authorizedKeysPath."
    }

    Write-Host "Configuring sshd_config for standard authorized_keys behavior..."
    $sshdConfigPath = "C:\ProgramData\ssh\sshd_config"

    $configContent = Get-Content -Path $sshdConfigPath -Raw

    $updatedContent = $configContent -replace '(?m)^(Match Group administrators)$', '# $1'
    $updatedContent = $updatedContent -replace '(?m)^(\s+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)$', '# $1'

    if ($updatedContent -ne $configContent) {
        Set-Content -Path $sshdConfigPath -Value $updatedContent -Force
        Write-Host "Commented out administrator-specific SSH key configuration in sshd_config"
        Restart-Service -Name sshd -Force
    }

    Write-Host "OpenSSH server was successfully enabled."
    Write-Host "The config file can be located at C:\ProgramData\ssh\sshd_config"
    Write-Host "Add your public keys to this file -> $authorizedKeysPath"
}
function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.


    #>
    param (
        [string]$theme = "Auto"
    )

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    "Color" {
                        # Convert hex string to RGB values
                        $hexColor = $Value.TrimStart("#")
                        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
                        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
                        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
                        [Windows.Media.Color]::FromRgb($r, $g, $b)
                    }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($_ in $themeProperties) {
            # Apply properties that deal with colors
            if ($_.Name -like "*color*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "ColorBrush"
                # For certain color properties, also set complementary values (e.g., BorderColor -> CBorderColor) This is required because e.g DropShadowEffect requires a <Color> and not a <SolidColorBrush> object
                if ($_.Name -in @("BorderColor", "ButtonBackgroundMouseoverColor")) {
                    Set-ThemeResourceProperty -Name "C$($_.Name)" -Value $_.Value -Type "Color"
                }
            }
            # Apply corner radius properties
            elseif ($_.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($_.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($_.Name -like "*Thickness*") -or ($_.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($_.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "Double"
            }
        }
    }

    $sync.preferences.theme = $theme
    Set-Preferences -save
    Set-WinutilTheme -currentTheme "shared"

    switch ($sync.preferences.theme) {
        "Auto" {
            $systemUsesDarkMode = Get-WinUtilToggleStatus WPFToggleDarkMode
            if ($systemUsesDarkMode) {
                $theme = "Dark"
            }
            else{
                $theme = "Light"
            }

            Set-WinutilTheme -currentTheme $theme
            $themeButtonIcon = [char]0xF08C
        }
        "Dark" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE708
           }
        "Light" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE706
        }
    }

    # Set FOSS Highlight Color
    $fossEnabled = $true
    if ($sync.WPFToggleFOSSHighlight) {
        $fossEnabled = $sync.WPFToggleFOSSHighlight.IsChecked
    }

    if ($fossEnabled) {
         $sync.Form.Resources["FOSSColor"] = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(255, 106, 0)) # #FF6A00
    } else {
         $sync.Form.Resources["FOSSColor"] = $sync.Form.Resources["MainForegroundColor"]
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon
}
function Invoke-WinUtilTweaks {
    <#

    .SYNOPSIS
        Invokes the function associated with each provided checkbox

    .PARAMETER CheckBox
        The checkbox to invoke

    .PARAMETER undo
        Indicates whether to undo the operation contained in the checkbox

    .PARAMETER KeepServiceStartup
        Indicates whether to override the startup of a service with the one given from WinUtil,
        or to keep the startup of said service, if it was changed by the user, or another program, from its default value.
    #>

    param(
        $CheckBox,
        $undo = $false,
        $KeepServiceStartup = $true
    )

    Write-Debug "Tweaks: $($CheckBox)"
    if($undo) {
        $Values = @{
            Registry = "OriginalValue"
            Service = "OriginalType"
            ScriptType = "UndoScript"
        }

    } else {
        $Values = @{
            Registry = "Value"
            Service = "StartupType"
            OriginalService = "OriginalType"
            ScriptType = "InvokeScript"
        }
    }
    if($sync.configs.tweaks.$CheckBox.service) {
        Write-Debug "KeepServiceStartup is $KeepServiceStartup"
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

        # The check for !($undo) is required, without it the script will throw an error for accessing unavailable member, which's the 'OriginalService' Property
            if($KeepServiceStartup -AND !($undo)) {
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $psitem.Name -ErrorAction Stop
                    if(!($service.StartType.ToString() -eq $psitem.$($values.OriginalService))) {
                        Write-Debug "Service $($service.Name) was changed in the past to $($service.StartType.ToString()) from it's original type of $($psitem.$($values.OriginalService)), will not change it to $($psitem.$($values.service))"
                        $changeservice = $false
                    }
                } catch [System.ServiceProcess.ServiceNotFoundException] {
                    Write-Warning "Service $($psitem.Name) was not found."
                }
            }

            if($changeservice) {
                Write-Debug "$($psitem.Name) and state is $($psitem.$($values.service))"
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if($sync.configs.tweaks.$CheckBox.registry) {
        $sync.configs.tweaks.$CheckBox.registry | ForEach-Object {
            Write-Debug "$($psitem.Name) and state is $($psitem.$($values.registry))"
            if (($psitem.Path -imatch "hku") -and !(Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
                $null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)
                if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) {
                    Write-Debug "HKU drive created successfully."
                } else {
                    Write-Debug "Failed to create HKU drive."
                }
            }
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            Write-Debug "$($psitem) and state is $($psitem.$($values.ScriptType))"
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if(!$undo) {
        if($sync.configs.tweaks.$CheckBox.appx) {
            $sync.configs.tweaks.$CheckBox.appx | ForEach-Object {
                Write-Debug "UNDO $($psitem.Name)"
                Remove-WinUtilAPPX -Name $psitem
            }
        }

    }
}
function Invoke-WinUtilUninstallPSProfile {

    if (Test-Path ($Profile + ".bak")) {
        Move-Item -Path ($Profile + ".bak") -Destination $Profile
    } else {
        Remove-Item -Path $Profile
    }

    Write-Host "Successfully uninstalled CTT PowerShell Profile." -ForegroundColor Green
}
function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name

    .PARAMETER Name
        The name of the APPX package to remove

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "Removing $Name"
    Get-AppxPackage $Name -AllUsers | Remove-AppxPackage -AllUsers
    Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $Name | Remove-AppxProvisionedPackage -Online
}
function Reset-WPFCheckBoxes {
    <#

    .SYNOPSIS
        Set winutil checkboxs to match $sync.selected values.
        Should only need to be run if $sync.selected updated outside of UI (i.e. presets or import)

    .PARAMETER doToggles
        Whether or not to set UI toggles. WARNING: they will trigger if altered

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"
        Used to make reset blazingly fast.
    #>

    param (
        [Parameter(position=0)]
        [bool]$doToggles = $false,

        [Parameter(position=1)]
        [string]$checkboxfilterpattern = "**"
    )

    $CheckBoxesToCheck = $sync.selectedApps + $sync.selectedTweaks + $sync.selectedFeatures
    $CheckBoxes = ($sync.GetEnumerator()).where{ $_.Value -is [System.Windows.Controls.CheckBox] -and $_.Name -notlike "WPFToggle*" -and $_.Name -like "$checkboxfilterpattern"}
    Write-Debug "Getting checkboxes to set, number of checkboxes: $($CheckBoxes.Count)"

    if ($CheckBoxesToCheck -ne "") {
        $debugMsg = "CheckBoxes to Check are: "
        $CheckBoxesToCheck | ForEach-Object { $debugMsg += "$_, " }
        $debugMsg = $debugMsg -replace (',\s*$', '')
        Write-Debug "$debugMsg"
    }

    foreach ($CheckBox in $CheckBoxes) {
        $checkboxName = $CheckBox.Key
        if (-not $CheckBoxesToCheck) {
            $sync.$checkBoxName.IsChecked = $false
            continue
        }

        # Check if the checkbox name exists in the flattened JSON hashtable
        if ($CheckBoxesToCheck -contains $checkboxName) {
            # If it exists, set IsChecked to true
            $sync.$checkboxName.IsChecked = $true
            Write-Debug "$checkboxName is checked"
        } else {
            # If it doesn't exist, set IsChecked to false
            $sync.$checkboxName.IsChecked = $false
            Write-Debug "$checkboxName is not checked"
        }
    }

    # Update Installs tab UI values
    $count = $sync.SelectedApps.Count
    $sync.WPFselectedAppsButton.Content = "Selected Apps: $count"
    # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
    $sync.selectedAppsstackPanel.Children.Clear()
    $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }

    if($doToggles) {
        # Restore toggle switch states from imported config.
        # Only act on toggles that are explicitly listed in the import - toggles absent
        # from the export file were not part of the saved config and should keep whatever
        # state the live system already has (set during UI initialisation via Get-WinUtilToggleStatus).
        $importedToggles = $sync.selectedToggles
        $allToggles = $sync.GetEnumerator() | Where-Object { $_.Key -like "WPFToggle*" -and $_.Value -is [System.Windows.Controls.CheckBox] }
        foreach ($toggle in $allToggles) {
            if ($importedToggles -contains $toggle.Key) {
                $sync[$toggle.Key].IsChecked = $true
                Write-Debug "Restoring toggle: $($toggle.Key) = checked"
            }
            # Toggles not present in the import are intentionally left untouched;
            # their current UI state already reflects the real system state.
        }
    }
}
function Set-Preferences{

    param(
        [switch]$save=$false
    )

    # TODO delete this function sometime later
    function Clean-OldPrefs{
        if (Test-Path -Path "$winutildir\LightTheme.ini") {
            $sync.preferences.theme = "Light"
            Remove-Item -Path "$winutildir\LightTheme.ini"
        }

        if (Test-Path -Path "$winutildir\DarkTheme.ini") {
            $sync.preferences.theme = "Dark"
            Remove-Item -Path "$winutildir\DarkTheme.ini"
        }

        # check old prefs, if its first line has no =, then absorb it as pm
        if (Test-Path -Path $iniPath) {
            $oldPM = Get-Content $iniPath
            if ($oldPM -notlike "*=*") {
                $sync.preferences.packagemanager = $oldPM
            }
        }

        if (Test-Path -Path "$winutildir\preferChocolatey.ini") {
            $sync.preferences.packagemanager = "Choco"
            Remove-Item -Path "$winutildir\preferChocolatey.ini"
        }
    }

    function Save-Preferences{
        $ini = ""
        foreach($key in $sync.preferences.Keys) {
            $pref = "$($key)=$($sync.preferences.$key)"
            Write-Debug "Saving pref: $($pref)"
            $ini = $ini + $pref + "`r`n"
        }
        $ini | Out-File $iniPath
    }

    function Load-Preferences{
        Clean-OldPrefs
        if (Test-Path -Path $iniPath) {
            $iniData = Get-Content "$winutildir\preferences.ini"
            foreach ($line in $iniData) {
                if ($line -like "*=*") {
                    $arr = $line -split "=",-2
                    $key = $arr[0] -replace "\s",""
                    $value = $arr[1] -replace "\s",""
                    Write-Debug "Preference: Key = '$($key)' Value ='$($value)'"
                    $sync.preferences.$key = $value
                }
            }
        }

        # write defaults in case preferences dont exist
        if ($null -eq $sync.preferences.theme) {
            $sync.preferences.theme = "Auto"
        }
        if ($null -eq $sync.preferences.packagemanager) {
            $sync.preferences.packagemanager = "Winget"
        }

        # convert packagemanager to enum
        if ($sync.preferences.packagemanager -eq "Choco") {
            $sync.preferences.packagemanager = [PackageManagers]::Choco
        }
        elseif ($sync.preferences.packagemanager -eq "Winget") {
            $sync.preferences.packagemanager = [PackageManagers]::Winget
        }
    }

    $iniPath = "$winutildir\preferences.ini"

    if ($save) {
        Save-Preferences
    }
    else {
        Load-Preferences
    }
}
function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)
    if($DNSProvider -eq "Default") {return}
    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "Ensuring DNS is set to $DNSProvider on the following interfaces:"
        Write-Host $($Adapters | Out-String)

        Foreach ($Adapter in $Adapters) {
            if($DNSProvider -eq "DHCP") {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ("$($sync.configs.dns.$DNSProvider.Primary)", "$($sync.configs.dns.$DNSProvider.Secondary)")
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ("$($sync.configs.dns.$DNSProvider.Primary6)", "$($sync.configs.dns.$DNSProvider.Secondary6)")
            }
        }
    } catch {
        Write-Warning "Unable to set DNS Provider due to an unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
    }
}
function Set-WinUtilProgressbar{
    <#
    .SYNOPSIS
        This function is used to Update the Progress Bar displayed in the winutil GUI.
        It will be automatically hidden if the user clicks something and no process is running
    .PARAMETER Label
        The Text to be overlaid onto the Progress Bar
    .PARAMETER PERCENT
        The percentage of the Progress Bar that should be filled (0-100)
    #>
    param(
        [string]$Label,
        [ValidateRange(0,100)]
        [int]$Percent
    )

    if($PARAM_NOUI) {
        return;
    }

    Invoke-WPFUIThread -ScriptBlock {$sync.progressBarTextBlock.Text = $label}
    Invoke-WPFUIThread -ScriptBlock {$sync.progressBarTextBlock.ToolTip = $label}
    if ($percent -lt 5 ) {
        $percent = 5 # Ensure the progress bar is not empty, as it looks weird
    }
    Invoke-WPFUIThread -ScriptBlock { $sync.ProgressBar.Value = $percent}

}
function Set-WinUtilRegistry {
    <#

    .SYNOPSIS
        Modifies the registry based on the given inputs

    .PARAMETER Name
        The name of the key to modify

    .PARAMETER Path
        The path to the key

    .PARAMETER Type
        The type of value to set the key to

    .PARAMETER Value
        The value to set the key to

    .EXAMPLE
        Set-WinUtilRegistry -Name "PublishUserActivities" -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Type "DWord" -Value "0"

    #>
    param (
        $Name,
        $Path,
        $Type,
        $Value
    )

    try {
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS}

        If (!(Test-Path $Path)) {
            Write-Host "$Path was not found. Creating..."
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        if ($Value -ne "<RemoveEntry>") {
            Write-Host "Set $Path\$Name to $Value"
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        else{
            Write-Host "Remove $Path\$Name"
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop | Out-Null
        }
    } catch [System.Security.SecurityException] {
        Write-Warning "Unable to set $Path\$Name to $Value due to a Security Exception."
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Warning $psitem.Exception.ErrorRecord
    } catch [System.UnauthorizedAccessException] {
       Write-Warning $psitem.Exception.Message
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
    }
}
Function Set-WinUtilService {
    <#

    .SYNOPSIS
        Changes the startup type of the given service

    .PARAMETER Name
        The name of the service to modify

    .PARAMETER StartupType
        The startup type to set the service to

    .EXAMPLE
        Set-WinUtilService -Name "HomeGroupListener" -StartupType "Manual"

    #>
    param (
        $Name,
        $StartupType
    )
    try {
        Write-Host "Setting Service $Name to $StartupType"

        # Check if the service exists
        $service = Get-Service -Name $Name -ErrorAction Stop

        # Service exists, proceed with changing properties -- while handling auto delayed start for PWSH 5
        if (($PSVersionTable.PSVersion.Major -lt 7) -and ($StartupType -eq "AutomaticDelayedStart")) {
            sc.exe config $Name start=delayed-auto
        } else {
            $service | Set-Service -StartupType $StartupType -ErrorAction Stop
        }
    } catch [System.ServiceProcess.ServiceNotFoundException] {
        Write-Warning "Service $Name was not found."
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $_.Exception.Message
    }

}
function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    if ($value) {
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state) {
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay) {
        switch ($overlay) {
            'logo' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description) {
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}
function Show-CustomDialog {
    <#
    .SYNOPSIS
    Displays a custom dialog box with an image, heading, message, and an OK button.

    .DESCRIPTION
    This function creates a custom dialog box with the specified message and additional elements such as an image, heading, and an OK button. The dialog box is designed with a green border, rounded corners, and a black background.

    .PARAMETER Title
    The Title to use for the dialog window's Title Bar, this will not be visible by the user, as window styling is set to None.

    .PARAMETER Message
    The message to be displayed in the dialog box.

    .PARAMETER Width
    The width of the custom dialog window.

    .PARAMETER Height
    The height of the custom dialog window.

    .PARAMETER FontSize
    The Font Size of message shown inside custom dialog window.

    .PARAMETER HeaderFontSize
    The Font Size for the Header of custom dialog window.

    .PARAMETER LogoSize
    The Size of the Logo used inside the custom dialog window.

    .PARAMETER ForegroundColor
    The Foreground Color of dialog window title & message.

    .PARAMETER BackgroundColor
    The Background Color of dialog window.

    .PARAMETER BorderColor
    The Color for dialog window border.

    .PARAMETER ButtonBackgroundColor
    The Background Color for Buttons in dialog window.

    .PARAMETER ButtonForegroundColor
    The Foreground Color for Buttons in dialog window.

    .PARAMETER ShadowColor
    The Color used when creating the Drop-down Shadow effect for dialog window.

    .PARAMETER LogoColor
    The Color of WinUtil Text found next to WinUtil's Logo inside dialog window.

    .PARAMETER LinkForegroundColor
    The Foreground Color for Links inside dialog window.

    .PARAMETER LinkHoverForegroundColor
    The Foreground Color for Links when the mouse pointer hovers over them inside dialog window.

    .PARAMETER EnableScroll
    A flag indicating whether to enable scrolling if the content exceeds the window size.

    .EXAMPLE
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels.
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    .EXAMPLE
    $foregroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $backgroundColor = New-Object System.Windows.Media.SolidColorBrush("#1e1e1e")
    $linkForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $linkHoverForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#005289")
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200 -ForegroundColor $foregroundColor -BackgroundColor $backgroundColor -LinkForegroundColor $linkForegroundColor -LinkHoverForegroundColor $linkHoverForegroundColor

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels, with a link foreground (and general foreground) colors of '#0088e5', background color of '#1e1e1e', and Link Color on Hover of '005289', all of which are in Hexadecimal (the '#' Symbol is required by SolidColorBrush Constructor).
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    #>
    param(
        [string]$Title,
        [string]$Message,
        [int]$Width = $sync.Form.Resources.CustomDialogWidth,
        [int]$Height = $sync.Form.Resources.CustomDialogHeight,

        [System.Windows.Media.FontFamily]$FontFamily = $sync.Form.Resources.FontFamily,
        [int]$FontSize = $sync.Form.Resources.CustomDialogFontSize,
        [int]$HeaderFontSize = $sync.Form.Resources.CustomDialogFontSizeHeader,
        [int]$LogoSize = $sync.Form.Resources.CustomDialogLogoSize,

        [System.Windows.Media.Color]$ShadowColor = "#AAAAAAAA",
        [System.Windows.Media.SolidColorBrush]$LogoColor = $sync.Form.Resources.LabelboxForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BorderColor = $sync.Form.Resources.BorderColor,
        [System.Windows.Media.SolidColorBrush]$ForegroundColor = $sync.Form.Resources.MainForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BackgroundColor = $sync.Form.Resources.MainBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkForegroundColor = $sync.Form.Resources.LinkForegroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkHoverForegroundColor = $sync.Form.Resources.LinkHoverForegroundColor,

        [bool]$EnableScroll = $false
    )

    # Create a custom dialog window
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Height = $Height
    $dialog.Width = $Width
    $dialog.Margin = New-Object Windows.Thickness(10)  # Add margin to the entire dialog box
    $dialog.WindowStyle = [Windows.WindowStyle]::None  # Remove title bar and window controls
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize  # Disable resizing
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen  # Center the window
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $FontFamily
    $dialog.FontSize = $FontSize

    # Create a Border for the green edge with rounded corners
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)  # Adjust border thickness as needed
    $border.CornerRadius = New-Object Windows.CornerRadius(10)  # Adjust the radius for rounded corners

    # Create a drop shadow effect
    $dropShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $dropShadow.Color = $shadowColor
    $dropShadow.Direction = 270
    $dropShadow.ShadowDepth = 5
    $dropShadow.BlurRadius = 10

    # Apply drop shadow effect to the border
    $dialog.Effect = $dropShadow

    $dialog.Content = $border

    # Create a grid for layout inside the Border
    $grid = New-Object Windows.Controls.Grid
    $border.Child = $grid

    # Uncomment the following line to show gridlines
    #$grid.ShowGridLines = $true

    # Add the following line to set the background color of the grid
    $grid.Background = [Windows.Media.Brushes]::Transparent
    # Add the following line to make the Grid stretch
    $grid.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Add the following line to make the Border stretch
    $border.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $border.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Set up Row Definitions
    $row0 = New-Object Windows.Controls.RowDefinition
    $row0.Height = [Windows.GridLength]::Auto

    $row1 = New-Object Windows.Controls.RowDefinition
    $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)

    $row2 = New-Object Windows.Controls.RowDefinition
    $row2.Height = [Windows.GridLength]::Auto

    # Add Row Definitions to Grid
    $grid.RowDefinitions.Add($row0)
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel)
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add CTT vector logo
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize)) | Out-Null

    # Add "Service PC Glew" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = "Service PC Glew"
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock)
    # Add TextBlock for information with text wrapping and margins
    $messageTextBlock = New-Object Windows.Controls.TextBlock
    $messageTextBlock.FontSize = $FontSize
    $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap  # Enable text wrapping
    $messageTextBlock.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $messageTextBlock.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $messageTextBlock.Margin = New-Object Windows.Thickness(10)  # Add margins around the text block

    # Define the Regex to find hyperlinks formatted as HTML <a> tags
    $regex = [regex]::new('<a href="([^"]+)">([^<]+)</a>')
    $lastPos = 0

    # Iterate through each match and add regular text and hyperlinks
    foreach ($match in $regex.Matches($Message)) {
        # Add the text before the hyperlink, if any
        $textBefore = $Message.Substring($lastPos, $match.Index - $lastPos)
        if ($textBefore.Length -gt 0) {
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore)))
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value)
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($sender, $args)
            Start-Process $sender.NavigateUri.AbsoluteUri
        })
        $hyperlink.Add_MouseEnter({
            param($sender, $args)
            $sender.Foreground = $LinkHoverForegroundColor
            $sender.FontSize = ($FontSize + ($FontSize / 4))
            $sender.FontWeight = "SemiBold"
        })
        $hyperlink.Add_MouseLeave({
            param($sender, $args)
            $sender.Foreground = $LinkForegroundColor
            $sender.FontSize = $FontSize
            $sender.FontWeight = "Normal"
        })

        $messageTextBlock.Inlines.Add($hyperlink)

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Add any remaining text after the last hyperlink
    if ($lastPos -lt $Message.Length) {
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter)))
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $messageTextBlock
        $grid.Children.Add($scrollViewer)
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($messageTextBlock)
        [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)  # Set the row to the second row (0-based index)
    }

    # Add OK button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "Aceptar"
    $okButton.FontSize = $FontSize
    $okButton.Width = 80
    $okButton.Height = 30
    $okButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $okButton.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $okButton.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    $okButton.Background = $buttonBackgroundColor
    $okButton.Foreground = $buttonForegroundColor
    $okButton.BorderBrush = $BorderColor
    $okButton.Add_Click({
        $dialog.Close()
    })
    $grid.Children.Add($okButton)
    [Windows.Controls.Grid]::SetRow($okButton, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $dialog.Close()
        }
    })

    # Set the OK button as the default button (activated on Enter)
    $okButton.IsDefault = $true

    # Show the custom dialog
    $dialog.ShowDialog()
}
function Show-WPFInstallAppBusy {
    <#
    .SYNOPSIS
        Displays a busy overlay in the install app area of the WPF form.
        This is used to indicate that an install or uninstall is in progress.
        Dynamically updates the size of the overlay based on the app area on each invocation.
    .PARAMETER text
        The text to display in the busy overlay. Defaults to "Installing apps...".
    #>
    param (
        $text = "Installing apps..."
    )
    Invoke-WPFUIThread -ScriptBlock {
        $sync.InstallAppAreaOverlay.Visibility = [Windows.Visibility]::Visible
        $sync.InstallAppAreaOverlay.Width = $($sync.InstallAppAreaScrollViewer.ActualWidth * 0.4)
        $sync.InstallAppAreaOverlay.Height = $($sync.InstallAppAreaScrollViewer.ActualWidth * 0.4)
        $sync.InstallAppAreaOverlayText.Text = $text
        $sync.InstallAppAreaBorder.IsEnabled = $false
        $sync.InstallAppAreaScrollViewer.Effect.Radius = 5
    }
}
function Test-WinUtilPackageManager {
    <#

    .SYNOPSIS
        Checks if WinGet and/or Choco are installed

    .PARAMETER winget
        Check if WinGet is installed

    .PARAMETER choco
        Check if Chocolatey is installed

    #>

    Param(
        [System.Management.Automation.SwitchParameter]$winget,
        [System.Management.Automation.SwitchParameter]$choco
    )

    if ($winget) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            $E = [char]27
            $orange = "$E[38;2;255;106;0m"
            $reset = "$E[0m"
            Write-Host "$orange===========================================$reset"
            Write-Host "$orange---        WinGet está instalado         ---$reset"
            Write-Host "$orange===========================================$reset"
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---      WinGet no está instalado       ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    if ($choco) {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            $E = [char]27
            $orange = "$E[38;2;255;106;0m"
            $reset = "$E[0m"
            Write-Host "$orange===========================================$reset"
            Write-Host "$orange---      Chocolatey está instalado       ---$reset"
            Write-Host "$orange===========================================$reset"
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---    Chocolatey no está instalado     ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    return $status
}
function Update-WinUtilSelections {
    <#

    .SYNOPSIS
        Updates the $sync.selected variables with a given preset.

    .PARAMETER flatJson
        The flattened json list of $sync values to select.
    #>

    param (
        $flatJson
    )

    Write-Debug "JSON to import: $($flatJson)"

    foreach ($item in $flatJson) {
        # Ensure each item is treated as a string to handle PSCustomObject from JSON deserialization
        $cbkey = [string]$item
        $group = if ($cbkey.StartsWith("WPFInstall")) { "Install" }
                    elseif ($cbkey.StartsWith("WPFTweaks")) { "Tweaks" }
                    elseif ($cbkey.StartsWith("WPFToggle")) { "Toggle" }
                    elseif ($cbkey.StartsWith("WPFFeature")) { "Feature" }
                    else { "na" }

        switch ($group) {
            "Install" {
                if (!$sync.selectedApps.Contains($cbkey)) {
                    $sync.selectedApps.Add($cbkey)
                    # The List type needs to be specified again, because otherwise Sort-Object will convert the list to a string if there is only a single entry
                    [System.Collections.Generic.List[string]]$sync.selectedApps = $sync.SelectedApps | Sort-Object
                }
            }
            "Tweaks" {
                if (!$sync.selectedTweaks.Contains($cbkey)) {
                    $sync.selectedTweaks.Add($cbkey)
                }
            }
            "Toggle" {
                if (!$sync.selectedToggles.Contains($cbkey)) {
                    $sync.selectedToggles.Add($cbkey)
                }
            }
            "Feature" {
                if (!$sync.selectedFeatures.Contains($cbkey)) {
                    $sync.selectedFeatures.Add($cbkey)
                }
            }
            default {
                Write-Host "Unknown group for checkbox: $($cbkey)"
            }
        }
    }

    Write-Debug "-------------------------------------"
    Write-Debug "Selected Apps: $($sync.selectedApps)"
    Write-Debug "Selected Tweaks: $($sync.selectedTweaks)"
    Write-Debug "Selected Toggles: $($sync.selectedToggles)"
    Write-Debug "Selected Features: $($sync.selectedFeatures)"
    Write-Debug "--------------------------------------"
}
function Initialize-WPFUI {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetGridName
    )

    switch ($TargetGridName) {
        "appscategory"{
            # TODO
            # Switch UI generation of the sidebar to this function
            # $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            # ...

            # Create and configure a popup for displaying selected apps
            $selectedAppsPopup = New-Object Windows.Controls.Primitives.Popup
            $selectedAppsPopup.IsOpen = $false
            $selectedAppsPopup.PlacementTarget = $sync.WPFselectedAppsButton
            $selectedAppsPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $selectedAppsPopup.AllowsTransparency = $true

            # Style the popup with a border and background
            $selectedAppsBorder = New-Object Windows.Controls.Border
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "MainBackgroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, "MainForegroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderThicknessProperty, "ButtonBorderThickness")
            $selectedAppsBorder.Width = 200
            $selectedAppsBorder.Padding = 5
            $selectedAppsPopup.Child = $selectedAppsBorder
            $sync.selectedAppsPopup = $selectedAppsPopup

            # Add a stack panel inside the popup's border to organize its child elements
            $sync.selectedAppsstackPanel = New-Object Windows.Controls.StackPanel
            $selectedAppsBorder.Child = $sync.selectedAppsstackPanel

            # Close selectedAppsPopup when mouse leaves both button and selectedAppsPopup
            $sync.WPFselectedAppsButton.Add_MouseLeave({
                if (-not $sync.selectedAppsPopup.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })
            $selectedAppsPopup.Add_MouseLeave({
                if (-not $sync.WPFselectedAppsButton.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })

            # Creates the popup that is displayed when the user right-clicks on an app entry
            # This popup contains buttons for installing, uninstalling, and viewing app information

            $appPopup = New-Object Windows.Controls.Primitives.Popup
            $appPopup.StaysOpen = $false
            $appPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $appPopup.AllowsTransparency = $true
            # Store the popup globally so the position can be set later
            $sync.appPopup = $appPopup

            $appPopupStackPanel = New-Object Windows.Controls.StackPanel
            $appPopupStackPanel.Orientation = "Horizontal"
            $appPopupStackPanel.Add_MouseLeave({
                $sync.appPopup.IsOpen = $false
            })
            $appPopup.Child = $appPopupStackPanel

            $appButtons = @(
            [PSCustomObject]@{ Name = "Install";    Icon = [char]0xE118 },
            [PSCustomObject]@{ Name = "Uninstall";  Icon = [char]0xE74D },
            [PSCustomObject]@{ Name = "Info";       Icon = [char]0xE946 }
            )
            foreach ($button in $appButtons) {
                $newButton = New-Object Windows.Controls.Button
                $newButton.Style = $sync.Form.Resources.AppEntryButtonStyle
                $newButton.Content = $button.Icon
                $appPopupStackPanel.Children.Add($newButton) | Out-Null

                # Dynamically load the selected app object so the buttons can be reused and do not need to be created for each app
                switch ($button.Name) {
                    "Install" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Install or Upgrade $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFInstall -PackagesToInstall $appObject
                        })
                    }
                    "Uninstall" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Uninstall $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFUnInstall -PackagesToUninstall $appObject
                        })
                    }
                    "Info" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Open the application's website in your default browser`n$($appObject.link)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Start-Process $appObject.link
                        })
                    }
                }
            }
        }
        "appspanel" {
            $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            Initialize-InstallCategoryAppList -TargetElement $sync.ItemsControl -Apps $sync.configs.applicationsHashtable
        }
        default {
            Write-Output "$TargetGridName not yet implemented"
        }
    }
}

function Invoke-WinUtilAutoRun {
    <#

    .SYNOPSIS
        Runs Install, Tweaks, and Features with optional UI invocation.
    #>

    function BusyWait {
        Start-Sleep -Milliseconds 100
        while ($sync.ProcessRunning) {
            Start-Sleep -Milliseconds 100
        }
    }

    if ($sync.selectedTweaks.Count -gt 0) {
        Write-Host "Applying tweaks..."
        Invoke-WPFtweaksbutton
        BusyWait
    }

    if ($sync.selectedFeatures.Count -gt 0) {
        Write-Host "Applying features..."
        Invoke-WPFFeatureInstall
        BusyWait
    }

    if ($sync.selectedApps.Count -gt 0) {
        Write-Host "Installing applications..."
        Invoke-WPFInstall
        BusyWait
    }

    Write-Host "Done." -ForegroundColor Green
}
function Invoke-WinUtilRemoveEdge {
  New-Item -Path "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force

  $Path = Resolve-Path -Path "$Env:ProgramFiles (x86)\Microsoft\Edge\Application\*\Installer\setup.exe" | Select-Object -Last 1
  Start-Process -FilePath $Path -ArgumentList '--uninstall --system-level --force-uninstall --delete-profile' -Wait

  Write-Host "Microsoft Edge was removed" -ForegroundColor Green
}
function Invoke-WPFBulkCrapUninstaller {
    [OutputType([void])]
    param()

    # El script que se ejecutará como Administrador en una nueva ventana de PowerShell
    $ScriptContent = @'
# 1. Consultar la API de GitHub para obtener la última versión
$api = Invoke-RestMethod -Uri "https://api.github.com/repos/Klocman/Bulk-Crap-Uninstaller/releases/latest"

# 2. Filtrar los archivos para encontrar el .zip de la versión portable
$asset = $api.assets | Where-Object { $_.name -match "portable\.zip$" }

# 3. Definir las rutas en el Escritorio
$desktopPath = [Environment]::GetFolderPath("Desktop")
$zipPath = Join-Path $desktopPath $asset.name
$extractPath = Join-Path $desktopPath "BCU_Portable"

# 4. Descargar el archivo
Write-Host "Descargando $($asset.name)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath

# 5. Extraer el .zip en una carpeta nueva y borrar el archivo comprimido
Write-Host "Extrayendo archivos..." -ForegroundColor Cyan
Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
Remove-Item $zipPath

# Colores personalizados naranja de Service PC Glew (#FF6A00) para el mensaje de éxito
$E = [char]27
Write-Host ""
Write-Host "$E[38;2;255;106;0m¡Listo! La última versión portable de BCU está en la carpeta 'BCU_Portable' de tu Escritorio.$E[0m"
Write-Host ""
Read-Host "Presiona Enter para continuar..."
'@

    # Guardar en un archivo temporal y ejecutarlo como Administrador
    $TempFile = Join-Path $env:TEMP "install-bcu.ps1"
    $ScriptContent | Out-File -FilePath $TempFile -Force -Encoding utf8
    Start-Process powershell -ArgumentList "-NoExit", "-ExecutionPolicy Bypass", "-File `"$TempFile`"" -Verb RunAs
}
function Invoke-WPFButton {

    <#

    .SYNOPSIS
        Invokes the function associated with the clicked button

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param ([string]$Button)

    $CreatePWA = {
        param (
            [string]$Name,
            [string]$Url,
            [string]$IconUrl
        )

        # 1. Determinar el navegador disponible
        $browserPath = ""
        $chromePaths = @(
            "C:\Program Files\Google\Chrome\Application\chrome.exe",
            "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
            "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
        )
        foreach ($path in $chromePaths) {
            if (Test-Path $path) { $browserPath = $path; break }
        }
        if (-not $browserPath) {
            $edgePaths = @(
                "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
                "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
            )
            foreach ($path in $edgePaths) {
                if (Test-Path $path) { $browserPath = $path; break }
            }
        }

        if (-not $browserPath) {
            # Fallback si no hay Chrome ni Edge
            Start-Process $Url
            return
        }

        # 2. Crear directorio de iconos corporativos de Service PC Glew
        $iconDir = Join-Path $env:USERPROFILE ".servicepcglew\icons"
        if (-not (Test-Path $iconDir)) {
            New-Item -ItemType Directory -Path $iconDir -Force | Out-Null
        }
        $iconPath = Join-Path $iconDir "$Name.ico"

        # 3. Descargar icono de forma silenciosa
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $IconUrl -OutFile $iconPath -TimeoutSec 5 -ErrorAction Stop | Out-Null
        } catch {
            # Si falla la descarga, usamos el icono del navegador por defecto
            $iconPath = $browserPath
        }

        # 4. Crear el acceso directo en el Escritorio
        $desktopPath = [Environment]::GetFolderPath("Desktop")
        $shortcutPath = Join-Path $desktopPath "$Name.lnk"

        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($shortcutPath)
        $Shortcut.TargetPath = $browserPath
        $Shortcut.Arguments = "--app=$Url"
        $Shortcut.IconLocation = $iconPath
        $Shortcut.Save()

        # Ventana de éxito corporativo rápida
        Show-CustomDialog -Title "Instalación Exitosa" -Message "Se ha creado el acceso directo de $Name en tu Escritorio de forma exitosa."
    }

    # Use this to get the name of the button
    #[System.Windows.MessageBox]::Show("$Button","Service PC Glew Tech's Windows Utility","OK","Info")
    if (-not $sync.ProcessRunning) {
        Set-WinUtilProgressBar  -label "" -percent 0
    }

    # Check if button is defined in feature config with function or InvokeScript
    if ($sync.configs.feature.$Button) {
        $buttonConfig = $sync.configs.feature.$Button

        # If button has a function defined, call it
        if ($buttonConfig.function) {
            $functionName = $buttonConfig.function
            if (Get-Command $functionName -ErrorAction SilentlyContinue) {
                & $functionName
                return
            }
        }

        # If button has InvokeScript defined, execute the scripts
        if ($buttonConfig.InvokeScript -and $buttonConfig.InvokeScript.Count -gt 0) {
            foreach ($script in $buttonConfig.InvokeScript) {
                if (-not [string]::IsNullOrWhiteSpace($script)) {
                    Invoke-Expression $script
                }
            }
            return
        }
    }

    # Fallback to hard-coded switch for buttons not in feature.json
    Switch -Wildcard ($Button) {
        "WPFTab?BT" {Invoke-WPFTab $Button}
        "WPFInstall" {Invoke-WPFInstall}
        "WPFUninstall" {Invoke-WPFUnInstall}
        "WPFInstallUpgrade" {Invoke-WPFInstallUpgrade}
        "WPFCollapseAllCategories" {Invoke-WPFToggleAllCategories -Action "Collapse"}
        "WPFExpandAllCategories" {Invoke-WPFToggleAllCategories -Action "Expand"}
        "WPFStandard" {Invoke-WPFPresets "Standard" -checkboxfilterpattern "WPFTweak*"}
        "WPFMinimal" {Invoke-WPFPresets "Minimal" -checkboxfilterpattern "WPFTweak*"}
        "WPFClearTweaksSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFTweak*"}
        "WPFClearInstallSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFInstall*"}
        "WPFtweaksbutton" {Invoke-WPFtweaksbutton}
        "WPFOOSUbutton" {Invoke-WPFOOSU}
        "WPFAddUltPerf" {Invoke-WPFUltimatePerformance -Do}
        "WPFRemoveUltPerf" {Invoke-WPFUltimatePerformance}
        "WPFundoall" {Invoke-WPFundoall}
        "WPFUpdatesdefault" {Invoke-WPFUpdatesdefault}
        "WPFUpdatesdisable" {Invoke-WPFUpdatesdisable}
        "WPFUpdatessecurity" {Invoke-WPFUpdatessecurity}
        "WPFGetInstalled" {Invoke-WPFGetInstalled -CheckBox "winget"}
        "WPFGetInstalledTweaks" {Invoke-WPFGetInstalled -CheckBox "tweaks"}
        "WPFCloseButton" {$sync.Form.Close(); Write-Host "Bye bye!"}
        "WPFselectedAppsButton" {$sync.selectedAppsPopup.IsOpen = -not $sync.selectedAppsPopup.IsOpen}
        "WPFMAS" {
            Start-Process powershell -ArgumentList "-NoExit", "-Command", "irm https://get.activated.win | iex"
        }
        "WPFActivation2" {
            # 1. Ventana de confirmación personalizada con estilo corporativo
            $dialog = New-Object Windows.Window
            $dialog.Title = "Confirmación de Activación"
            $dialog.Height = 180
            $dialog.Width = 360
            $dialog.WindowStyle = [Windows.WindowStyle]::None
            $dialog.ResizeMode = [Windows.ResizeMode]::NoResize
            $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen
            $dialog.Foreground = $sync.Form.Resources.MainForegroundColor
            $dialog.Background = $sync.Form.Resources.MainBackgroundColor
            $dialog.FontFamily = $sync.Form.Resources.FontFamily

            $border = New-Object Windows.Controls.Border
            $border.BorderBrush = $sync.Form.Resources.BorderColor
            $border.BorderThickness = New-Object Windows.Thickness(1)
            $border.CornerRadius = New-Object Windows.CornerRadius(10)
            $dialog.Content = $border

            $grid = New-Object Windows.Controls.Grid
            $border.Child = $grid
            $grid.Background = [Windows.Media.Brushes]::Transparent

            $row0 = New-Object Windows.Controls.RowDefinition
            $row0.Height = [Windows.GridLength]::Auto
            $row1 = New-Object Windows.Controls.RowDefinition
            $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $row2 = New-Object Windows.Controls.RowDefinition
            $row2.Height = [Windows.GridLength]::Auto
            $grid.RowDefinitions.Add($row0)
            $grid.RowDefinitions.Add($row1)
            $grid.RowDefinitions.Add($row2)

            # Fila de Cabecera (Logo + Nombre de Marca)
            $stackPanel = New-Object Windows.Controls.StackPanel
            $stackPanel.Margin = New-Object Windows.Thickness(15, 10, 15, 0)
            $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
            $grid.Children.Add($stackPanel) | Out-Null
            [Windows.Controls.Grid]::SetRow($stackPanel, 0)

            # Add CTT vector logo
            $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 26)) | Out-Null

            $winutilTextBlock = New-Object Windows.Controls.TextBlock
            $winutilTextBlock.Text = " Service PC Glew"
            $winutilTextBlock.FontSize = 14
            $winutilTextBlock.FontWeight = "SemiBold"
            $winutilTextBlock.Foreground = $sync.Form.Resources.LabelboxForegroundColor
            $stackPanel.Children.Add($winutilTextBlock) | Out-Null

            # Fila de Mensaje de Pregunta
            $messageTextBlock = New-Object Windows.Controls.TextBlock
            $messageTextBlock.Text = "¿Desea continuar con la activación de Windows 7 Pro / Enterprise?"
            $messageTextBlock.FontSize = 12
            $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap
            $messageTextBlock.Margin = New-Object Windows.Thickness(15, 15, 15, 10)
            $grid.Children.Add($messageTextBlock) | Out-Null
            [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)

            # Fila de Botones (Sí / No)
            $buttonsPanel = New-Object Windows.Controls.StackPanel
            $buttonsPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
            $buttonsPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
            $buttonsPanel.Margin = New-Object Windows.Thickness(0, 0, 15, 15)
            $grid.Children.Add($buttonsPanel) | Out-Null
            [Windows.Controls.Grid]::SetRow($buttonsPanel, 2)

            $confirmed = $false

            $yesButton = New-Object Windows.Controls.Button
            $yesButton.Content = "Sí"
            $yesButton.Width = 70
            $yesButton.Height = 28
            $yesButton.Margin = New-Object Windows.Thickness(0, 0, 10, 0)
            $yesButton.Background = $sync.Form.Resources.ButtonInstallBackgroundColor
            $yesButton.Foreground = $sync.Form.Resources.ButtonInstallForegroundColor
            $yesButton.BorderBrush = $sync.Form.Resources.BorderColor
            $yesButton.Add_Click({
                $confirmed = $true
                $dialog.Close()
            })
            $buttonsPanel.Children.Add($yesButton) | Out-Null

            $noButton = New-Object Windows.Controls.Button
            $noButton.Content = "No"
            $noButton.Width = 70
            $noButton.Height = 28
            $noButton.Background = $sync.Form.Resources.ButtonInstallBackgroundColor
            $noButton.Foreground = $sync.Form.Resources.ButtonInstallForegroundColor
            $noButton.BorderBrush = $sync.Form.Resources.BorderColor
            $noButton.Add_Click({
                $dialog.Close()
            })
            $buttonsPanel.Children.Add($noButton) | Out-Null

            $dialog.Add_KeyDown({
                if ($_.Key -eq 'Escape') {
                    $dialog.Close()
                }
            })

            $dialog.ShowDialog() | Out-Null

            if (-not $confirmed) {
                return
            }

            # 2. Ejecución del script en CMD nativo
            $batchContent = @'
@echo off
title Activacion de Windows 7 Pro / Enterprise
echo Detectando edicion de Windows...
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v EditionID | findstr /I "Enterprise" >nul
if %errorlevel% equ 0 (
    echo Detectado: Windows Enterprise
    echo Instalando clave KMS Enterprise (33PXH-7Y6KF-2VJC9-XBBR8-HVTHH)...
    slmgr /ipk 33PXH-7Y6KF-2VJC9-XBBR8-HVTHH
) else (
    echo Detectado: Windows Professional
    echo Instalando clave KMS Professional (FJ82H-XT6CR-J8D7Y-YQ6GY-G27F2)...
    slmgr /ipk FJ82H-XT6CR-J8D7Y-YQ6GY-G27F2
)
echo Configurando servidor KMS kms8.msguides.com...
slmgr /skms kms8.msguides.com
echo Activando Windows...
slmgr /ato
echo.
echo Proceso finalizado.
pause
'@
            $tempBat = Join-Path $env:TEMP "activate-win7.bat"
            $batchContent | Out-File -FilePath $tempBat -Force -Encoding oem
            Start-Process cmd.exe -ArgumentList "/c `"$tempBat`""
        }
        "WPFActivation3" {
            # 1. Ventana de confirmación personalizada con estilo corporativo
            $dialog = New-Object Windows.Window
            $dialog.Title = "Confirmación de Activación"
            $dialog.Height = 180
            $dialog.Width = 360
            $dialog.WindowStyle = [Windows.WindowStyle]::None
            $dialog.ResizeMode = [Windows.ResizeMode]::NoResize
            $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen
            $dialog.Foreground = $sync.Form.Resources.MainForegroundColor
            $dialog.Background = $sync.Form.Resources.MainBackgroundColor
            $dialog.FontFamily = $sync.Form.Resources.FontFamily

            $border = New-Object Windows.Controls.Border
            $border.BorderBrush = $sync.Form.Resources.BorderColor
            $border.BorderThickness = New-Object Windows.Thickness(1)
            $border.CornerRadius = New-Object Windows.CornerRadius(10)
            $dialog.Content = $border

            $grid = New-Object Windows.Controls.Grid
            $border.Child = $grid
            $grid.Background = [Windows.Media.Brushes]::Transparent

            $row0 = New-Object Windows.Controls.RowDefinition
            $row0.Height = [Windows.GridLength]::Auto
            $row1 = New-Object Windows.Controls.RowDefinition
            $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $row2 = New-Object Windows.Controls.RowDefinition
            $row2.Height = [Windows.GridLength]::Auto
            $grid.RowDefinitions.Add($row0)
            $grid.RowDefinitions.Add($row1)
            $grid.RowDefinitions.Add($row2)

            # Fila de Cabecera (Logo + Nombre de Marca)
            $stackPanel = New-Object Windows.Controls.StackPanel
            $stackPanel.Margin = New-Object Windows.Thickness(15, 10, 15, 0)
            $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
            $grid.Children.Add($stackPanel) | Out-Null
            [Windows.Controls.Grid]::SetRow($stackPanel, 0)

            # Add CTT vector logo
            $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 26)) | Out-Null

            $winutilTextBlock = New-Object Windows.Controls.TextBlock
            $winutilTextBlock.Text = " Service PC Glew"
            $winutilTextBlock.FontSize = 14
            $winutilTextBlock.FontWeight = "SemiBold"
            $winutilTextBlock.Foreground = $sync.Form.Resources.LabelboxForegroundColor
            $stackPanel.Children.Add($winutilTextBlock) | Out-Null

            # Fila de Mensaje de Pregunta
            $messageTextBlock = New-Object Windows.Controls.TextBlock
            $messageTextBlock.Text = "¿Desea continuar con la activación de Windows XP?"
            $messageTextBlock.FontSize = 12
            $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap
            $messageTextBlock.Margin = New-Object Windows.Thickness(15, 15, 15, 10)
            $grid.Children.Add($messageTextBlock) | Out-Null
            [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)

            # Fila de Botones (Sí / No)
            $buttonsPanel = New-Object Windows.Controls.StackPanel
            $buttonsPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
            $buttonsPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
            $buttonsPanel.Margin = New-Object Windows.Thickness(0, 0, 15, 15)
            $grid.Children.Add($buttonsPanel) | Out-Null
            [Windows.Controls.Grid]::SetRow($buttonsPanel, 2)

            $confirmed = $false

            $yesButton = New-Object Windows.Controls.Button
            $yesButton.Content = "Sí"
            $yesButton.Width = 70
            $yesButton.Height = 28
            $yesButton.Margin = New-Object Windows.Thickness(0, 0, 10, 0)
            $yesButton.Background = $sync.Form.Resources.ButtonInstallBackgroundColor
            $yesButton.Foreground = $sync.Form.Resources.ButtonInstallForegroundColor
            $yesButton.BorderBrush = $sync.Form.Resources.BorderColor
            $yesButton.Add_Click({
                $confirmed = $true
                $dialog.Close()
            })
            $buttonsPanel.Children.Add($yesButton) | Out-Null

            $noButton = New-Object Windows.Controls.Button
            $noButton.Content = "No"
            $noButton.Width = 70
            $noButton.Height = 28
            $noButton.Background = $sync.Form.Resources.ButtonInstallBackgroundColor
            $noButton.Foreground = $sync.Form.Resources.ButtonInstallForegroundColor
            $noButton.BorderBrush = $sync.Form.Resources.BorderColor
            $noButton.Add_Click({
                $dialog.Close()
            })
            $buttonsPanel.Children.Add($noButton) | Out-Null

            $dialog.Add_KeyDown({
                if ($_.Key -eq 'Escape') {
                    $dialog.Close()
                }
            })

            $dialog.ShowDialog() | Out-Null

            if (-not $confirmed) {
                return
            }

            # 2. Ejecución del script por lotes en CMD
            $batchContent = @'
@echo off
color 0A
title Activador Service Windows XP

echo [=========================================]
echo [      Inyectando Clave Corporativa       ]
echo [=========================================]
echo.

:: Crear el script VBS en la carpeta temporal de forma silenciosa
echo Set objWMIService = GetObject("winmgmts:{impersonationLevel=impersonate}") > "%temp%\act_xp.vbs"
echo For Each objAct in objWMIService.InstancesOf("win32_WindowsProductActivation") >> "%temp%\act_xp.vbs"
echo     objAct.SetProductKey("V2C47MK7JD3R89FD2KXWVPK3J") >> "%temp%\act_xp.vbs"
echo Next >> "%temp%\act_xp.vbs"

:: Ejecutar el script por consola sin mostrar ventanas de error
cscript //nologo "%temp%\act_xp.vbs"

:: Limpiar el rastro borrando el archivo temporal
del "%temp%\act_xp.vbs"

echo.
echo Operacion finalizada. El sistema ya no pedira activacion.
echo Presiona cualquier tecla para salir...
pause >nul
'@
            $tempBat = Join-Path $env:TEMP "activate-winxp.bat"
            $batchContent | Out-File -FilePath $tempBat -Force -Encoding oem
            Start-Process cmd.exe -ArgumentList "/c `"$tempBat`""
        }
        "WPFBulkCrapUninstaller" {
            Invoke-WPFBulkCrapUninstaller
        }
        "WPFBulkCrapUninstallerInstall" {
            Start-Process powershell -ArgumentList "-NoExit", "-Command", "winget install -e --id Klocman.BulkCrapUninstaller"
        }
        "WPFDriverBooster" {
            Invoke-WPFDriverBooster
        }
        "WPFWebAppMercadoPago" {
            & $CreatePWA -Name "Mercado Pago" -Url "https://www.mercadopago.com.ar/" -IconUrl "https://www.mercadopago.com.ar/favicon.ico"
        }
        "WPFWebAppWhatsApp" {
            & $CreatePWA -Name "WhatsApp Web" -Url "https://web.whatsapp.com/" -IconUrl "https://web.whatsapp.com/favicon.ico"
        }
        "WPFWebAppGmail" {
            & $CreatePWA -Name "Gmail" -Url "https://mail.google.com/" -IconUrl "https://ssl.gstatic.com/ui/v1/icons/mail/images/2/basic2_favicon_v2.ico"
        }
        "WPFWebAppYouTube" {
            & $CreatePWA -Name "YouTube" -Url "https://www.youtube.com/" -IconUrl "https://www.youtube.com/favicon.ico"
        }
        "WPFAutoYAOCTRI" {
            # Script de despliegue completo de Office sin activación (Fases 1 a 5)
            $scriptContent = @'
# ==============================================================================
# DEPLOYMENT OFFICE - SERVICE PC GLEW
# Menú de Descarga, Montaje Automático, Instalación Liviana y Limpieza
# ==============================================================================

$ProgressPreference = 'Continue'

function Download-FileWithProgress {
    param (
        [string]$Uri,
        [string]$OutFile
    )
    try {
        Add-Type -AssemblyName System.Net.Http
    } catch {}
    
    $client = [System.Net.Http.HttpClient]::new()
    try {
        $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "Error al conectar: $($response.StatusCode)"
        }
        $totalBytes = $response.Content.Headers.ContentLength
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = [System.IO.File]::Create($OutFile)
        $buffer = New-Object byte[] 65536
        $bytesRead = 0
        $totalBytesRead = 0
        $lastUpdate = [DateTime]::MinValue

        try {
            while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $bytesRead)
                $totalBytesRead += $bytesRead
                
                if ((Get-Date) -gt $lastUpdate.AddMilliseconds(150)) {
                    $lastUpdate = Get-Date
                    if ($totalBytes) {
                        $percent = [math]::Round(($totalBytesRead / $totalBytes) * 100)
                        $mbRead = [math]::Round($totalBytesRead / 1MB, 2)
                        $mbTotal = [math]::Round($totalBytes / 1MB, 2)
                        
                        # Barra de progreso de texto [=========>      ]
                        $barLength = 30
                        $filledLength = [math]::Round(($percent / 100) * $barLength)
                        $emptyLength = $barLength - $filledLength
                        $bar = ("=" * $filledLength) + ">" + (" " * $emptyLength)
                        if ($percent -eq 100) { $bar = "=" * $barLength }
                        
                        [Console]::Write("`r Descargando: [$bar] $percent% ($mbRead MB / $mbTotal MB)   ")
                        Write-Progress -Activity "Descargando imagen oficial de Microsoft ($mbTotal MB)" -Status "Progreso: $percent% ($mbRead MB de $mbTotal MB)" -PercentComplete $percent
                    } else {
                        $mbRead = [math]::Round($totalBytesRead / 1MB, 2)
                        [Console]::Write("`r Descargando: $mbRead MB...   ")
                        Write-Progress -Activity "Descargando imagen oficial de Microsoft" -Status "Descargado: $mbRead MB"
                    }
                }
            }
            # Completar barra al 100%
            if ($totalBytes) {
                $mbTotal = [math]::Round($totalBytes / 1MB, 2)
                [Console]::Write("`r Descargando: [" + ("=" * 30) + "] 100% ($mbTotal MB / $mbTotal MB)   `n")
            } else {
                [Console]::Write("`n")
            }
        } finally {
            $fileStream.Close()
            $stream.Close()
        }
    } finally {
        $client.Dispose()
        Write-Progress -Activity "Descargando imagen oficial de Microsoft" -Completed
    }
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] ERROR: Debes ejecutar este script como Administrador." -ForegroundColor Red
    Start-Sleep -Seconds 4
    Exit
}

$Arch = if ([Environment]::Is64BitOperatingSystem) { "64 bits" } else { "32 bits" }
$ArchCode = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }

$WorkDir = "C:\ServicePC_Office"
if (!(Test-Path $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }
Set-Location -Path $WorkDir

Clear-Host
Write-Host "=================================================" -ForegroundColor DarkGray
Write-Host "       SERVICE PC GLEW - OFFICE DEPLOYMENT       " -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host " Selecciona la versión de Office a descargar (Español):" -ForegroundColor White
Write-Host " 1. Office 2021 ProPlus ($Arch - Recomendado)" -ForegroundColor Cyan
Write-Host " 2. Office 2016 ProPlus (32 & 64 bits)" -ForegroundColor Cyan
Write-Host " 3. Office 2019 ProPlus ($Arch)" -ForegroundColor Cyan
Write-Host " 4. Microsoft 365 (32 & 64 bits)" -ForegroundColor Cyan
Write-Host " 5. Salir" -ForegroundColor Red
Write-Host ""

$opcion = Read-Host " Ingresa el número de tu elección"
$DownloadUrl = ""
$FileName = ""
$SuiteName = ""
$InstallArch = ""
$IniHeader = ""

switch ($opcion) {
    "1" { 
        $DownloadUrl = "https://officecdn.microsoft.com/db/492350f6-3a01-4f97-b9c0-c7c6ddf67d60/media/es-es/ProPlus2021Retail.img"
        $FileName = "Office2021.img"
        $SuiteName = "ProPlus2021Retail"
        $InstallArch = $ArchCode
        $IniHeader = if ($ArchCode -eq "x64") { "W64" } else { "W32" }
    }
    "2" { 
        $DownloadUrl = "https://officecdn.microsoft.com/db/492350f6-3a01-4f97-b9c0-c7c6ddf67d60/media/es-es/ProPlusRetail.img"
        $FileName = "Office2016.img"
        $SuiteName = "ProPlusRetail"
        $InstallArch = $ArchCode
        $IniHeader = if ($ArchCode -eq "x64") { "W64" } else { "W32" }
    }
    "3" { 
        $DownloadUrl = "https://officecdn.microsoft.com/db/492350f6-3a01-4f97-b9c0-c7c6ddf67d60/media/es-es/ProPlus2019Retail.img"
        $FileName = "Office2019.img"
        $SuiteName = "ProPlus2019Retail"
        $InstallArch = $ArchCode
        $IniHeader = if ($ArchCode -eq "x64") { "W64" } else { "W32" }
    }
    "4" { 
        $DownloadUrl = "https://officecdn.microsoft.com/db/492350f6-3a01-4f97-b9c0-c7c6ddf67d60/media/es-es/O365ProPlusRetail.img"
        $FileName = "Office365.img"
        $SuiteName = "O365ProPlusRetail"
        $InstallArch = $ArchCode
        $IniHeader = if ($ArchCode -eq "x64") { "W64" } else { "W32" }
    }
    "5" { Exit }
    default { Write-Host "Opción inválida." -ForegroundColor Red; Exit }
}

$ImagePath = "$WorkDir\$FileName"

# --- FASE 1: DESCARGA ---
Clear-Host
Write-Host "[1/5] Descargando imagen oficial de Microsoft (Aprox. 4.5 GB)..." -ForegroundColor Yellow
Write-Host "      Esto puede tardar dependiendo de tu conexión." -ForegroundColor DarkGray
try {
    Download-FileWithProgress -Uri $DownloadUrl -OutFile $ImagePath
} catch {
    Write-Host "[!] Advertencia: Descarga personalizada falló. Usando método alternativo..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ImagePath
}

# --- FASE 2: MONTAJE AUTOMÁTICO ---
Write-Host "`n[2/5] Montando la imagen descargada..." -ForegroundColor Cyan
$MountResult = Mount-DiskImage -ImagePath $ImagePath -PassThru
# Obtener la letra de la unidad montada para pasársela a YAOCTRI
$DriveLetter = ($MountResult | Get-Volume).DriveLetter
$DrivePath = "$($DriveLetter):\"

if (!$DriveLetter) {
    Write-Host "[!] Error: No se pudo montar la imagen ISO/IMG." -ForegroundColor Red
    pause; exit
}
Write-Host "[OK] Imagen montada en la unidad $DrivePath" -ForegroundColor Green

# --- FASE 3: PREPARACIÓN AUTOMÁTICA ---
Write-Host "`n=================================================" -ForegroundColor DarkGray
Write-Host " PREPARATIVOS LISTOS. EL EQUIPO ESTÁ PREPARADO.  " -ForegroundColor Yellow
Write-Host " Se instalará una versión liviana (Word, Excel, PPT) " -ForegroundColor White
Write-Host "=================================================" -ForegroundColor DarkGray
Write-Host " Iniciando la instalación silenciosa automáticamente en 3 segundos..." -ForegroundColor Green
Start-Sleep -Seconds 3

# --- FASE 4: INSTALACIÓN LIVIANA (YAOCTRI) ---
Clear-Host
Write-Host "[3/5] Descargando componentes de instalación YAOCTRI..." -ForegroundColor Yellow
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/abbodi1406/BatUtil/master/YAOCTRI/YAOCTRIR_Configurator.cmd" -OutFile "YAOCTRIR_Configurator.cmd"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/abbodi1406/BatUtil/master/YAOCTRI/YAOCTRI_Installer.cmd" -OutFile "YAOCTRI_Installer.cmd"

Write-Host "[4/5] Instalando Office silenciosamente (Sin Teams, OneDrive, etc)..." -ForegroundColor Cyan

# Obtener dinámicamente la carpeta de la versión desde el disco montado
$versionFolder = ""
if (Test-Path "$DrivePath\Office\Data") {
    $versionFolder = (Get-ChildItem -Path "$DrivePath\Office\Data" -Directory | Where-Object { Test-Path (Join-Path $_.FullName "stream*.dat") } | Select-Object -First 1).Name
}
if (!$versionFolder) {
    $subDirs = Get-ChildItem -Path "$DrivePath\Office\Data" -Directory
    if ($subDirs) {
        $versionFolder = $subDirs[0].Name
    }
}

$wow64 = if ([Environment]::Is64BitOperatingSystem -and $InstallArch -eq "x86") { 1 } else { 0 }

# Generar C2R_Config.ini con la estructura requerida por YAOCTRI
$IniContent = @"
[configuration]
SourcePath="$DrivePath"
Type=Local
Version=$versionFolder
Architecture=$InstallArch
O32W64=$wow64
Language=es-ES
LCID=3082
Channel=Current
CDN=492350f6-3a01-4f97-b9c0-c7c6ddf67d60
UpdatesEnabled=True
AcceptEULA=True
PinIconsToTaskbar=False
ForceAppShutdown=True
DisplayLevel=True
AutoActivate=False
DisableTelemetry=True
AutoInstallation=True
Suite=$SuiteName
ExcludedApps=Access,Groove,Lync,OneDrive,OneNote,Outlook,Publisher,Teams
"@

Out-File -FilePath "$WorkDir\C2R_Config.ini" -InputObject $IniContent -Encoding ascii

$process = Start-Process -FilePath "$WorkDir\YAOCTRI_Installer.cmd" -ArgumentList "/s" -WorkingDirectory $WorkDir -Wait -PassThru

# --- FASE 5: LIMPIEZA PROFUNDA ---
Write-Host "`n[5/5] Realizando limpieza profunda del sistema..." -ForegroundColor Yellow

Write-Host "      - Desmontando imagen virtual de Office..." -ForegroundColor DarkGray
if ($ImagePath -and (Test-Path $ImagePath)) {
    Dismount-DiskImage -ImagePath $ImagePath -ErrorAction SilentlyContinue | Out-Null
} else {
    Get-Volume | Where-Object {$_.DriveType -eq 'CD-ROM'} | ForEach-Object {
        Dismount-DiskImage -DevicePath $_.DevicePath -ErrorAction SilentlyContinue | Out-Null
    }
}

Write-Host "      - Eliminando la ISO de 4.5GB y herramientas YAOCTRI..." -ForegroundColor DarkGray
Set-Location -Path C:\
if ($WorkDir -and (Test-Path $WorkDir)) {
    Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "      - Vaciando carpetas temporales de Windows..." -ForegroundColor DarkGray
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:WINDIR\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n=================================================" -ForegroundColor DarkGray
Write-Host "     SERVICE PC GLEW - DESPLIEGUE COMPLETADO     " -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor DarkGray
Write-Host " [OK] Office instalado y sistema limpio." -ForegroundColor Green
Start-Sleep -Seconds 5
'@
            $tempScript = Join-Path $env:TEMP "yaoctri-deploy.ps1"
            $scriptContent | Out-File -FilePath $tempScript -Force -Encoding utf8
            Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass", "-NoExit", "-File", "`"$tempScript`"" -Verb RunAs
        }
        "WPFToggleFOSSHighlight" {
            if ($sync.WPFToggleFOSSHighlight.IsChecked) {
                 $sync.Form.Resources["FOSSColor"] = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(255, 106, 0)) # #FF6A00
            } else {
                 $sync.Form.Resources["FOSSColor"] = $sync.Form.Resources["MainForegroundColor"]
            }
        }
    }
}
function Invoke-WPFFeatureInstall {
    <#

    .SYNOPSIS
        Installs selected Windows Features

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFFeatureInstall] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $handle = Invoke-WPFRunspace -ScriptBlock {
        $Features = $sync.selectedFeatures
        $sync.ProcessRunning = $true
        if ($Features.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }

        $x = 0

        $Features | ForEach-Object {
            Invoke-WinUtilFeatureInstall $_
            $X++
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($x/$CheckBox.Count) }
        }

        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }

        Write-Host "==================================="
        Write-Host "---   Features are Installed    ---"
        Write-Host "---  A Reboot may be required   ---"
        Write-Host "==================================="
    }
}
function Invoke-WPFFixesNetwork {
    <#

    .SYNOPSIS
        Resets various network configurations

    #>

    Write-Host "Resetting Network with netsh"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo"
    # Reset WinSock catalog to a clean state
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.35 -overlay "logo"
    # Resets WinHTTP proxy setting to DIRECT
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.7 -overlay "logo"
    # Removes all user configured IP settings
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    Write-Host "Process complete. Please reboot your computer."

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "Network Reset "
    $Messageboxbody = ("Stock settings loaded.`n Please reboot your computer")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "=========================================="
    Write-Host "-- Network Configuration has been Reset --"
    Write-Host "=========================================="
}
function Invoke-WPFFixesNTPPool {
    <#
    .SYNOPSIS
        Configures Windows to use pool.ntp.org for NTP synchronization

    .DESCRIPTION
        Replaces the default Windows NTP server (time.windows.com) with
        pool.ntp.org for improved time synchronization accuracy and reliability.
    #>

    Start-Service w32time
    w32tm /config /update /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL

    Restart-Service w32time
    w32tm /resync

    Write-Host "================================="
    Write-Host "-- NTP Configuration Complete ---"
    Write-Host "================================="
}
function Invoke-WPFFixesUpdate {

    <#

    .SYNOPSIS
        Performs various tasks in an attempt to repair Windows Update

    .DESCRIPTION
        1. (Aggressive Only) Scans the system for corruption using the Invoke-WPFSystemRepair function
        2. Stops Windows Update Services
        3. Remove the QMGR Data file, which stores BITS jobs
        4. (Aggressive Only) Renames the DataStore and CatRoot2 folders
            DataStore - Contains the Windows Update History and Log Files
            CatRoot2 - Contains the Signatures for Windows Update Packages
        5. Renames the Windows Update Download Folder
        6. Deletes the Windows Update Log
        7. (Aggressive Only) Resets the Security Descriptors on the Windows Update Services
        8. Reregisters the BITS and Windows Update DLLs
        9. Removes the WSUS client settings
        10. Resets WinSock
        11. Gets and deletes all BITS jobs
        12. Sets the startup type of the Windows Update Services then starts them
        13. Forces Windows Update to check for updates

    .PARAMETER Aggressive
        If specified, the script will take additional steps to repair Windows Update that are more dangerous, take a significant amount of time, or are generally unnecessary

    #>

    param($Aggressive = $false)

    Write-Progress -Id 0 -Activity "Repairing Windows Update" -PercentComplete 0
    Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
    Write-Host "Starting Windows Update Repair..."
    # Wait for the first progress bar to show, otherwise the second one won't show
    Start-Sleep -Milliseconds 200

    if ($Aggressive) {
        Invoke-WPFSystemRepair
    }


    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Stopping Windows Update Services..." -PercentComplete 10
    # Stop the Windows Update Services
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping BITS..." -PercentComplete 0
    Stop-Service -Name BITS -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping wuauserv..." -PercentComplete 20
    Stop-Service -Name wuauserv -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping appidsvc..." -PercentComplete 40
    Stop-Service -Name appidsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping cryptsvc..." -PercentComplete 60
    Stop-Service -Name cryptsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Completed" -PercentComplete 100


    # Remove the QMGR Data file
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Renaming/Removing Files..." -PercentComplete 20
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing QMGR Data files..." -PercentComplete 0
    Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue


    if ($Aggressive) {
        # Rename the Windows Update Log and Signature Folders
        Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Log, Download, and Signature Folder..." -PercentComplete 20
        Rename-Item $env:systemroot\SoftwareDistribution\DataStore DataStore.bak -ErrorAction SilentlyContinue
        Rename-Item $env:systemroot\System32\Catroot2 catroot2.bak -ErrorAction SilentlyContinue
    }

    # Rename the Windows Update Download Folder
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Download Folder..." -PercentComplete 20
    Rename-Item $env:systemroot\SoftwareDistribution\Download Download.bak -ErrorAction SilentlyContinue

    # Delete the legacy Windows Update Log
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing the old Windows Update log..." -PercentComplete 80
    Remove-Item $env:systemroot\WindowsUpdate.log -ErrorAction SilentlyContinue
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Completed" -PercentComplete 100


    if ($Aggressive) {
        # Reset the Security Descriptors on the Windows Update Services
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting the WU Service Security Descriptors..." -PercentComplete 25
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the BITS Security Descriptor..." -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "bits", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the wuauserv Security Descriptor..." -PercentComplete 50
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "wuauserv", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Completed" -PercentComplete 100
    }


    # Reregister the BITS and Windows Update DLLs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Reregistering DLLs..." -PercentComplete 40
    $oldLocation = Get-Location
    Set-Location $env:systemroot\system32
    $i = 0
    $DLLs = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
        "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
        "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
        "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
        "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
        "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
        "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    foreach ($dll in $DLLs) {
        Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Registering $dll..." -PercentComplete ($i / $DLLs.Count * 100)
        $i++
        Start-Process -NoNewWindow -FilePath "regsvr32.exe" -ArgumentList "/s", $dll
    }
    Set-Location $oldLocation
    Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Completed" -PercentComplete 100


    # Remove the WSUS client settings
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate") {
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing WSUS client settings..." -PercentComplete 60
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "AccountDomainSid", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "PingID", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "SusClientId", "/f" -RedirectStandardError "NUL"
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -Status "Completed" -PercentComplete 100
    }

    # Remove Group Policy Windows Update settings
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing Group Policy Windows Update settings..." -PercentComplete 60
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -PercentComplete 0
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting driver offering through Windows Update..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting Windows Update automatic restart..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -ErrorAction SilentlyContinue
    Write-Host "Clearing ANY Windows Update Policy settings..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -NoNewWindow -FilePath "secedit" -ArgumentList "/configure", "/cfg", "$env:windir\inf\defltbase.inf", "/db", "defltbase.sdb", "/verbose" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy" -Wait
    Start-Process -NoNewWindow -FilePath "gpupdate" -ArgumentList "/force" -Wait
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -Status "Completed" -PercentComplete 100


    # Reset WinSock
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting WinSock..." -PercentComplete 65
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Resetting WinSock..." -PercentComplete 0
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Completed" -PercentComplete 100


    # Get and delete all BITS jobs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Deleting BITS jobs..." -PercentComplete 75
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Deleting BITS jobs..." -PercentComplete 0
    Get-BitsTransfer | Remove-BitsTransfer
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Completed" -PercentComplete 100


    # Change the startup type of the Windows Update Services and start them
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Starting Windows Update Services..." -PercentComplete 90
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting BITS..." -PercentComplete 0
    Get-Service BITS | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting wuauserv..." -PercentComplete 25
    Get-Service wuauserv | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting AppIDSvc..." -PercentComplete 50
    # The AppIDSvc service is protected, so the startup type has to be changed in the registry
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value "3" # Manual
    Start-Service AppIDSvc
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting CryptSvc..." -PercentComplete 75
    Get-Service CryptSvc | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Completed" -PercentComplete 100


    # Force Windows Update to check for updates
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Forcing discovery..." -PercentComplete 95
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Forcing discovery..." -PercentComplete 0
    try {
        (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    } catch {
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Write-Warning "Failed to create Windows Update COM object: $_"
    }
    Start-Process -NoNewWindow -FilePath "wuauclt" -ArgumentList "/resetauthorization", "/detectnow"
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Completed" -PercentComplete 100
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Completed" -PercentComplete 100

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "Reset Windows Update "
    $Messageboxbody = ("Stock settings loaded.`n Please reboot your computer")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "==============================================="
    Write-Host "-- Reset All Windows Update Settings to Stock -"
    Write-Host "==============================================="

    # Remove the progress bars
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Completed
    Write-Progress -Id 1 -Activity "Scanning for corruption" -Completed
    Write-Progress -Id 2 -Activity "Stopping Services" -Completed
    Write-Progress -Id 3 -Activity "Renaming/Removing Files" -Completed
    Write-Progress -Id 4 -Activity "Resetting the WU Service Security Descriptors" -Completed
    Write-Progress -Id 5 -Activity "Reregistering DLLs" -Completed
    Write-Progress -Id 6 -Activity "Removing Group Policy Windows Update settings" -Completed
    Write-Progress -Id 7 -Activity "Resetting WinSock" -Completed
    Write-Progress -Id 8 -Activity "Deleting BITS jobs" -Completed
    Write-Progress -Id 9 -Activity "Starting Windows Update Services" -Completed
    Write-Progress -Id 10 -Activity "Forcing discovery" -Completed
}
function Invoke-WPFFixesWinget {

    <#

    .SYNOPSIS
        Fixes WinGet by running `choco install winget`
    .DESCRIPTION
        BravoNorris for the fantastic idea of a button to reinstall WinGet
    #>
    # Install Choco if not already present
    try {
        Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
        Write-Host "==> Starting WinGet Repair"
        Install-WinUtilWinget
    } catch {
        Write-Error "Failed to install WinGet: $_"
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
    } finally {
        Write-Host "==> Finished WinGet Repair"
        Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    }

}
function Invoke-WPFGetInstalled {
    <#
    TODO: Add the Option to use Chocolatey as Engine
    .SYNOPSIS
        Invokes the function that gets the checkboxes to check in a new runspace

    .PARAMETER checkbox
        Indicates whether to check for installed 'winget' programs or applied 'tweaks'

    #>
    param($checkbox)
    if ($sync.ProcessRunning) {
        $msg = "[Invoke-WPFGetInstalled] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if (($sync.ChocoRadioButton.IsChecked -eq $false) -and ((Test-WinUtilPackageManager -winget) -eq "not-installed") -and $checkbox -eq "winget") {
        return
    }
    $managerPreference = $sync.preferences.packagemanager

    Invoke-WPFRunspace -ParameterList @(("managerPreference", $managerPreference),("checkbox", $checkbox)) -ScriptBlock {
        param (
            [string]$checkbox,
            [PackageManagers]$managerPreference
        )
        $sync.ProcessRunning = $true
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" }

        if ($checkbox -eq "winget") {
            Write-Host "Getting Installed Programs..."
            switch ($managerPreference) {
                "Choco"{$Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox "choco"; break}
                "Winget"{$Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox; break}
            }
        }
        elseif ($checkbox -eq "tweaks") {
            Write-Host "Getting Installed Tweaks..."
            $Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox
        }

        $sync.form.Dispatcher.invoke({
            foreach ($checkbox in $Checkboxes) {
                $sync.$checkbox.ischecked = $True
            }
        })

        Write-Host "Done..." -ForegroundColor Green
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" }
    }
}
function Invoke-WPFImpex {
    <#

    .SYNOPSIS
        Handles importing and exporting of the checkboxes checked for the tweaks section

    .PARAMETER type
        Indicates whether to 'import' or 'export'

    .PARAMETER checkbox
        The checkbox to export to a file or apply the imported file to

    .EXAMPLE
        Invoke-WPFImpex -type "export"

    #>
    param(
        $type,
        $Config = $null
    )

    function ConfigDialog {
        if (!$Config) {
            switch ($type) {
                "export" { $FileBrowser = New-Object System.Windows.Forms.SaveFileDialog }
                "import" { $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog }
            }
            $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            $FileBrowser.Filter = "JSON Files (*.json)|*.json"
            $FileBrowser.ShowDialog() | Out-Null

            if ($FileBrowser.FileName -eq "") {
                return $null
            } else {
                return $FileBrowser.FileName
            }
        } else {
            return $Config
        }
    }

    switch ($type) {
        "export" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    $allConfs = ($sync.selectedApps + $sync.selectedTweaks + $sync.selectedToggles + $sync.selectedFeatures) | ForEach-Object { [string]$_ }
                    if (-not $allConfs) {
                        [System.Windows.MessageBox]::Show(
                            "No settings are selected to export. Please select at least one app, tweak, toggle, or feature before exporting.",
                            "Nothing to Export", "OK", "Warning")
                        return
                    }
                    $jsonFile = $allConfs | ConvertTo-Json
                    $jsonFile | Out-File $Config -Force
                    "iex ""& { `$(irm https://servicepcglew-winutil.pages.dev/winutil.ps1) } -Config '$Config'""" | Set-Clipboard
                }
            } catch {
                Write-Error "An error occurred while exporting: $_"
            }
        }
        "import" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    try {
                        if ($Config -match '^https?://') {
                            $jsonFile = (Invoke-WebRequest "$Config").Content | ConvertFrom-Json
                        } else {
                            $jsonFile = Get-Content $Config | ConvertFrom-Json
                        }
                    } catch {
                        Write-Error "Failed to load the JSON file from the specified path or URL: $_"
                        return
                    }
                    # TODO how to handle old style? detected json type then flatten it in a func?
                    # $flattenedJson = $jsonFile.PSObject.Properties.Where({ $_.Name -ne "Install" }).ForEach({ $_.Value })
                    $flattenedJson = $jsonFile

                    if (-not $flattenedJson) {
                        [System.Windows.MessageBox]::Show(
                            "The selected file contains no settings to import. No changes have been made.",
                            "Empty Configuration", "OK", "Warning")
                        return
                    }

                    # Clear all existing selections before importing so the import replaces
                    # the current state rather than merging with it
                    $sync.selectedApps = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()

                    Update-WinUtilSelections -flatJson $flattenedJson

                    if (!$PARAM_NOUI) {
                        # Set flag so toggle Checked/Unchecked events don't trigger registry writes
                        # while we're programmatically restoring UI state from the imported config
                        $sync.ImportInProgress = $true
                        try {
                            Reset-WPFCheckBoxes -doToggles $true
                        } finally {
                            $sync.ImportInProgress = $false
                        }
                    }
                }
            } catch {
                Write-Error "An error occurred while importing: $_"
            }
        }
    }
}
function Invoke-WPFInstall {
    <#
    .SYNOPSIS
        Installs the selected programs using winget, if one or more of the selected programs are already installed on the system, winget will try and perform an upgrade if there's a newer version to install.
    #>

    $PackagesToInstall = $sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ }


    if ($sync.ProcessRunning) {
        $msg = "[Invoke-WPFInstall] An Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if ($PackagesToInstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to install or upgrade."
        [System.Windows.MessageBox]::Show($WarningMsg, $AppTitle, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $ManagerPreference = $sync.preferences.packagemanager

    $handle = Invoke-WPFRunspace -ParameterList @(("PackagesToInstall", $PackagesToInstall), ("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToInstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToInstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted[[PackageManagers]::Winget]
        $packagesChoco = $packagesSorted[[PackageManagers]::Choco]

        try {
            $sync.ProcessRunning = $true
            if ($packagesWinget.Count -gt 0 -and $packagesWinget -ne "0") {
                Show-WPFInstallAppBusy -text "Installing apps..."
                Install-WinUtilWinget
                Install-WinUtilProgramWinget -Action Install -Programs $packagesWinget
            }
            if ($packagesChoco.Count -gt 0) {
                Install-WinUtilChoco
                Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
            }
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "--      Installs have finished          ---"
            Write-Host "==========================================="
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        }
        catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
        }
        $sync.ProcessRunning = $False
    }
}
function Invoke-WPFInstallUpgrade {
    if ($sync.ChocoRadioButton.IsChecked) {
        Install-WinUtilChoco # Ensure Chocolatey is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'choco upgrade all -y'
    } else {
        Install-WinUtilWinget # Ensure WinGet is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements'
    }
}
function Invoke-WPFOOSU {
    <#
    .SYNOPSIS
        Downloads and runs OO Shutup 10
    #>
    try {
        $OOSU_filepath = "$ENV:temp\OOSU10.exe"
        $Initial_ProgressPreference = $ProgressPreference
        $ProgressPreference = "SilentlyContinue" # Disables the Progress Bar to drasticly speed up Invoke-WebRequest
        Invoke-WebRequest -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" -OutFile $OOSU_filepath
        Write-Host "Starting OO Shutup 10 ..."
        Start-Process $OOSU_filepath
    } catch {
        Write-Host "Error Downloading and Running OO Shutup 10" -ForegroundColor Red
    }
    finally {
        $ProgressPreference = $Initial_ProgressPreference
    }
}
function Invoke-WPFPanelAutologin {
    <#

    .SYNOPSIS
        Enables autologin using Sysinternals Autologon.exe

    #>

    # Official Microsoft recommendation: https://learn.microsoft.com/en-us/sysinternals/downloads/autologon
    Invoke-WebRequest -Uri "https://live.sysinternals.com/Autologon.exe" -OutFile "$env:temp\autologin.exe"
    cmd /c "$env:temp\autologin.exe" /accepteula
}
function Invoke-WPFPopup {
    param (
        [ValidateSet("Show", "Hide", "Toggle")]
        [string]$Action = "",

        [string[]]$Popups = @(),

        [ValidateScript({
            $invalid = $_.GetEnumerator() | Where-Object { $_.Value -notin @("Show", "Hide", "Toggle") }
            if ($invalid) {
                throw "Found invalid Popup-Action pair(s): " + ($invalid | ForEach-Object { "$($_.Key) = $($_.Value)" } -join "; ")
            }
            $true
        })]
        [hashtable]$PopupActionTable = @{}
    )

    if (-not $PopupActionTable.Count -and (-not $Action -or -not $Popups.Count)) {
        throw "Provide either 'PopupActionTable' or both 'Action' and 'Popups'."
    }

    if ($PopupActionTable.Count -and ($Action -or $Popups.Count)) {
        throw "Use 'PopupActionTable' on its own, or 'Action' with 'Popups'."
    }

    # Collect popups and actions
    $PopupsToProcess = if ($PopupActionTable.Count) {
        $PopupActionTable.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Key)Popup"; Action = $_.Value } }
    } else {
        $Popups | ForEach-Object { [PSCustomObject]@{ Name = "$_`Popup"; Action = $Action } }
    }

    $PopupsNotFound = @()

    # Apply actions
    foreach ($popupEntry in $PopupsToProcess) {
        $popupName = $popupEntry.Name

        if (-not $sync.$popupName) {
            $PopupsNotFound += $popupName
            continue
        }

        $sync.$popupName.IsOpen = switch ($popupEntry.Action) {
            "Show" { $true }
            "Hide" { $false }
            "Toggle" { -not $sync.$popupName.IsOpen }
        }
    }

    if ($PopupsNotFound.Count -gt 0) {
        throw "Could not find the following popups: $($PopupsNotFound -join ', ')"
    }
}
function Invoke-WPFPresets {
    <#

    .SYNOPSIS
        Sets the checkboxes in winutil to the given preset

    .PARAMETER preset
        The preset to set the checkboxes to

    .PARAMETER imported
        If the preset is imported from a file, defaults to false

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"

    #>

    param (
        [Parameter(position=0)]
        [Array]$preset = $null,

        [Parameter(position=1)]
        [bool]$imported = $false,

        [Parameter(position=2)]
        [string]$checkboxfilterpattern = "**"
    )

    if ($imported -eq $true) {
        $CheckBoxesToCheck = $preset
    } else {
        $CheckBoxesToCheck = $sync.configs.preset.$preset
    }

    # clear out the filtered pattern so applying a preset replaces the current
    # state rather than merging with it
    switch ($checkboxfilterpattern) {
        "WPFTweak*" { $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new() }
        "WPFInstall*" { $sync.selectedApps = [System.Collections.Generic.List[string]]::new() }
        "WPFeatures" { $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new() }
        "WPFToggle" { $sync.selectedToggles = [System.Collections.Generic.List[string]]::new() }
        default {}
    }

    if ($preset) {
        Update-WinUtilSelections -flatJson $CheckBoxesToCheck
    }

    Reset-WPFCheckBoxes -doToggles $false -checkboxfilterpattern $checkboxfilterpattern
}
function Invoke-WPFRunspace {

    <#

    .SYNOPSIS
        Creates and invokes a runspace using the given scriptblock and argumentlist

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the runspace

    .PARAMETER ArgumentList
        A list of arguments to pass to the runspace

    .PARAMETER ParameterList
        A list of named parameters that should be provided.
    .EXAMPLE
        Invoke-WPFRunspace `
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ArgumentList "Installadvancedip,Installbitwarden" `

        Invoke-WPFRunspace`
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ParameterList @(("PackagesToInstall", @("Installadvancedip,Installbitwarden")),("ChocoPreference", $true))
    #>

    [CmdletBinding()]
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList
    )

    # Create a PowerShell instance
    $script:powershell = [powershell]::Create()

    # Add Scriptblock and Arguments to runspace
    $script:powershell.AddScript($ScriptBlock)
    $script:powershell.AddArgument($ArgumentList)

    foreach ($parameter in $ParameterList) {
        $script:powershell.AddParameter($parameter[0], $parameter[1])
    }

    $script:powershell.RunspacePool = $sync.runspace

    # Execute the RunspacePool
    $script:handle = $script:powershell.BeginInvoke()

    # Clean up the RunspacePool threads when they are complete, and invoke the garbage collector to clean up the memory
    if ($script:handle.IsCompleted) {
        $script:powershell.EndInvoke($script:handle)
        $script:powershell.Dispose()
        $sync.runspace.Dispose()
        $sync.runspace.Close()
        [System.GC]::Collect()
    }
    # Return the handle
    return $handle
}
function Invoke-WPFSelectedCheckboxesUpdate{
    <#
        .SYNOPSIS
            This is a helper function that is called by the Checked and Unchecked events of the Checkboxes.
            It also Updates the "Selected Apps" selectedAppLabel on the Install Tab to represent the current collection
        .PARAMETER type
            Either: Add | Remove
        .PARAMETER checkboxName
            should contain the name of the current instance of the checkbox that triggered the Event.
            Most of the time will be the automatic variable $this.Parent.Tag
        .EXAMPLE
            $checkbox.Add_Unchecked({Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag})
            OR
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $specificCheckbox.Parent.Tag
    #>
    param (
        $type,
        $checkboxName
    )

    if (($type -ne "Add") -and ($type -ne "Remove"))
    {
        Write-Error "Type: $type not implemented"
        return
    }

    # Get the actual Name from the selectedAppLabel inside the Checkbox
    $appKey = $checkboxName
    $group = if ($appKey.StartsWith("WPFInstall")) { "Install" }
                elseif ($appKey.StartsWith("WPFTweaks")) { "Tweaks" }
                elseif ($appKey.StartsWith("WPFToggle")) { "Toggle" }
                elseif ($appKey.StartsWith("WPFFeature")) { "Feature" }
                else { "na" }

    switch ($group) {
        "Install" {
            if ($type -eq "Add") {
               if (!$sync.selectedApps.Contains($appKey)) {
                    $sync.selectedApps.Add($appKey)
                    # The List type needs to be specified again, because otherwise Sort-Object will convert the list to a string if there is only a single entry
                    [System.Collections.Generic.List[string]]$sync.selectedApps = $sync.SelectedApps | Sort-Object
                }
            }
            else{
                $sync.selectedApps.Remove($appKey)
            }

            $count = $sync.SelectedApps.Count
            $sync.WPFselectedAppsButton.Content = "Selected Apps: $count"
            # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
            $sync.selectedAppsstackPanel.Children.Clear()
            $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }
        }
        "Tweaks" {
            if ($type -eq "Add") {
                if (!$sync.selectedTweaks.Contains($appKey)) {
                    $sync.selectedTweaks.Add($appKey)
                }
            }
            else{
                $sync.selectedTweaks.Remove($appKey)
            }
        }
        "Toggle" {
            if ($type -eq "Add") {
                if (!$sync.selectedToggles.Contains($appKey)) {
                    $sync.selectedToggles.Add($appKey)
                }
            }
            else{
                $sync.selectedToggles.Remove($appKey)
            }
        }
        "Feature" {
            if ($type -eq "Add") {
                if (!$sync.selectedFeatures.Contains($appKey)) {
                    $sync.selectedFeatures.Add($appKey)
                }
            }
            else{
                $sync.selectedFeatures.Remove($appKey)
            }
        }
        default {
            Write-Host "Unknown group for checkbox: $($appKey)"
        }
    }

    Write-Debug "-------------------------------------"
    Write-Debug "Selected Apps: $($sync.selectedApps)"
    Write-Debug "Selected Tweaks: $($sync.selectedTweaks)"
    Write-Debug "Selected Toggles: $($sync.selectedToggles)"
    Write-Debug "Selected Features: $($sync.selectedFeatures)"
    Write-Debug "--------------------------------------"
}
function Invoke-WPFSSHServer {
    <#

    .SYNOPSIS
        Invokes the OpenSSH Server install in a runspace

  #>

    Invoke-WPFRunspace -ScriptBlock {

        Invoke-WinUtilSSHServer

        Write-Host "======================================="
        Write-Host "--     OpenSSH Server installed!    ---"
        Write-Host "======================================="
    }
}
function Invoke-WPFSystemRepair {
    <#
    .SYNOPSIS
        Checks for system corruption using SFC, and DISM
        Checks for disk failure using Chkdsk

    .DESCRIPTION
        1. Chkdsk - Checks for disk errors, which can cause system file corruption and notifies of early disk failure
        2. SFC - scans protected system files for corruption and fixes them
        3. DISM - Repair a corrupted Windows operating system image
    #>

    Start-Process cmd.exe -ArgumentList "/c chkdsk /scan /perf" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c sfc /scannow" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c dism /online /cleanup-image /restorehealth" -NoNewWindow -Wait

    Write-Host "==> Finished System Repair"
    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
}
function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab
    )

    $tabNav = Get-WinUtilVariables | Where-Object {$psitem -like "WPFTabNav"}
    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab?BT"}
    ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
        if ($ClickedTab -ne $PSItem.name) {
            $sync[$PSItem.Name].IsChecked = $false
        } else {
            $sync["$ClickedTab"].IsChecked = $true
            $tabNumber = [int]($ClickedTab-replace "WPFTab","" -replace "BT","") - 1
            $sync.$tabNav.Items[$tabNumber].IsSelected = $true
        }
    }
    $sync.currentTab = $sync.$tabNav.Items[$tabNumber].Header

    # Always reset the filter for the current tab
    if ($sync.currentTab -eq "Instalar") {
        # Reset Install tab filter
        Find-AppsByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "Ajustes") {
        # Reset Tweaks tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    }

    # Show search bar in Install and Tweaks tabs
    if ($tabNumber -eq 0 -or $tabNumber -eq 2) {
        $sync.SearchBar.Visibility = "Visible"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Visible"
        }
    } else {
        $sync.SearchBar.Visibility = "Collapsed"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Collapsed"
        }
        # Hide the clear button if it's visible
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
}
function Invoke-WPFToggleAllCategories {
    <#
        .SYNOPSIS
            Expands or collapses all categories in the Install tab

        .PARAMETER Action
            The action to perform: "Expand" or "Collapse"

        .DESCRIPTION
            This function iterates through all category containers in the Install tab
            and expands or collapses their WrapPanels while updating the toggle button labels
    #>

    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Expand", "Collapse")]
        [string]$Action
    )

    try {
        if ($null -eq $sync.ItemsControl) {
            Write-Warning "ItemsControl not initialized"
            return
        }

        $targetVisibility = if ($Action -eq "Expand") { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $targetPrefix = if ($Action -eq "Expand") { "-" } else { "+" }
        $sourcePrefix = if ($Action -eq "Expand") { "+" } else { "-" }

        # Iterate through all items in the ItemsControl
        $sync.ItemsControl.Items | ForEach-Object {
            $categoryContainer = $_

            # Check if this is a category container (StackPanel with children)
            if ($categoryContainer -is [System.Windows.Controls.StackPanel] -and $categoryContainer.Children.Count -ge 2) {
                # Get the WrapPanel (second child)
                $wrapPanel = $categoryContainer.Children[1]
                $wrapPanel.Visibility = $targetVisibility

                # Update the label to show the correct state
                $categoryLabel = $categoryContainer.Children[0]
                if ($categoryLabel.Content -like "$sourcePrefix*") {
                    $escapedSourcePrefix = [regex]::Escape($sourcePrefix)
                    $categoryLabel.Content = $categoryLabel.Content -replace "^$escapedSourcePrefix ", "$targetPrefix "
                }
            }
        }
    }
    catch {
        Write-Error "Error toggling categories: $_"
    }
}
function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  if($sync.ProcessRunning) {
    $msg = "[Invoke-WPFtweaksbutton] El proceso de instalación se está ejecutando actualmente."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  $Tweaks = $sync.selectedTweaks
  $dnsProvider = $sync["WPFchangedns"].text
  if (-not ($dnsProvider)) {
    $dnsProvider = "Default"
  }
  $restorePointTweak = "WPFTweaksRestorePoint"
  $restorePointSelected = $Tweaks -contains $restorePointTweak
  $tweaksToRun = @($Tweaks | Where-Object { $_ -ne $restorePointTweak })
  $totalSteps = [Math]::Max($Tweaks.Count, 1)
  $completedSteps = 0

  if ($tweaks.count -eq 0 -and $dnsProvider -eq "Default") {
    $msg = "Por favor, selecciona los ajustes que deseas aplicar."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  Write-Debug "Number of tweaks to process: $($Tweaks.Count)"

  if ($restorePointSelected) {
    $sync.ProcessRunning = $true

    if ($Tweaks.Count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    Set-WinUtilProgressBar -Label "Creando punto de restauración" -Percent 0
    Invoke-WinUtilTweaks $restorePointTweak
    $completedSteps = 1

    if ($tweaksToRun.Count -eq 0 -and $dnsProvider -eq "Default") {
      Set-WinUtilProgressBar -Label "Ajustes finalizados" -Percent 100
      $sync.ProcessRunning = $false
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
      Write-Host "======================================"
      Write-Host "---   Los Ajustes han Finalizado   ---"
      Write-Host "======================================"
      return
    }
  }

  # The leading "," in the ParameterList is necessary because we only provide one argument and powershell cannot be convinced that we want a nested loop with only one argument otherwise
  $handle = Invoke-WPFRunspace -ParameterList @(("tweaks", $tweaksToRun), ("dnsProvider", $dnsProvider), ("completedSteps", $completedSteps), ("totalSteps", $totalSteps)) -ScriptBlock {
    param($tweaks, $dnsProvider, $completedSteps, $totalSteps)
    Write-Debug "Inside Number of tweaks to process: $($Tweaks.Count)"

    $sync.ProcessRunning = $true

    if ($completedSteps -eq 0) {
      if ($Tweaks.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
      } else {
        Invoke-WPFUIThread -ScriptBlock{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
      }
    }

    Set-WinUtilDNS -DNSProvider $dnsProvider

    for ($i = 0; $i -lt $tweaks.Count; $i++) {
      Set-WinUtilProgressBar -Label "Aplicando $($tweaks[$i])" -Percent ($completedSteps / $totalSteps * 100)
      Invoke-WinUtilTweaks $tweaks[$i]
      $completedSteps++
      $progress = $completedSteps / $totalSteps
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value $progress }
    }
    Set-WinUtilProgressBar -Label "Ajustes finalizados" -Percent 100
    $sync.ProcessRunning = $false
    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
    Write-Host "======================================"
    Write-Host "---   Los Ajustes han Finalizado   ---"
    Write-Host "======================================"
  }
}
function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.applications -targetGridName "install" -columncount 5
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Category    = $entryInfo.Category
            Content     = $entryInfo.Content
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = $entryInfo.description
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
            Order       = $entryInfo.Order
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $count = 0
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle
        $targetGrid.Children.Add($border) | Out-Null

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create an ItemsControl for application content
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'

        # Set the ItemsPanel to a VirtualizingStackPanel
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.VirtualizingStackPanel])
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Set virtualization properties
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty, [Windows.Controls.VirtualizationMode]::Recycling)

        # Add the ItemsControl directly to the DockPanel
        [Windows.Controls.DockPanel]::SetDock($itemsControl, [Windows.Controls.Dock]::Bottom)
        $dockPanelContainer.Children.Add($itemsControl) | Out-Null
        $panelcount++

        # Now proceed with adding category labels and entries to $itemsControl
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {
            $count++

            if ($category -eq "z__Activaciones") {
                $separator = New-Object Windows.Controls.Separator
                $separator.Height = 2
                $separator.Margin = "0,15,0,15"
                $separator.SetResourceReference([Windows.Controls.Separator]::BackgroundProperty, "BorderColor")
                $itemsControl.Items.Add($separator) | Out-Null
            }

            $label = New-Object Windows.Controls.Label
            $label.Content = $category -replace ".*__", ""
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "LabelboxForegroundColor")
            $label.UseLayoutRounding = $true
            $itemsControl.Items.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by type (checkboxes first, then buttons, then comboboxes) and then alphabetically by Content (or by Order for Activaciones and Desinstalaciones)
            if ($category -eq "z__Activaciones" -or $category -eq "zz__Desinstalaciones") {
                $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                    switch ($_.Type) {
                        'Button' { 1 }
                        'Combobox' { 2 }
                        default { 0 }
                    }
                }}, @{Expression = { [int]$_.Order }}
            } else {
                $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                    switch ($_.Type) {
                        'Button' { 1 }
                        'Combobox' { 2 }
                        default { 0 }
                    }
                }}, Content
            }
            foreach ($entryInfo in $entries) {
                $count++
                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        [System.Windows.Automation.AutomationProperties]::SetName($dockPanel, $entryInfo.Content)
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $label.UseLayoutRounding = $true
                        $dockPanel.Children.Add($label) | Out-Null
                        $itemsControl.Items.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox
                        if ($entryInfo.Name -eq "WPFToggleFOSSHighlight") {
                             if ($entryInfo.Checked -eq $true) {
                                 $sync[$entryInfo.Name].IsChecked = $true
                             }

                             $sync[$entryInfo.Name].Add_Checked({
                                 Invoke-WPFButton -Button "WPFToggleFOSSHighlight"
                             })
                             $sync[$entryInfo.Name].Add_Unchecked({
                                 Invoke-WPFButton -Button "WPFToggleFOSSHighlight"
                             })
                        } else {
                            $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                            $sync[$entryInfo.Name].Add_Checked({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                                # Skip applying tweaks while an import is restoring toggle states
                                if (-not $sync.ImportInProgress) {
                                    Invoke-WinUtilTweaks $Sender.name
                                }
                            })

                            $sync[$entryInfo.Name].Add_Unchecked({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                                # Skip undoing tweaks while an import is restoring toggle states
                                if (-not $sync.ImportInProgress) {
                                    Invoke-WinUtiltweaks $Sender.name -undo $true
                                }
                            })
                        }
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = $entryInfo.Description
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle
                        [System.Windows.Automation.AutomationProperties]::SetName($toggleButton, $entryInfo.Content[0])

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $contentOn }
                        }

                        $itemsControl.Items.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.HorizontalAlignment = "Left"
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $label.UseLayoutRounding = $true
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $comboBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        foreach ($comboitem in ($entryInfo.ComboItems -split " ")) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            $comboBoxItem.Content = $comboitem
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null

                        $comboBox.SelectedIndex = 0

                        # Set initial text
                        if ($comboBox.Items.Count -gt 0) {
                            $comboBox.Text = $comboBox.Items[0].Content
                        }

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if ($selectedItem) {
                                $this.Text = $selectedItem.Content
                            }
                        })

                        $sync[$entryInfo.Name] = $comboBox
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $baseWidth = [int]$entryInfo.ButtonWidth
                            $button.Width = [math]::Max($baseWidth, 350)
                        }

                        if ($entryInfo.Name -eq "WPFGetInstalled") {
                            $button.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "LabelboxForegroundColor")
                        }

                        [System.Windows.Automation.AutomationProperties]::SetName($button, $entryInfo.Content)
                        $itemsControl.Items.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"
                            [System.Windows.Automation.AutomationProperties]::SetName($groupStackPanel, $entryInfo.GroupName)

                            # Add the group container to the ItemsControl
                            $itemsControl.Items.Add($groupStackPanel) | Out-Null
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description
                        $radioButton.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($radioButton, $entryInfo.Content)

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = $entryInfo.Description
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = $entryInfo.Link
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkbox $Sender.name
                        })
                    }
                }
            }
        }
    }
}
function Invoke-WPFUIThread {
    <#

    .SYNOPSIS
        Creates and runs a task on Winutil's WPF Forms thread.

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the thread
    #>

    [CmdletBinding()]
    Param (
        $ScriptBlock
    )

    if ($PARAM_NOUI) {
        return;
    }

    $sync.form.Dispatcher.Invoke([action]$ScriptBlock)
}
function Invoke-WPFUltimatePerformance {
    param(
        [switch]$Do
    )

    if ($Do) {
        if (-not (powercfg /list | Select-String "Service PC Glew - Ultimate Power Plan")) {
            if (-not (powercfg /list | Select-String "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")) {
                powercfg /restoredefaultschemes
                if (-not (powercfg /list | Select-String "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")) {
                    Write-Host "No se pudo restaurar el plan de Alto Rendimiento. Los planes por defecto no incluyen alto rendimiento. Si estás en una laptop, NO uses los planes de Alto Rendimiento o Rendimiento Definitivo." -ForegroundColor Red
                    return
                }
            }
            $guid = ((powercfg /duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c) -split '\s+')[3]
            powercfg /changename $guid "Service PC Glew - Ultimate Power Plan"
            powercfg /setacvalueindex $guid SUB_PROCESSOR IDLEDISABLE 1
            powercfg /setacvalueindex $guid 54533251-82be-4824-96c1-47b60b740d00 4d2b0152-7d5c-498b-88e2-34345392a2c5 1
            powercfg /setacvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMIN 100
            powercfg /setactive $guid
            $E = [char]27
            $orange = "$E[38;2;255;106;0m"
            $reset = "$E[0m"
            Write-Host "${orange}Plan Service PC Glew - Ultimate Power Plan instalado y activado.${reset}"
        } else {
            Write-Host "El plan Service PC Glew - Ultimate Power Plan ya está instalado." -ForegroundColor Red
            return
        }
    } else {
        if (powercfg /list | Select-String "Service PC Glew - Ultimate Power Plan") {
            powercfg /setactive SCHEME_BALANCED
            powercfg /delete ((powercfg /list | Select-String "Service PC Glew - Ultimate Power Plan").ToString().Split()[3])
            Write-Host "El plan Service PC Glew - Ultimate Power Plan fue eliminado." -ForegroundColor Red
        } else {
            Write-Host "El plan Service PC Glew - Ultimate Power Plan no está instalado." -ForegroundColor Yellow
        }
    }
}
function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFundoall] Un proceso de instalación se está ejecutando actualmente."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $tweaks = $sync.selectedTweaks

    if ($tweaks.count -eq 0) {
        $msg = "Por favor, selecciona los ajustes que deseas deshacer."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ArgumentList $tweaks -ScriptBlock {
        param($tweaks)

        $sync.ProcessRunning = $true
        if ($tweaks.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }


        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            Set-WinUtilProgressBar -Label "Deshaciendo $($tweaks[$i])" -Percent ($i / $tweaks.Count * 100)
            Invoke-WinUtiltweaks $tweaks[$i] -undo $true
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($i/$tweaks.Count) }
        }

        Set-WinUtilProgressBar -Label "Deshacer Ajustes Finalizado" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        Write-Host "====================================="
        Write-Host "--- Se han deshecho los ajustes   ---"
        Write-Host "====================================="

    }
}
function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFUnInstall] Un proceso de instalación se está ejecutando actualmente."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "Por favor, selecciona los programas para desinstalar."
        [System.Windows.MessageBox]::Show($WarningMsg, $AppTitle, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $ButtonType = [System.Windows.MessageBoxButton]::YesNo
    $MessageboxTitle = "¿Estás seguro?"
    $Messageboxbody = ("Esto desinstalará las siguientes aplicaciones: `n $($PackagesToUninstall | Select-Object Name, Description| Out-String)")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    $confirm = [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)

    if($confirm -eq "No") {return}

    $ManagerPreference = $sync.preferences.packagemanager

    Invoke-WPFRunspace -ParameterList @(("PackagesToUninstall", $PackagesToUninstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToUninstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference
        $packagesWinget = $packagesSorted[[PackageManagers]::Winget]
        $packagesChoco = $packagesSorted[[PackageManagers]::Choco]

        try {
            $sync.ProcessRunning = $true
            Show-WPFInstallAppBusy -text "Desinstalando aplicaciones..."

            # Uninstall all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                Install-WinUtilProgramWinget -Action Uninstall -Programs $packagesWinget
            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
            }
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "--- Las Desinstalaciones han finalizado ---"
            Write-Host "==========================================="
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
           Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
        }
        $sync.ProcessRunning = $False

    }
}
function Invoke-WPFUpdatesdefault {
    <#

    .SYNOPSIS
        Resets Windows Update settings to default

    #>
    $ErrorActionPreference = 'SilentlyContinue'

    Write-Host "Removing Windows Update policy settings..." -ForegroundColor Green

    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse -Force

    Write-Host "Showing Windows Updates in settings"
    Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name SettingsPageVisibility

    Write-Host "Reenabling Windows Update Services..." -ForegroundColor Green

    Write-Host "Restored BITS to Manual"
    Set-Service -Name BITS -StartupType Manual

    Write-Host "Restored wuauserv to Manual"
    Set-Service -Name wuauserv -StartupType Manual

    Write-Host "Restored UsoSvc to Automatic"
    Start-Service -Name UsoSvc
    Set-Service -Name UsoSvc -StartupType Automatic

    Write-Host "Restored WaaSMedicSvc to Manual"
    Set-Service -Name WaaSMedicSvc -StartupType Manual

    Write-Host "Enabling update related scheduled tasks..." -ForegroundColor Green

    $Tasks =
    '\Microsoft\Windows\InstallService\*',
    '\Microsoft\Windows\UpdateOrchestrator\*',
    '\Microsoft\Windows\UpdateAssistant\*',
    '\Microsoft\Windows\WaaSMedic\*',
    '\Microsoft\Windows\WindowsUpdate\*',
    '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "Windows Local Policies Reset to Default"
    secedit /configure /cfg "$Env:SystemRoot\inf\defltbase.inf" /db defltbase.sdb

    $E = [char]27
    $orange = "$E[38;2;255;106;0m"
    $reset = "$E[0m"
    Write-Host "$orange===================================================$reset"
    Write-Host "$orange---  Configuración de Windows Update por Defecto   ---$reset"
    Write-Host "$orange===================================================$reset"

    Write-Host "Nota: Debes reiniciar tu sistema para que todos los cambios surtan efecto." -ForegroundColor Yellow
}
function Invoke-WPFUpdatesdisable {
    <#

    .SYNOPSIS
        Disables Windows Update

    .NOTES
        Disabling Windows Update is not recommended. This is only for advanced users who know what they are doing.

    #>
    $ErrorActionPreference = 'SilentlyContinue'

    Write-Host "Configurando ajustes del registro..." -ForegroundColor Yellow
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    Write-Host "Ocultando Windows Updates de la configuración..."
    Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name SettingsPageVisibility -Value hide:windowsupdate

    Write-Host "Servicio BITS deshabilitado"
    Set-Service -Name BITS -StartupType Disabled

    Write-Host "Servicio wuauserv deshabilitado"
    Set-Service -Name wuauserv -StartupType Disabled

    Write-Host "Servicio UsoSvc deshabilitado"
    Stop-Service -Name UsoSvc -Force
    Set-Service -Name UsoSvc -StartupType Disabled

    Remove-Item "C:\Windows\SoftwareDistribution\*" -Recurse -Force
    Write-Host "Carpeta SoftwareDistribution vaciada"

    Write-Host "Deshabilitando tareas programadas de actualización..." -ForegroundColor Yellow

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task | Disable-ScheduledTask -ErrorAction SilentlyContinue
    }

    $E = [char]27
    $orange = "$E[38;2;255;106;0m"
    $reset = "$E[0m"
    Write-Host "$orange==========================================$reset"
    Write-Host "$orange---    Actualizaciones Deshabilitadas  ---$reset"
    Write-Host "$orange==========================================$reset"

    Write-Host "Nota: Debes reiniciar el sistema para que todos los cambios surtan efecto." -ForegroundColor Yellow
}
function Invoke-WPFUpdatessecurity {
    <#

    .SYNOPSIS
        Sets Windows Update to recommended settings

    .DESCRIPTION
        1. Disables driver offering through Windows Update
        2. Disables Windows Update automatic restart
        3. Sets Windows Update to Semi-Annual Channel (Targeted)
        4. Defers feature updates for 365 days
        5. Defers quality updates for 4 days

    #>

    Write-Host "Deshabilitando la descarga de drivers a través de Windows Update..."

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

    Write-Host "Retrasando actualizaciones acumulativas por 1 año y de seguridad por 4 días..."

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -Type DWord -Value 20
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

    Write-Host "Deshabilitando el reinicio automático de Windows Update..."

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -Type DWord -Value 0

    Write-Host "============================================"
    Write-Host "--- Actualizaciones Recomendadas Activas ---"
    Write-Host "============================================"
}
function Invoke-WPFDriverBooster {
    [OutputType([void])]
    param()

    # El script que se ejecutará como Administrador en una nueva ventana de PowerShell
    $ScriptContent = @'
# 0. Configurar protocolo TLS seguro y desactivar barra de progreso para descarga ultra rápida
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# 1. Definir el ID del archivo de Google Drive
$fileId = "1eeEe3yylzdxvT8d_2GXO2t5n4wbj3yrp"

# 2. Definir las rutas en el Escritorio
$desktopPath = [Environment]::GetFolderPath("Desktop")
$filePath = Join-Path $desktopPath "Driver Booster.7z"
$downloadUrl = "https://docs.google.com/uc?export=download&id=$fileId"

Write-Host "Descargando Driver Booster.7z en tu Escritorio de forma ultra rápida..." -ForegroundColor Cyan

try {
    # Hacemos la primera petición guardando la sesión para manejar la advertencia de virus de Google Drive
    Invoke-WebRequest -Uri $downloadUrl -OutFile $filePath -UserAgent "Mozilla/5.0" -SessionVariable mySession -ErrorAction Stop

    # Si es menor a 100 KB, es muy probable que sea la página de confirmación/error de Google Drive
    if ((Get-Item $filePath).Length -lt 100000) {
        $content = Get-Content $filePath -Raw -ErrorAction SilentlyContinue
        $confirmToken = ""
        
        if ($content -match 'confirm=([a-zA-Z0-9_]+)') {
            $confirmToken = $Matches[1]
        } elseif ($content -match 'name="confirm"\s+value="([^"]+)"') {
            $confirmToken = $Matches[1]
        } elseif ($content -match 'value="([^"]+)"\s+name="confirm"') {
            $confirmToken = $Matches[1]
        }

        if ($confirmToken) {
            $confirmUrl = "https://drive.usercontent.google.com/download?export=download&confirm=$confirmToken&id=$fileId"
            Write-Host "Confirmando y completando descarga del archivo..." -ForegroundColor Yellow
            Invoke-WebRequest -Uri $confirmUrl -OutFile $filePath -UserAgent "Mozilla/5.0" -WebSession $mySession -ErrorAction Stop
        }
    }

    # Colores personalizados naranja de Service PC Glew (#FF6A00) para el mensaje de éxito
    $E = [char]27
    Write-Host ""
    Write-Host "$E[38;2;255;106;0m¡Listo! El archivo Driver Booster.7z (22.7 MB) ha sido descargado correctamente en tu Escritorio.$E[0m"
    Write-Host ""
} catch {
    Write-Host "Error al descargar: $_" -ForegroundColor Red
}

Read-Host "Presiona Enter para continuar..."
'@

    # Guardar en un archivo temporal y ejecutarlo como Administrador
    $TempFile = Join-Path $env:TEMP "download-driverbooster.ps1"
    $ScriptContent | Out-File -FilePath $TempFile -Force -Encoding utf8
    Start-Process powershell -ArgumentList "-NoExit", "-ExecutionPolicy Bypass", "-File `"$TempFile`"" -Verb RunAs
}
Function Show-SPGLogo {
    <#
        .SYNOPSIS
            Displays the Service PC Glew logo in ASCII art.
        .DESCRIPTION
            This function displays the Service PC Glew logo in ASCII art format.
        .PARAMETER None
            No parameters are required for this function.
        .EXAMPLE
            Show-SPGLogo
            Prints the Service PC Glew logo in ASCII art format to the console.
    #>

    $E = [char]27
    $orange = "$E[38;2;255;127;0m"
    $white = "$E[38;2;255;255;255m"
    $reset = "$E[0m"

    # CAMBIA A $true PARA MOSTRAR EL LOGO GIGANTE, O $false PARA OCULTARLO
    $MostrarLogoCompleto = $true

    if ($MostrarLogoCompleto) {
        $line1 = "${orange}  ____                  _            ____   ____    ____ _                  ${reset}"
        $line2 = "${orange} / ___|  ___ _ ____   _(_) ___ ___  |  _ \ / ___|  / ___| | _____      __   ${reset}"
        $line3 = "${orange} \___ \ / _ \ '__\ \ / / |/ __/ _ \ | |_) | |     | |  _| |/ _ \ \ /\ / /   ${reset}"
        $line4 = "${orange}  ___) |  __/ |   \ V /| | (_|  __/ |  __/| |___  | |_| | |  __/\ V  V /    ${reset}"
        $line5 = "${orange} |____/ \___|_|    \_/ |_|\___\___| |_|    \____|  \____|_|\___| \_/\_/   ${reset}"

        Write-Host $line1
        Write-Host $line2
        Write-Host $line3
        Write-Host $line4
        Write-Host $line5
    }

    Write-Host ""
    Write-Host "$orange====$($white)Service PC Glew | Servicio Técnico Informático$orange=====$reset"
    Write-Host "$orange=====$($white)Herramientas de Windows$orange=====$reset"
    Write-Host "${orange}https://servicepcglew.pages.dev/$reset"
}
$sync.configs.applications = @'
{
    "WPFInstall1password":  {
                                "category":  "Utilidades",
                                "choco":  "1password",
                                "content":  "1Password",
                                "description":  "1Password es un gestor de contraseñas que te permite almacenar y gestionar tus contraseñas de forma segura.",
                                "link":  "https://1password.com/",
                                "winget":  "AgileBits.1Password",
                                "foss":  false
                            },
    "WPFInstall7zip":  {
                           "category":  "Utilidades",
                           "choco":  "7zip",
                           "content":  "7-Zip",
                           "description":  "7-Zip es una utilidad de compresión de archivos gratuita y de código abierto. Soporta varios formatos y proporciona un alto nivel de compresión.",
                           "link":  "https://www.7-zip.org/",
                           "winget":  "7zip.7zip",
                           "foss":  true
                       },
    "WPFInstalladobe":  {
                            "category":  "Herramientas Multimedia",
                            "choco":  "adobereader",
                            "content":  "Adobe Acrobat Reader",
                            "description":  "Adobe Acrobat Reader es un visor de PDF gratuito con funciones esenciales para ver, imprimir y anotar documentos PDF.",
                            "link":  "https://www.adobe.com/acrobat/pdf-reader.html",
                            "winget":  "Adobe.Acrobat.Reader.64-bit",
                            "foss":  false
                        },
    "WPFInstalladvancedip":  {
                                 "category":  "Herramientas Profesionales",
                                 "choco":  "advanced-ip-scanner",
                                 "content":  "Advanced IP Scanner",
                                 "description":  "Advanced IP Scanner es un escáner de red rápido y fácil de usar. Está diseñado para analizar redes LAN y proporcionar información sobre los dispositivos.",
                                 "link":  "https://www.advanced-ip-scanner.com/",
                                 "winget":  "Famatech.AdvancedIPScanner",
                                 "foss":  false
                             },
    "WPFInstallaimp":  {
                           "category":  "Herramientas Multimedia",
                           "choco":  "aimp",
                           "content":  "AIMP (Music Player)",
                           "description":  "AIMP es un reproductor de música con soporte para varios formatos de audio, listas de reproducción y una interfaz personalizable.",
                           "link":  "https://www.aimp.ru/",
                           "winget":  "AIMP.AIMP",
                           "foss":  false
                       },
    "WPFInstallangryipscanner":  {
                                     "category":  "Herramientas Profesionales",
                                     "choco":  "angryip",
                                     "content":  "Angry IP Scanner",
                                     "description":  "Angry IP Scanner es un escáner de red multiplataforma de código abierto. Se usa para escanear direcciones IP y puertos.",
                                     "link":  "https://angryip.org/",
                                     "winget":  "angryziber.AngryIPScanner",
                                     "foss":  true
                                 },
    "WPFInstallanydesk":  {
                              "category":  "Utilidades",
                              "choco":  "anydesk",
                              "content":  "AnyDesk",
                              "description":  "AnyDesk es un software de escritorio remoto que permite acceder y controlar ordenadores. Es conocido por su conexión rápida y baja latencia.",
                              "link":  "https://anydesk.com/",
                              "winget":  "AnyDesk.AnyDesk",
                              "foss":  false
                          },
    "WPFInstallaudacity":  {
                               "category":  "Herramientas Multimedia",
                               "choco":  "audacity",
                               "content":  "Audacity",
                               "description":  "Audacity es un software de edición de audio gratuito y de código abierto conocido por sus potentes capacidades de grabación y edición.",
                               "link":  "https://www.audacityteam.org/",
                               "winget":  "Audacity.Audacity",
                               "foss":  true
                           },
    "WPFInstallautoruns":  {
                               "category":  "Herramientas de Microsoft",
                               "choco":  "autoruns",
                               "content":  "Autoruns",
                               "description":  "Esta utilidad te muestra qué programas están configurados para ejecutarse durante el inicio del sistema o el inicio de sesión.",
                               "link":  "https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns",
                               "winget":  "Microsoft.Sysinternals.Autoruns",
                               "foss":  false
                           },
    "WPFInstallrdcman":  {
                             "category":  "Herramientas de Microsoft",
                             "choco":  "rdcman",
                             "content":  "RDCMan",
                             "description":  "RDCMan gestiona múltiples conexiones a escritorios remotos. Es útil para administrar laboratorios de servidores o centros de datos.",
                             "link":  "https://learn.microsoft.com/en-us/sysinternals/downloads/rdcman",
                             "winget":  "Microsoft.Sysinternals.RDCMan",
                             "foss":  false
                         },
    "WPFInstallautohotkey":  {
                                 "category":  "Utilidades",
                                 "choco":  "autohotkey",
                                 "content":  "AutoHotkey",
                                 "description":  "AutoHotkey es un lenguaje de scripting para Windows para crear macros de automatización. Muy usado para atajos de teclado y tareas repetitivas.",
                                 "link":  "https://www.autohotkey.com/",
                                 "winget":  "AutoHotkey.AutoHotkey",
                                 "foss":  true
                             },
    "WPFInstallbitwarden":  {
                                "category":  "Utilidades",
                                "choco":  "bitwarden",
                                "content":  "Bitwarden",
                                "description":  "Bitwarden es un gestor de contraseñas de código abierto. Permite almacenar contraseñas en una bóveda segura y cifrada.",
                                "link":  "https://bitwarden.com/",
                                "winget":  "Bitwarden.Bitwarden",
                                "foss":  true
                            },
    "WPFInstallblender":  {
                              "category":  "Herramientas Multimedia",
                              "choco":  "blender",
                              "content":  "Blender (3D Graphics)",
                              "description":  "Blender es una potente suite de creación 3D de código abierto que ofrece herramientas de modelado, escultura, animación y renderizado.",
                              "link":  "https://www.blender.org/",
                              "winget":  "BlenderFoundation.Blender",
                              "foss":  true
                          },
    "WPFInstallbrave":  {
                            "category":  "Navegadores",
                            "choco":  "brave",
                            "content":  "Brave",
                            "description":  "Brave es un navegador web centrado en la privacidad que bloquea anuncios y rastreadores, ofreciendo una experiencia más rápida y segura.",
                            "link":  "https://www.brave.com",
                            "winget":  "Brave.Brave",
                            "foss":  true
                        },
    "WPFInstallbulkcrapuninstaller":  {
                                          "category":  "Utilidades",
                                          "choco":  "bulk-crap-uninstaller",
                                          "content":  "Bulk Crap Uninstaller",
                                          "description":  "Bulk Crap Uninstaller es un desinstalador de código abierto para Windows. Permite eliminar múltiples aplicaciones de una sola vez.",
                                          "link":  "https://www.bcuninstaller.com/",
                                          "winget":  "Klocman.BulkCrapUninstaller",
                                          "foss":  true
                                      },
    "WPFInstallblurautoclicker":  {
                                      "category":  "Utilidades",
                                      "choco":  "na",
                                      "content":  "BlurAutoClicker",
                                      "description":  "Un Auto-clicker con funciones avanzadas y, en general, mejor rendimiento que las alternativas populares.",
                                      "link":  "https://blur009.vercel.app/projects/blur-autoclicker/",
                                      "winget":  "Blur009.BlurAutoClicker",
                                      "foss":  true
                                  },
    "WPFInstallcalibre":  {
                              "category":  "Herramientas Multimedia",
                              "choco":  "calibre",
                              "content":  "Calibre",
                              "description":  "Calibre es un potente gestor, visor y conversor de libros electrónicos (e-books) muy fácil de usar.",
                              "link":  "https://calibre-ebook.com/",
                              "winget":  "calibre.calibre",
                              "foss":  true
                          },
    "WPFInstallcemu":  {
                           "category":  "Juegos",
                           "choco":  "cemu",
                           "content":  "Cemu",
                           "description":  "Cemu es un software altamente experimental para emular aplicaciones de Wii U en PC.",
                           "link":  "https://cemu.info/",
                           "winget":  "Cemu.Cemu",
                           "foss":  true
                       },
    "WPFInstallchatterino":  {
                                 "category":  "Comunicaciones",
                                 "choco":  "chatterino",
                                 "content":  "Chatterino",
                                 "description":  "Chatterino es un cliente de chat para Twitch que ofrece una interfaz limpia y personalizable.",
                                 "link":  "https://www.chatterino.com/",
                                 "winget":  "ChatterinoTeam.Chatterino",
                                 "foss":  true
                             },
    "WPFInstallchrome":  {
                             "category":  "Navegadores",
                             "choco":  "googlechrome",
                             "content":  "Chrome",
                             "description":  "Google Chrome es un navegador web muy popular conocido por su velocidad, simplicidad e integración con los servicios de Google.",
                             "link":  "https://www.google.com/chrome/",
                             "winget":  "Google.Chrome",
                             "foss":  false
                         },
    "WPFInstallchromium":  {
                               "category":  "Navegadores",
                               "choco":  "chromium",
                               "content":  "Chromium",
                               "description":  "Chromium es el proyecto de código abierto que sirve como base para varios navegadores web, incluido Chrome.",
                               "link":  "https://github.com/Hibbiki/chromium-win64",
                               "winget":  "Hibbiki.Chromium",
                               "foss":  true
                           },
    "WPFInstallcmake":  {
                            "category":  "Desarrollo",
                            "choco":  "cmake",
                            "content":  "CMake",
                            "description":  "CMake es una familia de herramientas multiplataforma de código abierto diseñada para construir, probar y empaquetar software.",
                            "link":  "https://cmake.org/",
                            "winget":  "Kitware.CMake",
                            "foss":  true
                        },
    "WPFInstallcpuz":  {
                           "category":  "Herramientas Profesionales",
                           "choco":  "cpu-z",
                           "content":  "CPU-Z",
                           "description":  "CPU-Z es una herramienta de diagnóstico para Windows. Proporciona información detallada sobre el hardware (CPU, memoria, placa base).",
                           "link":  "https://www.cpuid.com/softwares/cpu-z.html",
                           "winget":  "CPUID.CPU-Z",
                           "foss":  false
                       },
    "WPFInstallcrystaldiskinfo":  {
                                      "category":  "Utilidades",
                                      "choco":  "crystaldiskinfo",
                                      "content":  "Crystal Disk Info",
                                      "description":  "Crystal Disk Info es una herramienta de monitoreo del estado de los discos. Ayuda a anticipar posibles fallos en el disco duro.",
                                      "link":  "https://crystalmark.info/en/software/crystaldiskinfo/",
                                      "winget":  "CrystalDewWorld.CrystalDiskInfo",
                                      "foss":  true
                                  },
    "WPFInstallcrystaldiskmark":  {
                                      "category":  "Utilidades",
                                      "choco":  "crystaldiskmark",
                                      "content":  "Crystal Disk Mark",
                                      "description":  "Crystal Disk Mark es una herramienta de evaluación comparativa que mide las velocidades de lectura y escritura de unidades de almacenamiento.",
                                      "link":  "https://crystalmark.info/en/software/crystaldiskmark/",
                                      "winget":  "CrystalDewWorld.CrystalDiskMark",
                                      "foss":  true
                                  },
    "WPFInstallcursor":  {
                             "category":  "Desarrollo",
                             "choco":  "cursoride",
                             "content":  "Cursor",
                             "description":  "Editor de código impulsado por IA (basado en VS Code) con características de codificación de agentes y asistencia de IA integrada.",
                             "link":  "https://cursor.com/",
                             "winget":  "Anysphere.Cursor",
                             "foss":  false
                         },
    "WPFInstallantigravityide":  {
                                     "category":  "Desarrollo",
                                     "choco":  "na",
                                     "content":  "Antigravity IDE",
                                     "description":  "Potente entorno de desarrollo y asistencia impulsado por los agentes de inteligencia artificial de Google DeepMind.",
                                     "link":  "https://deepmind.google/",
                                     "winget":  "Google.Antigravity",
                                     "foss":  false
                                 },
    "WPFInstallantigravity2":  {
                                   "category":  "Desarrollo",
                                   "choco":  "na",
                                   "content":  "Antigravity 2.0",
                                   "description":  "La próxima generación del entorno de desarrollo impulsado por inteligencia artificial.",
                                   "link":  "https://deepmind.google/",
                                   "winget":  "Google.Antigravity",
                                   "foss":  false
                               },
    "WPFInstallcloudflare":  {
                                 "category":  "Desarrollo",
                                 "choco":  "na",
                                 "content":  "Cloudflared",
                                 "description":  "Herramienta de desarrollo de Cloudflare para crear túneles seguros (Zero Trust) y exponer aplicaciones locales a internet sin abrir puertos.",
                                 "link":  "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/",
                                 "winget":  "Cloudflare.cloudflared",
                                 "foss":  true
                             },
    "WPFInstallddu":  {
                          "category":  "Herramientas Profesionales",
                          "choco":  "ddu",
                          "content":  "Display Driver Uninstaller",
                          "description":  "Display Driver Uninstaller (DDU) desinstala completamente los controladores gráficos de NVIDIA, AMD e Intel. Útil para solucionar problemas gráficos.",
                          "link":  "https://www.wagnardsoft.com/display-driver-uninstaller-DDU-",
                          "winget":  "Wagnardsoft.DisplayDriverUninstaller",
                          "foss":  true
                      },
    "WPFInstalldiscord":  {
                              "category":  "Comunicaciones",
                              "choco":  "discord",
                              "content":  "Discord",
                              "description":  "Discord es una plataforma de comunicación con chat de voz, video y texto, diseñada para jugadores pero utilizada por muchas comunidades.",
                              "link":  "https://discord.com/",
                              "winget":  "Discord.Discord",
                              "foss":  false
                          },
    "WPFInstallwhatsapp":  {
                               "category":  "Comunicaciones",
                               "choco":  "whatsapp",
                               "content":  "WhatsApp",
                               "description":  "WhatsApp Messenger de Meta es una aplicación de mensajería GRATUITA y videollamadas. Es utilizada por más de 2 mil millones de personas.",
                               "link":  "https://www.whatsapp.com/",
                               "winget":  "9NKSQGP7F2NH",
                               "foss":  false
                           },
    "WPFInstallwhatsappbeta":  {
                                   "category":  "Comunicaciones",
                                   "choco":  "na",
                                   "content":  "WhatsApp Beta",
                                   "description":  "WhatsApp Beta ofrece acceso anticipado a nuevas funciones de WhatsApp antes de que se lancen al público.",
                                   "link":  "https://www.whatsapp.com/",
                                   "winget":  "9NBDXK71NK08",
                                   "foss":  false
                               },
    "WPFInstalldismtools":  {
                                "category":  "Herramientas de Microsoft",
                                "choco":  "dismtools",
                                "content":  "DISMTools",
                                "description":  "DISMTools es una interfaz gráfica rápida para la utilidad DISM. Permite modificar imágenes de Windows de forma visual y accesible.",
                                "link":  "https://github.com/CodingWonders/DISMTools",
                                "winget":  "CodingWondersSoftware.DISMTools.Stable",
                                "foss":  true
                            },
    "WPFInstallntlite":  {
                             "category":  "Herramientas de Microsoft",
                             "choco":  "ntlite-free",
                             "content":  "NTLite",
                             "description":  "Integra actualizaciones, controladores y automatiza la configuración de Windows. Acelera el proceso de despliegue del sistema.",
                             "link":  "https://ntlite.com",
                             "winget":  "Nlitesoft.NTLite",
                             "foss":  false
                         },
    "WPFInstalldorion":  {
                             "category":  "Comunicaciones",
                             "choco":  "dorion",
                             "content":  "Dorion",
                             "description":  "Pequeño cliente alternativo de Discord que ocupa menos, arranca más rápido, con temas, plugins y más.",
                             "link":  "https://github.com/SpikeHD/Dorion",
                             "winget":  "SpikeHD.Dorion",
                             "foss":  true
                         },
    "WPFInstalldotnet6":  {
                              "category":  "Herramientas de Microsoft",
                              "choco":  "dotnet-6.0-runtime",
                              "content":  ".NET Desktop Runtime 6",
                              "description":  ".NET Desktop Runtime 6 es un entorno de ejecución necesario para ejecutar aplicaciones desarrolladas con .NET 6.",
                              "link":  "https://dotnet.microsoft.com/download/dotnet/6.0",
                              "winget":  "Microsoft.DotNet.DesktopRuntime.6",
                              "foss":  true
                          },
    "WPFInstalldotnet8":  {
                              "category":  "Herramientas de Microsoft",
                              "choco":  "dotnet-8.0-runtime",
                              "content":  ".NET Desktop Runtime 8",
                              "description":  ".NET Desktop Runtime 8 es un entorno de ejecución necesario para ejecutar aplicaciones desarrolladas con .NET 8.",
                              "link":  "https://dotnet.microsoft.com/download/dotnet/8.0",
                              "winget":  "Microsoft.DotNet.DesktopRuntime.8",
                              "foss":  true
                          },
    "WPFInstalldotnet9":  {
                              "category":  "Herramientas de Microsoft",
                              "choco":  "dotnet-9.0-runtime",
                              "content":  ".NET Desktop Runtime 9",
                              "description":  ".NET Desktop Runtime 9 es un entorno de ejecución necesario para ejecutar aplicaciones desarrolladas con .NET 9.",
                              "link":  "https://dotnet.microsoft.com/download/dotnet/9.0",
                              "winget":  "Microsoft.DotNet.DesktopRuntime.9",
                              "foss":  true
                          },
    "WPFInstalldotnet10":  {
                               "category":  "Herramientas de Microsoft",
                               "choco":  "dotnet-10.0-runtime",
                               "content":  ".NET Desktop Runtime 10",
                               "description":  ".NET Desktop Runtime 10 es un entorno de ejecución necesario para ejecutar aplicaciones desarrolladas con .NET 10.",
                               "link":  "https://dotnet.microsoft.com/download/dotnet/10.0",
                               "winget":  "Microsoft.DotNet.DesktopRuntime.10",
                               "foss":  true
                           },
    "WPFInstalleaapp":  {
                            "category":  "Juegos",
                            "choco":  "ea-app",
                            "content":  "EA App",
                            "description":  "EA App es una plataforma para acceder y jugar a los juegos de Electronic Arts.",
                            "link":  "https://www.ea.com/ea-app",
                            "winget":  "ElectronicArts.EADesktop",
                            "foss":  false
                        },
    "WPFInstalleartrumpet":  {
                                 "category":  "Herramientas Multimedia",
                                 "choco":  "eartrumpet",
                                 "content":  "EarTrumpet (Audio)",
                                 "description":  "EarTrumpet es una aplicación de control de audio para Windows que proporciona una interfaz sencilla e intuitiva para gestionar el sonido.",
                                 "link":  "https://eartrumpet.app/",
                                 "winget":  "File-New-Project.EarTrumpet",
                                 "foss":  true
                             },
    "WPFInstalledge":  {
                           "category":  "Navegadores",
                           "choco":  "microsoft-edge",
                           "content":  "Edge",
                           "description":  "Microsoft Edge es un navegador moderno basado en Chromium que ofrece rendimiento, seguridad e integración con servicios de Microsoft.",
                           "link":  "https://www.microsoft.com/edge",
                           "winget":  "Microsoft.Edge",
                           "foss":  false
                       },
    "WPFInstallenteauth":  {
                               "category":  "Utilidades",
                               "choco":  "ente-auth",
                               "content":  "Ente Auth",
                               "description":  "Ente Auth es una aplicación de autenticación gratuita, multiplataforma y cifrada de extremo a extremo.",
                               "link":  "https://ente.io/auth/",
                               "winget":  "ente-io.auth-desktop",
                               "foss":  true
                           },
    "WPFInstallepicgames":  {
                                "category":  "Juegos",
                                "choco":  "epicgameslauncher",
                                "content":  "Epic Games Launcher",
                                "description":  "Epic Games Launcher es el cliente para acceder y jugar a juegos de la Epic Games Store.",
                                "link":  "https://www.epicgames.com/store/en-US/",
                                "winget":  "EpicGames.EpicGamesLauncher",
                                "foss":  false
                            },
    "WPFInstallfiles":  {
                            "category":  "Utilidades",
                            "choco":  "files",
                            "content":  "Files",
                            "description":  "Explorador de archivos alternativo.",
                            "link":  "https://github.com/files-community/Files",
                            "winget":  "FilesCommunity.Files",
                            "foss":  true
                        },
    "WPFInstallfirefox":  {
                              "category":  "Navegadores",
                              "choco":  "firefox",
                              "content":  "Firefox",
                              "description":  "Mozilla Firefox es un navegador web de código abierto conocido por sus opciones de personalización, privacidad y extensiones.",
                              "link":  "https://www.mozilla.org/en-US/firefox/new/",
                              "winget":  "Mozilla.Firefox",
                              "foss":  true
                          },
    "WPFInstallfirefoxesr":  {
                                 "category":  "Navegadores",
                                 "choco":  "FirefoxESR",
                                 "content":  "Firefox ESR",
                                 "description":  "Firefox ESR (Extended Support Release) recibe actualizaciones principales cada 42 semanas y actualizaciones menores (seguridad, fallos) mínimo cada cuatro semanas.",
                                 "link":  "https://www.mozilla.org/en-US/firefox/enterprise/",
                                 "winget":  "Mozilla.Firefox.ESR",
                                 "foss":  true
                             },
    "WPFInstallfloorp":  {
                             "category":  "Navegadores",
                             "choco":  "floorp",
                             "content":  "Floorp",
                             "description":  "Floorp es un proyecto de navegador web de código abierto cuyo objetivo es ofrecer una experiencia de navegación sencilla y rápida.",
                             "link":  "https://floorp.app/",
                             "winget":  "Ablaze.Floorp",
                             "foss":  true
                         },
    "WPFInstallflux":  {
                           "category":  "Utilidades",
                           "choco":  "flux",
                           "content":  "F.lux",
                           "description":  "f.lux ajusta la temperatura de color de tu pantalla para reducir la fatiga visual durante el uso nocturno.",
                           "link":  "https://justgetflux.com/",
                           "winget":  "flux.flux",
                           "foss":  false
                       },
    "WPFInstallgeforcenow":  {
                                 "category":  "Juegos",
                                 "choco":  "nvidia-geforce-now",
                                 "content":  "GeForce NOW",
                                 "description":  "GeForce NOW es un servicio de juegos en la nube que te permite jugar a juegos de PC de alta calidad en tu dispositivo.",
                                 "link":  "https://www.nvidia.com/en-us/geforce-now/",
                                 "winget":  "Nvidia.GeForceNow",
                                 "foss":  false
                             },
    "WPFInstallgimp":  {
                           "category":  "Herramientas Multimedia",
                           "choco":  "gimp",
                           "content":  "GIMP (Image Editor)",
                           "description":  "GIMP es un versátil editor de gráficos de código abierto utilizado para retoque fotográfico, edición de imágenes y composición.",
                           "link":  "https://www.gimp.org/",
                           "winget":  "GIMP.GIMP.3",
                           "foss":  true
                       },
    "WPFInstallgit":  {
                          "category":  "Desarrollo",
                          "choco":  "git",
                          "content":  "Git",
                          "description":  "Git es un sistema de control de versiones distribuido muy utilizado para rastrear cambios en el código fuente durante el desarrollo.",
                          "link":  "https://git-scm.com/",
                          "winget":  "Git.Git",
                          "foss":  true
                      },
    "WPFInstallgithubdesktop":  {
                                    "category":  "Desarrollo",
                                    "choco":  "git;github-desktop",
                                    "content":  "GitHub Desktop",
                                    "description":  "GitHub Desktop es un cliente visual de Git que simplifica la colaboración en repositorios de GitHub con una interfaz fácil de usar.",
                                    "link":  "https://desktop.github.com/",
                                    "winget":  "GitHub.GitHubDesktop",
                                    "foss":  true
                                },
    "WPFInstallgog":  {
                          "category":  "Juegos",
                          "choco":  "goggalaxy",
                          "content":  "GOG Galaxy",
                          "description":  "GOG Galaxy es un cliente de juegos que ofrece juegos sin DRM, contenido adicional y más.",
                          "link":  "https://www.gog.com/galaxy",
                          "winget":  "GOG.Galaxy",
                          "foss":  false
                      },
    "WPFInstallgolang":  {
                             "category":  "Desarrollo",
                             "choco":  "golang",
                             "content":  "Go",
                             "description":  "Go (o Golang) es un lenguaje de programación compilado de tipado estático diseñado para la simplicidad, fiabilidad y eficiencia.",
                             "link":  "https://go.dev/",
                             "winget":  "GoLang.Go",
                             "foss":  true
                         },
    "WPFInstallgoogledrive":  {
                                  "category":  "Utilidades",
                                  "choco":  "googledrive",
                                  "content":  "Google Drive",
                                  "description":  "Sincronización de archivos en todos los dispositivos, vinculado a tu cuenta de Google.",
                                  "link":  "https://www.google.com/drive/",
                                  "winget":  "Google.GoogleDrive",
                                  "foss":  false
                              },
    "WPFInstallgpuz":  {
                           "category":  "Herramientas Profesionales",
                           "choco":  "gpu-z",
                           "content":  "GPU-Z",
                           "description":  "GPU-Z proporciona información detallada sobre tu tarjeta gráfica y GPU.",
                           "link":  "https://www.techpowerup.com/gpuz/",
                           "winget":  "TechPowerUp.GPU-Z",
                           "foss":  false
                       },
    "WPFInstallhelium":  {
                             "category":  "Navegadores",
                             "choco":  "helium",
                             "content":  "Helium",
                             "description":  "Navegador web privado, rápido y honesto.",
                             "link":  "https://github.com/imputnet/helium/",
                             "winget":  "ImputNet.Helium",
                             "foss":  true
                         },
    "WPFInstallhugo":  {
                           "category":  "Utilidades",
                           "choco":  "hugo-extended",
                           "content":  "Hugo",
                           "description":  "El framework más rápido del mundo para crear sitios web.",
                           "link":  "https://github.com/gohugoio/hugo/",
                           "winget":  "Hugo.Hugo.Extended",
                           "foss":  true
                       },
    "WPFInstallhandbrake":  {
                                "category":  "Herramientas Multimedia",
                                "choco":  "handbrake",
                                "content":  "HandBrake",
                                "description":  "HandBrake es un transcodificador de video de código abierto que permite convertir videos a una selección de códecs ampliamente compatibles.",
                                "link":  "https://handbrake.fr/",
                                "winget":  "HandBrake.HandBrake",
                                "foss":  true
                            },
    "WPFInstallheroiclauncher":  {
                                     "category":  "Juegos",
                                     "choco":  "na",
                                     "content":  "Heroic Games Launcher",
                                     "description":  "Heroic Games Launcher es un lanzador de juegos alternativo y de código abierto para la Epic Games Store.",
                                     "link":  "https://heroicgameslauncher.com/",
                                     "winget":  "HeroicGamesLauncher.HeroicGamesLauncher",
                                     "foss":  true
                                 },
    "WPFInstallhwinfo":  {
                             "category":  "Herramientas Profesionales",
                             "choco":  "hwinfo",
                             "content":  "HWiNFO",
                             "description":  "HWiNFO proporciona información completa y diagnósticos de hardware para Windows.",
                             "link":  "https://www.hwinfo.com/",
                             "winget":  "REALiX.HWiNFO",
                             "foss":  false
                         },
    "WPFInstallhwmonitor":  {
                                "category":  "Herramientas Profesionales",
                                "choco":  "hwmonitor",
                                "content":  "HWMonitor",
                                "description":  "HWMonitor es un programa de monitorización de hardware que lee los principales sensores de salud del sistema del PC.",
                                "link":  "https://www.cpuid.com/softwares/hwmonitor.html",
                                "winget":  "CPUID.HWMonitor",
                                "foss":  false
                            },
    "WPFInstallimageglass":  {
                                 "category":  "Herramientas Multimedia",
                                 "choco":  "imageglass",
                                 "content":  "ImageGlass (Image Viewer)",
                                 "description":  "ImageGlass es un visor de imágenes versátil con soporte para varios formatos y enfocado en la simplicidad y velocidad.",
                                 "link":  "https://imageglass.org/",
                                 "winget":  "DuongDieuPhap.ImageGlass",
                                 "foss":  true
                             },
    "WPFInstallirfanview":  {
                                "category":  "Herramientas Multimedia",
                                "choco":  "irfanview",
                                "content":  "IrfanView",
                                "description":  "IrfanView es un visor y editor de imágenes ligero, rápido y gratuito. Soporta múltiples formatos, procesamiento por lotes y potentes plugins.",
                                "link":  "https://irfanview.com/",
                                "winget":  "IrfanSkiljan.IrfanView"
                            },
    "WPFInstallitch":  {
                           "category":  "Juegos",
                           "choco":  "itch",
                           "content":  "Itch.io",
                           "description":  "Itch.io es una plataforma de distribución digital de juegos indie y proyectos creativos.",
                           "link":  "https://itch.io/",
                           "winget":  "ItchIo.Itch",
                           "foss":  true
                       },
    "WPFInstallitunes":  {
                             "category":  "Herramientas Multimedia",
                             "choco":  "itunes",
                             "content":  "iTunes",
                             "description":  "iTunes es un reproductor multimedia, biblioteca de medios y emisor de radio online desarrollado por Apple.",
                             "link":  "https://www.apple.com/itunes/",
                             "winget":  "Apple.iTunes",
                             "foss":  false
                         },
    "WPFInstalljava8":  {
                            "category":  "Desarrollo",
                            "choco":  "corretto8jdk",
                            "content":  "Amazon Corretto 8 (LTS)",
                            "description":  "Amazon Corretto es una distribución gratuita, multiplataforma y lista para producción del Open Java Development Kit (OpenJDK).",
                            "link":  "https://aws.amazon.com/corretto",
                            "winget":  "Amazon.Corretto.8.JDK",
                            "foss":  true
                        },
    "WPFInstalljava21":  {
                             "category":  "Desarrollo",
                             "choco":  "corretto21jdk",
                             "content":  "Amazon Corretto 21 (LTS)",
                             "description":  "Amazon Corretto es una distribución gratuita, multiplataforma y lista para producción del Open Java Development Kit (OpenJDK).",
                             "link":  "https://aws.amazon.com/corretto",
                             "winget":  "Amazon.Corretto.21.JDK",
                             "foss":  true
                         },
    "WPFInstalljava25":  {
                             "category":  "Desarrollo",
                             "choco":  "corretto25jdk",
                             "content":  "Amazon Corretto 25 (LTS)",
                             "description":  "Amazon Corretto es una distribución gratuita, multiplataforma y lista para producción del Open Java Development Kit (OpenJDK).",
                             "link":  "https://aws.amazon.com/corretto",
                             "winget":  "Amazon.Corretto.25.JDK",
                             "foss":  true
                         },
    "WPFInstalljellyfinmediaplayer":  {
                                          "category":  "Herramientas Selfhosted",
                                          "choco":  "jellyfin-media-player",
                                          "content":  "Jellyfin Media Player",
                                          "description":  "Jellyfin Media Player es una aplicación cliente para el servidor multimedia Jellyfin que da acceso a tu biblioteca de medios.",
                                          "link":  "https://github.com/jellyfin/jellyfin-media-player",
                                          "winget":  "Jellyfin.JellyfinMediaPlayer",
                                          "foss":  true
                                      },
    "WPFInstalljellyfinserver":  {
                                     "category":  "Herramientas Selfhosted",
                                     "choco":  "jellyfin",
                                     "content":  "Jellyfin Server",
                                     "description":  "Jellyfin Server es un software de servidor multimedia de código abierto para organizar y transmitir tu biblioteca de medios.",
                                     "link":  "https://jellyfin.org/",
                                     "winget":  "Jellyfin.Server",
                                     "foss":  true
                                 },
    "WPFInstalljetbrains":  {
                                "category":  "Desarrollo",
                                "choco":  "jetbrainstoolbox",
                                "content":  "Jetbrains Toolbox",
                                "description":  "JetBrains Toolbox es una plataforma para la fácil instalación y gestión de las herramientas de desarrollo de JetBrains.",
                                "link":  "https://www.jetbrains.com/toolbox/",
                                "winget":  "JetBrains.Toolbox",
                                "foss":  false
                            },
    "WPFInstalljpegview":  {
                               "category":  "Utilidades",
                               "choco":  "jpegview",
                               "content":  "JPEG View",
                               "description":  "JPEGView es un visor/editor rápido y altamente configurable para múltiples formatos de imagen con una interfaz mínima.",
                               "link":  "https://github.com/sylikc/jpegview",
                               "winget":  "sylikc.JPEGView",
                               "foss":  true
                           },
    "WPFInstallklite":  {
                            "category":  "Herramientas Multimedia",
                            "choco":  "k-litecodecpack-standard",
                            "content":  "K-Lite Codec Standard",
                            "description":  "K-Lite Codec Pack Standard es una colección de códecs de audio/video y herramientas relacionadas, proporcionando componentes esenciales para la reproducción de medios.",
                            "link":  "https://www.codecguide.com/",
                            "winget":  "CodecGuide.K-LiteCodecPack.Standard",
                            "foss":  false
                        },
    "WPFInstallkodi":  {
                           "category":  "Herramientas Selfhosted",
                           "choco":  "kodi",
                           "content":  "Kodi Media Center",
                           "description":  "Kodi es una aplicación de centro multimedia de código abierto que permite reproducir y ver la mayoría de los videos, música, podcasts y otros archivos digitales.",
                           "link":  "https://kodi.tv/",
                           "winget":  "XBMCFoundation.Kodi",
                           "foss":  true
                       },
    "WPFInstalllazygit":  {
                              "category":  "Desarrollo",
                              "choco":  "lazygit",
                              "content":  "Lazygit",
                              "description":  "Interfaz de terminal sencilla para comandos de git.",
                              "link":  "https://github.com/jesseduffield/lazygit/",
                              "winget":  "JesseDuffield.lazygit",
                              "foss":  true
                          },
    "WPFInstalllibreoffice":  {
                                  "category":  "Herramientas Multimedia",
                                  "choco":  "libreoffice-fresh",
                                  "content":  "LibreOffice",
                                  "description":  "LibreOffice es una potente y gratuita suite ofimática, compatible con otras suites importantes.",
                                  "link":  "https://www.libreoffice.org/",
                                  "winget":  "TheDocumentFoundation.LibreOffice",
                                  "foss":  true
                              },
    "WPFInstalllibrewolf":  {
                                "category":  "Navegadores",
                                "choco":  "librewolf",
                                "content":  "LibreWolf",
                                "description":  "LibreWolf es un navegador web centrado en la privacidad basado en Firefox, con mejoras adicionales de privacidad y seguridad.",
                                "link":  "https://librewolf-community.gitlab.io/",
                                "winget":  "LibreWolf.LibreWolf",
                                "foss":  true
                            },
    "WPFInstalllocalsend":  {
                                "category":  "Herramientas Selfhosted",
                                "choco":  "localsend.install",
                                "content":  "LocalSend",
                                "description":  "Una alternativa multiplataforma y de código abierto a AirDrop.",
                                "link":  "https://localsend.org/",
                                "winget":  "LocalSend.LocalSend",
                                "foss":  true
                            },
    "WPFInstallmpc-qt":  {
                             "category":  "Herramientas Multimedia",
                             "choco":  "mediainfo",
                             "content":  "mpc-qt",
                             "description":  "Media Player Classic Qute Theater",
                             "link":  "https://github.com/mpc-qt/mpc-qt",
                             "winget":  "mpc-qt.mpc-qt",
                             "foss":  true
                         },
    "WPFInstallmatrix":  {
                             "category":  "Comunicaciones",
                             "choco":  "element-desktop",
                             "content":  "Element",
                             "description":  "Element es un cliente para Matrix; una red abierta para una comunicación segura y descentralizada.",
                             "link":  "https://element.io/",
                             "winget":  "Element.Element",
                             "foss":  true
                         },
    "WPFInstallmodrinth":  {
                               "category":  "Juegos",
                               "choco":  "na",
                               "content":  "Modrinth App",
                               "description":  "Modrinth App es una aplicación de escritorio para gestionar mods y modpacks de Minecraft.",
                               "link":  "https://modrinth.com/app",
                               "winget":  "Modrinth.ModrinthApp",
                               "foss":  true
                           },
    "WPFInstallmoonlight":  {
                                "category":  "Herramientas Selfhosted",
                                "choco":  "moonlight-qt",
                                "content":  "Moonlight/GameStream Client",
                                "description":  "Moonlight/GameStream Client te permite transmitir juegos de PC a otros dispositivos en tu red local.",
                                "link":  "https://moonlight-stream.org/",
                                "winget":  "MoonlightGameStreamingProject.Moonlight",
                                "foss":  true
                            },
    "WPFInstallmpchc":  {
                            "category":  "Herramientas Multimedia",
                            "choco":  "mpc-hc-clsid2",
                            "content":  "Media Player Classic - Home Cinema",
                            "description":  "Media Player Classic - Home Cinema (MPC-HC) es un reproductor de audio y video gratuito y de código abierto para Windows. Contiene muchas características adicionales y corrección de errores.",
                            "link":  "https://github.com/clsid2/mpc-hc/",
                            "winget":  "clsid2.mpc-hc",
                            "foss":  true
                        },
    "WPFInstallmsedgeredirect":  {
                                     "category":  "Utilidades",
                                     "choco":  "msedgeredirect",
                                     "content":  "MSEdgeRedirect",
                                     "description":  "Una herramienta para redirigir Noticias, Búsquedas, Widgets, Tiempo y más a tu navegador predeterminado.",
                                     "link":  "https://github.com/rcmaehl/MSEdgeRedirect",
                                     "winget":  "rcmaehl.MSEdgeRedirect",
                                     "foss":  true
                                 },
    "WPFInstallmsiafterburner":  {
                                     "category":  "Utilidades",
                                     "choco":  "msiafterburner",
                                     "content":  "MSI Afterburner",
                                     "description":  "MSI Afterburner es una utilidad de overclocking para tarjetas gráficas con funciones avanzadas.",
                                     "link":  "https://www.msi.com/Landing/afterburner",
                                     "winget":  "Guru3D.Afterburner",
                                     "foss":  false
                                 },
    "WPFInstallmullvadvpn":  {
                                 "category":  "Herramientas Profesionales",
                                 "choco":  "mullvad-app",
                                 "content":  "Mullvad VPN",
                                 "description":  "Este es el software de cliente VPN para el servicio Mullvad VPN.",
                                 "link":  "https://github.com/mullvad/mullvadvpn-app",
                                 "winget":  "MullvadVPN.MullvadVPN",
                                 "foss":  true
                             },
    "WPFInstallmullvadbrowser":  {
                                     "category":  "Navegadores",
                                     "choco":  "na",
                                     "content":  "Mullvad Browser",
                                     "description":  "Mullvad Browser es un navegador web centrado en la privacidad, desarrollado en asociación con Tor Project.",
                                     "link":  "https://mullvad.net/browser",
                                     "winget":  "MullvadVPN.MullvadBrowser",
                                     "foss":  true
                                 },
    "WPFInstallnanazip":  {
                              "category":  "Utilidades",
                              "choco":  "nanazip",
                              "content":  "NanaZip",
                              "description":  "NanaZip es una herramienta rápida y eficiente de compresión y descompresión de archivos.",
                              "link":  "https://github.com/M2Team/NanaZip",
                              "winget":  "M2Team.NanaZip",
                              "foss":  true
                          },
    "WPFInstallnetbird":  {
                              "category":  "Herramientas Selfhosted",
                              "choco":  "netbird",
                              "content":  "NetBird",
                              "description":  "NetBird es una alternativa de código abierto comparable a TailScale que se puede conectar a un servidor alojado por ti mismo.",
                              "link":  "https://netbird.io/",
                              "winget":  "Netbird.Netbird",
                              "foss":  true
                          },
    "WPFInstallnaps2":  {
                            "category":  "Herramientas Multimedia",
                            "choco":  "naps2",
                            "content":  "NAPS2 (Document Scanner)",
                            "description":  "NAPS2 es una aplicación de escaneo de documentos que simplifica la creación de documentos electrónicos.",
                            "link":  "https://www.naps2.com/",
                            "winget":  "Cyanfish.NAPS2",
                            "foss":  true
                        },
    "WPFInstallneovim":  {
                             "category":  "Desarrollo",
                             "choco":  "neovim",
                             "content":  "Neovim",
                             "description":  "Neovim es un editor de texto altamente extensible y una mejora sobre el editor original Vim.",
                             "link":  "https://neovim.io/",
                             "winget":  "Neovim.Neovim",
                             "foss":  true
                         },
    "WPFInstallnextclouddesktop":  {
                                       "category":  "Herramientas Selfhosted",
                                       "choco":  "nextcloud-client",
                                       "content":  "Nextcloud Desktop",
                                       "description":  "Nextcloud Desktop es el cliente de escritorio oficial para la plataforma de sincronización y uso compartido de archivos Nextcloud.",
                                       "link":  "https://nextcloud.com/install/#install-clients",
                                       "winget":  "Nextcloud.NextcloudDesktop",
                                       "foss":  true
                                   },
    "WPFInstallnmap":  {
                           "category":  "Herramientas Profesionales",
                           "choco":  "nmap",
                           "content":  "Nmap",
                           "description":  "Nmap (Network Mapper) es una herramienta de código abierto para la exploración de redes y auditoría de seguridad. Descubre dispositivos e informa sobre sus puertos y servicios.",
                           "link":  "https://nmap.org/",
                           "winget":  "Insecure.Nmap",
                           "foss":  true
                       },
    "WPFInstallnodejs":  {
                             "category":  "Desarrollo",
                             "choco":  "nodejs",
                             "content":  "NodeJS",
                             "description":  "Node.js es un entorno de ejecución de JavaScript construido sobre el motor V8 de Chrome para construir aplicaciones de red y de servidor.",
                             "link":  "https://nodejs.org/",
                             "winget":  "OpenJS.NodeJS",
                             "foss":  true
                         },
    "WPFInstallnodejslts":  {
                                "category":  "Desarrollo",
                                "choco":  "nodejs-lts",
                                "content":  "NodeJS LTS",
                                "description":  "Node.js LTS proporciona versiones de soporte a largo plazo para un desarrollo de JavaScript del lado del servidor estable y confiable.",
                                "link":  "https://nodejs.org/",
                                "winget":  "OpenJS.NodeJS.LTS",
                                "foss":  true
                            },
    "WPFInstallnotepadplus":  {
                                  "category":  "Herramientas Multimedia",
                                  "choco":  "notepadplusplus",
                                  "content":  "Notepad++",
                                  "description":  "Notepad++ es un editor de código gratuito y de código abierto, un reemplazo del bloc de notas con soporte para múltiples lenguajes.",
                                  "link":  "https://notepad-plus-plus.org/",
                                  "winget":  "Notepad++.Notepad++",
                                  "foss":  true
                              },
    "WPFInstallnuget":  {
                            "category":  "Herramientas de Microsoft",
                            "choco":  "nuget.commandline",
                            "content":  "NuGet",
                            "description":  "NuGet es un administrador de paquetes para el marco .NET que permite a los desarrolladores administrar y compartir bibliotecas en sus aplicaciones.",
                            "link":  "https://www.nuget.org/",
                            "winget":  "Microsoft.NuGet",
                            "foss":  true
                        },
    "WPFInstallnvclean":  {
                              "category":  "Utilidades",
                              "choco":  "na",
                              "content":  "NVCleanstall",
                              "description":  "NVCleanstall es una herramienta diseñada para personalizar las instalaciones de controladores NVIDIA, permitiendo a usuarios avanzados controlar más aspectos.",
                              "link":  "https://www.techpowerup.com/nvcleanstall/",
                              "winget":  "TechPowerUp.NVCleanstall",
                              "foss":  false
                          },
    "WPFInstallobs":  {
                          "category":  "Herramientas Multimedia",
                          "choco":  "obs-studio",
                          "content":  "OBS Studio",
                          "description":  "OBS Studio es un software gratuito y de código abierto para grabación de video y transmisión en vivo. Soporta captura y mezcla de audio y video en tiempo real.",
                          "link":  "https://obsproject.com/",
                          "winget":  "OBSProject.OBSStudio",
                          "foss":  true
                      },
    "WPFInstallobsidian":  {
                               "category":  "Herramientas Multimedia",
                               "choco":  "obsidian",
                               "content":  "Obsidian",
                               "description":  "Obsidian es una potente aplicación para tomar notas y gestionar el conocimiento.",
                               "link":  "https://obsidian.md/",
                               "winget":  "Obsidian.Obsidian",
                               "foss":  false
                           },
    "WPFInstallonedrive":  {
                               "category":  "Herramientas de Microsoft",
                               "choco":  "onedrive",
                               "content":  "OneDrive",
                               "description":  "OneDrive es un servicio de almacenamiento en la nube proporcionado por Microsoft que permite almacenar y compartir archivos de forma segura.",
                               "link":  "https://onedrive.live.com/",
                               "winget":  "Microsoft.OneDrive",
                               "foss":  false
                           },
    "WPFInstallonlyoffice":  {
                                 "category":  "Herramientas Multimedia",
                                 "choco":  "onlyoffice",
                                 "content":  "ONLYOffice Desktop",
                                 "description":  "ONLYOffice Desktop es una suite ofimática completa para la edición de documentos y colaboración.",
                                 "link":  "https://www.onlyoffice.com/desktop.aspx",
                                 "winget":  "ONLYOFFICE.DesktopEditors",
                                 "foss":  true
                             },
    "WPFInstallOPAutoClicker":  {
                                    "category":  "Utilidades",
                                    "choco":  "autoclicker",
                                    "content":  "OPAutoClicker",
                                    "description":  "Un autoclicker completo con dos modos de auto-clic: en la ubicación dinámica de tu cursor o en una ubicación preestablecida.",
                                    "link":  "https://www.opautoclicker.com",
                                    "winget":  "OPAutoClicker.OPAutoClicker",
                                    "foss":  false
                                },
    "WPFInstallopenrgb":  {
                              "category":  "Utilidades",
                              "choco":  "openrgb",
                              "content":  "OpenRGB",
                              "description":  "OpenRGB es un software de control de iluminación RGB de código abierto para gestionar la luz RGB de varios componentes y periféricos.",
                              "link":  "https://openrgb.org/",
                              "winget":  "OpenRGB.OpenRGB",
                              "foss":  true
                          },
    "WPFInstallOpenVPN":  {
                              "category":  "Herramientas Profesionales",
                              "choco":  "openvpn-connect",
                              "content":  "OpenVPN Connect",
                              "description":  "OpenVPN Connect es un cliente VPN de código abierto que permite conectarse de forma segura a un servidor VPN. Protege la privacidad en línea.",
                              "link":  "https://openvpn.net/",
                              "winget":  "OpenVPNTechnologies.OpenVPNConnect",
                              "foss":  true
                          },
    "WPFInstallOVirtualBox":  {
                                  "category":  "Utilidades",
                                  "choco":  "virtualbox",
                                  "content":  "Oracle VirtualBox",
                                  "description":  "Oracle VirtualBox es una potente herramienta de virtualización gratuita y de código abierto para arquitecturas x86 y AMD64/Intel64.",
                                  "link":  "https://www.virtualbox.org/",
                                  "winget":  "Oracle.VirtualBox",
                                  "foss":  true
                              },
    "WPFInstallpolicyplus":  {
                                 "category":  "Utilidades",
                                 "choco":  "na",
                                 "content":  "Policy Plus",
                                 "description":  "Editor de directivas de grupo local y más, para todas las ediciones de Windows.",
                                 "link":  "https://github.com/Fleex255/PolicyPlus",
                                 "winget":  "Fleex255.PolicyPlus",
                                 "foss":  true
                             },
    "WPFInstallprocessexplorer":  {
                                      "category":  "Herramientas de Microsoft",
                                      "choco":  "na",
                                      "content":  "Process Explorer",
                                      "description":  "Process Explorer es un administrador de tareas y monitor de sistema.",
                                      "link":  "https://learn.microsoft.com/sysinternals/downloads/process-explorer",
                                      "winget":  "Microsoft.Sysinternals.ProcessExplorer",
                                      "foss":  false
                                  },
    "WPFInstallPaintdotnet":  {
                                  "category":  "Herramientas Multimedia",
                                  "choco":  "paint.net",
                                  "content":  "Paint.NET",
                                  "description":  "Paint.NET es un software gratuito de edición de imágenes y fotografías para Windows. Ofrece una interfaz intuitiva y potentes herramientas de edición.",
                                  "link":  "https://www.getpaint.net/",
                                  "winget":  "dotPDN.PaintDotNet",
                                  "foss":  false
                              },
    "WPFInstallparsec":  {
                             "category":  "Utilidades",
                             "choco":  "parsec",
                             "content":  "Parsec",
                             "description":  "Parsec es una aplicación de escritorio remoto compartida de alta calidad y baja latencia para colaborar y jugar.",
                             "link":  "https://parsec.app/",
                             "winget":  "Parsec.Parsec",
                             "foss":  false
                         },
    "WPFInstallpeazip":  {
                             "category":  "Utilidades",
                             "choco":  "peazip",
                             "content":  "PeaZip",
                             "description":  "PeaZip es un administrador de archivos gratuito y de código abierto que admite múltiples formatos de archivo y proporciona funciones de cifrado.",
                             "link":  "https://peazip.github.io/",
                             "winget":  "Giorgiotani.Peazip",
                             "foss":  true
                         },
    "WPFInstallplex":  {
                           "category":  "Herramientas Selfhosted",
                           "choco":  "plexmediaserver",
                           "content":  "Plex Media Server",
                           "description":  "Plex Media Server permite organizar y transmitir tu biblioteca multimedia. Soporta varios formatos y ofrece una amplia gama de funciones.",
                           "link":  "https://www.plex.tv/your-media/",
                           "winget":  "Plex.PlexMediaServer",
                           "foss":  false
                       },
    "WPFInstallplexdesktop":  {
                                  "category":  "Herramientas Selfhosted",
                                  "choco":  "plex",
                                  "content":  "Plex Desktop",
                                  "description":  "Plex Desktop para Windows es la interfaz principal para Plex Media Server.",
                                  "link":  "https://www.plex.tv",
                                  "winget":  "Plex.Plex",
                                  "foss":  false
                              },
    "WPFInstallposh":  {
                           "category":  "Desarrollo",
                           "choco":  "oh-my-posh",
                           "content":  "Oh My Posh (Prompt)",
                           "description":  "Oh My Posh es un motor de temas de la línea de comandos multiplataforma para cualquier terminal.",
                           "link":  "https://ohmyposh.dev/",
                           "winget":  "JanDeDobbeleer.OhMyPosh",
                           "foss":  true
                       },
    "WPFInstallpowershell":  {
                                 "category":  "Herramientas de Microsoft",
                                 "choco":  "powershell-core",
                                 "content":  "PowerShell",
                                 "description":  "PowerShell es un framework de automatización y lenguaje de scripting para administradores de sistemas, ofreciendo potentes capacidades de línea de comandos.",
                                 "link":  "https://github.com/PowerShell/PowerShell",
                                 "winget":  "Microsoft.PowerShell",
                                 "foss":  true
                             },
    "WPFInstallpowertoys":  {
                                "category":  "Herramientas de Microsoft",
                                "choco":  "powertoys",
                                "content":  "PowerToys",
                                "description":  "PowerToys es un conjunto de utilidades para usuarios avanzados para mejorar la productividad (incluye herramientas como FancyZones, PowerRename y más).",
                                "link":  "https://github.com/microsoft/PowerToys",
                                "winget":  "Microsoft.PowerToys",
                                "foss":  true
                            },
    "WPFInstallprismlauncher":  {
                                    "category":  "Juegos",
                                    "choco":  "prismlauncher",
                                    "content":  "Prism Launcher",
                                    "description":  "Prism Launcher es un lanzador de Minecraft de código abierto para gestionar múltiples instancias, cuentas y mods.",
                                    "link":  "https://prismlauncher.org/",
                                    "winget":  "PrismLauncher.PrismLauncher",
                                    "foss":  true
                                },
    "WPFInstallprocesslasso":  {
                                   "category":  "Utilidades",
                                   "choco":  "plasso",
                                   "content":  "Process Lasso",
                                   "description":  "Process Lasso es una herramienta de optimización y automatización del sistema que mejora la respuesta ajustando prioridades de procesos.",
                                   "link":  "https://bitsum.com/",
                                   "winget":  "BitSum.ProcessLasso",
                                   "foss":  false
                               },
    "WPFInstallprotonauth":  {
                                 "category":  "Utilidades",
                                 "choco":  "protonauth",
                                 "content":  "Proton Authenticator",
                                 "description":  "Aplicación 2FA de Proton para sincronizar y hacer copias de seguridad seguras de códigos 2FA.",
                                 "link":  "https://proton.me/authenticator",
                                 "winget":  "Proton.ProtonAuthenticator",
                                 "foss":  true
                             },
    "WPFInstallprotonmail":  {
                                 "category":  "Comunicaciones",
                                 "choco":  "protonmail",
                                 "content":  "Proton Mail",
                                 "description":  "Proton Mail es un servicio de correo electrónico cifrado de extremo a extremo de Proton que protege tu privacidad.",
                                 "link":  "https://proton.me/mail",
                                 "winget":  "Proton.ProtonMail",
                                 "foss":  true
                             },
    "WPFInstallprotondrive":  {
                                  "category":  "Utilidades",
                                  "choco":  "protondrive",
                                  "content":  "Proton Drive",
                                  "description":  "Proton Drive es una bóveda suiza cifrada de extremo a extremo para tus archivos que protege tus datos.",
                                  "link":  "https://proton.me/drive",
                                  "winget":  "Proton.ProtonDrive",
                                  "foss":  true
                              },
    "WPFInstallprotonpass":  {
                                 "category":  "Utilidades",
                                 "choco":  "protonpass",
                                 "content":  "Proton Pass",
                                 "description":  "Proton Pass es un gestor de contraseñas en la nube con cifrado de extremo a extremo y alias de correo electrónico únicos.",
                                 "link":  "https://proton.me/pass",
                                 "winget":  "Proton.ProtonPass",
                                 "foss":  true
                             },
    "WPFInstallprotonvpn":  {
                                "category":  "Herramientas Profesionales",
                                "choco":  "protonvpn",
                                "content":  "Proton VPN",
                                "description":  "Proton VPN es un servicio VPN sin registros que protege tu privacidad en línea con funciones como Secure Core y Tor sobre VPN.",
                                "link":  "https://protonvpn.com/",
                                "winget":  "Proton.ProtonVPN",
                                "foss":  true
                            },
    "WPFInstallprocessmonitor":  {
                                     "category":  "Herramientas de Microsoft",
                                     "choco":  "procexp",
                                     "content":  "SysInternals Process Monitor",
                                     "description":  "SysInternals Process Monitor es una herramienta avanzada que muestra la actividad del sistema de archivos, registro y procesos en tiempo real.",
                                     "link":  "https://docs.microsoft.com/en-us/sysinternals/downloads/procmon",
                                     "winget":  "Microsoft.Sysinternals.ProcessMonitor",
                                     "foss":  false
                                 },
    "WPFInstallputty":  {
                            "category":  "Herramientas Profesionales",
                            "choco":  "putty",
                            "content":  "PuTTY",
                            "description":  "PuTTY es un emulador de terminal, consola serie y aplicación de transferencia de archivos de código abierto. Soporta protocolos como SSH, Telnet y SCP.",
                            "link":  "https://www.chiark.greenend.org.uk/~sgtatham/putty/",
                            "winget":  "PuTTY.PuTTY",
                            "foss":  true
                        },
    "WPFInstallpython3":  {
                              "category":  "Desarrollo",
                              "choco":  "python",
                              "content":  "Python3",
                              "description":  "Python es un lenguaje de programación versátil utilizado para desarrollo web, análisis de datos, inteligencia artificial y más.",
                              "link":  "https://www.python.org/",
                              "winget":  "Python.Python.3.14",
                              "foss":  true
                          },
    "WPFInstallqbittorrent":  {
                                  "category":  "Utilidades",
                                  "choco":  "qbittorrent",
                                  "content":  "qBittorrent",
                                  "description":  "qBittorrent es un cliente BitTorrent gratuito y de código abierto que proporciona una alternativa ligera y rica en funciones a otros clientes.",
                                  "link":  "https://www.qbittorrent.org/",
                                  "winget":  "qBittorrent.qBittorrent",
                                  "foss":  true
                              },
    "WPFInstallqtox":  {
                           "category":  "Comunicaciones",
                           "choco":  "qtox",
                           "content":  "QTox",
                           "description":  "QTox es una aplicación de mensajería gratuita y de código abierto que prioriza la privacidad y seguridad del usuario en su diseño.",
                           "link":  "https://qtox.github.io/",
                           "winget":  "Tox.qTox",
                           "foss":  true
                       },
    "WPFInstallrevo":  {
                           "category":  "Utilidades",
                           "choco":  "revo-uninstaller",
                           "content":  "Revo Uninstaller",
                           "description":  "Revo Uninstaller es una herramienta de desinstalación avanzada que te ayuda a eliminar software no deseado y limpiar tu sistema.",
                           "link":  "https://www.revouninstaller.com/",
                           "winget":  "RevoUninstaller.RevoUninstaller",
                           "foss":  false
                       },
    "WPFInstallWiseProgramUninstaller":  {
                                             "category":  "Utilidades",
                                             "choco":  "na",
                                             "content":  "Wise Program Uninstaller (WiseCleaner)",
                                             "description":  "Wise Program Uninstaller es la solución perfecta para desinstalar programas de Windows, rápida y completamente a través de su interfaz sencilla.",
                                             "link":  "https://www.wisecleaner.com/wise-program-uninstaller.html",
                                             "winget":  "WiseCleaner.WiseProgramUninstaller",
                                             "foss":  false
                                         },
    "WPFInstallrufus":  {
                            "category":  "Utilidades",
                            "choco":  "rufus",
                            "content":  "Rufus Imager",
                            "description":  "Rufus es una utilidad que ayuda a formatear y crear unidades USB de arranque, como pendrives o memorias USB.",
                            "link":  "https://rufus.ie/",
                            "winget":  "Rufus.Rufus",
                            "foss":  true
                        },
    "WPFInstallrustdesk":  {
                               "category":  "Herramientas Profesionales",
                               "choco":  "rustdesk.portable",
                               "content":  "RustDesk",
                               "description":  "RustDesk es una aplicación de escritorio remoto gratuita y de código abierto. Proporciona una forma segura de conectarse a máquinas remotas.",
                               "link":  "https://rustdesk.com/",
                               "winget":  "RustDesk.RustDesk",
                               "foss":  true
                           },
    "WPFInstallrustlang":  {
                               "category":  "Desarrollo",
                               "choco":  "rust",
                               "content":  "Rust",
                               "description":  "Rust es un lenguaje de programación diseñado para la seguridad y el rendimiento, enfocado en la programación de sistemas.",
                               "link":  "https://www.rust-lang.org/",
                               "winget":  "Rustlang.Rust.MSVC",
                               "foss":  true
                           },
    "WPFInstallsdio":  {
                           "category":  "Utilidades",
                           "choco":  "sdio",
                           "content":  "Snappy Driver Installer Origin",
                           "description":  "Snappy Driver Installer Origin es un actualizador de controladores gratuito y de código abierto con una vasta base de datos para Windows.",
                           "link":  "https://www.glenn.delahoy.com/snappy-driver-installer-origin/",
                           "winget":  "GlennDelahoy.SnappyDriverInstallerOrigin",
                           "foss":  true
                       },
    "WPFInstallsharex":  {
                             "category":  "Herramientas Multimedia",
                             "choco":  "sharex",
                             "content":  "ShareX (Screenshots)",
                             "description":  "ShareX es una herramienta de captura de pantalla e intercambio de archivos de código abierto. Ofrece métodos de captura y funciones de edición.",
                             "link":  "https://getsharex.com/",
                             "winget":  "ShareX.ShareX",
                             "foss":  true
                         },
    "WPFInstallnilesoftShell":  {
                                    "category":  "Utilidades",
                                    "choco":  "nilesoft-shell",
                                    "content":  "Nilesoft Shell",
                                    "description":  "Shell es una herramienta de menú contextual ampliado que añade funcionalidades extra y opciones de personalización al menú de Windows.",
                                    "link":  "https://nilesoft.org/",
                                    "winget":  "Nilesoft.Shell",
                                    "foss":  false
                                },
    "WPFInstallsysteminformer":  {
                                     "category":  "Desarrollo",
                                     "choco":  "systeminformer",
                                     "content":  "System Informer",
                                     "description":  "Una herramienta gratuita y potente de múltiples propósitos que te ayuda a monitorear recursos, depurar software y detectar malware.",
                                     "link":  "https://systeminformer.com/",
                                     "winget":  "WinsiderSS.SystemInformer",
                                     "foss":  true
                                 },
    "WPFInstallsignal":  {
                             "category":  "Comunicaciones",
                             "choco":  "signal",
                             "content":  "Signal",
                             "description":  "Signal es una aplicación de mensajería centrada en la privacidad que ofrece cifrado de extremo a extremo para una comunicación segura.",
                             "link":  "https://signal.org/",
                             "winget":  "OpenWhisperSystems.Signal",
                             "foss":  true
                         },
    "WPFInstallsignalrgb":  {
                                "category":  "Utilidades",
                                "choco":  "na",
                                "content":  "SignalRGB",
                                "description":  "SignalRGB te permite controlar y sincronizar tus dispositivos RGB favoritos con una aplicación gratuita.",
                                "link":  "https://www.signalrgb.com/",
                                "winget":  "WhirlwindFX.SignalRgb",
                                "foss":  false
                            },
    "WPFInstallsimplewall":  {
                                 "category":  "Herramientas Profesionales",
                                 "choco":  "simplewall",
                                 "content":  "Simplewall",
                                 "description":  "Simplewall es un firewall gratuito y de código abierto para Windows. Permite controlar el tráfico de red entrante y saliente de las aplicaciones.",
                                 "link":  "https://github.com/henrypp/simplewall",
                                 "winget":  "Henry++.simplewall",
                                 "foss":  true
                             },
    "WPFInstallslack":  {
                            "category":  "Comunicaciones",
                            "choco":  "slack",
                            "content":  "Slack",
                            "description":  "Slack es un centro de colaboración que conecta equipos y facilita la comunicación a través de canales, mensajería y uso compartido de archivos.",
                            "link":  "https://slack.com/",
                            "winget":  "SlackTechnologies.Slack",
                            "foss":  false
                        },
    "WPFInstallsteam":  {
                            "category":  "Juegos",
                            "choco":  "steam-client",
                            "content":  "Steam",
                            "description":  "Steam es una plataforma de distribución digital para comprar y jugar videojuegos, ofreciendo juegos multijugador, transmisión de video y más.",
                            "link":  "https://store.steampowered.com/about/",
                            "winget":  "Valve.Steam",
                            "foss":  false
                        },
    "WPFInstallsublimetext":  {
                                  "category":  "Desarrollo",
                                  "choco":  "sublimetext4",
                                  "content":  "Sublime Text",
                                  "description":  "Sublime Text es un sofisticado editor de texto para código, marcado y prosa.",
                                  "link":  "https://www.sublimetext.com/",
                                  "winget":  "SublimeHQ.SublimeText.4",
                                  "foss":  false
                              },
    "WPFInstallsunshine":  {
                               "category":  "Herramientas Selfhosted",
                               "choco":  "sunshine",
                               "content":  "Sunshine/GameStream Server",
                               "description":  "Sunshine es un servidor GameStream que permite jugar de forma remota a juegos de PC en dispositivos con streaming de baja latencia.",
                               "link":  "https://github.com/LizardByte/Sunshine",
                               "winget":  "LizardByte.Sunshine",
                               "foss":  true
                           },
    "WPFInstalltcpview":  {
                              "category":  "Herramientas de Microsoft",
                              "choco":  "tcpview",
                              "content":  "SysInternals TCPView",
                              "description":  "SysInternals TCPView es una herramienta de monitoreo de red que muestra una lista detallada de todos los endpoints TCP y UDP en el sistema.",
                              "link":  "https://docs.microsoft.com/en-us/sysinternals/downloads/tcpview",
                              "winget":  "Microsoft.Sysinternals.TCPView",
                              "foss":  false
                          },
    "WPFInstallteams":  {
                            "category":  "Comunicaciones",
                            "choco":  "microsoft-teams",
                            "content":  "Teams",
                            "description":  "Microsoft Teams es una plataforma de colaboración que se integra con Office 365 y ofrece chat, videoconferencias, intercambio de archivos y más.",
                            "link":  "https://www.microsoft.com/en-us/microsoft-teams/group-chat-software",
                            "winget":  "Microsoft.Teams",
                            "foss":  false
                        },
    "WPFInstallteamviewer":  {
                                 "category":  "Utilidades",
                                 "choco":  "teamviewer9",
                                 "content":  "TeamViewer",
                                 "description":  "TeamViewer es un popular software de soporte y acceso remoto que permite conectarse y controlar dispositivos de forma remota.",
                                 "link":  "https://www.teamviewer.com/",
                                 "winget":  "TeamViewer.TeamViewer",
                                 "foss":  false
                             },
    "WPFInstallteamspeak3":  {
                                 "category":  "Comunicaciones",
                                 "choco":  "teamspeak",
                                 "content":  "TeamSpeak 3",
                                 "description":  "Comunícate con tu equipo con sonido claro y cruza plataformas con seguridad de grado militar, rendimiento sin demoras y confiabilidad.",
                                 "link":  "https://www.teamspeak.com/",
                                 "winget":  "TeamSpeakSystems.TeamSpeakClient",
                                 "foss":  false
                             },
    "WPFInstalltelegram":  {
                               "category":  "Comunicaciones",
                               "choco":  "telegram",
                               "content":  "Telegram",
                               "description":  "Telegram es una aplicación de mensajería instantánea basada en la nube conocida por sus características de seguridad, velocidad y simplicidad.",
                               "link":  "https://telegram.org/",
                               "winget":  "Telegram.TelegramDesktop",
                               "foss":  true
                           },
    "WPFInstallterminal":  {
                               "category":  "Herramientas de Microsoft",
                               "choco":  "microsoft-windows-terminal",
                               "content":  "Windows Terminal",
                               "description":  "Windows Terminal es una aplicación de terminal moderna y eficiente para usuarios de línea de comandos, que admite múltiples pestañas y paneles.",
                               "link":  "https://aka.ms/terminal",
                               "winget":  "Microsoft.WindowsTerminal",
                               "foss":  true
                           },
    "WPFInstallthunderbird":  {
                                  "category":  "Comunicaciones",
                                  "choco":  "thunderbird",
                                  "content":  "Thunderbird",
                                  "description":  "Mozilla Thunderbird es un cliente de correo electrónico, noticias y chat gratuito y de código abierto con características avanzadas.",
                                  "link":  "https://www.thunderbird.net/",
                                  "winget":  "Mozilla.Thunderbird",
                                  "foss":  true
                              },
    "WPFInstallbetterbird":  {
                                 "category":  "Comunicaciones",
                                 "choco":  "betterbird",
                                 "content":  "Betterbird",
                                 "description":  "Betterbird es una bifurcación de Mozilla Thunderbird con funciones adicionales y corrección de errores.",
                                 "link":  "https://www.betterbird.eu/",
                                 "winget":  "Betterbird.Betterbird",
                                 "foss":  true
                             },
    "WPFInstalltor":  {
                          "category":  "Navegadores",
                          "choco":  "tor-browser",
                          "content":  "Tor Browser",
                          "description":  "Tor Browser está diseñado para la navegación web anónima, utilizando la red Tor para proteger la privacidad y seguridad del usuario.",
                          "link":  "https://www.torproject.org/",
                          "winget":  "TorProject.TorBrowser",
                          "foss":  true
                      },
    "WPFInstalltotalcommander":  {
                                     "category":  "Utilidades",
                                     "choco":  "TotalCommander",
                                     "content":  "Total Commander",
                                     "description":  "Total Commander es un administrador de archivos para Windows que proporciona una interfaz potente e intuitiva para la gestión de archivos.",
                                     "link":  "https://www.ghisler.com/",
                                     "winget":  "Ghisler.TotalCommander",
                                     "foss":  false
                                 },
    "WPFInstalltreesize":  {
                               "category":  "Utilidades",
                               "choco":  "treesizefree",
                               "content":  "TreeSize Free",
                               "description":  "TreeSize Free es un administrador de espacio en disco que te ayuda a analizar y visualizar el uso de almacenamiento en tus unidades.",
                               "link":  "https://www.jam-software.com/treesize_free/",
                               "winget":  "JAMSoftware.TreeSize.Free",
                               "foss":  false
                           },
    "WPFInstallttaskbar":  {
                               "category":  "Utilidades",
                               "choco":  "translucenttb",
                               "content":  "TranslucentTB",
                               "description":  "TranslucentTB es una herramienta que te permite personalizar la transparencia de la barra de tareas de Windows.",
                               "link":  "https://github.com/TranslucentTB/TranslucentTB",
                               "winget":  "CharlesMilette.TranslucentTB",
                               "foss":  true
                           },
    "WPFInstallubisoft":  {
                              "category":  "Juegos",
                              "choco":  "ubisoft-connect",
                              "content":  "Ubisoft Connect",
                              "description":  "Ubisoft Connect es el servicio de distribución digital y juegos en línea de Ubisoft, dando acceso a sus juegos y servicios.",
                              "link":  "https://ubisoftconnect.com/",
                              "winget":  "Ubisoft.Connect",
                              "foss":  false
                          },
    "WPFInstallungoogled":  {
                                "category":  "Navegadores",
                                "choco":  "ungoogled-chromium",
                                "content":  "Ungoogled",
                                "description":  "Ungoogled Chromium es una versión de Chromium sin la integración de Google, enfocada en mayor privacidad y control.",
                                "link":  "https://github.com/Eloston/ungoogled-chromium",
                                "winget":  "eloston.ungoogled-chromium",
                                "foss":  true
                            },
    "WPFInstallunity":  {
                            "category":  "Desarrollo",
                            "choco":  "unityhub",
                            "content":  "Unity Game Engine",
                            "description":  "Unity es una potente plataforma de desarrollo de juegos para crear juegos en 2D, 3D, realidad aumentada y realidad virtual.",
                            "link":  "https://unity.com/",
                            "winget":  "Unity.UnityHub",
                            "foss":  false
                        },
    "WPFInstallvc2015_32":  {
                                "category":  "Herramientas de Microsoft",
                                "choco":  "na",
                                "content":  "Visual C++ 2015-2022 32-bit",
                                "description":  "El paquete redistribuible Visual C++ 2015-2022 de 32 bits instala los componentes en tiempo de ejecución necesarios para aplicaciones de 32 bits.",
                                "link":  "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
                                "winget":  "Microsoft.VCRedist.2015+.x86",
                                "foss":  false
                            },
    "WPFInstallvc2015_64":  {
                                "category":  "Herramientas de Microsoft",
                                "choco":  "na",
                                "content":  "Visual C++ 2015-2022 64-bit",
                                "description":  "El paquete redistribuible Visual C++ 2015-2022 de 64 bits instala los componentes en tiempo de ejecución necesarios para aplicaciones de 64 bits.",
                                "link":  "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
                                "winget":  "Microsoft.VCRedist.2015+.x64",
                                "foss":  false
                            },
    "WPFInstallventoy":  {
                             "category":  "Herramientas Profesionales",
                             "choco":  "ventoy",
                             "content":  "Ventoy",
                             "description":  "Ventoy es una herramienta de código abierto para crear unidades USB de arranque. Admite múltiples archivos ISO en una sola unidad.",
                             "link":  "https://www.ventoy.net/",
                             "winget":  "Ventoy.Ventoy",
                             "foss":  true
                         },
    "WPFInstallvesktop":  {
                              "category":  "Comunicaciones",
                              "choco":  "na",
                              "content":  "Vesktop",
                              "description":  "Una aplicación de escritorio multiplataforma basada en electron para brindarte una experiencia más rápida en Discord, con Vencord preinstalado.",
                              "link":  "https://github.com/Vencord/Vesktop",
                              "winget":  "Vencord.Vesktop",
                              "foss":  true
                          },
    "WPFInstallviber":  {
                            "category":  "Comunicaciones",
                            "choco":  "viber",
                            "content":  "Viber",
                            "description":  "Viber es una aplicación gratuita de mensajería y llamadas con funciones como chats grupales, videollamadas y más.",
                            "link":  "https://www.viber.com/",
                            "winget":  "Rakuten.Viber",
                            "foss":  false
                        },
    "WPFInstallvisualstudio2022":  {
                                       "category":  "Desarrollo",
                                       "choco":  "visualstudio2022community",
                                       "content":  "Visual Studio 2022",
                                       "description":  "Visual Studio 2022 es un entorno de desarrollo integrado (IDE) para construir, depurar e implementar aplicaciones.",
                                       "link":  "https://visualstudio.microsoft.com/",
                                       "winget":  "Microsoft.VisualStudio.2022.Community",
                                       "foss":  false
                                   },
    "WPFInstallvisualstudio2026":  {
                                       "category":  "Desarrollo",
                                       "choco":  "visualstudio2026community",
                                       "content":  "Visual Studio 2026",
                                       "description":  "Visual Studio 2026 es un entorno de desarrollo integrado (IDE) para construir, depurar e implementar aplicaciones.",
                                       "link":  "https://visualstudio.microsoft.com/",
                                       "winget":  "Microsoft.VisualStudio.Community",
                                       "foss":  false
                                   },
    "WPFInstallvivaldi":  {
                              "category":  "Navegadores",
                              "choco":  "vivaldi",
                              "content":  "Vivaldi",
                              "description":  "Vivaldi es un navegador web altamente personalizable con un enfoque en la personalización del usuario y funciones de productividad.",
                              "link":  "https://vivaldi.com/",
                              "winget":  "Vivaldi.Vivaldi",
                              "foss":  false
                          },
    "WPFInstallvlc":  {
                          "category":  "Herramientas Multimedia",
                          "choco":  "vlc",
                          "content":  "VLC (Video Player)",
                          "description":  "VLC Media Player es un reproductor multimedia gratuito y de código abierto que admite una amplia gama de formatos de audio y video. Conocido por su versatilidad.",
                          "link":  "https://www.videolan.org/vlc/",
                          "winget":  "VideoLAN.VLC",
                          "foss":  true
                      },
    "WPFInstallvrdesktopstreamer":  {
                                        "category":  "Juegos",
                                        "choco":  "na",
                                        "content":  "Virtual Desktop Streamer",
                                        "description":  "Virtual Desktop Streamer es una herramienta que te permite transmitir la pantalla de tu escritorio a dispositivos de realidad virtual (VR).",
                                        "link":  "https://www.vrdesktop.net/",
                                        "winget":  "VirtualDesktop.Streamer",
                                        "foss":  false
                                    },
    "WPFInstallvscode":  {
                             "category":  "Desarrollo",
                             "choco":  "vscode",
                             "content":  "VS Code",
                             "description":  "Visual Studio Code es un editor de código gratuito y de código abierto con soporte para múltiples lenguajes de programación.",
                             "link":  "https://code.visualstudio.com/",
                             "winget":  "Microsoft.VisualStudioCode",
                             "foss":  true
                         },
    "WPFInstallvscodium":  {
                               "category":  "Desarrollo",
                               "choco":  "vscodium",
                               "content":  "VS Codium",
                               "description":  "VSCodium es una distribución binaria comunitaria y de licencia gratuita del VS Code de Microsoft.",
                               "link":  "https://vscodium.com/",
                               "winget":  "VSCodium.VSCodium",
                               "foss":  true
                           },
    "WPFInstallwaterfox":  {
                               "category":  "Navegadores",
                               "choco":  "waterfox",
                               "content":  "Waterfox",
                               "description":  "Waterfox es un navegador web rápido y centrado en la privacidad basado en Firefox, diseñado para preservar la elección y privacidad del usuario.",
                               "link":  "https://www.waterfox.net/",
                               "winget":  "Waterfox.Waterfox",
                               "foss":  true
                           },
    "WPFInstallwingetui":  {
                               "category":  "Utilidades",
                               "choco":  "wingetui",
                               "content":  "UniGetUI",
                               "description":  "UniGetUI es una interfaz gráfica (GUI) para WinGet, Chocolatey y otros administradores de paquetes CLI de Windows.",
                               "link":  "https://devolutions.net/unigetui/",
                               "winget":  "Devolutions.UniGetUI",
                               "foss":  true
                           },
    "WPFInstallwinrar":  {
                             "category":  "Utilidades",
                             "choco":  "winrar",
                             "content":  "WinRAR",
                             "description":  "WinRAR es un potente administrador de archivos que te permite crear, gestionar y extraer archivos comprimidos.",
                             "link":  "https://www.win-rar.com/",
                             "winget":  "RARLab.WinRAR",
                             "foss":  false
                         },
    "WPFInstallwinscp":  {
                             "category":  "Herramientas Profesionales",
                             "choco":  "winscp",
                             "content":  "WinSCP",
                             "description":  "WinSCP es un cliente SFTP, FTP y SCP popular y de código abierto para Windows. Permite transferencias seguras de archivos.",
                             "link":  "https://winscp.net/",
                             "winget":  "WinSCP.WinSCP",
                             "foss":  true
                         },
    "WPFInstallwireguard":  {
                                "category":  "Herramientas Profesionales",
                                "choco":  "wireguard",
                                "content":  "WireGuard",
                                "description":  "WireGuard es un protocolo VPN rápido y moderno. Su objetivo es ser más simple y eficiente que otros protocolos, proporcionando conexiones seguras.",
                                "link":  "https://www.wireguard.com/",
                                "winget":  "WireGuard.WireGuard",
                                "foss":  true
                            },
    "WPFInstallwireshark":  {
                                "category":  "Herramientas Profesionales",
                                "choco":  "wireshark",
                                "content":  "Wireshark",
                                "description":  "Wireshark es un analizador de protocolos de red de código abierto. Permite capturar y analizar el tráfico de red en tiempo real.",
                                "link":  "https://www.wireshark.org/",
                                "winget":  "WiresharkFoundation.Wireshark",
                                "foss":  true
                            },
    "WPFInstallwiztree":  {
                              "category":  "Utilidades",
                              "choco":  "wiztree",
                              "content":  "WizTree",
                              "description":  "WizTree es un analizador de espacio en disco rápido que te ayuda a encontrar los archivos y carpetas que consumen más espacio en tu disco duro.",
                              "link":  "https://wiztreefree.com/",
                              "winget":  "AntibodySoftware.WizTree",
                              "foss":  false
                          },
    "WPFInstallxeheditor":  {
                                "category":  "Utilidades",
                                "choco":  "HxD",
                                "content":  "HxD Hex Editor",
                                "description":  "HxD es un editor hexadecimal gratuito que te permite editar, ver, buscar y analizar archivos binarios.",
                                "link":  "https://mh-nexus.de/en/hxd/",
                                "winget":  "MHNexus.HxD",
                                "foss":  false
                            },
    "WPFInstallyarn":  {
                           "category":  "Desarrollo",
                           "choco":  "yarn",
                           "content":  "Yarn",
                           "description":  "Yarn es una herramienta de gestión de dependencias rápida, confiable y segura para proyectos de JavaScript.",
                           "link":  "https://yarnpkg.com/",
                           "winget":  "Yarn.Yarn",
                           "foss":  true
                       },
    "WPFInstallzoom":  {
                           "category":  "Comunicaciones",
                           "choco":  "zoom",
                           "content":  "Zoom",
                           "description":  "Zoom es un popular servicio de videoconferencias web para reuniones en línea, seminarios web y proyectos colaborativos.",
                           "link":  "https://zoom.us/",
                           "winget":  "Zoom.Zoom",
                           "foss":  false
                       },
    "WPFInstalluv":  {
                         "category":  "Desarrollo",
                         "choco":  "uv",
                         "content":  "uv",
                         "description":  "uv es un administrador de proyectos y paquetes de Python rápido escrito en Rust.",
                         "link":  "https://docs.astral.sh/uv/getting-started/installation/",
                         "winget":  "astral-sh.uv",
                         "foss":  true
                     },
    "WPFInstalltightvnc":  {
                               "category":  "Utilidades",
                               "choco":  "TightVNC",
                               "content":  "TightVNC",
                               "description":  "TightVNC es un software de escritorio remoto gratuito y de código abierto que te permite acceder y controlar una computadora a través de la red de forma interactiva e intuitiva.",
                               "link":  "https://www.tightvnc.com/",
                               "winget":  "GlavSoft.TightVNC",
                               "foss":  true
                           },
    "WPFInstallglazewm":  {
                              "category":  "Utilidades",
                              "choco":  "glazewm",
                              "content":  "GlazeWM",
                              "description":  "GlazeWM es un administrador de ventanas de mosaico para Windows inspirado en i3 y Polybar.",
                              "link":  "https://github.com/glzr-io/glazewm",
                              "winget":  "glzr-io.glazewm",
                              "foss":  true
                          },
    "WPFInstallOverwolf":  {
                               "category":  "Juegos",
                               "choco":  "overwolf",
                               "content":  "Overwolf",
                               "description":  "Plataforma popular para superposiciones de juegos y aplicaciones complementarias (gestores de mods, rastreadores, etc.), ampliamente utilizada por jugadores.",
                               "link":  "https://www.overwolf.com/app/overwolf-curseforge",
                               "winget":  "Overwolf.CurseForge",
                               "foss":  false
                           },
    "WPFInstallOFGB":  {
                           "category":  "Utilidades",
                           "choco":  "ofgb",
                           "content":  "OFGB (Oh Frick Go Back)",
                           "description":  "Herramienta GUI para eliminar anuncios de varios lugares en Windows 11.",
                           "link":  "https://github.com/xM4ddy/OFGB",
                           "winget":  "xM4ddy.OFGB",
                           "foss":  true
                       },
    "WPFInstallZenBrowser":  {
                                 "category":  "Navegadores",
                                 "choco":  "zen-browser",
                                 "content":  "Zen Browser",
                                 "description":  "El navegador moderno, centrado en la privacidad y el rendimiento, basado en Firefox.",
                                 "link":  "https://zen-browser.app/",
                                 "winget":  "Zen-Team.Zen-Browser",
                                 "foss":  true
                             },
    "WPFInstallZed":  {
                          "category":  "Desarrollo",
                          "choco":  "zed",
                          "content":  "Zed",
                          "description":  "Zed es un editor de código moderno de alto rendimiento, diseñado desde cero para la velocidad y la colaboración.",
                          "link":  "https://zed.dev/",
                          "winget":  "ZedIndustries.Zed",
                          "foss":  true
                      },
    "WPFInstalldeskflow":  {
                               "category":  "Utilidades",
                               "choco":  "deskflow",
                               "content":  "Deskflow",
                               "description":  "Deskflow es un software KVM de código abierto que te permite compartir un solo teclado y ratón en varias computadoras.",
                               "link":  "https://github.com/deskflow/deskflow",
                               "winget":  "Deskflow.Deskflow",
                               "foss":  true
                           },
    "WPFInstallRuby":  {
                           "category":  "Desarrollo",
                           "choco":  "ruby",
                           "winget":  "RubyInstallerTeam.Ruby.4.0",
                           "description":  "Un entorno de ejecución para el lenguaje Ruby con una instalación MSYS2.",
                           "content":  "Ruby",
                           "link":  "https://rubyinstaller.org/",
                           "foss":  true
                       },
    "WPFInstallLua":  {
                          "category":  "Desarrollo",
                          "choco":  "lua",
                          "winget":  "rjpcomputing.luaforwindows",
                          "description":  "Un \u0027entorno con baterías incluidas\u0027 para el lenguaje de scripting Lua en Windows.",
                          "content":  "Lua",
                          "link":  "https://github.com/rjpcomputing/luaforwindows",
                          "foss":  true
                      },
    "WPFInstallspotify":  {
                              "category":  "Herramientas Multimedia",
                              "choco":  "spotify",
                              "content":  "Spotify",
                              "description":  "Spotify es un servicio de música digital, pódcast y vídeos que te da acceso a millones de canciones y a otros contenidos.",
                              "link":  "https://www.spotify.com/",
                              "winget":  "Spotify.Spotify",
                              "foss":  false
                          },
    "WPFInstalladobeexpressphotos":  {
                                         "category":  "Herramientas Multimedia",
                                         "choco":  "na",
                                         "content":  "Adobe Express Photos",
                                         "description":  "Adobe Express Photos (anteriormente Photoshop Express) ofrece edición rápida y sencilla de fotos, collage de fotos y retoque de imágenes.",
                                         "link":  "https://apps.microsoft.com/detail/9WZDNCRFJ27N",
                                         "winget":  "9WZDNCRFJ27N",
                                         "foss":  false
                                     },
    "WPFInstallpinterest":  {
                                "category":  "Herramientas Multimedia",
                                "choco":  "na",
                                "content":  "Pinterest",
                                "description":  "Pinterest es una plataforma de descubrimiento visual para encontrar ideas como recetas, inspiración para el hogar y de estilo.",
                                "link":  "https://apps.microsoft.com/detail/9MW29S155D3W",
                                "winget":  "9MW29S155D3W",
                                "foss":  false
                            },
    "WPFInstalldisneyplus":  {
                                 "category":  "Herramientas Multimedia",
                                 "choco":  "na",
                                 "content":  "Disney+",
                                 "description":  "Disney+ es la plataforma de transmisión de tus historias favoritas de Disney, Pixar, Marvel, Star Wars y National Geographic.",
                                 "link":  "https://apps.microsoft.com/detail/9NXQXXLFST89",
                                 "winget":  "9NXQXXLFST89",
                                 "foss":  false
                             },
    "WPFInstallnetflix":  {
                              "category":  "Herramientas Multimedia",
                              "choco":  "netflix",
                              "content":  "Netflix",
                              "description":  "Netflix es un servicio de streaming por suscripción que permite a sus miembros ver series y películas en un dispositivo con conexión a internet.",
                              "link":  "https://apps.microsoft.com/detail/9WZDNCRFJ3TJ",
                              "winget":  "9WZDNCRFJ3TJ",
                              "foss":  false
                          },
    "WPFInstalltwitch":  {
                             "category":  "Herramientas Multimedia",
                             "choco":  "na",
                             "content":  "Twitch (Streamlink GUI)",
                             "description":  "Streamlink Twitch GUI es un cliente de escritorio de código abierto que te permite ver transmisiones de Twitch en reproductores externos de alto rendimiento.",
                             "link":  "https://github.com/streamlink/streamlink-twitch-gui",
                             "winget":  "Streamlink.Streamlink.TwitchGui",
                             "foss":  true
                         },
    "WPFInstalloutlook":  {
                              "category":  "Herramientas de Microsoft",
                              "choco":  "na",
                              "content":  "Outlook for Windows",
                              "description":  "El nuevo Outlook para Windows es una experiencia de correo electrónico moderna y gratuita diseñada para mantener tu vida organizada y conectada.",
                              "link":  "https://apps.microsoft.com/detail/9NRX63209R7B",
                              "winget":  "9NRX63209R7B",
                              "foss":  false
                          }
}
'@ | ConvertFrom-Json
$sync.configs.appnavigation = @'
{
    "WPFInstall":  {
                       "Content":  "Instalar/Actualizar Aplicaciones",
                       "Category":  "____Acciones",
                       "Type":  "Button",
                       "Order":  "1",
                       "Description":  "Instala o actualiza las aplicaciones seleccionadas"
                   },
    "WingetRadioButton":  {
                              "Content":  "WinGet",
                              "Category":  "__Gestor de Paquetes",
                              "Type":  "RadioButton",
                              "GroupName":  "PackageManagerGroup",
                              "Checked":  true,
                              "Order":  "1",
                              "Description":  "Usa WinGet para la gestión de paquetes"
                          },
    "ChocoRadioButton":  {
                             "Content":  "Chocolatey",
                             "Category":  "__Gestor de Paquetes",
                             "Type":  "RadioButton",
                             "GroupName":  "PackageManagerGroup",
                             "Checked":  false,
                             "Order":  "2",
                             "Description":  "Usa Chocolatey para la gestión de paquetes"
                         },
    "WPFCollapseAllCategories":  {
                                     "Content":  "Contraer Todas las Categorías",
                                     "Category":  "__Selección",
                                     "Type":  "Button",
                                     "Order":  "1",
                                     "Description":  "Contrae todas las categorías de aplicaciones"
                                 },
    "WPFExpandAllCategories":  {
                                   "Content":  "Expandir Todas las Categorías",
                                   "Category":  "__Selección",
                                   "Type":  "Button",
                                   "Order":  "2",
                                   "Description":  "Expande todas las categorías de aplicaciones"
                               },
    "WPFClearInstallSelection":  {
                                     "Content":  "Limpiar Selección",
                                     "Category":  "__Selección",
                                     "Type":  "Button",
                                     "Order":  "3",
                                     "Description":  "Limpia la selección de aplicaciones"
                                 },
    "WPFGetInstalled":  {
                            "Content":  "Mostrar Apps Instaladas",
                            "Category":  "__Selección",
                            "Type":  "Button",
                            "Order":  "4",
                            "Description":  "Muestra las aplicaciones instaladas"
                        },
    "WPFselectedAppsButton":  {
                                  "Content":  "Apps Seleccionadas: 0",
                                  "Category":  "__Selección",
                                  "Type":  "Button",
                                  "Order":  "5",
                                  "Description":  "Muestra las aplicaciones seleccionadas"
                              },
    "WPFToggleFOSSHighlight":  {
                                   "Content":  "Resaltar FOSS",
                                   "Category":  "__Selección",
                                   "Type":  "Toggle",
                                   "Checked":  true,
                                   "Order":  "6",
                                   "Description":  "Alterna el resaltado verde para las aplicaciones FOSS (Software Libre)"
                               },
    "WPFMAS":  {
                   "Content":  "Windows 10, 11 \u0026 Office",
                   "Category":  "z__Activaciones",
                   "Type":  "Button",
                   "Order":  "1",
                   "Description":  "Ejecuta los scripts oficiales de activación de Microsoft (MAS)"
               },
    "WPFActivation2":  {
                           "Content":  "Windows 7 Pro  \u0026 Enterprise",
                           "Category":  "z__Activaciones",
                           "Type":  "Button",
                           "Order":  "2",
                           "Description":  "Activa Windows 7 Pro o Enterprise mediante KMS"
                       },
    "WPFBulkCrapUninstaller":  {
                                   "Content":  "Bulk-Crap-Uninstaller (portable)",
                                   "Category":  "zz__Desinstalaciones",
                                   "Type":  "Button",
                                   "Order":  "2",
                                   "Description":  "Descarga y extrae la última versión portable de Bulk Crap Uninstaller en tu Escritorio"
                               },
    "WPFAutoYAOCTRI":  {
                           "Content":  "Auto YAOCTRI",
                           "Category":  "zzz__Microsoft Office",
                           "Type":  "Button",
                           "Order":  "1",
                           "Description":  "Instalación y despliegue de Office con limpieza profunda del sistema"
                       },
    "WPFDriverBooster":  {
                             "Content":  "Driver Booster.7z",
                             "Category":  "zzzz__Drivers",
                             "Type":  "Button",
                             "Order":  "1",
                             "Description":  "Descarga automáticamente Driver Booster en tu Escritorio desde Google Drive"
                         }
}
'@ | ConvertFrom-Json
$sync.configs.dns = @'
{
    "Google":  {
                   "Primary":  "8.8.8.8",
                   "Secondary":  "8.8.4.4",
                   "Primary6":  "2001:4860:4860::8888",
                   "Secondary6":  "2001:4860:4860::8844"
               },
    "Cloudflare":  {
                       "Primary":  "1.1.1.1",
                       "Secondary":  "1.0.0.1",
                       "Primary6":  "2606:4700:4700::1111",
                       "Secondary6":  "2606:4700:4700::1001"
                   },
    "Cloudflare_Malware":  {
                               "Primary":  "1.1.1.2",
                               "Secondary":  "1.0.0.2",
                               "Primary6":  "2606:4700:4700::1112",
                               "Secondary6":  "2606:4700:4700::1002"
                           },
    "Cloudflare_Malware_Adult":  {
                                     "Primary":  "1.1.1.3",
                                     "Secondary":  "1.0.0.3",
                                     "Primary6":  "2606:4700:4700::1113",
                                     "Secondary6":  "2606:4700:4700::1003"
                                 },
    "Open_DNS":  {
                     "Primary":  "208.67.222.222",
                     "Secondary":  "208.67.220.220",
                     "Primary6":  "2620:119:35::35",
                     "Secondary6":  "2620:119:53::53"
                 },
    "Quad9":  {
                  "Primary":  "9.9.9.9",
                  "Secondary":  "149.112.112.112",
                  "Primary6":  "2620:fe::fe",
                  "Secondary6":  "2620:fe::9"
              },
    "AdGuard_Ads_Trackers":  {
                                 "Primary":  "94.140.14.14",
                                 "Secondary":  "94.140.15.15",
                                 "Primary6":  "2a10:50c0::ad1:ff",
                                 "Secondary6":  "2a10:50c0::ad2:ff"
                             },
    "AdGuard_Ads_Trackers_Malware_Adult":  {
                                               "Primary":  "94.140.14.15",
                                               "Secondary":  "94.140.15.16",
                                               "Primary6":  "2a10:50c0::bad1:ff",
                                               "Secondary6":  "2a10:50c0::bad2:ff"
                                           }
}
'@ | ConvertFrom-Json
$sync.configs.feature = @'
{
    "WPFFeaturesdotnet":  {
                              "Content":  ".NET Framework (Versiones 2, 3, 4) - Activar",
                              "Description":  ".NET y .NET Framework es una plataforma de desarrollo compuesta por herramientas, lenguajes de programación y bibliotecas para crear muchos tipos diferentes de aplicaciones.",
                              "category":  "Características",
                              "panel":  "1",
                              "feature":  [
                                              "NetFx4-AdvSrvs",
                                              "NetFx3"
                                          ],
                              "InvokeScript":  [

                                               ],
                              "link":  "https://servicepcglew-winutil.pages.dev/dev/features/features/dotnet"
                          },
    "WPFFixesNTPPool":  {
                            "Content":  "Servidor NTP - Activar",
                            "Description":  "Reemplaza el servidor NTP de Windows por defecto (time.windows.com) con pool.ntp.org para mejorar la precisión y confiabilidad de la sincronización de la hora.",
                            "category":  "Correcciones",
                            "panel":  "1",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "function":  "Invoke-WPFFixesNTPPool",
                            "link":  "https://servicepcglew-winutil.pages.dev/dev/features/fixes/ntppool"
                        },
    "WPFFeatureshyperv":  {
                              "Content":  "Hyper-V - Activar",
                              "Description":  "Hyper-V es un producto de virtualización de hardware desarrollado por Microsoft que permite a los usuarios crear y gestionar máquinas virtuales.",
                              "category":  "Características",
                              "panel":  "1",
                              "feature":  [
                                              "Microsoft-Hyper-V-All"
                                          ],
                              "InvokeScript":  [
                                                   "bcdedit /set hypervisorschedulertype classic"
                                               ],
                              "link":  "https://servicepcglew-winutil.pages.dev/dev/features/features/hyperv"
                          },
    "WPFFeatureslegacymedia":  {
                                   "Content":  "Componentes Multimedia Heredados (WMP, DirectPlay) - Activar",
                                   "Description":  "Habilita programas heredados de versiones anteriores de Windows.",
                                   "category":  "Características",
                                   "panel":  "1",
                                   "feature":  [
                                                   "WindowsMediaPlayer",
                                                   "MediaPlayback",
                                                   "DirectPlay",
                                                   "LegacyComponents"
                                               ],
                                   "InvokeScript":  [

                                                    ],
                                   "link":  "https://servicepcglew-winutil.pages.dev/dev/features/features/legacymedia"
                               },
    "WPFFeaturewsl":  {
                          "Content":  "Subsistema de Windows para Linux (WSL) - Activar",
                          "Description":  "El Subsistema de Windows para Linux es una característica opcional que permite ejecutar programas de Linux de forma nativa en Windows sin necesidad de una máquina virtual separada o arranque dual.",
                          "category":  "Características",
                          "panel":  "1",
                          "feature":  [
                                          "VirtualMachinePlatform",
                                          "Microsoft-Windows-Subsystem-Linux"
                                      ],
                          "InvokeScript":  [

                                           ],
                          "link":  "https://servicepcglew-winutil.pages.dev/dev/features/features/wsl"
                      },
    "WPFFeaturenfs":  {
                          "Content":  "Sistema de Archivos de Red (NFS) - Activar",
                          "Description":  "El Sistema de Archivos de Red (NFS) es un mecanismo para almacenar archivos en una red.",
                          "category":  "Características",
                          "panel":  "1",
                          "feature":  [
                                          "ServicesForNFS-ClientOnly",
                                          "ClientForNFS-Infrastructure",
                                          "NFS-Administration"
                                      ],
                          "InvokeScript":  [
                                               "nfsadmin client stop",
                                               "Set-ItemProperty -Path \u0027HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default\u0027 -Name \u0027AnonymousUID\u0027 -Type DWord -Value 0",
                                               "Set-ItemProperty -Path \u0027HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default\u0027 -Name \u0027AnonymousGID\u0027 -Type DWord -Value 0",
                                               "nfsadmin client start",
                                               "nfsadmin client localhost config fileaccess=755 SecFlavors=+sys -krb5 -krb5i"
                                           ],
                          "link":  "https://servicepcglew-winutil.pages.dev/dev/features/features/nfs"
                      },
    "WPFFeatureRegBackup":  {
                                "Content":  "Copia de Seguridad del Registro (Tarea Diaria 12:30am) - Activar",
                                "Description":  "Habilita la copia de seguridad diaria del registro, previamente deshabilitada por Microsoft en Windows 10 1803.",
                                "category":  "Características",
                                "panel":  "1",
                                "feature":  [

                                            ],
                                "InvokeScript":  [
                                                     "\r\n      New-ItemProperty -Path \u0027HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\u0027 -Name \u0027EnablePeriodicBackup\u0027 -Type DWord -Value 1 -Force\r\n      New-ItemProperty -Path \u0027HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\u0027 -Name \u0027BackupCount\u0027 -Type DWord -Value 2 -Force\r\n      $action = New-ScheduledTaskAction -Execute \u0027schtasks\u0027 -Argument \u0027/run /i /tn \"\\Microsoft\\Windows\\Registry\\RegIdleBackup\"\u0027\r\n      $trigger = New-ScheduledTaskTrigger -Daily -At 00:30\r\n      Register-ScheduledTask -Action $action -Trigger $trigger -TaskName \u0027AutoRegBackup\u0027 -Description \u0027Create System Registry Backups\u0027 -User \u0027System\u0027\r\n      "
                                                 ],
                                "link":  "https://servicepcglew-winutil.pages.dev/dev/features/features/regbackup"
                            },
    "WPFFeatureEnableLegacyRecovery":  {
                                           "Content":  "Recuperación de Arranque F8 Heredada - Activar",
                                           "Description":  "Habilita la pantalla de Opciones de Arranque Avanzadas que te permite iniciar Windows en modos de solución de problemas avanzados.",
                                           "category":  "Características",
                                           "panel":  "1",
                                           "feature":  [

                                                       ],
                                           "InvokeScript":  [
                                                                "bcdedit /set bootmenupolicy legacy"
                                                            ],
                                           "link":  "https://servicepcglew-winutil.pages.dev/dev/features/features/enablelegacyrecovery"
                                       },
    "WPFFeatureDisableLegacyRecovery":  {
                                            "Content":  "Recuperación de Arranque F8 Heredada - Desactivar",
                                            "Description":  "Deshabilita la pantalla de Opciones de Arranque Avanzadas que te permite iniciar Windows en modos de solución de problemas avanzados.",
                                            "category":  "Características",
                                            "panel":  "1",
                                            "feature":  [

                                                        ],
                                            "InvokeScript":  [
                                                                 "bcdedit /set bootmenupolicy standard"
                                                             ],
                                            "link":  "https://servicepcglew-winutil.pages.dev/dev/features/features/disablelegacyrecovery"
                                        },
    "WPFFeaturesSandbox":  {
                               "Content":  "Windows Sandbox - Activar",
                               "Description":  "Windows Sandbox es una máquina virtual ligera que proporciona un entorno de escritorio temporal para ejecutar aplicaciones y programas de forma segura y aislada.",
                               "category":  "Características",
                               "panel":  "1",
                               "feature":  [
                                               "Containers-DisposableClientVM"
                                           ],
                               "link":  "https://servicepcglew-winutil.pages.dev/dev/features/features/sandbox"
                           },
    "WPFFeatureInstall":  {
                              "Content":  "Ejecutar Características",
                              "category":  "Características",
                              "panel":  "1",
                              "Type":  "Button",
                              "ButtonWidth":  "300",
                              "function":  "Invoke-WPFFeatureInstall",
                              "link":  "https://servicepcglew-winutil.pages.dev/dev/features/features/install"
                          },
    "WPFPanelAutologin":  {
                              "Content":  "AutoLogon (Inicio automático) - Ejecutar",
                              "category":  "Correcciones",
                              "panel":  "1",
                              "Type":  "Button",
                              "ButtonWidth":  "300",
                              "function":  "Invoke-WPFPanelAutologin",
                              "link":  "https://servicepcglew-winutil.pages.dev/dev/features/fixes/autologin"
                          },
    "WPFFixesUpdate":  {
                           "Content":  "Windows Update - Restablecer",
                           "category":  "Correcciones",
                           "panel":  "1",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "function":  "Invoke-WPFFixesUpdate",
                           "link":  "https://servicepcglew-winutil.pages.dev/dev/features/fixes/update"
                       },
    "WPFFixesNetwork":  {
                            "Content":  "Red - Restablecer",
                            "category":  "Correcciones",
                            "panel":  "1",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "function":  "Invoke-WPFFixesNetwork",
                            "link":  "https://servicepcglew-winutil.pages.dev/dev/features/fixes/network"
                        },
    "WPFPanelDISM":  {
                         "Content":  "Escaneo de Corrupción del Sistema - Ejecutar",
                         "category":  "Correcciones",
                         "panel":  "1",
                         "Type":  "Button",
                         "ButtonWidth":  "300",
                         "function":  "Invoke-WPFSystemRepair",
                         "link":  "https://servicepcglew-winutil.pages.dev/dev/features/fixes/dism"
                     },
    "WPFFixesWinget":  {
                           "Content":  "WinGet - Reinstalar",
                           "category":  "Correcciones",
                           "panel":  "1",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "function":  "Invoke-WPFFixesWinget",
                           "link":  "https://servicepcglew-winutil.pages.dev/dev/features/fixes/winget"
                       },
    "WPFPanelControl":  {
                            "Content":  "Panel de Control",
                            "category":  "Paneles Heredados de Windows",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "control"
                                             ],
                            "link":  "https://servicepcglew-winutil.pages.dev/dev/features/legacy-windows-panels/control"
                        },
    "WPFPanelComputer":  {
                             "Content":  "Administración de Equipos",
                             "category":  "Paneles Heredados de Windows",
                             "panel":  "2",
                             "Type":  "Button",
                             "ButtonWidth":  "300",
                             "InvokeScript":  [
                                                  "compmgmt.msc"
                                              ],
                             "link":  "https://servicepcglew-winutil.pages.dev/dev/features/legacy-windows-panels/computer"
                         },
    "WPFPanelNetwork":  {
                            "Content":  "Conexiones de Red",
                            "category":  "Paneles Heredados de Windows",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "ncpa.cpl"
                                             ],
                            "link":  "https://servicepcglew-winutil.pages.dev/dev/features/legacy-windows-panels/network"
                        },
    "WPFPanelPower":  {
                          "Content":  "Opciones de Energía",
                          "category":  "Paneles Heredados de Windows",
                          "panel":  "2",
                          "Type":  "Button",
                          "ButtonWidth":  "300",
                          "InvokeScript":  [
                                               "powercfg.cpl"
                                           ],
                          "link":  "https://servicepcglew-winutil.pages.dev/dev/features/legacy-windows-panels/power"
                      },
    "WPFPanelPrinter":  {
                            "Content":  "Dispositivos e Impresoras",
                            "category":  "Paneles Heredados de Windows",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "Start-Process \u0027shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}\u0027"
                                             ],
                            "link":  "https://servicepcglew-winutil.pages.dev/dev/features/legacy-windows-panels/printer"
                        },
    "WPFPanelRegion":  {
                           "Content":  "Región",
                           "category":  "Paneles Heredados de Windows",
                           "panel":  "2",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "InvokeScript":  [
                                                "intl.cpl"
                                            ],
                           "link":  "https://servicepcglew-winutil.pages.dev/dev/features/legacy-windows-panels/region"
                       },
    "WPFPanelRestore":  {
                            "Content":  "Restaurar Sistema",
                            "category":  "Paneles Heredados de Windows",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "rstrui.exe"
                                             ],
                            "link":  "https://servicepcglew-winutil.pages.dev/dev/features/legacy-windows-panels/restore"
                        },
    "WPFPanelSound":  {
                          "Content":  "Opciones de Sonido",
                          "category":  "Paneles Heredados de Windows",
                          "panel":  "2",
                          "Type":  "Button",
                          "ButtonWidth":  "300",
                          "InvokeScript":  [
                                               "mmsys.cpl"
                                           ],
                          "link":  "https://servicepcglew-winutil.pages.dev/dev/features/legacy-windows-panels/sound"
                      },
    "WPFPanelSystem":  {
                           "Content":  "Propiedades del Sistema",
                           "category":  "Paneles Heredados de Windows",
                           "panel":  "2",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "InvokeScript":  [
                                                "sysdm.cpl"
                                            ],
                           "link":  "https://servicepcglew-winutil.pages.dev/dev/features/legacy-windows-panels/system"
                       },
    "WPFPanelTimedate":  {
                             "Content":  "Fecha y Hora",
                             "category":  "Paneles Heredados de Windows",
                             "panel":  "2",
                             "Type":  "Button",
                             "ButtonWidth":  "300",
                             "InvokeScript":  [
                                                  "timedate.cpl"
                                              ],
                             "link":  "https://servicepcglew-winutil.pages.dev/dev/features/legacy-windows-panels/timedate"
                         },
    "WPFWinUtilInstallPSProfile":  {
                                       "Content":  "Perfil PowerShell CTT - Instalar",
                                       "category":  "Perfil de Powershell Solo Powershell 7+",
                                       "panel":  "2",
                                       "Type":  "Button",
                                       "ButtonWidth":  "300",
                                       "function":  "Invoke-WinUtilInstallPSProfile",
                                       "link":  "https://servicepcglew-winutil.pages.dev/dev/features/powershell-profile-powershell-7--only/installpsprofile"
                                   },
    "WPFWinUtilUninstallPSProfile":  {
                                         "Content":  "Perfil PowerShell CTT - Eliminar",
                                         "category":  "Perfil de Powershell Solo Powershell 7+",
                                         "panel":  "2",
                                         "Type":  "Button",
                                         "ButtonWidth":  "300",
                                         "function":  "Invoke-WinUtilUninstallPSProfile",
                                         "link":  "https://servicepcglew-winutil.pages.dev/dev/features/powershell-profile-powershell-7--only/uninstallpsprofile"
                                     },
    "WPFWinUtilSSHServer":  {
                                "Content":  "Servidor OpenSSH - Activar",
                                "category":  "Acceso Remoto",
                                "panel":  "2",
                                "Type":  "Button",
                                "ButtonWidth":  "300",
                                "function":  "Invoke-WPFSSHServer",
                                "link":  "https://servicepcglew-winutil.pages.dev/dev/features/remote-access/sshserver"
                            }
}
'@ | ConvertFrom-Json
$sync.configs.preset = @'
{
    "Standard":  [
                     "WPFTweaksActivity",
                     "WPFTweaksConsumerFeatures",
                     "WPFTweaksDisableExplorerAutoDiscovery",
                     "WPFTweaksWPBT",
                     "WPFTweaksDVR",
                     "WPFTweaksDeBloat",
                     "WPFTweaksLocation",
                     "WPFTweaksServices",
                     "WPFTweaksTelemetry",
                     "WPFTweaksDiskCleanup",
                     "WPFTweaksDeleteTempFiles",
                     "WPFTweaksEndTaskOnTaskbar",
                     "WPFTweaksRestorePoint",
                     "WPFTweaksPowershell7Tele"
                 ],
    "Minimal":  [
                    "WPFTweaksConsumerFeatures",
                    "WPFTweaksDeBloat",
                    "WPFTweaksWPBT",
                    "WPFTweaksServices",
                    "WPFTweaksTelemetry"
                ]
}
'@ | ConvertFrom-Json
$sync.configs.themes = @'
{
    "shared":  {
                   "AppEntryWidth":  "200",
                   "AppEntryFontSize":  "11",
                   "AppEntryMargin":  "1,0,1,0",
                   "AppEntryBorderThickness":  "0",
                   "CustomDialogFontSize":  "12",
                   "CustomDialogFontSizeHeader":  "14",
                   "CustomDialogLogoSize":  "48",
                   "CustomDialogWidth":  "400",
                   "CustomDialogHeight":  "200",
                   "FontSize":  "12",
                   "FontFamily":  "Arial",
                   "HeaderFontSize":  "16",
                   "HeaderFontFamily":  "Consolas, Monaco",
                   "CheckBoxBulletDecoratorSize":  "14",
                   "CheckBoxMargin":  "15,0,0,2",
                   "TabContentMargin":  "5",
                   "TabButtonFontSize":  "14",
                   "TabButtonWidth":  "140",
                   "TabButtonHeight":  "32",
                   "TabRowHeightInPixels":  "50",
                   "ToolTipWidth":  "300",
                   "IconFontSize":  "14",
                   "IconButtonSize":  "38",
                   "SettingsIconFontSize":  "18",
                   "CloseIconFontSize":  "18",
                   "GroupBorderBackgroundColor":  "#232629",
                   "ButtonFontSize":  "12",
                   "ButtonFontFamily":  "Arial",
                   "ButtonWidth":  "200",
                   "ButtonHeight":  "25",
                   "ConfigTabButtonFontSize":  "14",
                   "ConfigUpdateButtonFontSize":  "14",
                   "SearchBarWidth":  "200",
                   "SearchBarHeight":  "32",
                   "SearchBarTextBoxFontSize":  "12",
                   "SearchBarClearButtonFontSize":  "14",
                   "CheckboxMouseOverColor":  "#999999",
                   "ButtonBorderThickness":  "1",
                   "ButtonMargin":  "1",
                   "ButtonCornerRadius":  "2"
               },
    "Light":  {
                  "AppInstallUnselectedColor":  "#F7F7F7",
                  "AppInstallHighlightedColor":  "#CFCFCF",
                  "AppInstallSelectedColor":  "#C2C2C2",
                  "AppInstallOverlayBackgroundColor":  "#6A6D72",
                  "ComboBoxForegroundColor":  "#232629",
                  "ComboBoxBackgroundColor":  "#F7F7F7",
                  "LabelboxForegroundColor":  "#232629",
                  "MainForegroundColor":  "#232629",
                  "MainBackgroundColor":  "#F7F7F7",
                  "LabelBackgroundColor":  "#F7F7F7",
                  "LinkForegroundColor":  "#484848",
                  "LinkHoverForegroundColor":  "#232629",
                  "ScrollBarBackgroundColor":  "#4A4D52",
                  "ScrollBarHoverColor":  "#5A5D62",
                  "ScrollBarDraggingColor":  "#6A6D72",
                  "ProgressBarForegroundColor":  "#2E77FF",
                  "ProgressBarBackgroundColor":  "Transparent",
                  "ProgressBarTextColor":  "#232629",
                  "ButtonInstallBackgroundColor":  "#F7F7F7",
                  "ButtonTweaksBackgroundColor":  "#F7F7F7",
                  "ButtonConfigBackgroundColor":  "#F7F7F7",
                  "ButtonUpdatesBackgroundColor":  "#F7F7F7",
                  "ButtonWin11ISOBackgroundColor":  "#F7F7F7",
                  "ButtonInstallForegroundColor":  "#232629",
                  "ButtonTweaksForegroundColor":  "#232629",
                  "ButtonConfigForegroundColor":  "#232629",
                  "ButtonUpdatesForegroundColor":  "#232629",
                  "ButtonWin11ISOForegroundColor":  "#232629",
                  "ButtonBackgroundColor":  "#F5F5F5",
                  "ButtonBackgroundPressedColor":  "#1A1A1A",
                  "ButtonBackgroundMouseoverColor":  "#C2C2C2",
                  "ButtonBackgroundSelectedColor":  "#F0F0F0",
                  "ButtonForegroundColor":  "#232629",
                  "ToggleButtonOnColor":  "#2E77FF",
                  "ToggleButtonOffColor":  "#707070",
                  "ToolTipBackgroundColor":  "#F7F7F7",
                  "BorderColor":  "#232629",
                  "BorderOpacity":  "0.2"
              },
    "Dark":  {
                 "AppInstallUnselectedColor":  "#252526",
                 "AppInstallHighlightedColor":  "#2D2D30",
                 "AppInstallSelectedColor":  "#3E3E42",
                 "AppInstallOverlayBackgroundColor":  "#1E1E1E",
                 "ComboBoxForegroundColor":  "#F7F7F7",
                 "ComboBoxBackgroundColor":  "#333333",
                 "LabelboxForegroundColor":  "#FF6A00",
                 "MainForegroundColor":  "#F7F7F7",
                 "MainBackgroundColor":  "#1E1E1E",
                 "LabelBackgroundColor":  "#1E1E1E",
                 "LinkForegroundColor":  "#FF8833",
                 "LinkHoverForegroundColor":  "#FF6A00",
                 "ScrollBarBackgroundColor":  "#1E1E1E",
                 "ScrollBarHoverColor":  "#424242",
                 "ScrollBarDraggingColor":  "#616161",
                 "ProgressBarForegroundColor":  "#FF6A00",
                 "ProgressBarBackgroundColor":  "Transparent",
                 "ProgressBarTextColor":  "#F7F7F7",
                 "ButtonInstallBackgroundColor":  "#2D2D30",
                 "ButtonTweaksBackgroundColor":  "#2D2D30",
                 "ButtonConfigBackgroundColor":  "#2D2D30",
                 "ButtonUpdatesBackgroundColor":  "#2D2D30",
                 "ButtonWin11ISOBackgroundColor":  "#2D2D30",
                 "ButtonInstallForegroundColor":  "#F7F7F7",
                 "ButtonTweaksForegroundColor":  "#F7F7F7",
                 "ButtonConfigForegroundColor":  "#F7F7F7",
                 "ButtonUpdatesForegroundColor":  "#F7F7F7",
                 "ButtonWin11ISOForegroundColor":  "#F7F7F7",
                 "ButtonBackgroundColor":  "#333333",
                 "ButtonBackgroundPressedColor":  "#CC5500",
                 "ButtonBackgroundMouseoverColor":  "#444444",
                 "ButtonBackgroundSelectedColor":  "#FF6A00",
                 "ButtonForegroundColor":  "#F7F7F7",
                 "ToggleButtonOnColor":  "#FF6A00",
                 "ToggleButtonOffColor":  "#555555",
                 "ToolTipBackgroundColor":  "#252526",
                 "BorderColor":  "#3C3C3C",
                 "BorderOpacity":  "0.5"
             }
}
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
{
    "WPFTweaksActivity":  {
                              "Content":  "Historial de Actividad - Desactivar",
                              "Description":  "Borra documentos recientes, portapapeles y el historial de ejecución.",
                              "category":  "Ajustes Esenciales",
                              "panel":  "1",
                              "registry":  [
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "EnableActivityFeed",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "PublishUserActivities",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "UploadUserActivities",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               }
                                           ],
                              "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/activity"
                          },
    "WPFTweaksHiber":  {
                           "Content":  "Hibernación - Desactivar",
                           "Description":  "La hibernación está pensada para laptops ya que guarda lo que está en memoria antes de apagar. Raramente debe usarse en PC.",
                           "category":  "Ajustes Esenciales",
                           "panel":  "1",
                           "registry":  [
                                            {
                                                "Path":  "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
                                                "Name":  "HibernateEnabled",
                                                "Value":  "0",
                                                "Type":  "DWord",
                                                "OriginalValue":  "1"
                                            },
                                            {
                                                "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
                                                "Name":  "ShowHibernateOption",
                                                "Value":  "0",
                                                "Type":  "DWord",
                                                "OriginalValue":  "1"
                                            }
                                        ],
                           "InvokeScript":  [
                                                "powercfg.exe /hibernate off"
                                            ],
                           "UndoScript":  [
                                              "powercfg.exe /hibernate on"
                                          ],
                           "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/hiber"
                       },
    "WPFTweaksWidget":  {
                            "Content":  "Widgets - Eliminar",
                            "Description":  "Elimina los molestos widgets en la parte inferior izquierda de la barra de tareas.",
                            "category":  "Ajustes Esenciales",
                            "panel":  "1",
                            "InvokeScript":  [
                                                 "\r\n      # Sometimes if you dont stop the Widgets process the removal may fail\r\n\r\n      Get-Process *Widget* | Stop-Process\r\n      Get-AppxPackage Microsoft.WidgetsPlatformRuntime -AllUsers | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage MicrosoftWindows.Client.WebExperience -AllUsers | Remove-AppxPackage -AllUsers\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      Write-Host \"Removed widgets\"\r\n      "
                                             ],
                            "UndoScript":  [
                                               "\r\n      Write-Host \"Restoring widgets AppxPackages\"\r\n\r\n      Add-AppxPackage -Register \"C:\\Program Files\\WindowsApps\\Microsoft.WidgetsPlatformRuntime*\\AppxManifest.xml\" -DisableDevelopmentMode\r\n      Add-AppxPackage -Register \"C:\\Program Files\\WindowsApps\\MicrosoftWindows.Client.WebExperience*\\AppxManifest.xml\" -DisableDevelopmentMode\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                           ],
                            "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/widget"
                        },
    "WPFTweaksRevertStartMenu":  {
                                     "Content":  "Diseño Anterior del Menú Inicio - Activar",
                                     "Description":  "Restaura el diseño anterior del Menú Inicio, previo al lanzamiento gradual del nuevo en la 25H2.",
                                     "category":  "Ajustes Esenciales",
                                     "panel":  "1",
                                     "InvokeScript":  [
                                                          "\r\n      Invoke-WebRequest https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip -OutFile ViVeTool.zip\r\n\r\n      Expand-Archive ViVeTool.zip\r\n      Remove-Item ViVeTool.zip\r\n\r\n      Start-Process \u0027ViVeTool\\ViVeTool.exe\u0027 -ArgumentList \u0027/disable /id:47205210\u0027 -Wait -NoNewWindow\r\n\r\n      Remove-Item ViVeTool -Recurse\r\n\r\n      Write-Host \u0027Old start menu reverted. Please restart your computer to take effect.\u0027\r\n      "
                                                      ],
                                     "UndoScript":  [
                                                        "\r\n      Invoke-WebRequest https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip -OutFile ViVeTool.zip\r\n\r\n      Expand-Archive ViVeTool.zip\r\n      Remove-Item ViVeTool.zip\r\n\r\n      Start-Process \u0027ViVeTool\\ViVeTool.exe\u0027 -ArgumentList \u0027/enable /id:47205210\u0027 -Wait -NoNewWindow\r\n\r\n      Remove-Item ViVeTool -Recurse\r\n\r\n      Write-Host \u0027New start menu reverted. Please restart your computer to take effect.\u0027\r\n      "
                                                    ],
                                     "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/revertstartmenu"
                                 },
    "WPFTweaksDisableStoreSearch":  {
                                        "Content":  "Resultados de Búsqueda Recomendados de Microsoft Store - Desactivar",
                                        "Description":  "No mostrará aplicaciones recomendadas de la Microsoft Store al buscar aplicaciones en el menú Inicio.",
                                        "category":  "Ajustes Esenciales",
                                        "panel":  "1",
                                        "InvokeScript":  [
                                                             "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /deny Everyone:F"
                                                         ],
                                        "UndoScript":  [
                                                           "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /grant Everyone:F"
                                                       ],
                                        "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/disablestoresearch"
                                    },
    "WPFTweaksLocation":  {
                              "Content":  "Rastreo de Ubicación - Desactivar",
                              "Description":  "Desactiva el rastreo de ubicación.",
                              "category":  "Ajustes Esenciales",
                              "panel":  "1",
                              "service":  [
                                              {
                                                  "Name":  "lfsvc",
                                                  "StartupType":  "Disable",
                                                  "OriginalType":  "Manual"
                                              }
                                          ],
                              "registry":  [
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
                                                   "Name":  "Value",
                                                   "Value":  "Deny",
                                                   "Type":  "String",
                                                   "OriginalValue":  "Allow"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
                                                   "Name":  "SensorPermissionState",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SYSTEM\\Maps",
                                                   "Name":  "AutoUpdateEnabled",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1"
                                               }
                                           ],
                              "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/location"
                          },
    "WPFTweaksServices":  {
                              "Content":  "Servicios - Establecer en Manual",
                              "Description":  "Establece algunos servicios en inicio Manual y ajusta el valor del registro SvcHostSplitThresholdInKB para coincidir mejor con la memoria del sistema, reduciendo los procesos svchost.exe.",
                              "category":  "Ajustes Esenciales",
                              "panel":  "1",
                              "service":  [
                                              {
                                                  "Name":  "CscService",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Manual"
                                              },
                                              {
                                                  "Name":  "DiagTrack",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "MapsBroker",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "StorSvc",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "SharedAccess",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Automatic"
                                              }
                                          ],
                              "InvokeScript":  [
                                                   "\r\n      $Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB\r\n      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value $Memory\r\n      "
                                               ],
                              "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/services"
                          },
    "WPFTweaksBraveDebloat":  {
                                  "Content":  "Navegador Brave - Optimizar (Debloat)",
                                  "Description":  "Desactiva varias molestias como Brave Rewards, Leo AI, Crypto Wallet y VPN.",
                                  "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                  "panel":  "1",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveRewardsDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveWalletDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveVPNDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveAIChatEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveStatsPingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveNewsDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveTalkDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "TorDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveP3AEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "UrlKeyedAnonymizedDataCollectionEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "SafeBrowsingExtendedReportingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "MetricsReportingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   }
                                               ],
                                  "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/bravedebloat"
                              },
    "WPFTweaksDisableWarningForUnsignedRdp":  {
                                                  "Content":  "Advertencias de Archivos RDP No Firmados - Desactivar",
                                                  "Description":  "Desactiva las advertencias al iniciar archivos RDP no firmados, introducidas en las últimas actualizaciones de Windows 10 y 11.",
                                                  "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                                  "panel":  "1",
                                                  "registry":  [
                                                                   {
                                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services\\Client",
                                                                       "Name":  "RedirectionWarningDialogVersion",
                                                                       "Value":  "1",
                                                                       "Type":  "DWord",
                                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                                   },
                                                                   {
                                                                       "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Terminal Server Client",
                                                                       "Name":  "RdpLaunchConsentAccepted",
                                                                       "Value":  "1",
                                                                       "Type":  "DWord",
                                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                                   }
                                                               ],
                                                  "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/disablewarningforunsignedrdp"
                                              },
    "WPFTweaksEdgeDebloat":  {
                                 "Content":  "Microsoft Edge - Optimizar (Debloat)",
                                 "Description":  "Desactiva varias opciones de telemetría, ventanas emergentes y otras molestias en Edge.",
                                 "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                 "panel":  "1",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
                                                      "Name":  "CreateDesktopShortcutDefault",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "PersonalizationReportingEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
                                                      "Name":  "1",
                                                      "Value":  "ofefcgjbeghpigppfmkologfjadafddi",
                                                      "Type":  "String",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ShowRecommendationsEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "HideFirstRunExperience",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "UserFeedbackAllowed",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ConfigureDoNotTrack",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "AlternateErrorPagesEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeCollectionsEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeShoppingAssistantEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "MicrosoftEdgeInsiderPromotionEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ShowMicrosoftRewards",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "WebWidgetAllowed",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "DiagnosticData",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeAssetDeliveryServiceEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "WalletDonationEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "DefaultBrowserSettingsCampaignEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  }
                                              ],
                                 "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/edgedebloat"
                             },
    "WPFTweaksConsumerFeatures":  {
                                      "Content":  "Características de Consumidor - Desactivar",
                                      "Description":  "Windows no instalará automáticamente juegos, aplicaciones de terceros ni enlaces de la Tienda. Algunas apps predeterminadas serán inaccesibles.",
                                      "category":  "Ajustes Esenciales",
                                      "panel":  "1",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
                                                           "Name":  "DisableWindowsConsumerFeatures",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                       }
                                                   ],
                                      "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/consumerfeatures"
                                  },
    "WPFTweaksTelemetry":  {
                               "Content":  "Telemetría - Desactivar",
                               "Description":  "Desactiva la telemetría de Microsoft.",
                               "category":  "Ajustes Esenciales",
                               "panel":  "1",
                               "registry":  [
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
                                                    "Name":  "Enabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
                                                    "Name":  "TailoredExperiencesWithDiagnosticDataEnabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
                                                    "Name":  "HasAccepted",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Input\\TIPC",
                                                    "Name":  "Enabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization",
                                                    "Name":  "RestrictImplicitInkCollection",
                                                    "Value":  "1",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization",
                                                    "Name":  "RestrictImplicitTextCollection",
                                                    "Value":  "1",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
                                                    "Name":  "HarvestContacts",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Personalization\\Settings",
                                                    "Name":  "AcceptedPrivacyPolicy",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
                                                    "Name":  "AllowTelemetry",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                    "Name":  "Start_TrackProgs",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                    "Name":  "PublishUserActivities",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
                                                    "Name":  "NumberOfSIUFInPeriod",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                }
                                            ],
                               "InvokeScript":  [
                                                    "\r\n      # Disable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 2\r\n\r\n      # Disable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Disabled\r\n\r\n      # Disable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Disabled\r\n\r\n      Remove-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Siuf\\Rules\" -Name PeriodInNanoSeconds\r\n      "
                                                ],
                               "UndoScript":  [
                                                  "\r\n      # Enable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 1\r\n\r\n      # Enable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Automatic\r\n\r\n      # Enable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Automatic\r\n      "
                                              ],
                               "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/telemetry"
                           },
    "WPFTweaksRemoveEdge":  {
                                "Content":  "Microsoft Edge - Eliminar",
                                "Description":  "Desbloquea las restricciones del desinstalador de Microsoft Edge y luego lo usa para eliminarlo.",
                                "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                "panel":  "1",
                                "InvokeScript":  [
                                                     "Invoke-WinUtilRemoveEdge"
                                                 ],
                                "UndoScript":  [
                                                   "\r\n      Write-Host \u0027Installing Microsoft Edge...\u0027\r\n      winget install Microsoft.Edge --source winget\r\n      "
                                               ],
                                "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/removeedge"
                            },
    "WPFTweaksUTC":  {
                         "Content":  "Fecha y Hora - Establecer hora en UTC",
                         "Description":  "Esencial para computadoras con arranque dual (dual boot). Arregla la sincronización de tiempo con sistemas Linux.",
                         "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                         "panel":  "1",
                         "registry":  [
                                          {
                                              "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
                                              "Name":  "RealTimeIsUniversal",
                                              "Value":  "1",
                                              "Type":  "QWord",
                                              "OriginalValue":  "0"
                                          }
                                      ],
                         "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/utc"
                     },
    "WPFTweaksRemoveOneDrive":  {
                                    "Content":  "Microsoft OneDrive - Eliminar",
                                    "Description":  "Deniega permisos para eliminar archivos de usuario de OneDrive, usa su desinstalador para eliminarlo y restaura los permisos después.",
                                    "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                    "panel":  "1",
                                    "InvokeScript":  [
                                                         "\r\n      # Deny permission to remove OneDrive folder\r\n      icacls $Env:OneDrive /deny \"Administrators:(D,DC)\"\r\n\r\n      Write-Host \"Uninstalling OneDrive...\"\r\n      Start-Process \u0027C:\\Windows\\System32\\OneDriveSetup.exe\u0027 -ArgumentList \u0027/uninstall\u0027 -Wait\r\n\r\n      # Some of OneDrive files use explorer, and OneDrive uses FileCoAuth\r\n      Write-Host \"Removing leftover OneDrive Files...\"\r\n      Stop-Process -Name FileCoAuth,Explorer\r\n      Remove-Item \"$Env:LocalAppData\\Microsoft\\OneDrive\" -Recurse -Force\r\n      Remove-Item \"C:\\ProgramData\\Microsoft OneDrive\" -Recurse -Force\r\n\r\n      # Grant back permission to access OneDrive folder\r\n      icacls $Env:OneDrive /grant \"Administrators:(D,DC)\"\r\n\r\n      # Disable OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Disabled\r\n      "
                                                     ],
                                    "UndoScript":  [
                                                       "\r\n      Write-Host \"Installing OneDrive\"\r\n      winget install Microsoft.Onedrive --source winget\r\n\r\n      # Enabled OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Automatic\r\n      "
                                                   ],
                                    "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/removeonedrive"
                                },
    "WPFTweaksRemoveHome":  {
                                "Content":  "Inicio y Galería del Explorador de Archivos - Desactivar",
                                "Description":  "Elimina el Inicio y la Galería del Explorador y establece \u0027Este equipo\u0027 por defecto.",
                                "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                "panel":  "1",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Software\\Classes\\CLSID\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
                                                     "Name":  "System.IsPinnedToNameSpaceTree",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                     "Name":  "LaunchTo",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                 }
                                             ],
                                "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/removehome"
                            },
    "WPFTweaksDisplay":  {
                             "Content":  "Efectos Visuales - Establecer en Mejor Rendimiento",
                             "Description":  "Establece las preferencias del sistema en rendimiento. También puedes hacerlo manualmente con sysdm.cpl.",
                             "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                             "panel":  "1",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop",
                                                  "Name":  "DragFullWindows",
                                                  "Value":  "0",
                                                  "Type":  "String",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop",
                                                  "Name":  "MenuShowDelay",
                                                  "Value":  "200",
                                                  "Type":  "String",
                                                  "OriginalValue":  "400"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
                                                  "Name":  "MinAnimate",
                                                  "Value":  "0",
                                                  "Type":  "String",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Keyboard",
                                                  "Name":  "KeyboardDelay",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ListviewAlphaSelect",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ListviewShadow",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "TaskbarAnimations",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
                                                  "Name":  "VisualFXSetting",
                                                  "Value":  "3",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\DWM",
                                                  "Name":  "EnableAeroPeek",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "TaskbarMn",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ShowTaskViewButton",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                  "Name":  "SearchboxTaskbarMode",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              }
                                          ],
                             "InvokeScript":  [
                                                  "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
                                              ],
                             "UndoScript":  [
                                                "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
                                            ],
                             "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/display"
                         },
    "WPFTweaksXboxRemoval":  {
                                 "Content":  "Componentes de Xbox y Juegos - Eliminar",
                                 "Description":  "Elimina los servicios de Xbox, la app de Xbox, Game Bar y los componentes de autenticación relacionados.",
                                 "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                 "panel":  "1",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\GameDVR",
                                                      "Name":  "AppCaptureEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "1"
                                                  }
                                              ],
                                 "appx":  [
                                              "Microsoft.XboxIdentityProvider",
                                              "Microsoft.XboxSpeechToTextOverlay",
                                              "Microsoft.GamingApp",
                                              "Microsoft.Xbox.TCUI",
                                              "Microsoft.XboxGamingOverlay"
                                          ],
                                 "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/xboxremoval"
                             },
    "WPFTweaksDeBloat":  {
                             "Content":  "Aplicaciones Preinstaladas No Deseadas - Eliminar",
                             "Description":  "Esto eliminará un montón de aplicaciones preinstaladas de Windows que la mayoría de la gente no quiere en su sistema.",
                             "category":  "Ajustes Esenciales",
                             "panel":  "1",
                             "appx":  [
                                          "Microsoft.WindowsFeedbackHub",
                                          "Microsoft.BingNews",
                                          "Microsoft.BingSearch",
                                          "Microsoft.BingWeather",
                                          "Clipchamp.Clipchamp",
                                          "Microsoft.Todos",
                                          "Microsoft.PowerAutomateDesktop",
                                          "Microsoft.MicrosoftSolitaireCollection",
                                          "Microsoft.WindowsSoundRecorder",
                                          "Microsoft.MicrosoftStickyNotes",
                                          "Microsoft.Windows.DevHome",
                                          "Microsoft.Paint",
                                          "Microsoft.OutlookForWindows",
                                          "Microsoft.WindowsAlarms",
                                          "Microsoft.StartExperiencesApp",
                                          "Microsoft.GetHelp",
                                          "Microsoft.ZuneMusic",
                                          "MicrosoftCorporationII.QuickAssist",
                                          "MSTeams"
                                      ],
                             "InvokeScript":  [
                                                  "\r\n      $TeamsPath = \"$Env:LocalAppData\\Microsoft\\Teams\\Update.exe\"\r\n\r\n      if (Test-Path $TeamsPath) {\r\n        Write-Host \"Uninstalling Teams\"\r\n        Start-Process $TeamsPath -ArgumentList -uninstall -wait\r\n\r\n        Write-Host \"Deleting Teams directory\"\r\n        Remove-Item $TeamsPath -Recurse -Force\r\n      }\r\n      "
                                              ],
                             "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/debloat"
                         },
    "WPFTweaksRestorePoint":  {
                                  "Content":  "Punto de Restauración - Crear",
                                  "Description":  "Crea un punto de restauración en tiempo de ejecución en caso de que sea necesario revertir las modificaciones de WinUtil.",
                                  "category":  "Ajustes Esenciales",
                                  "panel":  "1",
                                  "Checked":  "False",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore",
                                                       "Name":  "SystemRestorePointCreationFrequency",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "1440"
                                                   }
                                               ],
                                  "InvokeScript":  [
                                                       "\r\n      if (-not (Get-ComputerRestorePoint)) {\r\n          Enable-ComputerRestore -Drive $Env:SystemDrive\r\n      }\r\n\r\n      Checkpoint-Computer -Description \"System Restore Point created by WinUtil\" -RestorePointType MODIFY_SETTINGS\r\n      Write-Host \"System Restore Point Created Successfully\" -ForegroundColor Green\r\n      "
                                                   ],
                                  "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/restorepoint"
                              },
    "WPFTweaksEndTaskOnTaskbar":  {
                                      "Content":  "Finalizar Tarea con Clic Derecho - Activar",
                                      "Description":  "Habilita la opción de finalizar tarea al hacer clic derecho en un programa en la barra de tareas.",
                                      "category":  "Ajustes Esenciales",
                                      "panel":  "1",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
                                                           "Name":  "TaskbarEndTask",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                       }
                                                   ],
                                      "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/endtaskontaskbar"
                                  },
    "WPFTweaksPowershell7Tele":  {
                                     "Content":  "Telemetría de PowerShell 7 - Desactivar",
                                     "Description":  "Crea una variable de entorno \u0027POWERSHELL_TELEMETRY_OPTOUT\u0027 con valor \u00271\u0027 para evitar que PowerShell 7 envíe datos de telemetría.",
                                     "category":  "Ajustes Esenciales",
                                     "panel":  "1",
                                     "InvokeScript":  [
                                                          "[Environment]::SetEnvironmentVariable(\u0027POWERSHELL_TELEMETRY_OPTOUT\u0027, \u00271\u0027, \u0027Machine\u0027)"
                                                      ],
                                     "UndoScript":  [
                                                        "[Environment]::SetEnvironmentVariable(\u0027POWERSHELL_TELEMETRY_OPTOUT\u0027, \u0027\u0027, \u0027Machine\u0027)"
                                                    ],
                                     "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/powershell7tele"
                                 },
    "WPFTweaksStorage":  {
                             "Content":  "Sensor de Almacenamiento - Desactivar",
                             "Description":  "El Sensor de Almacenamiento elimina archivos temporales automáticamente.",
                             "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                             "panel":  "1",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
                                                  "Name":  "01",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              }
                                          ],
                             "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/storage"
                         },
    "WPFTweaksWindowsAI":  {
                               "Content":  "IA de Windows - Desactivar",
                               "Description":  "Elimina o desactiva todas las funciones y paquetes de IA.",
                               "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                               "panel":  "1",
                               "registry":  [
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
                                                    "Name":  "SettingsPageVisibility",
                                                    "Value":  "hide:aicomponents",
                                                    "Type":  "String",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Policies\\WindowsNotepad",
                                                    "Name":  "DisableAIFeatures",
                                                    "Value":  1,
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                }
                                            ],
                               "InvokeScript":  [
                                                    "\r\n      $Appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI).PackageFullName\r\n      $Sid = (Get-LocalUser $Env:UserName).Sid.Value\r\n\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$Sid\\$Appx\" -Force\r\n\r\n      Get-AppxPackage -AllUsers *Copilot* | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub | Remove-AppxPackage -AllUsers\r\n      Remove-AppxPackage $Appx\r\n\r\n      Set-Service -Name WSAIFabricSvc -StartupType Disabled\r\n      Disable-WindowsOptionalFeature -FeatureName Recall -Online\r\n\r\n      Write-Host \"Windows AI Disabled\"\r\n      "
                                                ],
                               "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/windowsai"
                           },
    "WPFTweaksWPBT":  {
                          "Content":  "Windows Platform Binary Table (WPBT) - Desactivar",
                          "Description":  "Si está habilitado, WPBT permite al fabricante ejecutar programas en el arranque (antirrobo, controladores) e instalar software sin consentimiento del usuario. Riesgo de seguridad.",
                          "category":  "Ajustes Esenciales",
                          "panel":  "1",
                          "registry":  [
                                           {
                                               "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
                                               "Name":  "DisableWpbtExecution",
                                               "Value":  "1",
                                               "Type":  "DWord",
                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                           }
                                       ],
                          "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/wpbt"
                      },
    "WPFTweaksRazerBlock":  {
                                "Content":  "Auto-Instalador de Software Razer - Desactivar",
                                "Description":  "Bloquea TODAS las instalaciones de software Razer. El hardware funciona bien sin ningún software.",
                                "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                "panel":  "1",
                                "registry":  [
                                                 {
                                                     "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
                                                     "Name":  "SearchOrderConfig",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1"
                                                 },
                                                 {
                                                     "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
                                                     "Name":  "DisableCoInstallers",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0"
                                                 }
                                             ],
                                "InvokeScript":  [
                                                     "\r\n      $RazerPath = \"C:\\Windows\\Installer\\Razer\"\r\n\r\n      if (Test-Path $RazerPath) {\r\n        Remove-Item $RazerPath\\* -Recurse -Force\r\n      } else {\r\n        New-Item -Path $RazerPath -ItemType Directory\r\n      }\r\n\r\n      icacls $RazerPath /deny \"Everyone:(W)\"\r\n      "
                                                 ],
                                "UndoScript":  [
                                                   "\r\n      icacls \"C:\\Windows\\Installer\\Razer\" /remove:d Everyone\r\n      "
                                               ],
                                "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/razerblock"
                            },
    "WPFTweaksDisableNotifications":  {
                                          "Content":  "Notificaciones de Bandeja de Sistema y Calendario - Desactivar",
                                          "Description":  "Desactiva todas las notificaciones INCLUYENDO el Calendario.",
                                          "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                          "panel":  "1",
                                          "registry":  [
                                                           {
                                                               "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
                                                               "Name":  "DisableNotificationCenter",
                                                               "Value":  "1",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                           },
                                                           {
                                                               "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
                                                               "Name":  "ToastEnabled",
                                                               "Value":  "0",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "1"
                                                           }
                                                       ],
                                          "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/disablenotifications"
                                      },
    "WPFTweaksBlockAdobeNet":  {
                                   "Content":  "Lista de Bloqueo de URLs de Adobe - Activar",
                                   "Description":  "Reduce interrupciones del usuario bloqueando selectivamente conexiones a servidores de activación y telemetría de Adobe. Crédito: Ruddernation-Designs",
                                   "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                   "panel":  "1",
                                   "InvokeScript":  [
                                                        "\r\n      $hostsUrl = \"https://github.com/Ruddernation-Designs/Adobe-URL-Block-List/raw/refs/heads/master/hosts\"\r\n      $hosts = \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\"\r\n\r\n      Move-Item $hosts \"$hosts.bak\"\r\n      Invoke-WebRequest $hostsUrl -OutFile $hosts\r\n      ipconfig /flushdns\r\n\r\n      Write-Host \"Added Adobe url block list from host file\"\r\n      "
                                                    ],
                                   "UndoScript":  [
                                                      "\r\n      $hosts = \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\"\r\n\r\n      Remove-Item $hosts\r\n      Move-Item \"$hosts.bak\" $hosts\r\n      ipconfig /flushdns\r\n\r\n      Write-Host \"Removed Adobe url block list from host file\"\r\n      "
                                                  ],
                                   "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/blockadobenet"
                               },
    "WPFTweaksRightClickMenu":  {
                                    "Content":  "Diseño Anterior de Menú de Clic Derecho - Activar",
                                    "Description":  "Restaura el menú contextual clásico al hacer clic derecho en el Explorador de Archivos, reemplazando la versión simplificada de Windows 11.",
                                    "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                    "panel":  "1",
                                    "InvokeScript":  [
                                                         "\r\n      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name \"InprocServer32\" -force -value \"\"\r\n      Write-Host Restarting explorer.exe ...\r\n      Stop-Process -Name \"explorer\" -Force\r\n      "
                                                     ],
                                    "UndoScript":  [
                                                       "\r\n      Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse -Confirm:$false -Force\r\n      # Restarting Explorer in the Undo Script might not be necessary, as the Registry change without restarting Explorer does work, but just to make sure.\r\n      Write-Host Restarting explorer.exe ...\r\n      Stop-Process -Name \"explorer\" -Force\r\n      "
                                                   ],
                                    "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/rightclickmenu"
                                },
    "WPFTweaksDiskCleanup":  {
                                 "Content":  "Liberador de Espacio en Disco - Ejecutar",
                                 "Description":  "Ejecuta el Liberador de Espacio en Disco en la unidad C: y elimina antiguas actualizaciones de Windows.",
                                 "category":  "Ajustes Esenciales",
                                 "panel":  "1",
                                 "InvokeScript":  [
                                                      "\r\n      cleanmgr.exe /d C: /VERYLOWDISK\r\n      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase\r\n      "
                                                  ],
                                 "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/diskcleanup"
                             },
    "WPFTweaksDeleteTempFiles":  {
                                     "Content":  "Archivos Temporales - Eliminar",
                                     "Description":  "Borra las carpetas TEMP.",
                                     "category":  "Ajustes Esenciales",
                                     "panel":  "1",
                                     "InvokeScript":  [
                                                          "\r\n      Remove-Item -Path \"$Env:Temp\\*\" -Recurse -Force\r\n      Remove-Item -Path \"$Env:SystemRoot\\Temp\\*\" -Recurse -Force\r\n      "
                                                      ],
                                     "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/deletetempfiles"
                                 },
    "WPFTweaksIPv46":  {
                           "Content":  "IPv6 - Establecer IPv4 como Preferido",
                           "Description":  "Dar preferencia a IPv4 puede tener beneficios de latencia y seguridad en redes privadas donde IPv6 no está configurado.",
                           "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                           "panel":  "1",
                           "registry":  [
                                            {
                                                "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                "Name":  "DisabledComponents",
                                                "Value":  "32",
                                                "Type":  "DWord",
                                                "OriginalValue":  "0"
                                            }
                                        ],
                           "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/ipv46"
                       },
    "WPFTweaksTeredo":  {
                            "Content":  "Teredo - Desactivar",
                            "Description":  "Teredo network tunneling es una función IPv6 que puede causar latencia adicional, pero desactivarlo puede causar problemas con algunos juegos.",
                            "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                            "panel":  "1",
                            "registry":  [
                                             {
                                                 "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                 "Name":  "DisabledComponents",
                                                 "Value":  "1",
                                                 "Type":  "DWord",
                                                 "OriginalValue":  "0"
                                             }
                                         ],
                            "InvokeScript":  [
                                                 "netsh interface teredo set state disabled"
                                             ],
                            "UndoScript":  [
                                               "netsh interface teredo set state default"
                                           ],
                            "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/teredo"
                        },
    "WPFTweaksDisableIPv6":  {
                                 "Content":  "IPv6 - Desactivar",
                                 "Description":  "Desactiva IPv6.",
                                 "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                 "panel":  "1",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                      "Name":  "DisabledComponents",
                                                      "Value":  "255",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "0"
                                                  }
                                              ],
                                 "InvokeScript":  [
                                                      "Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
                                                  ],
                                 "UndoScript":  [
                                                    "Enable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
                                                ],
                                 "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/disableipv6"
                             },
    "WPFTweaksDisableBGapps":  {
                                   "Content":  "Aplicaciones en Segundo Plano - Desactivar",
                                   "Description":  "Desactiva la ejecución en segundo plano de todas las aplicaciones de la Tienda de Microsoft.",
                                   "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                   "panel":  "1",
                                   "registry":  [
                                                    {
                                                        "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
                                                        "Name":  "GlobalUserDisabled",
                                                        "Value":  "1",
                                                        "Type":  "DWord",
                                                        "OriginalValue":  "0"
                                                    }
                                                ],
                                   "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/disablebgapps"
                               },
    "WPFTweaksDisableFSO":  {
                                "Content":  "Optimizaciones de Pantalla Completa - Desactivar",
                                "Description":  "Desactiva FSO en todas las aplicaciones. NOTA: Esto desactivará la gestión de color en pantalla completa exclusiva.",
                                "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                                "panel":  "1",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\System\\GameConfigStore",
                                                     "Name":  "GameDVR_DXGIHonorFSEWindowsCompatible",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0"
                                                 }
                                             ],
                                "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/disablefso"
                            },
    "WPFToggleDisableCrossDeviceResume":  {
                                              "Content":  "Reanudación Entre Dispositivos",
                                              "Description":  "Controla la función de Reanudación en Windows 11 24H2 y posteriores, que permite reanudar una actividad desde un dispositivo móvil y viceversa.",
                                              "category":  "Personalizar Preferencias",
                                              "panel":  "2",
                                              "Type":  "Toggle",
                                              "registry":  [
                                                               {
                                                                   "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\CrossDeviceResume\\Configuration",
                                                                   "Name":  "IsResumeAllowed",
                                                                   "Value":  "1",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "0",
                                                                   "DefaultState":  "true"
                                                               }
                                                           ],
                                              "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/disablecrossdeviceresume"
                                          },
    "WPFToggleDetailedBSoD":  {
                                  "Content":  "Modo Detallado BSoD (Pantalla Azul)",
                                  "Description":  "Si está habilitado, verás una Pantalla Azul de la Muerte (BSOD) detallada con más información.",
                                  "category":  "Personalizar Preferencias",
                                  "panel":  "2",
                                  "Type":  "Toggle",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
                                                       "Name":  "DisplayParameters",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
                                                       "Name":  "DisableEmoticon",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   }
                                               ],
                                  "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/detailedbsod"
                              },
    "WPFToggleBatteryPercentage":  {
                                       "Content":  "Porcentaje de Batería en Bandeja de Sistema",
                                       "Description":  "Si está habilitado, muestra el porcentaje numérico de batería junto al ícono en la bandeja del sistema.",
                                       "category":  "Personalizar Preferencias",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                            "Name":  "IsBatteryPercentageEnabled",
                                                            "Value":  "1",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                            "DefaultState":  "false"
                                                        }
                                                    ],
                                       "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/batterypercentage"
                                   },
    "WPFToggleDarkMode":  {
                              "Content":  "Tema Oscuro para Windows",
                              "Description":  "Activar/Desactivar Tema Oscuro.",
                              "category":  "Personalizar Preferencias",
                              "panel":  "2",
                              "Type":  "Toggle",
                              "registry":  [
                                               {
                                                   "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                                   "Name":  "AppsUseLightTheme",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1",
                                                   "DefaultState":  "false"
                                               },
                                               {
                                                   "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                                   "Name":  "SystemUsesLightTheme",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1",
                                                   "DefaultState":  "false"
                                               }
                                           ],
                              "InvokeScript":  [
                                                   "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
                                               ],
                              "UndoScript":  [
                                                 "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
                                             ],
                              "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/darkmode"
                          },
    "WPFToggleShowExt":  {
                             "Content":  "Extensiones de Archivos del Explorador",
                             "Description":  "Si está habilitado, las extensiones de archivos (ej. .txt, .jpg) serán visibles.",
                             "category":  "Personalizar Preferencias",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "HideFileExt",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "InvokeScript":  [
                                                  "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                              ],
                             "UndoScript":  [
                                                "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                            ],
                             "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/showext"
                         },
    "WPFToggleHiddenFiles":  {
                                 "Content":  "Archivos Ocultos del Explorador",
                                 "Description":  "Si está habilitado, se mostrarán los archivos ocultos.",
                                 "category":  "Personalizar Preferencias",
                                 "panel":  "2",
                                 "Type":  "Toggle",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                      "Name":  "Hidden",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "0",
                                                      "DefaultState":  "false"
                                                  }
                                              ],
                                 "InvokeScript":  [
                                                      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                  ],
                                 "UndoScript":  [
                                                    "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                ],
                                 "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/hiddenfiles"
                             },
    "WPFToggleVerboseLogon":  {
                                  "Content":  "Modo de Inicio de Sesión Detallado",
                                  "Description":  "Muestra mensajes detallados durante el proceso de inicio de sesión para solución de problemas.",
                                  "category":  "Personalizar Preferencias",
                                  "panel":  "2",
                                  "Type":  "Toggle",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
                                                       "Name":  "VerboseStatus",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   }
                                               ],
                                  "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/verboselogon"
                              },
    "WPFToggleNewOutlook":  {
                                "Content":  "Microsoft Outlook Nueva Versión",
                                "Description":  "Si está desactivado, elimina el interruptor del nuevo Outlook, desactiva la migración al nuevo Outlook y asegura que se use la aplicación clásica.",
                                "category":  "Personalizar Preferencias",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
                                                     "Name":  "UseNewOutlook",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
                                                     "Name":  "HideNewOutlookToggle",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1",
                                                     "DefaultState":  "true"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
                                                     "Name":  "DoNewOutlookAutoMigration",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "false"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
                                                     "Name":  "NewOutlookMigrationUserSetting",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/newoutlook"
                            },
    "WPFToggleScrollbars":  {
                                "Content":  "Barras de Desplazamiento Siempre Visibles",
                                "Description":  "Si está habilitado, las barras de desplazamiento siempre estarán visibles. Si está deshabilitado, Windows las ocultará automáticamente cuando no se usen.",
                                "category":  "Personalizar Preferencias",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Control Panel\\Accessibility",
                                                     "Name":  "DynamicScrollbars",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1",
                                                     "DefaultState":  "false",
                                                     "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/scrollbars"
                                                 }
                                             ],
                                "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/scrollbars"
                            },
    "WPFToggleMultiplaneOverlay":  {
                                       "Content":  "Superposición Multiplano (Multiplane Overlay)",
                                       "Description":  "Activa o desactiva la Superposición Multiplano, que a veces puede causar problemas con tarjetas gráficas.",
                                       "category":  "Personalizar Preferencias",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
                                                            "Name":  "OverlayTestMode",
                                                            "Value":  "0",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "5",
                                                            "DefaultState":  "true"
                                                        }
                                                    ],
                                       "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/multiplaneoverlay"
                                   },
    "WPFToggleMouseAcceleration":  {
                                       "Content":  "Aceleración del Ratón",
                                       "Description":  "Si está habilitado, el movimiento del cursor se ve afectado por la velocidad de tus movimientos físicos con el ratón.",
                                       "category":  "Personalizar Preferencias",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseSpeed",
                                                            "Value":  "1",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        },
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseThreshold1",
                                                            "Value":  "6",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        },
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseThreshold2",
                                                            "Value":  "10",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        }
                                                    ],
                                       "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/mouseacceleration"
                                   },
    "WPFToggleNumLock":  {
                             "Content":  "Bloqueo Numérico al Iniciar",
                             "Description":  "Alterna el estado de la tecla Bloqueo Numérico cuando tu computadora inicia.",
                             "category":  "Personalizar Preferencias",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKU:\\.Default\\Control Panel\\Keyboard",
                                                  "Name":  "InitialKeyboardIndicators",
                                                  "Value":  "2",
                                                  "Type":  "String",
                                                  "OriginalValue":  "0",
                                                  "DefaultState":  "false"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Keyboard",
                                                  "Name":  "InitialKeyboardIndicators",
                                                  "Value":  "2",
                                                  "Type":  "String",
                                                  "OriginalValue":  "0",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/numlock"
                         },
    "WPFToggleStandbyFix":  {
                                "Content":  "Conectividad de Red en Suspensión S0",
                                "Description":  "Activa o desactiva la conectividad de red durante la suspensión S0.",
                                "category":  "Personalizar Preferencias",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Power\\PowerSettings\\f15576e8-98b7-4186-b944-eafa664402d9",
                                                     "Name":  "ACSettingIndex",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/standbyfix"
                            },
    "WPFToggleS3Sleep":  {
                             "Content":  "Suspensión S3",
                             "Description":  "Alterna entre Modo de Espera Moderno y Suspensión S3.",
                             "category":  "Personalizar Preferencias",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power",
                                                  "Name":  "PlatformAoAcOverride",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/s3sleep"
                         },
    "WPFToggleHideSettingsHome":  {
                                      "Content":  "Página de Inicio de Configuración",
                                      "Description":  "Activa o desactiva la Página de Inicio en la aplicación Configuración de Windows.",
                                      "category":  "Personalizar Preferencias",
                                      "panel":  "2",
                                      "Type":  "Toggle",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
                                                           "Name":  "SettingsPageVisibility",
                                                           "Value":  "show:home",
                                                           "Type":  "String",
                                                           "OriginalValue":  "hide:home",
                                                           "DefaultState":  "true"
                                                       }
                                                   ],
                                      "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/hidesettingshome"
                                  },
    "WPFToggleBingSearch":  {
                                "Content":  "Búsqueda de Bing en Menú Inicio",
                                "Description":  "Si está habilitado, los resultados de búsqueda web de Bing se incluirán en tu búsqueda del Menú Inicio.",
                                "category":  "Personalizar Preferencias",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                     "Name":  "BingSearchEnabled",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/bingsearch"
                            },
    "WPFToggleLoginBlur":  {
                               "Content":  "Desenfoque Acrílico en Pantalla de Inicio de Sesión",
                               "Description":  "Si está desactivado, el efecto de desenfoque acrílico se eliminará del fondo de la pantalla de inicio de sesión de Windows 10/11.",
                               "category":  "Personalizar Preferencias",
                               "panel":  "2",
                               "Type":  "Toggle",
                               "registry":  [
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                    "Name":  "DisableAcrylicBackgroundOnLogon",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "1",
                                                    "DefaultState":  "true"
                                                }
                                            ],
                               "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/loginblur"
                           },
    "WPFToggleStartMenuRecommendations":  {
                                              "Content":  "Recomendaciones del Menú Inicio",
                                              "Description":  "Si está desactivado, no verás recomendaciones en el Menú Inicio. ADVERTENCIA: Esto también desactivará Contenido Destacado de Windows (Spotlight) en tu Pantalla de Bloqueo.",
                                              "category":  "Personalizar Preferencias",
                                              "panel":  "2",
                                              "Type":  "Toggle",
                                              "registry":  [
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
                                                                   "Name":  "HideRecommendedSection",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               },
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
                                                                   "Name":  "IsEducationEnvironment",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               },
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
                                                                   "Name":  "HideRecommendedSection",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               }
                                                           ],
                                              "InvokeScript":  [
                                                                   "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                               ],
                                              "UndoScript":  [
                                                                 "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                             ],
                                              "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/startmenurecommendations"
                                          },
    "WPFToggleStickyKeys":  {
                                "Content":  "Teclas Especiales (Sticky Keys)",
                                "Description":  "Si está habilitado, las Teclas Especiales se activan. Es una función de accesibilidad que ayuda a los usuarios con discapacidades físicas o para reducir lesiones por esfuerzo repetitivo.",
                                "category":  "Personalizar Preferencias",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
                                                     "Name":  "Flags",
                                                     "Value":  "506",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "58",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/stickykeys"
                            },
    "WPFToggleTaskbarAlignment":  {
                                      "Content":  "Iconos Centrados en Barra de Tareas",
                                      "Description":  "[Windows 11] Si está habilitado, los elementos de la Barra de Tareas se mostrarán en el Centro; de lo contrario, se mostrarán a la Izquierda.",
                                      "category":  "Personalizar Preferencias",
                                      "panel":  "2",
                                      "Type":  "Toggle",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                           "Name":  "TaskbarAl",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "0",
                                                           "DefaultState":  "true"
                                                       }
                                                   ],
                                      "InvokeScript":  [
                                                           "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                       ],
                                      "UndoScript":  [
                                                         "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                     ],
                                      "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/taskbaralignment"
                                  },
    "WPFToggleTaskbarSearch":  {
                                   "Content":  "Ícono de Búsqueda en Barra de Tareas",
                                   "Description":  "Si está habilitado, el botón de Búsqueda estará en la Barra de Tareas.",
                                   "category":  "Personalizar Preferencias",
                                   "panel":  "2",
                                   "Type":  "Toggle",
                                   "registry":  [
                                                    {
                                                        "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                        "Name":  "SearchboxTaskbarMode",
                                                        "Value":  "1",
                                                        "Type":  "DWord",
                                                        "OriginalValue":  "0",
                                                        "DefaultState":  "true"
                                                    }
                                                ],
                                   "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/taskbarsearch"
                               },
    "WPFToggleTaskView":  {
                              "Content":  "Ícono de Vista de Tareas en Barra de Tareas",
                              "Description":  "Si está habilitado, el botón de Vista de Tareas se mostrará en la Barra de Tareas.",
                              "category":  "Personalizar Preferencias",
                              "panel":  "2",
                              "Type":  "Toggle",
                              "registry":  [
                                               {
                                                   "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                   "Name":  "ShowTaskViewButton",
                                                   "Value":  "1",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "0",
                                                   "DefaultState":  "true"
                                               }
                                           ],
                              "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/customize-preferences/taskview"
                          },
    "WPFOOSUbutton":  {
                          "Content":  "O\u0026O ShutUp10++ - Ejecutar",
                          "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                          "panel":  "1",
                          "Type":  "Button",
                          "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/oosubutton"
                      },
    "WPFchangedns":  {
                         "Content":  "DNS - Establecer en:",
                         "category":  "z__Ajustes Avanzados - PRECAUCIÓN",
                         "panel":  "1",
                         "Type":  "Combobox",
                         "ComboItems":  "Default DHCP Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult",
                         "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/z--advanced-tweaks---caution/changedns"
                     },
    "WPFAddUltPerf":  {
                          "Content":  "Perfil de Máximo Rendimiento - Activar",
                          "category":  "Planes de Rendimiento",
                          "panel":  "2",
                          "Type":  "Button",
                          "ButtonWidth":  "300",
                          "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/performance-plans/addultperf"
                      },
    "WPFRemoveUltPerf":  {
                             "Content":  "Perfil de Máximo Rendimiento - Desactivar",
                             "category":  "Planes de Rendimiento",
                             "panel":  "2",
                             "Type":  "Button",
                             "ButtonWidth":  "300",
                             "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/performance-plans/removeultperf"
                         },
    "WPFTweaksDisableExplorerAutoDiscovery":  {
                                                  "Content":  "Descubrimiento Automático de Carpetas del Explorador - Desactivar",
                                                  "Description":  "El Explorador intenta adivinar automáticamente el tipo de carpeta según su contenido, ralentizando la navegación. ¡ADVERTENCIA! Esto desactivará la agrupación del Explorador.",
                                                  "category":  "Ajustes Esenciales",
                                                  "panel":  "1",
                                                  "InvokeScript":  [
                                                                       "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      # Every folder\r\n      $allFolders = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\\AllFolders\\Shell\"\r\n\r\n      if (!(Test-Path $allFolders)) {\r\n        New-Item -Path $allFolders -Force\r\n        Write-Host \"Created $allFolders\"\r\n      }\r\n\r\n      # Generic view\r\n      New-ItemProperty -Path $allFolders -Name \"FolderType\" -Value \"NotSpecified\" -PropertyType String -Force\r\n      Write-Host \"Set FolderType to NotSpecified\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
                                                                   ],
                                                  "UndoScript":  [
                                                                     "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
                                                                 ],
                                                  "link":  "https://servicepcglew-winutil.pages.dev/dev/tweaks/essential-tweaks/disableexplorerautodiscovery"
                                              }
}
'@ | ConvertFrom-Json
$inputXML = @'
<Window x:Class="WinUtility.MainWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:WinUtility"
        mc:Ignorable="d"
        WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True"
        WindowStyle="None"
        Width="Auto"
        Height="Auto"
        MinWidth="800"
        MinHeight="600"
        Title="WinUtil">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" CornerRadius="10"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
    <Style TargetType="ToolTip">
        <Setter Property="Background" Value="{DynamicResource ToolTipBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
        <Setter Property="MaxWidth" Value="{DynamicResource ToolTipWidth}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="2"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <!-- This ContentTemplate ensures that the content of the ToolTip wraps text properly for better readability -->
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <ContentPresenter Content="{TemplateBinding Content}">
                        <ContentPresenter.Resources>
                            <Style TargetType="TextBlock">
                                <Setter Property="TextWrapping" Value="Wrap"/>
                            </Style>
                        </ContentPresenter.Resources>
                    </ContentPresenter>
                </DataTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="{x:Type MenuItem}">
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <Setter Property="Padding" Value="5,2,5,2"/>
        <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <!--Scrollbar Thumbs-->
    <Style x:Key="ScrollThumbs" TargetType="{x:Type Thumb}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Thumb}">
                    <Grid x:Name="Grid">
                        <Rectangle HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto" Fill="Transparent" />
                        <Border x:Name="Rectangle1" CornerRadius="5" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto"  Background="{TemplateBinding Background}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Horizontal">
                            <Setter TargetName="Rectangle1" Property="Width" Value="Auto" />
                            <Setter TargetName="Rectangle1" Property="Height" Value="7" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="TextBlock" x:Key="HoverTextBlockStyle">
        <Setter Property="Foreground" Value="{DynamicResource LinkForegroundColor}" />
        <Setter Property="TextDecorations" Value="Underline" />
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource LinkHoverForegroundColor}" />
                <Setter Property="TextDecorations" Value="Underline" />
                <Setter Property="Cursor" Value="Hand" />
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="AppEntryBorderStyle" TargetType="Border">
        <Setter Property="BorderBrush" Value="Gray"/>
        <Setter Property="BorderThickness" Value="{DynamicResource AppEntryBorderThickness}"/>
        <Setter Property="CornerRadius" Value="2"/>
        <Setter Property="Padding" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Width" Value="{DynamicResource AppEntryWidth}"/>
        <Setter Property="VerticalAlignment" Value="Top"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Background" Value="{DynamicResource AppInstallUnselectedColor}"/>
    </Style>
    <Style x:Key="AppEntryCheckboxStyle" TargetType="CheckBox">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="HorizontalAlignment" Value="Left"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <StackPanel Orientation="Horizontal">
                        <Grid Width="16" Height="16" Margin="0,0,8,0">
                            <Border x:Name="CheckBoxBorder"
                                    BorderBrush="{DynamicResource MainForegroundColor}"
                                    Background="{DynamicResource ButtonBackgroundColor}"
                                    BorderThickness="1"
                                    Width="12"
                                    Height="12"
                                    CornerRadius="2"/>
                            <Path x:Name="CheckMark"
                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                  StrokeThickness="2"
                                  Data="M 2 8 L 6 12 L 14 4"
                                  Visibility="Collapsed"/>
                        </Grid>
                        <ContentPresenter Content="{TemplateBinding Content}"
                                        VerticalAlignment="Center"
                                        HorizontalAlignment="Left"
                                        IsHitTestVisible="False"/>
                    </StackPanel>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="AppEntryNameStyle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="{DynamicResource AppEntryFontSize}"/>
        <Setter Property="FontWeight" Value="Bold"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Background" Value="Transparent"/>
    </Style>
    <Style x:Key="AppEntryButtonStyle" TargetType="Button">
        <Setter Property="Width" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Height" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
        <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
        <Setter Property="HorizontalAlignment" Value="Center"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <TextBlock  Text="{Binding}"
                                FontFamily="Segoe MDL2 Assets"
                                FontSize="{DynamicResource IconFontSize}"
                                Background="Transparent"/>
                </DataTemplate>
            </Setter.Value>
        </Setter>
        <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Cursor" Value="Hand"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>


    </Style>
    <Style TargetType="Button" x:Key="HoverButtonStyle">
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="FontWeight" Value="Normal" />
        <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
        <Setter Property="TextElement.FontFamily" Value="{DynamicResource ButtonFontFamily}"/>
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="FontWeight" Value="Bold" />
                            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
                            <Setter Property="Cursor" Value="Hand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!--ScrollBars-->
    <Style x:Key="{x:Type ScrollBar}" TargetType="{x:Type ScrollBar}">
        <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
        <Setter Property="Foreground" Value="{DynamicResource ScrollBarBackgroundColor}" />
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Width" Value="6" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                    <Grid x:Name="GridRoot" Width="7" Background="{TemplateBinding Background}" >
                        <Grid.RowDefinitions>
                            <RowDefinition Height="0.00001*" />
                        </Grid.RowDefinitions>

                        <Track x:Name="PART_Track" Grid.Row="0" IsDirectionReversed="true" Focusable="false">
                            <Track.Thumb>
                                <Thumb x:Name="Thumb" Background="{TemplateBinding Foreground}" Style="{DynamicResource ScrollThumbs}" />
                            </Track.Thumb>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton x:Name="PageUp" Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="false" />
                            </Track.IncreaseRepeatButton>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton x:Name="PageDown" Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="false" />
                            </Track.DecreaseRepeatButton>
                        </Track>
                    </Grid>

                    <ControlTemplate.Triggers>
                        <Trigger SourceName="Thumb" Property="IsMouseOver" Value="true">
                            <Setter Value="{DynamicResource ScrollBarHoverColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>
                        <Trigger SourceName="Thumb" Property="IsDragging" Value="true">
                            <Setter Value="{DynamicResource ScrollBarDraggingColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>

                        <Trigger Property="IsEnabled" Value="false">
                            <Setter TargetName="Thumb" Property="Visibility" Value="Collapsed" />
                        </Trigger>
                        <Trigger Property="Orientation" Value="Horizontal">
                            <Setter TargetName="GridRoot" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter TargetName="PART_Track" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter Property="Width" Value="Auto" />
                            <Setter Property="Height" Value="8" />
                            <Setter TargetName="Thumb" Property="Tag" Value="Horizontal" />
                            <Setter TargetName="PageDown" Property="Command" Value="ScrollBar.PageLeftCommand" />
                            <Setter TargetName="PageUp" Property="Command" Value="ScrollBar.PageRightCommand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}" />
            <Setter Property="MinWidth"   Value="{DynamicResource ButtonWidth}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border x:Name="OuterBorder"
                                    BorderBrush="{DynamicResource BorderColor}"
                                    BorderThickness="1"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}"
                                    Background="{TemplateBinding Background}">
                                <ToggleButton x:Name="ToggleButton"
                                              Background="Transparent"
                                              BorderThickness="0"
                                              IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                              ClickMode="Press">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0"
                                                   Text="{TemplateBinding SelectionBoxItem}"
                                                   Foreground="{TemplateBinding Foreground}"
                                                   Background="Transparent"
                                                   HorizontalAlignment="Left" VerticalAlignment="Center"
                                                   Margin="6,3,2,3"/>
                                        <Path Grid.Column="1"
                                              Data="M 0,0 L 8,0 L 4,5 Z"
                                              Fill="{TemplateBinding Foreground}"
                                              Width="8" Height="5"
                                              VerticalAlignment="Center"
                                              HorizontalAlignment="Center"
                                              Stretch="Uniform"
                                              Margin="4,0,6,0"/>
                                    </Grid>
                                </ToggleButton>
                            </Border>
                            <Popup x:Name="Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   Focusable="False"
                                   AllowsTransparency="True"
                                   PopupAnimation="Slide">
                                <Border x:Name="DropDownBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1"
                                        CornerRadius="4">
                                    <ScrollViewer>
                                        <ItemsPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="4,2"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        </Style>

        <!-- TextBlock template -->
        <Style TargetType="TextBlock">
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
        </Style>
        <!-- Toggle button template x:Key="TabToggleButton" -->
        <Style TargetType="{x:Type ToggleButton}">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Content" Value=""/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border x:Name="ButtonGlow"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonForegroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <Border x:Name="BackgroundBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonBackgroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                        <ContentPresenter
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"
                                            Margin="10,2,10,2"/>
                                    </Border>
                                </Grid>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="5" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-100" BlurRadius="15"/>
                                    </Setter.Value>
                                </Setter>
                                <Setter Property="Panel.ZIndex" Value="2000"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter Property="BorderBrush" Value="Pink"/>
                                <Setter Property="BorderThickness" Value="2"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="2" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-111" BlurRadius="10"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="False">
                                <Setter Property="BorderBrush" Value="Transparent"/>
                                <Setter Property="BorderThickness" Value="{DynamicResource ButtonBorderThickness}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Button Template -->
        <Style TargetType="Button">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <!-- Toggle Dot Background -->
                                    <Ellipse Width="8" Height="16"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0" />

                                    <!-- Toggle Dot with hover grow effect -->
                                    <Ellipse x:Name="ToggleDot"
                                            Width="8" Height="8"
                                            Fill="{DynamicResource ButtonForegroundColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0"
                                            RenderTransformOrigin="0.5,0.5">
                                        <Ellipse.RenderTransform>
                                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                                        </Ellipse.RenderTransform>
                                    </Ellipse>

                                    <!-- Content Presenter -->
                                    <ContentPresenter HorizontalAlignment="Center"
                                                    VerticalAlignment="Center"
                                                    Margin="10,2,10,2"/>
                                </Grid>
                            </Border>
                        </Grid>

                        <!-- Triggers for ToggleButton states -->
                        <ControlTemplate.Triggers>
                            <!-- Hover effect -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to grow the dot when hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to shrink the dot back to original size when not hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>

                            <!-- IsChecked state -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ToggleDot" Property="VerticalAlignment" Value="Bottom"/>
                                <Setter TargetName="ToggleDot" Property="Margin" Value="0,0,5,3"/>
                            </Trigger>

                            <!-- IsEnabled state -->
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SearchBarClearButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="FontSize" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Content" Value="X"/>
            <Setter Property="Height" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Width" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="Red"/>
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="BorderThickness" Value="10"/>
                    <Setter Property="Cursor" Value="Hand"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Checkbox template -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="TextElement.FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Background="Transparent" Margin="{DynamicResource CheckBoxMargin}">
                            <BulletDecorator Background="Transparent">
                                <BulletDecorator.Bullet>
                                    <Grid Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                        <Border x:Name="Border"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                Background="{DynamicResource ButtonBackgroundColor}"
                                                BorderThickness="1"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Margin="1"
                                                SnapsToDevicePixels="True"/>
                                        <Viewbox x:Name="CheckMarkContainer"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                HorizontalAlignment="Center"
                                                VerticalAlignment="Center"
                                                Visibility="Collapsed">
                                            <Path x:Name="CheckMark"
                                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                                  StrokeThickness="1.5"
                                                  Data="M 0 5 L 5 10 L 12 0"
                                                  Stretch="Uniform"/>
                                        </Viewbox>
                                    </Grid>
                                </BulletDecorator.Bullet>
                                <ContentPresenter Margin="4,0,0,0"
                                                  HorizontalAlignment="Left"
                                                  VerticalAlignment="Center"
                                                  RecognizesAccessKey="True"
                                                  IsHitTestVisible="False"/>
                            </BulletDecorator>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckMarkContainer" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <!--Setter TargetName="Border" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/-->
                                <Setter Property="Foreground" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                 </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <StackPanel Orientation="Horizontal" Margin="{DynamicResource CheckBoxMargin}">
                            <Viewbox Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                <Grid Width="14" Height="14">
                                    <Ellipse x:Name="OuterCircle"
                                            Stroke="{DynamicResource ToggleButtonOffColor}"
                                            Fill="{DynamicResource ButtonBackgroundColor}"
                                            StrokeThickness="1"
                                            Width="14"
                                            Height="14"
                                            SnapsToDevicePixels="True"/>
                                    <Ellipse x:Name="InnerCircle"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            Width="8"
                                            Height="8"
                                            Visibility="Collapsed"
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"/>
                                </Grid>
                            </Viewbox>
                            <ContentPresenter Margin="4,0,0,0"
                                            VerticalAlignment="Center"
                                            RecognizesAccessKey="True"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="InnerCircle" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="OuterCircle" Property="Stroke" Value="{DynamicResource ToggleButtonOnColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel>
                            <Grid>
                                <Border Width="45"
                                        Height="20"
                                        Background="#555555"
                                        CornerRadius="10"
                                        Margin="5,0"
                                />
                                <Border Name="WPFToggleSwitchButton"
                                        Width="25"
                                        Height="25"
                                        Background="Black"
                                        CornerRadius="12.5"
                                        HorizontalAlignment="Left"
                                />
                                <ContentPresenter Name="WPFToggleSwitchContent"
                                                  Margin="10,0,0,0"
                                                  Content="{TemplateBinding Content}"
                                                  VerticalAlignment="Center"
                                />
                            </Grid>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="false">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchLeft" />
                                    <BeginStoryboard x:Name="WPFToggleSwitchRight">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="0,0,0,0"
                                                    To="28,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#fff9f4f4"
                                />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="true">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchRight" />
                                    <BeginStoryboard x:Name="WPFToggleSwitchLeft">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="28,0,0,0"
                                                    To="0,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#ff060600"
                                />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ColorfulToggleSwitchStyle" TargetType="{x:Type CheckBox}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Grid x:Name="toggleSwitch">

                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="1" x:Name="Border" CornerRadius="8"
                                BorderThickness="1"
                                Width="34" Height="17">
                            <Ellipse x:Name="Ellipse" Fill="{DynamicResource MainForegroundColor}" Stretch="Uniform"
                                    Margin="2,2,2,1"
                                    HorizontalAlignment="Left" Width="10.8"
                                    RenderTransformOrigin="0.5, 0.5">
                                <Ellipse.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1" />
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                        </Grid>

                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource LinkHoverForegroundColor}"/>
                                <Setter Property="Cursor" Value="Hand" />
                                <Setter Property="Panel.ZIndex" Value="1000"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.1" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="ToggleButton.IsChecked" Value="False">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource MainBackgroundColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOffColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="{DynamicResource ToggleButtonOffColor}" />
                            </Trigger>

                            <Trigger Property="ToggleButton.IsChecked" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="White" />

                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="18,2,2,2" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="2,2,2,1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <Style x:Key="labelfortweaks" TargetType="{x:Type Label}">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="White" />
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="BorderStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="5"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="ContextMenu">
                <Setter.Value>
                    <ContextMenu>
                        <ContextMenu.Style>
                            <Style TargetType="ContextMenu">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ContextMenu">
                                            <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" Padding="5">
                                                <StackPanel>
                                                    <MenuItem Command="Cut" Header="Cut"/>
                                                    <MenuItem Command="Copy" Header="Copy"/>
                                                    <MenuItem Command="Paste" Header="Paste"/>
                                                </StackPanel>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ContextMenu.Style>
                    </ContextMenu>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer x:Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer x:Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollVisibilityRectangle" TargetType="Rectangle">
            <Setter Property="Visibility" Value="Collapsed"/>
            <Style.Triggers>
                <MultiDataTrigger>
                    <MultiDataTrigger.Conditions>
                        <Condition Binding="{Binding Path=ComputedHorizontalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                        <Condition Binding="{Binding Path=ComputedVerticalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                    </MultiDataTrigger.Conditions>
                    <Setter Property="Visibility" Value="Visible"/>
                </MultiDataTrigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <Grid Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Name="WPFMainGrid" Width="Auto" Height="Auto" HorizontalAlignment="Stretch">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <!-- Offline banner -->
        <Border Name="WPFOfflineBanner" Grid.Row="0" Background="#8B0000" Visibility="Collapsed" Padding="6,4">
            <TextBlock Text="&#x26A0; Offline Mode - No Internet Connection" Foreground="White" FontWeight="Bold"
                HorizontalAlignment="Center" FontSize="13" Background="Transparent"/>
        </Border>
        <Grid Grid.Row="1" Background="{DynamicResource MainBackgroundColor}">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/> <!-- Navigation buttons -->
                <ColumnDefinition Width="*"/> <!-- Search bar and buttons -->
            </Grid.ColumnDefinitions>

            <!-- Navigation Buttons Panel -->
            <StackPanel Name="NavDockPanel" Orientation="Horizontal" Grid.Column="0" Margin="5,5,10,5">
                <StackPanel Name="NavLogoPanel" Orientation="Horizontal" HorizontalAlignment="Left" Background="{DynamicResource MainBackgroundColor}" SnapsToDevicePixels="True" Margin="10,0,20,0">
                </StackPanel>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonInstallBackgroundColor}" Foreground="white" FontWeight="Bold" Name="WPFTab1BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonInstallForegroundColor}" >
                            <Underline>I</Underline>nstalar
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="Auto" MinWidth="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonInstallBackgroundColor}" Foreground="white" FontWeight="Bold" Name="WPFTab2BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonInstallForegroundColor}" Padding="10,0,10,0">
                            Web Apps (PWA)
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonTweaksBackgroundColor}" Foreground="{DynamicResource ButtonTweaksForegroundColor}" FontWeight="Bold" Name="WPFTab3BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonTweaksForegroundColor}">
                            <Underline>A</Underline>justes
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonConfigBackgroundColor}" Foreground="{DynamicResource ButtonConfigForegroundColor}" FontWeight="Bold" Name="WPFTab4BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonConfigForegroundColor}">
                            <Underline>C</Underline>onfiguración
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonUpdatesBackgroundColor}" Foreground="{DynamicResource ButtonUpdatesForegroundColor}" FontWeight="Bold" Name="WPFTab5BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonUpdatesForegroundColor}">
                            <Underline>A</Underline>ctualizaciones
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="Auto" MinWidth="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonWin11ISOBackgroundColor}" Foreground="{DynamicResource ButtonWin11ISOForegroundColor}" FontWeight="Bold" Name="WPFTab6BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonWin11ISOForegroundColor}">
                            Creador <Underline>W</Underline>in11
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
            </StackPanel>

            <!-- Search Bar and Action Buttons -->
            <Grid Name="GridBesideNavDockPanel" Grid.Column="1" Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Height="Auto">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*"/> <!-- Search bar area - priority space -->
                    <ColumnDefinition Width="Auto"/><!-- Buttons area -->
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Margin="5,0,0,0" Width="{DynamicResource SearchBarWidth}" Height="{DynamicResource SearchBarHeight}" VerticalAlignment="Center" HorizontalAlignment="Left">
                    <Grid>
                        <TextBox
                            Width="{DynamicResource SearchBarWidth}"
                            Height="{DynamicResource SearchBarHeight}"
                            FontSize="{DynamicResource SearchBarTextBoxFontSize}"
                            VerticalAlignment="Center" HorizontalAlignment="Left"
                            BorderThickness="1"
                            Name="SearchBar"
                            Foreground="{DynamicResource MainForegroundColor}" Background="{DynamicResource MainBackgroundColor}"
                            Padding="3,3,30,0"
                            ToolTip="Presiona Ctrl-F y escribe el nombre de la app para filtrar la lista. Presiona Esc para reiniciar el filtro">
                        </TextBox>
                        <TextBlock
                            VerticalAlignment="Center" HorizontalAlignment="Right"
                            FontFamily="Segoe MDL2 Assets"
                            Foreground="{DynamicResource ButtonBackgroundSelectedColor}"
                            FontSize="{DynamicResource IconFontSize}"
                            Margin="0,0,8,0" Width="Auto" Height="Auto">&#xE721;
                        </TextBlock>
                    </Grid>
                </Border>
                <Button Grid.Column="0"
                    VerticalAlignment="Center" HorizontalAlignment="Left"
                    Name="SearchBarClearButton"
                    Style="{StaticResource SearchBarClearButtonStyle}"
                    Margin="213,0,0,0" Visibility="Collapsed">
                </Button>

                <!-- Buttons Container -->
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="5,5,5,5">
                    <Button Name="ThemeButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="N/A"
                    ToolTip="Cambiar el tema visual de la interfaz"
                />
                    <Popup Name="ThemePopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=ThemeButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Automático" Name="AutoThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Seguir el tema de Windows"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Oscuro" Name="DarkThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Usar Tema Oscuro"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Claro" Name="LightThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Usar Tema Claro"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="FontScalingButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE8D3;"
                    ToolTip="Ajustar escala de fuente para accesibilidad"
                />
                    <Popup Name="FontScalingPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=FontScalingButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" MinWidth="200">
                            <TextBlock Text="Escala de Fuente"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,5,10,5"
                                       FontWeight="Bold"/>
                            <Separator Margin="5,0,5,5"/>
                            <StackPanel Orientation="Horizontal" Margin="10,5,10,10">
                                <TextBlock Text="Pequeña"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="0,0,10,0"/>
                                <Slider Name="FontScalingSlider"
                                        Minimum="0.75" Maximum="2.0"
                                        Value="1.0"
                                        TickFrequency="0.25"
                                        TickPlacement="BottomRight"
                                        IsSnapToTickEnabled="True"
                                        Width="120"
                                        VerticalAlignment="Center"/>
                                <TextBlock Text="Grande"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="10,0,0,0"/>
                            </StackPanel>
                            <TextBlock Name="FontScalingValue"
                                       Text="100%"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,0,10,5"/>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="10,0,10,10">
                                <Button Name="FontScalingResetButton"
                                        Content="Restablecer"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                                <Button Name="FontScalingApplyButton"
                                        Content="Aplicar"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="SettingsButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE713;"/>
                    <Popup Name="SettingsPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=SettingsButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Importar" Name="ImportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Importar configuración desde un archivo exportado."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Exportar" Name="ExportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Exportar los elementos seleccionados y copiar el comando de ejecución al portapapeles."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <Separator/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Acerca de" Name="AboutMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Documentación" Name="DocumentationMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Patrocinadores" Name="SponsorMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button
                    Content="&#xD7;" BorderThickness="0"
                BorderBrush="Transparent"
                Background="{DynamicResource MainBackgroundColor}"
                Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                HorizontalAlignment="Right" VerticalAlignment="Top"
                Margin="0,0,0,0"
                FontFamily="{DynamicResource FontFamily}"
                Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource CloseIconFontSize}" Name="WPFCloseButton" />
                </StackPanel>
            </Grid>
        </Grid>

        <TabControl Name="WPFTabNav" Background="Transparent" Width="Auto" Height="Auto" BorderBrush="Transparent" BorderThickness="0" Grid.Row="2" Grid.Column="0" Padding="-1">
            <TabItem Header="Instalar" Visibility="Collapsed" Name="WPFTab1">
                <Grid Background="Transparent" >

                    <Grid Grid.Row="0" Grid.Column="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>

                        <Grid Name="appscategory" Grid.Column="0" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>

                        <Grid Name="appspanel" Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem Header="Web Apps" Visibility="Collapsed" Name="WPFTab2">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    
                    <!-- Header -->
                    <StackPanel Grid.Row="0" Margin="25,20,25,10">
                        <TextBlock Text="Web Apps (PWA) - Aplicaciones en Ventana Dedicada" FontSize="{DynamicResource FontSize}" FontWeight="Bold" Foreground="{DynamicResource LabelboxForegroundColor}"/>
                        <TextBlock Text="Crea accesos directos de tus sitios favoritos para abrirlos instantáneamente como aplicaciones independientes sin marcos de navegador." FontSize="{DynamicResource FontSize}" Foreground="{DynamicResource MainForegroundColor}" Margin="0,5,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    
                    <!-- Grid of Web App Cards -->
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="10,0,10,20">
                        <WrapPanel HorizontalAlignment="Center">
                            <!-- Mercado Pago -->
                            <Border Style="{StaticResource AppEntryBorderStyle}" Name="WPFWebAppMercadoPago" ToolTip="Billetera virtual y plataforma de pagos.">
                                <TextBlock Style="{StaticResource AppEntryNameStyle}" Text="Mercado Pago" Margin="8,4,8,4"/>
                            </Border>

                            <!-- WhatsApp Web -->
                            <Border Style="{StaticResource AppEntryBorderStyle}" Name="WPFWebAppWhatsApp" ToolTip="Envía y recibe mensajes en tu computadora.">
                                <TextBlock Style="{StaticResource AppEntryNameStyle}" Text="WhatsApp Web" Margin="8,4,8,4"/>
                            </Border>

                            <!-- Gmail -->
                            <Border Style="{StaticResource AppEntryBorderStyle}" Name="WPFWebAppGmail" ToolTip="Acceso rápido a tu correo electrónico de Google.">
                                <TextBlock Style="{StaticResource AppEntryNameStyle}" Text="Gmail" Margin="8,4,8,4"/>
                            </Border>

                            <!-- YouTube -->
                            <Border Style="{StaticResource AppEntryBorderStyle}" Name="WPFWebAppYouTube" ToolTip="Disfruta de videos y música sin distracciones.">
                                <TextBlock Style="{StaticResource AppEntryNameStyle}" Text="YouTube" Margin="8,4,8,4"/>
                            </Border>
                        </WrapPanel>
                    </ScrollViewer>
                </Grid>
            </TabItem>
            <TabItem Header="Ajustes" Visibility="Collapsed" Name="WPFTab3">
                <Grid>
                    <!-- Main content area with a ScrollViewer -->
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Vertical" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Margin="5">
                                <Label Content="Selecciones Recomendadas:" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2"/>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,2,0,0">
                                    <Button Name="WPFstandard" Content=" Estándar " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFminimal" Content=" Mínimo " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFClearTweaksSelection" Content=" Limpiar " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFGetInstalledTweaks" Content=" Obtener Ajustes Instalados " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                </StackPanel>
                            </StackPanel>

                            <Grid Name="tweakspanel" Grid.Row="1">
                                <!-- Your tweakspanel content goes here -->
                            </Grid>

                            <Border Grid.ColumnSpan="2" Grid.Row="2" Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Padding="10">
                                        Nota: Pasa el cursor sobre los elementos para obtener una mejor descripción. Ten cuidado, ya que muchos de estos ajustes modificarán tu sistema profundamente.
                                        <LineBreak/>Las selecciones recomendadas son para usuarios normales, ¡si no estás seguro NO marques nada más!
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Grid.Column="0">
                            <Button Name="WPFTweaksbutton" Content="Ejecutar Ajustes" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                            <Button Name="WPFUndoall" Content="Deshacer Ajustes Seleccionados" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                        </WrapPanel>
                    </Border>
                </Grid>
            </TabItem>
            <TabItem Header="Configuración" Visibility="Collapsed" Name="WPFTab4">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Margin="{DynamicResource TabContentMargin}">
                    <Grid Name="featurespanel" Grid.Row="1" Background="Transparent">
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Actualizaciones" Visibility="Collapsed" Name="WPFTab5">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="{DynamicResource TabContentMargin}">
                    <Grid Background="Transparent" MaxWidth="{Binding ActualWidth, RelativeSource={RelativeSource AncestorType=ScrollViewer}}">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>  <!-- Row for the 3 columns -->
                            <RowDefinition Height="Auto"/>  <!-- Row for Windows Version -->
                        </Grid.RowDefinitions>

                        <!-- Three columns container -->
                        <Grid Grid.Row="0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <!-- Default Settings -->
                            <Border Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatesdefault"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Configuración Predeterminada"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">Configuración Predeterminada de Windows Update</Run>
                                        <LineBreak/>
                                         - Sin modificaciones en los valores predeterminados
                                        <LineBreak/>
                                         - Elimina cualquier configuración de actualización personalizada
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">Nota: Esto restablece la configuración de Windows Update a sus valores predeterminados de fábrica. Elimina CUALQUIER política o personalización que se haya hecho.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Security Settings -->
                            <Border Grid.Column="1" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatessecurity"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Configuración de Seguridad"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">Configuración de Seguridad Equilibrada</Run>
                                        <LineBreak/>
                                         - Actualizaciones de características retrasadas 365 días
                                        <LineBreak/>
                                         - Actualizaciones de seguridad instaladas después de 4 días
                                        <LineBreak/>
                                         - Evita que Windows Update instale controladores
                                        <LineBreak/><LineBreak/>
                                        <Run FontWeight="SemiBold">Actualizaciones de Características:</Run> Nuevas funciones y posibles errores
                                        <LineBreak/>
                                        <Run FontWeight="SemiBold">Actualizaciones de Seguridad:</Run> Parches críticos
                                    <LineBreak/><LineBreak/>
                                    <Run FontStyle="Italic" FontSize="11">Nota: Esto solo se aplica a sistemas Pro que pueden usar políticas de grupo.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Disable Updates -->
                            <Border Grid.Column="2" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatesdisable"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Deshabilitar Actualizaciones"
                                            Foreground="Red"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold" Foreground="Red">!! No Recomendado !!</Run>
                                        <LineBreak/>
                                         - Deshabilita TODAS las actualizaciones de Windows
                                        <LineBreak/>
                                         - Aumenta los riesgos de seguridad
                                        <LineBreak/>
                                         - Usar solo para sistemas aislados
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">Advertencia: Tu sistema será vulnerable sin actualizaciones de seguridad.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Future Implementation: Add Windows Version to updates panel -->
                        <Grid Name="updatespanel" Grid.Row="1" Background="Transparent">
                        </Grid>
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Win11ISO" Visibility="Collapsed" Name="WPFTab6">
                <Grid Name="Win11ISOPanel" Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>  <!-- Steps 1-4 -->
                        <RowDefinition Height="*"/>     <!-- Log / Status -->
                    </Grid.RowDefinitions>

                    <!-- Steps 1-4 -->
                    <StackPanel Grid.Row="0">

                            <!-- ─── STEP 1 : Select Windows 11 ISO ─────────────── -->
                            <Grid Name="WPFWin11ISOSelectSection" Margin="5" HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <!-- Left: File Selector -->
                                <StackPanel Grid.Column="0" Margin="5,5,15,5">
                                    <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                        Paso 1 - Seleccionar ISO de Windows 11
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}" Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,6">
                                        Busca tu archivo ISO de Windows 11 guardado localmente. Solo se admiten
                                        ISO oficiales descargadas de Microsoft.
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}" Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,12" FontStyle="Italic">
                                        <Run FontWeight="Bold">NOTA:</Run> Esto solo es para instalaciones Limpias y Nuevas de Windows.
                                    </TextBlock>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBox Grid.Column="0"
                                                 Name="WPFWin11ISOPath"
                                                 IsReadOnly="True"
                                                 VerticalAlignment="Center"
                                                 Padding="6,4"
                                                 Margin="0,0,6,0"
                                                 Text="Ninguna ISO seleccionada..."
                                                 Foreground="{DynamicResource MainForegroundColor}"
                                                 Background="{DynamicResource MainBackgroundColor}"/>
                                        <Button Grid.Column="1"
                                                Name="WPFWin11ISOBrowseButton"
                                                Content="Examinar"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"/>
                                    </Grid>
                                    <TextBlock Name="WPFWin11ISOFileInfo"
                                               FontSize="{DynamicResource FontSize}"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               Margin="0,8,0,0"
                                               TextWrapping="Wrap"
                                               Visibility="Collapsed"/>
                                </StackPanel>

                                <!-- Right: Download guidance -->
                                <Border Grid.Column="1"
                                        Background="{DynamicResource MainBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1" CornerRadius="5"
                                        Margin="5" Padding="15">
                                    <StackPanel>
                                        <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                                   Foreground="OrangeRed" Margin="0,0,0,10">
                                            !!ADVERTENCIA!! Debes usar una ISO oficial de Microsoft
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,8">
                                            Descarga la ISO de Windows 11 directamente desde Microsoft.com.
                                            Las imágenes de terceros, premodificadas o no oficiales no son compatibles
                                            y pueden fallar.
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,6">
                                            En la página de descarga de Microsoft, elige:
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="12,0,0,12">
                                            - Edición : Windows 11
                                            <LineBreak/>- Idioma : tu idioma preferido
                                            <LineBreak/>- Arquitectura : 64-bit (x64)
                                        </TextBlock>
                                        <Button Name="WPFWin11ISODownloadLink"
                                                Content="Abrir página de descargas de Microsoft"
                                                HorizontalAlignment="Left"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- ─── STEP 2 : Mount & Verify ISO ──────────────────── -->
                            <Grid Name="WPFWin11ISOMountSection"
                                  Margin="5"
                                  Visibility="Collapsed"
                                  HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0" Margin="0,0,20,0" VerticalAlignment="Top">
                                    <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                        Paso 2 - Montar y Verificar ISO
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,12" MaxWidth="320">
                                        Monta la ISO y confirma que contiene un install.wim de Windows 11
                                        válido antes de hacer modificaciones.
                                    </TextBlock>
                                    <Button Name="WPFWin11ISOMountButton"
                                            Content="Montar y Verificar ISO"
                                            HorizontalAlignment="Left"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                    <CheckBox Name="WPFWin11ISOInjectDrivers"
                                              Content="Inyectar controladores del sistema actual"
                                              FontSize="{DynamicResource FontSize}"
                                              Foreground="{DynamicResource MainForegroundColor}"
                                              IsChecked="False"
                                              Margin="0,8,0,0"
                                              ToolTip="Exporta todos los controladores de esta máquina y los inyecta en install.wim y boot.wim. Recomendado para sistemas con controladores de red o NVMe no compatibles."/>
                                </StackPanel>

                                <!-- Verification results panel -->
                                <Border Grid.Column="1"
                                        Name="WPFWin11ISOVerifyResultPanel"
                                        Background="{DynamicResource MainBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1" CornerRadius="5"
                                        Padding="12" Margin="0,0,0,0"
                                        Visibility="Collapsed">
                                    <StackPanel>
                                        <TextBlock Name="WPFWin11ISOMountDriveLetter"
                                                   FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,0,0,4"/>
                                        <TextBlock Name="WPFWin11ISOArchLabel"
                                                   FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,0,0,4"/>
                                        <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,6,0,4">
                                            Seleccionar Edición:
                                        </TextBlock>
                                        <ComboBox Name="WPFWin11ISOEditionComboBox"
                                                  FontSize="{DynamicResource FontSize}"
                                                  Foreground="{DynamicResource MainForegroundColor}"
                                                  Background="{DynamicResource MainBackgroundColor}"
                                                  HorizontalAlignment="Left"
                                                  Margin="0,0,0,0"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- ─── STEP 3 : Modify install.wim ───────────────────── -->
                            <StackPanel Name="WPFWin11ISOModifySection"
                                        Margin="5"
                                        Visibility="Collapsed"
                                        HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                    Paso 3 - Modificar install.wim
                                </TextBlock>
                                <TextBlock FontSize="{DynamicResource FontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           TextWrapping="Wrap" Margin="0,0,0,12">
                                    Los contenidos de la ISO se extraerán a un directorio temporal,
                                    install.wim será modificado (se eliminarán componentes, se aplicarán ajustes),
                                    y el resultado se reempaquetará. Este proceso puede tardar varios minutos
                                    dependiendo de tu hardware.
                                </TextBlock>
                                <Button Name="WPFWin11ISOModifyButton"
                                        Content="Ejecutar Creador y Modificación de ISO de Windows"
                                        HorizontalAlignment="Left"
                                        Width="Auto" Padding="12,0"
                                        Height="{DynamicResource ButtonHeight}"/>
                            </StackPanel>

                            <!-- ─── STEP 4 : Output Options ───────────────────────── -->
                            <StackPanel Name="WPFWin11ISOOutputSection"
                                        Margin="5"
                                        Visibility="Collapsed"
                                        HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <!-- Header row: title + Clean & Reset button -->
                                <Grid Margin="0,0,0,12">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               VerticalAlignment="Center">
                                        Paso 4 - Salida: ¿Qué te gustaría hacer con la imagen modificada?
                                    </TextBlock>
                                    <Button Grid.Column="1"
                                            Name="WPFWin11ISOCleanResetButton"
                                            Content="Limpiar y Restablecer"
                                            Foreground="OrangeRed"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"
                                            ToolTip="Eliminar el directorio de trabajo temporal y restablecer la interfaz al Paso 1"
                                            Margin="12,0,0,0"/>
                                </Grid>

                                <!-- ── Choice prompt buttons ── -->
                                <Grid Margin="0,0,0,12">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="16"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Button Grid.Column="0"
                                            Name="WPFWin11ISOChooseISOButton"
                                            Content="Guardar como archivo ISO"
                                            HorizontalAlignment="Stretch"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                    <Button Grid.Column="2"
                                            Name="WPFWin11ISOChooseUSBButton"
                                            Content="Escribir Directamente a un USB (BORRA EL DISCO)"
                                            Foreground="OrangeRed"
                                            HorizontalAlignment="Stretch"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                </Grid>

                                <!-- ── USB write sub-panel (revealed on USB choice) ── -->
                                <Border Name="WPFWin11ISOOptionUSB"
                                        Style="{StaticResource BorderStyle}"
                                        Visibility="Collapsed"
                                        Margin="0,8,0,0">
                                    <StackPanel>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,8">
                                            <Run FontWeight="Bold" Foreground="OrangeRed">!! Todos los datos en el USB seleccionado se borrarán permanentemente !!</Run>
                                            <LineBreak/>
                                            Selecciona una unidad USB extraíble a continuación y luego haz clic en Borrar y Escribir.
                                        </TextBlock>
                                        <!-- USB drive selector row -->
                                        <Grid Margin="0,0,0,8">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <ComboBox Grid.Column="0"
                                                      Name="WPFWin11ISOUSBDriveComboBox"
                                                      Foreground="{DynamicResource MainForegroundColor}"
                                                      Background="{DynamicResource MainBackgroundColor}"
                                                      VerticalAlignment="Center"
                                                      Margin="0,0,6,0"/>
                                            <Button Grid.Column="1"
                                                    Name="WPFWin11ISORefreshUSBButton"
                                                    Content="Actualizar"
                                                    Width="Auto" Padding="8,0"
                                                    Height="{DynamicResource ButtonHeight}"/>
                                        </Grid>
                                        <Button Name="WPFWin11ISOWriteUSBButton"
                                                Content="Borrar y Escribir en USB"
                                                Foreground="OrangeRed"
                                                HorizontalAlignment="Stretch"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"
                                                Margin="0,0,0,10"/>
                                    </StackPanel>
                                </Border>
                            </StackPanel>

                    </StackPanel>

                    <!-- Status Log (fills remaining height) -->
                    <Grid Grid.Row="1" Margin="5">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0"
                                   FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                   Foreground="{DynamicResource MainForegroundColor}"
                                   Margin="0,0,0,4">
                            Registro de Estado
                        </TextBlock>
                        <TextBox Grid.Row="1"
                                 Name="WPFWin11ISOStatusLog"
                                 IsReadOnly="True"
                                 TextWrapping="Wrap"
                                 VerticalScrollBarVisibility="Visible"
                                 VerticalAlignment="Stretch"
                                 Padding="6"
                                 Background="{DynamicResource MainBackgroundColor}"
                                 Foreground="{DynamicResource MainForegroundColor}"
                                 BorderBrush="{DynamicResource BorderColor}"
                                 BorderThickness="1"
                                 Text="Listo. Por favor selecciona una ISO de Windows 11 para comenzar."/>
                    </Grid>

                </Grid>
            </TabItem>
        </TabControl>
    </Grid>
</Window>

'@
$WinUtilAutounattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <settings pass="offlineServicing"></settings>
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
            <UseConfigurationSet>false</UseConfigurationSet>
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="generalize"></settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -NoProfile -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\Specialize.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\DefaultUser.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg.exe unload "HKU\DefaultUser"</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="auditSystem"></settings>
    <settings pass="auditUser"></settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <HideEULAPage>true</HideEULAPage>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\FirstLogon.ps1"</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
    <Extensions xmlns="https://schneegans.de/windows/unattend-generator/">
        <ExtractScript>
param(
    [xml]$Document
);
foreach( $file in $Document.unattend.Extensions.File ) {
    $path = [System.Environment]::ExpandEnvironmentVariables( $file.GetAttribute( 'path' ) );
    mkdir -Path( $path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue';
    $encoding = switch( [System.IO.Path]::GetExtension( $path ) ) {
        { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; }
        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( $false, $true ); }
        default { [System.Text.Encoding]::Default; }
    };
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes( $file.InnerText.Trim() );
    [System.IO.File]::WriteAllBytes( $path, $bytes );
}
        </ExtractScript>
        <File path="C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml">
&lt;LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1"&gt;
    &lt;CustomTaskbarLayoutCollection PinListPlacement="Replace"&gt;
        &lt;defaultlayout:TaskbarLayout&gt;
            &lt;taskbar:TaskbarPinList&gt;
                &lt;taskbar:DesktopApp DesktopApplicationLinkPath="#leaveempty" /&gt;
            &lt;/taskbar:TaskbarPinList&gt;
        &lt;/defaultlayout:TaskbarLayout&gt;
    &lt;/CustomTaskbarLayoutCollection&gt;
&lt;/LayoutModificationTemplate&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.vbs">
HKU = &amp;H80000003
Set reg = GetObject("winmgmts://./root/default:StdRegProv")
Set fso = CreateObject("Scripting.FileSystemObject")
If reg.EnumKey(HKU, "", sids) = 0 Then
    If Not IsNull(sids) Then
        For Each sid In sids
            key = sid + "\Software\Policies\Microsoft\Windows\Explorer"
            name = "LockedStartLayout"
            If reg.GetDWORDValue(HKU, key, name, existing) = 0 Then
                reg.SetDWORDValue HKU, key, name, 0
            End If
        Next
    End If
End If
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.xml">
&lt;Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"&gt;
    &lt;Triggers&gt;
        &lt;EventTrigger&gt;
            &lt;Enabled&gt;true&lt;/Enabled&gt;
            &lt;Subscription&gt;&amp;lt;QueryList&amp;gt;&amp;lt;Query Id="0" Path="Application"&amp;gt;&amp;lt;Select Path="Application"&amp;gt;*[System[Provider[@Name='UnattendGenerator'] and EventID=1]]&amp;lt;/Select&amp;gt;&amp;lt;/Query&amp;gt;&amp;lt;/QueryList&amp;gt;&lt;/Subscription&gt;
        &lt;/EventTrigger&gt;
    &lt;/Triggers&gt;
    &lt;Principals&gt;
        &lt;Principal id="Author"&gt;
            &lt;UserId&gt;S-1-5-18&lt;/UserId&gt;
            &lt;RunLevel&gt;LeastPrivilege&lt;/RunLevel&gt;
        &lt;/Principal&gt;
    &lt;/Principals&gt;
    &lt;Settings&gt;
        &lt;MultipleInstancesPolicy&gt;IgnoreNew&lt;/MultipleInstancesPolicy&gt;
        &lt;DisallowStartIfOnBatteries&gt;false&lt;/DisallowStartIfOnBatteries&gt;
        &lt;StopIfGoingOnBatteries&gt;false&lt;/StopIfGoingOnBatteries&gt;
        &lt;AllowHardTerminate&gt;true&lt;/AllowHardTerminate&gt;
        &lt;StartWhenAvailable&gt;false&lt;/StartWhenAvailable&gt;
        &lt;RunOnlyIfNetworkAvailable&gt;false&lt;/RunOnlyIfNetworkAvailable&gt;
        &lt;IdleSettings&gt;
            &lt;StopOnIdleEnd&gt;true&lt;/StopOnIdleEnd&gt;
            &lt;RestartOnIdle&gt;false&lt;/RestartOnIdle&gt;
        &lt;/IdleSettings&gt;
        &lt;AllowStartOnDemand&gt;true&lt;/AllowStartOnDemand&gt;
        &lt;Enabled&gt;true&lt;/Enabled&gt;
        &lt;Hidden&gt;false&lt;/Hidden&gt;
        &lt;RunOnlyIfIdle&gt;false&lt;/RunOnlyIfIdle&gt;
        &lt;WakeToRun&gt;false&lt;/WakeToRun&gt;
        &lt;ExecutionTimeLimit&gt;PT72H&lt;/ExecutionTimeLimit&gt;
        &lt;Priority&gt;7&lt;/Priority&gt;
    &lt;/Settings&gt;
    &lt;Actions Context="Author"&gt;
        &lt;Exec&gt;
            &lt;Command&gt;C:\Windows\System32\wscript.exe&lt;/Command&gt;
            &lt;Arguments&gt;C:\Windows\Setup\Scripts\UnlockStartLayout.vbs&lt;/Arguments&gt;
        &lt;/Exec&gt;
    &lt;/Actions&gt;
&lt;/Task&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\SetStartPins.ps1">
$json = '{"pinnedList":[]}';
if( [System.Environment]::OSVersion.Version.Build -lt 20000 ) {
    return;
}
$key = 'Registry::HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start';
New-Item -Path $key -ItemType 'Directory' -ErrorAction 'SilentlyContinue';
Set-ItemProperty -LiteralPath $key -Name 'ConfigureStartPins' -Value $json -Type 'String';
        </File>
        <File path="C:\Windows\Setup\Scripts\SetColorTheme.ps1">
$lightThemeSystem = 0;
$lightThemeApps = 0;
$accentColorOnStart = 0;
$enableTransparency = 0;
$htmlAccentColor = '#0078D4';
&amp; {
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';
        Force = $true;
        Type = 'DWord';
    };
    Set-ItemProperty @params -Name 'SystemUsesLightTheme' -Value $lightThemeSystem;
    Set-ItemProperty @params -Name 'AppsUseLightTheme' -Value $lightThemeApps;
    Set-ItemProperty @params -Name 'ColorPrevalence' -Value $accentColorOnStart;
    Set-ItemProperty @params -Name 'EnableTransparency' -Value $enableTransparency;
};
&amp; {
    Add-Type -AssemblyName 'System.Drawing';
    $accentColor = [System.Drawing.ColorTranslator]::FromHtml( $htmlAccentColor );
    function ConvertTo-DWord {
        param(
            [System.Drawing.Color]
            $Color
        );
        [byte[]]$bytes = @(
            $Color.R;
            $Color.G;
            $Color.B;
            $Color.A;
        );
        return [System.BitConverter]::ToUInt32( $bytes, 0);
    }
    $startColor = [System.Drawing.Color]::FromArgb( 0xD2, $accentColor );
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent';
        Name = 'AccentPalette';
    };
    $palette = Get-ItemPropertyValue @params;
    $index = 20;
    $palette[ $index++ ] = $accentColor.R;
    $palette[ $index++ ] = $accentColor.G;
    $palette[ $index++ ] = $accentColor.B;
    $palette[ $index++ ] = $accentColor.A;
    Set-ItemProperty @params -Value $palette -Type 'Binary' -Force;
};
        </File>
        <File path="C:\Windows\Setup\Scripts\Specialize.ps1">
$scripts = @(
    {
        reg.exe add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f;
    };
    {
        net.exe accounts /maxpwage:UNLIMITED;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v "DisableCloudOptimizedContent" /t REG_DWORD /d 1 /f;
        [System.Diagnostics.EventLog]::CreateEventSource( 'UnattendGenerator', 'Application' );
    };
    {
        Register-ScheduledTask -TaskName 'UnlockStartLayout' -Xml $( Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UnlockStartLayout.xml' -Raw );
    };
    {
        reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
    };
    {
        Remove-Item -LiteralPath 'C:\Users\Public\Desktop\Microsoft Edge.lnk' -ErrorAction 'SilentlyContinue' -Verbose;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge" /v HideFirstRunExperience /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v BackgroundModeEnabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v StartupBoostEnabled /t REG_DWORD /d 0 /f;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetStartPins.ps1';
    };
    {
        reg.exe add "HKU\.DEFAULT\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f;
    };
);
&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\Specialize.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\UserOnce.ps1">
$scripts = @(
    {
        [System.Diagnostics.EventLog]::WriteEntry( 'UnattendGenerator', "User '$env:USERNAME' has requested to unlock the Start menu layout.", [System.Diagnostics.EventLogEntryType]::Information, 1 );
    };
    {
        Remove-Item -Path "${env:USERPROFILE}\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
        Remove-Item -Path "$env:HOMEDRIVE\Users\Default\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
    };
    {
        $taskbarPath = "$env:AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar";
        if( Test-Path $taskbarPath ) {
            Get-ChildItem -Path $taskbarPath -File | Remove-Item -Force;
        }
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesRemovedChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'Favorites' -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /ve /f;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Type 'DWord' -Value 1;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value 0;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetColorTheme.ps1';
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /v Enabled /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v AllAppsViewMode /t REG_DWORD /d 2 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_IrisRecommendations /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_AccountNotifications /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowAllPinsList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowFrequentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowRecentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_TrackDocs /t REG_DWORD /d 0 /f;
    };
    {
        Restart-Computer -Force;
    };
);
&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to configure this user account. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "$env:TEMP\UserOnce.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\DefaultUser.ps1">
$scripts = @(
    {
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "StartLayoutFile" /t REG_SZ /d "C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml" /f;
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "LockedStartLayout" /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAl /t REG_DWORD /d 0 /f;
    };
    {
        foreach( $root in 'Registry::HKU\.DEFAULT', 'Registry::HKU\DefaultUser' ) {
          Set-ItemProperty -LiteralPath "$root\Control Panel\Keyboard" -Name 'InitialKeyboardIndicators' -Type 'String' -Value 2 -Force;
        }
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v TaskbarEndTask /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\DWM" /v ColorPrevalence /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle \""Normal\"" -ExecutionPolicy \""Unrestricted\"" -NoProfile -File \""C:\Windows\Setup\Scripts\UserOnce.ps1\""" /f;
    };
);
&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to modify the default user&#x2019;&#x2019;s registry hive. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\DefaultUser.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\FirstLogon.ps1">
$scripts = @(
    {
        Remove-Item -LiteralPath @(
          'C:\Windows\Panther\unattend.xml';
          'C:\Windows\Panther\unattend-original.xml';
          'C:\Windows\Setup\Scripts\Wifi.xml';
          'C:\Windows.old';
        ) -Recurse -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /f;
        reg.exe delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\BITS" /v Start /t REG_DWORD /d 3 /f;
        reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\wuauserv" /v Start /t REG_DWORD /d 3 /f;
        reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\UsoSvc" /v Start /t REG_DWORD /d 2 /f;
        reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc" /v Start /t REG_DWORD /d 3 /f;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /v IsEducationEnvironment /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
    };
    {
        $recallFeature = Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' -and $_.FeatureName -like 'Recall' };
        if( $recallFeature ) {
            Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -Remove -ErrorAction SilentlyContinue;
        }
    };
    {
        $viveDir = Join-Path $env:TEMP 'ViVeTool';
        $viveZip = Join-Path $env:TEMP 'ViVeTool.zip';
        Invoke-WebRequest 'https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip' -OutFile $viveZip;
        Expand-Archive -Path $viveZip -DestinationPath $viveDir -Force;
        Remove-Item -Path $viveZip -Force;
        Start-Process -FilePath (Join-Path $viveDir 'ViVeTool.exe') -ArgumentList '/disable /id:47205210' -Wait -NoNewWindow;
        Remove-Item -Path $viveDir -Recurse -Force;
    };
    {
        Start-Process C:\Windows\System32\OneDriveSetup.exe -ArgumentList /uninstall
    };
    {
        if( (Get-BitLockerVolume -MountPoint $Env:SystemDrive).ProtectionStatus -eq 'On' ) {
            Disable-BitLocker -MountPoint $Env:SystemDrive;
        }
    };
    {
        if( (bcdedit | Select-String 'path').Count -eq 2 ) {
            bcdedit /set `{bootmgr`} timeout 0;
        }
    };
);
&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\FirstLogon.log";
        </File>
    </Extensions>
</unattend>
'@
# Create enums
Add-Type @"
public enum PackageManagers
{
    Winget,
    Choco
}
"@

# SPDX-License-Identifier: MIT
# Set the maximum number of threads for the RunspacePool to the number of threads on the machine
$maxthreads = [int]$env:NUMBER_OF_PROCESSORS

# Create a new session state for parsing variables into our runspace
$hashVars = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync',$sync,$Null
$debugVar = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'DebugPreference',$DebugPreference,$Null
$uiVar = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'PARAM_NOUI',$PARAM_NOUI,$Null
$offlineVar = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'PARAM_OFFLINE',$PARAM_OFFLINE,$Null
$InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

# Add the variable to the session state
$InitialSessionState.Variables.Add($hashVars)
$InitialSessionState.Variables.Add($debugVar)
$InitialSessionState.Variables.Add($uiVar)
$InitialSessionState.Variables.Add($offlineVar)

# Get every private function and add them to the session state
$functions = Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|WPF' }
foreach ($function in $functions) {
    $functionDefinition = Get-Content function:\$($function.name)
    $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $($function.name), $functionDefinition

    $initialSessionState.Commands.Add($functionEntry)
}

# Create the runspace pool
$sync.runspace = [runspacefactory]::CreateRunspacePool(
    1,                      # Minimum thread count
    $maxthreads,            # Maximum thread count
    $InitialSessionState,   # Initial session state
    $Host                   # Machine to create runspaces on
)

# Open the RunspacePool instance
$sync.runspace.Open()

# Create classes for different exceptions

class WingetFailedInstall : Exception {
    [string]$additionalData
    WingetFailedInstall($Message) : base($Message) {}
}

class ChocoFailedInstall : Exception {
    [string]$additionalData
    ChocoFailedInstall($Message) : base($Message) {}
}

class GenericException : Exception {
    [string]$additionalData
    GenericException($Message) : base($Message) {}
}

# Load the configuration files

$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}

Set-Preferences

if ($PARAM_NOUI) {
    Show-SPGLogo
    if ($PARAM_CONFIG -and -not [string]::IsNullOrWhiteSpace($PARAM_CONFIG)) {
        Write-Host "Running config file tasks..."
        Invoke-WPFImpex -type "import" -Config $PARAM_CONFIG
        Invoke-WinUtilAutoRun

        $sync.runspace.Dispose()
        $sync.runspace.Close()
        [System.GC]::Collect()
        Stop-Transcript
        exit 1
    }
    else {
        Write-Host "Cannot automatically run without a config file provided."
        $sync.runspace.Dispose()
        $sync.runspace.Close()
        [System.GC]::Collect()
        Stop-Transcript
        exit 1
    }
}

$inputXML = $inputXML -replace 'mc:Ignorable="d"', '' -replace "x:N", 'N' -replace '^<Win.*', '<Window'

[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[xml]$XAML = $inputXML

# Read the XAML file
$readerOperationSuccessful = $false # There's more cases of failure then success.
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
    $readerOperationSuccessful = $true
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
    Write-Host $error[0].Exception.Message -ForegroundColor Red

    If ($error[0].Exception.Message -like "*button*") {
        write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
    }
} catch {
    Write-Host "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed." -ForegroundColor Red
}

if (-NOT ($readerOperationSuccessful)) {
    Write-Host "Failed to parse xaml content using Windows.Markup.XamlReader's Load Method." -ForegroundColor Red
    Write-Host "Quitting winutil..." -ForegroundColor Red
    $sync.runspace.Dispose()
    $sync.runspace.Close()
    [System.GC]::Collect()
    exit 1
}

# Setup the Window to follow listen for windows Theme Change events and update the winutil theme
# throttle logic needed, because windows seems to send more than one theme change event per change
$lastThemeChangeTime = [datetime]::MinValue
$debounceInterval = [timespan]::FromSeconds(2)
$sync.Form.Add_Loaded({
    $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
    $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
    $hwndSource.AddHook({
        param (
            [System.IntPtr]$hwnd,
            [int]$msg,
            [System.IntPtr]$wParam,
            [System.IntPtr]$lParam,
            [ref]$handled
        )
        # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
        if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
            $currentTime = [datetime]::Now
            if ($currentTime - $lastThemeChangeTime -gt $debounceInterval) {
                Invoke-WinutilThemeChange -theme "Auto"
                $script:lastThemeChangeTime = $currentTime
                $handled = $true
            }
        }
        return 0
    })
})

Invoke-WinutilThemeChange -theme $sync.preferences.theme


# Now call the function with the final merged config
Invoke-WPFUIElements -configVariable $sync.configs.appnavigation -targetGridName "appscategory" -columncount 1
Initialize-WPFUI -targetGridName "appscategory"

Initialize-WPFUI -targetGridName "appspanel"

Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2

Invoke-WPFUIElements -configVariable $sync.configs.feature -targetGridName "featurespanel" -columncount 2

# Future implementation: Add Windows Version to updates panel
#Invoke-WPFUIElements -configVariable $sync.configs.updates -targetGridName "updatespanel" -columncount 1

#===========================================================================
# Store Form Objects In PowerShell
#===========================================================================

$xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}

#Persist Package Manager preference across winutil restarts
$sync.ChocoRadioButton.Add_Checked({
    $sync.preferences.packagemanager = [PackageManagers]::Choco
    Set-Preferences -save
})
$sync.WingetRadioButton.Add_Checked({
    $sync.preferences.packagemanager = [PackageManagers]::Winget
    Set-Preferences -save
})

switch ($sync.preferences.packagemanager) {
    "Choco" {$sync.ChocoRadioButton.IsChecked = $true; break}
    "Winget" {$sync.WingetRadioButton.IsChecked = $true; break}
}

$sync.keys | ForEach-Object {
    if($sync.$psitem) {
        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "ToggleButton") {
            $sync["$psitem"].Add_Click({
                [System.Object]$Sender = $args[0]
                Invoke-WPFButton $Sender.name
            })
        }

        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "Button") {
            $sync["$psitem"].Add_Click({
                [System.Object]$Sender = $args[0]
                Invoke-WPFButton $Sender.name
            })
        }

        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "Border") {
            if ($sync["$psitem"].Name -like "WPFWebApp*") {
                $sync["$psitem"].Add_MouseLeftButtonUp({
                    [System.Object]$Sender = $args[0]
                    Invoke-WPFButton $Sender.name
                })
                $sync["$psitem"].Add_MouseEnter({
                    [System.Object]$Sender = $args[0]
                    $Sender.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
                })
                $sync["$psitem"].Add_MouseLeave({
                    [System.Object]$Sender = $args[0]
                    $Sender.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
                })
            }
        }

        if ($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "TextBlock") {
            if ($sync["$psitem"].Name.EndsWith("Link")) {
                $sync["$psitem"].Add_MouseUp({
                    [System.Object]$Sender = $args[0]
                    Start-Process $Sender.ToolTip -ErrorAction Stop
                    Write-Debug "Opening: $($Sender.ToolTip)"
                })
            }

        }
    }
}

#===========================================================================
# Setup background config
#===========================================================================

# Load computer information in the background
Invoke-WPFRunspace -ScriptBlock {
    try {
        $ProgressPreference = "SilentlyContinue"
        $sync.ConfigLoaded = $False
        $sync.ComputerInfo = Get-ComputerInfo
        $sync.ConfigLoaded = $True
    }
    finally{
        $ProgressPreference = $oldProgressPreference
    }

} | Out-Null

#===========================================================================
# Setup and Show the Form
#===========================================================================

# Print the logo
Show-SPGLogo

# Progress bar in taskbaritem > Set-WinUtilProgressbar
$sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
Set-WinUtilTaskbaritem -state "None"

# Set window icon
try {
    $sync["Form"].Icon = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
} catch {
    Write-Debug "Could not load window icon: $_"
}

# Set the titlebar
$sync["Form"].title = $sync["Form"].title + " " + $sync.version
# Set the commands that will run when the form is closed
$sync["Form"].Add_Closing({
    $sync.runspace.Dispose()
    $sync.runspace.Close()
    [System.GC]::Collect()
})

# Attach the event handler to the Click event
$sync.SearchBarClearButton.Add_Click({
    $sync.SearchBar.Text = ""
    $sync.SearchBarClearButton.Visibility = "Collapsed"

    # Focus the search bar after clearing the text
    $sync.SearchBar.Focus()
    $sync.SearchBar.SelectAll()
})

# add some shortcuts for people that don't like clicking
$commonKeyEvents = {
    # Prevent shortcuts from executing if a process is already running
    if ($sync.ProcessRunning -eq $true) {
        return
    }

    # Handle key presses of single keys
    switch ($_.Key) {
        "Escape" { $sync.SearchBar.Text = "" }
    }
    # Handle Alt key combinations for navigation
    if ($_.KeyboardDevice.Modifiers -eq "Alt") {
        $keyEventArgs = $_
        switch ($_.SystemKey) {
            "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
            "P" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Web Apps tab
            "T" { Invoke-WPFButton "WPFTab3BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
            "C" { Invoke-WPFButton "WPFTab4BT"; $keyEventArgs.Handled = $true } # Navigate to Config tab
            "U" { Invoke-WPFButton "WPFTab5BT"; $keyEventArgs.Handled = $true } # Navigate to Updates tab
            "W" { Invoke-WPFButton "WPFTab6BT"; $keyEventArgs.Handled = $true } # Navigate to Win11ISO tab
        }
    }
    # Handle Ctrl key combinations for specific actions
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
        switch ($_.Key) {
            "F" { $sync.SearchBar.Focus() } # Focus on the search bar
            "Q" { $this.Close() } # Close the application
        }
    }
}
$sync["Form"].Add_PreViewKeyDown($commonKeyEvents)

$sync["Form"].Add_MouseLeftButtonDown({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    $sync["Form"].DragMove()
})

$sync["Form"].Add_MouseDoubleClick({
    if ($_.OriginalSource.Name -eq "NavDockPanel" -or
        $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
            if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                $sync["Form"].WindowState = [Windows.WindowState]::Maximized
            }
            else{
                $sync["Form"].WindowState = [Windows.WindowState]::Normal
            }
    }
})

$sync["Form"].Add_Deactivated({
    Write-Debug "WinUtil lost focus"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
})

$sync["Form"].Add_ContentRendered({
    # Load the Windows Forms assembly
    Add-Type -AssemblyName System.Windows.Forms
    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    # Check if the primary screen is found
    if ($primaryScreen) {
        # Extract screen width and height for the primary monitor
        $screenWidth = $primaryScreen.Bounds.Width
        $screenHeight = $primaryScreen.Bounds.Height

        # Print the screen size
        Write-Debug "Primary Monitor Width: $screenWidth pixels"
        Write-Debug "Primary Monitor Height: $screenHeight pixels"

        # Compare with the primary monitor size
        if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
            Write-Debug "The specified width and/or height is greater than the primary monitor size."
            $sync.Form.Left = 0
            $sync.Form.Top = 0
            $sync.Form.Width = $screenWidth
            $sync.Form.Height = $screenHeight
        } else {
            Write-Debug "The specified width and height are within the primary monitor size limits."
        }
    } else {
        Write-Debug "Unable to retrieve information about the primary monitor."
    }

    if ($PARAM_OFFLINE) {
        # Show offline banner
        $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible

        # Disable the install tab
        $sync.WPFTab1BT.IsEnabled = $false
        $sync.WPFTab1BT.Opacity = 0.5
        $sync.WPFTab1BT.ToolTip = "Internet connection required for installing applications"

        # Disable install-related buttons
        if ($sync.WPFInstall) { $sync.WPFInstall.IsEnabled = $false }
        if ($sync.WPFUninstall) { $sync.WPFUninstall.IsEnabled = $false }
        if ($sync.WPFInstallUpgrade) { $sync.WPFInstallUpgrade.IsEnabled = $false }
        if ($sync.WPFGetInstalled) { $sync.WPFGetInstalled.IsEnabled = $false }

        # Show offline indicator
        Write-Host "Offline mode detected - Install tab disabled" -ForegroundColor Yellow

        # Optionally switch to a different tab if install tab was going to be default
        Invoke-WPFTab "WPFTab3BT"  # Switch to Tweaks tab instead
    }
    else {
        # Online - ensure install tab is enabled
        $sync.WPFTab1BT.IsEnabled = $true
        $sync.WPFTab1BT.Opacity = 1.0
        $sync.WPFTab1BT.ToolTip = $null
        Invoke-WPFTab "WPFTab1BT"  # Default to install tab
    }

    $sync["Form"].Focus()

   if ($PARAM_CONFIG -and -not [string]::IsNullOrWhiteSpace($PARAM_CONFIG)) {
        Write-Host "Running config file tasks..."
        Invoke-WPFImpex -type "import" -Config $PARAM_CONFIG
        Invoke-WPFRunspace -ScriptBlock {
            Invoke-WinUtilAutoRun
        }
    }

})

# The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
# This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

$searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
$searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$searchBarTimer.IsEnabled = $false

$searchBarTimer.add_Tick({
    $searchBarTimer.Stop()
    switch ($sync.currentTab) {
        "Instalar" {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        "Ajustes" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
    }
})
$sync["SearchBar"].Add_TextChanged({
    if ($sync.SearchBar.Text -ne "") {
        $sync.SearchBarClearButton.Visibility = "Visible"
    } else {
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
    if ($searchBarTimer.IsEnabled) {
        $searchBarTimer.Stop()
    }
    $searchBarTimer.Start()
})

$sync["Form"].Add_Loaded({
    param($e)
    $sync.Form.MinWidth = "1000"
    $sync["Form"].MaxWidth = [Double]::PositiveInfinity
    $sync["Form"].MaxHeight = [Double]::PositiveInfinity
})

$NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")
$NavLogoPanel.Cursor = [System.Windows.Input.Cursors]::Hand
$NavLogoPanel.Add_MouseLeftButtonDown({
    Start-Process "https://servicepcglew.pages.dev/"
})
$NavLogoPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 48)) | Out-Null

if (Test-Path "$winutildir\logo.ico") {
    $sync["logorender"] = "$winutildir\logo.ico"
} else {
    $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
}
$sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
$sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)

Set-WinUtilTaskbaritem -overlay "logo"

$sync["Form"].Add_Activated({
    Set-WinUtilTaskbaritem -overlay "logo"
})

$sync["ThemeButton"].Add_Click({
    Write-Debug "ThemeButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
})
$sync["AutoThemeMenuItem"].Add_Click({
    Write-Debug "About clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Auto"
})
$sync["DarkThemeMenuItem"].Add_Click({
    Write-Debug "Dark Theme clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Dark"
})
$sync["LightThemeMenuItem"].Add_Click({
    Write-Debug "Light Theme clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Light"
})

$sync["SettingsButton"].Add_Click({
    Write-Debug "SettingsButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
})
$sync["ImportMenuItem"].Add_Click({
    Write-Debug "Import clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "import"
})
$sync["ExportMenuItem"].Add_Click({
    Write-Debug "Export clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "export"
})
$sync["AboutMenuItem"].Add_Click({
    Write-Debug "About clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
Autor    : 
UI       : 
Runspace : 
GitHub   : 
Versión  : 
"@
    Show-CustomDialog -Title "Acerca de" -Message $authorInfo
})
$sync["DocumentationMenuItem"].Add_Click({
    Write-Debug "Documentation clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Start-Process "https://servicepcglew-winutil.pages.dev/"
})
$sync["SponsorMenuItem"].Add_Click({
    Write-Debug "Sponsors clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
Patrocinadores actuales de Service PC Glew:
<a href="https://www.instagram.com/3d.suarez/">@3d.suarez</a>
"@
    $authorInfo += "`n"
    Show-CustomDialog -Title "Patrocinadores" -Message $authorInfo -EnableScroll $true
})

# Font Scaling Event Handlers
$sync["FontScalingButton"].Add_Click({
    Write-Debug "FontScalingButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
})

$sync["FontScalingSlider"].Add_ValueChanged({
    param($slider)
    $percentage = [math]::Round($slider.Value * 100)
    $sync.FontScalingValue.Text = "$percentage%"
})

$sync["FontScalingResetButton"].Add_Click({
    Write-Debug "FontScalingResetButton clicked"
    $sync.FontScalingSlider.Value = 1.0
    $sync.FontScalingValue.Text = "100%"
})

$sync["FontScalingApplyButton"].Add_Click({
    Write-Debug "FontScalingApplyButton clicked"
    $scaleFactor = $sync.FontScalingSlider.Value
    Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
    Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
})

# ── Win11ISO Tab button handlers ──────────────────────────────────────────────

$sync["WPFTab6BT"].Add_Click({
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Invoke-WinUtilISOCheckExistingWork }) | Out-Null
})

$sync["WPFWin11ISOBrowseButton"].Add_Click({
    Write-Debug "WPFWin11ISOBrowseButton clicked"
    Invoke-WinUtilISOBrowse
})

$sync["WPFWin11ISODownloadLink"].Add_Click({
    Write-Debug "WPFWin11ISODownloadLink clicked"
    Start-Process "https://www.microsoft.com/software-download/windows11"
})

$sync["WPFWin11ISOMountButton"].Add_Click({
    Write-Debug "WPFWin11ISOMountButton clicked"
    Invoke-WinUtilISOMountAndVerify
})

$sync["WPFWin11ISOModifyButton"].Add_Click({
    Write-Debug "WPFWin11ISOModifyButton clicked"
    Invoke-WinUtilISOModify
})

$sync["WPFWin11ISOChooseISOButton"].Add_Click({
    Write-Debug "WPFWin11ISOChooseISOButton clicked"
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Collapsed"
    Invoke-WinUtilISOExport
})

$sync["WPFWin11ISOChooseUSBButton"].Add_Click({
    Write-Debug "WPFWin11ISOChooseUSBButton clicked"
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Visible"
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISORefreshUSBButton"].Add_Click({
    Write-Debug "WPFWin11ISORefreshUSBButton clicked"
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISOWriteUSBButton"].Add_Click({
    Write-Debug "WPFWin11ISOWriteUSBButton clicked"
    Invoke-WinUtilISOWriteUSB
})

$sync["WPFWin11ISOCleanResetButton"].Add_Click({
    Write-Debug "WPFWin11ISOCleanResetButton clicked"
    Invoke-WinUtilISOCleanAndReset
})

# ──────────────────────────────────────────────────────────────────────────────

$sync["Form"].ShowDialog() | out-null
Stop-Transcript