#Requires -Version 5.1
<#
.SYNOPSIS
    Export or import Firewall rules as a configuration section.
.DESCRIPTION
    Import creates each rule in the persistent store. An existing rule with
    the same Name is replaced, but only once the new rule has been created:
    when creating fails, the existing rule is kept. Settings that are empty
    or missing from the configuration use the Windows defaults. Each failed
    rule is reported in Errors and the remaining rules are still processed.
.PARAMETER Action
    Export captures data in memory. Import applies Data to Windows.
.PARAMETER Data
    Resolved section data. An empty section performs no operations.
.PARAMETER RootFolder
    Absolute USB root for asset paths. No configuration files are written here.
.OUTPUTS
    Exactly one object: Data (export only), a string array of Messages and a
    string array of Errors.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Export', 'Import')][string]$Action,
    $Data,
    [Parameter(Mandatory)][string]$RootFolder
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\Common\Section.ps1"

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
        Write-Verbose "Get firewall rules from '$PolicyStore'"

        $params = @{
            DisplayName = $Name
            PolicyStore = $PolicyStore
        }
        $firewallRules = @(
            Get-NetFirewallRule @params | Where-Object {
                $_.Direction -like $Direction -and
                $_.Enabled -like $RuleState -and
                $_.Action -like $Action
            }
        )
        #endregion

        #region Get the filters of all rules at once
        # One query per filter type instead of seven per rule: with
        # hundreds of rules, asking per rule takes minutes
        $filters = @{}
        foreach ($type in @(
                'Address', 'Port', 'Application', 'Service', 'Interface',
                'InterfaceType', 'Security'
            )) {
            $progressParams = @{
                Id       = 1
                ParentId = 0
                Activity = 'Firewall rules'
                Status   = (
                    "Read the $type filters of $($firewallRules.Count) rules"
                )
            }
            Write-Progress @progressParams
            $filters[$type] = @{}
            $filterParams = @{
                All         = $true
                PolicyStore = $PolicyStore
            }
            foreach ($filter in @(
                    & "Get-NetFirewall${type}Filter" @filterParams
                )) {
                $filters[$type][[string]$filter.InstanceID] = $filter
            }
        }
        #endregion

        #region Create firewall rule details for export
        # Known folders in program paths become environment variables
        $sysPattern = "$($ENV:SystemRoot.Replace("\","\\"))\\"
        $x86Folder = ${ENV:ProgramFiles(x86)}.Replace("\", "\\")
        $x86Folder = $x86Folder.Replace("(", "\(").Replace(")", "\)")
        $x86Pattern = "$x86Folder\\"
        $pfPattern = "$($ENV:ProgramFiles.Replace("\","\\"))\\"
        $ruleNumber = 0

        $firewallRuleSet = ForEach ($rule In $firewallRules) {
            $ruleNumber++
            if ($ruleNumber % 25 -eq 1) {
                $progressParams = @{
                    Id              = 1
                    ParentId        = 0
                    Activity        = 'Firewall rules'
                    Status          = (
                        "Rule $ruleNumber of $($firewallRules.Count)"
                    )
                    PercentComplete = [int](
                        100 * $ruleNumber / $firewallRules.Count
                    )
                }
                Write-Progress @progressParams
            }
            Write-Verbose (
                "Firewall rule `"$($rule.DisplayName)`" ($($rule.Name))"
            )
            try {
                $id = [string]$rule.InstanceID
                $missing = @(
                    $filters.Keys | Where-Object {
                        -not $filters[$_].ContainsKey($id)
                    } | Sort-Object
                )
                if ($missing.Count) {
                    throw "no $($missing -join ', ') filter found"
                }
                $AddressFilter = $filters.Address[$id]
                $PortFilter = $filters.Port[$id]
                $ApplicationFilter = $filters.Application[$id]
                $ServiceFilter = $filters.Service[$id]
                $InterfaceFilter = $filters.Interface[$id]
                $InterfaceTypeFilter = $filters.InterfaceType[$id]
                $SecurityFilter = $filters.Security[$id]

                $prog = $ApplicationFilter.Program
                $prog = $prog -Replace $sysPattern, "%SystemRoot%\"
                $prog = $prog -Replace $x86Pattern, "%ProgramFiles(x86)%\"
                $prog = $prog -Replace $pfPattern, "%ProgramFiles%\"

                [Ordered]@{
                    Name                = $rule.Name
                    DisplayName         = $rule.DisplayName
                    Description         = $rule.Description
                    Action              = [String]$rule.Action
                    Direction           = [String]$rule.Direction
                    Enabled             = ConvertTo-BooleanHC $rule.Enabled
                    Profile             = [String]$rule.Profile -replace ' '
                    Protocol            = $PortFilter.Protocol
                    LocalPort           = ConvertTo-StringArrayHC (
                        $PortFilter.LocalPort
                    )
                    RemotePort          = ConvertTo-StringArrayHC (
                        $PortFilter.RemotePort
                    )
                    IcmpType            = ConvertTo-StringArrayHC (
                        $PortFilter.IcmpType
                    )
                    DynamicTarget       = [String]$PortFilter.DynamicTarget
                    Group               = $rule.Group
                    Platform            = ConvertTo-StringArrayHC $rule.Platform
                    EdgeTraversalPolicy = [String]$rule.EdgeTraversalPolicy
                    LooseSourceMapping  = ConvertTo-BooleanHC (
                        $rule.LooseSourceMapping
                    )
                    LocalOnlyMapping    = ConvertTo-BooleanHC (
                        $rule.LocalOnlyMapping
                    )
                    Owner               = $rule.Owner
                    LocalAddress        = ConvertTo-StringArrayHC (
                        $AddressFilter.LocalAddress
                    )
                    RemoteAddress       = ConvertTo-StringArrayHC (
                        $AddressFilter.RemoteAddress
                    )
                    Program             = $prog
                    Package             = $ApplicationFilter.Package
                    Service             = $ServiceFilter.Service
                    InterfaceAlias      = ConvertTo-StringArrayHC (
                        $InterfaceFilter.InterfaceAlias
                    )
                    InterfaceType       = (
                        [String]$InterfaceTypeFilter.InterfaceType
                    )
                    LocalUser           = $SecurityFilter.LocalUser
                    RemoteUser          = $SecurityFilter.RemoteUser
                    RemoteMachine       = $SecurityFilter.RemoteMachine
                    Authentication      = (
                        [String]$SecurityFilter.Authentication
                    )
                    Encryption          = [String]$SecurityFilter.Encryption
                    OverrideBlockRules  = ConvertTo-BooleanHC (
                        $SecurityFilter.OverrideBlockRules
                    )
                }
            }
            catch {
                $errors.Add(
                    'Failed to export firewall rule ' +
                    "'$($rule.DisplayName)' ($($rule.Name)): " +
                    "$($_.Exception.Message)"
                )
            }
        }
        #endregion

        Write-Progress -Id 1 -Activity 'Firewall rules' -Completed
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
                LooseSourceMapping  = ConvertTo-BooleanHC (
                    $rule.LooseSourceMapping
                )
                LocalOnlyMapping    = ConvertTo-BooleanHC $rule.LocalOnlyMapping
                LocalAddress        = ConvertTo-StringArrayHC $rule.LocalAddress
                RemoteAddress       = ConvertTo-StringArrayHC (
                    $rule.RemoteAddress
                )
                Protocol            = $rule.Protocol
                LocalPort           = ConvertTo-StringArrayHC $rule.LocalPort
                RemotePort          = ConvertTo-StringArrayHC $rule.RemotePort
                IcmpType            = ConvertTo-StringArrayHC $rule.IcmpType
                DynamicTarget       = $rule.DynamicTarget
                Program             = $rule.Program
                Service             = $rule.Service
                InterfaceAlias      = ConvertTo-StringArrayHC (
                    $rule.InterfaceAlias
                )
                InterfaceType       = $rule.InterfaceType
                LocalUser           = $rule.LocalUser
                RemoteUser          = $rule.RemoteUser
                RemoteMachine       = $rule.RemoteMachine
                Authentication      = $rule.Authentication
                Encryption          = $rule.Encryption
                OverrideBlockRules  = ConvertTo-BooleanHC (
                    $rule.OverrideBlockRules
                )
            }
            if ($rule.Platform) {
                $newRuleParams.Platform = ConvertTo-StringArrayHC (
                    $rule.Platform
                )
            }
            if ($rule.Owner) {
                $newRuleParams.Owner = $rule.Owner
            }
            if ($rule.Package) {
                $newRuleParams.Package = $rule.Package
            }

            # Empty or missing settings use the Windows default; passing
            # $null to an enumeration parameter such as Profile or Direction
            # fails
            foreach ($key in @($newRuleParams.Keys)) {
                $value = $newRuleParams[$key]
                if (
                    $null -eq $value -or
                    ($value -is [string] -and $value -eq '')
                ) {
                    $newRuleParams.Remove($key)
                }
            }

            Try {
                Write-Verbose (
                    "Create firewall rule '$($rule.DisplayName)' " +
                    "'($($rule.Name))'"
                )

                #region Move an existing rule aside, so it can be restored
                $backupName = $null
                if ($rule.Name) {
                    $params = @{
                        Name        = $rule.Name
                        PolicyStore = $PolicyStore
                        ErrorAction = 'Ignore'
                    }
                    $existingRule = @(Get-NetFirewallRule @params)
                    if ($existingRule.Count) {
                        $backupName = '{0}.backup-{1}' -f $rule.Name, (
                            [guid]::NewGuid().ToString('N')
                        )
                        Write-Verbose (
                            "Rename existing rule '$($rule.Name)' " +
                            "to '$backupName'"
                        )
                        $existingRule |
                            Rename-NetFirewallRule -NewName $backupName
                    }
                }
                #endregion

                try {
                    $newRuleParams.PolicyStore = $PolicyStore
                    $null = New-NetFirewallRule @newRuleParams
                }
                catch {
                    $createError = $_
                    if ($backupName) {
                        Write-Verbose (
                            "Restore existing rule '$($rule.Name)' " +
                            "from '$backupName'"
                        )
                        try {
                            $params = @{
                                Name        = $backupName
                                PolicyStore = $PolicyStore
                            }
                            Get-NetFirewallRule @params |
                                Rename-NetFirewallRule -NewName $rule.Name
                        }
                        catch {
                            throw (
                                "$($createError.Exception.Message); " +
                                'the existing rule could not be restored ' +
                                "and is kept as '$backupName': " +
                                "$($_.Exception.Message)"
                            )
                        }
                    }
                    throw $createError
                }

                if ($backupName) {
                    Write-Verbose "Remove backup rule '$backupName'"
                    $params = @{
                        Name        = $backupName
                        PolicyStore = $PolicyStore
                    }
                    Get-NetFirewallRule @params | Remove-NetFirewallRule
                    $messages.Add(
                        "Replaced firewall rule '$($rule.DisplayName)' " +
                        "($($rule.Name))"
                    )
                }
                else {
                    $messages.Add(
                        "Created firewall rule '$($rule.DisplayName)' " +
                        "($($rule.Name))"
                    )
                }
            }
            Catch {
                $errors.Add(
                    'Failed to create firewall rule ' +
                    "'$($rule.DisplayName)' ($($rule.Name)): " +
                    "$($_.Exception.Message)"
                )
            }
        }
    }
    Catch {
        throw "Failed to import the firewall rules: $_"
    }
}
#endregion

$exportData = $null

# Lists, so the helper functions can add to them from their own scope
$messages = New-Object 'System.Collections.Generic.List[string]'
$errors = New-Object 'System.Collections.Generic.List[string]'

if ($Action -eq 'Import' -and (Test-EmptySectionHC $Data)) {
    Write-Verbose 'Import Firewall rules: empty section, nothing to do'
    return New-SectionResultHC -Messages 'Nothing to do'
}

if ($Action -eq 'Export') {
    #region Capture section
    Write-Verbose 'Export Firewall rules'
    $exportData = @(Export-FirewallRulesHC)
    #endregion

    $messages.Add("Exported $($exportData.Count) firewall rules")
}
else {
    #region Apply section
    Write-Verbose 'Import Firewall rules'
    Import-FirewallRulesHC -Data $Data
    #endregion
}

$resultParams = @{
    Data     = $exportData
    Messages = $messages
    Errors   = $errors
}
New-SectionResultHC @resultParams