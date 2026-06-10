# Google-PhotosDeDuplicate

A local-first PowerShell module for scanning, reviewing, and cautiously de-duplicating large Google Photos libraries by driving **Chrome** through the Chrome DevTools Protocol.

> First target: Chrome on Windows with PowerShell 7.2+. Other browsers can come later.

## Why this exists

The Google Photos Library API is no longer a good fit for whole-library duplicate detection. After the 2025 API changes, listing/searching/retrieving media through the Library API is restricted to app-created content, so this module uses the signed-in browser UI instead.

## What it does

- Opens or attaches to Chrome with a dedicated profile.
- Scrolls the Google Photos timeline.
- Captures visible lazy-loaded tiles.
- Hashes thumbnails in the browser when possible.
- Stores scan results in an append-only JSONL database.
- Groups likely duplicate photos/videos.
- Exports a colourful review report.
- Moves a uniquely identified item to Google Photos Trash through the browser UI.
- Refuses ambiguous deletion unless you explicitly force it.
- Provides a built-in “detractor review” safety check.

## What it does **not** do yet

- It does not permanently delete anything.
- It does not use the restricted Google Photos Library API for full-library access.
- It does not silently delete duplicate groups.
- It does not yet support Edge/Firefox/Safari.
- It does not guarantee Google Photos UI selectors will remain stable forever.

## Install from source

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Import-Module ./Google-PhotosDeDuplicate/Google-PhotosDeDuplicate.psd1 -Force
```

Run the environment check:

```powershell
Test-GPDEnvironment
```

## First run

Open Chrome with a dedicated profile:

```powershell
Connect-GPDBrowser -Verbose
```

Sign in to Google Photos in that Chrome window. The module reuses the profile on later runs.

## Scan your Google Photos timeline

```powershell
Start-GPDLibraryScan `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -FromTop `
  -MaxScrolls 5000 `
  -ThrottleMs 1200 `
  -HashConcurrency 12 `
  -StopWhenNoNewItems `
  -Verbose
```

For 70,000+ items, expect to run in batches. The JSONL database is append-only and the scanner de-duplicates records by local fingerprint.

## Find duplicate groups

```powershell
Get-GPDDuplicateGroup `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -Similarity Conservative
```

Similarity modes:

| Mode | Meaning |
| --- | --- |
| `ExactVisualHash` | Same 64-bit thumbnail visual hash only. |
| `Conservative` | Same date/kind/aspect bucket and visual hash distance <= 4. |
| `Relaxed` | Same date/kind/aspect bucket and visual hash distance <= 8. |

## Export a review report

```powershell
Export-GPDReport `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -Path ./reports/duplicate-review.html `
  -Similarity Conservative `
  -Open
```

The report shows candidate groups, a proposed keeper, local IDs, hashes, and open links.

## Delete exactly one identified item

`Remove-GPDMediaItem` is intentionally strict. It refuses to continue if your identifiers match zero or multiple records.

Preview first:

```powershell
Remove-GPDMediaItem `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -LocalId 'PASTE_LOCAL_ID_HERE' `
  -WhatIf
```

Then move to Trash:

```powershell
Remove-GPDMediaItem `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -LocalId 'PASTE_LOCAL_ID_HERE' `
  -Confirm `
  -PassThru
```

Composite identity example:

```powershell
Remove-GPDMediaItem `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -VisualHash64 'fffffffffffffffe' `
  -ApproxDate '2024-01-01' `
  -Kind Photo `
  -Confirm
```

That composite delete only proceeds if the store resolves it to exactly one media item.

## One command workflow

```powershell
Invoke-GPDDeduplication `
  -Connect `
  -Scan `
  -FindDuplicates `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -MaxScrolls 5000 `
  -HashConcurrency 12 `
  -ExportReportPath ./reports/duplicate-review.html `
  -OpenReport
```

## Validate the module

```powershell
Install-PSResource Pester -Scope CurrentUser -TrustRepository -Reinstall
Install-PSResource PSScriptAnalyzer -Scope CurrentUser -TrustRepository -Reinstall
./tools/Test-GPDModule.ps1
```

This runs:

1. PSScriptAnalyzer.
2. Pester tests.
3. Built-in detractor review.

You can run only the built-in detractor pass with:

```powershell
Invoke-GPDDetractorReview
```

## Safety model

Deletion is intentionally hard to trigger:

- `Remove-GPDMediaItem` supports `-WhatIf` and `-Confirm`.
- It refuses ambiguous matches.
- It opens the target item in Chrome before deletion.
- It checks that the open page still looks like the expected media kind.
- It records the deletion result in the JSONL store.
- Google Photos Trash remains the recovery layer; the module does not permanently delete.

## Large library tips

For 70,000+ items:

```powershell
Start-GPDLibraryScan `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -MaxScrolls 10000 `
  -ThrottleMs 1500 `
  -HashConcurrency 16 `
  -StopWhenNoNewItems `
  -Verbose
```

Recommended approach:

1. Scan in batches.
2. Export report.
3. Review proposed keepers.
4. Delete only specific reviewed `LocalId` values.
5. Re-run duplicate grouping.

## Notes on browser automation

The module talks to Chrome through `127.0.0.1:<port>` and CDP websockets. It does not ask for your Google password and does not store OAuth tokens.

## Roadmap

- SQLite storage backend for heavier indexing.
- Video preview-frame hashing.
- Better item deep-link extraction.
- Batch review queue.
- Pause/resume scan cursor.
- Edge support.
- Optional rclone-assisted export comparison.

## License

MIT
