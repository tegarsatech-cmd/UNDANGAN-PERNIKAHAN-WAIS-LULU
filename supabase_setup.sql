-- ============================================================================
-- SUPABASE SETUP: RSVP & BUKU TAMU UNDANGAN WAIS & LULU (DENGAN EDIT & HAPUS)
-- Disesuaikan dengan Supabase Postgres Best Practices (2026)
-- Cara pakai: Buka Supabase Dashboard -> SQL Editor -> New Query -> Paste & Run
-- ============================================================================

-- 1. Helper function (SECURITY INVOKER) untuk membaca hash token pemilik dari header x-wish-token
create or replace function public.current_wish_token_hash()
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select case
    when coalesce(nullif(pg_catalog.current_setting('request.headers', true), '')::json ->> 'x-wish-token', '') <> ''
     and pg_catalog.char_length(nullif(pg_catalog.current_setting('request.headers', true), '')::json ->> 'x-wish-token') between 16 and 128
    then pg_catalog.encode(
      pg_catalog.sha256(
        pg_catalog.convert_to(
          nullif(pg_catalog.current_setting('request.headers', true), '')::json ->> 'x-wish-token',
          'UTF8'
        )
      ),
      'hex'
    )
    else null
  end;
$$;

-- 2. Buat tabel (jika belum ada) dengan tipe data optimal & SQL-standard bigint identity PK
create table if not exists public.wedding_wishes (
  id bigint generated always as identity primary key,
  name text not null,
  status text not null,
  guest_count text not null default '1',
  message text not null,
  token_hash text default public.current_wish_token_hash(),
  created_at timestamptz not null default now(),
  updated_at timestamptz,

  constraint wedding_wishes_name_length_chk
    check (char_length(btrim(name)) between 1 and 120),
  constraint wedding_wishes_status_chk
    check (status in ('Hadir', 'Tidak Hadir', 'Masih Ragu')),
  constraint wedding_wishes_guest_count_chk
    check (guest_count in ('1', '2', '3', '4+')),
  constraint wedding_wishes_message_length_chk
    check (char_length(btrim(message)) between 1 and 1000)
);

-- Migrasikan kolom baru secara idempotent jika tabel sudah dibuat sebelumnya
alter table public.wedding_wishes
  add column if not exists token_hash text default public.current_wish_token_hash(),
  add column if not exists updated_at timestamptz;

alter table public.wedding_wishes
  alter column token_hash set default public.current_wish_token_hash();

-- Trigger otomatis untuk mengisi updated_at setiap kali ucapan diedit
create or replace function public.touch_wedding_wishes_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := pg_catalog.now();
  return new;
end;
$$;

drop trigger if exists trg_wedding_wishes_updated_at on public.wedding_wishes;
create trigger trg_wedding_wishes_updated_at
  before update on public.wedding_wishes
  for each row
  execute function public.touch_wedding_wishes_updated_at();

-- 3. Index untuk query urutan terbaru, filter hadir, dan performa RLS token_hash
create index if not exists wedding_wishes_created_at_id_idx
  on public.wedding_wishes (created_at desc, id desc);

create index if not exists wedding_wishes_hadir_idx
  on public.wedding_wishes (created_at desc)
  where status = 'Hadir';

create index if not exists wedding_wishes_token_hash_idx
  on public.wedding_wishes (token_hash);

-- 4. Principle of Least Privilege & Explicit Grants (Wajib sejak update Supabase Okt 2026)
grant usage on schema public to anon, authenticated;
revoke all on table public.wedding_wishes from anon, authenticated;
grant select, insert, delete on table public.wedding_wishes to anon, authenticated;
grant update (name, status, guest_count, message, updated_at) on table public.wedding_wishes to anon, authenticated;
grant execute on function public.current_wish_token_hash() to anon, authenticated;
grant execute on function public.touch_wedding_wishes_updated_at() to anon, authenticated;

do $$
declare
  seq_name text := pg_get_serial_sequence('public.wedding_wishes', 'id');
begin
  if seq_name is not null then
    execute format('grant usage, select on sequence %s to anon, authenticated', seq_name);
  end if;
end $$;

-- 5. Row Level Security (RLS): Semua pengunjung bisa baca/kirim, hanya pemilik token yang bisa edit/hapus
alter table public.wedding_wishes enable row level security;

drop policy if exists "wedding_wishes_select_public" on public.wedding_wishes;
create policy "wedding_wishes_select_public"
  on public.wedding_wishes
  for select
  to anon, authenticated
  using (true);

drop policy if exists "wedding_wishes_insert_public" on public.wedding_wishes;
create policy "wedding_wishes_insert_public"
  on public.wedding_wishes
  for insert
  to anon, authenticated
  with check (
    token_hash is not null
    and token_hash = (select public.current_wish_token_hash())
    and char_length(btrim(name)) between 1 and 120
    and status in ('Hadir', 'Tidak Hadir', 'Masih Ragu')
    and guest_count in ('1', '2', '3', '4+')
    and char_length(btrim(message)) between 1 and 1000
  );

drop policy if exists "wedding_wishes_update_own" on public.wedding_wishes;
create policy "wedding_wishes_update_own"
  on public.wedding_wishes
  for update
  to anon, authenticated
  using (
    token_hash is not null
    and token_hash = (select public.current_wish_token_hash())
  )
  with check (
    token_hash is not null
    and token_hash = (select public.current_wish_token_hash())
    and char_length(btrim(name)) between 1 and 120
    and status in ('Hadir', 'Tidak Hadir', 'Masih Ragu')
    and guest_count in ('1', '2', '3', '4+')
    and char_length(btrim(message)) between 1 and 1000
  );

drop policy if exists "wedding_wishes_delete_own" on public.wedding_wishes;
create policy "wedding_wishes_delete_own"
  on public.wedding_wishes
  for delete
  to anon, authenticated
  using (
    token_hash is not null
    and token_hash = (select public.current_wish_token_hash())
  );

-- 6. Pastikan tabel terdaftar di publikasi Supabase Realtime (INSERT, UPDATE, DELETE)
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1
       from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'wedding_wishes'
     ) then
    alter publication supabase_realtime add table public.wedding_wishes;
  end if;
end $$;

-- 7. Muat ulang cache skema PostgREST
notify pgrst, 'reload schema';
