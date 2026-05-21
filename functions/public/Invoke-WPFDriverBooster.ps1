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
