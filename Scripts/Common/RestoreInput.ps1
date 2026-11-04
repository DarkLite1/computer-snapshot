#Requires -Version 5.1

function Get-RestoreInputFieldsHC {
    param(
        $Data,
        [string]$Path = 'Items',
        $Container,
        $Key
    )

    if ($Data -is [string]) {
        $pattern = (
            '\A\{\{(?<Kind>input|password|ipv4|prefix):' +
            '(?<Description>[^{}\r\n]+)\}\}\z'
        )
        $match = [regex]::Match($Data, $pattern)

        if (
            $match.Success -and
            -not [string]::IsNullOrWhiteSpace(
                $match.Groups['Description'].Value
            )
        ) {
            [pscustomobject]@{
                Path        = $Path
                Placeholder = $Data
                Kind        = $match.Groups['Kind'].Value
                Description = $match.Groups['Description'].Value.Trim()
                Container   = $Container
                Key         = $Key
            }
        }
        elseif (
            $Data.StartsWith('{{') -or
            $Data -match '\{\{(?:input|password|ipv4|prefix):'
        ) {
            throw (
                "${Path}: use a complete {{input:Description}}, " +
                '{{password:Description}}, {{ipv4:Description}} or ' +
                '{{prefix:Description}} string.'
            )
        }

        return
    }

    if ($Data -is [array]) {
        for ($index = 0; $index -lt $Data.Count; $index++) {
            $fieldParams = @{
                Data      = $Data[$index]
                Path      = "${Path}[$index]"
                Container = $Data
                Key       = $index
            }
            Get-RestoreInputFieldsHC @fieldParams
        }
    }
    elseif ($Data -is [System.Collections.IDictionary]) {
        foreach ($name in $Data.Keys) {
            if ($name -cne 'Comment') {
                $fieldParams = @{
                    Data      = $Data[$name]
                    Path      = "$Path.$name"
                    Container = $Data
                    Key       = $name
                }
                Get-RestoreInputFieldsHC @fieldParams
            }
        }
    }
    elseif (
        $null -ne $Data -and
        $Data.GetType() -eq [System.Management.Automation.PSCustomObject]
    ) {
        foreach ($property in $Data.PSObject.Properties) {
            if ($property.Name -cne 'Comment') {
                $fieldParams = @{
                    Data      = $property.Value
                    Path      = "$Path.$($property.Name)"
                    Container = $Data
                    Key       = $property.Name
                }
                Get-RestoreInputFieldsHC @fieldParams
            }
        }
    }
}

function Get-TextInputFieldsHC {
    # Placeholders anywhere in the text of a file; passwords are refused
    param(
        [string]$Text,
        [string]$Path
    )

    $complete = [regex]::Matches(
        $Text,
        (
            '\{\{(?<Kind>input|password|ipv4|prefix):' +
            '(?<Description>[^{}\r\n]+)\}\}'
        )
    )
    $started = [regex]::Matches($Text, '\{\{(?:input|password|ipv4|prefix):')

    if ($started.Count -ne $complete.Count) {
        throw (
            "${Path}: use complete {{input:Description}}, " +
            '{{ipv4:Description}} or {{prefix:Description}} placeholders.'
        )
    }

    foreach ($match in $complete) {
        if ($match.Groups['Kind'].Value -eq 'password') {
            throw (
                "${Path}: {{password:...}} is not allowed in a file, " +
                'because the password would be stored in plain text on ' +
                'the computer.'
            )
        }

        if ([string]::IsNullOrWhiteSpace($match.Groups['Description'].Value)) {
            throw "${Path}: a placeholder needs a description."
        }

        [pscustomobject]@{
            Path        = $Path
            Placeholder = $match.Value
            Kind        = $match.Groups['Kind'].Value
            Description = $match.Groups['Description'].Value.Trim()
            Container   = $null
            Key         = $null
        }
    }
}

function Get-FileInputFieldsHC {
    # Placeholders in the files that CopyFilesFolders fills in while copying
    param(
        $Items,
        [Parameter(Mandatory)][string]$RootFolder,
        [switch]$RequireSources
    )

    $entries = @($Items.CopyFilesFolders | Where-Object { $null -ne $_ })

    for ($index = 0; $index -lt $entries.Count; $index++) {
        if (
            $entries[$index].FillPlaceholders -ne $true -or
            $entries[$index].From -isnot [string]
        ) {
            continue
        }

        # A missing file is reported by the configuration check
        $resolveParams = @{
            Path       = $entries[$index].From
            RootFolder = $RootFolder
        }
        $file = Resolve-RootPathHC @resolveParams

        if (-not [IO.File]::Exists($file)) {
            if ($RequireSources) {
                throw (
                    "Cannot discover file placeholders: '$file' does not " +
                    'exist. Use an existing, fixed source path for ' +
                    'FillPlaceholders.'
                )
            }
            continue
        }

        Write-Verbose "Find placeholders in file '$file'"

        $textParams = @{
            Text = [IO.File]::ReadAllText($file)
            Path = (
                "Items.CopyFilesFolders[$index].From " +
                "'$($entries[$index].From)'"
            )
        }
        Get-TextInputFieldsHC @textParams
    }
}

function Test-RestoreInputValueHC {
    param(
        [string]$Kind,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    if ($Kind -eq 'ipv4') {
        $address = $null

        return (
            [Net.IPAddress]::TryParse($Value, [ref]$address) -and
            $address.AddressFamily -eq
            [Net.Sockets.AddressFamily]::InterNetwork -and
            $address.ToString() -ceq $Value
        )
    }

    if ($Kind -eq 'prefix') {
        # A whole number written plainly, such as 24
        return $Value -match '\A(?:[1-9]|[12][0-9]|3[0-2])\z'
    }

    return $true
}

function New-RestoreInputFormHC {
    param(
        $Field
    )

    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Restore - input required'
    $dialog.ClientSize = New-Object Drawing.Size 560, 240
    $dialog.MinimumSize = New-Object Drawing.Size 520, 280
    $dialog.Font = New-Object Drawing.Font 'Segoe UI', 10
    $dialog.StartPosition = 'CenterScreen'
    $dialog.TopMost = $true
    $dialog.Tag = @{ Kind = $Field.Kind; Value = $null }

    # Rows: description, location, input, validation message, buttons
    $percent = [Windows.Forms.SizeType]::Percent
    $absolute = [Windows.Forms.SizeType]::Absolute
    $autoSize = [Windows.Forms.SizeType]::AutoSize

    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.Padding = New-Object Windows.Forms.Padding 16
    $layout.ColumnCount = 1
    $null = $layout.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $percent, 100)
    )
    $layout.RowCount = 5
    foreach ($index in 1..2) {
        $null = $layout.RowStyles.Add(
            (New-Object Windows.Forms.RowStyle $autoSize)
        )
    }
    $null = $layout.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $absolute, 38)
    )
    $null = $layout.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $percent, 100)
    )
    $null = $layout.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $absolute, 44)
    )
    $dialog.Controls.Add($layout)

    $description = New-Object Windows.Forms.Label
    $description.Name = 'InputDescription'
    $description.Text = $Field.Description
    $description.UseMnemonic = $false
    $description.AutoSize = $true
    $description.Dock = 'Fill'
    $description.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 8
    $layout.Controls.Add($description, 0, 0)

    $location = New-Object Windows.Forms.Label
    $location.Text = $Field.Path
    $location.UseMnemonic = $false
    $location.Font = New-Object Drawing.Font $dialog.Font.FontFamily, 9
    $location.AutoSize = $true
    $location.Dock = 'Fill'
    $location.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 12
    $layout.Controls.Add($location, 0, 1)

    $inputBox = New-Object Windows.Forms.TextBox
    $inputBox.Name = 'InputValue'
    $inputBox.AccessibleName = $Field.Description
    $inputBox.Dock = 'Fill'
    $inputBox.UseSystemPasswordChar = $Field.Kind -eq 'password'
    $layout.Controls.Add($inputBox, 0, 2)

    $validation = New-Object Windows.Forms.Label
    $validation.Name = 'InputValidation'
    $validation.Text = 'A value is required.'
    $validation.Dock = 'Fill'
    $layout.Controls.Add($validation, 0, 3)

    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Fill'
    $buttons.FlowDirection = 'RightToLeft'

    $confirm = New-Object Windows.Forms.Button
    $confirm.Name = 'ConfirmInput'
    $confirm.Text = 'Continue'
    $confirm.Size = New-Object Drawing.Size 110, 34
    $confirm.Enabled = $false
    $confirm.Add_Click({
        $owner = $this.FindForm()
        $value = $owner.Controls.Find('InputValue', $true)[0].Text
        $valid = Test-RestoreInputValueHC -Kind $owner.Tag.Kind -Value $value
        if (-not $valid) {
            return
        }
        $owner.Tag.Value = $value
        $owner.DialogResult = [Windows.Forms.DialogResult]::OK
    })

    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Size = New-Object Drawing.Size 110, 34
    $cancel.DialogResult = 'Cancel'

    $buttons.Controls.AddRange(@($confirm, $cancel))
    $layout.Controls.Add($buttons, 0, 4)
    $dialog.AcceptButton = $confirm
    $dialog.CancelButton = $cancel

    $inputBox.Add_TextChanged({
        $owner = $this.FindForm()
        $valueParams = @{ Kind = $owner.Tag.Kind; Value = $this.Text }
        $valid = Test-RestoreInputValueHC @valueParams
        $owner.Controls.Find('ConfirmInput', $true)[0].Enabled = $valid
        $owner.Controls.Find('InputValidation', $true)[0].Text = if ($valid) {
            ''
        }
        elseif ([string]::IsNullOrWhiteSpace($this.Text)) {
            'A value is required.'
        }
        elseif ($owner.Tag.Kind -eq 'prefix') {
            'Enter a prefix length from 1 to 32, such as 24.'
        }
        else {
            'Enter an IPv4 address such as 192.0.2.10.'
        }
    })

    $dialog.ActiveControl = $inputBox
    return , $dialog
}

function Read-RestoreInputHC {
    param(
        $Field
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $dialog = New-RestoreInputFormHC -Field $Field

    try {
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            return $dialog.Tag.Value
        }
    }
    finally {
        $dialog.Controls.Find('InputValue', $true)[0].Clear()
        $dialog.Tag.Value = $null
        $dialog.Dispose()
    }
}

function Read-RestoreAnswerFileHC {
    param([Parameter(Mandatory)][string]$Path)

    Write-Verbose "Read answer file '$Path'"

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        Add-Type -AssemblyName System.Runtime.Serialization -ErrorAction Stop
        $parserType = 'System.Web.Script.Serialization.JavaScriptSerializer'
        $parser = New-Object $parserType
    }
    $reader = $null
    try {
        # The XML JSON reader alone accepts some truncated documents.
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $jsonParams = @{
                InputObject = $text
                AsHashtable = $true
                ErrorAction = 'Stop'
            }
            $null = ConvertFrom-Json @jsonParams
        }
        else {
            $null = $parser.DeserializeObject($text)
        }
        # Preserve case-sensitive keys and duplicates on both PowerShell
        # versions.
        $factory = [System.Runtime.Serialization.Json.JsonReaderWriterFactory]
        $reader = $factory::CreateJsonReader(
            [Text.Encoding]::UTF8.GetBytes($text),
            [System.Xml.XmlDictionaryReaderQuotas]::Max
        )
        $document = New-Object System.Xml.XmlDocument
        $document.Load($reader)
    }
    catch {
        # JSON parser errors can repeat the file contents, including passwords.
        throw "Answer file '$Path' is not valid JSON."
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }

    $root = $document.DocumentElement
    $answerNodes = @(
        $root.ChildNodes | Where-Object {
            $_.LocalName -ceq 'Answers' -and $_.NamespaceURI -eq ''
        }
    )
    $comments = @(
        $root.ChildNodes | Where-Object {
            $_.LocalName -ceq 'Comment' -and $_.NamespaceURI -eq ''
        }
    )
    if (
        $root.GetAttribute('type') -ne 'object' -or
        $answerNodes.Count -ne 1 -or
        $answerNodes[0].GetAttribute('type') -ne 'object' -or
        $comments.Count -gt 1 -or
        @(
            $comments | Where-Object {
                $_.GetAttribute('type') -notin @('string', 'null')
            }
        ).Count -or
        $root.ChildNodes.Count -ne (1 + $comments.Count)
    ) {
        throw (
            "Answer file '$Path' must contain an Answers object and an " +
            'optional Comment.'
        )
    }

    $dictionaryType = 'System.Collections.Generic.Dictionary[string,string]'
    $hashSetType = 'System.Collections.Generic.HashSet[string]'
    $answers = New-Object $dictionaryType ([StringComparer]::Ordinal)
    $keys = New-Object $hashSetType ([StringComparer]::Ordinal)

    foreach ($node in $answerNodes[0].ChildNodes) {
        $key = if ($node.HasAttribute('item')) {
            $node.GetAttribute('item')
        }
        else {
            $node.LocalName
        }
        $field = @(Get-RestoreInputFieldsHC -Data $key)
        if ($field.Count -ne 1) {
            throw (
                "Answer file '$Path': every answer key must be a complete " +
                'placeholder.'
            )
        }
        if (-not $keys.Add($key)) {
            throw "Answer file '$Path': duplicate answer key '$key'."
        }
        if ($node.GetAttribute('type') -eq 'null') {
            continue
        }
        $valueParams = @{
            Kind  = $field[0].Kind
            Value = $node.InnerText
        }
        if (
            $node.GetAttribute('type') -ne 'string' -or
            -not (Test-RestoreInputValueHC @valueParams)
        ) {
            throw (
                "Answer file '$Path': the answer for '$key' must be a " +
                "nonempty, valid $($field[0].Kind) string."
            )
        }
        $answers.Add($key, $node.InnerText)
    }

    Write-Verbose "Answer file '$Path': $($answers.Count) answers"

    return ,$answers
}

function New-RestoreAnswerFileHC {
    param(
        [Parameter(Mandatory)][string]$ConfigurationFile,
        [Parameter(Mandatory)][string]$AnswerFile,
        [Parameter(Mandatory)][string]$RootFolder,
        [string[]]$Items,
        [switch]$Force
    )

    $configurationPath = Resolve-RootPathHC $ConfigurationFile $RootFolder
    $answerPath = Resolve-RootPathHC $AnswerFile $RootFolder
    if ($configurationPath -eq $answerPath) {
        throw 'The answer file must not replace the configuration template.'
    }
    if ((Test-Path -LiteralPath $answerPath) -and -not $Force) {
        throw (
            "Answer file '$answerPath' already exists. " +
            'Use -Force to replace it.'
        )
    }

    Write-Verbose "Create answer file '$answerPath'"

    $configurationParams = @{
        Path       = $configurationPath
        RootFolder = $RootFolder
        Items      = $Items
    }
    $configuration = Read-ConfigurationHC @configurationParams
    if ($configuration.Problems.Count) {
        throw ($configuration.Problems -join [Environment]::NewLine)
    }

    $fields = @(Get-RestoreInputFieldsHC -Data $configuration.Items)
    $fileParams = @{
        Items          = $configuration.Items
        RootFolder     = $RootFolder
        RequireSources = $true
    }
    $fields += @(Get-FileInputFieldsHC @fileParams)

    $dictionaryType = 'System.Collections.Generic.Dictionary[string,object]'
    $answers = New-Object $dictionaryType ([StringComparer]::Ordinal)
    foreach ($field in $fields) {
        if (-not $answers.ContainsKey($field.Placeholder)) {
            $answers.Add($field.Placeholder, $null)
        }
    }

    Write-Verbose "Answer file: $($answers.Count) placeholders"

    $json = [ordered]@{
        Comment = (
            'Replace null with a string answer. Null means missing. ' +
            'Password answers are stored in plain text; protect this file.'
        )
        Answers = $answers
    } | ConvertTo-Json -Depth 10

    # Write a temporary file first, so a failure never leaves half a file
    $tempName = '.answers-{0}.tmp' -f [guid]::NewGuid().ToString('N')
    $tempPath = Join-Path (Split-Path $answerPath -Parent) $tempName
    try {
        $encoding = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText(
            $tempPath, $json + [Environment]::NewLine, $encoding
        )
        if ($Force -and [IO.File]::Exists($answerPath)) {
            [IO.File]::Replace($tempPath, $answerPath, [NullString]::Value)
        }
        else {
            [IO.File]::Move($tempPath, $answerPath)
        }
    }
    finally {
        if ([IO.File]::Exists($tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction Stop
        }
    }

    $answerPath
}

function Resolve-RestoreInputHC {
    param(
        $Items,
        [Parameter(Mandatory)][scriptblock]$ReadValue,
        # Also ask for the placeholders in files that are filled while copying
        [string]$RootFolder,
        [System.Collections.IDictionary]$Answers,
        [switch]$Unattended
    )

    $fields = @(Get-RestoreInputFieldsHC -Data $Items)

    if ($RootFolder) {
        $fields += @(
            Get-FileInputFieldsHC -Items $Items -RootFolder $RootFolder
        )
    }

    Write-Verbose "Restore input: $($fields.Count) placeholders found"

    $objectDictionaryType = (
        'System.Collections.Generic.Dictionary[string,object]'
    )
    $stringDictionaryType = (
        'System.Collections.Generic.Dictionary[string,string]'
    )
    $ordinal = [StringComparer]::Ordinal

    $suppliedAnswers = New-Object $objectDictionaryType $ordinal
    if ($null -ne $Answers) {
        foreach ($key in $Answers.Keys) {
            $suppliedAnswers.Add($key, $Answers[$key])
        }
    }
    $answers = New-Object $stringDictionaryType $ordinal
    $secrets = New-Object 'System.Collections.Generic.List[string]'

    if ($Unattended) {
        $missing = @(
            $fields | Where-Object {
                -not $suppliedAnswers.ContainsKey($_.Placeholder) -or
                $null -eq $suppliedAnswers[$_.Placeholder]
            } | Select-Object -ExpandProperty Placeholder -Unique
        )
        if ($missing.Count) {
            throw (
                'Unattended restore is missing answers for: ' +
                "$($missing -join ', '). No items executed."
            )
        }
    }

    foreach ($field in $fields) {
        if ($answers.ContainsKey($field.Placeholder)) {
            continue
        }

        $value = if (
            $suppliedAnswers.ContainsKey($field.Placeholder) -and
            $null -ne $suppliedAnswers[$field.Placeholder]
        ) {
            $suppliedAnswers[$field.Placeholder]
        }
        else {
            Write-Verbose "Ask input for '$($field.Placeholder)'"
            & $ReadValue $field
        }

        if ($null -eq $value) {
            throw [OperationCanceledException]::new(
                'Restore cancelled. No items executed.'
            )
        }

        if (
            $value -isnot [string] -or
            -not (Test-RestoreInputValueHC -Kind $field.Kind -Value $value)
        ) {
            throw "$($field.Path): the supplied input is empty or invalid."
        }

        $answers.Add($field.Placeholder, $value)

        if ($field.Kind -eq 'password') {
            $secrets.Add($value)
        }
    }

    foreach ($field in $fields) {
        # Placeholders in files are filled in by the copy, not here
        if ($null -eq $field.Container) {
            continue
        }

        # A prefix length is a number in the configuration
        $answer = if ($field.Kind -eq 'prefix') {
            [int]$answers[$field.Placeholder]
        }
        else {
            $answers[$field.Placeholder]
        }

        if (
            $field.Container -is [System.Collections.IDictionary] -or
            $field.Container -is [array]
        ) {
            $field.Container[$field.Key] = $answer
        }
        else {
            $field.Container.($field.Key) = $answer
        }
    }

    [pscustomobject]@{
        SecretValues = $secrets.ToArray()
        # Every answer by its placeholder, for placeholders in files
        Values       = $answers
    }
}

function Protect-RestoreInputTextHC {
    <#
    .SYNOPSIS
        Replace every secret in the text with '[redacted]'.
    .DESCRIPTION
        Besides the secret as typed, the forms in which programs and
        PowerShell commonly repeat it are redacted too: XML or HTML encoded,
        URL encoded, JSON escaped and with doubled single quotes.
    #>
    param(
        [string]$Text,
        [string[]]$SecretValues
    )

    $forms = foreach ($secret in $SecretValues) {
        if ([string]::IsNullOrEmpty($secret)) {
            continue
        }

        $secret
        [System.Security.SecurityElement]::Escape($secret)
        [System.Net.WebUtility]::HtmlEncode($secret)
        [System.Uri]::EscapeDataString($secret)
        (ConvertTo-Json -InputObject $secret -Compress).Trim('"')
        $secret.Replace("'", "''")
    }

    # Longest first, so a longer form is never left half redacted
    foreach (
        $form in
        @($forms | Select-Object -Unique | Sort-Object Length -Descending)
    ) {
        if (-not [string]::IsNullOrEmpty($form)) {
            $Text = $Text.Replace($form, '[redacted]')
        }
    }

    return $Text
}