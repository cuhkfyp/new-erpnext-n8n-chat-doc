# Supabase 768-dimensional schema notes

## Correct pgvector type

The initial migration failed when it declared the column as
`extensions.vector(768)`. In this Supabase project, the `vector` type is
available on the database search path and is not exposed as
`extensions.vector`.

Use:

```sql
create extension if not exists vector;

create schema if not exists ai_assistant;

create table if not exists ai_assistant.schema_chunks (
    site_key text not null,
    doctype_name text not null,
    chunk_key text not null,
    content_hash text not null,
    schema_text text not null,
    embedding vector(768) not null,
    updated_at timestamptz not null default now(),
    primary key (site_key, doctype_name, chunk_key)
);
```

The corrected environment migration completed successfully with no returned
rows.

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
