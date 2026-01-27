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
   - Folder: `/docs`
4. In Actions, run **weekly-export** once (manual).
5. Check `https://<user>.github.io/<repo>/` for reports list.

## What the workflow does
1. Validates `INTERVALS_API_KEY` secret.
2. Runs `export-intervals-week-com-notas.ps1` and `intervals-longterm-coach-edition.ps1`.
3. Builds static site from `Relatorios_Intervals`.
4. Commits `Relatorios_Intervals` and `docs`.

## Notes
- The export already saves JSON and planned MD in `Relatorios_Intervals`.
- You can change the cron time in the workflow file.

## API key (local vs GitHub)
### Local MVP
The scripts now look for the key in this order:
1. `INTERVALS_API_KEY` environment variable
2. `api_key.txt` in the project root
3. `%USERPROFILE%\.intervals\api_key.txt` (or `$HOME/.intervals/api_key.txt`)

Recommended: create the local file outside the repo:
`C:\Users\Andre\.intervals\api_key.txt`

### GitHub Actions
Use `INTERVALS_API_KEY` in GitHub Secrets. The workflow reads the secret directly and does not write any key file.
