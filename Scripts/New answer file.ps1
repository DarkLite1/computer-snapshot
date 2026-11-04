#Requires -Version 5.1
<#
.SYNOPSIS
    Create an empty answer file for the placeholders in a configuration.
.DESCRIPTION
    Includes selected shared sections and fixed-source CopyFilesFolders
    templates with FillPlaceholders. Does not prompt, restore or copy files.
    Null values must be filled with strings before an unattended restore.
.PARAMETER ConfigurationFile
    Configuration template, relative to the USB root unless absolute.
.PARAMETER AnswerFile
    Output JSON path, relative to the USB root unless absolute. Its directory
    must already exist. Password answers will be plain text when filled in.
.PARAMETER Items
    Optional section selection, matching the restore selection.
.PARAMETER Force
    Replace an existing answer file. The configuration itself is protected.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigurationFile,
    [Parameter(Mandatory)][string]$AnswerFile,
    [string[]]$Items,
    [switch]$Force
)
Import-Module "$PSScriptRoot\Common\Configuration.psm1" -Force
. "$PSScriptRoot\Common\Section.ps1"
. "$PSScriptRoot\Common\RestoreInput.ps1"

$rootFolder = Split-Path $PSScriptRoot -Parent
Write-Verbose "Create answer file '$AnswerFile' for '$ConfigurationFile'"
New-RestoreAnswerFileHC @PSBoundParameters -RootFolder $rootFolder
