# new-erpnext-n8n-chat-doc

Public-safe documentation backup for the secured ERPNext AI Assistant v2
implementation completed and cut over on 2026-09-02.

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
- Visible chat history is restored through an authenticated Frappe endpoint
  and an opaque per-user Redis key. The same ERPNext account can restore it
  after F5 or in another browser, while different users remain isolated.
- Record queries execute through Frappe's permission-aware list API. Model-
  generated SQL, joins, writes, and arbitrary expressions are rejected.
- Unambiguous simple counts can use a fixed deterministic QueryPlanV1 after
  schema retrieval; all such plans still pass through Frappe permissions.
  Other plans use Gemini structured output, strict local validation, and a
  bounded retry for temporary provider failures. Aggregate plans normalize
  redundant selected fields to their group-by fields before final Frappe
  validation.
- The vector index is isolated at `ai_assistant.erpnext_schema_chunks`, contains
  schema metadata only, and uses 768-dimensional Gemini embeddings. The
  unrelated `handbook_chunks` and `handbook_documents` tables are not used by
  v2. ERPNext record values are never embedded.
- The normal lower-right Desk widget now uses the secure v2 Frappe-bootstrap
  loader. The isolated acceptance Page is temporarily retained for diagnosis.
- The nominated higher-permission and restricted-user browser matrix has
  passed, including the corrected bilingual relative-date behavior.
- The normal schema-repair path and container-recreation persistence gate have
  passed. Redis now uses a tracked named volume with AOF and the documented
  host-memory prerequisite.
- Host reboot and deliberate provider-failure injection remain deferred
  explicit-impact maintenance tests; they are not widget-cutover blockers.
- The read-only reboot precheck is prepared, but currently reports nine
  pre-existing Frappe restart-policy blockers. The host must not be rebooted
  for acceptance until the persistent Frappe Compose policy is corrected and
  the checkpoint reports zero failures.
- Server-side cutover checks and the normal lower-right Desk smoke passed for
  both nominated users: the higher-permission query succeeded, the restricted
  user's allowed query succeeded, and the restricted dataset remained denied.
  Legacy workflow deactivation and the fourteen-day retention window remain a
  controlled follow-up.
- A separately managed Gemini generative credential was manually selected
  after a point-in-time health test. Automatic key cycling remains disabled.
- Frappe now supplies an authoritative current date/year and exact date ranges
  to both model paths, so English and Chinese relative-date questions do not
  depend on Gemini's training date or prior chat memory.

Production values must be supplied through Frappe and n8n credential stores,
never committed to this repository.
