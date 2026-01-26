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

function Html-Escape {
  param([string]$Text)
  if ($null -eq $Text) { return "" }
  return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Get-WellnessForDate {
  param(
    [object[]]$Wellness,
    [string]$Date
  )

  if (-not $Date) { return $null }
  return $Wellness | Where-Object { $_.data -eq $Date } | Select-Object -First 1
}

function Classify-Quality {
  param(
    [object]$Plan
  )

  if (-not $Plan) {
    return @{ label = "Sem plano"; level = "neutral" }
  }

  $dt = $Plan.delta_time_min
  $dd = $Plan.delta_distance_km
  $dtAbs = if ($dt -ne $null) { [math]::Abs([double]$dt) } else { $null }
  $ddAbs = if ($dd -ne $null) { [math]::Abs([double]$dd) } else { $null }

  if (($dtAbs -ne $null -and $dtAbs -le 5) -or ($ddAbs -ne $null -and $ddAbs -le 1)) {
    return @{ label = "No alvo"; level = "good" }
  }

  if ($dt -ne $null -and $dt -gt 5) {
    return @{ label = "Acima"; level = "warn" }
  }

  if ($dt -ne $null -and $dt -lt -5) {
    return @{ label = "Abaixo"; level = "bad" }
  }

  return @{ label = "Parcial"; level = "neutral" }
}

function Build-Insight {
  param(
    [object]$Activity,
    [object]$WellnessDay,
    [double]$AvgSleep,
    [double]$AvgHrv,
    [double]$AvgRhr
  )

  $notes = @()

  if ($WellnessDay) {
    if ($WellnessDay.sono_h -lt 6.5) { $notes += "Sono baixo pode elevar FC e reduzir qualidade." }
    elseif ($WellnessDay.sono_h -ge 7.5) { $notes += "Sono bom favorece execução." }

    if ($WellnessDay.hrv -lt ($AvgHrv - 3)) { $notes += "HRV abaixo da média: atenção a fadiga." }
    if ($WellnessDay.fc_reposo -gt ($AvgRhr + 3)) { $notes += "FC repouso acima da média: sinal de stress." }
  }

  if ($Activity.type -eq "Run" -and $Activity.notas -match "joelho") {
    $notes += "Joelho citado: manter volume protegido."
  }

  if ($notes.Count -eq 0) { return "Execução sem alertas claros." }
  return ($notes -join " ")
}

function Build-ReportHtml {
  param(
    [string]$ReportPath,
    [string]$OutputPath
  )

  $report = Get-Content $ReportPath -Raw | ConvertFrom-Json
  $range = "$($report.semana.inicio) a $($report.semana.fim)"

  $activities = @($report.atividades)
  $wellness = @($report.bem_estar)
  $planned = @()
  if ($report.PSObject.Properties.Name -contains "treinos_planejados") {
    $planned = @($report.treinos_planejados)
  }

  $totalTime = $report.semana.tempo_total_horas
  $totalDist = $report.semana.distancia_total_km
  $totalTss = $report.semana.carga_total_tss
  $ctl = $report.metricas.CTL
  $atl = $report.metricas.ATL
  $tsb = $report.metricas.TSB
  $ramp = $report.metricas.RampRate
  $peso = $report.metricas.peso_atual

  $distGroups = $activities | Group-Object type | ForEach-Object {
    $timeMin = ($_.Group | Measure-Object moving_time_min -Sum).Sum
    $distKm = ($_.Group | Measure-Object distance_km -Sum).Sum
    [PSCustomObject]@{
      type = $_.Name
      time_h = if ($timeMin) { [math]::Round($timeMin / 60, 2) } else { 0 }
      dist_km = if ($distKm) { [math]::Round($distKm, 1) } else { 0 }
    }
  } | Sort-Object type

  $distLabels = @($distGroups | ForEach-Object { $_.type })
  $distValues = @($distGroups | ForEach-Object { $_.time_h })

  $wellDates = @($wellness | ForEach-Object { $_.data })
  $ctlVals = @($wellness | ForEach-Object { $_.ctl })
  $atlVals = @($wellness | ForEach-Object { $_.atl })
  $sleepVals = @($wellness | ForEach-Object { $_.sono_h })
  $hrvVals = @($wellness | ForEach-Object { $_.hrv })
  $rhrVals = @($wellness | ForEach-Object { $_.fc_reposo })

  $avgSleep = if ($wellness.Count -gt 0) { [math]::Round((($wellness | Measure-Object sono_h -Average).Average), 2) } else { 0 }
  $avgHrv = if ($wellness.Count -gt 0) { [math]::Round((($wellness | Measure-Object hrv -Average).Average), 1) } else { 0 }
  $avgRhr = if ($wellness.Count -gt 0) { [math]::Round((($wellness | Measure-Object fc_reposo -Average).Average), 1) } else { 0 }

  $notesWeek = @()
  if ($report.PSObject.Properties.Name -contains "notas_semana") {
    $notesWeek = @($report.notas_semana)
  }

  $activityRows = @()
  $activityCards = @()
  foreach ($a in ($activities | Sort-Object start_date_local)) {
    $plan = $a.planejado
    $planText = "Sem planejado"
    if ($plan) {
      $pt = if ($plan.moving_time_min -ne $null) { "$($plan.moving_time_min) min" } else { "n/a" }
      $pd = if ($plan.distance_km -ne $null) { "$($plan.distance_km) km" } else { "n/a" }
      $dt = if ($plan.delta_time_min -ne $null) { "$($plan.delta_time_min) min" } else { "n/a" }
      $dd = if ($plan.delta_distance_km -ne $null) { "$($plan.delta_distance_km) km" } else { "n/a" }
      $planText = "Plan: $pt | $pd | delta $dt | delta $dd"
    }

    $notes = ""
    if ($a.notas) { $notes = $a.notas }

    $wellDay = Get-WellnessForDate -Wellness $wellness -Date $a.start_date_local
    $sleepText = if ($wellDay) { "$($wellDay.sono_h)h" } else { "n/a" }
    $hrvText = if ($wellDay) { "$($wellDay.hrv)" } else { "n/a" }
    $rhrText = if ($wellDay) { "$($wellDay.fc_reposo)" } else { "n/a" }
    $quality = Classify-Quality -Plan $plan
    $insight = Build-Insight -Activity $a -WellnessDay $wellDay -AvgSleep $avgSleep -AvgHrv $avgHrv -AvgRhr $avgRhr

    $activityCards += @"
<div class=""activity-card"">
  <div class=""activity-head"">
    <div>
      <div class=""activity-name"">$(Html-Escape $a.name)</div>
      <div class=""activity-date"">$(Html-Escape $a.start_date_local) · $(Html-Escape $a.type)</div>
    </div>
    <span class=""badge badge-$($quality.level)"">$($quality.label)</span>
  </div>
  <div class=""chips"">
    <span class=""chip"">Tempo: $($a.moving_time_min) min</span>
    <span class=""chip"">Dist: $($a.distance_km) km</span>
    <span class=""chip"">Sono: $sleepText</span>
    <span class=""chip"">HRV: $hrvText</span>
    <span class=""chip"">FC Rep: $rhrText</span>
  </div>
  <div class=""activity-plan"">$(Html-Escape $planText)</div>
  <div class=""activity-insight"">$(Html-Escape $insight)</div>
  <div class=""activity-notes"">$(Html-Escape $notes)</div>
</div>
"@

    $activityRows += @"
<tr>
  <td>$(Html-Escape $a.start_date_local)</td>
  <td>$(Html-Escape $a.type)</td>
  <td>$(Html-Escape $a.name)</td>
  <td>$($a.moving_time_min) min</td>
  <td>$($a.distance_km) km</td>
  <td>$(Html-Escape $planText)</td>
  <td>$(Html-Escape $notes)</td>
</tr>
"@
  }

  $notesBlock = ""
  if ($notesWeek.Count -gt 0) {
    $lines = @()
    foreach ($n in $notesWeek) {
      $lines += "<div class=""note-item""><strong>$(Html-Escape $n.name)</strong><div>$(Html-Escape $n.description)</div></div>"
    }
    $notesHtml = $lines -join ""
    $notesBlock = "<section class=""card notes""><h2>Notas da Semana</h2>$notesHtml</section>"
  }

  $html = @()
  $html += "<!doctype html>"
  $html += "<html lang=""pt-BR"">"
  $html += "<head>"
  $html += "  <meta charset=""utf-8"">"
  $html += "  <meta name=""viewport"" content=""width=device-width, initial-scale=1"">"
  $html += "  <title>Relatorio Semanal - $range</title>"
  $html += "  <script src=""https://cdn.jsdelivr.net/npm/chart.js""></script>"
  $html += "  <link href=""https://fonts.googleapis.com/css2?family=Sora:wght@300;400;600;700&display=swap"" rel=""stylesheet"">"
  $html += "  <style>"
  $html += "    :root { --bg:#f6f7fb; --ink:#0f172a; --muted:#64748b; --card:#ffffff; --accent:#0ea5e9; --accent2:#10b981; --accent3:#f59e0b; }"
  $html += "    *{box-sizing:border-box} body{margin:0;font-family:'Sora',sans-serif;background:var(--bg);color:var(--ink)}"
  $html += "    .wrap{max-width:1200px;margin:24px auto;padding:0 20px}"
  $html += "    header{background:linear-gradient(135deg,#0ea5e9,#22c55e);color:white;padding:24px;border-radius:18px}"
  $html += "    header h1{margin:0 0 6px 0;font-size:24px} header p{margin:0;opacity:.9}"
  $html += "    .grid{display:grid;gap:16px} .grid-4{grid-template-columns:repeat(auto-fit,minmax(200px,1fr))}"
  $html += "    .card{background:var(--card);border-radius:14px;padding:16px;box-shadow:0 6px 20px rgba(15,23,42,0.08)}"
  $html += "    .kpi{font-size:26px;font-weight:700} .label{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.08em}"
  $html += "    .section{margin-top:18px} .section h2{margin:0 0 10px 0;font-size:18px}"
  $html += "    .charts{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}"
  $html += "    table{width:100%;border-collapse:collapse;font-size:12px} th,td{padding:8px;border-bottom:1px solid #e2e8f0;text-align:left}"
  $html += "    th{color:var(--muted);font-weight:600} .note-item{padding:8px 0;border-bottom:1px dashed #e2e8f0}"
  $html += "    .activity-card{border:1px solid #e2e8f0;border-radius:12px;padding:12px;margin-top:10px;background:#fff}"
  $html += "    .activity-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}"
  $html += "    .activity-name{font-weight:600} .activity-date{color:var(--muted);font-size:12px}"
  $html += "    .chips{display:flex;flex-wrap:wrap;gap:8px;margin:8px 0}"
  $html += "    .chip{background:#f1f5f9;border-radius:999px;padding:4px 10px;font-size:11px;color:#334155}"
  $html += "    .badge{padding:4px 10px;border-radius:999px;font-size:11px;font-weight:600}"
  $html += "    .badge-good{background:#dcfce7;color:#166534}"
  $html += "    .badge-warn{background:#fef3c7;color:#92400e}"
  $html += "    .badge-bad{background:#fee2e2;color:#991b1b}"
  $html += "    .badge-neutral{background:#e2e8f0;color:#334155}"
  $html += "    .activity-plan{font-size:12px;color:#475569;margin-bottom:6px}"
  $html += "    .activity-insight{font-size:12px;color:#0f172a;background:#f8fafc;border-left:3px solid #0ea5e9;padding:6px 8px;border-radius:6px}"
  $html += "    .activity-notes{font-size:12px;color:#64748b;margin-top:6px}"
  $html += "  </style>"
  $html += "</head>"
  $html += "<body>"
  $html += "<div class=""wrap"">"
  $html += "<header><h1>Relatorio Semanal</h1><p>$range</p></header>"
  $html += "<div class=""grid grid-4 section"">"
  $html += "<div class=""card""><div class=""label"">Tempo total</div><div class=""kpi"">$totalTime h</div></div>"
  $html += "<div class=""card""><div class=""label"">Distancia</div><div class=""kpi"">$totalDist km</div></div>"
  $html += "<div class=""card""><div class=""label"">Carga</div><div class=""kpi"">$totalTss</div></div>"
  $html += "<div class=""card""><div class=""label"">TSB</div><div class=""kpi"">$tsb</div></div>"
  $html += "</div>"
  $html += "<div class=""grid grid-4 section"">"
  $html += "<div class=""card""><div class=""label"">CTL</div><div class=""kpi"">$ctl</div></div>"
  $html += "<div class=""card""><div class=""label"">ATL</div><div class=""kpi"">$atl</div></div>"
  $html += "<div class=""card""><div class=""label"">RampRate</div><div class=""kpi"">$ramp</div></div>"
  $html += "<div class=""card""><div class=""label"">Peso</div><div class=""kpi"">$peso</div></div>"
  $html += "</div>"
  $html += "<div class=""section charts"">"
  $html += "  <div class=""card""><h2>Distribuicao por modalidade</h2><canvas id=""dist-chart""></canvas></div>"
  $html += "  <div class=""card""><h2>CTL / ATL</h2><canvas id=""pmc-chart""></canvas></div>"
  $html += "  <div class=""card""><h2>Bem-estar diario</h2><canvas id=""well-chart""></canvas></div>"
  $html += "</div>"
  if ($notesBlock) { $html += $notesBlock }
  if ($activityCards.Count -gt 0) {
    $html += "<section class=""card section""><h2>Qualidade por Sessao (planejado vs executado + wellness)</h2>"
    $html += ($activityCards -join "`n")
    $html += "</section>"
  }
  $html += "<section class=""card section""><h2>Atividades (planejado vs executado)</h2>"
  $html += "<table><thead><tr><th>Data</th><th>Tipo</th><th>Nome</th><th>Tempo</th><th>Distancia</th><th>Planejado</th><th>Notas</th></tr></thead><tbody>"
  $html += ($activityRows -join "`n")
  $html += "</tbody></table></section>"
  $html += "</div>"
  $html += "<script>"
  $html += "const distCtx = document.getElementById('dist-chart');"
  $html += "new Chart(distCtx,{type:'doughnut',data:{labels:$([string](ConvertTo-Json $distLabels -Compress)),datasets:[{data:$([string](ConvertTo-Json $distValues -Compress)),backgroundColor:['#0ea5e9','#10b981','#f59e0b','#6366f1','#ef4444']}]},options:{plugins:{legend:{position:'bottom'}},cutout:'60%'}});"
  $html += "const pmcCtx = document.getElementById('pmc-chart');"
  $html += "new Chart(pmcCtx,{type:'line',data:{labels:$([string](ConvertTo-Json $wellDates -Compress)),datasets:[{label:'CTL',data:$([string](ConvertTo-Json $ctlVals -Compress)),borderColor:'#0ea5e9',tension:.3},{label:'ATL',data:$([string](ConvertTo-Json $atlVals -Compress)),borderColor:'#f59e0b',tension:.3}]},options:{plugins:{legend:{position:'bottom'}},scales:{x:{display:false}}}});"
  $html += "const wellCtx = document.getElementById('well-chart');"
  $html += "new Chart(wellCtx,{type:'line',data:{labels:$([string](ConvertTo-Json $wellDates -Compress)),datasets:[{label:'Sono (h)',data:$([string](ConvertTo-Json $sleepVals -Compress)),borderColor:'#10b981',tension:.3},{label:'HRV',data:$([string](ConvertTo-Json $hrvVals -Compress)),borderColor:'#6366f1',tension:.3},{label:'FC Repouso',data:$([string](ConvertTo-Json $rhrVals -Compress)),borderColor:'#ef4444',tension:.3}]},options:{plugins:{legend:{position:'bottom'}},scales:{x:{display:false}}}});"
  $html += "</script>"
  $html += "</body></html>"

  Set-Content -Path $OutputPath -Value $html -Encoding UTF8
}

foreach ($report in $reportFiles) {
  $outputName = $report.Name -replace "\.json$", ".html"
  $outputPath = Join-Path $siteReports $outputName
  Build-ReportHtml -ReportPath $report.FullName -OutputPath $outputPath
}

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
  $htmlName = ($file.Name -replace "\.json$", ".html")
  $lines += "        <li><a href=`"reports/$htmlName`">$htmlName</a> | <a href=`"reports/$name`">json</a></li>"
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

