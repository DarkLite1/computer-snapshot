#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\Common\Child contract.ps1" -ScriptPath "$PSScriptRoot\..\Scripts\Firewall rules import export.ps1" -Name 'Firewall rules'
Describe 'Firewall rules import errors' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\Firewall rules import export.ps1"
        # Pipeline-friendly stand-ins, like in the shared child contract tests
        function Remove-NetFirewallRule { param([Parameter(ValueFromPipeline)]$InputObject) }
        function Rename-NetFirewallRule { param([Parameter(ValueFromPipeline)]$InputObject, $NewName) }
    }
    BeforeEach {
        Mock Get-NetFirewallRule { [pscustomobject]@{ Name = $Name } } -ParameterFilter { $Name -like 'Existing*' }
        Mock Get-NetFirewallRule { } -ParameterFilter { $Name -notlike 'Existing*' }
        Mock New-NetFirewallRule
        Mock New-NetFirewallRule { throw 'The parameter is incorrect' } -ParameterFilter { $Protocol -eq 'BOGUS' }
        Mock Rename-NetFirewallRule
        Mock Remove-NetFirewallRule
    }
    It 'creates the bundled example rule, which leaves most settings empty' {
        $data = @(Get-Content -LiteralPath "$PSScriptRoot\..\Examples\FirewallRules.json" -Raw | ConvertFrom-Json)
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors.Count | Should -Be 0 -Because ($result[0].Errors -join '; ')
        $result[0].Messages | Should -Be @("Created firewall rule 'Example' (Example)")
        Should -Invoke New-NetFirewallRule -Times 1 -Exactly -ParameterFilter {
            -not $PSBoundParameters.ContainsKey('EdgeTraversalPolicy') -and -not $PSBoundParameters.ContainsKey('InterfaceType')
        }
    }
    It 'replaces an existing rule only after the new rule was created' {
        $data = @([pscustomobject]@{ Name = 'Existing'; DisplayName = 'Existing'; Direction = 'Inbound'; Action = 'Allow' })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Messages | Should -Be @("Replaced firewall rule 'Existing' (Existing)")
        Should -Invoke Rename-NetFirewallRule -Times 1 -Exactly -ParameterFilter { $NewName -like 'Existing.backup-*' }
        Should -Invoke Remove-NetFirewallRule -Times 1 -Exactly
    }
    It 'keeps the existing rule when the new rule cannot be created' {
        $data = @([pscustomobject]@{ Name = 'Existing'; DisplayName = 'Existing'; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'BOGUS' })
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to create firewall rule 'Existing' (Existing): The parameter is incorrect")
        Should -Invoke Rename-NetFirewallRule -Times 1 -Exactly -ParameterFilter { $NewName -eq 'Existing' }
        Should -Invoke Remove-NetFirewallRule -Times 0 -Exactly
    }
    It 'reports a failed rule and still creates the next rule' {
        $data = @(
            [pscustomobject]@{ Name = 'Bad'; DisplayName = 'Bad'; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'BOGUS' }
            [pscustomobject]@{ Name = 'Fresh'; DisplayName = 'Fresh'; Direction = 'Outbound'; Action = 'Block' }
        )
        $result = @(& $scriptPath -Action Import -Data $data -RootFolder $TestDrive)
        $result[0].Errors | Should -Be @("Failed to create firewall rule 'Bad' (Bad): The parameter is incorrect")
        $result[0].Messages | Should -Be @("Created firewall rule 'Fresh' (Fresh)")
    }
}