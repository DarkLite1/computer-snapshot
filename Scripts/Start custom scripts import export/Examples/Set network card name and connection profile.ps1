Param (
    [HashTable[]]$NetworkCards = @(
        @{
            Manufacturer = 'Broadcom'
            NetworkCardName = 'LAN FABRIEK'
            NetworkCategory = $null
        },
        @{
            Manufacturer = 'Intel'
            NetworkCardName = 'LAN KANTOOR'
            NetworkCategory = 'Private'
        }
    )
)

#region Rename network cards
$netAdapters = Get-NetAdapter

foreach ($card in $NetworkCards) {
    foreach ($adapter in $netAdapters) {    
        if (
            ($adapter.InterfaceDescription -like "*$($card.Manufacturer)*") -and
            ($adapter.Name -ne $card.NetworkCardName)
        ) {
            Rename-NetAdapter -Name $adapter.Name -NewName $card.NetworkCardName
            Write-Output "Renamed network card with description '$($adapter.InterfaceDescription)' from '$($adapter.Name)' to '$($card.NetworkCardName)'"
        }
    }
}
#endregion

#region Set network connection profile
$netConnectionProfile = Get-NetConnectionProfile

foreach ($card in $NetworkCards) {
    foreach ($profile in 
        $netConnectionProfile | Where-Object {
            ($_.InterfaceAlias -eq $card.NetworkCardName) -and
            ($_.NetworkCategory -ne $card.NetworkCategory) 
        }
    ) {    
        Set-NetConnectionProfile -InterfaceIndex $profile.InterfaceIndex -NetworkCategory $card.NetworkCategory
        Write-Output "Changed network connection profile on card '$($card.NetworkCardName)' from '$($profile.NetworkCategory)' to '$($card.NetworkCategory)'"
    }
}
#endregion