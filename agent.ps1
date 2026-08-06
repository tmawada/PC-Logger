param(
    [ValidateSet("Boot","Shutdown","Restart")]
    [string]$EventType
)

$hostname = $env:COMPUTERNAME

switch ($EventType) {

    "Boot" {

        $event = Get-WinEvent -FilterHashtable @{
            LogName='System'
            ProviderName='Microsoft-Windows-Kernel-General'
            Id=12
        } -MaxEvents 1

    }

    "Shutdown" {

        $event = Get-WinEvent -FilterHashtable @{
            LogName='System'
            ProviderName='User32'
            Id=1074
        } -MaxEvents 1

    }

    "Restart" {

        $event = Get-WinEvent -FilterHashtable @{
            LogName='System'
            ProviderName='User32'
            Id=1074
        } -MaxEvents 1

        # Pastikan ini benar-benar restart
        if ($event.Message -notmatch "restart") {
            Write-Host "Latest User32 1074 is not a restart."
            exit
        }

    }

}

if ($null -eq $event) {
    Write-Host "No event found."
    exit
}

$payload = @{
    hostname    = $hostname
    type        = $EventType
    message     = $event.Message
    timecreated = $event.TimeCreated.ToString("o")
}

$payload | ConvertTo-Json