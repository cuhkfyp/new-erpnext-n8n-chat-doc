## ERPNext AI Assistant v2

> Public-backup note: this full appendix uses placeholders for environment-
> specific identifiers and internal business schema names. It contains no
> credential values or rendered production workflow data.

The permission-aware implementation, configuration contract, test matrix,
cutover, and rollback are maintained in
`ai-assistant-v2/IMPLEMENTATION_AND_OPERATIONS.md`.

Operational changes from the legacy widget:

- n8n is pinned to `docker.n8n.io/n8nio/n8n:2.21.7`;
- the existing `/home/node/.n8n` volume, SQLite database, credential encryption,
  webhook error patch, and `surfshark-vpn:8888` proxy remain in place;
- three v2 workflows were imported inactive and save neither successful nor
  failed execution payloads because chat request metadata contains the
  short-lived opaque bearer. It never contains the Frappe cookie/SID, username,
  or CSRF value. During the isolated production canary, chat and permissioned
  query are published. The tested authenticated schema-only workflow is also
  published for automatic post-migrate/nightly synchronization;
- Redis memory is explicitly keyed by Frappe's opaque non-PII session ID, and
  schema-sync transport/error outputs record bounded failure telemetry without
  entering the stale-deletion branch. Trigger-level visible-history reload is
  disabled because Chat Trigger handles it before workflow authentication;
  agent memory still serves normal same-session follow-ups;
- Gemini generative, Gemini embedding, Frappe sync, Supabase, and Redis
  credentials are bound through n8n credential storage, not workflow JSON;
- the exact production Apache route maps one v2 chat ID for the isolated
  `/app/ai-assistant-v2-uat` Page; there is no broad `/n8n-webhook/` production
  proxy and the default widget remains unchanged;
- never troubleshoot v2 by activating the legacy raw-SQL workflow.

Routine `stop/start` retains current mounts and data. Compose recreation now
uses the pinned tested image. Before changing the pin, verify the mounted
`webhook-helpers.js` against the new image and complete the entire v2 acceptance
matrix.

Current production shadow status (2026-09-01): the corrected `public`-pgvector
Supabase migration completed, and `Supabase Schema RAG v2 - production` is
stored and bound to all four Supabase nodes. Redis is also bound.
Frappe's non-secret site/webhook/sync identifiers are staged with the master
switch enabled only for browser acceptance. `Frappe AI Assistant Sync v2 - production` is bound to all
three authenticated sync nodes. Managed Gemini generative and dedicated
production embedding credentials are bound to all four model nodes, and the live export
contains no `CONFIGURE_*` placeholders. The pinned production Compose runtime
has been recreated with its persistent n8n/Redis data intact. The schema-only
index now has 11 matching chunks for 3 allowlisted DocTypes; an immediate
repeat sync recorded `Success`, changed `0`, deleted `0`. The first-run empty
hash response is preserved with `alwaysOutputData`, and strict HTTP response
nodes use proxy-safe autodetection before validation. Chat and permissioned
query are published on the one exact authenticated canary route; authenticated
schema-only sync is published for post-migrate/nightly repair. Use
`/app/ai-assistant-v2-uat` for the nominated
two-user matrix, not the old floating widget. After the 2026-09-01 canary fix,
hard-refresh that Page once: n8n `2.21.7` Chat Trigger outputs the POST body but
not request headers, so the Page now sends only the opaque token/session via
supported metadata. Frappe validates that bearer against the exact active
issuing session before Gemini and again before query execution. A forged-token
probe stopped with Frappe HTTP 401 before the agent. Audit snapshot:
`baseline/2026-09-01/n8n-workflows-after-canary-auth-fix.json`, SHA-256
`f12ac30e2dc8fb1464af606bde1de68b36520d27afeba8d9b26fa6caeabfdbe9`.
The final automatic-sync export is
`baseline/2026-09-01/n8n-workflows-after-automatic-sync-cutover.json`, SHA-256
`d6c05b8d11d4a8318c746c66ae4b051587b07130a6f5e0508ae3ec44d4c468af`;
all three v2 workflows are active and the repair sync recorded `Success`, 3
DocTypes, 11 chunks, changed `0`, deleted `0`.

Frappe runtime note: `deploy_shadow_backend.sh backend-only` now synchronizes
the AI module and hook state to backend, short queue, long queue, and scheduler
containers, with recoverable backups and compilation checks. This is necessary
on the current container layout because their writable image layers are not
shared. After deployment, use the supplied persistent ERPNext stop/start
script. The exact enqueue-after-commit path was verified through the short
queue and recorded the same successful 3-DocType/11-chunk result.

Credential distinction: the 32-or-more-character Frappe Integration Secret
belongs only in `AI Assistant Settings` and the matching n8n Header Auth
credential for schema-sync APIs. It is not a Gemini key, Supabase encryption
key, browser token, or `N8N_ENCRYPTION_KEY`. Normal chat receives an ephemeral
token/session automatically from authenticated Frappe bootstrap; an
uncredentialed or forged webhook request is expected to fail before Gemini.

Canary UI note: n8n executions `292`/`293` completed the live data question
successfully while the browser showed only the top edge of the reply. The
DevTools then confirmed the bot bubble had its full height but extended below
the body underneath the composer. The tracked acceptance Page therefore owns
explicit header/body/footer grid rows, a message-tail gutter, and scoped
tail-follow behavior for the body's DOM mutations. Preserve that Page JS/CSS
together; this is a browser presentation correction, not a workflow or
authentication change.

A second DevTools capture showed the temporary generated flex spacer consuming
the remaining message-list height and pushing the bubble back toward the
footer. The final Page removes that spacer, uses top-origin block flow, and
reserves ordinary list padding plus a fixed trailing block at the scroll tail.
Unlike the removed flex spacer, this `::after` block follows every message and
cannot consume the body's remaining height. Its observer now forces a post-layout tail update for every newly
added `.chat-message`, including typing and assistant bubbles, closing the
long-conversation race in which the newest answer could remain below the
composer. The force is a pending latch consumed only in the final animation
frame; intervening scroll or streaming mutations cannot clear it early. The
remaining root cause was n8n's inherited `.chat-body { height: 100% }`, which
made the middle grid item extend underneath the composer. The tracked Page now
resets body height/block-size to `auto !important`, assigns all three explicit
grid rows, and keeps the footer above the scroll body.

The n8n renderer may append a small typing/assistant shell and populate its
inner Markdown later. That second mutation can increase the existing bubble's
height without adding another `.chat-message`. The Page observer therefore
preserves tail-follow for mutations whose target is inside a message while the
user is already following the tail (or a forced tail update is pending). This
keeps the completed/error text visible without overriding a deliberate manual
scroll upward.

Input safety is also deterministic rather than prompt-only. After the real
Frappe session is validated, the chat workflow rejects raw SQL, write intent,
credential/secret requests, and injection shapes before the Agent/Gemini. The
permissioned-query workflow repeats this gate before embedding and explicitly
forbids nearest-schema substitution. The earlier response to
`SELECT * FROM tabUser` was incorrect: it did not read `tabUser`, but it
returned unrelated allowlisted `Example Master` rows. The corrected behavior is a
fixed refusal with no embedding or ERPNext data query.

The first permitted count after that change exposed an overly broad semantic
rule, not an input-gate block: `example client database` was converted to the
temporary `__NOT_ALLOWLISTED__` sentinel and Frappe correctly returned 403.
That sentinel has been removed. The planner again resolves natural business
names, translations, and abbreviations against the retrieved allowlisted
schema while Frappe remains the final allowlist/permission authority.

A separate subsequent general prompt failed because the original managed
production Gemini generative credential reached its 20-request free-tier quota
(HTTP 429). On 2026-09-01 the operator's four new managed generative credentials
were checked without exposing their values: `back 2`, `back 3`, and `back 4`
returned valid Gemini responses, while `back 1` was rate-limited/overloaded.
`back 2` was initially bound to the chat and query-plan generation nodes. On
2026-09-02 it reached the 20-request daily quota during restricted-user
acceptance. `back 3` was re-probed, returned HTTP 200, and was manually loaded;
it later returned HTTP 429 during the higher-permission grouped-aggregate test.
`back 4` was then re-probed through the inactive managed-credential smoke
workflow. Execution `410` returned HTTP 200 with exactly `OK`, so only the
query-plan and chat generative nodes were explicitly switched to `back 4`,
imported, published, and loaded with the supplied persistent n8n restart
procedure. The embedding nodes remain on `Gemini Embedding v2 - production`.
This remains a deliberate manual switch, not automatic key cycling. Both
current workflows match their published versions and activated after
stop/start; n8n health and Redis returned HTTP 200 and `PONG`. Audit exports
and checksums are recorded in `ai-assistant-v2/IMPLEMENTATION_AND_OPERATIONS.md`.

The acceptance Page is temporary. After the nominated higher-permission and
restricted-user tests pass, `deploy_shadow_backend.sh cutover-widget` installs
the tracked secure `mode: "window"` loader for the normal lower-right Desk
widget. This is a v2 cutover, not a return to the legacy raw-SQL workflow.

Frappe's standard `frappe.desk.reportview.delete_bulk` publishes a successful
bulk-delete message over realtime to the username that initiated the job. If
multiple browsers share `Administrator`, a deletion started from an unrelated
List view can therefore appear above the acceptance Page. Production logs on
2026-09-01 traced the observed dialog to `Administrator` bulk deletes for
`AI Training Log`, `AI Session History`, and `Chat`, not to the read-only v2
workflows. Do not suppress the notification; use distinct named acceptance
accounts and correlate future occurrences with Frappe access/worker logs.

### Authoritative relative-date context

The authenticated Frappe session response supplies `date_context` with current
date/year, exact year/month boundaries, and site timezone. Validate this
structure in both gates before any model call. Inject it dynamically into the
Agent and QueryPlan prompts, explicitly overriding model training dates and
prior Redis memory. `this year`, `current year`, `今年`, and `本年` must use the
server's exact current-year range; never fall back to a browser clock or model
guess.

After a contract change, publish both chat/query workflows, use the persistent
n8n restart, and verify activation plus matching current/published versions.
Keep full workflow exports restricted because legacy definitions can contain
plaintext historical credentials; only sanitized templates belong in the
public source backup.

### Redis recreation persistence

Use the Compose-named `n8n_redis_data` volume at `/data`, enable AOF with
`appendfsync everysec`, and check the host with
`n8n/apply_redis_host_tuning.sh status`. Its root-only `apply` action
persistently sets `vm.overcommit_memory = 1` and does not restart containers.

For an existing deployment, save and retain a restricted recovery RDB before
migration. Do not allow an empty Redis instance to create the first AOF before
the old keys are seeded and verified. Retain the former volume until the named
volume passes independent recreation. Verify expected key count, healthy AOF
load/write status, n8n HTTP health, and all v2 workflow activations. Raw Redis
data and workflow exports never belong in the public repository.

The 2026-09-02 production run preserved all five existing keys through repeated
named-volume recreation and a final post-tuning recreation; normalized v2
workflow content and credential roles remained unchanged.

### Host reboot procedure

Run `operations/reboot_persistence_check.sh capture` before approving a reboot.
It creates a private baseline and refuses readiness if required containers lack
a daemon-restart-capable policy. After an operator reboots Ubuntu, run `verify`;
the script requires a changed boot ID and checks the saved application,
storage, workflow, proxy, mount, and configuration invariants. It never starts
or modifies services.

The first production capture is blocked because nine long-lived Frappe
containers use `on-failure`, and no enabled Frappe boot unit was detected.
Persist a reboot-capable policy in the Frappe Compose source and capture again
before the maintenance window.
