Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        InvokeWinUtilCurrentSystem -Checkbox "winget"

    #>

    param(
        $CheckBox
    )
    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).choco -split ";")
            if ($dependencies -in $apps) {
                Write-Output $psitem.name
            }
        }
    }

    if ($checkbox -eq "winget") {

        $originalEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        $rawOutput = winget list
        [Console]::OutputEncoding = $originalEncoding

        $sepIndex = -1
        for ($i = 0; $i -lt $rawOutput.Count; $i++) {
            if ($rawOutput[$i] -match '^[- ]+$' -and $rawOutput[$i] -match '-{10,}') {
                $sepIndex = $i
                break
            }
        }

        if ($sepIndex -gt 0) {
            $headerLine = $rawOutput[$sepIndex - 1]
            $matches = [regex]::Matches($headerLine, "\S+")
            $cols = @()
            foreach ($m in $matches) {
                $cols += [PSCustomObject]@{
                    Name  = $m.Value
                    Index = $m.Index
                }
            }
            for ($c = 0; $c -lt $cols.Count; $c++) {
                if ($c -lt $cols.Count - 1) {
                    $cols[$c] | Add-Member -NotePropertyName Length -NotePropertyValue ($cols[$c+1].Index - $cols[$c].Index)
                } else {
                    $cols[$c] | Add-Member -NotePropertyName Length -NotePropertyValue -1
                }
            }

            $Sync.InstalledPrograms = @()
            for ($i = $sepIndex + 1; $i -lt $rawOutput.Count; $i++) {
                $line = $rawOutput[$i]
                if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^<') {
                    continue
                }
                $obj = [PSCustomObject]@{}
                for ($c = 0; $c -lt $cols.Count; $c++) {
                    $idx = $cols[$c].Index
                    $len = $cols[$c].Length
                    if ($idx -ge $line.Length) {
                        $val = ""
                    } elseif ($len -eq -1) {
                        $val = $line.Substring($idx).Trim()
                    } else {
                        $val = $line.Substring($idx, [Math]::Min($len, $line.Length - $idx)).Trim()
                    }

                    $propName = switch ($c) {
                        0 { "Name" }
                        1 { "Id" }
                        2 { "Version" }
                        3 { if ($cols.Count -eq 4) { "Source" } else { "Available" } }
                        4 { "Source" }
                    }
                    $obj | Add-Member -NotePropertyName $propName -NotePropertyValue $val
                }
                $Sync.InstalledPrograms += $obj
            }
        } else {
            $Sync.InstalledPrograms = @()
        }

        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $appKey = $psitem.Key
            $appConfig = $sync.configs.applications.$appKey
            $dependencies = @($appConfig.winget -split ";")
            $dep = $dependencies[-1]
            $content = $appConfig.content

            $isInstalled = $false
            if ($dep) {
                $isInstalled = ($sync.InstalledPrograms | Where-Object {
                    $_.Id -eq $dep -or 
                    $_.Id -like "$dep.*" -or
                    ($dep.Contains(".") -and $_.Id -like "*$($dep.Split('.')[-1])*") -or
                    $_.Name -eq $content -or
                    ($content -and $content.Length -ge 4 -and $_.Name.Replace(" ", "").ToLower().Contains($content.Replace(" ", "").ToLower())) -or
                    ($content -and $content.Length -ge 4 -and $content.Replace(" ", "").ToLower().Contains($_.Name.Replace(" ", "").ToLower())) -or
                    ($appKey -eq "WPFInstalladobe" -and $_.Name -like "*Adobe Acrobat*") -or
                    ($dep -eq "9NKSQGP7F2NH" -and $_.Id -like "*5319275A.WhatsAppDesktop*") -or
                    ($dep -eq "9NBDXK71NK08" -and $_.Id -like "*5319275A.51895FA4EA97F*")
                }) -ne $null
            }

            if ($isInstalled) {
                Write-Output $psitem.name
            }
        }
    }

    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $appxKeys = $entry.appx
            $invokeScript = $entry.InvokeScript
            $entryType = $entry.Type

            if ($registryKeys -or $serviceKeys) {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path) {
                                $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            } else {
                if ($invokeScript -or $appxKeys) {
                    Write-Debug "Skipping $Config in Get Installed: no detectable registry, scheduled task, or service state."
                }
            }
        }
    }
}
