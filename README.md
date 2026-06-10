# Google-PhotosDeDuplicate

A local-first PowerShell module for scanning, reviewing, and cautiously de-duplicating large Google Photos libraries by driving **Chrome** through the Chrome DevTools Protocol.

> First target: Chrome on Windows with PowerShell 7.2+. Other browsers can come later.

## Current status

This is an early working scaffold. It is designed to be safe by default, observable, and testable before it touches your Google Photos trash.

## Why browser automation?

The Google Photos Library API is no longer a reliable whole-library scanning path for existing libraries, so this module uses your signed-in Chrome session and the Google Photos web UI. It does not ask for your Google password and does not store OAuth tokens.

## Features

- Opens or attaches to Chrome with `--remote-debugging-port`.
- Uses a dedicated Chrome profile by default.
- Scrolls the Google Photos timeline and captures lazy-loaded visible tiles.
- Hashes visible thumbnails in-browser when canvas access is allowed.
- Stores results in an append-only JSONL scan store.
- Uses parallel PowerShell processing when normalising scan records.
- Groups likely duplicate photos/videos using thumbnail URL and visual hash buckets.
- Exports a vibrant HTML review report.
- Provides a strict `Remove-GPDMediaItem` cmdlet that only deletes when identifiers resolve to exactly one item unless `-Force` is used.
- Includes Pester tests, GitHub Actions validation, and an internal detractor review cmdlet.

## Install from source

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Import-Module ./Google-PhotosDeDuplicate/Google-PhotosDeDuplicate.psd1 -Force
```

Validate your machine:

```powershell
Test-GPDEnvironment
```

## Connect to Chrome

```powershell
Connect-GPDBrowser -Verbose
```

The first run opens Chrome with a profile under:

```text
%LOCALAPPDATA%\GooglePhotosDeDuplicate\ChromeProfile
```

Sign in to Google Photos in that Chrome window. Later runs reuse the profile.

## Scan the timeline

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

For 70,000+ items, run in batches. The JSONL store is append-only and avoids duplicate `LocalId` values within the active scan run.

## Find duplicate groups

```powershell
Get-GPDDuplicateGroup `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -Similarity Conservative
```

Similarity modes:

| Mode | Behaviour |
| --- | --- |
| `ExactVisualHash` | Same 64-bit visual hash. |
| `Conservative` | Same kind/date/aspect bucket and Hamming distance <= 4. |
| `Relaxed` | Same kind/date/aspect bucket and Hamming distance <= 8. |

## Export the review report

```powershell
Export-GPDReport `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -Path ./reports/duplicate-review.html `
  -Similarity Conservative `
  -Open
```

The report shows duplicate groups, proposed keepers, local IDs, hashes, dimensions, and Google Photos links when discovered.

## Delete a uniquely identified item

Preview first:

```powershell
Remove-GPDMediaItem `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -LocalId 'PASTE_LOCAL_ID_HERE' `
  -WhatIf
```

Move the item to Google Photos Trash:

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

That composite delete only proceeds when it resolves to exactly one known media item.

## One-command workflow

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

This command does **not** delete anything.

## Validate and verify

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck
./tools/Test-GPDModule.ps1
```

That script runs:

1. PSScriptAnalyzer.
2. Pester tests.
3. `Invoke-GPDDetractorReview`.

Run only the detractor pass:

```powershell
Invoke-GPDDetractorReview
```

## Safety rules

- Deletion supports `-WhatIf` and `-Confirm`.
- Ambiguous identifiers are refused by default.
- Browser deletion requires a discovered `ItemUrl`.
- The module moves items to Trash; it does not permanently delete.
- Every delete attempt appends an audit row to the JSONL store.

## Large-library guidance

Recommended first serious run:

```powershell
Connect-GPDBrowser
Start-GPDLibraryScan `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -FromTop `
  -MaxScrolls 10000 `
  -ThrottleMs 1500 `
  -HashConcurrency 16 `
  -StopWhenNoNewItems `
  -Verbose
Export-GPDReport `
  -DatabasePath ./scan-output/google-photos.jsonl `
  -Path ./reports/review.html `
  -Open
```

Then delete only reviewed `LocalId` values.

## Limitations

- Google Photos UI selectors can change.
- Some thumbnails may not be hashable because browser canvas access can be blocked by cross-origin image protections.
- Video matching is thumbnail-based in this first cut; preview-frame hashing is on the roadmap.
- JSONL is simple and robust, but SQLite will be better for very heavy indexing later.

## Roadmap

- SQLite backend.
- Video frame sampling.
- Stronger deep-link extraction.
- Batch review queue.
- Resume cursor/checkpoint UX.
- Edge support.
- Optional rclone-assisted comparison against local exports.

## License

MIT
