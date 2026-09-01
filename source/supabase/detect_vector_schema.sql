-- Run this first. Choose the migration matching the returned vector_schema.
select
  namespace.nspname as vector_schema,
  extension.extversion as vector_version
from pg_extension as extension
join pg_namespace as namespace on namespace.oid = extension.extnamespace
where extension.extname = 'vector';
