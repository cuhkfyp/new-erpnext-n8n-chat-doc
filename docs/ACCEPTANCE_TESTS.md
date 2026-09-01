# Acceptance and security tests

## Accounts

Use one nominated existing higher-permission user and one nominated existing
restricted user. Do not share `Administrator` between browsers: unrelated
realtime notifications from another tab can appear in every session using the
same username and confuse attribution.

Never record passwords, cookies, SIDs, CSRF values, opaque tokens, or screenshots
that expose those values.

## Browser procedure

1. Sign in as the higher-permission user.
2. Open the isolated AI Assistant v2 acceptance Page.
3. Hard-refresh and reconnect so the newest scoped chat layout is loaded.
4. Run the functional and negative tests below and compare results with the
   equivalent ERPNext list/report access.
5. Sign out completely.
6. Repeat with the restricted user.

The Page is temporary. The normal lower-right widget is restored only during
the later atomic v2 cutover.

## Functional tests

- greeting and ordinary follow-up conversation;
- permitted lists with selected fields;
- count, sum, average, minimum, and maximum;
- grouping and sorting;
- pagination and truncation messages;
- English and Traditional Chinese prompts;
- natural business labels, translations, and abbreviations;
- empty results; and
- Redis-backed same-session follow-up context.

The two users must receive results matching their different ERPNext field and
row permissions.

## Mandatory negative tests

- denied DocType;
- denied field or row;
- invalid filter or operator;
- oversized limit;
- raw SQL and system-table request;
- write, update, delete, or insert intent;
- password, API key, cookie, token, or credential request;
- prompt injection and instruction-override attempts; and
- expired, forged, missing, or cross-session opaque token.

Raw SQL must receive a fixed refusal. It is a failure if the assistant redirects
the request to a nearby allowlisted DocType and returns unrelated data.

A normal natural-language question about an allowlisted business dataset must
still proceed. The deterministic raw-SQL gate must not block every permitted
query.

## Schema synchronization tests

- Adding an allowlisted field embeds only new or changed chunks.
- Changing a field updates only changed chunks.
- Removing a field or DocType removes stale chunks only after a complete
  successful catalog and upsert run.
- Gemini, Supabase, proxy, quota, and partial-batch failures preserve the last
  good index and appear in Frappe status.
- Development, UAT, and production namespaces and credentials cannot cross.

## Persistence tests

- n8n stop/start;
- Redis stop/start;
- approved Compose recreation with persistent mounts;
- ERPNext restart; and
- host reboot.

Workflow, credential, SQLite, Redis, routing, and schema-index state must retain
their documented persistence characteristics.

## UI regression tests

- Initial assistant message is fully visible.
- Long and streamed answers remain above the composer.
- A later Markdown height increase does not hide the final line.
- Many stacked messages scroll to the newest reply.
- Manually scrolling upward is respected until a new message is appended.
- Resizing the window or opening developer tools does not make the body overlap
  the composer.

## Failure classification

Do not report every model error as a Frappe permission failure:

- HTTP 401/403 from validation or execution indicates authentication,
  allowlist, or permission handling;
- HTTP 429 from Gemini indicates quota/rate limiting;
- a fixed safety refusal indicates the deterministic input gate; and
- a successful backend execution with a hidden reply indicates a presentation
  defect, not a data-access failure.
