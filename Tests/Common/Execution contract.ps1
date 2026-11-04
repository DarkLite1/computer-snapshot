Describe 'Single-file execution' {
    BeforeAll {
        $scriptsFolder = Join-Path $PSScriptRoot '..\..\Scripts'
        Import-Module "$scriptsFolder\Common\Execution.psm1" -Force
        Import-Module "$scriptsFolder\Common\Configuration.psm1" -Force
        $scriptPath = Join-Path $scriptsFolder 'Folders import export.ps1'
        $inModule = @{ ModuleName = 'Execution' }
        . "$PSScriptRoot\Restore input.ps1"
    }
    BeforeEach {
        $path = Join-Path $TestDrive (
            ([guid]::NewGuid().ToString('N')) + '.json'
        )
        $params = @{
            Action              = 'CreateSnapshot'
            ConfigurationFile   = $path
            RootFolder          = $TestDrive
            Script              = [ordered]@{
                UserAccounts  = $scriptPath
                CreateFolders = $scriptPath
            }
            Items               = @('CreateFolders', 'UserAccounts')
            OpenReportInBrowser = $false
        }
        Mock Write-SnapshotReportHC @inModule {
            Join-Path $TestDrive 'report.html'
        }
        Mock Test-ElevatedHC @inModule { $true }
        Mock Write-Host @inModule
        Mock Write-Warning @inModule
        Mock Start-ComputerRestartHC @inModule
        Mock Start-Process @inModule
        Mock Invoke-ChildScriptHC @inModule {
            [pscustomobject]@{
                Data     = @()
                Messages = [string[]]@('Exported')
                Errors   = [string[]]@()
            }
        }
        Mock Read-RestoreInputHC @inModule {
            throw 'Unexpected input prompt in test.'
        }
    }
    It 'writes exactly one file and creates no folders' {
        $params.Items = @('UserAccounts')
        $before = @(Get-ChildItem $TestDrive -Recurse).Count
        $result = Invoke-ComputerSnapshotHC @params
        @(Get-ChildItem $TestDrive -Recurse).Count | Should -Be ($before + 1)
        @(Get-ChildItem $TestDrive -Directory).Count | Should -Be 0
        $path | Should -Exist
        $configuration = Read-ConfigurationHC $path $TestDrive
        @(Test-ConfigurationHC $configuration $TestDrive).Count |
            Should -Be 0
        $result.Success | Should -BeTrue
    }
    It 'rejects an existing file before any child runs unless Force is used' {
        'existing' | Set-Content $path
        { Invoke-ComputerSnapshotHC @params } |
            Should -Throw '*already exists*'
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
        $params.Items = @('UserAccounts')
        Invoke-ComputerSnapshotHC @params -Force
        $configuration = Read-ConfigurationHC $path $TestDrive
        @(Test-ConfigurationHC $configuration $TestDrive).Count |
            Should -Be 0
    }
    It 'keeps successful sections when another export throws' {
        $params.Script.CreateFolders = Join-Path $PSScriptRoot (
            '..\..\Scripts\User accounts import export.ps1'
        )
        Mock Invoke-ChildScriptHC @inModule -ParameterFilter {
            $Path -like '*User accounts import export.ps1'
        } -MockWith {
            throw 'Export failed'
        }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeFalse
        $loaded = Read-ConfigurationHC $path $TestDrive
        @($loaded.Items.Keys) | Should -Be @('UserAccounts')
    }
    It 'writes no configuration when all exports fail' {
        Mock Invoke-ChildScriptHC @inModule { throw 'Export failed' }
        { Invoke-ComputerSnapshotHC @params } |
            Should -Throw '*No items exported*'
        $path | Should -Not -Exist
    }
    It 'runs no child scripts if restore validation fails' {
        '{"SchemaVersion":1,"Items":{"Unknown":{}}}' | Set-Content $path
        $params.Action = 'RestoreSnapshot'
        { Invoke-ComputerSnapshotHC @params } |
            Should -Throw '*No items executed*'
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
        Should -Invoke Write-SnapshotReportHC @inModule -Times 1 -Exactly
    }
    It 'restores in fixed order independently of JSON key order' {
        $document = @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $false }
            Items         = [ordered]@{
                CreateFolders = @{ FolderPaths = @('C:\Example') }
                UserAccounts  = @(@{ Name = 'Example' })
            }
        }
        Write-ConfigurationHC $document $path
        $params.Action = 'RestoreSnapshot'
        $script:order = New-Object 'System.Collections.Generic.List[string]'
        Mock Invoke-ChildScriptHC @inModule {
            if (-not $Data.FolderPaths) {
                $Data.GetType().IsArray | Should -BeTrue
            }
            $script:order.Add($(
                    if ($Data.FolderPaths) {
                        'CreateFolders'
                    }
                    else {
                        'UserAccounts'
                    }
                ))
            [pscustomobject]@{
                Data     = $null
                Messages = [string[]]@('Imported')
                Errors   = [string[]]@()
            }
        }
        Invoke-ComputerSnapshotHC @params
        @($script:order) | Should -Be @('UserAccounts', 'CreateFolders')
    }
    It 'skips and reports empty sections' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $false }
            Items         = @{ UserAccounts = @() }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Remove('Items')
        $result = Invoke-ComputerSnapshotHC @params
        $result.Results[0].Status | Should -Be 'Skipped'
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
    }
    It ('reports a failed time-service operation and never reboots ' +
        'after it') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{
                OpenReportInBrowser = $false
                RebootComputer      = $true
            }
            Items         = @{
                NtpTimeServers = @{
                    SyncTimeWithDomain = $true
                    TimeServerNames    = @()
                }
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Remove('Items')
        $params.Script = [ordered]@{
            NtpTimeServers = Join-Path $PSScriptRoot (
                '..\..\Scripts\NTP time servers import export.ps1'
            )
        }
        Mock Invoke-ChildScriptHC @inModule {
            throw ('w32tm /resync failed with exit code 1: ' +
                'No time data available')
        }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeFalse
        $result.Results[0].Status | Should -Be 'Failed'
        $result.Results[0].Messages[0] | Should -Match 'exit code 1'
        Should -Invoke Start-ComputerRestartHC @inModule -Times 0 -Exactly
        Should -Invoke Write-SnapshotReportHC @inModule -Times 1 -Exactly
    }
    It ('restores only selected sections without changing the ' +
        'configuration file') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $false }
            Items         = @{
                UserAccounts  = @(@{ Name = 'Example' })
                CreateFolders = @{ FolderPaths = @('C:\Example') }
            }
        } $path
        $before = Get-Content -LiteralPath $path -Raw
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('CreateFolders')
        $result = Invoke-ComputerSnapshotHC @params
        @($result.Results.Name) | Should -Be @('CreateFolders')
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = { $Data.FolderPaths -contains 'C:\Example' }
        }
        Should -Invoke Invoke-ChildScriptHC @invoke
        (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $before
    }
    It ('does not resolve references or validate assets in unchecked ' +
        'sections') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $false }
            Items         = @{
                UserAccounts  = 'missing-users.json'
                Software      = @{
                    Install = @(@{ ExecutablePath = 'missing-installer.exe' })
                }
                CreateFolders = @{ FolderPaths = @('C:\Example') }
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('CreateFolders')
        (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 1 -Exactly
    }
    It 'restores all configured sections when no selection is supplied' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $false }
            Items         = @{
                UserAccounts  = @(@{ Name = 'Example' })
                CreateFolders = @{ FolderPaths = @('C:\Example') }
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Remove('Items')
        $result = Invoke-ComputerSnapshotHC @params
        @($result.Results.Name) |
            Should -Be @('UserAccounts', 'CreateFolders')
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 2 -Exactly
    }
    It ('honors both true and false per-run settings without changing ' +
        'the file') {
        foreach ($override in @($false, $true)) {
            Write-ConfigurationHC @{
                SchemaVersion = 3
                Settings      = @{
                    RebootComputer      = -not $override
                    OpenReportInBrowser = -not $override
                }
                Items         = @{ UserAccounts = @(@{ Name = 'Example' }) }
            } $path
            $before = Get-Content -LiteralPath $path -Raw
            $params.Action = 'RestoreSnapshot'
            $params.Items = @('UserAccounts')
            $params.RebootComputer = $override
            $params.OpenReportInBrowser = $override
            (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue
            (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $before
            $expected = [int]$override
            $invoke = @{
                ModuleName = 'Execution'
                Times      = $expected
                Exactly    = $true
            }
            Should -Invoke Start-ComputerRestartHC @invoke
            Should -Invoke Start-Process @invoke
        }
    }
    It 'uses saved settings when overrides are omitted' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{
                RebootComputer      = $true
                OpenReportInBrowser = $true
            }
            Items         = @{ UserAccounts = @(@{ Name = 'Example' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $params.Remove('OpenReportInBrowser')
        (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue
        Should -Invoke Start-ComputerRestartHC @inModule -Times 1 -Exactly
        Should -Invoke Start-Process @inModule -Times 1 -Exactly
    }
    It 'does not reboot after a failed restore even when overridden to true' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{
                RebootComputer      = $false
                OpenReportInBrowser = $false
            }
            Items         = @{ UserAccounts = @(@{ Name = 'Example' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $params.RebootComputer = $true
        Mock Invoke-ChildScriptHC @inModule { throw 'Restore failed' }
        (Invoke-ComputerSnapshotHC @params).Success | Should -BeFalse
        Should -Invoke Start-ComputerRestartHC @inModule -Times 0 -Exactly
    }
    It ('collects selected shared-section inputs before execution, ' +
        'redacts passwords, and preserves source files') {
        $sharedPath = Join-Path $TestDrive 'users.json'
        ('[{"Name":"{{input:Local account}}",' +
            '"Password":"{{password:Local password}}"}]') |
            Set-Content -LiteralPath $sharedPath
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $false }
            Items         = @{
                UserAccounts = 'users.json'
                Software     = @{
                    Install = @(
                        @{ ExecutablePath = '{{input:Unselected installer}}' }
                    )
                }
            }
        } $path
        $before = Get-Content -LiteralPath $path -Raw
        $sharedBefore = Get-Content -LiteralPath $sharedPath -Raw
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Read-RestoreInputHC @inModule {
            $answer = {
                param($Field)
                Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
                if ($Field.Kind -eq 'password') {
                    'Test-secret!42'
                }
                else {
                    'Example'
                }
            }
            & (New-FakeReadValuesHC $answer) $Questions
        }
        Mock Invoke-ChildScriptHC @inModule {
            $Data[0].Name | Should -Be 'Example'
            $Data[0].Password | Should -Be 'Test-secret!42'
            [pscustomobject]@{
                Data     = $null
                Messages = [string[]]@('Applied Test-secret!42')
                Errors   = [string[]]@()
            }
        }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeTrue
        $result.Results[0].Messages | Should -Be @('Applied [redacted]')
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                @($Questions.Kind) -join ',' -eq 'input,password'
            }
        }
        Should -Invoke Read-RestoreInputHC @invoke
        (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $before
        (Get-Content -LiteralPath $sharedPath -Raw) |
            Should -BeExactly $sharedBefore
    }
    It ('cancels before any script, report or reboot when an input ' +
        'dialog is cancelled') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ RebootComputer = $true }
            Items         = @{
                UserAccounts = @(@{ Name = '{{input:Account}}' })
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Read-RestoreInputHC @inModule { $null }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Cancelled | Should -BeTrue
        $result.Success | Should -BeFalse
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
        Should -Invoke Write-SnapshotReportHC @inModule -Times 0 -Exactly
        Should -Invoke Start-ComputerRestartHC @inModule -Times 0 -Exactly
        Should -Invoke Start-Process @inModule -Times 0 -Exactly
    }
    It ('gives the answers for placeholders in a copied file to the ' +
        'copy, and asks before any child runs') {
        $null = New-Item -Path "$TestDrive\Files" -ItemType Directory -Force
        'url=http://{{ipv4:Terminal server}}:1353' |
            Set-Content -LiteralPath "$TestDrive\Files\Start.ps1"
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $false }
            Items         = @{
                CopyFilesFolders = @(
                    @{
                        From             = 'Files\Start.ps1'
                        To               = 'C:\HC\Start.ps1'
                        FillPlaceholders = $true
                    }
                )
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('CopyFilesFolders')
        $params.Script = [ordered]@{ CopyFilesFolders = $scriptPath }
        Mock Read-RestoreInputHC @inModule {
            $answer = {
                param($Field)
                Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
                '10.20.60.47'
            }
            & (New-FakeReadValuesHC $answer) $Questions
        }
        Mock Invoke-ChildScriptHC @inModule {
            $Data[0].PlaceholderValues['{{ipv4:Terminal server}}'] |
                Should -Be '10.20.60.47'
            [pscustomobject]@{
                Data     = $null
                Messages = [string[]]@('Copied')
                Errors   = [string[]]@()
            }
        }
        (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue
        Should -Invoke Read-RestoreInputHC @inModule -Times 1 -Exactly
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 1 -Exactly
    }
    It ('gives each copied file only its own answers and never a ' +
        'password') {
        $null = New-Item -Path "$TestDrive\Files" -ItemType Directory -Force
        'a={{input:First}}' |
            Set-Content -LiteralPath "$TestDrive\Files\First.txt"
        'b={{ipv4:Second}}' |
            Set-Content -LiteralPath "$TestDrive\Files\Second.txt"
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $false }
            Items         = @{
                UserAccounts     = @(
                    @{
                        Name     = 'Example'
                        Password = '{{password:Password}}'
                    }
                )
                CopyFilesFolders = @(
                    @{
                        From             = 'Files\First.txt'
                        To               = "$TestDrive\Out\First.txt"
                        FillPlaceholders = $true
                    }
                    @{
                        From             = 'Files\Second.txt'
                        To               = "$TestDrive\Out\Second.txt"
                        FillPlaceholders = $true
                    }
                )
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts', 'CopyFilesFolders')
        $params.Script = [ordered]@{
            UserAccounts     = $scriptPath
            CopyFilesFolders = Join-Path $scriptsFolder (
                'Copy files folders import export.ps1'
            )
        }
        Mock Read-RestoreInputHC @inModule {
            $answer = {
                param($Field)
                switch ($Field.Kind) {
                    'password' {
                        'Test-secret!42'
                    }
                    'input' {
                        'alpha'
                    }
                    'ipv4' {
                        '192.0.2.20'
                    }
                }
            }
            & (New-FakeReadValuesHC $answer) $Questions
        }
        $mockParams = @{
            ModuleName      = 'Execution'
            ParameterFilter = { $Path -like '*Copy files folders*' }
        }
        Mock Invoke-ChildScriptHC @mockParams -MockWith {
            @($Data[0].PlaceholderValues.Keys) |
                Should -BeExactly @('{{input:First}}')
            @($Data[1].PlaceholderValues.Keys) |
                Should -BeExactly @('{{ipv4:Second}}')
            $Data | ForEach-Object { $_.PlaceholderValues.Values } |
                Should -Not -Contain 'Test-secret!42'

            & $Path -Action $Action -Data $Data -RootFolder $RootFolder
        }

        $result = Invoke-ComputerSnapshotHC @params

        $result.Success | Should -BeTrue
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = { @($Questions).Count -eq 3 }
        }
        Should -Invoke Read-RestoreInputHC @invoke
        Get-Content -LiteralPath "$TestDrive\Out\First.txt" |
            Should -BeExactly 'a=alpha'
        Get-Content -LiteralPath "$TestDrive\Out\Second.txt" |
            Should -BeExactly 'b=192.0.2.20'
    }
    It 'redacts prompted passwords from child failure results and reports' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                UserAccounts = @(
                    @{ Name = 'Example'; Password = '{{password:Password}}' }
                )
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Read-RestoreInputHC @inModule {
            & (New-FakeReadValuesHC { 'Test-secret!42' }) $Questions
        }
        Mock Invoke-ChildScriptHC @inModule { throw 'Rejected Test-secret!42' }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeFalse
        $result.Results[0].Messages |
            Should -Be @('ERROR: Rejected [redacted]')
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                $Results[0].Messages -notmatch 'Test-secret'
            }
        }
        Should -Invoke Write-SnapshotReportHC @invoke
    }
    It ('reports a configuration problem before asking for any input, ' +
        'and asks for nothing') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                UserAccounts = @(
                    @{ Name = 'Example'; Password = '{{password:Password}}' }
                )
                Software     = @{
                    Install = @(@{ ExecutablePath = 'Missing\setup.exe' })
                }
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts', 'Software')
        $params.Script = [ordered]@{
            UserAccounts = $scriptPath
            Software     = $scriptPath
        }

        { Invoke-ComputerSnapshotHC @params } |
            Should -Throw '*validation failed*'

        Should -Invoke Read-RestoreInputHC @inModule -Times 0 -Exactly
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                $Results[0].Messages -match
                "Install\[0\]\.ExecutablePath: file 'Missing\\setup\.exe'"
            }
        }
        Should -Invoke Write-SnapshotReportHC @invoke
    }
    It ('accepts prefix and IPv4 placeholders before the input and asks ' +
        'each once') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                NetworkCards = @(
                    @{
                        FindBy = @{ Name = 'Ethernet' }
                        Change = @{
                            IPSettings = @{
                                IPAddress      = '{{ipv4:Address}}'
                                PrefixLength   = '{{prefix:Prefix}}'
                                DefaultGateway = '{{ipv4:Gateway}}'
                                DNSServers     = @('{{ipv4:Gateway}}')
                            }
                        }
                    }
                )
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('NetworkCards')
        $params.Script = [ordered]@{ NetworkCards = $scriptPath }
        Mock Read-RestoreInputHC @inModule {
            $answer = {
                param($Field)
                switch ($Field.Kind) {
                    'prefix' {
                        '24'
                    }
                    default {
                        if ($Field.Description -eq 'Address') {
                            '192.0.2.10'
                        }
                        else {
                            '192.0.2.1'
                        }
                    }
                }
            }
            & (New-FakeReadValuesHC $answer) $Questions
        }
        Mock Invoke-ChildScriptHC @inModule {
            $settings = $Data[0].Change.IPSettings
            $settings.PrefixLength | Should -Be 24
            $settings.DefaultGateway | Should -Be '192.0.2.1'
            [pscustomobject]@{
                Data     = $null
                Messages = [string[]]@('Applied')
                Errors   = [string[]]@()
            }
        }

        (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue

        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = { @($Questions).Count -eq 3 }
        }
        Should -Invoke Read-RestoreInputHC @invoke
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 1 -Exactly
    }
    Context 'a number placeholder' {
        BeforeEach {
            Write-ConfigurationHC @{
                SchemaVersion = 3
                Items         = @{
                    Software = @{
                        Install = @(
                            @{
                                ExecutablePath = 'C:\Windows\notepad.exe'
                                TimeoutMinutes = '{{number:Minutes}}'
                            }
                            @{
                                ExecutablePath = 'C:\Windows\notepad.exe'
                                TimeoutMinutes = '{{number:Minutes}}'
                            }
                        )
                    }
                }
            } $path
            $params.Action = 'RestoreSnapshot'
            $params.Items = @('Software')
            $params.Script = [ordered]@{ Software = $scriptPath }
        }
        It ('passes the check before input, is asked once and reaches the ' +
            'section as a number') {
            Mock Read-RestoreInputHC @inModule {
                & (New-FakeReadValuesHC { '30' }) $Questions
            }
            Mock Invoke-ChildScriptHC @inModule {
                foreach ($install in $Data.Install) {
                    $install.TimeoutMinutes | Should -BeOfType [int]
                    $install.TimeoutMinutes | Should -Be 30
                }
                [pscustomobject]@{
                    Data     = $null
                    Messages = [string[]]@('Applied')
                    Errors   = [string[]]@()
                }
            }

            (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue

            Should -Invoke Read-RestoreInputHC @inModule -Times 1 -Exactly
            Should -Invoke Invoke-ChildScriptHC @inModule -Times 1 -Exactly
        }
        It 'refuses the prompt answer abc before any section runs' {
            Mock Read-RestoreInputHC @inModule {
                & (New-FakeReadValuesHC { 'abc' }) $Questions
            }

            { Invoke-ComputerSnapshotHC @params } |
                Should -Throw '*validation failed*'

            Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
            $invoke = @{
                ModuleName      = 'Execution'
                Times           = 1
                Exactly         = $true
                ParameterFilter = {
                    $Results[0].Messages -match (
                        'TimeoutMinutes: the supplied input is empty or ' +
                        'invalid'
                    )
                }
            }
            Should -Invoke Write-SnapshotReportHC @invoke
        }
        It 'refuses the answer file answer abc before any section runs' {
            $answerPath = Join-Path $TestDrive 'number.answers.json'
            '{"Answers":{"{{number:Minutes}}":"abc"}}' |
                Set-Content -LiteralPath $answerPath
            $params.AnswerFile = $answerPath
            $params.Unattended = $true

            { Invoke-ComputerSnapshotHC @params } |
                Should -Throw '*validation failed*'

            Should -Invoke Read-RestoreInputHC @inModule -Times 0 -Exactly
            Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
            $invoke = @{
                ModuleName      = 'Execution'
                Times           = 1
                Exactly         = $true
                ParameterFilter = {
                    $Results[0].Messages -match (
                        'must be a nonempty, valid number string or number'
                    )
                }
            }
            Should -Invoke Write-SnapshotReportHC @invoke
        }
    }
    It ('fails before any section when an answer is invalid where it is ' +
        'used') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                NetworkCards = @(
                    @{
                        FindBy = @{ Name = 'Ethernet' }
                        Change = @{
                            IPSettings = @{
                                IPAddress      = '{{ipv4:Address}}'
                                PrefixLength   = 24
                                DefaultGateway = '192.0.2.1'
                            }
                        }
                    }
                )
            }
        } $path
        $answerPath = Join-Path $TestDrive 'subnet.answers.json'
        '{"Answers":{"{{ipv4:Address}}":"198.51.100.10"}}' |
            Set-Content -LiteralPath $answerPath
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('NetworkCards')
        $params.Script = [ordered]@{ NetworkCards = $scriptPath }
        $params.AnswerFile = $answerPath
        $params.Unattended = $true

        { Invoke-ComputerSnapshotHC @params } |
            Should -Throw '*validation failed*'

        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                $Results[0].Messages -match 'is not in the subnet'
            }
        }
        Should -Invoke Write-SnapshotReportHC @invoke
    }
    It ('validates resolved values before any child runs and redacts ' +
        'validation messages') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                Software = @{
                    Install = @(
                        @{ ExecutablePath = '{{password:Installer path}}' }
                    )
                }
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('Software')
        Mock Read-RestoreInputHC @inModule {
            & (New-FakeReadValuesHC { 'Test-secret!42' }) $Questions
        }
        { Invoke-ComputerSnapshotHC @params } |
            Should -Throw '*validation failed*'
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 0
            Exactly         = $true
            ParameterFilter = { $Message -match 'Test-secret' }
        }
        Should -Invoke Write-Warning @invoke
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                (
                    ($Results | ConvertTo-Json -Depth 10) -notmatch
                    'Test-secret'
                ) -and
                ($Results | ConvertTo-Json -Depth 10) -match '\[redacted\]'
            }
        }
        Should -Invoke Write-SnapshotReportHC @invoke
    }
    It ('uses answer files for selected shared sections, redacts secrets ' +
        'and suppresses browser opening unattended') {
        $sharedPath = Join-Path $TestDrive 'answer-users.json'
        ('[{"Name":"{{input:Account}}",' +
            '"Password":"{{password:Password}}"}]') |
            Set-Content -LiteralPath $sharedPath
        $answerPath = Join-Path $TestDrive 'answers.json'
        ('{"Answers":{"{{input:Account}}":"Example",' +
            '"{{password:Password}}":"File-secret!42",' +
            '"{{input:Unselected}}":"Unused"}}') |
            Set-Content -LiteralPath $answerPath
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $true }
            Items         = @{
                UserAccounts = 'answer-users.json'
                Software     = 'missing-unselected.json'
            }
        } $path
        $files = @($path, $sharedPath, $answerPath)
        $before = @(Get-Content -LiteralPath $files -Raw)
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $params.AnswerFile = 'answers.json'
        $params.Unattended = $true
        $params.OpenReportInBrowser = $true
        Mock Invoke-ChildScriptHC @inModule {
            $Data[0].Name | Should -Be 'Example'
            $Data[0].Password | Should -Be 'File-secret!42'
            [pscustomobject]@{
                Data     = $null
                Messages = [string[]]@('Applied File-secret!42')
                Errors   = [string[]]@()
            }
        }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeTrue
        $result.Results[0].Messages | Should -Be @('Applied [redacted]')
        Should -Invoke Read-RestoreInputHC @inModule -Times 0 -Exactly
        Should -Invoke Start-Process @inModule -Times 0 -Exactly
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                ($Results | ConvertTo-Json -Depth 10) -notmatch 'File-secret'
            }
        }
        Should -Invoke Write-SnapshotReportHC @invoke
        @(Get-Content -LiteralPath $files -Raw) | Should -Be $before
    }
    It ('prompts only for answers missing from a partial file during an ' +
        'interactive restore') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                UserAccounts = @(
                    @{
                        Name     = '{{input:Account}}'
                        Password = '{{password:Password}}'
                    }
                )
            }
        } $path
        $answerPath = Join-Path $TestDrive 'partial.answers.json'
        ('{"Answers":{"{{input:Account}}":"Example",' +
            '"{{password:Password}}":null}}') |
            Set-Content -LiteralPath $answerPath
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $params.AnswerFile = $answerPath
        Mock Read-RestoreInputHC @inModule {
            & (New-FakeReadValuesHC { 'Prompt-secret!42' }) $Questions
        }
        (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                @($Questions).Count -eq 1 -and
                $Questions[0].Kind -eq 'password'
            }
        }
        Should -Invoke Read-RestoreInputHC @invoke
    }
    It ('fails unattended on missing answers before any child or ' +
        'restart, with no prompts') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ RebootComputer = $true }
            Items         = @{
                UserAccounts = @(@{ Name = '{{input:Account}}' })
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $params.Unattended = $true
        { Invoke-ComputerSnapshotHC @params } |
            Should -Throw '*validation failed*No items executed*'
        Should -Invoke Read-RestoreInputHC @inModule -Times 0 -Exactly
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
        Should -Invoke Start-ComputerRestartHC @inModule -Times 0 -Exactly
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                $Results[0].Messages -match 'missing answers'
            }
        }
        Should -Invoke Write-SnapshotReportHC @invoke
    }
    It 'rejects invalid supplied answers before prompting for any other field' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                UserAccounts = @(@{ Name = '{{input:Account}}' })
            }
        } $path
        $answerPath = Join-Path $TestDrive 'invalid.answers.json'
        '{"Answers":{"{{ipv4:Server}}":"INVALID-PRIVATE-VALUE"}}' |
            Set-Content -LiteralPath $answerPath
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $params.AnswerFile = $answerPath
        { Invoke-ComputerSnapshotHC @params } |
            Should -Throw '*validation failed*'
        Should -Invoke Read-RestoreInputHC @inModule -Times 0 -Exactly
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                ($Results | ConvertTo-Json -Depth 10) -notmatch 'PRIVATE-VALUE'
            }
        }
        Should -Invoke Write-SnapshotReportHC @invoke
    }
    It ('passes file-template answers to the copy section during ' +
        'unattended restores') {
        $source = Join-Path $TestDrive 'answer-template.txt'
        'host={{ipv4:Server}}' | Set-Content -LiteralPath $source
        $answerPath = Join-Path $TestDrive 'file-template.answers.json'
        '{"Answers":{"{{ipv4:Server}}":"192.0.2.10"}}' |
            Set-Content -LiteralPath $answerPath
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                CopyFilesFolders = @(
                    @{
                        From             = $source
                        To               = 'C:\Example\template.txt'
                        FillPlaceholders = $true
                    }
                )
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('CopyFilesFolders')
        $params.Script = [ordered]@{ CopyFilesFolders = $scriptPath }
        $params.AnswerFile = $answerPath
        $params.Unattended = $true
        (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                $Data[0].PlaceholderValues['{{ipv4:Server}}'] -eq '192.0.2.10'
            }
        }
        Should -Invoke Invoke-ChildScriptHC @invoke
        Should -Invoke Read-RestoreInputHC @inModule -Times 0 -Exactly
    }
    It ('runs unattended without an answer file when no placeholders ' +
        'are present') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{ UserAccounts = @(@{ Name = 'Existing' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $params.Unattended = $true
        (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue
        Should -Invoke Read-RestoreInputHC @inModule -Times 0 -Exactly
    }
    It ('refuses unattended without administrator rights, ' +
        'RunElevated <RunElevated>, before reading answers or ' +
        'running a child') -ForEach @(
        @{ RunElevated = $true }
        @{ RunElevated = $false }
    ) {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ RunElevated = $RunElevated }
            Items         = @{
                UserAccounts = @(@{ Name = '{{input:Account}}' })
            }
        } $path
        $answerPath = Join-Path $TestDrive 'admin.answers.json'
        '{"Answers":{"{{input:Account}}":"kiosk"}}' |
            Set-Content -LiteralPath $answerPath
        Mock Read-RestoreAnswerFileHC @inModule
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $params.AnswerFile = $answerPath
        $params.Unattended = $true
        Mock Test-ElevatedHC @inModule { $false }

        { Invoke-ComputerSnapshotHC @params } |
            Should -Throw '*validation failed*'

        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                ($Results.Messages -join ' ') -like
                '*Unattended restore requires administrator rights*'
            }
        }
        Should -Invoke Write-SnapshotReportHC @invoke
        Should -Invoke Read-RestoreAnswerFileHC @inModule -Times 0 -Exactly
        Should -Invoke Read-RestoreInputHC @inModule -Times 0 -Exactly
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
        Should -Invoke Start-Process @inModule -Times 0 -Exactly
    }
    It ('only warns about missing administrator rights in an interactive ' +
        'restore') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{ UserAccounts = @(@{ Name = 'Existing' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Test-ElevatedHC @inModule { $false }

        (Invoke-ComputerSnapshotHC @params).Success | Should -BeTrue

        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                $Message -like 'Not running as administrator*'
            }
        }
        Should -Invoke Write-Warning @invoke
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 1 -Exactly
    }
    It ('redacts file-supplied passwords from resolved-configuration ' +
        'validation failures') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                Software = @{
                    Install = @(@{ ExecutablePath = '{{password:Path}}' })
                }
            }
        } $path
        $answerPath = Join-Path $TestDrive 'secret.answers.json'
        '{"Answers":{"{{password:Path}}":"File-secret!42"}}' |
            Set-Content -LiteralPath $answerPath
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('Software')
        $params.AnswerFile = $answerPath
        $params.Unattended = $true
        { Invoke-ComputerSnapshotHC @params } |
            Should -Throw '*validation failed*'
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                (
                    ($Results | ConvertTo-Json -Depth 10) -notmatch
                    'File-secret'
                ) -and
                ($Results | ConvertTo-Json -Depth 10) -match '\[redacted\]'
            }
        }
        Should -Invoke Write-SnapshotReportHC @invoke
    }
    It 'rejects restore-only answer options on export' {
        $params.AnswerFile = 'answers.json'
        { Invoke-ComputerSnapshotHC @params } | Should -Throw '*restore-only*'
        $params.Remove('AnswerFile')
        $params.Unattended = $true
        { Invoke-ComputerSnapshotHC @params } | Should -Throw '*restore-only*'
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
    }
    It 'rejects an empty or unavailable restore selection' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{ UserAccounts = @() }
        } $path
        $params.Action = 'RestoreSnapshot'
        foreach ($selection in @(@(), @('CreateFolders'), @('Unknown'))) {
            $params.Items = $selection
            { Invoke-ComputerSnapshotHC @params } |
                Should -Throw '*No items executed*'
        }
        Should -Invoke Invoke-ChildScriptHC @inModule -Times 0 -Exactly
    }
    It ('keeps the existing configuration and still writes the report ' +
        'when saving fails') {
        '{"existing":true}' | Set-Content -LiteralPath $path -Encoding UTF8
        $before = Get-Content -LiteralPath $path -Raw
        $params.Items = @('UserAccounts')
        Mock Write-ConfigurationHC @inModule { throw 'disk full' }
        $result = Invoke-ComputerSnapshotHC @params -Force
        $result.Success | Should -BeFalse
        $failed = $result.Results | Where-Object Name -EQ 'Configuration file'
        $failed.Status | Should -Be 'Failed'
        $failed.Messages[0] | Should -BeLike 'ERROR: *disk full*'
        ($result.Results | Where-Object Name -EQ 'UserAccounts').Status |
            Should -Be 'Success'
        @($result.Results.Name) | Should -Not -Contain 'Export validation'
        Should -Invoke Write-SnapshotReportHC @inModule -Times 1 -Exactly
        (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $before
    }
    It ('reports errors returned in the Errors property next to the ' +
        'success messages') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $false }
            Items         = @{
                UserAccounts = @(
                    @{ Name = 'A' }, @{ Name = 'B' }, @{ Name = 'C' }
                )
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Invoke-ChildScriptHC @inModule {
            [pscustomobject]@{
                Data     = $null
                Messages = [string[]]@('Updated A')
                Errors   = [string[]]@('Failed B', 'Failed C')
            }
        }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeFalse
        $result.Results[0].Status | Should -Be 'Failed'
        $result.Results[0].Messages |
            Should -Be @('Updated A', 'ERROR: Failed B', 'ERROR: Failed C')
    }
    It 'does not export a section that returned errors' {
        $params.Script.UserAccounts = Join-Path $PSScriptRoot (
            '..\..\Scripts\User accounts import export.ps1'
        )
        Mock Invoke-ChildScriptHC @inModule {
            [pscustomobject]@{
                Data     = @()
                Messages = [string[]]@('Exported')
                Errors   = [string[]]@('Failed')
            }
        } -ParameterFilter { $Path -like '*User accounts import export.ps1' }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeFalse
        @((Read-ConfigurationHC $path $TestDrive).Items.Keys) |
            Should -Be @('CreateFolders')
    }
    It 'treats an empty Errors property as success' {
        $params.Items = @('UserAccounts')
        Mock Invoke-ChildScriptHC @inModule {
            [pscustomobject]@{
                Data     = @()
                Messages = [string[]]@('Exported')
                Errors   = [string[]]@()
            }
        }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeTrue
        $result.Results[0].Messages | Should -Be @('Exported')
    }
    It 'rejects an Errors property that is not a string array' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $false }
            Items         = @{ UserAccounts = @(@{ Name = 'A' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Invoke-ChildScriptHC @inModule {
            [pscustomobject]@{
                Data     = @()
                Messages = [string[]]@('Exported')
                Errors   = 'Failed B'
            }
        }
        $result = Invoke-ComputerSnapshotHC @params 3>$null
        $result.Results[0].Status | Should -Be 'Failed'
        $result.Results[0].Messages | Should -Be @(
            ("ERROR: 'UserAccounts' did not return exactly one result " +
                'with Data, Messages (string array) and Errors ' +
                '(string array)')
        )
    }
    It 'rejects a result without an Errors property' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{ OpenReportInBrowser = $false }
            Items         = @{ UserAccounts = @(@{ Name = 'A' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Invoke-ChildScriptHC @inModule {
            [pscustomobject]@{
                Data     = $null
                Messages = [string[]]@('Imported')
            }
        }
        $result = Invoke-ComputerSnapshotHC @params 3>$null
        $result.Success | Should -BeFalse
        $result.Results[0].Status | Should -Be 'Failed'
        $result.Results[0].Messages | Should -Be @(
            ("ERROR: 'UserAccounts' did not return exactly one result " +
                'with Data, Messages (string array) and Errors ' +
                '(string array)')
        )
    }
    It 'redacts prompted passwords in returned errors' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Items         = @{
                UserAccounts = @(
                    @{ Name = 'Example'; Password = '{{password:Password}}' }
                )
            }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Read-RestoreInputHC @inModule {
            & (New-FakeReadValuesHC { 'Test-secret!42' }) $Questions
        }
        Mock Invoke-ChildScriptHC @inModule {
            [pscustomobject]@{
                Data     = $null
                Messages = [string[]]@()
                Errors   = [string[]]@('Rejected Test-secret!42')
            }
        }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Results[0].Messages |
            Should -Be @('ERROR: Rejected [redacted]')
    }
    It 'never restarts after an export and says so in the report' {
        $params.RebootComputer = $true
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeTrue
        $result.RestartScheduled | Should -BeFalse
        $restart = $result.Results | Where-Object Name -EQ 'Restart computer'
        $restart.Status | Should -Be 'Skipped'
        $restart.Messages |
            Should -Be @('The computer only restarts after a restore')
        Should -Invoke Start-ComputerRestartHC @inModule -Times 0 -Exactly
    }
    It ('reports a scheduled restart with its countdown before writing ' +
        'the report') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{
                OpenReportInBrowser = $false
                RebootComputer      = $true
            }
            Items         = @{ UserAccounts = @(@{ Name = 'Example' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $result = Invoke-ComputerSnapshotHC @params
        $result.RestartScheduled | Should -BeTrue
        $restart = $result.Results | Where-Object Name -EQ 'Restart computer'
        $restart.Status | Should -Be 'Success'
        $restart.Messages | Should -Be @(
            ('The computer restarts in 60 seconds; ' +
                "run 'shutdown /a' to cancel")
        )
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = { $DelaySeconds -eq 60 }
        }
        Should -Invoke Start-ComputerRestartHC @invoke
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                @(
                    $Results | Where-Object Name -EQ 'Restart computer'
                ).Count -eq 1
            }
        }
        Should -Invoke Write-SnapshotReportHC @invoke
    }
    It 'uses the saved restart delay unless the run overrides it' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{
                OpenReportInBrowser = $false
                RebootComputer      = $true
                RestartDelaySeconds = 300
            }
            Items         = @{ UserAccounts = @(@{ Name = 'Example' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        $result = Invoke-ComputerSnapshotHC @params
        $restart = $result.Results | Where-Object Name -EQ 'Restart computer'
        $restart.Messages[0] |
            Should -BeLike 'The computer restarts in 300 seconds*'
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = { $DelaySeconds -eq 300 }
        }
        Should -Invoke Start-ComputerRestartHC @invoke
        $params.RestartDelaySeconds = 0
        $null = Invoke-ComputerSnapshotHC @params
        $invoke.ParameterFilter = { $DelaySeconds -eq 0 }
        Should -Invoke Start-ComputerRestartHC @invoke
    }
    It 'reports a restart that was not done because a section failed' {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{
                OpenReportInBrowser = $false
                RebootComputer      = $true
            }
            Items         = @{ UserAccounts = @(@{ Name = 'Example' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Invoke-ChildScriptHC @inModule { throw 'Restore failed' }
        $result = Invoke-ComputerSnapshotHC @params
        $restart = $result.Results | Where-Object Name -EQ 'Restart computer'
        $restart.Status | Should -Be 'Skipped'
        $restart.Messages[0] |
            Should -BeLike 'Not restarted, because a section failed*'
    }
    It ('keeps a successful restore successful when the restart cannot ' +
        'be scheduled') {
        Write-ConfigurationHC @{
            SchemaVersion = 3
            Settings      = @{
                OpenReportInBrowser = $false
                RebootComputer      = $true
            }
            Items         = @{ UserAccounts = @(@{ Name = 'Example' }) }
        } $path
        $params.Action = 'RestoreSnapshot'
        $params.Items = @('UserAccounts')
        Mock Start-ComputerRestartHC @inModule {
            throw ('shutdown.exe failed with exit code 1190: ' +
                'A system shutdown has already been scheduled.')
        }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeTrue
        $result.RestartScheduled | Should -BeFalse
        $restart = $result.Results | Where-Object Name -EQ 'Restart computer'
        $restart.Status | Should -Be 'Warning'
        $restart.Messages[0] | Should -BeLike '*exit code 1190*'
    }
    It 'still returns the result when the report cannot be opened' {
        $params.OpenReportInBrowser = $true
        Mock Start-Process @inModule {
            throw 'There is no application associated with the specified file'
        }
        $result = Invoke-ComputerSnapshotHC @params
        $result.Success | Should -BeTrue
        $invoke = @{
            ModuleName      = 'Execution'
            ParameterFilter = {
                $Message -like 'The report could not be opened:*'
            }
        }
        Should -Invoke Write-Warning @invoke
    }
    It 'passes export options to the child script as Data on export only' {
        $params.Items = @('UserAccounts')
        $params.ExportOptions = @{ UserAccounts = @{ Example = 'Option' } }
        $null = Invoke-ComputerSnapshotHC @params
        $invoke = @{
            ModuleName      = 'Execution'
            Times           = 1
            Exactly         = $true
            ParameterFilter = {
                $Action -eq 'Export' -and $Data.Example -eq 'Option'
            }
        }
        Should -Invoke Invoke-ChildScriptHC @invoke
    }
}