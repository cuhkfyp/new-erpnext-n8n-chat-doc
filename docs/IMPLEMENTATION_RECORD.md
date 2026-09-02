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

The authenticated backend exposes five narrow APIs:

- `bootstrap` returns an environment-specific webhook URL, a short-lived opaque
  token bound to the real browser session, and a non-PII chat session ID;
- `chat_history` accepts no username, session ID, or history key and returns
  only the current authenticated ERPNext user's bounded human/assistant Redis
  transcript;
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
   model call, keeps Redis memory under a Frappe-derived opaque user history
   ID, and exposes the permissioned query workflow as its only ERPNext data
   tool.

Deterministic gates reject raw SQL, write intent, credential or secret requests,
and common injection shapes after session validation but before Gemini. A
second equivalent gate exists in the query workflow before embedding.

Frappe session validation also returns an authoritative server date context:
current date/year, exact current-year and current-month ranges, and the site
timezone. Both workflow gates validate it before Gemini. The Agent and
QueryPlan prompts use it for direct date questions and multilingual relative
terms such as `this year`, `今年`, and `本年`; it explicitly overrides model
training dates and stale Redis conversation memory. The browser clock is never
trusted and Gemini is never asked to guess the current year.

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

## Authenticated visible history

The lower-right widget now restores visible messages after F5 and in another
browser logged in as the same ERPNext user. Frappe derives an opaque `u2_`
Redis key with HMAC-SHA256 over the site ID and authenticated user, using the
site encryption key. The browser never receives this key and cannot submit a
username or history identity.

The validated n8n workflow receives `history_id` only after the opaque browser
token has been checked by Frappe, and the Agent memory node uses that value as
its Redis session key. The separately authenticated `chat_history` API derives
the same key from the active Frappe login and returns only normalized human and
assistant text. History is bounded to 100 visible messages and 500,000
characters and expires eight hours after the most recent Agent turn.

n8n Chat Trigger `loadPreviousSession` remains disabled because it handles
history before workflow authentication. A direct trigger history request
therefore returns no stored messages. Guest Frappe history requests return
HTTP 403. The nominated higher-permission and restricted accounts resolve to
distinct history keys, so neither can select or retrieve the other's
transcript.

Bootstrap can merge a former browser-session list into the user key when the
old authenticated session mapping is still available. The merge is bounded,
deduplicated, TTL-preserving, and removes only the migrated source key. An
ambiguous pre-upgrade list must expire rather than be assigned speculatively.
Deterministic safety refusals occur before Agent memory and are not guaranteed
to appear in restored history.

## Gemini credential follow-up

The initial generative credential reached its free-tier request quota. Four new
n8n-managed generative credentials were checked through one temporary inactive
diagnostic workflow without exporting or printing their values.

- One new credential was rate-limited or overloaded at test time.
- Three returned valid Gemini responses.
- `back 2` was initially selected for both chat generation and QueryPlan
  generation. After it reached the 20-request daily quota during restricted
  acceptance on 2026-09-02, `back 3` was re-probed successfully and explicitly
  selected for those same two nodes. When `back 3` later returned HTTP 429
  during the higher-permission grouped aggregate, `back 4` was re-probed by
  inactive smoke execution `410`, returned HTTP 200 with exactly `OK`, and was
  explicitly selected for those same two nodes.
- The separate production embedding credential was not changed.

These were manual switches, not a rotating key pool. Both updated workflows
were republished and loaded through the persistent n8n restart procedure.
Current and published definitions matched, and each switch changed only the
managed credential reference on the two generative nodes.

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
- Frappe's live date helper returned internally consistent current date/year,
  month/year boundaries, and site timezone; both live workflow versions contain
  the validated authoritative-date contract.

The nominated higher-permission and restricted-user browser matrix is complete,
including the corrected bilingual relative-date behavior. The normal schema
repair and container-recreation persistence gates are also complete: Redis was
migrated from an anonymous volume to a tracked named AOF-backed volume, all five
keys survived repeated recreation, n8n remained healthy, and normalized v2
workflow definitions and credential roles did not change. The host now
persistently applies `vm.overcommit_memory = 1` through an idempotent tracked
helper. The host-reboot/provider-failure tests are deferred maintenance-window
work and are not cutover blockers.

A tracked read-only `capture`/`verify` script now preserves the pre-reboot
baseline and compares the recovered host without exporting workflow or
credential data. Its initial capture found a pre-existing blocker: all nine
long-lived Frappe containers use Docker's `on-failure` policy, which does not
restart them when the daemon restarts, and no enabled Frappe boot service was
present. All current health checks passed, but reboot readiness remains false
until the persistent Frappe Compose policy is corrected and recaptured.

## Atomic widget cutover

On 2026-09-02 the secure loader was installed for the normal lower-right Desk
widget. Preflight captured restricted workflow/vhost backups, confirmed all
three v2 workflows active, verified the exact route, and completed a fresh
four-DocType, thirteen-chunk schema repair.

The deployment helper was updated to back up and checksum-verify both the Hksr
app source and this Docker layout's separate frontend-served asset. The public
asset matched the tracked source and retained Frappe bootstrap, opaque
token/session metadata, window mode, and disabled unauthenticated history
loading. Post-change Apache, guest/forged rejection, n8n, Redis, VPN, and Frappe
health checks passed. A logged-in normal-Desk hard-refresh smoke remains before
the old workflows are deactivated but retained for fourteen days.

The first normal-Desk screenshot was still an old in-memory widget retained
across single-page route navigation. The deployment helper now versions the
widget URL in Frappe hooks as well as backing up/checking both asset copies.
After site-cache clear and graceful Gunicorn reload, the effective hook and
versioned public response both resolved to v2. Users must hard-refresh once to
destroy a widget that was already running before cutover.
