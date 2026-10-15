-- =====================================================================
-- Finance Tracker: complete schema for a NEW Supabase project
--
-- How to use: Supabase dashboard -> SQL Editor -> New query -> paste this
-- whole file -> Run. It is safe to run more than once (idempotent).
--
-- What the app needs from the database:
--   * public.transactions  (read/write by the signed-in owner only)
-- Extras included:
--   * public.profiles      (one row per account, created automatically at sign-up)
--   * protection against an older offline edit overwriting a newer one
--   * Row Level Security everywhere, anonymous users blocked
--
-- Column names of public.transactions are what lib/main.dart sends and reads
-- (FinanceEntry.toJson / fromJson). Do not rename them without changing the app.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. profiles: one row per account (email, Google name/avatar, currency)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  email        text,
  display_name text,
  avatar_url   text,
  -- Not used by the current app yet (currency is stored on the device);
  -- reserved so it can be synced later without another migration.
  currency     text not null default 'UZS' check (char_length(currency) between 3 and 8),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Create the profile automatically for every new account (email or Google).
-- SECURITY DEFINER lets the trigger insert even though users cannot insert here.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, display_name, avatar_url)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Accounts that already exist (if you run this on a project with users).
insert into public.profiles (id, email, display_name, avatar_url)
select u.id,
       u.email,
       coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name'),
       u.raw_user_meta_data ->> 'avatar_url'
from auth.users u
on conflict (id) do nothing;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();


-- ---------------------------------------------------------------------
-- 2. transactions: the records the app syncs
-- ---------------------------------------------------------------------
create table if not exists public.transactions (
  -- Generated on the device (UUID v4), so records can be created offline
  -- without clashing with anything on the server.
  id         uuid primary key,
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  amount     numeric(18, 2) not null check (amount > 0),
  category   text not null check (char_length(category) between 1 and 100),
  type       text not null check (type in ('income', 'expense')),
  note       text not null default '' check (char_length(note) <= 1000),
  -- Both timestamps come from the device. updated_at drives conflict
  -- resolution: the newest edit wins (see guard trigger below).
  created_at timestamptz not null,
  updated_at timestamptz not null,
  -- Soft delete, so a deletion made on one device reaches the others.
  deleted    boolean not null default false
);

-- Loading a user's list newest-first.
create index if not exists transactions_user_created_idx
  on public.transactions (user_id, created_at desc);

-- Pulling only what changed since the last sync.
create index if not exists transactions_user_updated_idx
  on public.transactions (user_id, updated_at desc);

-- Stale-write guard. A phone that was offline for days may upload an old
-- version of a record that was edited more recently on another device.
-- In that case the server keeps the newer row and silently ignores the
-- older write (the app then pulls the newer version on its next sync).
create or replace function public.transactions_ignore_stale_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.updated_at < old.updated_at then
    return null; -- skip this row's update, no error
  end if;
  return new;
end;
$$;

drop trigger if exists transactions_ignore_stale_update on public.transactions;
create trigger transactions_ignore_stale_update
  before update on public.transactions
  for each row execute function public.transactions_ignore_stale_update();

-- A record can never be moved to another account.
create or replace function public.transactions_lock_owner()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.user_id <> old.user_id then
    raise exception 'user_id cannot be changed';
  end if;
  return new;
end;
$$;

drop trigger if exists transactions_lock_owner on public.transactions;
create trigger transactions_lock_owner
  before update on public.transactions
  for each row execute function public.transactions_lock_owner();


-- ---------------------------------------------------------------------
-- 3. Row Level Security
--    Each signed-in (non-anonymous) user can only see and change their own rows.
-- ---------------------------------------------------------------------
alter table public.profiles     enable row level security;
alter table public.transactions enable row level security;

-- Re-running the script replaces old policies instead of failing.
drop policy if exists "Users can read their own profile"       on public.profiles;
drop policy if exists "Users can update their own profile"     on public.profiles;
drop policy if exists "Users can read their own transactions"   on public.transactions;
drop policy if exists "Users can create their own transactions" on public.transactions;
drop policy if exists "Users can update their own transactions" on public.transactions;
drop policy if exists "Users can remove their own transactions" on public.transactions;

create policy "Users can read their own profile"
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "Users can update their own profile"
  on public.profiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- The app does not use anonymous sign-ins; if someone turns them on in the
-- dashboard, those throwaway identities still cannot write records.
create policy "Users can read their own transactions"
  on public.transactions for select
  to authenticated
  using (
    (select auth.uid()) = user_id
    and coalesce((select auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  );

create policy "Users can create their own transactions"
  on public.transactions for insert
  to authenticated
  with check (
    (select auth.uid()) = user_id
    and coalesce((select auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  );

create policy "Users can update their own transactions"
  on public.transactions for update
  to authenticated
  using (
    (select auth.uid()) = user_id
    and coalesce((select auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  )
  with check ((select auth.uid()) = user_id);

create policy "Users can remove their own transactions"
  on public.transactions for delete
  to authenticated
  using (
    (select auth.uid()) = user_id
    and coalesce((select auth.jwt() ->> 'is_anonymous')::boolean, false) = false
  );


-- ---------------------------------------------------------------------
-- 4. Privileges
--    Signed-out visitors (role "anon") get no access at all.
-- ---------------------------------------------------------------------
revoke all on public.profiles     from anon, authenticated;
revoke all on public.transactions from anon, authenticated;

grant select on public.profiles to authenticated;
-- Only these columns may be edited by the user; id/email stay system-managed.
grant update (display_name, avatar_url, currency) on public.profiles to authenticated;

grant select, insert, update, delete on public.transactions to authenticated;

-- The trigger functions are internal; nobody should call them directly.
revoke execute on function public.handle_new_user()                   from public, anon, authenticated;
revoke execute on function public.touch_updated_at()                  from public, anon, authenticated;
revoke execute on function public.transactions_ignore_stale_update()  from public, anon, authenticated;
revoke execute on function public.transactions_lock_owner()           from public, anon, authenticated;
