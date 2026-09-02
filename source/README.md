# Public-safe implementation source

This directory is a sanitized backup of the implemented ERPNext AI Assistant
v2 source. Production credential values were never part of this copy.
Environment-specific hostnames, webhook examples, namespaces, paths, and
container defaults were replaced with examples or required environment
variables before publication. Internal default DocType names and live workflow
and version UUIDs were also replaced with explicit examples.

## Contents

- `hksr_overlay/` — Frappe authentication, session validation, schema catalog,
  QueryPlanV1 validation/execution, synchronization, Settings DocTypes, secure
  per-user Redis history, Desk loader, acceptance Page, authoritative
  server-date context, and tests.
- `n8n/workflows/` — inactive generic templates for schema sync, permissioned
  query, and authenticated chat. Credential references remain `CONFIGURE_*`
  placeholders.
- `n8n/render_workflows.sh` — environment renderer for template placeholders.
- `n8n/docker-compose.v2.yml` — pinned n8n/Redis example using environment-
  supplied persistent paths, a named AOF-backed Redis volume, and host
  configuration.
- `n8n/apply_redis_host_tuning.sh` — idempotent status/apply helper for Redis's
  persistent `vm.overcommit_memory = 1` host prerequisite.
- `operations/reboot_persistence_check.sh` — read-only pre/post Ubuntu reboot
  checkpoint and verification helper; it never starts or changes services.
- `n8n/production.env.example` — sanitized non-secret production runtime
  example.
- `n8n/workflows.rendered.example.json` — inactive rendered example with
  example webhook/workflow IDs and `CONFIGURE_*` credential placeholders.
- `supabase/` — pgvector schema/RPC migrations and vector-schema detection.
- `apache/` — idempotent exact-route apply/verify/rollback helper using example
  host defaults.
- `deploy_shadow_backend.sh` — recoverable Frappe overlay deployment helper with
  generic public path defaults.
- `install_operations_source.sh` — documentation/runtime installation helper
  with generic public path defaults.
- `uat/` — UAT deployment and non-secret environment examples with sanitized
  defaults.
- `tests/` — static syntax and security-contract checks.

## Intentionally excluded

- raw `production.env` (a sanitized `.example` is included);
- raw `workflows.rendered.json` (a sanitized `.example.json` is included);
- n8n workflow exports and execution data;
- credential exports, IDs, fingerprints, or encrypted inventories;
- production webhook IDs, hostnames, Supabase project URLs, and backup paths;
- Python bytecode and runtime staging files; and
- Apache virtual-host copies, databases, logs, or container data.

## Before deployment

1. Review every example path, host, network, and container name for the target
   environment.
2. Create the Frappe, Gemini generative, Gemini embedding, Supabase, and Redis
   credentials in managed stores.
3. Render fresh workflow IDs and credential references per environment.
4. Keep the workflow templates inactive until bindings and negative tests pass.
5. Run `tests/test_static_contracts.sh`.
6. Follow the operations and acceptance documents in the repository root.

Visible history requires a private Redis URL in Frappe site configuration.
The browser must never receive the derived history key, and n8n Chat Trigger
history loading must stay disabled. Frappe's authenticated `chat_history` API
is the only supported browser history path.

Never deploy this public copy by blindly reusing example values.
