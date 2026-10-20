#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

. "$PSScriptRoot\..\Common\Child contract.ps1" -ScriptPath $PSCommandPath.Replace('.Tests.ps1', '.ps1') -Name 'User accounts'