#!/usr/bin/env node
/**
 * intervals_new_activity_poll.mjs
 *
 * Poll Intervals.icu for recently executed activities and print a short message
 * (suitable for Telegram) only when new activity IDs are detected.
 *
 * Also tracks VO2Max changes (from Intervals wellness endpoint) and emits a
 * message when the value changes.
 *
 * API key lookup order (matches MVP_HOSTED_PLAN.md):
 * 1) env INTERVALS_API_KEY
 * 2) repo root api_key.txt
 * 3) ~/.intervals/api_key.txt
 *
 * State files (gitignored):
 * - scripts/.state/intervals_new_activity_state.json
 * - scripts/.state/intervals_vo2max_state.json
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const TZ = 'America/Sao_Paulo';
const ATHLETE_ID = process.env.INTERVALS_ATHLETE_ID || '0';
const DAYS_LOOKBACK = Number(process.env.INTERVALS_LOOKBACK_DAYS || '3');
const MAX_SEEN = Number(process.env.INTERVALS_MAX_SEEN || '800');
const VO2MAX_HISTORY_DAYS = Number(process.env.INTERVALS_VO2MAX_HISTORY_DAYS || '60');

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

  const home = os.homedir();
  const localKeyPath = path.join(home, '.intervals', 'api_key.txt');
  if (exists(localKeyPath)) return readTextTrim(localKeyPath);

  return null;
}

function basicAuthHeader(apiKey) {
  // Intervals expects username "API_KEY" and password = apiKey
  const token = Buffer.from(`API_KEY:${apiKey}`, 'utf8').toString('base64');
  return `Basic ${token}`;
}

function zonedParts(date = new Date()) {
  const dtf = new Intl.DateTimeFormat('en-CA', {
    timeZone: TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
  const parts = Object.fromEntries(dtf.formatToParts(date).map(p => [p.type, p.value]));
  return {
    yyyy: parts.year,
    mm: parts.month,
    dd: parts.day,
    HH: parts.hour,
    MM: parts.minute,
  };
}

function inSendWindow(now = new Date()) {
  const { HH, MM } = zonedParts(now);
  const minutes = Number(HH) * 60 + Number(MM);
  const start = 5 * 60 + 30;  // 05:30
  const end = 21 * 60 + 30;   // 21:30
  return minutes >= start && minutes <= end;
}

function yyyyMmDdDaysAgo(daysAgo) {
  const d = new Date();
  d.setDate(d.getDate() - daysAgo);
  const { yyyy, mm, dd } = zonedParts(d);
  return `${yyyy}-${mm}-${dd}`;
}

function yyyyMmDdToday() {
  const { yyyy, mm, dd } = zonedParts(new Date());
  return `${yyyy}-${mm}-${dd}`;
}

function statePaths() {
  const dir = path.join(repoRoot, 'scripts', '.state');
  const file = path.join(dir, 'intervals_new_activity_state.json');
  return { dir, file };
}

function loadState() {
  const { file } = statePaths();
  if (!exists(file)) return { seenActivityIds: [], lastRunAt: null };
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    const ids = Array.isArray(parsed?.seenActivityIds) ? parsed.seenActivityIds : [];
    return { seenActivityIds: ids.map(String), lastRunAt: parsed?.lastRunAt || null };
  } catch {
    return { seenActivityIds: [], lastRunAt: null };
  }
}

function saveState(state) {
  const { dir, file } = statePaths();
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(file, JSON.stringify(state, null, 2) + '\n', 'utf8');
}

function vo2maxStatePaths() {
  const dir = path.join(repoRoot, 'scripts', '.state');
  const file = path.join(dir, 'intervals_vo2max_state.json');
  return { dir, file };
}

function loadVo2maxState() {
  const { file } = vo2maxStatePaths();
  if (!exists(file)) return { lastVo2max: null, lastSeenDate: null, history: [] };
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    return {
      lastVo2max: parsed?.lastVo2max ?? null,
      lastSeenDate: parsed?.lastSeenDate ?? null,
      history: Array.isArray(parsed?.history) ? parsed.history : [],
    };
  } catch {
    return { lastVo2max: null, lastSeenDate: null, history: [] };
  }
}

function saveVo2maxState(state) {
  const { dir, file } = vo2maxStatePaths();
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(file, JSON.stringify(state, null, 2) + '\n', 'utf8');
}

function fmtKm(meters) {
  if (meters == null) return null;
  const km = meters / 1000;
  return km >= 10 ? km.toFixed(1) : km.toFixed(2);
}

function fmtMin(seconds) {
  if (seconds == null) return null;
  const min = seconds / 60;
  return min >= 100 ? Math.round(min).toString() : min.toFixed(0);
}

function brDateFromIso(iso) {
  // iso may be "2026-02-12T..."; use date portion only.
  if (!iso || typeof iso !== 'string') return null;
  const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return null;
  return `${m[3]}/${m[2]}`; // dd/mm
}

function intervalsActivityUrl(id) {
  return `https://intervals.icu/activities/${encodeURIComponent(id)}`;
}

async function fetchRecentActivities(apiKey) {
  const oldest = yyyyMmDdDaysAgo(Math.max(1, DAYS_LOOKBACK));
  const newest = yyyyMmDdToday();
  const url = `https://intervals.icu/api/v1/athlete/${encodeURIComponent(ATHLETE_ID)}/activities?oldest=${encodeURIComponent(oldest)}&newest=${encodeURIComponent(newest)}`;

  const res = await fetch(url, {
    method: 'GET',
    headers: {
      Authorization: basicAuthHeader(apiKey),
      Accept: 'application/json',
    },
  });

  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`Intervals API HTTP ${res.status} ${res.statusText}${text ? ` - ${text.slice(0, 200)}` : ''}`);
  }

  const json = await res.json();
  if (!Array.isArray(json)) return [];
  return json;
}

async function fetchWellnessToday(apiKey) {
  const today = yyyyMmDdToday();
  const url = `https://intervals.icu/api/v1/athlete/${encodeURIComponent(ATHLETE_ID)}/wellness?oldest=${encodeURIComponent(today)}&newest=${encodeURIComponent(today)}`;

  const res = await fetch(url, {
    method: 'GET',
    headers: {
      Authorization: basicAuthHeader(apiKey),
      Accept: 'application/json',
    },
  });

  if (!res.ok) return null;
  const json = await res.json().catch(() => null);
  if (!Array.isArray(json) || !json[0]) return null;
  return json[0];
}

function normalizeType(type) {
  if (!type) return 'Workout';
  if (type === 'VirtualRide') return 'Ride';
  if (type === 'VirtualRun') return 'Run';
  return type;
}

function buildTelegramSummary(newActs) {
  const lines = [];
  lines.push(`Novas atividades no Intervals (${newActs.length}):`);
  for (const a of newActs.slice(0, 6)) {
    const id = a?.id ?? a?.activity_id ?? a?.icu_activity_id;
    const type = normalizeType(a?.type);
    const date = brDateFromIso(a?.start_date_local || a?.start_date);
    const name = (a?.name || '').trim();
    const km = fmtKm(a?.distance);
    const min = fmtMin(a?.moving_time ?? a?.elapsed_time);

    const bits = [date, type].filter(Boolean);
    if (km) bits.push(`${km} km`);
    if (min) bits.push(`${min} min`);

    const title = bits.join(' · ');
    lines.push(`- ${title}${name ? ` — ${name}` : ''}`);
    if (id != null) lines.push(`  ${intervalsActivityUrl(String(id))}`);
  }

  if (newActs.length > 6) {
    lines.push(`(+${newActs.length - 6} outras)`);
  }

  return lines.join('\n');
}

async function main() {
  // Silent outside time window
  if (!inSendWindow()) process.exit(0);

  const apiKey = getApiKey();
  if (!apiKey) {
    // Do not print secrets; keep error short.
    console.error('Intervals poll: missing INTERVALS_API_KEY (env or api_key.txt).');
    process.exit(2);
  }

  const state = loadState();
  const seen = new Set((state.seenActivityIds || []).map(String));

  // --- VO2Max tracking (Intervals wellness) ---
  // VO2Max usually lives in the wellness endpoint (e.g., Garmin VO2Max sync), not in the activity list.
  let vo2maxMsg = null;
  try {
    const wellness = await fetchWellnessToday(apiKey);
    const today = yyyyMmDdToday();
    const vo2 = wellness?.vo2max;
    if (vo2 != null && Number.isFinite(Number(vo2))) {
      const vo2State = loadVo2maxState();
      const prev = vo2State?.lastVo2max;
      if (prev == null) {
        vo2maxMsg = `VO2Max registrado: ${Number(vo2)}`;
      } else if (Number(prev) !== Number(vo2)) {
        const delta = Number(vo2) - Number(prev);
        const sign = delta > 0 ? '+' : '';
        vo2maxMsg = `VO2Max mudou: ${Number(prev)} → ${Number(vo2)} (${sign}${delta})`;
      }

      // Persist state (keep a rolling history)
      const history = Array.isArray(vo2State?.history) ? vo2State.history : [];
      const nextHistory = [...history.filter(h => h?.date !== today), { date: today, vo2max: Number(vo2) }]
        .slice(-Math.max(14, VO2MAX_HISTORY_DAYS));

      saveVo2maxState({
        lastVo2max: Number(vo2),
        lastSeenDate: today,
        history: nextHistory,
      });
    }
  } catch {
    // Silent: wellness/VO2Max is optional.
  }

  let activities;
  try {
    activities = await fetchRecentActivities(apiKey);
  } catch (err) {
    console.error(`Intervals poll: failed to fetch activities (${err?.message || err}).`);
    process.exit(3);
  }

  // newest first
  activities.sort((a, b) => {
    const da = (a?.start_date_local || a?.start_date || '');
    const db = (b?.start_date_local || b?.start_date || '');
    return db.localeCompare(da);
  });

  const newlySeen = [];
  for (const a of activities) {
    const id = a?.id ?? a?.activity_id ?? a?.icu_activity_id;
    if (id == null) continue;
    const idStr = String(id);
    if (!seen.has(idStr)) {
      newlySeen.push(a);
      seen.add(idStr);
    }
  }

  // Persist state regardless (so we don't re-notify on next run if API order changes)
  const seenArr = Array.from(seen);
  const pruned = seenArr.slice(Math.max(0, seenArr.length - MAX_SEEN));
  saveState({
    seenActivityIds: pruned,
    lastRunAt: new Date().toISOString(),
  });

  // If nothing new AND no VO2Max update worth mentioning, stay silent.
  if (newlySeen.length === 0 && !vo2maxMsg) process.exit(0);

  const blocks = [];
  if (newlySeen.length) blocks.push(buildTelegramSummary(newlySeen));
  if (vo2maxMsg) blocks.push(vo2maxMsg);

  process.stdout.write(blocks.join('\n\n') + '\n');
}

main();
