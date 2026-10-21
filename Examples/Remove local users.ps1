@('bob') | ForEach-Object {
    if (Get-LocalUser -Name $_ -EA Ignore) {
        Remove-localUser -Name $_
        "Removed user account '$_'"
    }
    else {
        "User account '$_' not found"
    }
}