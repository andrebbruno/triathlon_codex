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

  $distLabelsJson = ConvertTo-Json $distLabels -Compress
  $distValuesJson = ConvertTo-Json $distValues -Compress
  $wellDatesJson = ConvertTo-Json $wellDates -Compress
  $ctlJson = ConvertTo-Json $ctlVals -Compress
  $atlJson = ConvertTo-Json $atlVals -Compress
  $sleepJson = ConvertTo-Json $sleepVals -Compress
  $hrvJson = ConvertTo-Json $hrvVals -Compress
  $rhrJson = ConvertTo-Json $rhrVals -Compress

  function Parse-PlanTarget {
    param(
      [string]$Description,
      [string]$Type
    )

    if (-not $Description) { return $null }

    if ($Type -eq "Ride") {
      $m = [regex]::Match($Description, "(\d+)\s*-\s*(\d+)\s*W", "IgnoreCase")
      if ($m.Success) { return @{ min = [int]$m.Groups[1].Value; max = [int]$m.Groups[2].Value; unit = "W" } }
      $m2 = [regex]::Match($Description, "(\d+)\s*W", "IgnoreCase")
      if ($m2.Success) { $v = [int]$m2.Groups[1].Value; return @{ min = $v; max = $v; unit = "W" } }
    }

    if ($Type -eq "Run") {
      $m = [regex]::Match($Description, "(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})/km", "IgnoreCase")
      if ($m.Success) { return @{ min = $m.Groups[1].Value; max = $m.Groups[2].Value; unit = "pace" } }
      $m2 = [regex]::Match($Description, "(\d{1,2}:\d{2})/km", "IgnoreCase")
      if ($m2.Success) { $v = $m2.Groups[1].Value; return @{ min = $v; max = $v; unit = "pace" } }
    }

    return $null
  }

  function Pace-From-Activity {
    param(
      [double]$Minutes,
      [double]$DistanceKm
    )

    if (-not $DistanceKm -or $DistanceKm -le 0) { return $null }
    $pace = $Minutes / $DistanceKm
    $min = [math]::Floor($pace)
    $sec = [math]::Round(($pace - $min) * 60)
    if ($sec -eq 60) { $min += 1; $sec = 0 }
    return "{0}:{1:00}/km" -f $min, $sec
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

    $planTarget = Parse-PlanTarget -Description $plan.description -Type $a.type
    $actualTarget = $null
    if ($a.type -eq "Ride" -and $a.average_watts) {
      $actualTarget = "$($a.average_watts) W"
    } elseif ($a.type -eq "Run") {
      $paceActual = Pace-From-Activity -Minutes $a.moving_time_min -DistanceKm $a.distance_km
      if ($paceActual) { $actualTarget = $paceActual }
    }

    $planTargetText = "n/a"
    if ($planTarget) {
      if ($planTarget.unit -eq "W") { $planTargetText = "$($planTarget.min)-$($planTarget.max) W" }
      if ($planTarget.unit -eq "pace") { $planTargetText = "$($planTarget.min)-$($planTarget.max)" }
    }

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
  <div class=""activity-target""><strong>Alvo:</strong> $(Html-Escape $planTargetText) · <strong>Executado:</strong> $(Html-Escape $actualTarget)</div>
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

  $html = @"
<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Relatorio Semanal - $range</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=IBM+Plex+Sans:wght@300;400;600&display=swap" rel="stylesheet">
  <style>
    :root{
      --bg:#f4f3ef;
      --ink:#0f172a;
      --muted:#6b7280;
      --card:#ffffff;
      --accent:#1f8ef1;
      --accent-2:#16a34a;
      --accent-3:#f59e0b;
      --accent-4:#111827;
      --shadow:0 16px 45px rgba(15,23,42,0.12);
    }
    *{box-sizing:border-box}
    body{
      margin:0;
      font-family:"IBM Plex Sans",sans-serif;
      background:radial-gradient(circle at 20% 20%, #ffffff 0%, #f4f3ef 55%, #ede9e3 100%);
      color:var(--ink);
    }
    .wrap{max-width:1200px;margin:24px auto;padding:0 24px}
    .hero{
      background:linear-gradient(135deg,#0f172a 0%,#1f2937 100%);
      color:#f8fafc;
      padding:28px;
      border-radius:22px;
      position:relative;
      overflow:hidden;
      box-shadow:var(--shadow);
    }
    .hero:after{
      content:"";
      position:absolute;
      width:320px;height:320px;
      right:-80px;top:-140px;
      background:radial-gradient(circle,#1f8ef1 0%,rgba(31,142,241,0) 70%);
      opacity:.6;
    }
    .hero h1{font-family:"Space Grotesk",sans-serif;margin:0 0 6px 0;font-size:26px}
    .hero p{margin:0;color:#cbd5f5}
    .grid{display:grid;gap:16px}
    .grid-4{grid-template-columns:repeat(auto-fit,minmax(200px,1fr))}
    .section{margin-top:20px}
    .card{
      background:var(--card);
      border-radius:16px;
      padding:18px;
      box-shadow:var(--shadow);
    }
    .kpi{font-size:28px;font-weight:700;font-family:"Space Grotesk",sans-serif}
    .label{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.12em}
    .charts{display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(280px,1fr))}
    .note-item{padding:8px 0;border-bottom:1px dashed #e5e7eb}
    .activity-card{border:1px solid #e5e7eb;border-radius:14px;padding:14px;margin-top:12px;background:#fff}
    .activity-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}
    .activity-name{font-weight:600;font-family:"Space Grotesk",sans-serif}
    .activity-date{color:var(--muted);font-size:12px}
    .chips{display:flex;flex-wrap:wrap;gap:8px;margin:8px 0}
    .chip{background:#f8fafc;border-radius:999px;padding:4px 10px;font-size:11px;color:#334155}
    .badge{padding:4px 10px;border-radius:999px;font-size:11px;font-weight:600}
    .badge-good{background:#dcfce7;color:#166534}
    .badge-warn{background:#fef3c7;color:#92400e}
    .badge-bad{background:#fee2e2;color:#991b1b}
    .badge-neutral{background:#e2e8f0;color:#334155}
    .activity-plan{font-size:12px;color:#475569;margin-bottom:6px}
    .activity-target{font-size:12px;color:#111827;margin-bottom:6px}
    .activity-insight{font-size:12px;color:#0f172a;background:#f1f5f9;border-left:3px solid #1f8ef1;padding:8px;border-radius:8px}
    .activity-notes{font-size:12px;color:#64748b;margin-top:6px}
    table{width:100%;border-collapse:collapse;font-size:12px}
    th,td{padding:8px;border-bottom:1px solid #e5e7eb;text-align:left}
    th{color:var(--muted);font-weight:600}
  </style>
</head>
<body>
<div class="wrap">
  <div class="hero">
    <h1>Relatorio Semanal</h1>
    <p>$range</p>
  </div>

  <div class="grid grid-4 section">
    <div class="card"><div class="label">Tempo total</div><div class="kpi">$totalTime h</div></div>
    <div class="card"><div class="label">Distancia</div><div class="kpi">$totalDist km</div></div>
    <div class="card"><div class="label">Carga</div><div class="kpi">$totalTss</div></div>
    <div class="card"><div class="label">TSB</div><div class="kpi">$tsb</div></div>
  </div>
  <div class="grid grid-4 section">
    <div class="card"><div class="label">CTL</div><div class="kpi">$ctl</div></div>
    <div class="card"><div class="label">ATL</div><div class="kpi">$atl</div></div>
    <div class="card"><div class="label">RampRate</div><div class="kpi">$ramp</div></div>
    <div class="card"><div class="label">Peso</div><div class="kpi">$peso</div></div>
  </div>

  <div class="section charts">
    <div class="card"><h2>Distribuicao por modalidade</h2><canvas id="dist-chart"></canvas></div>
    <div class="card"><h2>CTL / ATL</h2><canvas id="pmc-chart"></canvas></div>
    <div class="card"><h2>Bem-estar diario</h2><canvas id="well-chart"></canvas></div>
  </div>

  $notesBlock

  <section class="card section">
    <h2>Qualidade por Sessao (planejado vs executado + wellness)</h2>
    $($activityCards -join "`n")
  </section>

  <section class="card section">
    <h2>Atividades (planejado vs executado)</h2>
    <table>
      <thead>
        <tr><th>Data</th><th>Tipo</th><th>Nome</th><th>Tempo</th><th>Distancia</th><th>Planejado</th><th>Notas</th></tr>
      </thead>
      <tbody>
        $($activityRows -join "`n")
      </tbody>
    </table>
  </section>
</div>
<script>
  new Chart(document.getElementById('dist-chart'),{
    type:'doughnut',
    data:{labels:$distLabelsJson,datasets:[{data:$distValuesJson,backgroundColor:['#1f8ef1','#16a34a','#f59e0b','#111827','#ef4444']}]},
    options:{plugins:{legend:{position:'bottom'}},cutout:'60%'}
  });
  new Chart(document.getElementById('pmc-chart'),{
    type:'line',
    data:{labels:$wellDatesJson,datasets:[
      {label:'CTL',data:$ctlJson,borderColor:'#1f8ef1',tension:.3},
      {label:'ATL',data:$atlJson,borderColor:'#f59e0b',tension:.3}
    ]},
    options:{plugins:{legend:{position:'bottom'}},scales:{x:{display:false}}}
  });
  new Chart(document.getElementById('well-chart'),{
    type:'line',
    data:{labels:$wellDatesJson,datasets:[
      {label:'Sono (h)',data:$sleepJson,borderColor:'#16a34a',tension:.3},
      {label:'HRV',data:$hrvJson,borderColor:'#1f8ef1',tension:.3},
      {label:'FC Repouso',data:$rhrJson,borderColor:'#ef4444',tension:.3}
    ]},
    options:{plugins:{legend:{position:'bottom'}},scales:{x:{display:false}}}
  });
</script>
</body>
</html>
"@

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

