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
