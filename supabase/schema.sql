-- YTH Traffic · Supabase schema
-- One document table mirrors the app's collections (team, projects, tasks, retainers,
-- inbox, config, joins, adm/v1/cap). Row Level Security decides who reads and writes.

create table if not exists public.docs (
  collection text not null,
  id text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  primary key (collection, id)
);

alter table public.docs enable row level security;
alter table public.docs replica identity full;

-- Who is an admin: listed in config/app.adminIds
create or replace function public.yth_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.docs
    where collection = 'config' and id = 'app'
      and coalesce(data->'adminIds','[]'::jsonb) ? (auth.uid())::text
  );
$$;

-- Who is a linked team member: a team record carries their login id
create or replace function public.yth_is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.docs
    where collection = 'team' and data->>'userId' = (auth.uid())::text
  );
$$;

-- First person to claim becomes owner + admin, only while nobody owns the app
create or replace function public.yth_claim_owner() returns boolean
language plpgsql security definer set search_path = public as $$
declare cur jsonb;
begin
  if auth.uid() is null then return false; end if;
  select data into cur from public.docs where collection = 'config' and id = 'app';
  if cur is not null and coalesce(cur->>'ownerId','') <> '' then return false; end if;
  insert into public.docs (collection, id, data)
  values ('config','app', jsonb_build_object('ownerId', auth.uid()::text, 'adminIds', jsonb_build_array(auth.uid()::text)))
  on conflict (collection, id) do update
    set data = coalesce(public.docs.data,'{}'::jsonb)
             || jsonb_build_object('ownerId', auth.uid()::text, 'adminIds', jsonb_build_array(auth.uid()::text)),
        updated_at = now();
  return true;
end; $$;

create or replace function public.yth_has_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.docs where collection='config' and id='app' and coalesce(data->>'ownerId','') <> '');
$$;

grant execute on function public.yth_is_admin(), public.yth_is_member(), public.yth_claim_owner(), public.yth_has_owner() to authenticated;

drop policy if exists docs_read on public.docs;
drop policy if exists docs_admin_write on public.docs;
drop policy if exists docs_member_insert on public.docs;
drop policy if exists docs_member_update on public.docs;
drop policy if exists docs_join_self on public.docs;
drop policy if exists docs_join_self_update on public.docs;
drop policy if exists docs_join_self_read on public.docs;

-- Read: admins see everything; linked members see everything except admin-only areas
create policy docs_read on public.docs for select to authenticated
using (
  public.yth_is_admin()
  or (public.yth_is_member() and collection not like 'adm/%' and collection <> 'joins')
  or (collection = 'config' and id = 'app')
);
create policy docs_join_self_read on public.docs for select to authenticated
using (collection = 'joins' and id = (auth.uid())::text);

-- Admins can do anything
create policy docs_admin_write on public.docs for all to authenticated
using (public.yth_is_admin()) with check (public.yth_is_admin());

-- Members can create and update tasks and notifications (progress, submissions, comments)
create policy docs_member_insert on public.docs for insert to authenticated
with check (public.yth_is_member() and collection in ('tasks','inbox'));
create policy docs_member_update on public.docs for update to authenticated
using (public.yth_is_member() and collection in ('tasks','inbox'))
with check (public.yth_is_member() and collection in ('tasks','inbox'));

-- Anyone signed in may file their own "please link me" request
create policy docs_join_self on public.docs for insert to authenticated
with check (collection = 'joins' and id = (auth.uid())::text);
create policy docs_join_self_update on public.docs for update to authenticated
using (collection = 'joins' and id = (auth.uid())::text)
with check (collection = 'joins' and id = (auth.uid())::text);

-- Live updates
do $$ begin
  begin
    alter publication supabase_realtime add table public.docs;
  exception when duplicate_object then null;
  end;
end $$;

-- File attachments bucket (links are unguessable; uploads need a login)
insert into storage.buckets (id, name, public) values ('attachments','attachments', true)
on conflict (id) do nothing;
drop policy if exists yth_upload on storage.objects;
create policy yth_upload on storage.objects for insert to authenticated
with check (bucket_id = 'attachments' and (public.yth_is_admin() or public.yth_is_member()));
