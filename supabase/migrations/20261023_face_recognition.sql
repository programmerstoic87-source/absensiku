-- ============================================================
-- 20261023_face_recognition.sql
-- Face recognition + liveness untuk aplikasi absensi (Fresh DB)
-- ============================================================

-- 1. Aktifkan extension vector untuk penyimpanan embedding
create extension if not exists vector;

-- 2. Tabel profiles (digunakan server index.js: db.from('profiles'))
create table if not exists profiles (
  id uuid primary key default gen_random_uuid(),
  full_name text,
  email text unique,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- 3. Tabel employees (dengan kolom face_registered baru)
create table if not exists employees (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  role text default 'user',
  face_registered boolean default false,
  face_encoding bytea, -- legacy column, dipakai server lama
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- 4. Tabel attendance (dengan kolom face baru)
create table if not exists attendance (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid references employees(id) on delete set null,
  check_in_at timestamptz,
  check_out_at timestamptz,
  location text,
  face_match float,
  face_verified boolean default false,
  liveness_passed boolean default false,
  needs_photo boolean default false,
  face_verification_id uuid,
  tanggal date default trunc(now()),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- 5. Tabel employee_faces (simpan embedding 128-d wajah)
create table if not exists employee_faces (
  employee_id uuid references employees(id) on delete cascade primary key,
  embedding vector(128) not null,
  registered_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- 6. Index duplikat wajah (untuk pencarian exact)
create unique index if not exists employee_faces_pkey on employee_faces (employee_id);

-- 7. Tabel face_attempt_logs (log enroll/verify/liveness)
create table if not exists face_attempt_logs (
  id bigint generated always as identity primary key,
  employee_id uuid references employees(id) on delete set null,
  attempt_type text not null check (attempt_type in ('enroll','verify','liveness')),
  success boolean not null,
  distance float,
  reason text,
  ip text,
  created_at timestamptz default now()
);

create index if not exists face_attempt_logs_employee_idx on face_attempt_logs (employee_id, created_at desc);

-- 8. Tabel face_verifikasi sekali pakai
create table if not exists face_verifications (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references employees(id) on delete cascade,
  distance float not null,
  liveness_passed boolean default false,
  expires_at timestamptz default now() + interval '2 minutes',
  used_at timestamptz,
  created_at timestamptz default now()
);

create index if not exists face_verifications_employee_idx on face_verifications (employee_id, created_at desc);

-- 9. RPC: cari wajah terdekat (exact scan)
-- query dikirim sebagai string '[0.1,0.2,...]' agar aman lewat PostgREST.
-- Operator <-> = euclidean distance (bukan cosine <=>).
create or replace function match_employee_face(
  query vector(128),
  max_distance float default 0.5
)
returns table (employee_id uuid, dist float)
language sql stable
as $$
  select ef.employee_id,
         (ef.embedding <-> query)::float as dist
    from employee_faces ef
   where ef.embedding <-> query < max_distance
   order by ef.embedding <-> query asc
   limit 1;
$$;

revoke all on function match_employee_face(vector, float) from public;
revoke all on function match_employee_face(vector, float) from anon, authenticated;
grant execute on function match_employee_face(vector, float) to service_role;

-- 10. RLS: hanya service role
-- Tidak ada policy sengaja. Verifikasi setelah migrasi:
--   select tablename, policyname from pg_policies
--    where tablename in ('employee_faces','face_attempt_logs','face_verifications');
-- Hasil yang benar: 0 baris policy.

alter table employee_faces     enable row level security;
alter table face_attempt_logs  enable row level security;
alter table face_verifications enable row level security;

-- ------------------------------------------------------------
-- 11. Verifikasi cepat (jalankan manual)
-- ------------------------------------------------------------
-- select column_name, data_type from information_schema.columns
--  where table_name = 'attendance' and column_name like 'face%';
-- select indexname from pg_indexes where tablename = 'attendance';

-- 12. Indexunik absen per karyawan per tanggal
create unique index if not exists attendance_emp_tanggal on attendance (employee_id, tanggal) where check_in_at is not null;