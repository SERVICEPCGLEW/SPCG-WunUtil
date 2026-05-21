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
        $line1 = "${orange}  ____                  _            ____   ____    ____ _                  ${white}.---------.${reset}"
        $line2 = "${orange} / ___|  ___ _ ____   _(_) ___ ___  |  _ \ / ___|  / ___| | _____      __   ${white}|.-------.|${reset}"
        $line3 = "${orange} \___ \ / _ \ '__\ \ / / |/ __/ _ \ | |_) | |     | |  _| |/ _ \ \ /\ / /   ${white}||       ||${reset}"
        $line4 = "${orange}  ___) |  __/ |   \ V /| | (_|  __/ |  __/| |___  | |_| | |  __/\ V  V /    ${white}`"-------'|${reset}"
        $line5 = "${orange} |____/ \___|_|    \_/ |_|\___\___| |_|    \____|  \____|_|\___| \_/\_/   ${white}.-^---------^-.${reset}"
        $line6 = "${orange}                                                                          ${white}`"-------------'${reset}"

        Write-Host $line1
        Write-Host $line2
        Write-Host $line3
        Write-Host $line4
        Write-Host $line5
        Write-Host $line6
    }

    Write-Host ""
    Write-Host "$orange====$($white)Service PC Glew$orange=====$reset"
    Write-Host "$orange=====$($white)Herramientas de Windows$orange=====$reset"
    Write-Host "${orange}https://servicepcglew.pages.dev/$reset"
}
