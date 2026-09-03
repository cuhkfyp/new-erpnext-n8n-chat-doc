#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

python3 -m compileall -q "${ROOT_DIR}/hksr_overlay/hksr"

while IFS= read -r json_file; do
  jq empty "${json_file}"
done < <(rg --files "${ROOT_DIR}" -g '*.json')

if rg -n --glob '*.json' --glob '*.py' --glob '*.js' \
  '(AIza[0-9A-Za-z_-]{30,}|service_role[^A-Za-z0-9]+[A-Za-z0-9._-]{20,}|mysql://[^[:space:]]+:[^[:space:]]+@)' \
  "${ROOT_DIR}"; then
  echo "A source file appears to contain a plaintext credential." >&2
  exit 10
fi

for workflow in "${ROOT_DIR}"/n8n/workflows/*.json; do
  jq -e 'length == 1 and .[0].active == false and (.[] | .settings.saveDataSuccessExecution == "none" and .settings.saveDataErrorExecution == "none")' \
    "${workflow}" >/dev/null
done

jq -e '
  .[0] as $workflow
  | ($workflow.nodes | map(.name) | index("Validate Frappe Session Before Gemini") < index("Gate Unsafe Chat Request"))
  and ($workflow.nodes | map(.name) | index("Gate Unsafe Chat Request") < index("Permission-aware ERPNext Agent"))
  and ($workflow.nodes[] | select(.name == "Gate Unsafe Chat Request")
      | .parameters.jsCode
        | contains("rawSql")
          and contains("sensitiveRequest")
          and contains("injectionAttempt")
          and contains("date_context")
          and contains("current_year_start")
          and contains("invalid authoritative date context"))
  and ($workflow.nodes[] | select(.name == "Permission-aware ERPNext Agent")
      | .parameters.options.systemMessage
        | contains("AUTHORITATIVE ERPNext date context")
          and contains("prior conversation memory")
          and contains("今年"))
  and ($workflow.connections["Validate Frappe Session Before Gemini"].main[0][0].node == "Gate Unsafe Chat Request")
  and ($workflow.connections["Unsafe Chat Request?"].main[0][0].node == "Return Safe Rejection")
  and ($workflow.connections["Unsafe Chat Request?"].main[1][0].node == "Permission-aware ERPNext Agent")
' \
  "${ROOT_DIR}/n8n/workflows/erpnext-ai-chat-assistant-v2.json" >/dev/null
jq -e '
  .[0] as $workflow
  | ($workflow.nodes | map(.name) | index("Validate Session Before Retrieval") < index("Validate Natural-language Read Request"))
  and ($workflow.nodes | map(.name) | index("Validate Natural-language Read Request") < index("Gemini Query Embedding 768"))
  and ($workflow.nodes[] | select(.name == "Validate Natural-language Read Request")
      | .parameters.jsCode
        | contains("rawSql")
          and contains("sensitiveRequest")
          and contains("injectionAttempt")
          and contains("date_context")
          and contains("current_year_start")
          and contains("invalid authoritative date context"))
  and ($workflow.connections["Validate Session Before Retrieval"].main[0][0].node == "Validate Natural-language Read Request")
  and ($workflow.connections["Validate Natural-language Read Request"].main[0][0].node == "Gemini Query Embedding 768")
  and ($workflow.nodes[] | select(.name == "Build QueryPlanV1 Prompt")
      | .parameters.jsCode
        | contains("natural-language business names")
          and contains("example client database")
          and contains("deterministic")
          and contains("Do not invent an unrelated DocType")
          and contains("AUTHORITATIVE ERPNext DATE CONTEXT")
          and contains("Never guess the current date or year")
          and contains("今年"))
  and ($workflow.connections["Build QueryPlanV1 Prompt"].main[0][0].node == "Deterministic Simple Count?")
  and ($workflow.connections["Deterministic Simple Count?"].main[0][0].node == "Frappe Execute Permissioned Plan")
  and ($workflow.connections["Deterministic Simple Count?"].main[1][0].node == "Gemini Generate QueryPlanV1")
  and ($workflow.nodes[] | select(.name == "Gemini Generate QueryPlanV1")
      | .retryOnFail == true
        and .maxTries == 3
        and .waitBetweenTries == 3000
        and (.parameters.body | contains("responseSchema")))
  and ($workflow.nodes[] | select(.name == "Parse Strict JSON Plan")
      | .parameters.jsCode
        | contains("incomplete QueryPlanV1")
          and contains("unsupported QueryPlanV1 keys")
          and contains("plan.aggregates.length")
          and contains("plan.fields = [...plan.group_by]"))
  and ([$workflow.nodes[] | .parameters.jsCode? // ""] | all(contains("__NOT_ALLOWLISTED__") | not))
' \
  "${ROOT_DIR}/n8n/workflows/erpnext-permissioned-query-v2.json" >/dev/null
jq -e '.[0].nodes[] | select(.name == "Opaque Session Redis Memory") | .parameters.sessionKey | contains("Validate Frappe Session Before Gemini") and contains("history_id")' \
  "${ROOT_DIR}/n8n/workflows/erpnext-ai-chat-assistant-v2.json" >/dev/null
jq -e '
  .[0] as $workflow
  | (["Fetch Schema-only Catalog", "Fetch Existing Chunk Hashes", "Atomic Upsert Changed Chunks", "Delete Stale Only After Success"]
     | all(.[]; . as $name
       | ($workflow.nodes[] | select(.name == $name) | .onError == "continueErrorOutput")
         and ($workflow.connections[$name].main[1][0].node == "Build Failed Sync Result")))
  and ($workflow.nodes[] | select(.name == "Embed Changed Chunks at 768") | .onError == "continueRegularOutput")
  and ($workflow.nodes[] | select(.name == "Fetch Existing Chunk Hashes") | .alwaysOutputData == true)
  and (["Embed Changed Chunks at 768", "Atomic Upsert Changed Chunks", "Delete Stale Only After Success"]
       | all(.[]; . as $name
         | ($workflow.nodes[] | select(.name == $name)
            | .parameters.options.response.response.responseFormat == "autodetect")))
' "${ROOT_DIR}/n8n/workflows/erpnext-schema-sync-v2.json" >/dev/null

rg -q 'HARD_MAX_LIMIT = 100' "${ROOT_DIR}/hksr_overlay/hksr/ai_assistant/query_plan.py"
rg -q 'BLOCKED_FIELDTYPES' "${ROOT_DIR}/hksr_overlay/hksr/ai_assistant/query_plan.py"
rg -q 'FRONTEND_WIDGET_ASSET=' "${ROOT_DIR}/deploy_shadow_backend.sh"
rg -q 'frontend_widget_hash=' "${ROOT_DIR}/deploy_shadow_backend.sh"
rg -q 'WIDGET_ASSET_VERSION=' "${ROOT_DIR}/deploy_shadow_backend.sh"
jq -e '.doctype == "Page" and .name == "ai-assistant-v2-uat" and .module == "Hksr" and (.roles | length == 0)' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.json" >/dev/null
rg -q 'hksr\.ai_assistant\.api\.bootstrap' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -q 'aiSessionToken: config\.token' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -q 'loadPreviousSession: false' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -q 'hksr\.ai_assistant\.api\.chat_history' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js" \
  "${ROOT_DIR}/hksr_overlay/hksr/public/js/n8n_chat.js"
rg -q 'hydrate_visible_history' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -q 'hydrateVisibleHistory' \
  "${ROOT_DIR}/hksr_overlay/hksr/public/js/n8n_chat.js"
rg -Fq 'height: clamp(520px, calc(100dvh - 300px), 760px)' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.css"
rg -q '\.ai-assistant-v2-uat-chat \.chat-messages-list' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.css"
rg -q 'grid-template-rows: max-content minmax\(0, 1fr\) max-content' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.css"
rg -Fq 'height: auto !important' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.css"
rg -Fq 'grid-row: 2' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.css"
rg -Fq 'display: block' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.css"
rg -Fq 'padding-bottom: var(--chat--spacing)' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.css"
! rg -Fq '.ai-assistant-v2-uat-chat .chat-messages-list::before' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.css"
rg -Fq '.ai-assistant-v2-uat-chat .chat-messages-list::after' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.css"
rg -Fq 'height: calc(var(--chat--spacing) + 12px)' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.css"
rg -q 'new MutationObserver' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -Fq 'node.matches(".chat-message")' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -Fq 'target.closest(".chat-message")' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -Fq 'state.follow_chat_tail || state.force_chat_tail_pending' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -Fq 'schedule_tail_follow(state, message_added || keep_following_changed_message)' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -Fq 'state.force_chat_tail_pending = true' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -Fq 'state.force_chat_tail_pending || state.follow_chat_tail' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
! rg -Fq 'node.matches(".chat-message-from-user")' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -Fq 'body.scrollTop = body.scrollHeight' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
rg -Fq 'state.chat_observer.disconnect()' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
! rg -qi 'metadata:\s*\{[^}]*user(name)?|frappe\.session\.sid' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js"
jq -e '
  .[0] as $workflow
  | ($workflow.nodes[] | select(.name == "Authenticated Chat Trigger v2")
      | .parameters.options.loadPreviousSession == "notSupported")
  and ($workflow.nodes[] | select(.name == "Capture Browser Auth Context")
      | .parameters.jsCode | contains("metadata?.aiSessionToken"))
  and (["Cookie", "X-Frappe-CSRF-Token"]
      | all(.[]; . as $header
        | all($workflow.nodes[]; ((.parameters.headerParameters.parameters // []) | map(.name) | index($header)) == null)))
' "${ROOT_DIR}/n8n/workflows/erpnext-ai-chat-assistant-v2.json" >/dev/null
jq -e '
  .[0] as $workflow
  | (["Cookie", "X-Frappe-CSRF-Token"]
      | all(.[]; . as $header
        | all($workflow.nodes[]; ((.parameters.headerParameters.parameters // []) | map(.name) | index($header)) == null)))
' "${ROOT_DIR}/n8n/workflows/erpnext-permissioned-query-v2.json" >/dev/null
rg -q 'frappe_sid' "${ROOT_DIR}/hksr_overlay/hksr/ai_assistant/auth.py"
rg -q '^def chat_history()' \
  "${ROOT_DIR}/hksr_overlay/hksr/ai_assistant/api.py"
rg -q '^def get_user_history_id' \
  "${ROOT_DIR}/hksr_overlay/hksr/ai_assistant/history.py"
rg -q 'hmac\.new' \
  "${ROOT_DIR}/hksr_overlay/hksr/ai_assistant/history.py"
rg -q 'ai_assistant_memory_redis_url' \
  "${ROOT_DIR}/hksr_overlay/hksr/ai_assistant/history.py"
rg -q '"date_context": _server_date_context()' \
  "${ROOT_DIR}/hksr_overlay/hksr/ai_assistant/api.py"
rg -q '^def _server_date_context()' \
  "${ROOT_DIR}/hksr_overlay/hksr/ai_assistant/api.py"
rg -q 'get_system_timezone' \
  "${ROOT_DIR}/hksr_overlay/hksr/ai_assistant/api.py"
! rg -q 'frappe_sid|frappe\.session\.sid' \
  "${ROOT_DIR}/hksr_overlay/hksr/hksr/page/ai_assistant_v2_uat/ai_assistant_v2_uat.js" \
  "${ROOT_DIR}/hksr_overlay/hksr/public/js/n8n_chat.js" \
  "${ROOT_DIR}/n8n/workflows/erpnext-ai-chat-assistant-v2.json"
rg -q 'embedding extensions.vector\(768\)' "${ROOT_DIR}/supabase/001_erpnext_schema_rag_v2.sql"
rg -q 'OPERATOR\(extensions\.<=>\)' "${ROOT_DIR}/supabase/001_erpnext_schema_rag_v2.sql"
rg -q 'embedding public.vector\(768\)' "${ROOT_DIR}/supabase/001_erpnext_schema_rag_v2.public-vector.sql"
rg -q 'OPERATOR\(public\.<=>\)' "${ROOT_DIR}/supabase/001_erpnext_schema_rag_v2.public-vector.sql"
rg -q "where extension.extname = 'vector'" "${ROOT_DIR}/supabase/detect_vector_schema.sql"
rg -q 'docker.n8n.io/n8nio/n8n:2.21.7' "${ROOT_DIR}/n8n/docker-compose.v2.yml"
rg -q '^  n8n_redis_data:$' "${ROOT_DIR}/n8n/docker-compose.v2.yml"
rg -q 'n8n_redis_data:/data' "${ROOT_DIR}/n8n/docker-compose.v2.yml"
rg -q -- '--appendonly.*yes' "${ROOT_DIR}/n8n/docker-compose.v2.yml"
bash -n "${ROOT_DIR}/n8n/apply_redis_host_tuning.sh"
rg -q 'vm\.overcommit_memory' "${ROOT_DIR}/n8n/apply_redis_host_tuning.sh"
rg -q '/etc/sysctl\.d/90-n8n-redis\.conf' "${ROOT_DIR}/n8n/apply_redis_host_tuning.sh"
bash -n "${ROOT_DIR}/operations/reboot_persistence_check.sh"
rg -q 'PRE_REBOOT_BOOT_ID' "${ROOT_DIR}/operations/reboot_persistence_check.sh"
rg -q 'RESTART_POLICY_BLOCKERS' "${ROOT_DIR}/operations/reboot_persistence_check.sh"
rg -q 'active_v2_count' "${ROOT_DIR}/operations/reboot_persistence_check.sh"
rg -q 'this script still does not initiate the reboot' "${ROOT_DIR}/operations/reboot_persistence_check.sh"
! rg -q 'docker (container )?(start|restart|update)|systemctl (start|restart|reboot)|(^|[[:space:]])reboot([[:space:]]|$)' \
  "${ROOT_DIR}/operations/reboot_persistence_check.sh"
bash -n "${ROOT_DIR}/operations/frappe_runtime_integrity.sh"
bash -n "${ROOT_DIR}/operations/erpnext_restart.safe.sh"
bash -n "${ROOT_DIR}/operations/install_frappe_runtime_guard.sh"
rg -q 'audit\|verify\|sync\|warm-cache' \
  "${ROOT_DIR}/operations/frappe_runtime_integrity.sh"
rg -q 'sheets\.boot\.extend_bootinfo' \
  "${ROOT_DIR}/operations/frappe_runtime_integrity.sh"
rg -q 'drive\.api\.product\.after_request' \
  "${ROOT_DIR}/operations/frappe_runtime_integrity.sh"
rg -Fq 'Refusing to rebuild app_hooks while' \
  "${ROOT_DIR}/operations/frappe_runtime_integrity.sh"
rg -Fq 'Checking Frappe application and cached-hook integrity before restart' \
  "${ROOT_DIR}/operations/erpnext_restart.safe.sh"
rg -Fq 'Starting database and Redis first' \
  "${ROOT_DIR}/operations/erpnext_restart.safe.sh"
rg -Fq 'rebuilding app_hooks before any worker can write the cache' \
  "${ROOT_DIR}/operations/erpnext_restart.safe.sh"
rg -Fq 'background runtimes remain stopped until integrity is verified' \
  "${ROOT_DIR}/operations/erpnext_restart.safe.sh"
rg -Fq 'ERPNEXT_PUBLIC_HOST' \
  "${ROOT_DIR}/operations/erpnext_restart.safe.sh"
rg -Fq 'No Frappe application source, database, Redis data, or container was changed' \
  "${ROOT_DIR}/operations/install_frappe_runtime_guard.sh"
rg -Fq -- "--exclude='.runtime-workflow-stage/'" "${ROOT_DIR}/install_operations_source.sh"
rg -Fq -- "--exclude='*.rdb'" "${ROOT_DIR}/install_operations_source.sh"
rg -q 'frappe_docker-queue-short-1 frappe_docker-queue-long-1 frappe_docker-scheduler-1' \
  "${ROOT_DIR}/deploy_shadow_backend.sh"
rg -Fq 'mktemp -d "${SCRIPT_DIR}/.runtime-stage.XXXXXX"' \
  "${ROOT_DIR}/deploy_shadow_backend.sh"
rg -Fq 'docker cp -a "${runtime_stage}/." "${runtime_container}:${RUNTIME_PACKAGE}/"' \
  "${ROOT_DIR}/deploy_shadow_backend.sh"
rg -q 'python -m compileall -q' "${ROOT_DIR}/deploy_shadow_backend.sh"
rg -Fq 'RUNTIME_INTEGRITY_SCRIPT=' "${ROOT_DIR}/deploy_shadow_backend.sh"
[[ "$(rg -c '"\$\{RUNTIME_INTEGRITY_SCRIPT\}" verify' "${ROOT_DIR}/deploy_shadow_backend.sh")" -eq 2 ]]

echo "Static security and syntax contracts passed."
