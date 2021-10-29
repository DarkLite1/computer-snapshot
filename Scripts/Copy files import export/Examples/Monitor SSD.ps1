$physicalDisks = Get-PhysicalDisk

Foreach ($disk in $physicalDisks) {
    $reliabilityCounter = $disk | Get-StorageReliabilityCounter

    [PSCustomObject]@{
        Model                  = $disk.Model
        Size                   = $disk.Size / 1GB
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