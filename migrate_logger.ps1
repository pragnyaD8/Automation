class Logger {
    [string]$Component

    Logger([string]$component) {
        $this.Component = $component
    }

    [void] Log([string]$level, [string]$message) {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Write-Host "[$ts][$level][$($this.Component)] $message"
    }

    [void] Step([string]$message) { $this.Log("STEP ", $message) }
    [void] Info([string]$message) { $this.Log("INFO ", $message) }
    [void] Warn([string]$message) { $this.Log("WARN ", $message) }
    [void] Error([string]$message){ $this.Log("ERROR", $message) }
}

function New-Logger {
    param([Parameter(Mandatory)][string]$Component)
    return [Logger]::new($Component)
}
