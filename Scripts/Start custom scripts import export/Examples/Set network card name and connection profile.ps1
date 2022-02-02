Param (
    [HashTable[]]$NetworkCards = @(
        @{
            NetworkCardDescription = 'Broadcom'
            NetworkCardName = 'LAN FABRIEK'
            NetworkCategory = $null
        },
        @{
            NetworkCardDescription = 'Intel'
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
            ($adapter.InterfaceDescription -like "*$($card.NetworkCardDescription)*") -and
            ($adapter.Name -ne $card.NetworkCardName)
        ) {
            Rename-NetAdapter -Name $adapter.Name -NewName $card.NetworkCardName
            Write-Output "Renamed network card with description '$($adapter.InterfaceDescription)' from '$($adapter.Name)' to '$($card.NetworkCardName)'"
        }
    }
}
#endregion

#region Set network connection profile
$netConnectionProfiles = Get-NetConnectionProfile

foreach ($card in $NetworkCards) {
    foreach ($profile in 
        $netConnectionProfiles | Where-Object {
            ($_.InterfaceAlias -eq $card.NetworkCardName) -and
            ($_.NetworkCategory -ne $card.NetworkCategory) 
        }
    ) {    
        Set-NetConnectionProfile -InterfaceIndex $profile.InterfaceIndex -NetworkCategory $card.NetworkCategory
        Write-Output "Changed network connection profile on card '$($card.NetworkCardName)' from '$($profile.NetworkCategory)' to '$($card.NetworkCategory)'"
    }
}
#endregion