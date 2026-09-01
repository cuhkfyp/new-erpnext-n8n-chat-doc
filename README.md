# new-erpnext-n8n-chat-doc

Public-safe documentation backup for the secured ERPNext AI Assistant v2
implementation completed and verified on 2026-09-01.

This repository documents the design, implementation changes, operating
procedures, acceptance tests, and rollback controls. It is intentionally not a
deployment bundle. Secret values, credential IDs, internal hostnames, webhook
IDs, browser tokens, database exports, workflow exports, and legacy key
fingerprints are excluded because this repository is public.

## Documents

- [Implementation record](docs/IMPLEMENTATION_RECORD.md)
- [Operations and credential handling](docs/OPERATIONS.md)
- [Acceptance and security tests](docs/ACCEPTANCE_TESTS.md)
- [Supabase 768-dimensional schema notes](docs/SUPABASE_SCHEMA.md)
- [Change log](docs/CHANGELOG.md)

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
- A separately managed Gemini generative credential was manually selected
  after a point-in-time health test. Automatic key cycling remains disabled.

Production values must be supplied through Frappe and n8n credential stores,
never committed to this repository.
