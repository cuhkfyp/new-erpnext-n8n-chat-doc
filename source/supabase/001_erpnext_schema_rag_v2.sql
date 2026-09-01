-- ERPNext AI Assistant v2: schema-only, environment-isolated vector index.
-- Variant for projects whose vector extension is installed in `extensions`.
-- Run detect_vector_schema.sql first. This guard never relocates an existing
-- extension because doing so could disrupt legacy 3072-dimensional objects.

create schema if not exists extensions;
do $$
declare
  installed_schema text;
begin
  select namespace.nspname
    into installed_schema
  from pg_extension as extension
  join pg_namespace as namespace on namespace.oid = extension.extnamespace
  where extension.extname = 'vector';

  if installed_schema is null then
    execute 'create extension vector with schema extensions';
  elsif installed_schema <> 'extensions' then
    raise exception 'vector extension is installed in schema %, not extensions; use the matching schema-specific migration', installed_schema;
  end if;
end;
$$;
create schema if not exists ai_assistant;

revoke all on schema ai_assistant from public, anon, authenticated;
grant usage on schema ai_assistant to service_role;

create table if not exists ai_assistant.erpnext_schema_chunks (
  site_id text not null check (site_id ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{1,139}$'),
  doctype text not null check (length(doctype) between 1 and 140),
  chunk_id text not null check (chunk_id ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,139}$'),
  content text not null,
  content_hash text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  embedding_model text not null,
  embedding_dimensions integer not null default 768 check (embedding_dimensions = 768),
  embedding extensions.vector(768) not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (site_id, doctype, chunk_id)
);

alter table ai_assistant.erpnext_schema_chunks enable row level security;
alter table ai_assistant.erpnext_schema_chunks force row level security;
revoke all on ai_assistant.erpnext_schema_chunks from public, anon, authenticated;
grant select, insert, update, delete on ai_assistant.erpnext_schema_chunks to service_role;

create index if not exists erpnext_schema_chunks_site_hash_idx
  on ai_assistant.erpnext_schema_chunks (site_id, content_hash);

create index if not exists erpnext_schema_chunks_embedding_hnsw_idx
  on ai_assistant.erpnext_schema_chunks
  using hnsw (embedding extensions.vector_cosine_ops);

create or replace function public.list_erpnext_schema_hashes_v2(requested_site_id text)
returns table (doctype text, chunk_id text, content_hash text)
language sql
stable
security definer
set search_path = ''
as $$
  select chunk.doctype, chunk.chunk_id, chunk.content_hash
  from ai_assistant.erpnext_schema_chunks as chunk
  where chunk.site_id = requested_site_id
  order by chunk.doctype, chunk.chunk_id;
$$;

create or replace function public.apply_erpnext_schema_upserts_v2(
  requested_site_id text,
  chunks jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  applied integer := 0;
  item_embedding extensions.vector(768);
begin
  if requested_site_id !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{1,139}$' then
    raise exception 'invalid site identifier';
  end if;
  if jsonb_typeof(chunks) <> 'array' or jsonb_array_length(chunks) > 1000 then
    raise exception 'chunks must be a bounded JSON array';
  end if;

  for item in select value from jsonb_array_elements(chunks)
  loop
    if coalesce(item->>'doctype', '') = ''
      or coalesce(item->>'chunk_id', '') !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,139}$'
      or coalesce(item->>'content_hash', '') !~ '^[0-9a-f]{64}$'
      or coalesce(item->>'embedding_model', '') = ''
      or jsonb_typeof(item->'embedding') <> 'array'
      or jsonb_array_length(item->'embedding') <> 768 then
      raise exception 'invalid schema chunk payload';
    end if;

    item_embedding := (item->'embedding')::text::extensions.vector(768);

    insert into ai_assistant.erpnext_schema_chunks (
      site_id,
      doctype,
      chunk_id,
      content,
      content_hash,
      embedding_model,
      embedding_dimensions,
      embedding,
      metadata,
      updated_at
    ) values (
      requested_site_id,
      item->>'doctype',
      item->>'chunk_id',
      item->>'content',
      item->>'content_hash',
      item->>'embedding_model',
      768,
      item_embedding,
      coalesce(item->'metadata', '{}'::jsonb),
      now()
    )
    on conflict (site_id, doctype, chunk_id) do update set
      content = excluded.content,
      content_hash = excluded.content_hash,
      embedding_model = excluded.embedding_model,
      embedding_dimensions = 768,
      embedding = excluded.embedding,
      metadata = excluded.metadata,
      updated_at = now();
    applied := applied + 1;
  end loop;

  return applied;
end;
$$;

create or replace function public.delete_erpnext_schema_chunks_v2(
  requested_site_id text,
  chunks jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  deleted_count integer;
begin
  if requested_site_id !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{1,139}$' then
    raise exception 'invalid site identifier';
  end if;
  if jsonb_typeof(chunks) <> 'array' or jsonb_array_length(chunks) > 1000 then
    raise exception 'chunks must be a bounded JSON array';
  end if;

  delete from ai_assistant.erpnext_schema_chunks as stored
  using jsonb_to_recordset(chunks) as stale(doctype text, chunk_id text)
  where stored.site_id = requested_site_id
    and stored.doctype = stale.doctype
    and stored.chunk_id = stale.chunk_id;
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

create or replace function public.match_erpnext_schema_v2(
  query_embedding extensions.vector(768),
  match_site_id text,
  match_count integer default 8
)
returns table (
  doctype text,
  chunk_id text,
  content text,
  metadata jsonb,
  similarity double precision
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    chunk.doctype,
    chunk.chunk_id,
    chunk.content,
    chunk.metadata,
    1 - (chunk.embedding OPERATOR(extensions.<=>) query_embedding) as similarity
  from ai_assistant.erpnext_schema_chunks as chunk
  where chunk.site_id = match_site_id
  order by chunk.embedding OPERATOR(extensions.<=>) query_embedding
  limit greatest(1, least(coalesce(match_count, 8), 20));
$$;

revoke all on function public.list_erpnext_schema_hashes_v2(text) from public, anon, authenticated;
revoke all on function public.apply_erpnext_schema_upserts_v2(text, jsonb) from public, anon, authenticated;
revoke all on function public.delete_erpnext_schema_chunks_v2(text, jsonb) from public, anon, authenticated;
revoke all on function public.match_erpnext_schema_v2(extensions.vector, text, integer) from public, anon, authenticated;

grant execute on function public.list_erpnext_schema_hashes_v2(text) to service_role;
grant execute on function public.apply_erpnext_schema_upserts_v2(text, jsonb) to service_role;
grant execute on function public.delete_erpnext_schema_chunks_v2(text, jsonb) to service_role;
grant execute on function public.match_erpnext_schema_v2(extensions.vector, text, integer) to service_role;

comment on table ai_assistant.erpnext_schema_chunks is
  'Schema metadata only. ERPNext record values must never be written to this table.';
