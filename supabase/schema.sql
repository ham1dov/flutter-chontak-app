create table if not exists public.transactions (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  amount numeric(18, 2) not null check (amount > 0),
  category text not null,
  type text not null check (type in ('income', 'expense')),
  note text not null default '',
  created_at timestamptz not null,
  updated_at timestamptz not null,
  deleted boolean not null default false
);

create index if not exists transactions_user_created_idx
  on public.transactions (user_id, created_at desc);

alter table public.transactions enable row level security;

create policy "Users can read their own transactions"
  on public.transactions for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "Users can create their own transactions"
  on public.transactions for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

create policy "Users can update their own transactions"
  on public.transactions for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "Users can remove their own transactions"
  on public.transactions for delete
  to authenticated
  using ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.transactions to authenticated;