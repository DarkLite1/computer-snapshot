#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath = "$PSScriptRoot\..\Engine\Scripts\Firewall rules import export.ps1"
    Name       = 'Firewall rules'
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'Firewall rules import errors' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\" +
            'Firewall rules import export.ps1'
        # Pipeline-friendly stand-ins, like in the shared child contract tests
        function Remove-NetFirewallRule {
            param([Parameter(ValueFromPipeline)]$InputObject)
        }
        function Rename-NetFirewallRule {
            param([Parameter(ValueFromPipeline)]$InputObject, $NewName)
        }
    }
    BeforeEach {
        Mock Get-NetFirewallRule {
            [pscustomobject]@{ Name = $Name }
        } -ParameterFilter { $Name -like 'Existing*' }
        Mock Get-NetFirewallRule { } -ParameterFilter {
            $Name -notlike 'Existing*'
        }
        Mock New-NetFirewallRule
        Mock New-NetFirewallRule {
            throw 'The parameter is incorrect'
        } -ParameterFilter { $Protocol -eq 'BOGUS' }
        Mock Rename-NetFirewallRule
        Mock Remove-NetFirewallRule
    }
    It 'creates the bundled example rule, which leaves most settings empty' {
        $data = @(
            Get-Content -Raw -LiteralPath (
                "$PSScriptRoot\..\Shared\Examples\FirewallRules.json"
            ) | ConvertFrom-Json
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors.Count |
            Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages |
            Should -Be @("Created firewall rule 'Example' (Example)")
        Should -Invoke New-NetFirewallRule -Times 1 -Exactly -ParameterFilter {
            -not $PesterBoundParameters.ContainsKey('EdgeTraversalPolicy') -and
            -not $PesterBoundParameters.ContainsKey('InterfaceType')
        }
    }
    It 'replaces an existing rule only after the new rule was created' {
        $data = @(
            [pscustomobject]@{
                Name        = 'Existing'
                DisplayName = 'Existing'
                Direction   = 'Inbound'
                Action      = 'Allow'
            }
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Messages |
            Should -Be @("Replaced firewall rule 'Existing' (Existing)")
        $invokeParams = @{
            CommandName = 'Rename-NetFirewallRule'
            Times       = 1
            Exactly     = $true
        }
        Should -Invoke @invokeParams -ParameterFilter {
            $NewName -like 'Existing.backup-*'
        }
        Should -Invoke Remove-NetFirewallRule -Times 1 -Exactly
    }
    It 'keeps the existing rule when the new rule cannot be created' {
        $data = @(
            [pscustomobject]@{
                Name        = 'Existing'
                DisplayName = 'Existing'
                Direction   = 'Inbound'
                Action      = 'Allow'
                Protocol    = 'BOGUS'
            }
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors | Should -Be @(
            ("Failed to create firewall rule 'Existing' (Existing): " +
                'The parameter is incorrect')
        )
        $invokeParams = @{
            CommandName = 'Rename-NetFirewallRule'
            Times       = 1
            Exactly     = $true
        }
        Should -Invoke @invokeParams -ParameterFilter {
            $NewName -eq 'Existing'
        }
        Should -Invoke Remove-NetFirewallRule -Times 0 -Exactly
    }
    It 'reports a failed rule and still creates the next rule' {
        $data = @(
            [pscustomobject]@{
                Name        = 'Bad'
                DisplayName = 'Bad'
                Direction   = 'Inbound'
                Action      = 'Allow'
                Protocol    = 'BOGUS'
            }
            [pscustomobject]@{
                Name        = 'Fresh'
                DisplayName = 'Fresh'
                Direction   = 'Outbound'
                Action      = 'Block'
            }
        )

        $result = @(
            & $scriptPath -Action Import -Data $data -RootFolder $TestDrive
        )

        $result[0].Errors | Should -Be @(
            ("Failed to create firewall rule 'Bad' (Bad): " +
                'The parameter is incorrect')
        )
        $result[0].Messages |
            Should -Be @("Created firewall rule 'Fresh' (Fresh)")
    }
}

Describe 'Firewall rules export' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Engine\Scripts\" +
            'Firewall rules import export.ps1'
        $filterTypes = @(
            'Address', 'Port', 'Application', 'Service', 'Interface',
            'InterfaceType', 'Security'
        )
    }
    BeforeEach {
        Mock Get-NetFirewallRule {
            foreach ($id in @('{A}', '{B}', '{C}')) {
                [pscustomobject]@{
                    Name        = $id
                    InstanceID  = $id
                    DisplayName = "Rule $id"
                    Direction   = 'Inbound'
                    Enabled     = 'True'
                    Action      = 'Allow'
                    Profile     = 'Domain, Private'
                }
            }
        }
        # Every rule has each filter, except rule C its port filter
        foreach ($type in $filterTypes) {
            Mock "Get-NetFirewall${type}Filter" {
                foreach ($id in @('{A}', '{B}', '{C}')) {
                    [pscustomobject]@{
                        InstanceID = $id
                        Protocol   = 'TCP'
                        LocalPort  = @('80', '443')
                        Program    = "$env:ProgramFiles\App\app.exe"
                    }
                }
            }
        }
        Mock Get-NetFirewallPortFilter {
            foreach ($id in @('{A}', '{B}')) {
                [pscustomobject]@{
                    InstanceID = $id
                    Protocol   = 'TCP'
                    LocalPort  = @('80', '443')
                }
            }
        }
        Mock Write-Progress
    }
    It ('reads each filter type once for all rules, and reports a rule ' +
        'without its filter') {
        $result = & $scriptPath -Action Export -RootFolder $TestDrive

        $invokeParams = @{
            Times   = 1
            Exactly = $true
        }
        foreach ($type in $filterTypes) {
            $command = "Get-NetFirewall${type}Filter"
            Should -Invoke $command @invokeParams -ParameterFilter {
                $All -and $PolicyStore -eq 'ActiveStore'
            }
        }
        @($result.Data.Name) | Should -Be @('{A}', '{B}')
        $result.Data[0].LocalPort | Should -Be '80,443'
        $result.Data[0].Profile | Should -Be 'Domain,Private'
        $result.Data[0].Program | Should -Be '%ProgramFiles%\App\app.exe'
        $result.Errors | Should -Be @(
            "Failed to export firewall rule 'Rule {C}' ({C}): " +
            'no Port filter found'
        )
        $result.Messages | Should -Be @('Exported 2 firewall rules')
    }
    It 'shows the progress of the rules under the progress of the section' {
        $null = & $scriptPath -Action Export -RootFolder $TestDrive

        Should -Invoke Write-Progress -ParameterFilter {
            $Id -eq 1 -and $ParentId -eq 0 -and
            $Status -eq 'Rule 1 of 3' -and $PercentComplete -eq 33
        }
        Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter {
            $Id -eq 1 -and $Completed
        }
    }
}