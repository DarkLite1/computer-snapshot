Param (
    [String]$TimeZone = 'Romance Standard Time', # Brussels
    [Int]$RegionGeoId = 21, # Belgium
    [String]$Culture = 'nl-BE'
)

Set-WinSystemLocale -SystemLocale $Culture
Write-Output "Regional format set to '$Culture'"

Set-TimeZone -Id $TimeZone
Write-Output "Time zone set to '$TimeZone'"

Set-WinHomeLocation -GeoId $RegionGeoId
Write-Output "Country or region set to GeoId '$RegionGeoId'"

Set-Culture $Culture
Write-Output "Region format set to '$Culture'"

Write-Output 'Changes take effect after the computer is restarted'