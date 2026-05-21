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

            $customLogoPath = "$($sync.PSScriptRoot)\marca de agua.png"
            if (Test-Path $customLogoPath) {
                try {
                    $logoImage = New-Object System.Windows.Controls.Image
                    $logoBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                    $logoBitmap.BeginInit()
                    $logoBitmap.UriSource = [Uri]$customLogoPath
                    $logoBitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                    $logoBitmap.EndInit()
                    $logoImage.Source = $logoBitmap
                    $logoImage.Height = 24
                    $logoImage.Stretch = [System.Windows.Media.Stretch]::Uniform
                    $stackPanel.Children.Add($logoImage) | Out-Null
                } catch {}
            }

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

            $customLogoPath = "$($sync.PSScriptRoot)\marca de agua.png"
            if (Test-Path $customLogoPath) {
                try {
                    $logoImage = New-Object System.Windows.Controls.Image
                    $logoBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                    $logoBitmap.BeginInit()
                    $logoBitmap.UriSource = [Uri]$customLogoPath
                    $logoBitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                    $logoBitmap.EndInit()
                    $logoImage.Source = $logoBitmap
                    $logoImage.Height = 24
                    $logoImage.Stretch = [System.Windows.Media.Stretch]::Uniform
                    $stackPanel.Children.Add($logoImage) | Out-Null
                } catch {}
            }

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
