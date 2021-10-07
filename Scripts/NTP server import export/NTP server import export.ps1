<#
    .SYNOPSIS
        Set the NTP server.

    .DESCRIPTION
        Read the NTP server name from an input file and set the NTP server.
        
    .PARAMETER Action
        When action is 'Import' the NTP server will be read from the import 
        file and it will be set on the current machine. When action is 'Export' 
        a template file is exported that can be edited by the user.

    .PARAMETER DataFolder
        Folder where the file can be found that contains the NTP server name.

    .PARAMETER FoldersFileName
        File containing a string representing the NTP server name.
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$NtpFileName = 'ntpServers.json'
)

Begin {
    Function Get-TimeServerHC {
        <#
        .SYNOPSIS
            Get the time server used on a specific computer
    
        .DESCRIPTION
            Get the time server used on a specific computer.
            The default is current computer.
    
        .EXAMPLE
            Get-TimeServerHC
            Get the time server on the current computer
            
        .EXAMPLE
            Get-TimeServerHC -ComputerName 'PC1', 'PC2'
            Get the time servers for PC1 and PC2
        #>
        [CmdletBinding()]
        Param (
            [String[]]$ComputerName = $env:COMPUTERNAME
        )
        
        process {
            $HKLM = 2147483650
        
            foreach ($Computer in $ComputerName) {
                try {
                    $Output = [PSCustomObject]@{
                        ComputerName = $Computer
                        TimeServer   = $null
                        Type         = $null
                        Description  = $null
                    }
                    $reg = [wmiClass]"\\$Computer\root\default:StdRegprov"
                    $key = 'SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
                        
                    $type = $reg.GetStringValue($HKLM, $key, 'Type')
                    $Output.Type = $Type.sValue
    
                    if ($Output.Type -eq 'NTP') {
                        $Output.Description = 'Get time from configured NTP source'
                        $server = $reg.GetStringValue($HKLM, $key, 'NtpServer')
                        $Output.TimeServer = ($server.sValue -split ',')[0]
                    }
                    else {
                        $Output.Description = 'Get time from the domain hierarchy'
                        $Output.TimeServer = w32tm /query /source
                    }
                    
                    $Output
                }
                catch {
                    Write-Error "Failed to get NTP server from computer '$Computer': $_"
                }
            }
        }
    }
    Function Set-SynchronizeTimeWithServerHC {
        Param (
            [Parameter(Mandatory)]
            [String[]]$ComputerName
        )

        $manualpeerlist = $ComputerName -join ' '

        w32tm /config /manualpeerlist:"$manualpeerlist" /syncfromflags:manual /update
    }
    Function Set-SynchronizeTimeWithDomainHC {
        w32tm /config /syncfromflags:domhier /update
    }

    Try {
        $ntpFile = Join-Path -Path $DataFolder -ChildPath $NtpFileName

        #region Test DataFolder
        If ($Action -eq 'Export') {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Export folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -ne 0) {
                throw "Export folder '$DataFolder' not empty"
            }
        }
        else {
            If (-not (Test-Path -LiteralPath $DataFolder -PathType Container)) {
                throw "Import folder '$DataFolder' not found"
            }
            If ((Get-ChildItem -Path $DataFolder | Measure-Object).Count -eq 0) {
                throw "Import folder '$DataFolder' empty"
            }
            If (-not (Test-Path -LiteralPath $ntpFile -PathType Leaf)) {
                throw "NTP file '$ntpFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action NTP servers failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            $timeServers = Get-TimeServerHC
            @{
                SyncTimeWithDomain = $timeServers.Type -eq 'NT5DS'
                TimeServerNames    = @(
                    $timeServers.TimeServer -split ' ' | Where-Object { $_ } |
                    ForEach-Object { $_.trim() }
                )
            } | 
            ConvertTo-Json | Out-File -LiteralPath $ntpFile -Encoding utf8

            Write-Output 'Exported NTP config'
        }
        else {            
            Write-Verbose "Import NTP config from file '$ntpFile'"
            $ntp = Get-Content -LiteralPath $ntpFile -Encoding UTF8 -Raw | 
            ConvertFrom-Json -EA Stop
            
            if ($ntp.SyncTimeWithDomain) {
                Write-Verbose 'Sync time with the domain'
                Set-SynchronizeTimeWithDomainHC
                Write-Output 'Time synchronized with the domain'
                Write-Output 'Custom time server names are disregarded'
            } 
            else {
                $timeServerNames = $ntp.TimeServerNames | Where-Object { $_ } | 
                ForEach-Object { $_.trim() }
                
                if ($timeServerNames) {
                    Write-Verbose "Sync time with servers '$timeServerNames'"
                    Set-SynchronizeTimeWithServerHC -ComputerName $timeServerNames
                    
                    Write-Output "Time synchronized with custom time servers '$timeServerNames'"
                }
                else {
                    throw 'No time server names found in the import file'
                }
            }    
           
            Restart-Service w32time
        }
    }
    Catch {
        throw "$Action NTP servers failed: $_"
    }
}