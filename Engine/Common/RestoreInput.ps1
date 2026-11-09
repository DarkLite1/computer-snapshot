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
            '\A\{\{(?<Kind>input|password|ipv4|prefix|number):' +
            '(?<Description>[^{}\r\n]+)\}\}\z'
        )
        $match = [regex]::Match($Data, $pattern)

        $incomplete = (
            "${Path}: use a complete {{input:Description}}, " +
            '{{password:Description}}, {{ipv4:Description}}, ' +
            '{{prefix:Description}} or {{number:Description}} string.'
        )

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
                Embedded    = $false
            }

            return
        }

        # Placeholders combined with other text, such as 'Kiosk of
        # {{input:Site}}'; only text answers fit inside text
        $complete = [regex]::Matches(
            $Data,
            (
                '\{\{(?<Kind>input|password|ipv4|prefix|number):' +
                '(?<Description>[^{}\r\n]+)\}\}'
            )
        )
        $started = [regex]::Matches(
            $Data,
            '\{\{(?:input|password|ipv4|prefix|number):'
        )

        if (-not $started.Count) {
            if ($Data.StartsWith('{{')) {
                throw $incomplete
            }

            return
        }

        if ($started.Count -ne $complete.Count) {
            throw $incomplete
        }

        foreach ($embedded in $complete) {
            $kind = $embedded.Groups['Kind'].Value
            $description = $embedded.Groups['Description'].Value

            if ([string]::IsNullOrWhiteSpace($description)) {
                throw $incomplete
            }

            if ($kind -notin @('input', 'ipv4')) {
                throw (
                    "${Path}: {{${kind}:Description}} must be the whole " +
                    'value. Only {{input:...}} and {{ipv4:...}} can be ' +
                    'combined with other text.'
                )
            }

            [pscustomobject]@{
                Path        = $Path
                Placeholder = $embedded.Value
                Kind        = $kind
                Description = $description.Trim()
                Container   = $Container
                Key         = $Key
                Embedded    = $true
                Text        = $Data
            }
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
            '\{\{(?<Kind>input|password|ipv4|prefix|number):' +
            '(?<Description>[^{}\r\n]+)\}\}'
        )
    )
    $started = [regex]::Matches(
        $Text,
        '\{\{(?:input|password|ipv4|prefix|number):'
    )

    if ($started.Count -ne $complete.Count) {
        throw (
            "${Path}: use complete {{input:Description}}, " +
            '{{ipv4:Description}}, {{prefix:Description}} or ' +
            '{{number:Description}} placeholders.'
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

    if ($Kind -eq 'number') {
        # A whole number written plainly, such as 15 or -1, that fits a long
        $number = [long]0

        return (
            $Value -match '\A-?(?:0|[1-9][0-9]*)\z' -and
            [long]::TryParse(
                $Value,
                [Globalization.NumberStyles]::AllowLeadingSign,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$number
            )
        )
    }

    return $true
}

function ConvertTo-RestoreInputNumberHC {
    # The answer of a {{number:...}} placeholder: an int when it fits,
    # otherwise a long
    param(
        [Parameter(Mandatory)][string]$Value
    )

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $number = [long]::Parse($Value, $culture)

    if ($number -ge [int]::MinValue -and $number -le [int]::MaxValue) {
        return [int]$number
    }

    $number
}

function Get-RestoreInputSectionHC {
    # The section of a configuration path such as Items.UserAccounts[0].Name,
    # with its name in the wizard, such as 'User accounts', in execution
    # order
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $scripts = Get-SnapshotScriptsHC
    $key = ''

    if ($Path -match '\AItems\.(?<Key>[A-Za-z]+)') {
        $key = $Matches['Key']
    }

    if (-not $scripts.Contains($key)) {
        return [pscustomobject]@{
            Key   = $key
            Name  = 'Other'
            Order = $scripts.Count
        }
    }

    [pscustomobject]@{
        Key   = $key
        Name  = (Get-SnapshotSectionLabelsHC)[$key][0]
        Order = [array]::IndexOf(@($scripts.Keys), $key)
    }
}

function Get-SchemaAlternativesHC {
    # A schema node with its $ref, anyOf and oneOf alternatives, flattened
    param(
        $Node,
        [Parameter(Mandatory)]$Schema
    )

    if ($null -eq $Node) {
        return
    }

    if ($Node.'$ref') {
        $name = $Node.'$ref' -replace '^#/\$defs/', ''
        Get-SchemaAlternativesHC $Schema.'$defs'.$name $Schema

        return
    }

    $Node

    foreach ($alternative in @($Node.anyOf) + @($Node.oneOf)) {
        if ($null -ne $alternative) {
            Get-SchemaAlternativesHC $alternative $Schema
        }
    }
}

function Get-RestoreInputRuleHC {
    <#
    .SYNOPSIS
        What the schema allows at a configuration path, such as
        Items.Software.Install[0].TimeoutMinutes: the range of a whole number
        or the fixed values of a text. Nothing when it does not limit the
        answer.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Schema
    )

    $pathMatch = [regex]::Match(
        $Path,
        (
            '\AItems\.(?<Section>[A-Za-z]+)' +
            '(?<Steps>(?:\.[^.\[\]]+|\[\d+\])*)\z'
        )
    )

    if (-not $pathMatch.Success) {
        return
    }

    $sectionName = $pathMatch.Groups['Section'].Value
    $nodes = @(Get-SchemaAlternativesHC $Schema.'$defs'.$sectionName $Schema)
    $steps = [regex]::Matches(
        $pathMatch.Groups['Steps'].Value,
        '\.(?<Name>[^.\[\]]+)|\[(?<Index>\d+)\]'
    )

    foreach ($step in $steps) {
        $name = $step.Groups['Name'].Value
        $children = foreach ($node in $nodes) {
            if ($step.Groups['Index'].Success) {
                $node.items
            }
            elseif (
                $null -ne $node.properties -and
                $node.properties.PSObject.Properties[$name]
            ) {
                $node.properties.$name
            }
            elseif ($null -ne $node.patternProperties) {
                foreach (
                    $pattern in $node.patternProperties.PSObject.Properties
                ) {
                    if ($name -match $pattern.Name) {
                        $pattern.Value
                    }
                }
            }
        }
        $nodes = @(
            foreach ($child in $children) {
                Get-SchemaAlternativesHC $child $Schema
            }
        )
    }

    $integers = @($nodes | Where-Object { @($_.type) -contains 'integer' })
    # A string with a pattern is the placeholder itself, not an answer
    $texts = @(
        $nodes | Where-Object {
            @($_.type) -contains 'string' -and -not $_.pattern
        }
    )

    $minimum = $null
    $maximum = $null

    if (
        $integers.Count -and
        -not @($integers | Where-Object { $null -eq $_.minimum }).Count
    ) {
        $minimum = [long](
            $integers | Measure-Object -Property minimum -Minimum
        ).Minimum
    }

    if (
        $integers.Count -and
        -not @($integers | Where-Object { $null -eq $_.maximum }).Count
    ) {
        $maximum = [long](
            $integers | Measure-Object -Property maximum -Maximum
        ).Maximum
    }

    $values = $null

    if (
        $texts.Count -and
        -not @($texts | Where-Object { -not $_.enum }).Count
    ) {
        # The check compares case-insensitively, so one spelling is enough
        $hashSetType = 'System.Collections.Generic.HashSet[string]'
        $seen = New-Object $hashSetType ([StringComparer]::OrdinalIgnoreCase)
        $values = [string[]]@(
            foreach ($text in $texts) {
                foreach ($value in $text.enum) {
                    if ($seen.Add([string]$value)) {
                        [string]$value
                    }
                }
            }
        )
    }

    if ($null -eq $minimum -and $null -eq $maximum -and $null -eq $values) {
        return
    }

    [pscustomobject]@{
        Minimum = $minimum
        Maximum = $maximum
        Values  = $values
    }
}

function Merge-RestoreInputRuleHC {
    # One rule for a placeholder that is used in several places: an answer
    # must be valid in each of them
    param(
        $First,
        $Second
    )

    if ($null -eq $First) {
        return $Second
    }

    if ($null -eq $Second) {
        return $First
    }

    $minimum = @($First.Minimum, $Second.Minimum) |
        Where-Object { $null -ne $_ } |
        Measure-Object -Maximum
    $maximum = @($First.Maximum, $Second.Maximum) |
        Where-Object { $null -ne $_ } |
        Measure-Object -Minimum

    $values = if ($First.Values -and $Second.Values) {
        [string[]]@($First.Values | Where-Object { $_ -in $Second.Values })
    }
    elseif ($First.Values) {
        $First.Values
    }
    else {
        $Second.Values
    }

    $merged = [pscustomobject]@{
        Minimum = $null
        Maximum = $null
        Values  = $values
    }

    if ($minimum.Count) {
        $merged.Minimum = [long]$minimum.Maximum
    }

    if ($maximum.Count) {
        $merged.Maximum = [long]$maximum.Minimum
    }

    $merged
}

function Get-RestoreInputQuestionHC {
    <#
    .SYNOPSIS
        One question per placeholder that has no answer yet, in the order
        the sections run, with the rule of every place it is used.
    #>
    param(
        [object[]]$Fields,
        [System.Collections.IDictionary]$Answers
    )

    $schema = $null
    $questions = New-Object 'System.Collections.Generic.List[object]'
    $dictionaryType = 'System.Collections.Generic.Dictionary[string,object]'
    $lookup = New-Object $dictionaryType ([StringComparer]::Ordinal)
    $position = 0

    foreach ($field in $Fields) {
        $position++

        if ($null -ne $Answers -and $null -ne $Answers[$field.Placeholder]) {
            continue
        }

        $section = Get-RestoreInputSectionHC -Path $field.Path
        $rule = $null

        # A placeholder in a file or inside other text is text; the schema
        # does not describe it
        if ($null -ne $field.Container -and -not $field.Embedded) {
            if ($null -eq $schema) {
                $schemaParams = @{
                    LiteralPath = "$PSScriptRoot\..\Schemas\config.schema.json"
                    Raw         = $true
                    Encoding    = 'UTF8'
                }
                $schema = Get-Content @schemaParams | ConvertFrom-Json
            }

            $rule = Get-RestoreInputRuleHC -Path $field.Path -Schema $schema
        }

        $question = $null

        if ($lookup.TryGetValue($field.Placeholder, [ref]$question)) {
            $question.Paths.Add($field.Path)
            $question.Rule = Merge-RestoreInputRuleHC $question.Rule $rule

            # Ask it in the section that runs first, and name the others
            if ($section.Order -lt $question.SectionOrder) {
                $question.OtherSections.Insert(0, $question.Section)
                $question.Path = $field.Path
                $question.Section = $section.Name
                $question.SectionOrder = $section.Order
                $question.Index = $position
                $null = $question.OtherSections.Remove($section.Name)
            }
            elseif (
                $section.Name -ne $question.Section -and
                $question.OtherSections -notcontains $section.Name
            ) {
                $question.OtherSections.Add($section.Name)
            }

            continue
        }

        $question = [pscustomobject]@{
            Placeholder   = $field.Placeholder
            Kind          = $field.Kind
            Description   = $field.Description
            Path          = $field.Path
            # Every place the placeholder is used
            Paths         = New-Object 'System.Collections.Generic.List[string]'
            Section       = $section.Name
            SectionOrder  = $section.Order
            Index         = $position
            OtherSections = New-Object 'System.Collections.Generic.List[string]'
            Rule          = $rule
        }
        $question.Paths.Add($field.Path)
        $lookup.Add($field.Placeholder, $question)
        $questions.Add($question)
    }

    $questions | Sort-Object -Property SectionOrder, Index
}

function Get-RestoreInputHintHC {
    # What an answer must look like, as shown below its field
    param(
        [string]$Kind,
        $Rule
    )

    if ($Rule.Values) {
        return 'Choose a value from the list.'
    }

    $minimum = $Rule.Minimum
    $maximum = $Rule.Maximum

    switch ($Kind) {
        'ipv4' {
            'Enter an IPv4 address, such as 192.0.2.10.'
        }
        'prefix' {
            'Enter a prefix length from 1 to 32, such as 24.'
        }
        'number' {
            if ($null -ne $minimum -and $null -ne $maximum) {
                "Enter a whole number from $minimum to $maximum."
            }
            elseif ($null -ne $minimum) {
                "Enter a whole number of at least $minimum."
            }
            elseif ($null -ne $maximum) {
                "Enter a whole number of at most $maximum."
            }
            else {
                'Enter a whole number, such as 15.'
            }
        }
        default {
            ''
        }
    }
}

function Get-RestoreInputProblemHC {
    # Why an answer is not valid for its question; nothing when it is valid
    param(
        [string]$Kind,
        [string]$Value,
        $Rule
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'A value is required.'
    }

    if ($Rule.Values -and $Value -notin $Rule.Values) {
        return 'Choose a value from the list.'
    }

    $hint = Get-RestoreInputHintHC -Kind $Kind -Rule $Rule

    if (-not (Test-RestoreInputValueHC -Kind $Kind -Value $Value)) {
        return $hint
    }

    if ($Kind -in @('prefix', 'number')) {
        $number = [long]$Value

        if (
            ($null -ne $Rule.Minimum -and $number -lt $Rule.Minimum) -or
            ($null -ne $Rule.Maximum -and $number -gt $Rule.Maximum)
        ) {
            return $hint
        }
    }
}

function Get-RestoreInputControlValueHC {
    # The answer in a text box or the value chosen in a list
    param(
        [Parameter(Mandatory)]$Control
    )

    if ($Control -is [Windows.Forms.ComboBox]) {
        return [string]$Control.SelectedItem
    }

    $Control.Text
}

function Get-RestoreInputPanelHC {
    # The questions panel that contains a control
    param(
        [Parameter(Mandatory)]$Control
    )

    $parent = $Control

    while ($null -ne $parent -and $parent.Name -ne 'RestoreInputPanel') {
        $parent = $parent.Parent
    }

    $parent
}

function Update-RestoreInputPanelHC {
    # Show the problem of every answer that was left, count the answers
    # still needed, and enable the confirm button only when all are valid
    param(
        [Parameter(Mandatory)]$Panel
    )

    $invalid = 0

    foreach ($control in $Panel.Tag.Inputs) {
        $state = $control.Tag
        $question = $state.Question
        $problemParams = @{
            Kind  = $question.Kind
            Value = Get-RestoreInputControlValueHC -Control $control
            Rule  = $question.Rule
        }
        $problem = Get-RestoreInputProblemHC @problemParams

        if (-not $problem) {
            $state.Message.Text = ''
            continue
        }

        $invalid++

        if ($state.Touched) {
            $state.Message.Text = $problem
            $state.Message.ForeColor = [Drawing.Color]::Firebrick
        }
        else {
            $hintParams = @{
                Kind = $question.Kind
                Rule = $question.Rule
            }
            $state.Message.Text = Get-RestoreInputHintHC @hintParams
            $state.Message.ForeColor = [Drawing.Color]::DimGray
        }
    }

    if ($null -ne $Panel.Tag.Confirm) {
        $Panel.Tag.Confirm.Enabled = $invalid -eq 0
    }

    $Panel.Controls.Find('InputSummary', $true)[0].Text = if ($invalid) {
        "$invalid of $($Panel.Tag.Inputs.Count) answer(s) still needed"
    }
    else {
        'All answers are valid'
    }
}

function Get-RestoreInputPanelValuesHC {
    # The answers in the questions panel, by placeholder
    param(
        [Parameter(Mandatory)]$Panel
    )

    $dictionaryType = 'System.Collections.Generic.Dictionary[string,string]'
    $values = New-Object $dictionaryType ([StringComparer]::Ordinal)

    foreach ($control in $Panel.Tag.Inputs) {
        $values[$control.Tag.Question.Placeholder] = (
            Get-RestoreInputControlValueHC -Control $control
        )
    }

    return , $values
}

function Clear-RestoreInputPanelHC {
    # Forget the typed answers, passwords included
    param(
        [Parameter(Mandatory)]$Panel
    )

    foreach ($control in $Panel.Tag.Inputs) {
        if ($control -is [Windows.Forms.TextBox]) {
            $control.Clear()
        }
    }
}

function New-RestoreInputPanelHC {
    <#
    .SYNOPSIS
        Every question under a header for each section, for the input form
        and for the questions page of the wizard.
    .DESCRIPTION
        Each field checks its answer against the kind of placeholder and the
        schema of the setting, and a field with fixed values is a list.
        Values fills the fields with earlier answers, by placeholder. Set
        Tag.Confirm to the button that may only be used when every answer is
        valid, then call Update-RestoreInputPanelHC.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Questions,
        [string]$Introduction = (
            'Answer every question to start the restore. Nothing is ' +
            'changed before you click Continue.'
        ),
        [System.Collections.IDictionary]$Values,
        [Drawing.Font]$Font = (New-Object Drawing.Font 'Segoe UI', 10)
    )

    $percent = [Windows.Forms.SizeType]::Percent
    $autoSize = [Windows.Forms.SizeType]::AutoSize
    $smallFont = New-Object Drawing.Font $Font.FontFamily, 9
    $headerFont = New-Object Drawing.Font (
        $Font.FontFamily, 11, [Drawing.FontStyle]::Bold
    )

    # Rows: introduction, questions, how many answers are still needed
    $panel = New-Object Windows.Forms.TableLayoutPanel
    $panel.Name = 'RestoreInputPanel'
    $panel.Dock = 'Fill'
    $panel.ColumnCount = 1
    $null = $panel.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $percent, 100)
    )
    $panel.RowCount = 3
    $null = $panel.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $autoSize)
    )
    $null = $panel.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $percent, 100)
    )
    $null = $panel.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle $autoSize)
    )
    $panel.Tag = @{
        Inputs  = New-Object 'System.Collections.Generic.List[object]'
        Labels  = New-Object 'System.Collections.Generic.List[object]'
        Confirm = $null
    }

    $intro = New-Object Windows.Forms.Label
    $intro.Name = 'InputIntro'
    $intro.Text = $Introduction
    $intro.AutoSize = $true
    $intro.Dock = 'Fill'
    $intro.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 8
    $panel.Controls.Add($intro, 0, 0)

    $scroll = New-Object Windows.Forms.Panel
    $scroll.Name = 'InputQuestions'
    $scroll.Dock = 'Fill'
    $scroll.AutoScroll = $true
    $panel.Controls.Add($scroll, 0, 1)

    $list = New-Object Windows.Forms.TableLayoutPanel
    $list.Dock = 'Top'
    $list.AutoSize = $true
    $list.AutoSizeMode = 'GrowAndShrink'
    $list.ColumnCount = 1
    $null = $list.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle $percent, 100)
    )
    $list.GrowStyle = 'AddRows'
    $scroll.Controls.Add($list)

    $summary = New-Object Windows.Forms.Label
    $summary.Name = 'InputSummary'
    $summary.AutoSize = $true
    $summary.Dock = 'Fill'
    $summary.Margin = New-Object Windows.Forms.Padding 0, 8, 0, 0
    $panel.Controls.Add($summary, 0, 2)

    $section = $null

    foreach ($question in $Questions) {
        if ($question.Section -ne $section) {
            $section = $question.Section

            $header = New-Object Windows.Forms.Label
            $header.Name = 'SectionHeader'
            $header.Text = $section
            $header.UseMnemonic = $false
            $header.Font = $headerFont
            $header.ForeColor = [Drawing.Color]::DarkSlateBlue
            $header.AutoSize = $true
            $top = if ($list.Controls.Count) {
                16
            }
            else {
                0
            }
            $header.Margin = New-Object Windows.Forms.Padding 0, $top, 0, 4
            $list.Controls.Add($header)
        }

        $description = New-Object Windows.Forms.Label
        $description.Name = 'QuestionDescription'
        $description.Text = $question.Description
        $description.UseMnemonic = $false
        $description.AutoSize = $true
        $description.Margin = New-Object Windows.Forms.Padding 0, 6, 0, 0
        $panel.Tag.Labels.Add($description)
        $list.Controls.Add($description)

        $locationText = $question.Path
        if ($question.OtherSections.Count) {
            $locationText += (
                [Environment]::NewLine +
                "Also used by: $($question.OtherSections -join ', ')"
            )
        }

        $location = New-Object Windows.Forms.Label
        $location.Name = 'QuestionLocation'
        $location.Text = $locationText
        $location.UseMnemonic = $false
        $location.Font = $smallFont
        $location.ForeColor = [Drawing.Color]::DimGray
        $location.AutoSize = $true
        $location.Margin = New-Object Windows.Forms.Padding 0, 0, 0, 2
        $panel.Tag.Labels.Add($location)
        $list.Controls.Add($location)

        $earlier = $null
        if ($null -ne $Values) {
            $earlier = $Values[$question.Placeholder]
        }

        if ($question.Rule.Values) {
            $control = New-Object Windows.Forms.ComboBox
            $control.DropDownStyle = 'DropDownList'
            $control.Items.AddRange([object[]]$question.Rule.Values)
            if ($earlier -and $control.Items.Contains($earlier)) {
                $control.SelectedItem = $earlier
            }
            $control.Add_SelectedIndexChanged({
                $this.Tag.Touched = $true
                $inputPanel = Get-RestoreInputPanelHC -Control $this
                Update-RestoreInputPanelHC -Panel $inputPanel
            })
        }
        else {
            $control = New-Object Windows.Forms.TextBox
            $control.UseSystemPasswordChar = $question.Kind -eq 'password'
            if ($earlier) {
                $control.Text = $earlier
            }
            $control.Add_TextChanged({
                $inputPanel = Get-RestoreInputPanelHC -Control $this
                Update-RestoreInputPanelHC -Panel $inputPanel
            })
        }

        $control.Name = "Answer$($panel.Tag.Inputs.Count)"
        $control.AccessibleName = $question.Description
        $control.Dock = 'Fill'
        $control.Margin = New-Object Windows.Forms.Padding 0
        $control.Add_Leave({
            $this.Tag.Touched = $true
            $inputPanel = Get-RestoreInputPanelHC -Control $this
            Update-RestoreInputPanelHC -Panel $inputPanel
        })

        $message = New-Object Windows.Forms.Label
        $message.Name = "Problem$($panel.Tag.Inputs.Count)"
        $message.Font = $smallFont
        $message.AutoSize = $true
        $message.Margin = New-Object Windows.Forms.Padding 0, 2, 0, 0
        $panel.Tag.Labels.Add($message)

        $control.Tag = @{
            Question = $question
            Message  = $message
            Touched  = [bool]$earlier
        }
        $panel.Tag.Inputs.Add($control)
        $list.Controls.Add($control)
        $list.Controls.Add($message)
    }

    # Long texts wrap at the width of the panel instead of scrolling sideways
    $scroll.Add_Resize({
        $width = [Math]::Max(120, $this.ClientSize.Width - 24)
        foreach ($label in $this.Parent.Tag.Labels) {
            $label.MaximumSize = New-Object Drawing.Size $width, 0
        }
    })

    Update-RestoreInputPanelHC -Panel $panel

    return , $panel
}

function New-RestoreInputFormHC {
    <#
    .SYNOPSIS
        One form with every question, under a header for each section.
    .DESCRIPTION
        Asks the questions that the wizard did not answer, for example in a
        restore from the command line. Continue is enabled once every
        answer is valid.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Questions
    )

    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Restore - input required'
    $dialog.ClientSize = New-Object Drawing.Size 640, 560
    $dialog.MinimumSize = New-Object Drawing.Size 520, 360
    $dialog.Font = New-Object Drawing.Font 'Segoe UI', 10
    $dialog.StartPosition = 'CenterScreen'
    $dialog.TopMost = $true

    # Rows: questions, buttons
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.Padding = New-Object Windows.Forms.Padding 16
    $layout.ColumnCount = 1
    $null = $layout.ColumnStyles.Add(
        (New-Object Windows.Forms.ColumnStyle (
            [Windows.Forms.SizeType]::Percent
        ), 100)
    )
    $layout.RowCount = 2
    $null = $layout.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle (
            [Windows.Forms.SizeType]::Percent
        ), 100)
    )
    $null = $layout.RowStyles.Add(
        (New-Object Windows.Forms.RowStyle (
            [Windows.Forms.SizeType]::Absolute
        ), 48)
    )
    $dialog.Controls.Add($layout)

    $panel = New-RestoreInputPanelHC -Questions $Questions -Font $dialog.Font
    $layout.Controls.Add($panel, 0, 0)

    $dialog.Tag = @{
        Panel  = $panel
        Inputs = $panel.Tag.Inputs
        Values = $null
    }

    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Fill'
    $buttons.FlowDirection = 'RightToLeft'

    $confirm = New-Object Windows.Forms.Button
    $confirm.Name = 'ConfirmInput'
    $confirm.Text = 'Continue'
    $confirm.Size = New-Object Drawing.Size 110, 34
    $confirm.Add_Click({
        $owner = $this.FindForm()
        $inputPanel = $owner.Tag.Panel
        Update-RestoreInputPanelHC -Panel $inputPanel
        if (-not $this.Enabled) {
            return
        }

        $owner.Tag.Values = Get-RestoreInputPanelValuesHC -Panel $inputPanel
        $owner.DialogResult = [Windows.Forms.DialogResult]::OK
    })

    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Size = New-Object Drawing.Size 110, 34
    $cancel.DialogResult = 'Cancel'

    $buttons.Controls.AddRange(@($confirm, $cancel))
    $layout.Controls.Add($buttons, 0, 1)
    $dialog.AcceptButton = $confirm
    $dialog.CancelButton = $cancel

    $panel.Tag.Confirm = $confirm
    Update-RestoreInputPanelHC -Panel $panel

    if ($panel.Tag.Inputs.Count) {
        $dialog.ActiveControl = $panel.Tag.Inputs[0]
    }

    return , $dialog
}

function Read-RestoreInputHC {
    # Ask every question in one form; returns the answers by placeholder,
    # or nothing when the form is cancelled
    param(
        [Parameter(Mandatory)][object[]]$Questions
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $dialog = New-RestoreInputFormHC -Questions $Questions

    try {
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            return $dialog.Tag.Values
        }
    }
    finally {
        Clear-RestoreInputPanelHC -Panel $dialog.Tag.Panel
        $dialog.Tag.Values = $null
        $dialog.Dispose()
    }
}

function ConvertTo-RestoreAnswerBytesHC {
    # Answers as UTF-8 JSON; a list of pairs, because placeholders are
    # case-sensitive and the keys of a JSON object are not in PowerShell
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Answers
    )

    $pairs = @(
        foreach ($key in $Answers.Keys) {
            [pscustomobject]@{
                Key   = [string]$key
                Value = [string]$Answers[$key]
            }
        }
    )
    $json = ConvertTo-Json -InputObject $pairs -Compress

    [Text.Encoding]::UTF8.GetBytes($json)
}

function ConvertFrom-RestoreAnswerBytesHC {
    # The answers of ConvertTo-RestoreAnswerBytesHC, by placeholder
    param(
        [Parameter(Mandatory)][byte[]]$Bytes
    )

    $dictionaryType = 'System.Collections.Generic.Dictionary[string,string]'
    $answers = New-Object $dictionaryType ([StringComparer]::Ordinal)
    $json = [Text.Encoding]::UTF8.GetString($Bytes)
    # Windows PowerShell returns the array as one object; foreach unrolls it
    $pairs = ConvertFrom-Json -InputObject $json

    foreach ($pair in $pairs) {
        $answers[[string]$pair.Key] = [string]$pair.Value
    }

    return , $answers
}

function Start-RestoreAnswerServerHC {
    <#
    .SYNOPSIS
        Serve answers once over a named pipe, from memory, and return the
        pipe name and the PowerShell instance that serves it.
    .DESCRIPTION
        The wizard hands the answers of its questions page to the restore
        process this way, without writing them to disk or putting them in
        the command line. The pipe has a random name, admits only the
        current account and the Administrators group, accepts one
        connection, and closes after the answers are sent or after
        TimeoutSeconds. Stop the returned instance to close it sooner.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Answers,
        [int]$TimeoutSeconds = 600
    )

    $pipeName = 'ComputerSnapshot-' + [guid]::NewGuid().ToString('N')
    $bytes = ConvertTo-RestoreAnswerBytesHC -Answers $Answers

    $serve = {
        param(
            [string]$PipeName,
            [byte[]]$Bytes,
            [int]$TimeoutSeconds
        )

        $pipes = 'System.IO.Pipes'
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            Add-Type -AssemblyName System.IO.Pipes.AccessControl
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $administrators = New-Object Security.Principal.SecurityIdentifier (
            'S-1-5-32-544'
        )
        $security = New-Object "$pipes.PipeSecurity"
        $security.AddAccessRule(
            (New-Object "$pipes.PipeAccessRule" (
                $identity.User, 'FullControl', 'Allow'
            ))
        )
        $security.AddAccessRule(
            (New-Object "$pipes.PipeAccessRule" (
                $administrators, 'ReadWrite', 'Allow'
            ))
        )
        $identity.Dispose()

        $pipeArguments = @(
            $PipeName, [IO.Pipes.PipeDirection]::Out, 1,
            [IO.Pipes.PipeTransmissionMode]::Byte,
            [IO.Pipes.PipeOptions]::Asynchronous, 0, 0, $security
        )
        # PowerShell 7 creates a pipe with an access list through a factory
        $server = if ("$pipes.NamedPipeServerStreamAcl" -as [type]) {
            [IO.Pipes.NamedPipeServerStreamAcl]::Create.Invoke(
                $pipeArguments + @([IO.HandleInheritability]::None, 0)
            )
        }
        else {
            New-Object "$pipes.NamedPipeServerStream" $pipeArguments
        }

        try {
            $connection = $server.BeginWaitForConnection($null, $null)
            $timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

            if (-not $connection.AsyncWaitHandle.WaitOne($timeout)) {
                return
            }

            $server.EndWaitForConnection($connection)
            $server.Write($Bytes, 0, $Bytes.Length)
            $server.Flush()
            $server.WaitForPipeDrain()
        }
        finally {
            [Array]::Clear($Bytes, 0, $Bytes.Length)
            $server.Dispose()
        }
    }

    $powerShell = [PowerShell]::Create()
    $null = $powerShell.AddScript($serve.ToString())
    $null = $powerShell.AddParameters(
        @{
            PipeName       = $pipeName
            Bytes          = $bytes
            TimeoutSeconds = $TimeoutSeconds
        }
    )
    $null = $powerShell.BeginInvoke()

    [pscustomobject]@{
        PipeName   = $pipeName
        PowerShell = $powerShell
    }
}

function Receive-RestoreAnswersHC {
    # The answers that Start-RestoreAnswerServerHC serves on the pipe
    param(
        [Parameter(Mandatory)][string]$PipeName,
        [int]$TimeoutSeconds = 30
    )

    $client = New-Object IO.Pipes.NamedPipeClientStream (
        '.', $PipeName, [IO.Pipes.PipeDirection]::In
    )

    try {
        $client.Connect($TimeoutSeconds * 1000)

        $buffer = New-Object IO.MemoryStream
        try {
            $client.CopyTo($buffer)
            $bytes = $buffer.ToArray()
        }
        finally {
            $buffer.Dispose()
        }

        try {
            ConvertFrom-RestoreAnswerBytesHC -Bytes $bytes
        }
        finally {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
    finally {
        $client.Dispose()
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
        if ($field.Count -ne 1 -or $field[0].Embedded) {
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
        $kind = $field[0].Kind
        $type = $node.GetAttribute('type')
        $allowedTypes = @('string')
        $expected = "nonempty, valid $kind string"

        # A prefix length or a whole number is a number, so 24 is as natural
        # as "24"
        if ($kind -in @('prefix', 'number')) {
            $allowedTypes += 'number'
            $expected += ' or number'
        }

        $valueParams = @{
            Kind  = $kind
            Value = $node.InnerText
        }
        if (
            $type -notin $allowedTypes -or
            -not (Test-RestoreInputValueHC @valueParams)
        ) {
            throw (
                "Answer file '$Path': the answer for '$key' must be a " +
                "$expected."
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

function Test-ConfigurationBeforeInputHC {
    <#
    .SYNOPSIS
        Check a configuration before restore-time input is asked for.
    .DESCRIPTION
        Returns the problems of Test-ConfigurationHC, except those of a value
        that still holds a placeholder, such as {{prefix:...}} where a
        number is expected, {{ipv4:...}} in a path or a host name such as
        'kiosk-{{input:Site}}'. Those are checked again
        after the answers are filled in. This way nobody types answers for a
        configuration that cannot be restored anyway.
    #>
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$RootFolder
    )

    $placeholderPaths = @(
        Get-RestoreInputFieldsHC -Data $Configuration.Items |
        ForEach-Object { " > $($_.Path): " }
    )

    $testParams = @{
        Configuration = $Configuration
        RootFolder    = $RootFolder
    }

    foreach ($problem in @(Test-ConfigurationHC @testParams)) {
        $isPlaceholder = @(
            $placeholderPaths | Where-Object { $problem.Contains($_) }
        ).Count

        if (-not $isPlaceholder) {
            $problem
        }
    }
}

function Resolve-RestoreInputHC {
    param(
        $Items,
        # Called once with every question that has no answer yet, one per
        # placeholder; returns the answers by placeholder, or nothing to
        # cancel the restore
        [Parameter(Mandatory)][scriptblock]$ReadValues,
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

    $questionParams = @{
        Fields  = $fields
        Answers = $suppliedAnswers
    }
    $questions = @(Get-RestoreInputQuestionHC @questionParams)
    $readAnswers = $null

    if ($questions.Count) {
        Write-Verbose "Ask $($questions.Count) question(s) in one form"
        $readAnswers = & $ReadValues $questions

        if ($null -eq $readAnswers) {
            throw [OperationCanceledException]::new(
                'Restore cancelled. No items executed.'
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
            $readAnswers[$field.Placeholder]
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

        $answer = if ($field.Embedded) {
            # Fill in every placeholder of the original text at once, so an
            # answer that looks like a placeholder is never filled in again
            $parts = [regex]::Split(
                $field.Text,
                '(\{\{(?:input|ipv4):[^{}\r\n]+\}\})'
            )
            -join @(
                foreach ($part in $parts) {
                    if ($answers.ContainsKey($part)) {
                        $answers[$part]
                    }
                    else {
                        $part
                    }
                }
            )
        }
        else {
            # Prefix lengths and whole numbers are numbers in the
            # configuration
            switch ($field.Kind) {
                'prefix' {
                    [int]$answers[$field.Placeholder]
                }
                'number' {
                    ConvertTo-RestoreInputNumberHC $answers[$field.Placeholder]
                }
                default {
                    $answers[$field.Placeholder]
                }
            }
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
