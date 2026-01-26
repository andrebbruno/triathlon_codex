# MVP Hosted (Free) - Plan

Goal: keep cost near zero and automate weekly export + web view.

## Stack (free)
- GitHub Actions: weekly cron to run export.
- GitHub Pages: static site with reports.
- Intervals.icu API: data source.

## Files added
- `.github/workflows/weekly-export.yml`
- `scripts/build_site.ps1`

## Setup steps
1. Create a GitHub repo and push this folder.
2. In GitHub > Settings > Secrets and variables > Actions:
   - Add `INTERVALS_API_KEY` with your key.
3. Enable GitHub Pages:
   - Source: `Deploy from a branch`
   - Branch: `main`
   - Folder: `/site`
4. In Actions, run **weekly-export** once (manual).
5. Check `https://<user>.github.io/<repo>/` for reports list.

## What the workflow does
1. Writes `api_key.txt` from secret.
2. Runs `export-intervals-week-com-notas.ps1`.
3. Builds static site from `Relatorios_Intervals`.
4. Commits `Relatorios_Intervals` and `site`.

## Notes
- The export already saves JSON and planned MD in `Relatorios_Intervals`.
- You can change the cron time in the workflow file.
