<#
.SYNOPSIS
    Service PC Glew - WinUtil
.DESCRIPTION
    Herramienta técnica de optimización y mantenimiento de sistemas, diseñada
    específicamente para agilizar el formateo y la puesta a punto de equipos.
    Desarrollado en PowerShell puro con interfaz gráfica WPF.
#>

# -------------------------------------------------------------------------
# 1. AUTO-ELEVACIÓN DE PERMISOS
# -------------------------------------------------------------------------
# Comprobamos si el script se está ejecutando como administrador (Elevado)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # Si no es administrador, relanzamos el script con elevación de privilegios
    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "powershell.exe"
        $processInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $processInfo.Verb = "RunAs"
        [System.Diagnostics.Process]::Start($processInfo) | Out-Null
    } catch {
        Write-Warning "Se requieren permisos de administrador para ejecutar esta utilidad."
        Pause
    }
    exit
}

# -------------------------------------------------------------------------
# 2. CARGA DE DEPENDENCIAS (.NET WPF y WinForms)
# -------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms # Requerido para DoEvents (refresco de interfaz)

[System.Windows.Forms.Application]::EnableVisualStyles() | Out-Null

# -------------------------------------------------------------------------
# 3. DEFINICIÓN DE LA INTERFAZ GRÁFICA (XAML)
# -------------------------------------------------------------------------
# Aquí construimos toda la interfaz gráfica, botones, pestañas y estilos
# usando colores corporativos: Fondo #121212 y Acento Naranja #FF6A00
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Service PC Glew - WinUtil" Height="680" Width="800" WindowStartupLocation="CenterScreen" Background="#121212">
    <Window.Resources>
        <!-- ESTILO DE LOS BOTONES -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#1E1E1E"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#FF6A00"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#FF6A00"/>
                                <Setter Property="Foreground" Value="#121212"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ESTILO DE LAS PESTAÑAS (TabItems) -->
        <Style TargetType="TabItem">
            <Setter Property="Background" Value="#1E1E1E"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#FF6A00"/>
            <Setter Property="Padding" Value="15,10"/>
            <Setter Property="Margin" Value="0,0,2,0"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border Name="Border" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1,1,1,0" CornerRadius="4,4,0,0">
                            <ContentPresenter x:Name="ContentSite" VerticalAlignment="Center" HorizontalAlignment="Center" ContentSource="Header" Margin="15,8"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#FF6A00"/>
                                <Setter Property="Foreground" Value="#121212"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="BorderThickness" Value="2,2,2,0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ESTILO DE CHECKBOX Y TEXTBLOCKS -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontFamily" Value="Segoe UI, Inter, Arial"/>
        </Style>
    </Window.Resources>
    
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        
        <!-- HEADER (Logo/Título) -->
        <Border BorderBrush="#FF6A00" BorderThickness="0,0,0,2" Margin="0,0,0,20" Padding="0,0,0,10">
            <TextBlock Text="SERVICE PC GLEW - WINUTIL" FontSize="32" FontWeight="Black" Foreground="#FF6A00" HorizontalAlignment="Center" />
        </Border>
        
        <!-- CONTENIDO PRINCIPAL EN PESTAÑAS -->
        <TabControl Grid.Row="1" Background="Transparent" BorderBrush="#FF6A00" BorderThickness="0,2,0,0">
            
            <!-- ============================================== -->
            <!-- PESTAÑA 1: INSTALADOR DE SOFTWARE              -->
            <!-- ============================================== -->
            <TabItem Header="Instalador de Software">
                <Grid Margin="15">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    
                    <ScrollViewer VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                            <!-- CATEGORÍA: NAVEGADORES -->
                            <TextBlock Text="Navegadores Web" FontSize="18" FontWeight="Bold" Foreground="#FF6A00" Margin="0,10,0,5"/>
                            <CheckBox Name="chkChrome" Content="Google Chrome"/>
                            <CheckBox Name="chkBrave" Content="Brave Browser"/>
                            
                            <!-- CATEGORÍA: UTILIDADES -->
                            <TextBlock Text="Utilidades Comunes" FontSize="18" FontWeight="Bold" Foreground="#FF6A00" Margin="0,20,0,5"/>
                            <CheckBox Name="chk7Zip" Content="7-Zip"/>
                            <CheckBox Name="chkVLC" Content="VLC Media Player"/>
                            <CheckBox Name="chkAnyDesk" Content="AnyDesk"/>
                            <CheckBox Name="chkLightshot" Content="Lightshot (Capturas de pantalla)"/>
                            
                            <!-- CATEGORÍA: RUNTIMES -->
                            <TextBlock Text="Runtimes y Dependencias" FontSize="18" FontWeight="Bold" Foreground="#FF6A00" Margin="0,20,0,5"/>
                            <CheckBox Name="chkVCRedist" Content="Visual C++ Redistributable All-in-One"/>
                            <CheckBox Name="chkDotNet" Content=".NET Desktop Runtime 8"/>
                        </StackPanel>
                    </ScrollViewer>
                    
                    <!-- BOTÓN ACCIÓN PESTAÑA 1 -->
                    <Button Name="btnInstallSoftware" Grid.Row="1" Content="INSTALAR SOFTWARE SELECCIONADO" FontSize="16" Height="45" Margin="0,20,0,0"/>
                </Grid>
            </TabItem>
            
            <!-- ============================================== -->
            <!-- PESTAÑA 2: DEBLOAT Y OPTIMIZACIÓN              -->
            <!-- ============================================== -->
            <TabItem Header="Debloat y Optimización">
                <Grid Margin="15">
                    <StackPanel>
                        <TextBlock Text="Tweaks y Optimizaciones de Sistema" FontSize="22" FontWeight="Bold" Foreground="#FF6A00" Margin="0,10,0,30" HorizontalAlignment="Center"/>
                        
                        <!-- BOTÓN: TELEMETRÍA -->
                        <Button Name="btnDisableTelemetry" Content="Desactivar Telemetría y Recolección de Datos" FontSize="15" Height="50" Margin="10,5,10,15" HorizontalAlignment="Stretch"/>
                        
                        <!-- BOTÓN: BLOATWARE -->
                        <Button Name="btnRemoveBloatware" Content="Eliminar Aplicaciones Preinstaladas (Bloatware Windows)" FontSize="15" Height="50" Margin="10,5,10,15" HorizontalAlignment="Stretch"/>
                        
                        <!-- BOTÓN: MÁXIMO RENDIMIENTO -->
                        <Button Name="btnMaxPower" Content="Activar Plan de Energía: Máximo Rendimiento" FontSize="15" Height="50" Margin="10,5,10,15" HorizontalAlignment="Stretch"/>
                        
                        <!-- ESTADO / RESULTADOS -->
                        <TextBlock Name="txtOptStatus" Text="" Foreground="#FF6A00" Margin="0,30,0,0" FontSize="16" HorizontalAlignment="Center" FontWeight="Bold"/>
                    </StackPanel>
                </Grid>
            </TabItem>
            
            <!-- ============================================== -->
            <!-- PESTAÑA 3: REPARACIÓN Y MANTENIMIENTO          -->
            <!-- ============================================== -->
            <TabItem Header="Reparación y Mantenimiento">
                <Grid Margin="15">
                    <StackPanel>
                        <TextBlock Text="Mantenimiento Preventivo y Correctivo" FontSize="22" FontWeight="Bold" Foreground="#FF6A00" Margin="0,10,0,30" HorizontalAlignment="Center"/>
                        
                        <!-- BOTÓN: LIMPIEZA TEMP -->
                        <Button Name="btnCleanTemp" Content="Limpieza Profunda de Archivos Temporales" FontSize="15" Height="50" Margin="10,5,10,15" HorizontalAlignment="Stretch"/>
                        
                        <!-- BOTÓN: SFC & DISM -->
                        <Button Name="btnSfcDism" Content="Ejecutar Diagnóstico de Sistema (SFC / DISM)" FontSize="15" Height="50" Margin="10,5,10,15" HorizontalAlignment="Stretch"/>
                        
                        <!-- ESTADO / RESULTADOS -->
                        <TextBlock Name="txtMaintStatus" Text="" Foreground="#FF6A00" Margin="0,30,0,0" FontSize="16" HorizontalAlignment="Center" FontWeight="Bold"/>
                    </StackPanel>
                </Grid>
            </TabItem>
            
        </TabControl>
    </Grid>
</Window>
"@

# -------------------------------------------------------------------------
# 4. LECTURA DEL XAML E INICIALIZACIÓN DE VARIABLES
# -------------------------------------------------------------------------
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-Host "Error al cargar la interfaz XAML: $_"
    Pause
    exit
}

# --- MAPEAMOS LOS CONTROLES DEL XAML A VARIABLES DE POWERSHELL ---

# Controles Pestaña 1
$btnInstallSoftware = $window.FindName("btnInstallSoftware")
$chkChrome          = $window.FindName("chkChrome")
$chkBrave           = $window.FindName("chkBrave")
$chk7Zip            = $window.FindName("chk7Zip")
$chkVLC             = $window.FindName("chkVLC")
$chkAnyDesk         = $window.FindName("chkAnyDesk")
$chkLightshot       = $window.FindName("chkLightshot")
$chkVCRedist        = $window.FindName("chkVCRedist")
$chkDotNet          = $window.FindName("chkDotNet")

# Controles Pestaña 2
$btnDisableTelemetry = $window.FindName("btnDisableTelemetry")
$btnRemoveBloatware  = $window.FindName("btnRemoveBloatware")
$btnMaxPower         = $window.FindName("btnMaxPower")
$txtOptStatus        = $window.FindName("txtOptStatus")

# Controles Pestaña 3
$btnCleanTemp   = $window.FindName("btnCleanTemp")
$btnSfcDism     = $window.FindName("btnSfcDism")
$txtMaintStatus = $window.FindName("txtMaintStatus")

# -------------------------------------------------------------------------
# 5. LÓGICA Y EVENTOS DE LOS BOTONES
# -------------------------------------------------------------------------

# -> EVENTO: Instalador de Software (Winget)
$btnInstallSoftware.Add_Click({
    
    # 1. Recopilar IDs de paquetes seleccionados basados en el manifest de winget
    $packages = @()
    if ($chkChrome.IsChecked)    { $packages += "Google.Chrome" }
    if ($chkBrave.IsChecked)     { $packages += "Brave.Brave" }
    if ($chk7Zip.IsChecked)      { $packages += "7zip.7zip" }
    if ($chkVLC.IsChecked)       { $packages += "VideoLAN.VLC" }
    if ($chkAnyDesk.IsChecked)   { $packages += "AnyDeskSoftwareGmbH.AnyDesk" }
    if ($chkLightshot.IsChecked) { $packages += "Skillbrains.Lightshot" }
    if ($chkVCRedist.IsChecked)  { $packages += "Microsoft.VCRedist.2015+.x64" }
    if ($chkDotNet.IsChecked)    { $packages += "Microsoft.DotNet.DesktopRuntime.8" }
    
    # 2. Verificar que se haya seleccionado al menos uno
    if ($packages.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Por favor, seleccione al menos un programa para instalar.", "Atención", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    # 3. Confirmar acción para no iniciar accidentalmente
    $msg = "Se procederá a instalar $($packages.Count) programa(s) en modo silencioso. La interfaz principal quedará en espera hasta que finalicen las instalaciones.`n`n¿Desea continuar?"
    $confirm = [System.Windows.MessageBox]::Show($msg, "Instalador de Software", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
    
    if ($confirm -eq 'Yes') {
        $btnInstallSoftware.Content = "INSTALANDO... POR FAVOR ESPERE"
        $btnInstallSoftware.IsEnabled = $false
        
        # Forzamos la actualización visual del botón en la UI de WPF
        [System.Windows.Forms.Application]::DoEvents()

        # Iteramos sobre los paquetes y ejecutamos winget en la consola oculta de fondo
        foreach ($pkg in $packages) {
            # Opciones de Winget:
            # --silent: Para que la instalación sea desatendida.
            # --accept-package-agreements / --accept-source-agreements: Evita interrupciones para aceptar términos.
            $args = "install --id `"$pkg`" -e --accept-package-agreements --accept-source-agreements --silent"
            
            try {
                # Start-Process -Wait pausa la ejecución del script hasta que el comando Winget finalice.
                Start-Process "winget" -ArgumentList $args -NoNewWindow -Wait -ErrorAction SilentlyContinue
            } catch {
                Write-Warning "Fallo al intentar lanzar winget para el paquete: $pkg"
            }
        }
        
        [System.Windows.MessageBox]::Show("Instalación de paquetes finalizada.", "Éxito", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        
        $btnInstallSoftware.Content = "INSTALAR SOFTWARE SELECCIONADO"
        $btnInstallSoftware.IsEnabled = $true
    }
})

# -> EVENTO: Desactivar Telemetría
$btnDisableTelemetry.Add_Click({
    $txtOptStatus.Text = "Desactivando telemetría... Espere."
    [System.Windows.Forms.Application]::DoEvents()
    
    try {
        # Modificar políticas de grupo/registro para desactivar telemetría
        $path1 = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
        if (-not (Test-Path $path1)) { New-Item -Path $path1 -Force | Out-Null }
        Set-ItemProperty -Path $path1 -Name "AllowTelemetry" -Value 0 -ErrorAction SilentlyContinue
        
        $path2 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"
        if (-not (Test-Path $path2)) { New-Item -Path $path2 -Force | Out-Null }
        Set-ItemProperty -Path $path2 -Name "AllowTelemetry" -Value 0 -ErrorAction SilentlyContinue
        
        # Deshabilitar tareas programadas que reportan análisis y métricas a Microsoft
        Disable-ScheduledTask -TaskName "Consolidator" -TaskPath "\Microsoft\Windows\Customer Experience Improvement Program\" -ErrorAction SilentlyContinue
        Disable-ScheduledTask -TaskName "UsbCeip" -TaskPath "\Microsoft\Windows\Customer Experience Improvement Program\" -ErrorAction SilentlyContinue
        
        # Detener y deshabilitar el servicio de Experiencia del Usuario (DiagTrack / Connected User Experiences and Telemetry)
        Stop-Service -Name "DiagTrack" -Force -ErrorAction SilentlyContinue
        Set-Service -Name "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue
        
        $txtOptStatus.Text = "Telemetría y recolección de datos desactivadas con éxito."
    } catch {
        $txtOptStatus.Text = "Hubo un error al aplicar los cambios. Revisa los permisos."
    }
})

# -> EVENTO: Eliminar Bloatware
$btnRemoveBloatware.Add_Click({
    $txtOptStatus.Text = "Eliminando Bloatware (Esto puede tardar un poco)..."
    [System.Windows.Forms.Application]::DoEvents()
    
    # Lista de aplicaciones basura preinstaladas
    $bloatware = @(
        "Microsoft.BingWeather",
        "Microsoft.GetHelp",
        "Microsoft.Getstarted",
        "Microsoft.MicrosoftOfficeHub",
        "Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.People",
        "Microsoft.WindowsAlarms",
        "Microsoft.WindowsFeedbackHub",
        "Microsoft.WindowsMaps",
        "Microsoft.XboxApp",
        "Microsoft.XboxGamingOverlay",
        "Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo",
        "Microsoft.YourPhone",
        "Microsoft.549981C3F5F10" # ID interno del paquete de Cortana
    )
    
    foreach ($app in $bloatware) {
        # Buscamos el paquete en el sistema y lo removemos para todos los usuarios posibles
        Get-AppxPackage -Name "*$app*" -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    }
    
    $txtOptStatus.Text = "Aplicaciones preinstaladas y Bloatware eliminados correctamente."
})

# -> EVENTO: Activar Plan Máximo Rendimiento
$btnMaxPower.Add_Click({
    $txtOptStatus.Text = "Activando plan de energía..."
    [System.Windows.Forms.Application]::DoEvents()
    
    # El comando powercfg sirve para administrar los planes de energía.
    # GUID de Ultimate Performance (Máximo Rendimiento): e9a42b02-d5df-448d-aa00-03f14749eb61
    # GUID de High Performance (Alto Rendimiento regular): 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
    
    try {
        # Forzamos la habilitación del plan Ultimate Performance en el sistema
        powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
        
        # Buscamos en la lista de planes cuál corresponde al ultimate performance para activarlo
        $ultimatePlan = powercfg -l | Select-String "e9a42b02-d5df-448d-aa00-03f14749eb61"
        
        if ($ultimatePlan) {
            # Extraemos el GUID exacto asignado y lo activamos
            $guid = ($ultimatePlan -split "\s+")[3]
            powercfg -setactive $guid
            $txtOptStatus.Text = "Plan 'Máximo Rendimiento' (Ultimate) activado correctamente."
        } else {
            # Fallback a Alto Rendimiento estándar si Ultimate no es compatible o falla
            powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
            $txtOptStatus.Text = "Plan 'Alto Rendimiento' activado (Ultimate no disponible)."
        }
    } catch {
        $txtOptStatus.Text = "Error al intentar cambiar el plan de energía."
    }
})

# -> EVENTO: Limpieza Profunda Temporales
$btnCleanTemp.Add_Click({
    $txtMaintStatus.Text = "Calculando y limpiando archivos basura... Espere."
    [System.Windows.Forms.Application]::DoEvents()
    
    # Definimos los directorios principales donde se acumula basura temporal
    $foldersToClean = @(
        "$env:temp",
        "$env:windir\Temp",
        "$env:windir\Prefetch",
        "$env:windir\SoftwareDistribution\Download"
    )
    
    $totalBytesBefore = 0
    $totalBytesAfter = 0
    
    foreach ($folder in $foldersToClean) {
        if (Test-Path $folder) {
            # Calcular tamaño de los archivos de manera preventiva
            $itemsBefore = Get-ChildItem -Path $folder -Recurse -File -Force -ErrorAction SilentlyContinue
            foreach ($item in $itemsBefore) { $totalBytesBefore += $item.Length }
            
            # Limpiar contenido interno ignorando archivos que estén actualmente en uso por el sistema
            Get-ChildItem -Path $folder -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            
            # Calcular el tamaño restante (usualmente archivos bloqueados)
            $itemsAfter = Get-ChildItem -Path $folder -Recurse -File -Force -ErrorAction SilentlyContinue
            foreach ($item in $itemsAfter) { $totalBytesAfter += $item.Length }
        }
    }
    
    # Vaciado de la Papelera de Reciclaje en todas las unidades
    try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch {}
    
    $freedBytes = $totalBytesBefore - $totalBytesAfter
    if ($freedBytes -lt 0) { $freedBytes = 0 } # Prevenir errores de lectura
    
    $freedMB = [math]::Round($freedBytes / 1MB, 2)
    $txtMaintStatus.Text = "Limpieza completada. Espacio liberado estimado: $freedMB MB."
})

# -> EVENTO: SFC & DISM (Consola Visible)
$btnSfcDism.Add_Click({
    $txtMaintStatus.Text = "Lanzando consola de diagnóstico..."
    [System.Windows.Forms.Application]::DoEvents()
    
    # Generamos un script temporal separado. Esto permite que se abra en una ventana de consola visible,
    # permitiendo monitorear el progreso exacto sin bloquear la interfaz de WPF.
    $tempScript = "$env:TEMP\ServicePcGlew_SfcDism.ps1"
    
    $scriptContent = @"
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host "   SERVICE PC GLEW - DIAGNÓSTICO DEL SISTEMA (SFC & DISM)  " -ForegroundColor Cyan
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "ATENCIÓN: Este proceso puede tardar varios minutos. NO cierre la ventana." -ForegroundColor Red

Write-Host "`n[1/2] Ejecutando DISM (Reparación de la imagen de Windows)..." -ForegroundColor Yellow
DISM /Online /Cleanup-Image /RestoreHealth

Write-Host "`n[2/2] Ejecutando SFC (Comprobador de integridad de archivos de sistema)..." -ForegroundColor Yellow
sfc /scannow

Write-Host "`n===========================================================" -ForegroundColor Cyan
Write-Host "   PROCESO COMPLETADO. VERIFICA SI HUBO ERRORES REPARADOS. " -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Cyan
Read-Host "`nPresiona Enter para salir"
"@
    
    # Escribimos el archivo y lo forzamos con UTF8
    $scriptContent | Out-File -FilePath $tempScript -Encoding UTF8 -Force
    
    try {
        # Ejecutamos el script temporal en una nueva ventana visible y de permisos elevados
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
        $txtMaintStatus.Text = "Consola de reparación iniciada. Revisa la nueva ventana emergente."
    } catch {
        $txtMaintStatus.Text = "Error al intentar lanzar la consola de comandos."
    }
})

# -------------------------------------------------------------------------
# 6. MOSTRAR VENTANA (Bloqueante)
# -------------------------------------------------------------------------
# Presenta la interfaz gráfica. El script se queda en este punto hasta que el usuario cierre la ventana.
$window.ShowDialog() | Out-Null
