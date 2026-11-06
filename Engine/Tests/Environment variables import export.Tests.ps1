#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

$childContract = @{
    ScriptPath = (
        "$PSScriptRoot\..\Scripts\Environment variables import export.ps1"
    )
    Name       = 'Environment variables'
}
. "$PSScriptRoot\Common\Child contract.ps1" @childContract

Describe 'Environment variables' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot\..\Scripts\" +
            'Environment variables import export.ps1'
        function Get-EnvironmentVariablesHC { param($Scope) }
        function Set-EnvironmentVariableHC {
            param($Scope, $Name, $Value, $Kind)
        }
        function Send-EnvironmentChangeHC {}
    }
    BeforeEach {
        Mock Get-EnvironmentVariablesHC {
            [pscustomobject]@{
                Name  = 'Path'
                Value = '%SystemRoot%\system32;C:\Old vendor\;C:\Keep'
                Kind  = 'ExpandString'
            }
            [pscustomobject]@{
                Name  = 'ComSpec'
                Value = '%SystemRoot%\system32\cmd.exe'
                Kind  = 'ExpandString'
            }
            [pscustomobject]@{
                Name  = 'VENDOR_HOME'
                Value = 'C:\Vendor'
                Kind  = 'String'
            }
        } -ParameterFilter { $Scope -eq 'Machine' }
        Mock Get-EnvironmentVariablesHC {} -ParameterFilter {
            $Scope -eq 'User'
        }
        Mock Set-EnvironmentVariableHC
        Mock Send-EnvironmentChangeHC
        $importParams = @{ Action = 'Import'; RootFolder = $TestDrive }
    }
    It 'adds to and removes from Path, keeping the rest and its type' {
        $importParams.Data = @(
            [pscustomobject]@{
                Name   = 'Path'
                Action = 'AddToList'
                Values = @('c:\keep\', '%ProgramData%\Tools')
            }
            [pscustomobject]@{
                Name   = 'Path'
                Action = 'RemoveFromList'
                Values = @('C:\Old vendor')
            }
        )

        $result = & $scriptPath @importParams

        $result.Errors | Should -BeNullOrEmpty
        Should -Invoke Set-EnvironmentVariableHC -ParameterFilter {
            $Value -ceq (
                '%SystemRoot%\system32;C:\Old vendor\;C:\Keep;' +
                '%ProgramData%\Tools'
            ) -and $Kind -eq 'ExpandString' -and $Scope -eq 'Machine'
        } -Times 1 -Exactly
        Should -Invoke Set-EnvironmentVariableHC -ParameterFilter {
            $Value -ceq '%SystemRoot%\system32;C:\Keep;%ProgramData%\Tools'
        } -Times 1 -Exactly
        Should -Invoke Send-EnvironmentChangeHC -Times 1 -Exactly
    }
    It 'creates, changes and removes variables, for the computer or user' {
        $importParams.Data = @(
            [pscustomobject]@{ Name = 'TOOLS'; Value = '%ProgramData%\T' }
            [pscustomobject]@{ Name = 'VENDOR_HOME'; Value = 'D:\Vendor' }
            [pscustomobject]@{
                Name   = 'DEBUG'
                Scope  = 'User'
                Action = 'Remove'
            }
        )

        $result = & $scriptPath @importParams

        Should -Invoke Set-EnvironmentVariableHC -ParameterFilter {
            $Name -eq 'TOOLS' -and $Kind -eq 'ExpandString'
        } -Times 1 -Exactly
        Should -Invoke Set-EnvironmentVariableHC -ParameterFilter {
            $Name -eq 'VENDOR_HOME' -and $Kind -eq 'String'
        } -Times 1 -Exactly
        Should -Invoke Set-EnvironmentVariableHC -Times 2 -Exactly
        $result.Messages | Should -Be @(
            "Created Machine variable 'TOOLS' with '%ProgramData%\T'"
            ("Changed Machine variable 'VENDOR_HOME' from 'C:\Vendor' to " +
                "'D:\Vendor'")
            "User variable 'DEBUG' is already correct"
        )
    }
    It 'changes nothing when everything is already correct' {
        $importParams.Data = @(
            [pscustomobject]@{ Name = 'VENDOR_HOME'; Value = 'C:\Vendor' }
            [pscustomobject]@{
                Name   = 'Path'
                Action = 'AddToList'
                Values = @('C:\KEEP')
            }
        )

        $null = & $scriptPath @importParams

        Should -Invoke Set-EnvironmentVariableHC -Times 0 -Exactly
        Should -Invoke Send-EnvironmentChangeHC -Times 0 -Exactly
    }
    It 'reports a failed variable and still sets the next one' {
        Mock Set-EnvironmentVariableHC {
            throw 'access denied'
        } -ParameterFilter { $Name -eq 'A' }
        $importParams.Data = @(
            [pscustomobject]@{ Name = 'A'; Value = '1' }
            [pscustomobject]@{ Name = 'B'; Value = '2' }
        )

        $result = & $scriptPath @importParams

        $result.Errors | Should -Be @(
            "Failed to set Machine variable 'A': access denied"
        )
        Should -Invoke Set-EnvironmentVariableHC -ParameterFilter {
            $Name -eq 'B'
        } -Times 1 -Exactly
    }
    It 'exports the computer variables that are not part of Windows' {
        $result = & $scriptPath -Action Export -RootFolder $TestDrive

        @($result.Data).Count | Should -Be 1
        $result.Data[0].Name | Should -Be 'VENDOR_HOME'
        $result.Data[0].Value | Should -Be 'C:\Vendor'
    }
    It 'exports a value that looks like a secret as a placeholder' {
        Mock Get-EnvironmentVariablesHC {
            [pscustomobject]@{
                Name  = 'SMTP_PASSWORD'
                Value = 'Test-only secret'
                Kind  = 'String'
            }
        } -ParameterFilter { $Scope -eq 'Machine' }

        $result = & $scriptPath -Action Export -RootFolder $TestDrive

        $result.Data[0].Value |
            Should -Be '{{password:Value of environment variable SMTP_PASSWORD}}'
        $result.Messages -join ';' | Should -Not -Match 'Test-only secret'
    }
    It 'checks Value and Values against the Action' {
        Import-Module (
            "$PSScriptRoot\..\Common\Configuration.psm1"
        ) -Force
        $test = {
            param([object[]]$Entries)
            $configuration = @{
                SchemaVersion = 3
                Items         = @{ EnvironmentVariables = $Entries }
            }
            @(Test-ConfigurationHC $configuration $TestDrive) -join ';'
        }

        & $test @(
            @{ Name = 'A'; Value = '1' }
            @{ Name = 'Path'; Action = 'AddToList'; Values = @('C:\T') }
            @{ Name = 'B'; Scope = 'User'; Action = 'Remove' }
        ) | Should -BeNullOrEmpty
        & $test @(@{ Name = 'A' }) |
            Should -Match '\[0\]\.Value: required for Action Set'
        & $test @(@{ Name = 'Path'; Action = 'AddToList'; Values = @() }) |
            Should -Match '\[0\]\.Values: required for Action AddToList'
        & $test @(@{ Name = 'A'; Action = 'Remove'; Value = '1' }) |
            Should -Match 'Value: not used with Action Remove'
        & $test @(@{ Name = 'A=B'; Value = '1' }) |
            Should -Match "Name: expected a variable name without '='"
        & $test @(
            @{ Name = 'Path'; Action = 'AddToList'; Values = @('C:\A;C:\B') }
        ) | Should -Match "expected a list entry without ';'"
    }
}
