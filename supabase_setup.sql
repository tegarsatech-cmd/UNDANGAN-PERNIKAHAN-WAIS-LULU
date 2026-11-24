-- ============================================================================
-- SUPABASE SETUP: RSVP & BUKU TAMU UNDANGAN WAIS & LULU
-- Disesuaikan dengan Supabase Postgres Best Practices (2026)
-- Cara pakai: Buka Supabase Dashboard -> SQL Editor -> New Query -> Paste & Run
-- ============================================================================

-- 1. Buat tabel dengan tipe data optimal & SQL-standard bigint identity PK
create table if not exists public.wedding_wishes (
  id bigint generated always as identity primary key,
  name text not null,
  status text not null,
  guest_count text not null default '1',
  message text not null,
  created_at timestamptz not null default now(),

  constraint wedding_wishes_name_length_chk
    check (char_length(btrim(name)) between 1 and 120),
  constraint wedding_wishes_status_chk
    check (status in ('Hadir', 'Tidak Hadir', 'Masih Ragu')),
  constraint wedding_wishes_guest_count_chk
    check (guest_count in ('1', '2', '3', '4+')),
  constraint wedding_wishes_message_length_chk
    check (char_length(btrim(message)) between 1 and 1000)
);

-- 2. Index komposit untuk query urutan terbaru & cursor pagination (O(limit) tanpa sort)
create index if not exists wedding_wishes_created_at_id_idx
  on public.wedding_wishes (created_at desc, id desc);

-- Partial index opsional untuk rekap cepat tamu yang konfirmasi 'Hadir'
create index if not exists wedding_wishes_hadir_idx
  on public.wedding_wishes (created_at desc)
  where status = 'Hadir';

-- 3. Principle of Least Privilege & Explicit Grants (Wajib sejak update Supabase Okt 2026)
grant usage on schema public to anon, authenticated;
revoke all on table public.wedding_wishes from anon, authenticated;
grant select, insert on table public.wedding_wishes to anon, authenticated;

do $$
declare
  seq_name text := pg_get_serial_sequence('public.wedding_wishes', 'id');
begin
  if seq_name is not null then
    execute format('grant usage, select on sequence %s to anon, authenticated', seq_name);
  end if;
end $$;

-- 4. Aktifkan Row Level Security (RLS) menggunakan klausa TO (bukan auth.role() yang deprecated)
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
    char_length(btrim(name)) between 1 and 120
    and status in ('Hadir', 'Tidak Hadir', 'Masih Ragu')
    and guest_count in ('1', '2', '3', '4+')
    and char_length(btrim(message)) between 1 and 1000
  );

-- 5. Aktifkan Supabase Realtime agar ucapan baru otomatis sinkron ke semua pengunjung
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

-- 6. Muat ulang cache skema PostgREST
notify pgrst, 'reload schema';
