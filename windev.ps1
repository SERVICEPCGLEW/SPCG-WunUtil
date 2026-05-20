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

Invoke-RestMethod "https://servicepcglew-winutil.pages.dev/winutil.ps1" | Invoke-Expression
