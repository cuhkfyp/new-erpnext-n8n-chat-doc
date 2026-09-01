# ERPNext AI Assistant v2 implementation record

## Outcome

The original chat outage was traced to reverse-proxy routing: the webhook path
was reaching Frappe instead of n8n and returning an HTML 400 response. The old
workflow was not restored because it trusted a forgeable username and executed
model-generated SQL with a shared database account.

A shadow v2 assistant was built instead. It keeps schema-only RAG, supports
authenticated staff, and delegates every record read to Frappe so the current
user's DocType, field, and row permissions remain authoritative.

## Frappe application changes

An `AI Assistant Settings` Single DocType was added with:

- an enable/disable switch;
- environment-specific n8n and integration configuration;
- default and hard result limits;
- a child table labelled `Schema DocType Allowlist`;
- a manual `Sync Now` action; and
- read-only sync status, counts, timestamps, drift, and error fields.

The authenticated backend exposes four narrow APIs:

- `bootstrap` returns an environment-specific webhook URL, a short-lived opaque
  token bound to the real browser session, and a non-PII chat session ID;
- `schema_catalog` returns normalized allowlisted schema metadata and stable
  hashes, never record values;
- `execute_query_plan` validates a `QueryPlanV1`, the browser session, allowlist,
  fields, filters, operators, limits, and read permission before executing via
  Frappe's permission-aware list API; and
- `record_sync_result` records successful synchronization, drift, changed and
  deleted chunks, and bounded failure details.

The raw issuing SID stays server-side in a short-lived token cache. The query
endpoint temporarily enters the validated session user's context only for the
bounded permission-aware read and restores the prior context afterward.

## QueryPlanV1

One request can address one DocType and supports:

- selected permitted fields;
- validated filters and operators;
- sorting and pagination;
- count, sum, average, minimum, and maximum; and
- one validated group-by field.

The default result limit is 20 and the hard maximum is 100. Raw SQL, writes,
joins, arbitrary expressions, system-table redirection, invalid fields,
unsupported operators, and oversized limits are rejected.

## n8n workflows

Three v2 workflows were created:

1. `ERPNext Schema Sync v2` fetches the complete catalog, compares deterministic
   hashes, embeds only added or changed chunks, upserts deterministically, and
   removes stale chunks only after a completely successful catalog and upsert
   run.
2. `ERPNext Permissioned Query v2` validates the Frappe session before
   retrieval, embeds the question at 768 dimensions, searches only the current
   environment namespace, asks Gemini for strict QueryPlanV1 JSON, validates
   the plan, and calls Frappe for execution.
3. `ERPNext AI Chat Assistant v2` validates the real Frappe session before any
   model call, keeps per-session Redis memory, and exposes the permissioned
   query workflow as its only ERPNext data tool.

Deterministic gates reject raw SQL, write intent, credential or secret requests,
and common injection shapes after session validation but before Gemini. A
second equivalent gate exists in the query workflow before embedding.

Natural business labels, translations, and abbreviations may resolve to an
allowlisted schema. They must never redirect a denied system-table request to a
different allowlisted DocType.

## Schema-only RAG

The isolated Supabase index is keyed by environment/site, DocType, chunk key,
and stable content hash. Both indexing and retrieval use
`gemini-embedding-2` with an explicit 768-dimensional output.

Only schema metadata is embedded. ERPNext records remain live in ERPNext and
are read only after Frappe has validated the user's permissions.

Synchronization is queued non-blockingly after a successful migration and runs
nightly at 02:30 Asia/Hong_Kong. A missed or failed event is repaired by the
nightly run. Partial catalog, embedding, Supabase, or batch failures preserve
the last good index and are recorded in Settings.

## Proxy and runtime changes

The exact v2 webhook route is placed before the catch-all ERPNext proxy. Its
apply procedure backs up the virtual host, performs an Apache configuration
test, reloads gracefully, and verifies routing. It does not add a broad n8n
proxy.

n8n is pinned to the tested release instead of `latest`. Existing workflow,
credential, SQLite, Redis, and mounted patch data remain on persistent volumes.
The supplied restart procedure uses container stop/start; it does not recreate
the containers or delete persistent data.

The VPN/proxy topology was retained and was not unnecessarily reconfigured.

## Acceptance Page and presentation corrections

A temporary authenticated Desk Page provides browser-level acceptance without
replacing the legacy lower-right widget. It obtains the opaque token through
Frappe bootstrap and sends it through supported n8n chat metadata. Direct,
uncredentialed, expired, or forged webhook requests fail before Gemini.

Several stacked-message clipping defects were corrected in the Page's scoped
chat layout:

- explicit header/body/footer grid rows prevent the scroll body from extending
  underneath the composer;
- inherited `height: 100%` and flex sizing are reset on the body;
- message flow begins at the top rather than using a flex spacer;
- a fixed trailing block contributes real scroll clearance after the final
  bubble; and
- DOM observation follows new shells and later Markdown height changes while
  respecting deliberate manual upward scrolling.

These are presentation-only changes. The authentication, permission, and
workflow contracts are unchanged.

## Gemini credential follow-up

The initial generative credential reached its free-tier request quota. Four new
n8n-managed generative credentials were checked through one temporary inactive
diagnostic workflow without exporting or printing their values.

- One new credential was rate-limited or overloaded at test time.
- Three returned valid Gemini responses.
- One working credential was deliberately selected for both chat generation
  and QueryPlan generation.
- The separate production embedding credential was not changed.

This was a manual switch, not a rotating key pool. Both updated workflows were
republished and loaded through the persistent n8n restart procedure. Current
and published definitions matched, and a normalized before/after comparison
confirmed that workflow logic did not change.

## Verification completed

- Static security and syntax contracts passed.
- Both v2 chat and query workflows were active and matched their published
  versions after restart.
- n8n and Redis returned healthy status after persistent stop/start.
- Startup logs confirmed activation of the v2 workflows.
- The generative credential change affected only the two intended model nodes.
- The 768-dimensional embedding credential and Supabase credential bindings
  were unchanged.
- A forged token stopped at Frappe validation before Agent/Gemini execution.
- Raw SQL, password/credential requests, and write attempts produced fixed safe
  refusals without ERPNext data execution.
- Schema synchronization completed successfully and repeat synchronization
  reported no drift.

The remaining rollout gate is the nominated higher-permission and restricted-
user browser acceptance matrix followed by an atomic widget cutover.
