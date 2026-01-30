# IT Tech Memory

Focus: scripts, automation, Intervals.icu API, reports build pipeline.

Update rules
- Save technical decisions, fixes, and known issues.
- If it affects workflow reliability, mirror in CORE.

2026-01-29
- Added MFP diary scraper using Playwright (scripts/mfp_scrape.mjs + scripts/mfp_scrape.ps1).
- Requires MFP_DIARY_PASSWORD env var; uses persistent profile at scripts/.mfp_profile.
- Cloudflare may require manual solve on first run; script pauses until ENTER.
- Use MFP_BROWSER=msedge and MFP_LOCALE=pt for best results.
