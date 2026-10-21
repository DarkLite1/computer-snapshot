#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Firewall rules as a configuration section.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only) and a string array of Messages.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
. "$PSScriptRoot\Common\Section.ps1"
#region Windows helpers
Function Export-FirewallRulesHC {
        
        Param(
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
            $firewallRules = Get-NetFirewallRule -DisplayName $Name -PolicyStore $PolicyStore | Where-Object { $_.Direction -like $Direction -and $_.Enabled -like $RuleState -and $_.Action -like $Action }
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
        
            return @($firewallRuleSet)
        }
        Catch {
            throw "Failed to export the firewall rules: $_"
        }
    }
Function Import-FirewallRulesHC {
        
        
        Param(
            [Parameter(Mandatory)]
            $Data, 
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
            
            $firewallRules = $Data
        
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
#endregion
$exportData = $null
$messages = @()
if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    return [pscustomobject]@{ Data = $null; Messages = [string[]]@('Nothing to do') }
}

if ($Action -eq 'Export') {
    #region Capture section
$exportData = @(Export-FirewallRulesHC)
    #endregion
    $messages = @('Exported Firewall rules')
}
else {
    #region Apply section
    $messages = @(& {
Import-FirewallRulesHC -Data $Data
    })
    #endregion
}
[pscustomobject]@{ Data = $exportData; Messages = [string[]]$messages }
