# ERPNext AI Assistant v2 — Implementation and Operations

> Public-backup note: this is a full copy of the authoritative runbook with
> production hostnames, webhook/workflow/version IDs, credential record IDs,
> private paths, legacy-key locations, and internal DocType names replaced by
> placeholders or examples. No API key or credential value was present in the
> source document.

Last updated: 2026-09-01 (Asia/Hong_Kong operational timezone)

This is the implementation record and runbook for restoring ERPNext AI chat
without re-enabling the legacy raw-SQL design. The vector index contains
DocType schema metadata only. ERPNext record values remain live in Frappe and
are read through the current browser user's permissions.

## Current rollout state

The v2 implementation is deliberately fail-closed.

- All three v2 n8n workflows were imported as inactive shadows. The chat and
  permissioned-query workflows are now published for isolated browser
  acceptance. The already-tested authenticated schema-only workflow is also
  published so post-migrate and nightly synchronization can operate; it does
  not expose ERPNext record data.
- The two existing colleague workflows remain active and unmodified.
- The Hksr backend overlay is installed and migrated. The production master
  switch is temporarily enabled for acceptance, but the default Desk widget
  remains the legacy file and was not switched.
- Dedicated production Supabase, Frappe, Gemini generative, Gemini embedding,
  and Redis credentials are stored in n8n and bound without exporting values.
- The production schema index is initialized with 11 schema-only chunks for
  `Example Master`, `Example Registration`, and the operator-added `example_reporting`. A repeat
  sync completed with zero changed and zero deleted chunks.
- One exact v2 Apache path is applied for the isolated canary Page. The broad
  ERPNext catch-all and legacy widget route were not changed.
- Supabase and Gemini secret values are not present in source. Development and
  UAT still require their own projects and managed credentials.
- `Example Reporting View` is not currently an installed Frappe DocType on the
  inspected `frontend` site. It is therefore not seeded as queryable: Frappe
  cannot enforce DocType/field/row permissions for a raw MariaDB table. The
  settings status records this mismatch. Install a real permissioned DocType
  or remove the requested entry; do not add a raw-SQL exception.

Do not install the v2 default widget or deactivate the legacy workflows until
the two-user acceptance gate is complete.

## What changed

| Area | File or component | Change |
|---|---|---|
| Frappe auth | `hksr/ai_assistant/auth.py` | Issues random, short-lived tokens bound to the real Frappe cookie session and a required opaque non-PII chat session ID. The raw SID stays server-side. Every bearer validation checks the exact issuing `Sessions` row is still active, unexpired, owned by the same enabled user, and unchanged. Validates the n8n integration header using an encrypted Password field. |
| Query API | `hksr/ai_assistant/query_plan.py` | Strict QueryPlanV1 parser; rejects unknown keys, SQL, writes, joins, expressions, invalid fields/operators, and limits over 100. Executes only via `frappe.get_list`. |
| Schema RAG | `hksr/ai_assistant/schema.py` | Produces deterministic schema-only chunks and SHA-256 hashes. It never queries document rows. |
| Sync lifecycle | `hksr/ai_assistant/sync.py` | Seeds existing default DocTypes, queues after migrations without failing deployment, runs nightly at 02:30 site time, triggers n8n, and records status/counts/errors. |
| Frappe APIs | `hksr/ai_assistant/api.py` | Adds `bootstrap`, authenticated user-scoped `chat_history`, `validate_session`, `schema_catalog`, `execute_query_plan`, `record_sync_result`, and `request_schema_sync`. |
| ERPNext UI | `AI Assistant Settings` Single DocType | Adds enabled switch, environment paths, encrypted integration secret, result limits, DocType child allowlist, Sync Now, and read-only sync telemetry. System Manager only. |
| Desk widget | `hksr/public/js/n8n_chat.js` | Calls Frappe bootstrap first; sends no username or cookie to n8n; places only the opaque token/session in supported chat-request metadata; restores the active user's visible history through authenticated Frappe; has no insecure legacy fallback. Installed only during atomic cutover. |
| Acceptance Page | `hksr/hksr/page/ai_assistant_v2_uat` | Provides `/app/ai-assistant-v2-uat` for logged-in browser testing without replacing the default widget. It bootstraps through Frappe, mounts the standard n8n client in-page, and hides the legacy floating widget only while the Page is open. Trigger-level visible-history reload is disabled because n8n processes it before workflow authentication; authenticated Frappe history restores the same user's Agent transcript. |
| Frappe hooks | `hksr/hooks.py` marker block | Registers `after_migrate` and `30 2 * * *` schema-sync scheduling. The site timezone is confirmed as `Asia/Hong_Kong`. |
| Schema sync workflow | `ERPNext Schema Sync v2` | Authenticated trigger; stable hash comparison; treats an empty first-run hash list as valid input; embeds only changed chunks; atomically upserts a complete batch; deletes stale chunks only after a complete successful run; routes catalog, Supabase, embedding, upsert, and delete failures to bounded Frappe status telemetry. |
| Query workflow | `ERPNext Permissioned Query v2` | Revalidates the opaque token and active issuing Frappe session before retrieval/Gemini, retrieves only the environment namespace, requests JSON QueryPlanV1, and calls Frappe for permissioned execution. Cookies and CSRF values do not enter n8n. |
| Chat workflow | `ERPNext AI Chat Assistant v2` | Validates before the model, keys Redis memory only by the Frappe-validated opaque user history ID, and exposes only the permissioned query workflow as a data tool. |
| Supabase | `supabase/detect_vector_schema.sql` and schema-specific `001_erpnext_schema_rag_v2*.sql` | Detects whether the existing vector extension lives in `extensions` or `public`, then creates a private 768-dimensional index and service-role-only RPCs without relocating or modifying legacy 3072-dimensional objects. |
| n8n runtime | `n8n/docker-compose.v2.yml` | Pins tested n8n `2.21.7`, retains the existing data volume/error patch/VPN/direct-DB bypass, and adds non-secret environment configuration. Production is the safe default namespace; UAT/development must override it explicitly. |
| Frappe runtime deployment | `deploy_shadow_backend.sh` | Preserves the Hksr tree, then installs the same AI module and hook state into backend, short queue, long queue, and scheduler containers with per-container backups. It stages files below the tracked workspace so snap-packaged Docker can read them, compiles each runtime copy, and fails closed if an expected worker is missing. |
| Apache | `apache/apply_ai_chat_route.sh` | Persistent idempotent exact-route apply/verify/rollback with backup, configtest, graceful reload, and upstream-vs-local-TLS-vhost routing verification. `curl --resolve` avoids false failures where the host cannot hairpin through its public address. |
| Verification | `tests/test_static_contracts.sh` | Checks Python/JSON syntax, inactive workflow-template state, no saved execution payloads, pre-Gemini validation order, hard limits, vector dimensions, first-run empty-hash handling, proxy-safe response decoding, synchronized worker deployment, and common secret patterns. |

Frappe documents that `frappe.get_list` applies record permissions for the
session user. The v2 endpoint also calls `frappe.model.get_permitted_fields`
and rejects every selected, filter, sort, grouping, and aggregate field that is
not permitted before invoking `get_list`: [Frappe Database API](https://docs.frappe.io/framework/user/en/api/database).

Frappe runs `after_migrate` after schema/background-job synchronization. The
hook catches its own failures so a Redis/n8n outage cannot fail deployment:
[Frappe database migrations](https://docs.frappe.io/framework/user/en/database-migrations).

## Request and trust flow

1. An authenticated Desk browser calls `bootstrap` through Frappe.
2. Frappe checks the enabled switch, returns a same-origin webhook path, and
   issues an opaque token bound to the current Frappe SID. Neither the username
   nor SID is returned.
3. The browser calls the exact Apache route. The supported `@n8n/chat`
   metadata body carries only the opaque token and non-PII chat session ID.
   The browser cookie, SID, username, and CSRF token do not enter n8n.
4. The chat workflow strictly validates the metadata shape, then forwards the
   opaque token/session as headers to `validate_session`. Although this Frappe
   endpoint permits a Guest transport, it requires the bearer values and
   verifies their server-side SID binding against the exact still-active,
   unexpired `Sessions` row and enabled user. Missing, expired, forged, or
   cross-session values fail before Gemini.
5. A data question invokes the permissioned query workflow, which validates
   again before creating a query embedding.
6. Supabase returns schema metadata from the validated environment namespace.
7. Gemini returns QueryPlanV1 JSON, never SQL.
8. Frappe revalidates the bearer and backing browser session, temporarily sets
   only the permission user for this read-only call, validates the complete
   plan, and executes `frappe.get_list`, preserving DocType, field-level, user,
   and row permissions. No new login session is created or copied.
9. Only the permitted result is returned to n8n for conversational formatting.

The opaque token is a short-lived bearer delegated by the authenticated
bootstrap call, not a username assertion. It cannot outlive logout, expiry,
session deletion, or user disablement because Frappe checks the backing session
on every validation and query. Calls directly to n8n without the matching
unexpired token/session pair cannot create a Frappe query context. n8n is
configured not to save successful or failed execution payloads.

The configured browser route is additionally constrained to exactly
`/n8n-webhook/<16-128 URL-safe characters>/chat`; absolute URLs, extra path
segments, traversal tokens, query strings, fragments, and whitespace are
rejected.

## QueryPlanV1 contract

One request targets exactly one allowlisted normal DocType.

```json
{
  "version": "1",
  "doctype": "Example Registration",
  "fields": ["name", "status"],
  "filters": [
    {"field": "status", "operator": "=", "value": "Open"}
  ],
  "order_by": [
    {"field": "modified", "direction": "desc"}
  ],
  "offset": 0,
  "limit": 20,
  "aggregates": [],
  "group_by": []
}
```

Supported filter operators are `=`, `!=`, `>`, `>=`, `<`, `<=`, `in`,
`not in`, `like`, `not like`, `between`, and `is`. Supported aggregate names
are `count`, `sum`, `average`, `minimum`, and `maximum`.

Enforced bounds:

- default limit 20; configurable maximum cannot exceed hard limit 100;
- offset maximum 10,000;
- at most 25 selected fields, 20 filters, 3 sort fields, 3 group fields, and
  5 aggregates;
- at most 100 values in `in`/`not in` and 2,048 characters per string value;
- no unknown top-level or nested keys;
- no dotted fields, joins, raw aliases, custom functions, write verbs, or SQL;
- `sum` and `average` require numeric Frappe fields;
- Password, attachment, HTML, code/editor, child-table, and layout field types
  are blocked even if a broad role could otherwise read them.

The server generates aggregate expressions itself after validation. Model text
is never placed into an SQL expression.

## Schema synchronization behavior

Catalog chunks are deterministic by `(site_id, doctype, chunk_id)` and include
only labels, field names, field types, safe options, descriptions, and schema
flags. A content hash changes when the normalized chunk changes.

The workflow reads existing hashes, embeds only added/changed chunks, and sends
the complete changed batch to one PostgreSQL RPC transaction. Any malformed
embedding or upsert aborts that transaction. Stale deletion is a later,
separate transaction reached only if:

- the catalog reported `complete=true` for all requested DocTypes;
- every changed chunk produced exactly 768 numbers; and
- the atomic upsert completed successfully.

An incomplete catalog, Gemini failure, Supabase failure, or partial embedding
batch therefore cannot delete the last known chunks. ERPNext records Success,
Drift, or Error with catalog/DocType/chunk/changed/deleted counts and a bounded
error message.

The hash-list HTTP node uses n8n `alwaysOutputData` so a valid empty Supabase
array still reaches comparison on the first run. Gemini/upsert/delete HTTP
nodes use n8n response autodetection; in the deployed proxy topology this
consumes and decodes the HTTP response stream before the strict status/body
validators run.

Google's current Gemini embedding guide identifies `gemini-embedding-2` and
recommends 768, 1536, or 3072 output dimensions. v2 uses the documented
asymmetric retrieval prefixes and explicit REST `output_dimensionality: 768`:
[Gemini embeddings](https://ai.google.dev/gemini-api/docs/embeddings).

Supabase documents that pgvector similarity operators should be wrapped by a
Postgres RPC and filtered in the function. The v2 match RPC filters on
`site_id` before ordering by cosine distance:
[Supabase vector columns](https://supabase.com/docs/guides/ai/vector-columns).

## Credential and environment matrix

Create separate projects/credentials for development, UAT, and production.
Never copy production n8n SQLite/encryption material to another environment.

| Credential in n8n | Type | Required scope |
|---|---|---|
| `Frappe AI Assistant Sync v2 - ENV` | Header Auth | Header name `X-AI-Assistant-Integration-Key`; value exactly matches the encrypted Frappe Settings value for that environment. |
| `Gemini Generative v2 - ENV` | Google Gemini/PaLM API | Dedicated generative key for the configured model. Do not use the embedding key or the old multi-key pool. |
| `Gemini Embedding v2 - ENV` | Google Gemini/PaLM API | Dedicated embedding key for `gemini-embedding-2`. |
| `Supabase Schema RAG v2 - ENV` | Supabase API | Service credential for that environment's dedicated project only. |
| `Redis (n8n-redis)` | Redis | The local n8n Redis sidecar; opaque chat sessions only. |

Do not confuse the four authentication/encryption values:

- the operator-created 32-or-more-character **Integration Secret** is used
  only by schema synchronization between n8n and the protected Frappe catalog
  and status APIs. It is not a Gemini key and it does not encrypt Supabase;
- Gemini generative and embedding API keys are separate managed n8n
  credentials used only when their respective model nodes run;
- the browser token and chat session ID are generated automatically by Frappe
  after a real ERPNext login. The Page supplies them to n8n and users do not
  create, copy, or type them;
- `N8N_ENCRYPTION_KEY` is separate existing n8n runtime encryption material
  protecting stored credentials. It must remain stable across restarts and is
  not sent with API requests.

Non-secret runtime variables:

| Variable | Example/purpose |
|---|---|
| `AI_ENVIRONMENT` | `development`, `uat`, or `production` |
| `AI_FRAPPE_BASE_URL` | Internal Frappe frontend URL, currently `http://<FRAPPE_INTERNAL_HOST>:8080` |
| `AI_FRAPPE_SITE_HOST` | Frappe site routing header, currently `frontend` |
| `AI_SUPABASE_URL` | Dedicated environment project URL |
| `AI_EMBEDDING_MODEL` | `gemini-embedding-2` |
| `AI_EMBEDDING_DIMENSIONS` | fixed at `768` |
| `AI_GENERATIVE_MODEL` | Managed environment model name |
| `AI_SCHEMA_MATCH_COUNT` | retrieval chunk count, default 8 |

In Frappe `site_config.json`, environment-owned values may override the
Settings fields with `ai_assistant_site_id`, `ai_assistant_webhook_url`,
`ai_assistant_sync_url`, and `ai_assistant_token_ttl_seconds`. Webhook bootstrap
accepts only a relative same-origin `/n8n-webhook/.../chat` path.

## Shadow installation

The persistent source of truth is
`<N8N_OPERATIONS_ROOT>/ai-assistant-v2`. The implementation
installer backs up the tracked Compose/UAT/operations files, copies this
bundle there, pins Compose without recreating the running container, and
updates the existing operations and UAT guides with idempotent marker blocks:

```bash
cd <IMPLEMENTATION_WORKSPACE>
sudo ./ai-assistant-v2/install_operations_source.sh
```

This installer does not reload Apache, restart n8n, activate workflows, or
enable the Frappe assistant.

### 1. Preserve and install the Hksr backend

The script archives the entire current Hksr working tree (excluding `.git` and
bytecode), records `git status`, records a binary tracked diff, adds only the
new backend/DocType trees, and inserts an idempotent hook marker. It also backs
up and synchronizes the AI module, DocTypes, hooks, and acceptance Page into
the short queue, long queue, and scheduler containers. This is required when
those containers do not share the backend container layer. It does not replace
the current widget in backend-only mode.

```bash
cd <N8N_OPERATIONS_ROOT>/ai-assistant-v2
sudo ./deploy_shadow_backend.sh backend-only
docker exec frappe_docker-backend-1 bash -lc \
  'cd /home/frappe/frappe-bench && bench --site frontend migrate'
```

The deployment must report successful synchronization for all three runtime
containers. Confirm Settings exists and remains disabled. The after-migrate
job will not call n8n while disabled. Use the supplied persistent ERPNext
restart script after a live update so every Python process loads the same
module version; do not recreate containers merely to reload code.

### 2. Apply Supabase SQL

Run `supabase/detect_vector_schema.sql` first. If it returns `extensions`, apply
`supabase/001_erpnext_schema_rag_v2.sql`. If it returns `public`, apply
`supabase/001_erpnext_schema_rag_v2.public-vector.sql`. Each migration refuses
to run against the wrong extension schema and never relocates the extension,
because the existing 3072-dimensional functions or explicitly qualified types
may depend on its current location.

Confirm the 768-dimensional column and four functions, then create the managed
Supabase credential in n8n. Do not expose the private `ai_assistant` schema to
anonymous/authenticated API roles.

### 3. Render and import environment workflows

Use new, unique IDs in every environment. IDs are routing identifiers, not
credentials; header/session validation remains mandatory.

```bash
cd <N8N_OPERATIONS_ROOT>/ai-assistant-v2/n8n
AI_CHAT_WEBHOOK_ID='<unique-environment-chat-id>' \
AI_SCHEMA_SYNC_WEBHOOK_ID='<unique-environment-sync-id>' \
./render_workflows.sh workflows.rendered.json

docker cp workflows.rendered.json n8n:/tmp/erpnext-ai-v2-workflows.json
docker exec -u root n8n chmod 0644 /tmp/erpnext-ai-v2-workflows.json
docker exec n8n n8n import:workflow --input=/tmp/erpnext-ai-v2-workflows.json
```

The imported workflows must remain inactive while credentials show
`CONFIGURE_*`. Bind the five environment credentials in the UI and save each
workflow without activating the chat workflow.

### 4. Configure Frappe Settings

As System Manager, open `AI Assistant Settings` and configure:

- a unique site identifier, such as `<PRODUCTION_SITE_ID>`;
- the relative browser webhook path matching the rendered chat webhook ID;
- internal sync URL `http://<N8N_INTERNAL_HOST>:5678/webhook/<sync-id>`;
- a new random integration secret of at least 32 characters, copied once into
  the matching n8n Header Auth credential;
- default/maximum result limits and existing DocType allowlist.

Leave Enabled unchecked until credential, sync, permission, and failure tests
pass.

## Acceptance tests

Use one nominated existing higher-permission user and one nominated existing
restricted user. Use separate named accounts rather than a shared
`Administrator` login: Frappe realtime dialogs are addressed to the logged-in
user, so background actions from another browser using the same account can
appear in the acceptance tab. Never create a fake username or send one in
workflow metadata.

### Authentication and direct-call tests

- Browser bootstrap as each user succeeds only when enabled.
- Guest bootstrap fails.
- Direct chat webhook without SID/token fails before any Gemini execution.
- Forged username metadata has no effect.
- Token with a different/expired SID fails.
- Missing/invalid sync integration header cannot fetch the catalog or record a
  result.

### Query safety tests

- Valid list, count, sum, average, minimum, maximum, grouped count, sort,
  pagination, empty result, and >limit truncation.
- Traditional Chinese and English prompts.
- Denied DocType, denied field, denied row, bad operator, dotted field, unknown
  key, boolean/oversized limit, excessive offset, raw SQL, comments, union,
  subquery, write verbs, and injection strings.
- Compare results for the higher-permission and restricted users to equivalent
  ERPNext list views/reports. They must differ where Frappe permissions differ.

### Schema sync and failure tests

- Initial sync adds only schema metadata.
- An allowlisted field label/type/description change changes only its chunk.
- Removing a field or DocType deletes stale chunks only after a complete run.
- Force one embedding failure: no upsert/deletion transaction is applied and
  ERPNext reports Error.
- Force atomic upsert failure: transaction rolls back and stale deletion is not
  reached.
- Force catalog incomplete: no stale deletion.
- Confirm development/UAT/production credentials and Supabase projects cannot
  retrieve each other's `site_id` data.

### Persistence tests

- `docker stop/start` n8n and Redis preserves workflows/credentials/memory
  storage as configured.
- Compose recreation uses pinned n8n 2.21.7 and the persistent n8n data bind.
- ERPNext restart preserves Settings/DocTypes.
- Deferred resilience test: a maintenance-window host reboot must eventually
  prove that n8n volume, route, Frappe schema, Redis behavior, and VPN topology
  recover. This is not a browser-acceptance or widget-cutover prerequisite.
- Confirm n8n still uses `surfshark-vpn:8888`; do not reconfigure or stop the
  independent `surfshark-wireguard` project.

## Atomic cutover

Cutover is one change window after acceptance:

1. Export/checksum all workflows again and back up the SSL vhost.
2. Activate Schema Sync v2 and Permissioned Query v2; run a complete successful
   schema sync.
3. Activate Chat Assistant v2.
4. Install the v2 widget with `deploy_shadow_backend.sh cutover-widget`, build
   assets/clear Frappe cache as required.
5. Set the Settings webhook path to the same rendered v2 chat ID and enable.
6. Apply the exact Apache route:

   ```bash
   cd <N8N_OPERATIONS_ROOT>/ai-assistant-v2/apache
   AI_CHAT_WEBHOOK_ID='<production-v2-id>' sudo ./apply_ai_chat_route.sh apply
   ```

7. Repeat both users' browser greeting/data/direct-forgery smoke tests.
8. Monitor Apache, Frappe web/queue/scheduler, n8n, n8n Redis, Supabase sync
   telemetry, and `surfshark-vpn` health.

The acceptance Page is a temporary full-page canary. Step 4 installs the
tracked secure v2 loader in `mode: "window"`, returning the assistant to the
normal lower-right Desk widget after acceptance. It replaces the legacy
widget's endpoint and authentication contract; it does not restore or reuse
the insecure raw-SQL workflow.

Only after acceptance, rotate every exposed legacy Gemini key (including the
old pool) and the legacy Supabase service credential. Deactivate, but do not
delete, the two old workflows for 14 days. Never reactivate their raw-SQL path.

## Rollback

Rollback does not restore insecure raw SQL.

1. Uncheck Enabled in AI Assistant Settings.
2. Deactivate the v2 Chat workflow (and sync workflow if it is failing).
3. Restore the saved Apache vhost:

   ```bash
   sudo ./apply_ai_chat_route.sh rollback \
     <AI_ROUTE_STATE_DIR>/<ERP_VHOST>.conf.before-ai-v2.<timestamp>
   ```

4. Restore the pre-cutover widget from the Hksr backup only if needed to remove
   the launcher; do not point it at the old raw-SQL workflow.
5. Preserve v2 workflows, logs, Settings telemetry, and Supabase index for
   diagnosis.

## Baseline and audit artifacts

The implementation baseline directory contains:

- all seven pre-change workflow definitions and SHA-256 checksum;
- a post-shadow-import export/checksum showing ten workflows;
- pre-change Hksr dirty-worktree archive/diff/status;
- Apache SSL/HTTP vhost copies and runtime inventory;
- credential references by name/type and fingerprints only (never values).

The VS Code Copilot memory file may point here but is not an operational source
of truth. Maintain this runbook together with `N8N_SETUP_AND_OPERATIONS.md` and
the UAT deployment guide whenever configuration changes.

## 2026-09-01 implementation and verification record

Completed in the production shadow without routing users to v2:

- saved the seven-workflow pre-change export, Apache vhosts, Compose/restart
  configuration, container/mount/network inventory, and a fingerprint-only
  credential reference inventory in a mode-0700 baseline directory;
- installed and migrated the Hksr v2 backend and Single/child DocTypes, while
  retaining timestamped full Hksr working-tree backups and the pre-migration
  Frappe site backup;
- left `AI Assistant Settings.enabled=0`; seeded `Example Master` and
  `Example Registration`; recorded the missing `Example Reporting View` DocType as an
  error rather than bypassing Frappe permissions. The operator subsequently
  added the existing `example_reporting` DocType to the allowlist;
- registered `hksr.ai_assistant.sync.nightly_schema_sync` as an enabled Cron
  job at `30 2 * * *`; the site timezone is `Asia/Hong_Kong`;
- imported all three v2 workflows with inactive state and execution payload
  saving disabled, then re-exported ten workflows. The final restricted audit
  export SHA-256 is
  `70a02c1aea858002bb42514cfe5b655630bb4445bc4f454213610c47584d77ca`;
- confirmed the two legacy colleague workflows remained active and unchanged;
- pinned the tracked Compose source to n8n `2.21.7` and completed a controlled
  Compose recreation. The existing n8n bind volume, SQLite workflows,
  credentials, mounted patch, Redis data, and VPN topology were retained;
- updated `N8N_SETUP_AND_OPERATIONS.md`, both UAT guides, the UAT environment
  template, and `Deploy_UAT.sh`. The UAT stage now carries the v2 templates and
  deliberately removes production v2 definitions so UAT must render fresh IDs;
- kept the SSL vhost byte-identical to its baseline and kept the legacy widget
  in place. There is no production v2 Apache route and no v2 browser cutover;
- passed static Python/JSON/shell/security contracts, Compose validation,
  workflow Code-node JavaScript syntax checks, and eight Frappe tests. Frappe
  test mode was restored to `allow_tests=false`;
- observed local fail-closed HTTP results: guest bootstrap `403`, catalog
  without the integration key `401`, and direct inactive v2 chat webhook `404`.

Acceptance-gated work intentionally remains outside this implementation run:

- create separate development/UAT Supabase projects and apply the migration to
  each before those environments are used;
- execute the full two-existing-user browser/UAT matrix, including permission
  differences and forced partial failures;
- only after acceptance, activate v2, install the widget, apply the exact
  Apache route, enable Settings, rotate exposed legacy credentials, and
  deactivate (not delete) the legacy workflows for 14 days.

### 2026-09-01 production credential follow-up

- The production project reported pgvector in `public`; the operator applied
  `001_erpnext_schema_rag_v2.public-vector.sql` successfully. This created the
  isolated 768-dimensional table/index and four service-role RPCs without
  changing the existing 3072-dimensional objects.
- The operator stored the current production service-role value in the n8n
  credential `Supabase Schema RAG v2 - production`. The value remains encrypted
  in n8n and is not present in workflow JSON, this repository, or this runbook.
- Credential reference ID `<SUPABASE_CREDENTIAL_ID>` is now bound to all four inactive
  v2 Supabase nodes: hash listing, atomic upsert, stale deletion, and schema
  matching. The verified ten-workflow export is
  `baseline/2026-09-01/n8n-workflows-after-supabase-bind-verified.json` with
  SHA-256
  `6da99117a2a7fbe1d1adb9863e499b465253a6506d8de1f9ef89f4b23a446264`.
- Non-secret Frappe settings are staged as `<PRODUCTION_SITE_ID>`, browser path
  `/n8n-webhook/<PRODUCTION_CHAT_WEBHOOK_ID>/chat`, and internal sync URL
  `http://<N8N_INTERNAL_HOST>:5678/webhook/<PRODUCTION_SYNC_WEBHOOK_ID>`. The master
  switch remains disabled.
- The operator stored the matching Frappe integration value in
  `Frappe AI Assistant Sync v2 - production`. Credential reference ID
  `<FRAPPE_SYNC_CREDENTIAL_ID>` is bound to the authenticated sync webhook, catalog fetch,
  and ERPNext result-recording nodes. The workflows remain inactive. The
  post-binding audit export is
  `baseline/2026-09-01/n8n-workflows-after-frappe-auth-bind-verified.json` with
  SHA-256
  `828266a94dfa205225906869c38030e7238b7e388a805026b23ec254fb94205b`.
- `n8n/production.env` records the non-secret production runtime contract. It
  takes effect only after a controlled Compose recreation. Do not activate v2
  until the initial sync and permission tests pass.
- The operator created `Gemini Generative v2 - production` and
  `Gemini Embedding v2 - production` in n8n. Their values were never read or
  exported. Credential references `<GENERATIVE_CREDENTIAL_ID>` and
  `<EMBEDDING_CREDENTIAL_ID>` are bound respectively to both generative nodes and both
  768-dimensional embedding nodes. A fresh export confirms all three v2
  workflows are inactive and contain no `CONFIGURE_*` credential placeholders.
  The restricted audit export is
  `baseline/2026-09-01/n8n-workflows-after-gemini-bind-verified.json` with
  SHA-256
  `c4585e40de60609ba8356952b61831ba90eff0c1e938c99be4773cf2cc3cc597`.
- The AI Assistant Settings section label was renamed from
  `Schema-RAG DocType Allowlist` to `Schema DocType Allowlist`. The fieldname
  and stored allowlist rows did not change. The overlay was redeployed from a
  full pre-change backup at
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T043702Z`,
  and `bench --site frontend migrate` completed successfully.

### 2026-09-01 runtime, restart, and initial sync verification

- Production n8n was recreated from the pinned `2.21.7` Compose definition.
  `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` is deliberately scoped to the non-secret
  `AI_*` runtime contract used by workflow expressions; secret values remain in
  n8n/Frappe credential storage. The existing persistent volume and credential
  encryption key were retained.
- The operator-approved `<ERPNEXT_RESTART_SCRIPT>` was
  used for the Frappe restart. It performed its ordered stop/start and reapplied
  the existing portal, nginx real-IP, host, SSH, and mount configuration. The
  MariaDB sites/assets/logs volumes remained mounted and no ERPNext or n8n data
  was lost.
- A disabled-state schema test failed closed with HTTP 403 before Gemini or
  Supabase. The controlled restart then loaded the migrated schema-catalog code
  that had been stale in the earlier worker process.
- The first real catalog contained 3 allowlisted DocTypes and 11 deterministic
  schema chunks with catalog hash
  `495a46948319472d0c7200c5881e931169bce2df13b92b652ff3e9a917a2ef4f`.
  An empty Supabase hash array initially produced zero n8n items; the hash node
  now has `alwaysOutputData=true`, with a static regression contract.
- The first embedding attempt returned HTTP 200 but exposed an undecoded
  response stream to the validator. Setting the three strict full-response
  nodes to `responseFormat=autodetect` fixed decoding without weakening status,
  768-dimension, complete-batch, or stale-deletion checks.
- The successful first population embedded and atomically upserted all 11
  chunks, recorded `Drift`, and deleted zero chunks. The immediate second run
  recorded `Success`, 3 DocTypes, 11 chunks, changed `0`, deleted `0`, and an
  empty error. `AI Assistant Settings.enabled` was returned to `0` after every
  controlled run. CLI-driven shadow tests do not set `last_sync_started_at`;
  normal manual/nightly triggers set it in Frappe before calling n8n.
- The final ten-workflow restricted export is
  `baseline/2026-09-01/n8n-workflows-final-shadow.json`, SHA-256
  `c527b78a355f2671d23fd83bca9dc4d6635d1f4551cfb1420f4d09260ad3e1a9`.
  It confirms both legacy workflows active, all v2 workflows inactive, all
  managed credential references bound, the first-run/response fixes present,
  and no `CONFIGURE_*` placeholders.

### 2026-09-01 isolated production browser-acceptance canary

- Added the standard Desk Page `AI Assistant v2 Acceptance` at
  `https://<ERP_PUBLIC_HOST>/app/ai-assistant-v2-uat`. It has no stored
  secrets, usernames, or SIDs. It calls Frappe `bootstrap`, uses the real
  browser cookie only for that bootstrap, then sends the opaque token/session
  through chat metadata and mounts chat into a Page-local target. The raw
  cookie/SID never enters n8n. The legacy floating widget is hidden only while
  this Page is open and its source still points to the unchanged legacy webhook.
- The Page was deployed from pre-change Hksr backup
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T061753Z`
  and registered with `bench --site frontend migrate`.
- Initially published only workflow IDs
  `<PERMISSIONED_QUERY_WORKFLOW_ID>` (permissioned query) and
  `<CHAT_WORKFLOW_ID>` (chat). After the correction,
  published authenticated schema sync ID
  `<SCHEMA_SYNC_WORKFLOW_ID>` as well, so post-migrate and nightly
  events no longer strand Settings at `Queued`. The supplied
  `<N8N_RESTART_SCRIPT>` stop/start retained n8n SQLite,
  credentials, Redis data, mounts, and the pinned `2.21.7` image.
- Applied only
  `/n8n-webhook/<PRODUCTION_CHAT_WEBHOOK_ID>/chat` before the Frappe
  catch-all. Apache passed `configtest` and direct-vs-TLS-vhost comparison.
  Rollback backup:
  `<AI_ROUTE_STATE_DIR>/<ERP_VHOST>.conf.before-ai-v2.20260901T062234Z`.
- The first verification attempt safely restored its vhost backup when the
  public-address hairpin timed out. The verifier now uses local TLS resolution
  with the real hostname/SNI, bypasses proxy variables, and scopes temporary
  cleanup to the verifier subshell.
- Guest bootstrap returns HTTP 403. A forged direct webhook call receives the
  intentionally generic mounted-patch response.
- The first real Page attempt exposed two n8n `2.21.7` contracts: Chat Trigger
  emits only the POST body (not HTTP headers), and its visible-history action
  runs before ordinary workflow nodes. Consequently, the original header-based
  capture always failed, while history reload required an unauthenticated
  trigger memory connection.
- The initial assistant message and each newly appended user/typing/reply
  message could be partly hidden behind the composer. Flex sizing constraints
  and tail-follow alone did not correct the shell allocation. Browser
  DevTools showed a complete `779.4 x 56px` bot bubble extending roughly one
  composer-height below the body. The Page therefore overrides the n8n shell
  with explicit `max-content / minmax(0, 1fr) / max-content` grid rows for
  header, body, and footer. A follow-up DevTools capture showed that the added
  `::before` flex spacer itself consumed the remaining list height and still
  forced the bubble against the footer; it has been removed. Messages now use
  normal block flow from the top of the body, and a protected `78px` tail
  (spacing + actual 50px composer + clearance) keeps the final bubble above
  the composer during scrolling. The Page also runs a scoped
  `MutationObserver` that
  follows the body tail after DOM/layout frames while the user is already near
  the bottom. Manually scrolling upward disables tail-follow until the user
  returns to the bottom or sends a new message. The observer, scroll listener,
  and animation frame are all removed during reconnect/unmount.
- A longer-conversation capture exposed a remaining race: adding a typing or
  assistant bubble could increase `scrollHeight` before the scheduled layout
  frame, causing the passive scroll listener to clear tail-follow. The observer
  had previously forced following only for a new user bubble. It now treats any
  newly added `.chat-message` as an explicit tail event and performs the
  post-layout scroll for user, typing, and assistant bubbles alike. Manual
  upward scrolling remains respected when no new message is being appended.
- The next DevTools capture proved the first all-message change still set its
  force flag too early: the final assistant `<p>` existed in the message list,
  but a scroll event between the mutation and the two animation frames could
  clear `follow_chat_tail` before the actual scroll. The Page now retains a
  separate `force_chat_tail_pending` latch across cancelled/rescheduled frames
  and consumes it only after setting the body to its final `scrollHeight`.
  Thus character-data streaming cannot cancel a newly added message's required
  tail scroll, while ordinary manual upward scrolling remains respected.
- A full `.chat-body` DevTools highlight then exposed the underlying geometry:
  n8n's base stylesheet still supplied `height: 100%` to the body. The grid item
  therefore remained as tall as the whole shell and physically continued under
  its sibling footer/composer; no scroll position could reveal that covered
  region. The Page now assigns header/body/footer to grid rows 1/2/3, resets
  body `height`/`block-size` to `auto !important`, removes its flex sizing, and
  keeps the footer above it. The body's real maximum scroll position now ends
  above the composer.
- The next browser capture showed that this geometry correction worked, but
  the last completed/error bubble could still be clipped by roughly one text
  line. n8n first adds a typing/assistant message shell and then inserts or
  replaces Markdown inside that existing shell. The earlier observer forced a
  tail update only when the shell itself was added, so the later height change
  could arrive after that force was consumed. The Page observer now recognizes
  mutations whose target is inside `.chat-message` and preserves the tail
  latch when the user was already following (or a force remains pending).
  Deliberate manual upward scrolling is still respected.
- A further three-part DevTools capture proved the final 80px bot bubble still
  ended flush with, or roughly 10px inside, the 66px composer even though the
  grid row boxes themselves no longer overlapped. The configured n8n variables
  were present (`--chat--spacing: 1rem`, `--chat--textarea--height: 50px`), so
  this was not an invalid CSS expression. The composer-sized padding workaround
  was replaced with ordinary list padding and a fixed-height trailing
  `.chat-messages-list::after` block. In normal block flow this final block is
  included in `scrollHeight` after every message, while the previously removed
  leading flex spacer consumed the remaining body height. This provides real
  clearance below the last bubble without changing the three-row shell.
- The observed answer to `SELECT * FROM tabUser` was not acceptable. Although
  it did not execute SQL or read `tabUser`, schema retrieval chose the nearest
  allowlisted metadata and the models substituted `Example Master`, producing an
  unrelated 100-row result. The chat workflow now validates the real Frappe
  session first, then deterministically routes raw SQL, write intent,
  credential/secret requests, and injection shapes to a fixed safe refusal
  before the Agent or Gemini. The permissioned-query workflow repeats the same
  read-only natural-language gate after session validation and before the
  embedding call. Its planner may resolve ordinary business-language names,
  translated labels, and abbreviations against the retrieved allowlisted
  DocType name/label/description, but may not invent an unrelated DocType or
  field. Frappe remains the authoritative allowlist and permission boundary.
  Container-side gate tests rejected `SELECT * FROM tabUser`, password
  retrieval, and deletion while accepting a normal Example Master count.
- The first live count after the gate change proved an over-strict planner
  instruction was wrong: it treated `example client database` as absent and
  generated `__NOT_ALLOWLISTED__`. Frappe correctly returned 403, but the
  question should have mapped to `Example Master`. That sentinel has been removed
  and business-label resolution restored without weakening the raw-SQL gate.
  A later plain `why` prompt failed independently at the chat model with Gemini
  HTTP 429: the managed generative credential had reached its 20-request
  free-tier quota. That is not a Frappe permission or gate decision. Continue
  model-backed acceptance after quota reset or with an approved separately
  managed generative credential; automatic key cycling remains prohibited.
- On 2026-09-01, four newly created n8n-managed generative credentials named
  `Gemini Generative v2 - back 1` through `back 4` were checked through one
  temporary inactive diagnostic workflow. Secret values were neither exported
  nor printed. The existing production credential returned HTTP 429; `back 1`
  returned Google's too-many-requests response; `back 2` and `back 3` returned
  HTTP 200 with the expected probe reply; and `back 4` returned a valid Gemini
  candidate with the expected reply. This is a point-in-time health check, not
  an automatic failover pool.
- `back 2` was then bound manually to only `Gemini Generate QueryPlanV1` in
  `ERPNext Permissioned Query v2` and `Gemini Generative v2` in
  `ERPNext AI Chat Assistant v2`. `Gemini Query Embedding 768` remains bound to
  the separate `Gemini Embedding v2 - production` credential. The environment-
  rendered workflow file was updated to match; reusable templates retain their
  credential placeholders.
- n8n's supported import command deactivated the two updated drafts. Both were
  immediately republished as their current versions and the supplied persistent
  stop/start script was used so the running process loaded them. Startup logs
  confirm activation of both v2 workflows. The published query version is
  `<PUBLISHED_QUERY_VERSION_ID>`; the published chat version is
  `<PUBLISHED_CHAT_VERSION_ID>`. Current and published exports are
  byte-identical for each workflow.
- Credential-switch snapshots are
  `baseline/2026-09-01/ai-query-before-credential-switch.json` (SHA-256
  `f857e494eb031837199735046f5e9e504dc8b9c2bcadb84d47dc8ddcdeeb2fe3`),
  `baseline/2026-09-01/ai-chat-before-credential-switch.json` (SHA-256
  `e995ba81223d179969d74a42292757d87bfec9d3c9e1d649f48fddb1d01f3f0c`),
  `baseline/2026-09-01/ai-query-after-credential-switch.json` (SHA-256
  `a5108b759ec4d48a1ca688615c85efb7117c2a7c865d208b5ab5f438287f615c`),
  and `baseline/2026-09-01/ai-chat-after-credential-switch.json` (SHA-256
  `ebe70f41c16bff0d9dd53e16d0e4dd759096b143f98a7a744745230dae2caf08`).
  Matching `*-published-*` snapshots have the same respective hashes. After
  normalizing version metadata and the generative credential reference, the
  before/after structure hashes are identical (`5d7f23ce...` for query and
  `78cc2355...` for chat), proving no workflow logic changed.
- A separate `Bulk Operation Successful` / `Deleted all documents successfully`
  dialog was traced to standard Frappe `frappe.desk.reportview.delete_bulk`, not
  to either v2 workflow. At 16:07-16:09 Hong Kong time, access and worker logs
  recorded `Administrator` bulk-delete requests/jobs for `AI Training Log`,
  `AI Session History`, and `Chat`. Frappe publishes that success dialog over
  realtime to the session user, so every open tab using a shared
  `Administrator` identity can display it. The acceptance Page deliberately
  does not suppress a real deletion notification. Use distinct named users to
  attribute acceptance activity and avoid cross-browser dialogs.
- Live n8n executions `292` (chat) and `293` (permissioned query) proved that
  the clipped data question completed every validation, embedding, retrieval,
  QueryPlan, Frappe execution, and final-agent node successfully; its completed
  reply was the white strip below the visible scroll position. This confirms
  the final correction is presentation-only. The bearer, permission, and
  workflow contracts are unchanged.
- The launcher help text now states precisely that uncredentialed or forged
  n8n requests fail; the valid Page itself still posts to n8n with a
  Frappe-issued bearer. Layout deployment backups are
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T072147Z`
  and
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T074607Z`.
  The final grid correction backup is
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T075419Z`.
  The spacer-removal/full-tail backup is
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T080306Z`.
  The all-message tail-follow correction backup is
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T081923Z`.
  The pending-force/input-gate deployment backup is
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T083712Z`.
  The explicit body-height/business-alias correction backup is
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T085548Z`.
  The existing-message-content tail-follow correction backup is
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T091719Z`;
  its first persistent documentation installation backup is
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-config-backups/20260901T092013Z`.
  The fixed trailing-block correction backup is
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T093130Z`.
  These Page-only deployments used Frappe cache clear plus the persistent ERPNext
  stop/start; no schema migration was necessary. Live Page JS/CSS checksums
  match tracked source, and service/sync health remained good. After the inner
  message correction, Page JavaScript SHA-256
  `086909950e4819a4103753cb2325ce966d81ab0b330f77801da426d5f6188446`
  matched the tracked overlay, persistent Hksr repository, and restarted
  backend runtime. After the fixed trailing block, Page CSS SHA-256
  `2ef2d9e4563e7b4fee4a91821b5d1b62f2b840eaae77012f6c38626607a0c70b`
  matched the tracked overlay, persistent Hksr repository, and restarted
  backend runtime; the static security/syntax contract suite passed.
- The corrected Page/widget now puts the opaque token/session in supported
  request metadata, never the cookie or SID. Frappe stores the raw issuing SID
  only in its server-side token cache and validates the still-active `Sessions`
  row on each call. The query endpoint applies that validated user only within
  the permissioned `frappe.get_list` call. Visible-history reload is explicitly
  `notSupported`/`false`; Redis agent memory remains enabled for same-session
  follow-up questions.
- A live compatibility probe found that the internal `Sessions` table has no
  `modified` column; its active-session lookup therefore uses Frappe's query
  builder, matching Frappe's own session code. The corrected read-only probe
  printed `active_session_probe=passed` without exposing an SID.
- Post-fix negative test execution `288` used a forged non-secret token. It
  passed metadata shape validation, received HTTP 401 from Frappe at
  `Validate Frappe Session Before Gemini`, and never started the agent or any
  Gemini node. Guest bootstrap remains HTTP 403.
- Backend safety backups for this correction are
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T064007Z`
  `20260901T064600Z`, and `20260901T065146Z`. The final permission-user context
  also replaces per-request user/role/local caches during the bounded query and
  restores them afterward, preventing Guest or prior-user cache reuse. The
  supplied ERPNext and n8n restart scripts used container stop/start; no
  container or persistent volume was recreated.
- The first exact queued repair test remained at `Queued` because the backend
  container had `hksr.ai_assistant` while the short queue, long queue, and
  scheduler container layers did not. The deployment script now installs and
  compiles one synchronized runtime copy in all four containers and creates a
  recoverable per-container backup before replacement. Its first attempt
  failed safely because snap-packaged Docker could not read a host `/tmp`
  staging directory; staging now uses a private directory below the deployment
  workspace. The failed-safe and successful backup sets are respectively
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T070702Z`
  and
  `<PRIVATE_BACKUP_ROOT>/ai-assistant-v2-backups/20260901T070745Z`.
- After the synchronized deployment and the supplied persistent ERPNext
  restart, backend, both queues, and scheduler had matching module checksums.
  The exact `enqueue_schema_sync(...); frappe.db.commit()` path then executed
  in the short queue and recorded `Success`, 3 DocTypes, 11 chunks, changed
  `0`, deleted `0`, and an empty error. This verifies the real after-migrate
  and nightly worker path, not only a direct synchronous call.
- `AI Assistant Settings.enabled=1` only for this acceptance window. The last
  automatic repair sync recorded `Success`, 3 DocTypes, 11 chunks, changed
  `0`, deleted `0`, and an empty error. After testing, either
  proceed with atomic widget cutover or set the switch to `0`, unpublish all
  three v2 workflows, restart n8n, and roll back the exact Apache route.
- Restricted workflow audit export:
  `baseline/2026-09-01/n8n-workflows-canary-active.json`, SHA-256
  `f5966d59fa1b669998ea3159ca93822bd84c31326cabcb07a4c6738a0559bd13`.
  The corresponding restricted Apache vhost copy is
  `baseline/2026-09-01/apache-<ERP_VHOST>.conf.after-canary`, SHA-256
  `0f0f968b162d937422f16b638f6a703b7d3c762e7eae2b6eaedcbde0422061d0`.
- Authentication-fix workflow snapshots are
  `baseline/2026-09-01/n8n-workflows-before-canary-auth-fix.json`, SHA-256
  `9f4929c05b40e4d932290067276da36bdb70da7723290db8d8b86d8a6589c7f7`,
  and `baseline/2026-09-01/n8n-workflows-after-canary-auth-fix.json`, SHA-256
  `f12ac30e2dc8fb1464af606bde1de68b36520d27afeba8d9b26fa6caeabfdbe9`.
  The latter confirms chat/query active, schema sync inactive, metadata auth
  present, and trigger history reload disabled.
- Final automatic-sync audit export:
  `baseline/2026-09-01/n8n-workflows-after-automatic-sync-cutover.json`,
  SHA-256
  `d6c05b8d11d4a8318c746c66ae4b051587b07130a6f5e0508ae3ec44d4c468af`.
  It confirms all three v2 workflows active, no `CONFIGURE_*` placeholders,
  no browser cookie/CSRF/SID transport in chat/query, metadata bearer capture,
  and trigger history reload disabled.
- Input-gate workflow snapshots are
  `baseline/2026-09-01/n8n-workflows-before-input-gate.json`, SHA-256
  `d6c05b8d11d4a8318c746c66ae4b051587b07130a6f5e0508ae3ec44d4c468af`,
  and `baseline/2026-09-01/n8n-workflows-after-input-gate.json`, SHA-256
  `f0d94666bf7191f4bd7667569a5f3eaee68d35bf91693ce4efd846c955b36d65`.
  The latter confirms all three v2 workflows active, 10-node chat/query
  definitions with both deterministic gates, and all managed credential
  references still bound. The supported n8n CLI import/publish sequence and
  supplied persistent stop/start retained SQLite, credentials, Redis, mounts,
  and the pinned image. Post-restart Redis returned `PONG`, Apache configuration
  was valid, all Frappe containers were up, and the Page JS checksum
  `9b28392f3bd7809a58a2aa627b068fae08f5091bbb90055717153f3cbee0af48`
  matched backend, both queues, scheduler, and tracked source.
- The post-diagnosis planner/grid export is
  `baseline/2026-09-01/n8n-workflows-after-alias-grid-fix.json`, SHA-256
  `8da5fa09dbbf355af0d03fd2898050fb2a70e1045dc1f3be65df7a3edeb90617`.
  It confirms all three v2 workflows active, no `__NOT_ALLOWLISTED__` sentinel,
  the natural-business-label planner contract, and preserved managed
  credentials. The deployed Page CSS SHA-256 is
  `83e93d086e102efe9242c7d160141fc878d7ff56edfae2e586a37d89d36dd44d`
  in tracked source, backend, both queues, and scheduler. The restart script's
  first probe ran before n8n's longer startup and returned HTTP 000; subsequent
  health was `ok`, all three v2 workflows activated, Redis returned `PONG`, all
  Frappe containers were up, and Apache configuration was valid.
- On 2026-09-02, partial higher-permission and restricted-user browser
  acceptance confirmed permitted example-registration reads, restricted
  example-master and example-metrics enforcement, and deterministic raw-SQL/write
  refusals. The restricted request reached Frappe and was correctly rejected
  with HTTP 403. The enclosing chat execution then failed while composing the
  denial because the active `back 2` generative credential returned Gemini
  HTTP 429 for its 20-request free-tier daily quota; the generic browser error
  was therefore a quota presentation failure, not a permission bypass.
- `Gemini Generative v2 - back 3` was rechecked without reading or exporting
  its secret and returned HTTP 200 with the expected smoke reply. The supported
  n8n export/import/publish path then changed only the QueryPlan generator and
  chat model to the managed `back 3` credential. The embedding nodes remain on
  the separate production embedding credential, and there is no automatic key
  cycling. The supplied persistent stop/start procedure retained SQLite,
  credentials, Redis, mounts, and the pinned n8n version. Subsequent health was
  HTTP 200 and startup logs activated all three v2 workflows with the chat
  webhook registered.
- Continued restricted-user acceptance passed permission-bypass injection
  rejection, credential/password refusal, empty results, read-only/write
  rejection, pagination, filtered aggregation, and conversational follow-up.
  The higher-permission grouped aggregate then failed before query execution
  because both generative nodes returned Gemini HTTP 429 on `back 3`; this was
  a credential quota failure, not a permission or QueryPlan validation result.
- `Gemini Generative v2 - back 4` was rechecked without exporting or displaying
  its secret. Inactive smoke execution `410` returned HTTP 200 and exactly
  `OK`. Only the QueryPlan generator and chat model were switched to the
  managed `back 4` credential through n8n's supported export/import/publish
  path. Embeddings remain on the separate production embedding credential and
  automatic key cycling remains disabled. The persistent stop/start retained
  SQLite, encrypted credentials, workflow history, Redis data, mounts, and the
  pinned n8n version. After restart, n8n returned HTTP 200, Redis returned
  `PONG`, all three v2 workflows activated, both changed workflows had matching
  current/published versions, and the static contract suite passed. The grouped
  aggregate and two-user browser matrix were subsequently completed after the
  authoritative-date correction described below.

Browser acceptance procedure:

1. Sign in as the nominated higher-permission existing user and open
   `/app/ai-assistant-v2-uat` directly. Hard-refresh once (`Ctrl+Shift+R`) so
   the corrected Page JavaScript is loaded, then press `Reconnect`. Do not use
   the old floating widget.
2. Test a greeting, then allowed lists/counts/aggregates/grouping/pagination in
   English and Traditional Chinese. Record the exact permitted result expected
   from ERPNext.
3. Sign out completely, sign in as the nominated restricted existing user,
   open the same Page, and repeat the same questions. Restricted fields/rows
   must be denied or absent and results must match ERPNext list/report access.
4. Test a denied DocType, raw SQL/write request, credential/password request,
   injection attempt, oversized limit, empty result, and a normal follow-up
   question using Redis memory. `SELECT * FROM tabUser` must return only a
   refusal: no CCD rows, schema substitution, embedding, query-plan, or Frappe
   data execution is acceptable.
5. Report both usernames and pass/fail observations only; never send passwords,
   browser cookies, opaque tokens, or screenshots containing those values.

### Gemini plaintext location inventory

The operator's remembered multi-key collection is
`<REDACTED_LEGACY_KEY_SOURCE>`; it contains three
distinct plaintext Gemini keys. Two of those fingerprints also occur in legacy
workflow definitions and therefore in n8n SQLite/WAL and restricted workflow
exports. Repeated copies exist in historical test/upload scripts and output
files. The complete filename/count/fingerprint inventory is
`<REDACTED_LEGACY_KEY_INVENTORY>`; it contains no
secret values.

Do not add new keys to those files. n8n-managed `Google Gemini(PaLM) Api`
credentials remain the operational credential source. Reusing an existing
managed credential does not require recovering its value from disk. Every key
that appears in the plaintext inventory remains rotation-required after v2
acceptance.

### 2026-09-02 authoritative server-date correction

English and Traditional Chinese current-year questions both returned 2024
while Frappe's clock and site timezone correctly reported 2026. This was
missing prompt grounding, not a quota or timezone failure.

Authenticated session validation now returns a Frappe-generated
`date_context`: current date/year, exact current-year and current-month ranges,
and site timezone. Both n8n paths validate it before Gemini. Chat and QueryPlan
prompts use those values for direct date questions and relative terms such as
`this year`, `今年`, and `本年`; the server context overrides model training
dates and stale Redis memory. Browser-supplied dates and model guesses are not
accepted.

The backend and two workflow versions were deployed through the maintained
persistent procedures. Static contracts, n8n HTTP health, Redis health,
workflow activation, matching current/published versions, unchanged credential
roles, and a clean v2-only audit were verified. Full workflow rollback exports
remain restricted because untouched legacy workflow definitions may contain
historical plaintext credentials. The browser closure procedure required
reconnecting, confirming the Frappe year, and repeating the grouped
relative-date aggregate; the subsequent canary result below completed it.

The later production canary passed: the administrator's Traditional Chinese
`今年` grouped aggregate used 2026 and completed, while the direct English
current-year answer returned 2026. Combined with the earlier restricted-user
permission/safety results, the nominated two-user browser gate is complete.
The host-reboot resilience test remains separate and deferred.

### Operational-resilience result

The automatic nightly schema repair and a manual repair run completed against
the same four-DocType, thirteen-chunk schema-only catalog with zero drift. No
allowlisted schema or live provider credential was deliberately damaged for
this test.

Redis was migrated from an anonymous volume to the tracked Compose-named
`n8n_redis_data` volume with AOF and `appendfsync everysec`. A restricted RDB
was retained for rollback and was not copied to this public backup. All five
existing keys survived repeated Redis-only Compose recreation while n8n stayed
HTTP 200 and the three v2 workflows stayed active. Pre/post workflow content
was identical after removing n8n's volatile export counter, credential roles
were unchanged, and no raw export is published here.

The tracked `n8n/apply_redis_host_tuning.sh` helper persistently applies
`vm.overcommit_memory = 1`. A final recreation loaded all five keys without the
former warning. Container-recreation persistence is accepted. On 2026-09-02
the operator postponed the host reboot; it remains a separate
maintenance-window resilience test and does not block atomic widget cutover.
Deliberate provider-failure injection also remains a separate explicit-impact
decision.

The operations-source installer excludes runtime workflow stages, temporary
runtime-stage directories, and RDB files. Previously installed runtime
artifacts were moved to a private recoverable backup and are not published.

### Host-reboot checkpoint

The tracked `operations/reboot_persistence_check.sh` helper has separate
`capture`, `verify`, and `status` actions. It records a private baseline of
checksums and non-secret health values, requires a changed boot ID after reboot,
and verifies Redis, n8n, v2 workflow activation, Frappe, Apache, VPN/proxy,
mounts, images, policies, and tracked configuration. It never starts, restarts,
updates, or reboots a service.

The initial production capture passed every live application and storage check
but reported `REBOOT NOT READY`: nine long-lived Frappe containers use
`on-failure`, which does not restart them after a Docker daemon restart, and no
enabled Frappe boot service was detected. The persistent Frappe Compose policy
and existing post-boot recovery steps must be corrected and recaptured before
scheduling host-reboot acceptance. This deferred work is not a widget-cutover
blocker.

### Atomic lower-right widget cutover

On 2026-09-02 a restricted workflow/vhost baseline was captured, all three v2
workflows and the exact route were verified, and a fresh four-DocType,
thirteen-chunk repair completed successfully. The deployment helper now backs
up the existing widget and checksum-verifies the secure loader in both the Hksr
app source and the separate frontend-served asset filesystem.

The normal lower-right Desk widget was switched to the secure Frappe-bootstrap
loader without rebooting or recreating containers. The tracked, app-source,
and publicly served widget checksums matched. Apache routing, guest rejection,
forged-request safe failure, n8n/Redis health, and required container health
passed. A logged-in normal-Desk hard-refresh greeting/data smoke remains before
the old workflows are deactivated but retained for fourteen days.

The first normal-Desk screenshot still showed the legacy subtitle because an
already-open single-page Desk tab retained its pre-cutover JavaScript instance.
The server file was already v2. The deployment helper now versions the widget
URL in Frappe hooks, synchronizes it to runtimes, and preserves its existing
asset backups/checksums. After cache clear and graceful Gunicorn reload, the
effective hook and exact versioned public URL both resolved to the v2 loader.
One user hard refresh remains necessary to destroy the old in-memory instance.

### Authenticated visible-history retention

Redis Agent memory survived F5, but the n8n client originally rebuilt an empty
message view. Chat Trigger history loading remains disabled because n8n handles
that action before the workflow can validate the Frappe session. The secure
replacement loads visible messages through a separately authenticated Frappe
API.

Frappe derives an opaque user history ID with HMAC-SHA256 over the environment
site ID and the actual logged-in ERPNext user, using the site encryption key.
The browser never receives that ID and `chat_history` accepts no username,
session ID, or Redis key. The n8n Agent gets the same ID only from the already
validated Frappe response. This lets the same ERPNext account restore its
history after F5 or in another browser while isolating every other account.

The Frappe site needs a private n8n Redis URL supplied through environment/site
configuration. Do not publish Redis passwords. Visible history is normalized
to human/assistant text, bounded to 100 messages and 500,000 characters, and
expires eight hours after the most recent Agent turn. Fixed safety refusals
that occur before the Agent are not guaranteed to be stored.

Bootstrap can migrate a former session-key list when the authenticated mapping
still exists. The merge is bounded, deduplicated, and TTL-preserving. Any
ambiguous pre-upgrade list must be left to expire instead of assigning it to a
user speculatively. Verification requires guest history HTTP 403, empty direct
n8n trigger history, same-user F5/second-browser restoration, and cross-user
isolation.

### 2026-09-03 query-planner resilience correction

Visible history continued to work across F5. Two independent planner failures
then appeared: Gemini once returned an empty `{}` query plan, and another
request received a temporary Gemini HTTP 503 high-demand response. A restricted
user's refusal for a separate DocType remained the expected Frappe permission
result.

The permissioned-query workflow now handles only unambiguous simple counts
deterministically after schema retrieval. It accepts an exact DocType name from
the retrieved schema or a configured environment alias and constructs a fixed,
no-filter `count(*)` QueryPlanV1. The plan still executes through authenticated
Frappe under the real ERPNext user, so this path grants no DocType, field, or
row access and cannot run SQL or writes.

Other questions continue through Gemini. The planner request now supplies an
explicit structured-output schema requiring every QueryPlanV1 member, the local
parser rejects incomplete and unknown members, and transient planner failures
are retried no more than three times with 3-second waits. This follows Google's
structured-output guidance while retaining application validation:
<https://ai.google.dev/gemini-api/docs/structured-output>.

Only the permissioned-query workflow was exported, updated, imported,
published, and loaded through the persistent n8n stop/start procedure. Managed
generative, embedding, and Supabase credential roles did not change. Static
contracts, n8n/Redis health, permitted administrator-level and restricted-user
counts, and the restricted DocType denial were reverified. Raw workflow
exports, exact IDs, private paths, and production counts remain in restricted
operational evidence and are not included in this public backup.

### 2026-09-03 query-planner resilience correction

Visible history continued to work across F5. Two independent planner failures
then appeared: Gemini once returned an empty `{}` query plan, and another
request received a temporary Gemini HTTP 503 high-demand response. A restricted
user's refusal for a separate DocType remained the expected Frappe permission
result.

The permissioned-query workflow now handles only unambiguous simple counts
deterministically after schema retrieval. It accepts an exact DocType name from
the retrieved schema or a configured environment alias and constructs a fixed,
no-filter `count(*)` QueryPlanV1. The plan still executes through authenticated
Frappe under the real ERPNext user, so this path grants no DocType, field, or
row access and cannot run SQL or writes.

Other questions continue through Gemini. The planner request now supplies an
explicit structured-output schema requiring every QueryPlanV1 member, the local
parser rejects incomplete and unknown members, and transient planner failures
are retried no more than three times with 3-second waits. This follows Google's
structured-output guidance while retaining application validation:
<https://ai.google.dev/gemini-api/docs/structured-output>.

Only the permissioned-query workflow was exported, updated, imported,
published, and loaded through the persistent n8n stop/start procedure. Managed
generative, embedding, and Supabase credential roles did not change. Static
contracts, n8n/Redis health, permitted administrator-level and restricted-user
counts, and the restricted DocType denial were reverified. Raw workflow
exports, exact IDs, private paths, and production counts remain in restricted
operational evidence and are not included in this public backup.
