<#
    .SYNOPSIS
        Export or import firewall rules.

    .DESCRIPTION
        This script should be run on a machine that has its firewall rules 
        correctly configured with the action 'Export'. This will save the 
        current firewall rules. On another machine this data will be used to 
        restore the firewall rules.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DateFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER DataFolder
        Folder where to save or restore the firewall rules

    .EXAMPLE
        & 'C:\ImportExportFirewallRules.ps1' -DataFolder 'C:\FirewallRules' -Action 'Export'

        Export all firewall rules on the current machine to the folder 'FirewallRules'

    .EXAMPLE
        & 'C:\ImportExportFirewallRules.ps1' -DataFolder 'C:\FirewallRules' -Action 'Import'

        Restore all firewall rules in the folder 'FirewallRules' to the local machine
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$FirewallManagerModule = "$PSScriptRoot\Firewall-Manager",
    [String]$FileName = 'FirewallRules.csv'
)

Begin {
    Function Export-FirewallRulesHC {
        <#
        .SYNOPSIS
            Exports firewall rules to a '.csv' file

        .DESCRIPTION
            Export local and policy based firewall rules to a '.csv' file.
            All rules are exported by default, you can filter with parameter 
            -Name, -Inbound, -Outbound, -Enabled, -Disabled, -Allow and -Block

        .PARAMETER Name
            Display name of the rules to be processed. Wildcard character * is 
            allowed

        .PARAMETER PolicyStore
            Store from which the rules are retrieved (default: ActiveStore).
            Allowed values are PersistentStore, ActiveStore (the resultant rule 
            set of all sources), localhost, a computer name, <domain.fqdn.
            com>\<GPO_Friendly_Name>, RSOP and others depending on the 
            environment.
        
        .EXAMPLE
            Export-FirewallRulesHC -CsvFile 'C:\rules.csv'

            Exports all firewall rules to the file 'C:\rules.csv'

        .EXAMPLE
            Export-FirewallRulesHC -CsvFile 'C:\rules.csv' -Inbound -Allow

            Exports all inbound and firewall 'Allow' rules to the file 
            'C:\rules.csv'
        #>
        Param(
            [Parameter(Mandatory)]
            [String]$CsvFile, 
            [String]$Name = '*', 
            [String]$PolicyStore = 'ActiveStore', 
            [Switch]$Inbound, 
            [Switch]$Outbound, 
            [Switch]$Enabled, 
            [Switch]$Disabled, 
            [Switch]$Block, 
            [Switch]$Allow
        )
    
        function StringArrayToList($StringArray) {
            if ($StringArray) {
                $Result = ''
                Foreach ($Value In $StringArray) {
                    if ($Result -ne '') { $Result += ',' }
                    $Result += $Value
                }
                return $Result
            }
            else {
                return ''
            }
        }
    
        Try {
            #region Filter rules
            $Direction = '*'
            if ($Inbound -And !$Outbound) { $Direction = 'Inbound' }
            if (!$Inbound -And $Outbound) { $Direction = 'Outbound' }
    
            $RuleState = '*'
            if ($Enabled -And !$Disabled) { $RuleState = 'True' }
            if (!$Enabled -And $Disabled) { $RuleState = 'False' }
    
            $Action = '*'
            if ($Allow -And !$Block) { $Action = 'Allow' }
            if (!$Allow -And $Block) { $Action = 'Block' }
            #endregion
    
            #region Get firewall rules
            $firewallRules = Get-NetFirewallRule -DisplayName $Name -PolicyStore $PolicyStore | Where-Object { 
                $_.Direction -like $Direction -and 
                $_.Enabled -like $RuleState -And 
                $_.Action -like $Action 
            }
            #endregion
            
            #region Create firewall rule details for export
            $firewallRuleSet = ForEach ($rule In $firewallRules) {
                Write-Verbose "Firewall rule `"$($rule.DisplayName)`" ($($rule.Name))"
    
                $AddressFilter = $rule | Get-NetFirewallAddressFilter
                $PortFilter = $rule | Get-NetFirewallPortFilter
                $ApplicationFilter = $rule | Get-NetFirewallApplicationFilter
                $ServiceFilter = $rule | Get-NetFirewallServiceFilter
                $InterfaceFilter = $rule | Get-NetFirewallInterfaceFilter
                $InterfaceTypeFilter = $rule | Get-NetFirewallInterfaceTypeFilter
                $SecurityFilter = $rule | Get-NetFirewallSecurityFilter
    
                [PSCustomObject]@{
                    Name                = $rule.Name
                    DisplayName         = $rule.DisplayName
                    Description         = $rule.Description
                    Group               = $rule.Group
                    Enabled             = $rule.Enabled
                    Profile             = $rule.Profile
                    Platform            = StringArrayToList $rule.Platform
                    Direction           = $rule.Direction
                    Action              = $rule.Action
                    EdgeTraversalPolicy = $rule.EdgeTraversalPolicy
                    LooseSourceMapping  = $rule.LooseSourceMapping
                    LocalOnlyMapping    = $rule.LocalOnlyMapping
                    Owner               = $rule.Owner
                    LocalAddress        = StringArrayToList $AddressFilter.LocalAddress
                    RemoteAddress       = StringArrayToList $AddressFilter.RemoteAddress
                    Protocol            = $PortFilter.Protocol
                    LocalPort           = StringArrayToList $PortFilter.LocalPort
                    RemotePort          = StringArrayToList $PortFilter.RemotePort
                    IcmpType            = StringArrayToList $PortFilter.IcmpType
                    DynamicTarget       = $PortFilter.DynamicTarget
                    Program             = $ApplicationFilter.Program -Replace "$($ENV:SystemRoot.Replace("\","\\"))\\", "%SystemRoot%\" -Replace "$(${ENV:ProgramFiles(x86)}.Replace("\","\\").Replace("(","\(").Replace(")","\)"))\\", "%ProgramFiles(x86)%\" -Replace "$($ENV:ProgramFiles.Replace("\","\\"))\\", "%ProgramFiles%\"
                    Package             = $ApplicationFilter.Package
                    Service             = $ServiceFilter.Service
                    InterfaceAlias      = StringArrayToList $InterfaceFilter.InterfaceAlias
                    InterfaceType       = $InterfaceTypeFilter.InterfaceType
                    LocalUser           = $SecurityFilter.LocalUser
                    RemoteUser          = $SecurityFilter.RemoteUser
                    RemoteMachine       = $SecurityFilter.RemoteMachine
                    Authentication      = $SecurityFilter.Authentication
                    Encryption          = $SecurityFilter.Encryption
                    OverrideBlockRules  = $SecurityFilter.OverrideBlockRules
                }
            }
            #endregion
    
            $exportParams = @{
                LiteralPath       = $CsvFile 
                NoTypeInformation = $true
                Delimiter         = ';' 
                Encoding          = 'UTF8'
            }
            $firewallRuleSet | Export-Csv @exportParams
        }
        Catch {
            throw "Failed to export the firewall rules: $_"
        }
    }
    Function Import-FirewallRulesHC {
        <#
    .SYNOPSIS
        Imports firewall rules from a '.csv' file

    .DESCRIPTION
        Imports firewall rules from a '.csv' file. Existing rules with same 
        display name will be overwritten.

    .PARAMETER PolicyStore
        Store to which the rules are written (default: PersistentStore).
        Allowed values are PersistentStore, ActiveStore (the resultant rule 
        set of all sources), localhost, a computer name, 
        <domain.fqdn.com>\<GPO_Friendly_Name> and others depending on the 
        environment.

    .EXAMPLE
        Import-FirewallRulesHC -CsvFile 'C:\rules.csv'
            
        Import all firewall rules in the file 'C:\rules.csv'
    #>
    
        Param(
            [Parameter(Mandatory)]
            [String]$CsvFile, 
            [String]$PolicyStore = 'PersistentStore'
        )
    
        Function ListToStringArray {
            Param (
                [String]$List, 
                [String]$DefaultValue = 'Any'
            )
            if (![String]::IsNullOrEmpty($List)) {
                return ($List -split ',')
            }
            else {
                return $DefaultValue 
            }
        }
    
        Function ValueToBoolean {
            Param (
                [String]$Value,
                [Boolean]$DefaultValue = $false
            )
            if (![String]::IsNullOrEmpty($Value)) {
                if (($Value -eq 'True') -or ($Value -eq '1')) { 
                    return $true 
                }
                else {
                    return $false 
                }
            }
            else {
                return $DefaultValue
            }
        }
    
        Try {
            $importParams = @{
                LiteralPath = $CsvFile 
                Delimiter   = ';'  
                Encoding    = 'UTF8'
            }
            $firewallRules = Import-Csv @importParams
    
            ForEach ($rule In $firewallRules) {
                $newRuleParams = @{
                    Name                = $rule.Name
                    DisplayName         = $rule.DisplayName
                    Description         = $rule.Description
                    Group               = $rule.Group
                    Enabled             = $rule.Enabled
                    Profile             = $rule.Profile
                    Direction           = $rule.Direction
                    Action              = $rule.Action
                    EdgeTraversalPolicy = $rule.EdgeTraversalPolicy
                    LooseSourceMapping  = ValueToBoolean $rule.LooseSourceMapping
                    LocalOnlyMapping    = ValueToBoolean $rule.LocalOnlyMapping
                    LocalAddress        = ListToStringArray $rule.LocalAddress
                    RemoteAddress       = ListToStringArray $rule.RemoteAddress
                    Platform            = ListToStringArray $rule.Platform $null
                    Protocol            = $rule.Protocol
                    LocalPort           = ListToStringArray $rule.LocalPort
                    RemotePort          = ListToStringArray $rule.RemotePort
                    IcmpType            = ListToStringArray $rule.IcmpType
                    DynamicTarget       = if (
                        [String]::IsNullOrEmpty($rule.DynamicTarget)) { 'Any' } else { $rule.DynamicTarget }
                    Program             = $rule.Program
                    Service             = $rule.Service
                    InterfaceAlias      = ListToStringArray $rule.InterfaceAlias
                    InterfaceType       = $rule.InterfaceType
                    LocalUser           = $rule.LocalUser
                    RemoteUser          = $rule.RemoteUser
                    RemoteMachine       = $rule.RemoteMachine
                    Authentication      = $rule.Authentication
                    Encryption          = $rule.Encryption
                    OverrideBlockRules  = ValueToBoolean $rule.OverrideBlockRules
                }
                if (-not $rule.Platform) { $newRuleParams.Remove('Platform') }
    
                # for SID types no empty value is defined, so omit if not present
                if (![String]::IsNullOrEmpty($rule.Owner)) { 
                    $newRuleParams.Owner = $rule.Owner 
                }
                if (![String]::IsNullOrEmpty($rule.Package)) {
                    $newRuleParams.Package = $rule.Package 
                }

                $storeParam = @{
                    PolicyStore = $PolicyStore
                }
                Get-NetFirewallRule @storeParam -Name $rule.Name -EA Ignore | 
                Remove-NetFirewallRule
            
                Try {
                    Write-Verbose "Create firewall rule '$($rule.DisplayName)' '($($rule.Name))'"
                    $null = New-NetFirewallRule @newRuleParams @storeParam -EA Stop
                }
                Catch {
                    Write-Error "Failed to create firewall rule '$($rule.DisplayName)' '($($rule.Name))': $_"
                    $Error.RemoveAt(1)
                }
            }
        }
        Catch {
            throw "Failed to import the firewall rules: $_"
        }
    }

    Try {
        $csvFile = Join-Path -Path $DataFolder -ChildPath $FileName

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
            If (-not (Test-Path -LiteralPath $csvFile -PathType Leaf)) {
                throw "Firewall rules file '$csvFile' not found"
            }
        }
        #endregion
    }
    Catch {
        throw "$Action firewall rules failed: $_"
    }
}

Process {
    Try {
        If ($Action -eq 'Export') {
            Write-Verbose "Export firewall rules to file '$csvFile'"
            Export-FirewallRulesHC -CsvFile $csvFile
        }
        else {
            Write-Verbose "Import firewall rules from file '$csvFile'"
            Import-FirewallRulesHC -CsvFile $csvFile
        }
    }
    Catch {
        throw "$Action firewall rules failed: $_"
    }
}