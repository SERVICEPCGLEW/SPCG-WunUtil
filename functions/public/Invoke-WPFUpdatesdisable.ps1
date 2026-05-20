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
