<#
    .SYNOPSIS
        Export or import firewall rules.

    .DESCRIPTION
        This script should be run on a computer that has its firewall rules 
        correctly configured with the action 'Export'. This will save the 
        current firewall rules. On another computer this data will be used to 
        restore the firewall rules.

    .PARAMETER Action
        When action is 'Export' the data will be saved in the $DateFolder, when 
        action is 'Import' the data in the $DataFolder will be restored.

    .PARAMETER DataFolder
        Folder where to save or restore the firewall rules

    .EXAMPLE
        $exportParams = @{
            Action     = 'Export'
            DataFolder = 'C:\FirewallRules'
        }
        & 'C:\ImportExportFirewallRules.ps1' @exportParams

        Export all firewall rules on the current computer to the folder 
        'FirewallRules'

    .EXAMPLE
        $importParams = @{
            Action     = 'Import'
            DataFolder = 'C:\FirewallRules'
        }
        & 'C:\ImportExportFirewallRules.ps1' @importParams

        Restore all firewall rules in the folder 'FirewallRules' to the local 
        computer
#>

[CmdletBinding()]
Param(
    [ValidateSet('Export', 'Import')]
    [Parameter(Mandatory)]
    [String]$Action,
    [Parameter(Mandatory)]
    [String]$DataFolder,
    [String]$FileName = 'FirewallRules.json'
)

Begin {
    Function Export-FirewallRulesHC {
        <#
            .SYNOPSIS
                Exports firewall rules to a '.json' file
    
            .DESCRIPTION
                Export local and policy based firewall rules to a '.json' file.
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
                Export-FirewallRulesHC -ExportFile 'C:\rules.json'
    
                Exports all firewall rules to the file 'C:\rules.json'
    
            .EXAMPLE
                Export-FirewallRulesHC -ExportFile 'C:\rules.json' -Inbound -Allow
    
                Exports all inbound and firewall 'Allow' rules to the file 
                'C:\rules.json'
            #>
        Param(
            [Parameter(Mandatory)]
            [String]$ExportFile, 
            [String]$Name = '*', 
            [String]$PolicyStore = 'ActiveStore', 
            [Switch]$Inbound, 
            [Switch]$Outbound, 
            [Switch]$Enabled, 
            [Switch]$Disabled, 
            [Switch]$Block, 
            [Switch]$Allow
        )
        
        Function ConvertTo-BooleanHC {
            Param (
                $Value
            )
            if ($Value -is [Boolean]) {
                $Value
            }
            else {
                if (($Value -eq 'True') -or ($Value -eq '1')) { 
                    $true 
                }
                else {
                    $false 
                }
            }
        }
        Function ConvertTo-StringArrayHC {
            Param(
                $StringArray
            )
            $Result = ''
            if ($StringArray) {
                Foreach ($Value In $StringArray) {
                    if ($Result -ne '') { $Result += ',' }
                    $Result += $Value
                }
            }
            $Result
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
        
                [Ordered]@{
                    Name                = $rule.Name
                    DisplayName         = $rule.DisplayName
                    Description         = $rule.Description
                    Action              = [String]$rule.Action
                    Direction           = [String]$rule.Direction
                    Enabled             = ConvertTo-BooleanHC $rule.Enabled
                    Profile             = [String]$rule.Profile -replace ' '
                    Protocol            = $PortFilter.Protocol
                    LocalPort           = ConvertTo-StringArrayHC $PortFilter.LocalPort
                    RemotePort          = ConvertTo-StringArrayHC $PortFilter.RemotePort
                    IcmpType            = ConvertTo-StringArrayHC $PortFilter.IcmpType
                    DynamicTarget       = [String]$PortFilter.DynamicTarget
                    Group               = $rule.Group
                    Platform            = ConvertTo-StringArrayHC $rule.Platform
                    EdgeTraversalPolicy = [String]$rule.EdgeTraversalPolicy
                    LooseSourceMapping  = ConvertTo-BooleanHC $rule.LooseSourceMapping
                    LocalOnlyMapping    = ConvertTo-BooleanHC $rule.LocalOnlyMapping
                    Owner               = $rule.Owner
                    LocalAddress        = ConvertTo-StringArrayHC $AddressFilter.LocalAddress
                    RemoteAddress       = ConvertTo-StringArrayHC $AddressFilter.RemoteAddress
                    Program             = $ApplicationFilter.Program -Replace "$($ENV:SystemRoot.Replace("\","\\"))\\", "%SystemRoot%\" -Replace "$(${ENV:ProgramFiles(x86)}.Replace("\","\\").Replace("(","\(").Replace(")","\)"))\\", "%ProgramFiles(x86)%\" -Replace "$($ENV:ProgramFiles.Replace("\","\\"))\\", "%ProgramFiles%\"
                    Package             = $ApplicationFilter.Package
                    Service             = $ServiceFilter.Service
                    InterfaceAlias      = ConvertTo-StringArrayHC $InterfaceFilter.InterfaceAlias
                    InterfaceType       = [String]$InterfaceTypeFilter.InterfaceType
                    LocalUser           = $SecurityFilter.LocalUser
                    RemoteUser          = $SecurityFilter.RemoteUser
                    RemoteMachine       = $SecurityFilter.RemoteMachine
                    Authentication      = [String]$SecurityFilter.Authentication
                    Encryption          = [String]$SecurityFilter.Encryption
                    OverrideBlockRules  = ConvertTo-BooleanHC $SecurityFilter.OverrideBlockRules
                }
            }
            #endregion
        
            $outParams = @{
                LiteralPath = $ExportFile 
                Encoding    = 'UTF8'
            }
            $firewallRuleSet | ConvertTo-Json | Out-File @outParams
            Write-Output "Exported $($firewallRuleSet.Count) firewall rules"
        }
        Catch {
            throw "Failed to export the firewall rules: $_"
        }
    }
    Function Import-FirewallRulesHC {
        <#
            .SYNOPSIS
                Imports firewall rules from a '.json' file
    
            .DESCRIPTION
                Imports firewall rules from a '.json' file. Existing rules with same 
                display name will be overwritten.
    
            .PARAMETER PolicyStore
                Store to which the rules are written (default: PersistentStore).
                Allowed values are PersistentStore, ActiveStore (the resultant rule 
                set of all sources), localhost, a computer name, 
                <domain.fqdn.com>\<GPO_Friendly_Name> and others depending on the 
                environment.
    
            .EXAMPLE
                Import-FirewallRulesHC -ImportFile 'C:\rules.json'
                    
                Import all firewall rules in the file 'C:\rules.json'
    
            .EXAMPLE
                Export-FirewallRulesHC -ExportFile '.\rules.json' -Verbose
    
                $getParams = @{
                    Path     = '.\rules.json'
                    Raw      = $true
                    Encoding = 'utf8'
                }
                $exportedRules = (Get-Content @getParams) | ConvertFrom-Json
    
                $rulesToImport = $exportedRules | Where-Object {
                    ($_.DisplayName -eq 'Logica') -or
                    ($_.DisplayName -eq 'CA Communication Beckhoff PLC') -or
                    ($_.DisplayName -eq 'Firebird DB Server') -or
                    ($_.DisplayName -eq 'SMB')
                }
    
                $outParams = @{
                    FilePath = '.\rules.json'
                    Encoding  = 'utf8'
                }
                $rulesToImport | ConvertTo-Json | Out-File @outParams
    
                Import-FirewallRulesHC -ImportFile $outParams.FilePath
    
                The first command exports the current firewall rules, then they 
                only the rules that need to be restored are selected and the file
                is updated. Om import only those selected rules will be restored.
            #>
        
        Param(
            [Parameter(Mandatory)]
            [String]$ImportFile, 
            [String]$PolicyStore = 'PersistentStore'
        )
        
        Function ConvertTo-StringArrayHC {
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
        Function ConvertTo-BooleanHC {
            Param (
                $Value
            )
            if ($Value -is [Boolean]) {
                $Value
            }
            else {
                if (($Value -eq 'True') -or ($Value -eq '1')) { 
                    $true 
                }
                else {
                    $false 
                }
            }
        }
        
        Try {
            $getParams = @{
                LiteralPath = $ImportFile 
                Encoding    = 'UTF8'
                Raw         = $true
            }
            $firewallRules = (Get-Content @getParams) | 
            ConvertFrom-Json -EA Stop
        
            ForEach ($rule In $firewallRules) {
                $newRuleParams = @{
                    Name                = $rule.Name
                    DisplayName         = $rule.DisplayName
                    Description         = $rule.Description
                    Group               = $rule.Group
                    Enabled             = if (
                        ConvertTo-BooleanHC $rule.Enabled
                    ) {
                        # only accepts a string not a boolean
                        'true'
                    }
                    else {
                        'false'
                    }
                    Profile             = $rule.Profile
                    Direction           = $rule.Direction
                    Action              = $rule.Action
                    EdgeTraversalPolicy = $rule.EdgeTraversalPolicy
                    LooseSourceMapping  = ConvertTo-BooleanHC $rule.LooseSourceMapping
                    LocalOnlyMapping    = ConvertTo-BooleanHC $rule.LocalOnlyMapping
                    LocalAddress        = ConvertTo-StringArrayHC $rule.LocalAddress
                    RemoteAddress       = ConvertTo-StringArrayHC $rule.RemoteAddress
                    Protocol            = $rule.Protocol
                    LocalPort           = ConvertTo-StringArrayHC $rule.LocalPort
                    RemotePort          = ConvertTo-StringArrayHC $rule.RemotePort
                    IcmpType            = ConvertTo-StringArrayHC $rule.IcmpType
                    DynamicTarget       = $rule.DynamicTarget
                    Program             = $rule.Program
                    Service             = $rule.Service
                    InterfaceAlias      = ConvertTo-StringArrayHC $rule.InterfaceAlias
                    InterfaceType       = $rule.InterfaceType
                    LocalUser           = $rule.LocalUser
                    RemoteUser          = $rule.RemoteUser
                    RemoteMachine       = $rule.RemoteMachine
                    Authentication      = $rule.Authentication
                    Encryption          = $rule.Encryption
                    OverrideBlockRules  = ConvertTo-BooleanHC $rule.OverrideBlockRules
                }
                if ($rule.Platform) { 
                    $newRuleParams.Platform = ConvertTo-StringArrayHC $rule.Platform
                }
                if ($rule.Owner) { 
                    $newRuleParams.Owner = $rule.Owner 
                }
                if ($rule.Package) {
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
                    Write-Output "Created firewall rule '$($newRuleParams.DisplayName) ($($newRuleParams.Name))'"

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
        $ExportFile = Join-Path -Path $DataFolder -ChildPath $FileName

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
            If (-not (Test-Path -LiteralPath $ExportFile -PathType Leaf)) {
                throw "Firewall rules file '$ExportFile' not found"
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
            Write-Verbose "Export firewall rules to file '$ExportFile'"
            Export-FirewallRulesHC -ExportFile $ExportFile
        }
        else {
            Write-Verbose "Import firewall rules from file '$ExportFile'"
            Import-FirewallRulesHC -ImportFile $ExportFile
        }
    }
    Catch {
        throw "$Action firewall rules failed: $_"
    }
}