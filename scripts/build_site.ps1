param(
  [string]$ReportsDir,
  [string]$SiteDir
)

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ReportsDir) { $ReportsDir = Join-Path $repoRoot "Relatorios_Intervals" }
if (-not $SiteDir) { $SiteDir = Join-Path $repoRoot "docs" }

if (-not (Test-Path $ReportsDir)) {
  Write-Host "Reports directory not found: $ReportsDir"
  exit 1
}

$siteReports = Join-Path $SiteDir "reports"
New-Item -ItemType Directory -Path $siteReports -Force | Out-Null

Copy-Item -Path (Join-Path $ReportsDir "*.json") -Destination $siteReports -Force -ErrorAction SilentlyContinue
Copy-Item -Path (Join-Path $ReportsDir "*.md") -Destination $siteReports -Force -ErrorAction SilentlyContinue

$reportFiles = Get-ChildItem $ReportsDir -Filter "report_*.json" | Sort-Object Name -Descending
$plannedFiles = Get-ChildItem $ReportsDir -Filter "planned_*.md" | Sort-Object Name -Descending

$lines = @()
$lines += "<!doctype html>"
$lines += "<html lang=`"pt-BR`">"
$lines += "<head>"
$lines += "  <meta charset=`"utf-8`">"
$lines += "  <meta name=`"viewport`" content=`"width=device-width, initial-scale=1`">"
$lines += "  <title>Relatorios Intervals</title>"
$lines += "  <style>"
$lines += "    body { font-family: Arial, sans-serif; margin: 24px; color: #111; }"
$lines += "    h1 { margin-bottom: 4px; }"
$lines += "    .meta { color: #666; margin-top: 0; }"
$lines += "    ul { padding-left: 18px; }"
$lines += "    a { color: #0b63ce; text-decoration: none; }"
$lines += "    a:hover { text-decoration: underline; }"
$lines += "    section { margin-top: 24px; }"
$lines += "  </style>"
$lines += "</head>"
$lines += "<body>"
$lines += "  <main>"
$lines += "    <h1>Relatorios Intervals</h1>"
$lines += "    <p class=`"meta`">Atualizado: $(Get-Date -Format "yyyy-MM-dd HH:mm")</p>"
$lines += "    <section>"
$lines += "      <h2>Relatorios</h2>"
$lines += "      <ul>"
foreach ($file in $reportFiles) {
  $name = $file.Name
  $lines += "        <li><a href=`"reports/$name`">$name</a></li>"
}
$lines += "      </ul>"
$lines += "    </section>"
$lines += "    <section>"
$lines += "      <h2>Planejado</h2>"
$lines += "      <ul>"
foreach ($file in $plannedFiles) {
  $name = $file.Name
  $lines += "        <li><a href=`"reports/$name`">$name</a></li>"
}
$lines += "      </ul>"
$lines += "    </section>"
$lines += "  </main>"
$lines += "</body>"
$lines += "</html>"

Set-Content -Path (Join-Path $SiteDir "index.html") -Value $lines -Encoding UTF8
Set-Content -Path (Join-Path $SiteDir ".nojekyll") -Value "" -Encoding ASCII
