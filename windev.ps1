<#
.SYNOPSIS
    This Script is used as a target for the https://servicepcglew-winutil.pages.dev/winutil.ps1dev alias.
.DESCRIPTION
    This Script provides a simple way to start the bleeding edge release of winutil.
.EXAMPLE
    irm https://servicepcglew-winutil.pages.dev/winutil.ps1dev | iex
    OR
    Run in Admin Powershell >  ./windev.ps1
#>

$latestTag = (Invoke-RestMethod "https://api.github.com/repos/ServicePCGlew/winutil/tags")[0].name
Invoke-RestMethod "https://github.com/servicepcglew/winutil/releases/download/$latestTag/winutil.ps1" | Invoke-Expression
