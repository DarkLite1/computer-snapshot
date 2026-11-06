#Requires -Version 5.1

function New-FakeReadValuesHC {
    <#
    .SYNOPSIS
        A ReadValues script block for Resolve-RestoreInputHC that answers
        each question of the input form with Answer, as a user would.
    .DESCRIPTION
        Answer gets one question and returns its answer. Nothing for any
        question cancels the form.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Answer
    )

    {
        param($questions)

        $dictionaryType = 'System.Collections.Generic.Dictionary[string,string]'
        $values = New-Object $dictionaryType ([StringComparer]::Ordinal)

        foreach ($question in $questions) {
            $value = & $Answer $question

            if ($null -eq $value) {
                return
            }

            $values[$question.Placeholder] = $value
        }

        $values
    }.GetNewClosure()
}
