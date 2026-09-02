# Operations and credential handling

## Environment separation

Development, UAT, and production must use separate:

- Frappe sites and integration credentials;
- Supabase projects and service credentials;
- Gemini generative credentials;
- Gemini embedding credentials;
- webhook IDs and vector namespaces; and
- internal URLs and proxy targets.

Workflow templates should contain placeholders. Rendered environment workflows
must remain outside a public documentation repository.

## Credential roles

| Credential | Purpose |
| --- | --- |
| Frappe integration secret | Authenticates n8n schema-sync/status calls to Frappe. It is not a Gemini key or encryption key. |
| Gemini generative | Used only by chat generation and QueryPlan generation. |
| Gemini embedding | Used only for 768-dimensional schema indexing and retrieval. |
| Supabase service | Accesses only that environment's isolated schema-vector project. |
| Redis | Stores bounded chat memory keyed by the opaque non-PII session ID. |
| n8n encryption key | Encrypts n8n-managed credentials at rest and must remain stable across restarts. |

Never place these values in workflow JSON, documentation, shell history, source
files, or screenshots.

## Manual Gemini credential switch

Automatic key cycling is intentionally prohibited. If a generative credential
is quota-limited:

1. Create separate managed credentials in n8n without pasting values into a
   workflow export.
2. Test each candidate through a temporary inactive diagnostic workflow using a
   minimal request and record only the credential name and response status.
3. Select one working credential explicitly.
4. Change only the chat-generation and QueryPlan-generation nodes.
5. Leave the embedding node on its dedicated embedding credential.
6. Export current and published definitions before and after the change.
7. Confirm node count, connections, security gates, credential roles, and
   normalized workflow structure are unchanged.
8. Publish each current workflow and restart through the persistent n8n
   stop/start procedure.
9. Confirm activation in startup logs and keep the diagnostic workflow inactive.

n8n's CLI import can deactivate an updated workflow. Publishing the current
version and restarting the running process are required before considering the
switch complete.

## Schema synchronization

The sync sequence is:

1. Authenticate the caller.
2. Fetch a complete schema-only catalog.
3. Compare deterministic hashes with the current environment namespace.
4. Embed only new or changed chunks at 768 dimensions.
5. Require a complete embedding batch.
6. Upsert the complete changed batch atomically.
7. Delete stale chunks only after all previous stages succeed.
8. Record bounded status and drift telemetry in Frappe.

On any partial failure, preserve the last good index and report the failure.

## Authoritative date context

Relative-date behavior must be grounded in the authenticated Frappe server,
not the browser clock or Gemini's training date. Session validation supplies
the current date/year, exact year/month boundaries, and site timezone. Both
chat and query gates validate those values before a model call; invalid or
missing context is a hard workflow error.

After any date-contract change, publish both query and chat workflows, restart
through the persistent procedure, verify matching current/published versions,
and test direct current-year plus English/Chinese relative-date questions.
Keep complete n8n exports restricted because untouched legacy workflows may
contain historical plaintext credentials. Public backups may include only
sanitized templates and documentation.

## Restart and persistence

Use the maintained restart script for the deployed environment. It performs
container stop/start and retains:

- the n8n SQLite database;
- n8n-managed credentials and encryption state;
- workflow definitions and history;
- Redis data on its configured volume;
- mounted proxy/error patches; and
- the pinned n8n image.

Do not edit n8n SQLite directly. Do not rely on unmounted container-layer edits;
they are lost on recreation.

Redis chat memory must use the Compose-named `n8n_redis_data` volume mounted at
`/data`, with AOF enabled and `appendfsync everysec`. Run
`source/n8n/apply_redis_host_tuning.sh status` to check the host. Its root-only
`apply` action atomically persists and applies `vm.overcommit_memory = 1`; the
helper does not restart either container.

When migrating existing Redis data, retain a restricted RDB and the former
volume until the named volume passes an independent recreation. Verify the
expected key count, AOF load/write health, n8n HTTP health, and all three v2
workflow activations after recreation. Never commit the RDB or raw workflow
exports.

## Deferred host-reboot checkpoint

The host-reboot test was explicitly postponed on 2026-09-02. It verifies
recovery after a real power outage or Ubuntu restart; it is not required for
normal assistant operation, browser acceptance, or atomic widget cutover.

Run `source/operations/reboot_persistence_check.sh capture` before approving a
host reboot. The script writes a private baseline of checksums and non-secret
health metadata. It checks reboot-capable restart policies as well as Redis,
n8n, Frappe, Apache, VPN/proxy, persistent mounts, and tracked configuration.
It never starts, restarts, updates, or reboots a service.

After the Ubuntu host is rebooted by an operator, run the script with `verify`.
It requires a changed boot ID and compares the recovered system with the saved
baseline. Do not proceed when `capture` reports a blocker.

The production precheck on 2026-09-02 found nine long-lived Frappe containers
using `on-failure` and no enabled Frappe boot service. Docker explicitly states
that `on-failure` does not restart a container when the daemon restarts.
[Docker restart-policy documentation](https://docs.docker.com/engine/containers/start-containers-automatically/)
Therefore the host is not reboot-ready. Before a future maintenance-window
reboot test, persist a reboot-capable policy in the Frappe Compose source, add
the required idempotent post-boot recovery for existing nginx/SSHFS/host-map
and proxy steps, apply it without changing volumes or one-shot setup services,
and recapture until the script reports zero failures. This deferred work does
not block the v2 widget cutover.

## Cutover

Current checkpoint (2026-09-02): steps 1-6 are complete. The secure loader is
served by the normal lower-right Desk widget and server-side post-change health
checks passed. Complete step 7 from a normal logged-in Desk page before
deactivating the legacy workflows.

The Desk loader URL must be versioned during cutover. Frappe Desk preserves
JavaScript already running in an open tab while navigating between routes, so
replacing an unversioned server file does not replace that instance. After
deploying the versioned hook, clear site cache, gracefully reload Gunicorn, and
have the user hard-refresh once. Confirm the permission-aware v2 subtitle
before sending smoke questions.

After the two-user acceptance matrix passes:

1. Capture current workflow and proxy backups with checksums.
2. Confirm all three v2 workflows are published and healthy.
3. Apply the exact tested Apache route.
4. Install the secure window-mode loader for the normal lower-right Desk widget.
5. Switch Frappe bootstrap to the v2 webhook atomically.
6. Monitor Apache, Frappe, n8n, Redis, VPN/proxy, and schema-sync status.
7. Rotate exposed legacy credentials after acceptance.
8. Deactivate, but do not delete, the legacy workflows for 14 days.

Do not reactivate the insecure raw-SQL path during rollout or rollback.

## Rollback

Rollback disables v2, restores the saved bootstrap/proxy configuration, and
keeps the secure v2 workflows available for diagnosis. It never restores the
legacy shared-account raw-SQL execution path.
