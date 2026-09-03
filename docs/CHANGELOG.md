# Change log

## 2026-09-03

- Diagnosed two independent lower-right-widget failures: a syntactically valid
  but empty Gemini query-plan object and a temporary Gemini HTTP 503 high-demand
  response. A restricted user's denial for a separate DocType remained the
  expected Frappe permission result.
- Added a deterministic, no-filter `count(*)` QueryPlanV1 branch for an exact
  DocType found in retrieved schema metadata or an explicitly configured
  environment alias. The plan still executes only through authenticated
  Frappe permission enforcement.
- Added Gemini structured-output schema requirements, strict local plan-shape
  validation, and three attempts with 3-second waits for transient planner
  failures.
- Republished only the permissioned-query workflow through the supported n8n
  procedure, retaining all managed credential roles and persistent data.
- Verified administrator-level and restricted-user permitted counts directly
  through Frappe and confirmed that the restricted DocType remains denied.

## 2026-09-02

- Added authenticated, user-scoped visible chat history. Frappe derives an
  opaque Redis key from the site and actual logged-in ERPNext user, so F5 and
  another browser restore the same account's transcript without accepting a
  username or history key from the browser.
- Changed n8n Agent memory from a browser-session key to the Frappe-validated
  user history ID, retained the eight-hour Redis TTL, and kept n8n Chat Trigger
  history loading disabled because it occurs before workflow authentication.
- Added bounded Frappe history normalization and one-time legacy session-list
  migration. Guest history access is HTTP 403 and a direct n8n history request
  returns no stored messages.
- Versioned the lower-right widget loader again and verified distinct opaque
  keys for the nominated higher-permission and restricted accounts plus
  authenticated server-side isolation. One ambiguous pre-upgrade list was left
  to expire instead of risking assignment to the wrong user.
- Explicitly postponed host-reboot recovery testing to a future maintenance
  window and recorded that it is not a browser-acceptance or widget-cutover
  blocker.
- Captured restricted pre-cutover workflow and SSL-vhost backups and completed
  a fresh successful four-DocType, thirteen-chunk schema repair.
- Strengthened widget deployment to preserve and checksum-verify the Hksr app
  source and separate frontend-served asset.
- Switched the normal lower-right Desk widget to the secure v2 Frappe-bootstrap
  loader without rebooting, recreating, or restarting containers.
- Verified the publicly served loader, exact Apache route, guest rejection,
  forged-request safe failure, n8n/Redis health, VPN health, and required Frappe
  container health. Normal logged-in Desk smoke remains before legacy workflow
  deactivation.
- Diagnosed the first normal-Desk screenshot as a legacy widget instance kept
  alive by an already-open single-page Desk tab, not a v2 route regression.
- Added a versioned widget URL to Frappe hooks, resynchronized runtimes, cleared
  site cache, and gracefully reloaded Gunicorn without restarting containers.
  The effective hook and exact versioned public asset now resolve to v2.

- Verified the automatic nightly schema repair and a manual repair run against
  the same four-DocType, thirteen-chunk catalog with zero drift.
- Replaced the implicit anonymous Redis volume with a tracked Compose-named
  volume and enabled AOF with `appendfsync everysec`.
- Preserved and restored all five existing Redis keys, then passed repeated
  Redis-only Compose recreation while n8n remained healthy and all v2
  workflows stayed active.
- Added an idempotent Redis host-tuning helper and persistently applied
  `vm.overcommit_memory = 1`; the final recreation loaded without the previous
  warning.
- Verified normalized pre/post workflow definitions and credential roles were
  unchanged and kept raw recovery/workflow evidence out of the public backup.
- Hardened the operations-source installer to exclude runtime workflow stages
  and RDB files; stale installed artifacts were moved to a private recoverable
  backup rather than deleted.
- Added a read-only, private-baseline host-reboot `capture`/`verify` helper that
  never starts or changes services.
- Ran the precheck and blocked reboot readiness after finding nine long-lived
  Frappe containers on Docker's daemon-restart-incompatible `on-failure`
  policy; every current application/storage health check otherwise passed.

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
  allowed example-registration reads succeeded, restricted example-master and
  example-metrics access was enforced by Frappe, and deterministic raw-SQL/write
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
  rendered-workflow examples plus a complete manifest covering every source
  file and generated bytecode file.
