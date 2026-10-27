#Requires -Version 5.1

function Get-RestoreInputFieldsHC {
    param(
        $Data,
        [string]$Path = 'Items', 
        $Container, 
        $Key
    )
         
    if ($Data -is [string]) {
        $match = [regex]::Match($Data, '\A\{\{(?<Kind>input|password|ipv4):(?<Description>[^{}\r\n]+)\}\}\z')
        
        if (
            $match.Success -and
            -not [string]::IsNullOrWhiteSpace($match.Groups['Description'].Value)
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
            $Data -match '\{\{(?:input|password|ipv4):'
        ) {
            throw "${Path}: use a complete {{input:Description}}, {{password:Description}} or {{ipv4:Description}} string."
        }

        return
    }

    if ($Data -is [array]) {
        for ($index = 0; $index -lt $Data.Count; $index++) {
            Get-RestoreInputFieldsHC `
                -Data $Data[$index] `
                -Path "${Path}[$index]" `
                -Container $Data `
                -Key $index
        }
    }
    elseif ($Data -is [System.Collections.IDictionary]) {
        foreach ($name in $Data.Keys) {
            if ($name -cne 'Comment') {
                Get-RestoreInputFieldsHC `
                    -Data $Data[$name] `
                    -Path "$Path.$name" `
                    -Container $Data `
                    -Key $name
            }
        }
    }
    elseif (
        $null -ne $Data -and $Data.GetType() -eq [System.Management.Automation.PSCustomObject]
    ) {
        foreach ($property in $Data.PSObject.Properties) {
            if ($property.Name -cne 'Comment') { 
                Get-RestoreInputFieldsHC `
                    -Data $property.Value `
                    -Path "$Path.$($property.Name)" `
                    -Container $Data `
                    -Key $property.Name
            }
        }
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
            $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $address.ToString() -ceq $Value
        )
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
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.Padding = New-Object Windows.Forms.Padding 16
    $layout.ColumnCount = 1
    $null = $layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle ([Windows.Forms.SizeType]::Percent), 100))
    $layout.RowCount = 5
    foreach ($index in 1..2) { $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::AutoSize))) }
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Absolute), 38))
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Percent), 100))
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle ([Windows.Forms.SizeType]::Absolute), 44))
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
            if (-not (Test-RestoreInputValueHC -Kind $owner.Tag.Kind -Value $value)) { return }
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
            $valid = Test-RestoreInputValueHC -Kind $owner.Tag.Kind -Value $this.Text
            $owner.Controls.Find('ConfirmInput', $true)[0].Enabled = $valid
            $owner.Controls.Find('InputValidation', $true)[0].Text = if ($valid) { '' }
            elseif ([string]::IsNullOrWhiteSpace($this.Text)) { 'A value is required.' }
            else { 'Enter an IPv4 address such as 192.0.2.10.' }
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

function Resolve-RestoreInputHC {
    param(
        $Items,
        [Parameter(Mandatory)][scriptblock]$ReadValue
    )

    $fields = @(Get-RestoreInputFieldsHC -Data $Items)
    $answers = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $secrets = New-Object 'System.Collections.Generic.List[string]'
    
    foreach ($field in $fields) {
        if ($answers.ContainsKey($field.Placeholder)) { 
            continue 
        }

        $value = & $ReadValue $field
        
        if ($null -eq $value) {
            throw [OperationCanceledException]::new('Restore cancelled. No items executed.') 
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
        if (
            $field.Container -is [System.Collections.IDictionary] -or 
            $field.Container -is [array]
        ) {
            $field.Container[$field.Key] = $answers[$field.Placeholder]
        }
        else {
            $field.Container.($field.Key) = $answers[$field.Placeholder] 
        }
    }

    [pscustomobject]@{ 
        SecretValues = $secrets.ToArray() 
    }
}

function Protect-RestoreInputTextHC {
    param(
        [string]$Text,
        [string[]]$SecretValues
    )
         
    foreach (
        $secret in
        $SecretValues | Sort-Object Length -Descending
    ) {
        if (-not [string]::IsNullOrEmpty($secret)) { 
            $Text = $Text.Replace($secret, '[redacted]') 
        }
    }
    
    return $Text
}