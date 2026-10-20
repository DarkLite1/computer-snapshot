powercfg -change -monitor-timeout-ac 0
Write-Output 'Turn of display: Never'

powercfg -change -standby-timeout-ac 0 
Write-Output 'Put computer to sleep: Never'
