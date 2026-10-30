-- Egg incubator: the ESP32 pushes its state here; phones read it and queue setting changes.
-- Everything is keyed by a random device key (sha256-hashed at rest). Tables are private;
-- anon only reaches them through the three security-definer functions below. Re-runnable.
create extension if not exists pgcrypto with schema extensions;
create schema if not exists incubator;
revoke all on schema incubator from anon, authenticated;

create table if not exists incubator.devices (
  key_hash text primary key,
  state jsonb not null default '{}',      -- latest report from the ESP32 (readings + settings)
  seen_at timestamptz,
  cmd jsonb not null default '{}',        -- settings patch waiting for the ESP32
  cmd_id bigint not null default 0,
  acked_id bigint not null default 0,
  created_at timestamptz not null default now()
);
alter table incubator.devices enable row level security;

create table if not exists incubator.readings (
  key_hash text not null references incubator.devices(key_hash) on delete cascade,
  at timestamptz not null default now(),
  t real,
  h real,
  lamp boolean,
  fan boolean
);
create index if not exists readings_key_at on incubator.readings (key_hash, at desc);
alter table incubator.readings enable row level security;

create or replace function incubator.hash(p_key text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(p_key, 'sha256'), 'hex')
$$;

-- ESP32, every ~20 s: store state, keep a reading every 5 min, return a pending command if any.
create or replace function public.incubator_push(p_key text, p_state jsonb, p_ack bigint default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  k text;
  d incubator.devices;
begin
  if p_key is null or length(p_key) < 16 or length(p_key) > 64 then raise exception 'bad key'; end if;
  if pg_column_size(p_state) > 4000 then raise exception 'state too big'; end if;
  k := incubator.hash(p_key);
  insert into incubator.devices (key_hash, state, seen_at, acked_id)
  values (k, p_state, now(), coalesce(p_ack, 0))
  on conflict (key_hash) do update
    set state = excluded.state, seen_at = now(),
        acked_id = greatest(incubator.devices.acked_id, excluded.acked_id)
  returning * into d;

  if not exists (select 1 from incubator.readings r where r.key_hash = k and r.at > now() - interval '290 seconds') then
    insert into incubator.readings (key_hash, t, h, lamp, fan)
    values (k, (p_state->>'t')::real, (p_state->>'h')::real, (p_state->>'lamp')::boolean, (p_state->>'fan')::boolean);
    delete from incubator.readings r where r.key_hash = k and r.at < now() - interval '30 days';
  end if;

  if d.cmd_id > d.acked_id then
    return jsonb_build_object('cmd_id', d.cmd_id, 'cmd', d.cmd);
  end if;
  return jsonb_build_object('cmd_id', d.cmd_id);
end $$;

-- Phone: latest state + last 24 h of readings.
create or replace function public.incubator_get(p_key text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'state', d.state,
    'seen_at', d.seen_at,
    'now', now(),
    'pending', d.cmd_id > d.acked_id,
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('at', extract(epoch from r.at)::bigint, 't', r.t, 'h', r.h) order by r.at)
      from incubator.readings r where r.key_hash = d.key_hash and r.at > now() - interval '24 hours'
    ), '[]'::jsonb))
  from incubator.devices d where d.key_hash = incubator.hash(p_key)
$$;

-- Phone: queue a settings change; the ESP32 picks it up on its next push.
create or replace function public.incubator_command(p_key text, p_patch jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare r bigint;
begin
  if pg_column_size(p_patch) > 2000 then raise exception 'patch too big'; end if;
  update incubator.devices d
     set cmd = case when d.cmd_id > d.acked_id then d.cmd || p_patch else p_patch end,
         cmd_id = d.cmd_id + 1
   where d.key_hash = incubator.hash(p_key)
  returning d.cmd_id into r;
  if r is null then raise exception 'unknown device'; end if;
  return r;
end $$;

revoke all on function public.incubator_push(text, jsonb, bigint) from public;
revoke all on function public.incubator_get(text) from public;
revoke all on function public.incubator_command(text, jsonb) from public;
grant execute on function public.incubator_push(text, jsonb, bigint) to anon, authenticated;
grant execute on function public.incubator_get(text) to anon, authenticated;
grant execute on function public.incubator_command(text, jsonb) to anon, authenticated;
