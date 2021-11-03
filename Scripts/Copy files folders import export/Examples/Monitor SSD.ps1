Param (
    [String]$SmtpServer,
    [String[]]$MailTo
)

Begin {
    Function Send-MailHC {
        <#
    .SYNOPSIS
        Send an e-mail message as anonymous, when allowed by the SMTP-Relay 
        server.

    .DESCRIPTION
        This function sends out a preformatted HTML e-mail by only providing 
        the recipient, subject and body. The e-mail formatting is optimized for 
        MS Outlook. 

    .PARAMETER From
        The sender address, by preference this is an existing mailbox so we get 
        the bounce back mail in case of failure. But the From address does not
        need to exist if SMTP-relay is enabled on the network for the local 
        computer.

    .PARAMETER To
        The e-mail address of the recipient(s) you wish to e-mail.

    .PARAMETER Bcc
        The e-mail address of the recipient(s) you wish to e-mail in Blind 
        Carbon Copy. Other users will not see the e-mail address of users in 
        the 'Bcc' field.

    .PARAMETER Cc
        The e-mail address of the recipient(s) you wish to e-mail in Carbon 
        Copy.

    .PARAMETER From
        The address from which the mail is sent. Enter a name (optional) and 
        e-mail address, such as "Name <someone@example.com>". If not specified, 
        the default value will be the script name or 'Test' when the script 
        name is unknown.

    .PARAMETER Subject
        The Subject-header used in the e-mail.

    .PARAMETER Message
        The message you want to send will appear by default in a paragraph 
        '<p>My message</p>'. If you want to have a title/header too, you can 
        use: -Message "<h3>Header one:<\h3>", "My message"

    .PARAMETER Priority
        Specifies the priority of the e-mail message. Valid values are 
        'Normal', 'High', and 'Low'. If not specified, the default value is 
        'Normal'.

    .PARAMETER Attachments
        Specifies the path and file names of files to be attached to the e-mail 
        message.

    .EXAMPLE
        "The world will change tomorrow." | 
        Send-MailHC -To 'Bob@domain.net' -Subject 'Notification'
        
        Sends an e-mail to Bob with the subject "Notification' and the body "The world will change tomorrow.".
 #>

        [CmdLetBinding()]
        Param (
            [Parameter(Mandatory)]
            [String]$SMTPserver,    
            [Parameter(Mandatory)]
            [String]$Header,
            [Parameter(Mandatory, Position = 0)]
            [ValidateNotNullOrEmpty()]
            [String[]]$To,
            [Parameter(Mandatory, Position = 1)]
            [ValidateNotNullOrEmpty()]
            [String]$Subject,
            [Parameter(Mandatory, Position = 2, ValueFromPipeline)]
            [ValidateNotNullOrEmpty()]
            [String[]]$Message,
            [String[]]$Cc,
            [String[]]$Bcc,
            [ValidateScript( { Test-Path $_ -PathType Leaf })]
            [String[]]$Attachments,
            [ValidateSet('Low', 'Normal', 'High')]
            [String]$Priority = 'Normal',
            [ValidateNotNullOrEmpty()]
            [String]$From = "PowerShell@$env:COMPUTERNAME"
        )

        Begin {
            Try {
                $EncUTF8 = New-Object System.Text.utf8encoding

                $OriginalMessage = @()

                #region Excel files that are opened can't be sent as attachment
                # so we copy them first
                $Attachment = New-Object System.Collections.ArrayList($null)

                $TmpFolder = "$env:TEMP\Send-MailHC {0}" -f (Get-Random)
                foreach ($a in $Attachments) {
                    if ($a -like '*.xlsx') {
                        if (-not(Test-Path $TmpFolder)) {
                            $null = New-Item $TmpFolder -ItemType Directory
                        }
                        Copy-Item $a -Destination $TmpFolder

                        $null = $Attachment.Add("$TmpFolder\$(Split-Path $a -Leaf)")
                    }
                    else {
                        $null = $Attachment.Add($a)
                    }
                }
                #endregion
            }
            Catch {
                $Global:Error.RemoveAt(0)
                throw "Failed sending e-mail to '$To': $_"
            }
        }

        Process {
            Foreach ($M in $Message) {
                $M = $M.Trim()

                $OriginalMessage += $M
                if ($M -like '<*') {
                    # We receive pre-formatted HTML-code
                    $Messages += $M
                }
                else {
                    # We receive plain text and make it a paragraph
                    $Messages += "<p>$M</p>"
                }
            }
        }

        End {
            Try {
                $HTML = @"
<!DOCTYPE html>
<html><head><style type="text/css">
body {font-family:verdana;background-color:white;}
h1 {background-color:black;color:white;margin-bottom:10px;text-indent:10px;page-break-before: always;}
h2 {background-color:lightGrey;margin-bottom:10px;text-indent:10px;page-break-before: always;}
h3 {background-color:lightGrey;margin-bottom:10px;font-size:16px;text-indent:10px;page-break-before: always;}
p {font-size: 14px;margin-left:10px;}
p.italic {font-style: italic;font-size: 12px;}
table {font-size:14px;border-collapse:collapse;border:1px none;padding:3px;text-align:left;padding-right:10px;margin-left:10px;}
td, th {font-size:14px;border-collapse:collapse;border:1px none;padding:3px;text-align:left;padding-right:10px}
li {font-size: 14px;}
base {target="_blank"}
</style></head><body>
<h1>$Header</h1>
<h2>The following has been reported:</h2>
$Messages
<h2>About</h2>
<table>
<colgroup><col/><col/></colgroup>
$(if($global:PSCommandPath){"<tr><th>PSCommandPath</th><td>$global:PSCommandPath</td></tr>"})
<tr><th>Host</th><td>$($host.Name)</td></tr>
<tr><th>ComputerName</th><td>$env:COMPUTERNAME</td></tr>
<tr><th>Whoami</th><td>$(if($env:USERDNSDOMAIN){"$env:USERDNSDOMAIN\"};"$env:USERNAME")</td></tr>
</table>
</body></html>
"@

                $EmailParams = @{
                    To          = $To
                    Cc          = $Cc
                    Bcc         = $Bcc
                    From        = $Header + ' <' + $From + '>'
                    Subject     = $Subject
                    Body        = $HTML
                    BodyAsHtml  = $True
                    Priority    = $Priority
                    SMTPServer  = $SMTPserver
                    Attachments = $Attachment
                    Encoding    = $EncUTF8
                    ErrorAction = 'Stop'
                }

                #region Remove empty params
                $list = New-Object System.Collections.ArrayList($null)
                foreach ($h in $EmailParams.Keys) { 
                    if ($($EmailParams.Item($h)) -eq $null) { 
                        $null = $list.Add($h) 
                    } 
                }
                foreach ($h in $list) { $EmailParams.Remove($h) }
                #endregion

                Send-MailMessage @EmailParams
                Write-Verbose "Mail sent to '$To'"
            }
            Catch {
                $Global:Error.RemoveAt(0)
                throw "Failed sending e-mail to '$($To)': $_"
            }
            Finally {
                if (Test-Path $TmpFolder) {
                    Remove-Item -LiteralPath $TmpFolder -Recurse -Force
                }
            }
        }
    }

    if (-not $SmtpServer) {
        throw 'SMTP Server name is required'
    }
    if (-not $MailTo) {
        throw 'E-mail To field is required'
    }
}

Process {
    $physicalDisks = Foreach ($disk in Get-PhysicalDisk) {
        $reliabilityCounter = $disk | Get-StorageReliabilityCounter

        [PSCustomObject]@{
            Model                  = $disk.Model
            Size                   = [math]::Round($disk.Size / 1Gb, 0)
            OperationalStatus      = $disk.OperationalStatus
            HealthStatus           = $disk.HealthStatus
            MediaType              = $disk.MediaType
            Temperature            = $reliabilityCounter.Temperature
            TemperatureMax         = $reliabilityCounter.TemperatureMax
            Wear                   = $reliabilityCounter.Wear
            ReadErrorsCorrected    = $reliabilityCounter.ReadErrorsCorrected
            ReadErrorsUncorrected  = $reliabilityCounter.ReadErrorsUncorrected
            ReadErrorsTotal        = $reliabilityCounter.ReadErrorsTotal
            WriteErrorsCorrected   = $reliabilityCounter.WriteErrorsCorrected
            WriteErrorsUncorrected = $reliabilityCounter.WriteErrorsUncorrected
            WriteErrorsTotal       = $reliabilityCounter.WriteErrorsTotal
        }
    }

    $failingDisks = $physicalDisks | Where-Object { 
       ($_.OperationalStatus -ne 'OK') -or ($_.HealthStatus -ne 'Healthy')
    }

    if ($failingDisks) {
        $htmlStyle = @"
<style>
    #overviewTable {
        border-collapse: collapse;
        border: 1px solid Black;
        table-layout: fixed;
    }

    #overviewTable th {
        font-weight: normal;
        text-align: left;
    }
    #overviewTable td {
        text-align: left;
    }
    table tbody tr td a {
        display: block;
        width: 100%;
        height: 100%;
    }
</style>
"@

        $htmlTableFailingDrives = foreach ($f in $failingDisks) {
@"
<table id="overviewTable">
    <tr>
        <th>Model</th>
        <td><b>$($f.Model)</b></td>
    </tr>
    <tr>
        <th>Type</th>
        <td>$($f.MediaType)</td>
    </tr>
    <tr>
        <th>Size</th>
        <td>$($f.Size) GB</td>
    </tr>
    <tr>
        <th>OperationalStatus</th>
        <td>$($f.OperationalStatus)</td>
    </tr>
    <tr>
        <th>HealthStatus</th>
        <td>$($f.HealthStatus)</td>
    </tr>
    <tr>
        <th>Temperature</th>
        <td>$($f.Temperature)</td>
    </tr>
    <tr>
        <th>TemperatureMax</th>
        <td>$($f.TemperatureMax)</td>
    </tr>
    $(
        if($f.Wear) {
            "<tr>
                <th>Wear</th>
                <td>$($f.Wear)</td>
            </tr>"
        }
    )
    $(
        if($f.ReadErrorsCorrected) {
            "<tr>
                <th>ReadErrorsCorrected</th>
                <td>$($f.ReadErrorsCorrected)</td>
            </tr>"
        }
    )
    $(
        if($f.ReadErrorsUncorrected) {
            "<tr>
                <th>ReadErrorsUncorrected</th>
                <td>$($f.ReadErrorsUncorrected)</td>
            </tr>"
        }
    )
    $(
        if($f.ReadErrorsTotal) {
            "<tr>
                <th>ReadErrorsTotal</th>
                <td>$($f.ReadErrorsTotal)</td>
            </tr>"
        }
    )
    $(
        if($f.WriteErrorsCorrected) {
            "<tr>
                <th>WriteErrorsCorrected</th>
                <td>$($f.WriteErrorsCorrected)</td>
            </tr>"
        }
    )
    $(
        if($f.WriteErrorsUncorrected) {
            "<tr>
                <th>WriteErrorsUncorrected</th>
                <td>$($f.WriteErrorsUncorrected)</td>
            </tr>"
        }
    )
    $(
        if($f.WriteErrorsTotal) {
            "<tr>
                <th>WriteErrorsTotal</th>
                <td>$($f.WriteErrorsTotal)</td>
            </tr>"
        }
    )
</table>    
"@        
        }

        $mailParams = @{
            SmtpServer = $SmtpServer 
            Header     = 'Monitor hard drive'
            Priority   = 'High'
            To         = $MailTo 
            Subject    = 'Failure eminent' 
            Message    = @"
$htmlStyle
<p><b>Failing hard drive$(if($failingDisks.count -gt 1){'s'}):</b></p>
$(
    $htmlTableFailingDrives -join '<hr style="width:50%;text-align:left;margin-left:0">'
)
"@
        }
        Send-MailHC @mailParams
    }
}
