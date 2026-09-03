# Supabase 768-dimensional schema notes

## Correct pgvector type

The initial migration failed when it declared the column as
`extensions.vector(768)`. In this Supabase project, the extension is installed
in `public`, so the complete migration declares `public.vector(768)` and uses
the matching `public.vector_cosine_ops` operator class.

Run `source/supabase/detect_vector_schema.sql` first. For a result of `public`,
run the complete
`source/supabase/001_erpnext_schema_rag_v2.public-vector.sql`; do not construct
a shortened table manually because the workflow also depends on its protected
RPCs, constraints, grants, hash/model metadata, and index. The corrected
environment migration completed successfully with no returned rows.

## Index and RPC requirements

- Use the same 768-dimensional embedding output for indexing and retrieval.
- Filter similarity search by the exact environment/site namespace.
- Key upserts deterministically by site, DocType, and chunk.
- Store a stable content hash so unchanged schema chunks are not re-embedded.
- Expose only a bounded, filtered similarity RPC to the workflow.
- Keep the table isolated from legacy colleague data.
- Do not embed ERPNext record values.
- Remove stale rows only after a complete successful catalog and upsert batch.

Each environment requires a separate Supabase project and separately managed
credential.

## Which tables v2 uses

The v2 assistant does not use `handbook_chunks` or `handbook_documents`.
Those names belong to a separate or legacy index and may legitimately be
empty. Reusing them would violate the requirement to isolate the ERPNext
schema index from colleague data.

The actual table is `ai_assistant.erpnext_schema_chunks`, and similarity
retrieval uses `public.match_erpnext_schema_v2`. It stores only schema metadata,
hashes, and embeddings. ERPNext record values are queried live through Frappe
under the authenticated user's permissions.

Use this read-only SQL Editor query to confirm the index without displaying
embeddings or content:

```sql
select
  site_id,
  count(*) as chunk_count,
  count(distinct doctype) as doctype_count,
  min(updated_at) as oldest_chunk_update,
  max(updated_at) as newest_chunk_update
from ai_assistant.erpnext_schema_chunks
group by site_id
order by site_id;
```
