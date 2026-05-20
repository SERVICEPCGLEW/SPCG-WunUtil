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
