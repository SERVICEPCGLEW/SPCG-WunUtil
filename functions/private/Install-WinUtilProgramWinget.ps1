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
