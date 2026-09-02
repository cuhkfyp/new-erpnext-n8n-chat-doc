# Change log

## 2026-09-02

- Diagnosed bilingual 2024 current-year answers as missing server temporal
  context, not a quota, host-clock, or ERPNext-timezone failure.
- Added a Frappe-generated authoritative date context with current date/year,
  exact current-year/current-month boundaries, and site timezone.
- Validated that context before both Gemini paths and injected it into chat and
  QueryPlan prompts, overriding model training dates and prior Redis memory.
- Republished both workflows through the supported persistent procedure;
  health, activation, current/published versions, and unchanged credential
  roles were verified.
- Closed the two-user browser acceptance gate after the administrator's
  Traditional Chinese grouped `今年` aggregate used 2026 and the direct English
  current-year answer returned 2026; earlier restricted-user permission and
  safety results remained valid.
- Recorded partial higher-permission and restricted-user browser acceptance:
  allowed `CCD Registration` reads succeeded, restricted `CCD Master` and
  `hksr_rb` access was enforced by Frappe, and deterministic raw-SQL/write
  refusals remained in place.
- Diagnosed the restricted RB browser's generic error as two sequential,
  independent results: the expected Frappe HTTP 403 permission rejection,
  followed by Gemini HTTP 429 while formatting the denial because the active
  `back 2` project had reached its 20-request daily quota.
- Re-probed the n8n-managed `Gemini Generative v2 - back 3` credential without
  exposing its value; it returned HTTP 200 with the expected smoke reply.
- Switched only the chat and QueryPlan generation nodes to `back 3` through
  n8n export/import/publish, leaving the embedding credential unchanged.
- After `back 3` returned HTTP 429 during the higher-permission grouped
  aggregate, re-probed `Gemini Generative v2 - back 4` through the inactive
  managed-credential workflow. Execution `410` returned HTTP 200 and exactly
  `OK`; no credential value was exported or displayed.
- Explicitly switched only the chat and QueryPlan generation nodes to
  `back 4`. Automatic key cycling remains disabled and the embedding credential
  remains unchanged.
- Reloaded n8n through the supplied persistent stop/start script. n8n and
  Redis remained healthy, all three v2 workflows activated, and the v2 webhook
  was registered. No workflow, credential, or SQLite volume was recreated.
- Verified matching current/published workflow versions, HTTP 200 n8n health,
  Redis `PONG`, and the static security/syntax contracts after the `back 4`
  switch.
- Updated the authoritative implementation, n8n operations, and UAT records.

## 2026-09-01

- Confirmed the legacy outage was caused by reverse-proxy routing to Frappe
  instead of n8n.
- Rejected restoration of the insecure forgeable-user/raw-SQL workflow.
- Added configurable AI Assistant Settings and Schema DocType Allowlist.
- Added authenticated bootstrap, schema catalog, permissioned QueryPlanV1
  execution, and sync-result APIs.
- Added non-blocking post-migration sync and nightly repair scheduling.
- Added schema-only Supabase RAG with deterministic hashes and 768-dimensional
  Gemini embeddings.
- Added secure chat, permissioned-query, and incremental schema-sync n8n
  workflows.
- Added opaque session-bound authentication and Redis chat memory.
- Added deterministic pre-model gates for raw SQL, writes, secrets, and prompt
  injection.
- Corrected natural-language allowlisted dataset resolution without allowing
  denied system-table substitution.
- Added exact reverse-proxy route management with backup, configuration test,
  graceful reload, and routing verification.
- Pinned n8n to the tested version and preserved mounted SQLite, credential,
  patch, and Redis data.
- Added the isolated browser acceptance Page.
- Fixed initial and stacked-message clipping, composer overlap, streaming-height
  races, and final-message tail clearance.
- Diagnosed unrelated bulk-delete notifications as shared-user Frappe realtime
  messages, not v2 workflow writes.
- Tested four newly managed Gemini generative credentials without exporting
  their values; manually switched both generation nodes to one working
  credential and left the embedding credential unchanged.
- Republished and restarted n8n through the persistent procedure; verified both
  v2 workflows active and structurally unchanged apart from the intended
  credential reference.
- Updated the tracked and persistent implementation, n8n operations, and UAT
  documentation.
- Added a public-safe source backup containing the Frappe backend and Desk UI,
  generic n8n workflow templates, Supabase migrations, proxy/runtime helpers,
  UAT examples, and static contract tests. Environment-rendered workflows,
  production configuration, bytecode, credentials, and runtime artifacts were
  excluded.
- Added sanitized full copies of the authoritative implementation/operations,
  n8n guide, and UAT documents. Added sanitized production-environment and
  rendered-workflow examples plus a complete manifest covering all 39 source
  files and 13 generated bytecode files.
