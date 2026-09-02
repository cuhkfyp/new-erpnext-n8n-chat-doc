## ERPNext AI Assistant v2 UAT isolation

> Public-backup note: this full appendix uses placeholders for production
> hosts, project endpoints, identifiers, private paths, and internal business
> schema names. It contains no credential values.

UAT must render the workflow templates with new UAT-only chat/sync IDs and use
a dedicated Supabase project plus UAT-only Frappe, Gemini generative, Gemini
embedding, Supabase service, Redis, and VPN credentials. Do not import the
production rendered v2 workflow file or copy production n8n SQLite/encryption
material.

Before deployment, configure these UAT environment variables in the n8n `.env`:

```text
AI_ENVIRONMENT=uat
AI_FRAPPE_BASE_URL=http://<FRAPPE_INTERNAL_HOST>:8080
AI_FRAPPE_SITE_HOST=frontend
AI_SUPABASE_URL=https://<uat-project>.supabase.co
AI_EMBEDDING_MODEL=gemini-embedding-2
AI_EMBEDDING_DIMENSIONS=768
AI_GENERATIVE_MODEL=<approved-uat-model>
AI_SCHEMA_MATCH_COUNT=8
```

Run `supabase/detect_vector_schema.sql`, then apply the matching `extensions`
or `public` 768-dimensional migration. Render/import the three workflows
inactive, bind UAT credentials, install/migrate the Hksr backend, and leave
Settings disabled. Use a UAT higher-permission and restricted existing user for
the full matrix in the main runbook.

The Hksr deployment must install the same AI module and hook state into the
backend, short queue, long queue, and scheduler containers (or use a verified
shared application mount). A backend-only container layer is insufficient:
post-migrate/nightly jobs execute in workers. Confirm matching runtime files,
restart with the environment's persistent stop/start procedure, then exercise
the exact enqueue-after-commit sync path before browser acceptance.

`Deploy_UAT.sh` stages the v2 source/templates but filters production v2
definitions from the generic workflow export. Render fresh UAT-only chat and
sync IDs from the staged templates; do not reuse the production rendered file.

The UAT Apache/nginx route must use the UAT chat ID and local UAT n8n target.
It must never point at production. After acceptance, repeat the same process in
production with freshly rendered IDs and credentials; do not promote stored
credential material between environments.

For the current production browser-acceptance canary, logged-in nominated users
open `https://<ERP_PUBLIC_HOST>/app/ai-assistant-v2-uat`. The Page exists so
browser permission testing does not require the broken legacy widget or a
direct n8n call. Direct calls are a negative test and must stop before Gemini.
Sign out completely between the higher-permission and restricted user runs;
never share passwords, cookies, opaque bootstrap values, or the same
`Administrator` identity. Frappe realtime dialogs target a username, so a bulk
operation performed in another browser using a shared account can surface in
the acceptance tab. Such a dialog is not evidence that the read-only v2
assistant performed the operation, and the Page must not hide real deletion
notifications; correlate it with Frappe access/worker logs.

The bundled n8n `2.21.7` Chat Trigger emits the chat POST body but not HTTP
headers to downstream nodes. UAT must therefore use the tracked Page/widget
metadata transport: `aiSessionToken` plus the matching opaque `aiSessionId`.
Never add a username, cookie/SID, or CSRF value to that metadata. Keep
trigger-level `loadPreviousSession` disabled because that action runs before
workflow authentication. Configure Frappe's private Redis connection, key Agent
memory from the validated `history_id`, and load visible messages only through
the authenticated `hksr.ai_assistant.api.chat_history` endpoint. That endpoint
takes no user or history-key argument.

After each nominated user creates at least one safe conversation turn, test
all of the following before acceptance:

- F5 restores that user's visible human and assistant messages;
- a second browser logged in as the same ERPNext user restores the same
  messages while their Redis TTL remains;
- signing in as the other nominated user does not show the first user's
  transcript;
- guest access to `chat_history` is HTTP 403;
- a direct n8n `loadPreviousSession` request returns no stored messages; and
- Redis/n8n stop-start retains the user-scoped lists and remaining TTL.

Safety-gate refusals occur before Agent memory and are not promised as durable
history. Normal greetings, data questions, tool results, and follow-ups that
reach the Agent are retained for eight hours after the most recent turn.

The acceptance Page includes scoped grid-shell and tail-follow corrections.
Preserve both the tracked Page CSS and JavaScript when promoting to
UAT/production: header, body, and composer must remain explicit grid rows; the
body must be the only scrollable item; messages must remain normal block flow
without a generated flex spacer; a fixed trailing block plus ordinary list
padding must provide visible clearance below the last message; and the Page's bounded
`MutationObserver` must move the body to its tail as n8n adds or streams
messages. Any newly added `.chat-message` (user, typing, or assistant) forces a
post-layout tail update so a passive scroll event cannot hide the newest reply.
That force is stored separately until the final animation frame; a streaming
text mutation or intervening scroll event must not clear it before the body is
set to its maximum scroll position. The Page must also override n8n's inherited
body `height: 100%`: assign header/body/footer to explicit grid rows and keep
the body's height/block-size `auto`, otherwise the body extends underneath the
composer and its apparent maximum scroll position still hides the final reply.
The n8n client can create a typing/assistant message shell before inserting or
replacing its inner Markdown. The observer must therefore also preserve the
pending tail follow when a mutation target is inside an existing
`.chat-message`; detecting only newly added message shells leaves the final
content-height increase partly below the viewport.
The trailing `::after` block is intentionally different from the removed
`::before` flex spacer: it has a fixed height after all messages and therefore
contributes to `scrollHeight` without consuming the body's remaining space.
It stops following when a user scrolls upward and no new message is being
appended, and cleans up on reconnect/unmount. These presentation controls do
not change authentication.

Raw SQL, writes, credential/secret requests, and injection-shaped input must be
rejected by the deterministic chat gate after the Frappe session check and
before Gemini. The permissioned-query workflow has a second gate before
embedding. In particular, `SELECT * FROM tabUser` must produce only the fixed
safe refusal; returning data from `Example Master` or any nearest schema is a test
failure even though `tabUser` itself was not read. A naturally phrased allowed
CCD question must still proceed normally.

Do not classify a normal business-language alias as a denied DocType. The
phrase `example client database`, translated labels, and abbreviations may map
to the matching retrieved allowlisted schema such as `Example Master`. The removed
`__NOT_ALLOWLISTED__` planner sentinel incorrectly rejected this valid case.
Frappe's allowlist and permission checks remain authoritative after plan
generation.

Distinguish safety/permission failures from quota failures during UAT. On
2026-09-01, the original production generative credential reached Gemini's
20-request free-tier quota and a later general prompt failed with HTTP 429.
The separately managed `Gemini Generative v2 - back 2` credential passed a
point-in-time HTTP 200 probe and was manually bound to both v2 generative
nodes. During restricted-user acceptance on 2026-09-02, Frappe correctly
rejected an `hksr_rb` plan with HTTP 403, then the chat model returned HTTP 429
because `back 2` had reached the same 20-request daily quota. `back 3` was
re-probed and manually loaded, then later returned HTTP 429 during the
higher-permission grouped-aggregate test. `back 4` was re-probed without
exposing its secret; inactive smoke execution `410` returned HTTP 200 and
exactly `OK`. Both v2 generative nodes are now explicitly bound to `back 4`,
current and published versions match, and the persistent restart loaded them.
The browser matrix was subsequently completed with `back 4` after the
authoritative-date correction. Diagnose any later failure with an explicit
managed-credential change; do not implement automatic key cycling. The
embedding credential was not changed.

This full-page launcher is temporary. The nominated two-user matrix passed and
the 2026-09-02 atomic production cutover installed the same secure bootstrap
and opaque-token contract through the tracked `mode: "window"` loader,
restoring the normal lower-right Desk presentation. Retain this Page only for
diagnosis until post-cutover browser smoke passes. Do not point the widget back
to the legacy raw-SQL workflow.

The normal-Desk retest must use a hard refresh after the cache-versioned hook is
deployed. Route navigation alone can retain the pre-cutover widget inside the
already-running single-page Desk. Verify the v2 permission-aware subtitle
before sending the greeting/data smoke questions.

### Relative-date UAT regression

Confirm authenticated Frappe validation returns a consistent date, year,
year/month boundaries, and expected site timezone. Missing or inconsistent
context must stop both workflow paths before Gemini.

For both nominated users, reconnect and ask `What's the current year?` and
`今年年份是什麼？`, then run equivalent permitted `this year` and `今年`
aggregates. Repeat once in a conversation whose Redis memory contains a stale
year. Direct answers and QueryPlan date filters must follow Frappe's context;
user permissions must still produce the expected differing results or denial.
A stale model year is a failed regression, not a quota or timezone result.

Production canary result on 2026-09-02: the administrator's Traditional
Chinese grouped `今年` query used 2026 and completed; the direct English
current-year answer was also 2026. Together with the earlier restricted-user
permission and safety matrix, the nominated two-user browser acceptance passed.
The operational/resilience checklist remains separate from this browser gate.

### Operational-resilience result

The automatic and manual schema repair paths completed against the same
four-DocType, thirteen-chunk catalog with zero drift. Redis was migrated to the
tracked named AOF-backed volume, all five existing keys survived repeated
service recreation, n8n remained healthy, and all v2 workflows remained active
with unchanged normalized definitions and credential roles. The Redis host
prerequisite is persistently set to `vm.overcommit_memory = 1`, and the final
recreation loaded without its earlier warning.

Container-recreation persistence is accepted. The operator postponed the host
reboot on 2026-09-02; it remains a separate maintenance-window resilience test
and does not block atomic widget cutover. Deliberate production
provider-failure injection is also a separate explicit-impact test.

### Host-reboot precheck

The tracked read-only reboot checker passed the current application, storage,
workflow, proxy, and configuration checks but reported `REBOOT NOT READY`.
Nine long-lived Frappe containers use Docker's `on-failure` policy, and no
enabled Frappe boot service was found. Correct the persistent Frappe Compose
policy and required post-boot recovery steps, then recapture with zero failures
before future reboot UAT. This deferred work is not a widget-cutover blocker.
