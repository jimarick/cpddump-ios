# CPD Dump — iOS companion app

Native Swift/SwiftUI companion for CPD Dump (AI evidence inbox for UK
doctors' appraisal). Xcode project `CPDDump/CPDDump.xcodeproj`, plus the
`CPDDumpShare` share extension. Bundle id family: com.cpddump.

## Sibling app: the backend + web app

**The backend lives at `~/Code/CPD-Dump`** (Laravel 13 + Inertia/React, live
at cpddump.com on Laravel Cloud). This app talks to it exclusively through
the Sanctum-token API: `routes/api.php` → `app/Http/Controllers/Api/` in
that repo. When in doubt about a contract, read the backend source and its
tests (`tests/Feature/Api/`) — they are the truth, not memory.

Rules for keeping the two in step:

- **When planning any feature**, check the backend for whether the API
  surface it needs already exists. Never invent endpoints or fields — read
  `routes/api.php` and the controllers.
- **When a change needs backend work** (new endpoint, extra serialised
  field, different status code): if `~/Code/CPD-Dump` is an attached working
  directory in this session, apply the backend change directly (run its
  tests: `vendor/bin/pest --parallel` — Postgres, from that repo). If not
  attached, end your summary with a clearly-marked **"Backend follow-up"**
  section listing exactly what the web session must change, precise enough
  to paste there. Do not silently work around missing API surface.
- **Contract principles to honour**: the server enforces rules (PII gate,
  retention, quotas) — this app surfaces them, never re-implements them as
  the only line of defence; dismissed items and deleted activities are HARD
  deleted (404 forever — no local state may assume they persist); attachment
  files vanish on a schedule (audio after transcription, unkept files at
  approval) — always handle `purged: true` and 404s on attachment URLs;
  `raw_payload` carries only title/subject/url/details — display the AI
  draft (`ai_analysis`), not raw source text.

## Key API behaviours (as of 2026-07-20)

- Approve: `POST /api/v1/inbox-items/{id}/approve` accepts
  `keep_attachment_ids: [int]` (files not listed are deleted — server
  default is delete) and `pii_ack: bool`. If the item has `pii_gate: true`,
  approval without `pii_ack` returns 422 with validation error key `pii`.
- `POST /api/v1/inbox-items/{id}/remove-pii` purges stored files to stubs,
  scrubs NHS numbers from user-authored text, lifts the gate, and returns
  the refreshed item.
- Dismiss returns `{"status": "dismissed", "deleted": true}` — the row is
  gone.
- Upload allowlist follows the backend config (`config/cpd.php`
  `ingest.allowed_extensions`) — includes heic/heif (server converts
  everything to JPEG), eml, csv, xlsx, md, rtf, mp3, wav, m4a, tiff, avif,
  bmp. Client-side HEIC→JPEG conversion before upload is a worthwhile
  bandwidth optimisation but no longer a correctness requirement.

## Design language

Match the web: "cpd dump." wordmark with orange full stop, paper + ink + one
orange (#F4590C), Bricolage Grotesque for display type where feasible. The
retired stamp logo and Cormorant serif must not reappear.
