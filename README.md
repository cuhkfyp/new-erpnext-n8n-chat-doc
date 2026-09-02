# new-erpnext-n8n-chat-doc

Public-safe documentation backup for the secured ERPNext AI Assistant v2
implementation completed and verified on 2026-09-01.

This repository documents the design, implementation changes, operating
procedures, acceptance tests, and rollback controls. It also contains the
public-safe implementation source. Secret values, credential IDs, internal
hostnames, webhook IDs, browser tokens, database exports, rendered workflow
exports, and legacy key fingerprints are excluded because this repository is
public.

## Documents

- [Implementation record](docs/IMPLEMENTATION_RECORD.md)
- [Operations and credential handling](docs/OPERATIONS.md)
- [Acceptance and security tests](docs/ACCEPTANCE_TESTS.md)
- [Supabase 768-dimensional schema notes](docs/SUPABASE_SCHEMA.md)
- [Change log](docs/CHANGELOG.md)
- [Complete project-file audit](MANIFEST.md)
- [Sanitized full implementation runbook](docs/full/IMPLEMENTATION_AND_OPERATIONS.md)
- [Sanitized full n8n guide appendix](docs/full/N8N_GUIDE_V2_APPENDIX.md)
- [Sanitized full UAT appendix](docs/full/UAT_V2_APPENDIX.md)
- [Public-safe source bundle](source/README.md)

## Current state at backup time

- The secure v2 chat, permissioned-query, and schema-sync workflows are
  implemented.
- Browser requests use an opaque, session-bound token issued by Frappe; a raw
  Frappe SID or password is never sent to n8n.
- Record queries execute through Frappe's permission-aware list API. Model-
  generated SQL, joins, writes, and arbitrary expressions are rejected.
- The vector index contains schema metadata only and uses 768-dimensional
  Gemini embeddings. ERPNext record values are never embedded.
- The isolated acceptance Page is active for browser testing. The legacy Desk
  widget has not yet been replaced.
- The nominated higher-permission and restricted-user browser matrix has
  passed, including the corrected bilingual relative-date behavior. Broader
  operational/resilience checks still precede widget cutover.
- A separately managed Gemini generative credential was manually selected
  after a point-in-time health test. Automatic key cycling remains disabled.
- Frappe now supplies an authoritative current date/year and exact date ranges
  to both model paths, so English and Chinese relative-date questions do not
  depend on Gemini's training date or prior chat memory.

Production values must be supplied through Frappe and n8n credential stores,
never committed to this repository.
