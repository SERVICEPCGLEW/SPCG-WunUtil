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
