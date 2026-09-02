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
workflow authentication; the Agent's Redis memory remains enabled for normal
same-session follow-up questions.

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
Continue browser acceptance with `back 4`. Diagnose any later failure and
perform another explicit managed-credential change; do not implement automatic
key cycling. The embedding credential was not changed.

This full-page launcher is temporary. After the nominated two-user matrix
passes, the atomic production cutover installs the same secure bootstrap and
opaque-token contract through the tracked `mode: "window"` loader, restoring
the normal lower-right Desk presentation. Do not point that widget back to the
legacy raw-SQL workflow.
