#!/usr/bin/env node
/**
 * daily_briefing.mjs
 *
 * Builds a short daily training briefing (Telegram-ready) from Intervals planned events.
 * - Reads API key using repo conventions (see MVP_HOSTED_PLAN.md)
 * - Fetches planned events for today (local TZ America/Sao_Paulo)
 * - Prints a concise message
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const TZ = 'America/Sao_Paulo';
const ATHLETE_ID = process.env.INTERVALS_ATHLETE_ID || '0';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..');

function exists(p) {
  try { fs.accessSync(p, fs.constants.F_OK); return true; } catch { return false; }
}

function readTextTrim(p) {
  return fs.readFileSync(p, 'utf8').trim();
}

function getApiKey() {
  if (process.env.INTERVALS_API_KEY) return process.env.INTERVALS_API_KEY.trim();

  const repoKeyPath = path.join(repoRoot, 'api_key.txt');
  if (exists(repoKeyPath)) return readTextTrim(repoKeyPath);

  const localKeyPath = path.join(os.homedir(), '.intervals', 'api_key.txt');
  if (exists(localKeyPath)) return readTextTrim(localKeyPath);

  return null;
}

function basicAuthHeader(apiKey) {
  const token = Buffer.from(`API_KEY:${apiKey}`, 'utf8').toString('base64');
  return `Basic ${token}`;
}

function parts(date = new Date()) {
  const dtf = new Intl.DateTimeFormat('en-CA', {
    timeZone: TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
  const p = Object.fromEntries(dtf.formatToParts(date).map(x => [x.type, x.value]));
  return { yyyy: p.year, mm: p.month, dd: p.day, HH: p.hour, MM: p.minute };
}

function ymd(date = new Date()) {
  const { yyyy, mm, dd } = parts(date);
  return `${yyyy}-${mm}-${dd}`;
}

function ymdTomorrow() {
  const d = new Date();
  d.setDate(d.getDate() + 1);
  return ymd(d);
}

function hhmmFromISO(isoLocal) {
  // isoLocal like 2026-02-12T07:00:00
  const m = String(isoLocal || '').match(/T(\d\d):(\d\d):/);
  return m ? `${m[1]}:${m[2]}` : null;
}

function pickRules(desc) {
  if (!desc) return [];
  const lines = desc.split(/\r?\n/).map(s => s.trim()).filter(Boolean);

  const rules = [];
  for (let i = 0; i < lines.length; i++) {
    const ln = lines[i];
    const isRuleHeader = /^Regra/i.test(ln) || /joelho/i.test(ln) || /sono/i.test(ln);
    if (!isRuleHeader) continue;

    // Include the header line.
    rules.push(ln);

    // If it's a header like "Regra do joelho:", also include up to 2 following bullet-ish lines.
    if (/:$/.test(ln)) {
      for (let j = i + 1; j < lines.length && j <= i + 2; j++) {
        const next = lines[j];
        if (/^[-•]/.test(next) || /dor|run\/walk|encerrar|reduzir/i.test(next)) {
          rules.push(next.replace(/^[-•]\s*/, ''));
        }
      }
    }

    if (rules.length >= 3) break; // keep it short
  }

  // Deduplicate while preserving order.
  return [...new Set(rules)].slice(0, 3);
}

function loadWeeklyDecisions(maxItems = 3) {
  // Reads memory/DECISOES_SEMANAIS.md and returns up to maxItems unchecked decisions.
  const p = path.join(repoRoot, 'memory', 'DECISOES_SEMANAIS.md');
  if (!exists(p)) return [];

  const text = fs.readFileSync(p, 'utf8');
  const out = [];

  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line.startsWith('- [ ]')) continue;

    // Keep the main bullet line only; ignore sub-bullets.
    const cleaned = line.replace(/^- \[ \]\s*/, '').trim();
    if (!cleaned) continue;
    // Ignore the explanatory template checkbox in the header.
    if (/^pendente\s*\//i.test(cleaned)) continue;
    out.push(cleaned);
    if (out.length >= maxItems) break;
  }

  return out;
}

const FETCH_TIMEOUT_MS = Number(process.env.BRIEFING_FETCH_TIMEOUT_MS || '12000');

async function fetchWithTimeout(url, options = {}, timeoutMs = FETCH_TIMEOUT_MS) {
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, { ...options, signal: controller.signal });
    return res;
  } finally {
    clearTimeout(t);
  }
}

async function fetchJson(url, headers, timeoutMs = FETCH_TIMEOUT_MS) {
  const res = await fetchWithTimeout(url, { headers }, timeoutMs);
  if (!res.ok) {
    const txt = await res.text().catch(() => '');
    throw new Error(`HTTP ${res.status} ${res.statusText} - ${txt.slice(0, 200)}`);
  }
  return res.json();
}

async function fetchWeatherNow(location) {
  // No API key. Uses wttr.in JSON to infer rain.
  // location examples: "Taubate", "Sao+Jose+dos+Campos", "Sao+Paulo".
  const loc = encodeURIComponent(location || 'Taubate');
  const url = `https://wttr.in/${loc}?format=j1`;
  const res = await fetchWithTimeout(
    url,
    { headers: { 'User-Agent': 'OpenClaw CoachTri daily_briefing' } },
    Math.min(8000, FETCH_TIMEOUT_MS)
  );
  if (!res.ok) return null;
  const data = await res.json().catch(() => null);
  if (!data || !data.current_condition || !data.current_condition[0]) return null;

  const cur = data.current_condition[0];
  const tempC = cur.temp_C != null ? Number(cur.temp_C) : null;
  const desc = (cur.weatherDesc && cur.weatherDesc[0] && cur.weatherDesc[0].value) ? String(cur.weatherDesc[0].value) : null;
  const precipMM = cur.precipMM != null ? Number(cur.precipMM) : 0;

  // "chanceofrain" lives in weather[0].hourly[]; use the max for current day as a proxy.
  let chanceRain = null;
  try {
    const hourly = (data.weather && data.weather[0] && data.weather[0].hourly) ? data.weather[0].hourly : [];
    const vals = hourly
      .map(h => h.chanceofrain)
      .map(v => (v == null ? null : Number(v)))
      .filter(v => Number.isFinite(v));
    if (vals.length) chanceRain = Math.max(...vals);
  } catch {
    chanceRain = null;
  }

  const isRaining = precipMM > 0;

  return {
    location: location || 'Taubate',
    tempC,
    desc,
    isRaining,
    precipMM,
    chanceRain,
  };
}

async function main() {
  const apiKey = getApiKey();
  if (!apiKey) {
    console.log('Briefing diário: não achei INTERVALS_API_KEY (env) nem api_key.txt nem ~/.intervals/api_key.txt.');
    return;
  }

  const today = ymd();
  const headers = { Authorization: basicAuthHeader(apiKey) };

  // Intervals events API treats `newest` as inclusive (whole day). To fetch *only* today,
  // set newest=today (not tomorrow), otherwise it will include tomorrow's events.
  const eventsUrl = `https://intervals.icu/api/v1/athlete/${encodeURIComponent(ATHLETE_ID)}/events?oldest=${today}&newest=${today}`;
  const events = await fetchJson(eventsUrl, headers);

  // Optional: wellness (sleep/HRV/RHR) for today.
  let wellness = null;
  try {
    const wellnessUrl = `https://intervals.icu/api/v1/athlete/${encodeURIComponent(ATHLETE_ID)}/wellness?oldest=${today}&newest=${today}`;
    const w = await fetchJson(wellnessUrl, headers);
    if (Array.isArray(w) && w.length) wellness = w[0];
  } catch {
    wellness = null;
  }

  if (!Array.isArray(events) || events.length === 0) {
    console.log(`Briefing diário (${today}): nenhum treino planejado encontrado no Intervals.`);
    return;
  }

  // Sort by local start
  events.sort((a, b) => String(a.start_date_local).localeCompare(String(b.start_date_local)));

  const lines = [];

  // Recovery header (if available)
  if (wellness && (wellness.sleepSecs != null || wellness.hrv != null || wellness.restingHR != null)) {
    const sleepH = wellness.sleepSecs != null ? (wellness.sleepSecs / 3600) : null;
    const sleepStr = sleepH != null ? `${sleepH.toFixed(1)}h` : 'n/a';
    const sleepScoreStr = wellness.sleepScore != null ? String(wellness.sleepScore) : 'n/a';
    const hrvStr = wellness.hrv != null ? String(wellness.hrv) : 'n/a';
    const rhrStr = wellness.restingHR != null ? String(wellness.restingHR) : 'n/a';

    const ctl = (wellness.ctl != null && Number.isFinite(Number(wellness.ctl))) ? Number(wellness.ctl) : null;
    const atl = (wellness.atl != null && Number.isFinite(Number(wellness.atl))) ? Number(wellness.atl) : null;
    const tsbRaw = (wellness.tsb != null && Number.isFinite(Number(wellness.tsb))) ? Number(wellness.tsb) : null;
    const tsbEst = (tsbRaw != null) ? tsbRaw : (ctl != null && atl != null ? (ctl - atl) : null);
    const tsbStr = (tsbEst != null && Number.isFinite(tsbEst)) ? tsbEst.toFixed(1) : 'n/a';

    // Simple traffic-light heuristic (conservative)
    let flag = '🟢';
    if ((sleepH != null && sleepH < 6.0) || (sleepScoreStr !== 'n/a' && Number(sleepScoreStr) < 70) || (hrvStr !== 'n/a' && Number(hrvStr) < 42) || (rhrStr !== 'n/a' && Number(rhrStr) > 52)) {
      flag = '🟡';
    }
    if ((sleepH != null && sleepH < 5.5) || (sleepScoreStr !== 'n/a' && Number(sleepScoreStr) < 60) || (hrvStr !== 'n/a' && Number(hrvStr) < 38) || (rhrStr !== 'n/a' && Number(rhrStr) > 55)) {
      flag = '🔴';
    }

    lines.push(`Recuperação (hoje): sono ${sleepStr} · sleepScore ${sleepScoreStr} · HRV ${hrvStr} · FCrep ${rhrStr} · TSB(est) ${tsbStr} ${flag}`);
  } else {
    lines.push('Recuperação (hoje): dados de sono/HRV/FC repouso ainda não sincronizaram no Intervals.');
  }

  // Weather (best-effort) — helps outdoor sessions.
  // Default is Taubaté; override with WEATHER_LOCATION env var.
  try {
    const loc = process.env.WEATHER_LOCATION || 'Taubate';
    const wx = await fetchWeatherNow(loc);
    if (wx) {
      const temp = (wx.tempC != null && Number.isFinite(wx.tempC)) ? `${wx.tempC}°C` : 'n/a';
      const rainNow = wx.isRaining ? 'sim' : 'não';
      const chance = (wx.chanceRain != null && Number.isFinite(wx.chanceRain)) ? `${wx.chanceRain}%` : 'n/a';
      const desc = wx.desc ? ` (${wx.desc})` : '';
      lines.push(`Clima (agora): ${temp}${desc} · chovendo: ${rainNow} · chance chuva (hoje): ${chance}`);
    }
  } catch {
    // ignore
  }

  lines.push(`Treinos de hoje (${today}) no Intervals (${events.length}):`);

  for (const e of events) {
    const time = hhmmFromISO(e.start_date_local) || '??:??';
    const type = e.type || 'Workout';
    const name = e.name || '(sem nome)';
    const rules = pickRules(e.description);

    lines.push(`- ${time} · ${type} — ${name}`);
    for (const r of rules) lines.push(`  • ${r}`);
  }

  const decisions = loadWeeklyDecisions(3);
  if (decisions.length) {
    lines.push('');
    lines.push('Decisões da semana (pendentes):');
    for (const d of decisions) lines.push(`- ${d}`);
  }

  console.log(lines.join('\n'));
}

main().catch(err => {
  console.error('Briefing diário: erro ao consultar Intervals:', err?.message || err);
  process.exitCode = 1;
});
