# upload_training.ps1 - Intervals.icu Calendar Events (bulk upsert)

param(
  [string]$IntervalsApiKey = "",
  [string]$ApiKeyPath = "$PSScriptRoot\api_key.txt",
  [string]$TrainingsFile = "trainings.json",
  [string]$StartTimeLocal = "",
  [switch]$WriteBackNormalized
)

$logPath = Join-Path $PSScriptRoot "upload_training.log.jsonl"

function Write-Log {
  param(
    [string]$Level,
    [string]$Message,
    [hashtable]$Data
  )

  $entry = [ordered]@{
    timestamp = (Get-Date).ToString("s")
    level     = $Level
    message   = $Message
    data      = $Data
  }

  ($entry | ConvertTo-Json -Depth 6 -Compress) | Add-Content -Path $logPath -Encoding UTF8
}

function Resolve-ApiKey {
  param(
    [string]$ProvidedKey,
    [string]$Path
  )

  if ($ProvidedKey) { return $ProvidedKey }
  if ($env:INTERVALS_API_KEY) { return $env:INTERVALS_API_KEY }
  if (Test-Path $Path) { return (Get-Content $Path -Raw).Trim() }
  $localPath = $null
  if ($env:USERPROFILE) { $localPath = Join-Path $env:USERPROFILE ".intervals\\api_key.txt" }
  elseif ($env:HOME) { $localPath = Join-Path $env:HOME ".intervals\\api_key.txt" }
  if ($localPath -and (Test-Path $localPath)) { return (Get-Content $localPath -Raw).Trim() }
  return ""
}

function Normalize-Description {
  param(
    [string]$Description,
    [string]$Type
  )

  if (-not $Description) { return "" }
  $normalized = ($Description -replace "`r`n", "`n").Trim()
  $lines = $normalized -split "`n"
  $output = @()

  foreach ($line in $lines) {
    $current = $line.TrimEnd()

    if ($Type -eq "Swim") {
      if ($current -match "^\s*-\s") {
        $current = $current -replace "(\d+)\s+meters", '$1meters'
        if ($current -match "\bmeters\b" -and $current -notmatch "\bpace\b") {
          $current = $current.TrimEnd() + " pace"
        }
        $current = $current -replace "\bPace\b", "pace"
      }
    } else {
      if ($current -match "^\s*-\s") {
        $current = $current -replace "\s+in\s+", " "
      }
      $current = $current -replace "\bPace\b", "pace"
    }

    $output += $current
  }

  return ($output -join "`n").Trim()
}

function Validate-Event {
  param(
    [hashtable]$Event
  )

  $errors = @()
  $warnings = @()

  $required = @("external_id", "category", "start_date_local", "type", "name", "description")
  foreach ($field in $required) {
    if (-not $Event.ContainsKey($field) -or [string]::IsNullOrWhiteSpace([string]$Event[$field])) {
      $errors += "Campo obrigatorio ausente: $field"
    }
  }

  $validTypes = @("Ride", "Run", "Swim", "WeightTraining")
  if ($Event.type -and ($validTypes -notcontains $Event.type)) {
    $errors += "Tipo invalido: $($Event.type)"
  }

  if ($Event.start_date_local) {
    try { [void][DateTime]::Parse($Event.start_date_local) }
    catch { $errors += "start_date_local invalido: $($Event.start_date_local)" }
  }

  if ($Event.type -eq "Swim") {
    if ($Event.description -match "\b\d+m\b") {
      $errors += "Natacao com 'm' detectado (minutos). Use 'meters'."
    }
    if ($Event.description -notmatch "\d+meters") {
      $warnings += "Natacao sem 'meters' encontrado no texto."
    }
    if ($Event.description -notmatch "\bpace\b") {
      $warnings += "Natacao sem 'pace' encontrado no texto."
    }
  }

  return @{
    Errors = $errors
    Warnings = $warnings
  }
}

function Apply-StartTime {
  param(
    [string]$StartDateLocal,
    [string]$StartTime
  )

  if ([string]::IsNullOrWhiteSpace($StartTime)) { return $StartDateLocal }
  try {
    $date = [DateTime]::Parse($StartDateLocal)
    $time = [TimeSpan]::Parse($StartTime)
    return (Get-Date ($date.Date + $time) -Format "yyyy-MM-ddTHH:mm:ss")
  } catch {
    return $StartDateLocal
  }
}

$IntervalsApiKey = Resolve-ApiKey -ProvidedKey $IntervalsApiKey -Path $ApiKeyPath
if (-not $IntervalsApiKey) {
  Write-Host "API key not provided."
  Write-Log -Level "error" -Message "API key missing" -Data @{ file = $ApiKeyPath }
  exit 1
}

if (-not (Test-Path $TrainingsFile)) {
  Write-Host "Arquivo trainings.json nao encontrado."
  Write-Log -Level "error" -Message "Arquivo nao encontrado" -Data @{ file = $TrainingsFile }
  exit 1
}

$pair   = "API_KEY:$IntervalsApiKey"
$base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
$headers = @{
  Authorization = "Basic $base64"
  Accept        = "application/json"
  "Content-Type"= "application/json"
}

$uri = "https://intervals.icu/api/v1/athlete/0/events/bulk?upsert=true"

$rawEvents = Get-Content $TrainingsFile -Raw | ConvertFrom-Json
$events = @($rawEvents)

$normalizedEvents = @()
$hasChanges = $false
$allErrors = @()

foreach ($event in $events) {
  $eventHash = @{}
  $event.PSObject.Properties | ForEach-Object { $eventHash[$_.Name] = $_.Value }

  $eventHash.description = Normalize-Description -Description $eventHash.description -Type $eventHash.type
  $eventHash.start_date_local = Apply-StartTime -StartDateLocal $eventHash.start_date_local -StartTime $StartTimeLocal

  $validation = Validate-Event -Event $eventHash
  foreach ($warning in $validation.Warnings) {
    Write-Host "Aviso: $warning (external_id=$($eventHash.external_id))"
  }
  foreach ($error in $validation.Errors) {
    $allErrors += "$error (external_id=$($eventHash.external_id))"
  }

  if ($eventHash.description -ne $event.description -or $eventHash.start_date_local -ne $event.start_date_local) {
    $hasChanges = $true
  }

  $normalizedEvents += [PSCustomObject]$eventHash
}

if ($allErrors.Count -gt 0) {
  $allErrors | ForEach-Object { Write-Host "Erro: $_" }
  Write-Log -Level "error" -Message "Validacao falhou" -Data @{ errors = $allErrors }
  exit 1
}

if ($WriteBackNormalized -and $hasChanges) {
  $normalizedEvents | ConvertTo-Json -Depth 12 | Out-File -FilePath $TrainingsFile -Encoding UTF8
  Write-Host "trainings.json normalizado e regravado."
  Write-Log -Level "info" -Message "Arquivo normalizado" -Data @{ file = $TrainingsFile }
}

try {
  $body = ($normalizedEvents | ConvertTo-Json -Depth 12)
  if ($body.TrimStart().StartsWith("{")) { $body = "[$body]" }
  $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
  Write-Host "Upload OK. Eventos criados/atualizados: $($resp.Count)"
  Write-Log -Level "info" -Message "Upload OK" -Data @{ count = $resp.Count; file = $TrainingsFile }
}
catch {
  Write-Host "Failed to upload trainings:"
  Write-Host $_.Exception.Message

  $errorBody = $null
  try {
    if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream()) {
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $errorBody = $reader.ReadToEnd()
      if ($errorBody) {
        Write-Host "Server response body:"
        Write-Host $errorBody
      }
    }
  } catch { }

  Write-Log -Level "error" -Message "Upload falhou" -Data @{ message = $_.Exception.Message; body = $errorBody }
  exit 1
}
