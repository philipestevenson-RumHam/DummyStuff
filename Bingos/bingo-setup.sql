-- RumHam Music Bingo backend. Run once in Supabase > SQL Editor. Safe to re-run.
-- Uses bingo_ tables, so it sits alongside the quiz setup without touching it.
-- Game states: lobby -> playing <-> paused -> (bingo called: paused, host judges) -> won -> playing ... -> ended

create table if not exists bingo_rooms (
  code text primary key, host_key text not null,
  state text not null default 'lobby' check (state in ('lobby','playing','paused','won','ended')),
  songs jsonb not null default '[]',            -- ["Artist - Title", ...] (the whole playlist)
  played int[] not null default '{}',           -- song indexes in the order they started
  prizes jsonb not null default '[{"n":"One line","k":1},{"n":"Two lines","k":2},{"n":"Full house","k":25}]', -- k = lines needed (25 = full house)
  prize_idx int not null default 0,
  claim_by uuid, claim_marks int[], claim_at timestamptz,   -- a pending bingo call
  win jsonb, winners jsonb not null default '[]',
  created_at timestamptz not null default now()
);
create table if not exists bingo_players (
  id uuid primary key default gen_random_uuid(),
  room text not null references bingo_rooms(code) on delete cascade,
  name text not null, secret uuid not null default gen_random_uuid(),
  card int[] not null default '{}',             -- 25 song indexes
  locked_until timestamptz,                     -- cooldown after a rejected call
  joined_at timestamptz not null default now(), last_seen timestamptz default now()
);
create unique index if not exists bingo_players_name on bingo_players (room, lower(name));
alter table bingo_rooms add column if not exists claim_queue jsonb not null default '[]';   -- further bingo calls waiting behind the current one, in order
alter table bingo_rooms add column if not exists claim_late uuid[] not null default '{}';   -- callers who were queued when someone else won (told they were too late)
alter table bingo_players add column if not exists paid boolean not null default false;   -- host ticks this when the player's PayPal payment arrives
alter table bingo_rooms add column if not exists undo jsonb;   -- snapshot taken just before the last verdict, so it can be undone for 15 seconds
alter table bingo_players add column if not exists marks int[] not null default '{}';   -- the squares a player has ticked, so a new phone can pick up where they left off
alter table bingo_players add column if not exists ref text;   -- the player's reference or email, to match PayPal payments (host only)

alter table bingo_rooms enable row level security;
alter table bingo_players enable row level security;
revoke all on bingo_rooms, bingo_players from anon, authenticated;

-- ---------- helpers ----------
create or replace function _bchk(p_room text, p_key text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from bingo_rooms where code = upper(btrim(p_room)) and host_key = p_key) then
    raise exception 'Bad room code or host key';
  end if;
end $$;

-- Deals 25 random songs to a player who has no card yet (needs 25+ songs in the playlist).
create or replace function _bdeal(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update bingo_players p set card = (
    select array_agg(i) from (select i from generate_series(0, jsonb_array_length(r.songs) - 1) i order by random() limit 25) x)
  from bingo_rooms r
  where p.id = p_id and r.code = p.room and cardinality(p.card) = 0 and jsonb_array_length(r.songs) >= 25;
end $$;

-- Checks a card against the songs actually played. A square only counts if it is marked AND has been played.
create or replace function _bcheck(r bingo_rooms, c int[], m int[]) returns json
language plpgsql stable as $$
declare
  L int[] := array[[0,1,2,3,4],[5,6,7,8,9],[10,11,12,13,14],[15,16,17,18,19],[20,21,22,23,24],
                   [0,5,10,15,20],[1,6,11,16,21],[2,7,12,17,22],[3,8,13,18,23],[4,9,14,19,24],
                   [0,6,12,18,24],[4,8,12,16,20]];
  g boolean[] := array_fill(false, array[25]);
  ls int := 0; ok boolean; have int; tot int; kind text;
  k int := coalesce((r.prizes -> r.prize_idx ->> 'k')::int, 1);
  t text := coalesce(r.prizes -> r.prize_idx ->> 't', 'h');   -- which lines count: h = horizontal, v = vertical, d = diagonal, a = any (a mix)
begin
  for i in 0..24 loop g[i+1] := (i = any(coalesce(m, '{}'))) and (c[i+1] = any(r.played)); end loop;
  for n in 1..12 loop
    if (t = 'a' or (t = 'h' and n <= 5) or (t = 'v' and n between 6 and 10) or (t = 'd' and n >= 11)) and g[L[n][1]+1] and g[L[n][2]+1] and g[L[n][3]+1] and g[L[n][4]+1] and g[L[n][5]+1] then ls := ls + 1; end if;
  end loop;
  -- prize kinds: 1-5 = that many lines, 25 = full house, 101 = four corners, 102 = X shape, 103 = postage stamp (2x2 block in any corner)
  kind := case k when 101 then 'corners' when 102 then 'x' when 103 then 'stamp' else case when k >= 25 then 'full' else 'lines' end end;
  if kind = 'lines' then have := ls; tot := k;
  elsif kind = 'full' then have := (select count(*) from unnest(g) x where x); tot := 25;
  elsif kind = 'corners' then have := g[1]::int + g[5]::int + g[21]::int + g[25]::int; tot := 4;
  elsif kind = 'x' then have := g[1]::int + g[5]::int + g[7]::int + g[9]::int + g[13]::int + g[17]::int + g[19]::int + g[21]::int + g[25]::int; tot := 9;
  else have := greatest(g[1]::int + g[2]::int + g[6]::int + g[7]::int, g[4]::int + g[5]::int + g[9]::int + g[10]::int,
                        g[16]::int + g[17]::int + g[21]::int + g[22]::int, g[19]::int + g[20]::int + g[24]::int + g[25]::int); tot := 4;
  end if;
  ok := have >= tot;
  return json_build_object('valid', ok, 'kind', kind, 'dir', t, 'have', have, 'of', tot, 'lines', ls, 'need', k,
    'cells', (select json_agg(json_build_object('t', r.songs ->> c[x+1], 'm', x = any(coalesce(m, '{}')), 'p', c[x+1] = any(r.played)) order by x)
                from generate_series(0, 24) x));
end $$;

-- ---------- host functions ----------
create or replace function bingo_create_room(p_code text, p_key text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into bingo_rooms (code, host_key) values (upper(btrim(p_code)), p_key) on conflict (code) do nothing;
  perform _bchk(p_code, p_key);
end $$;

-- Sets the playlist and prizes and starts a FRESH game: every player is removed, so everyone joins again and gets a new card.
create or replace function bingo_setup(p_room text, p_key text, p_songs text[], p_prizes jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
declare rc text := upper(btrim(p_room));
begin
  perform _bchk(p_room, p_key);
  if coalesce(array_length(p_songs, 1), 0) < 25 then raise exception 'Need at least 25 songs'; end if;
  update bingo_rooms set songs = to_jsonb(p_songs), prizes = coalesce(p_prizes, prizes), played = '{}', prize_idx = 0,
         state = 'lobby', claim_by = null, claim_marks = null, claim_at = null, win = null, winners = '[]', claim_queue = '[]', claim_late = '{}', undo = null
   where code = rc;
  delete from bingo_players where room = rc;
end $$;

-- The host's player calls this as each track STARTS. The first call also starts the game.
create or replace function bingo_play(p_room text, p_key text, p_idx int) returns void
language plpgsql security definer set search_path = public as $$
declare r bingo_rooms;
begin
  perform _bchk(p_room, p_key);
  select * into r from bingo_rooms where code = upper(btrim(p_room));
  if r.state not in ('lobby', 'playing') then raise exception 'Game is %', r.state; end if;
  if p_idx < 0 or p_idx >= jsonb_array_length(r.songs) then raise exception 'Bad song number'; end if;
  update bingo_rooms set state = 'playing', played = case when p_idx = any(played) then played else array_append(played, p_idx) end
   where code = r.code;
end $$;

-- 'paused' (manual pause), 'playing' (resume, or continue after a win; after the LAST prize it ends the game),
-- 'free' (after the last prize: carry on playing the remaining songs, no more prizes), 'ended'.
create or replace function bingo_set_state(p_room text, p_key text, p_state text) returns void
language plpgsql security definer set search_path = public as $$
declare r bingo_rooms;
begin
  perform _bchk(p_room, p_key);
  select * into r from bingo_rooms where code = upper(btrim(p_room));
  if p_state = 'paused' then
    update bingo_rooms set state = 'paused' where code = r.code and state = 'playing';
  elsif p_state = 'playing' then
    if r.claim_by is not null then raise exception 'Judge the bingo call first'; end if;
    update bingo_rooms set win = null, claim_late = '{}',
           state = case when r.state = 'won' and prize_idx >= jsonb_array_length(prizes) then 'ended' else 'playing' end
     where code = r.code;
  elsif p_state = 'free' then
    update bingo_rooms set win = null, claim_late = '{}', state = 'playing' where code = r.code and state = 'won';
  elsif p_state = 'ended' then
    update bingo_rooms set state = 'ended', claim_by = null, claim_marks = null, claim_queue = '[]' where code = r.code;
  else raise exception 'Bad state';
  end if;
end $$;

-- Moves on to the next waiting bingo call (skipping anyone who has left). With nobody waiting, the game resumes.
create or replace function _bnext(rc text) returns void
language plpgsql security definer set search_path = public as $$
declare r bingo_rooms; e jsonb; q jsonb;
begin
  select * into r from bingo_rooms where code = rc for update;
  q := r.claim_queue;
  while jsonb_array_length(q) > 0 loop
    e := q -> 0; q := q - 0;
    if exists (select 1 from bingo_players where id = (e ->> 'p')::uuid) then
      update bingo_rooms set claim_by = (e ->> 'p')::uuid, claim_marks = array(select jsonb_array_elements_text(e -> 'm')::int),
             claim_at = clock_timestamp(), claim_queue = q, state = 'paused' where code = rc;
      return;
    end if;
  end loop;
  update bingo_rooms set claim_by = null, claim_marks = null, claim_at = null, claim_queue = '[]', state = 'playing' where code = rc;
end $$;

-- Host verdict on a pending call. Good call: prize recorded, game stays stopped on 'won' (congratulations)
-- until the host continues. Bad call: caller gets a 30 second cooldown and the game carries on.
create or replace function bingo_judge(p_room text, p_key text, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r bingo_rooms; p bingo_players; w jsonb; late uuid[]; snap jsonb; st text; cb uuid;
begin
  perform _bchk(p_room, p_key);
  select * into r from bingo_rooms where code = upper(btrim(p_room)) for update;
  if r.claim_by is null then raise exception 'No bingo call to judge'; end if;
  select * into p from bingo_players where id = r.claim_by;
  -- remember exactly how things were, so the verdict can be undone for 15 seconds (see bingo_undo)
  snap := jsonb_build_object('at', clock_timestamp(), 'ok', p_ok, 'state', r.state, 'claim_by', r.claim_by, 'claim_marks', to_jsonb(r.claim_marks),
    'claim_at', r.claim_at, 'queue', r.claim_queue, 'prize_idx', r.prize_idx, 'win', r.win, 'winners', r.winners, 'late', to_jsonb(r.claim_late),
    'player', p.id, 'locked', p.locked_until, 'played', cardinality(r.played));
  if p_ok then
    -- good call: prize recorded, anyone still waiting in the queue misses out
    w := jsonb_build_object('name', p.name, 'prize', r.prizes -> r.prize_idx ->> 'n');
    late := coalesce((select array_agg((e ->> 'p')::uuid) from jsonb_array_elements(r.claim_queue) e), '{}');
    update bingo_rooms set state = 'won', win = w, winners = winners || jsonb_build_array(w), prize_idx = prize_idx + 1,
           claim_by = null, claim_marks = null, claim_at = null, claim_queue = '[]', claim_late = late where code = r.code;
  else
    -- bad call: caller gets a cooldown; the next waiting caller (if any) comes up, otherwise the game resumes
    update bingo_players set locked_until = clock_timestamp() + interval '30 seconds' where id = p.id;
    perform _bnext(r.code);
  end if;
  select state, claim_by into st, cb from bingo_rooms where code = r.code;
  update bingo_rooms set undo = snap || jsonb_build_object('after_state', st, 'after_claim', cb) where code = r.code;
end $$;

-- Takes back the last verdict, within 15 seconds, as long as the game hasn't moved on (no Continue, no new song, no new caller).
create or replace function bingo_undo(p_room text, p_key text) returns json
language plpgsql security definer set search_path = public as $$
declare r bingo_rooms; u jsonb;
begin
  perform _bchk(p_room, p_key);
  select * into r from bingo_rooms where code = upper(btrim(p_room)) for update;
  u := r.undo;
  if u is null then raise exception 'Nothing to undo'; end if;
  if clock_timestamp() - (u ->> 'at')::timestamptz > interval '15 seconds' then raise exception 'Too late to undo (15 seconds)'; end if;
  if r.state is distinct from (u ->> 'after_state') or r.claim_by is distinct from (u ->> 'after_claim')::uuid or cardinality(r.played) <> (u ->> 'played')::int then
    raise exception 'The game has moved on, so this can''t be undone'; end if;
  if not exists (select 1 from bingo_players where id = (u ->> 'claim_by')::uuid) then raise exception 'That player has left, so this can''t be undone'; end if;
  update bingo_rooms set state = u ->> 'state', claim_by = (u ->> 'claim_by')::uuid,
         claim_marks = array(select jsonb_array_elements_text(u -> 'claim_marks')::int), claim_at = (u ->> 'claim_at')::timestamptz,
         claim_queue = u -> 'queue', prize_idx = (u ->> 'prize_idx')::int, win = case when u -> 'win' = 'null'::jsonb then null else u -> 'win' end,
         winners = u -> 'winners', claim_late = array(select jsonb_array_elements_text(u -> 'late')::uuid), undo = null
   where code = r.code;
  update bingo_players set locked_until = (u ->> 'locked')::timestamptz where id = (u ->> 'player')::uuid;
  return json_build_object('ok', true, 'was', case when (u ->> 'ok')::boolean then 'valid' else 'not valid' end);
end $$;

-- Host removes one player. If they were the one calling bingo, the call is cleared and the game carries on.
create or replace function bingo_remove_player(p_room text, p_key text, p_player uuid) returns void
language plpgsql security definer set search_path = public as $$
declare rc text := upper(btrim(p_room)); r bingo_rooms;
begin
  perform _bchk(p_room, p_key);
  select * into r from bingo_rooms where code = rc for update;
  delete from bingo_players where id = p_player and room = rc;
  update bingo_rooms set claim_queue = coalesce((select jsonb_agg(e) from jsonb_array_elements(claim_queue) e where e ->> 'p' <> p_player::text), '[]')
   where code = rc;
  if r.claim_by = p_player then perform _bnext(rc); end if;   -- they were mid-call: move on to the next caller, or resume
end $$;

-- Host ticks (or unticks) a player as having paid their entry.
create or replace function bingo_set_paid(p_room text, p_key text, p_player uuid, p_paid boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _bchk(p_room, p_key);
  update bingo_players set paid = coalesce(p_paid, false) where id = p_player and room = upper(btrim(p_room));
end $$;

create or replace function bingo_host_state(p_room text, p_key text) returns json
language plpgsql security definer set search_path = public as $$
declare r bingo_rooms;
begin
  perform _bchk(p_room, p_key);
  select * into r from bingo_rooms where code = upper(btrim(p_room));
  return json_build_object(
    'state', r.state, 'played', to_json(r.played), 'prizes', r.prizes, 'prize_idx', r.prize_idx,
    'win', r.win, 'winners', r.winners,
    'win_ref', (select ref from bingo_players where room = r.code and name = r.win ->> 'name' limit 1),
    'queue', (select coalesce(json_agg(pl.name order by e.o), '[]'::json) from jsonb_array_elements(r.claim_queue) with ordinality e(q, o)
                join bingo_players pl on pl.id = (e.q ->> 'p')::uuid),
    'players', (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'ref', ref, 'paid', paid, 'card', to_json(card),
                  'seen', round(extract(epoch from (clock_timestamp() - last_seen)))) order by joined_at), '[]'::json)
                from bingo_players where room = r.code),
    'claim', case when r.claim_by is not null then (
        select json_build_object('name', p.name, 'ref', p.ref, 'prize', r.prizes -> r.prize_idx ->> 'n', 'check', _bcheck(r, p.card, r.claim_marks))
          from bingo_players p where p.id = r.claim_by) end);
end $$;

create or replace function bingo_delete_room(p_room text, p_key text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _bchk(p_room, p_key);
  delete from bingo_rooms where code = upper(btrim(p_room));
end $$;

-- ---------- player functions ----------
drop function if exists bingo_join(text, text);   -- replaced by the version below, which also takes a reference
create or replace function bingo_join(p_room text, p_name text, p_ref text default null) returns json
language plpgsql security definer set search_path = public as $$
declare t bingo_players; n text := left(btrim(coalesce(p_name, '')), 24); rc text := upper(btrim(coalesce(p_room, '')));
        rf text := left(nullif(btrim(coalesce(p_ref, '')), ''), 80);
begin
  if n = '' then raise exception 'Enter your name'; end if;
  if not exists (select 1 from bingo_rooms where code = rc) then raise exception 'Room not found'; end if;
  begin
    insert into bingo_players (room, name, ref) values (rc, n, rf) returning * into t;
  exception when unique_violation then
    -- the name is taken. If it's the same person on a new phone (same name AND the same reference or email), hand them their card back.
    select * into t from bingo_players where room = rc and lower(name) = lower(n);
    if t.ref is null or rf is null or lower(t.ref) <> lower(rf) then
      raise exception 'That name is already taken. If this is you on a new phone, enter the same reference or email you used before.';
    end if;
    update bingo_players set secret = gen_random_uuid(), last_seen = clock_timestamp() where id = t.id returning * into t;   -- the old phone is signed out
  end;
  perform _bdeal(t.id);
  return json_build_object('id', t.id, 'secret', t.secret, 'name', t.name);
end $$;

-- A player's phone saves which squares they have ticked, so a new phone (or a reload) can restore them.
create or replace function bingo_set_marks(p_room text, p_player uuid, p_secret uuid, p_marks int[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  update bingo_players set marks = coalesce((select array_agg(distinct x order by x) from unnest(p_marks) x where x between 0 and 24), '{}')
   where id = p_player and room = upper(btrim(p_room)) and secret = p_secret;
end $$;

-- A player says "bingo" and sends the squares (0-24) they have marked. Everything stops until the host judges.
-- Only the first call gets in; the server decides who was first.
create or replace function bingo_call(p_room text, p_player uuid, p_secret uuid, p_marks int[]) returns json
language plpgsql security definer set search_path = public as $$
declare p bingo_players; m int[]; r bingo_rooms;
begin
  select * into p from bingo_players where id = p_player and room = upper(btrim(p_room)) and secret = p_secret;
  if not found then raise exception 'You are not in this room'; end if;
  if p.locked_until is not null and p.locked_until > clock_timestamp() then raise exception 'Wait for your cooldown to finish'; end if;
  m := coalesce((select array_agg(distinct x) from unnest(p_marks) x where x between 0 and 24), '{}');
  select * into r from bingo_rooms where code = p.room for update;   -- one call at a time, in the order they reach the server
  if r.prize_idx >= jsonb_array_length(r.prizes) then raise exception 'All the prizes have been won'; end if;
  if r.state not in ('playing', 'paused') then raise exception 'Bingo can''t be called right now'; end if;
  if r.claim_by = p.id or exists (select 1 from jsonb_array_elements(r.claim_queue) e where e ->> 'p' = p.id::text) then
    raise exception 'You have already called bingo'; end if;
  if r.claim_by is null then
    update bingo_rooms set state = 'paused', claim_by = p.id, claim_marks = m, claim_at = clock_timestamp() where code = r.code;
    return json_build_object('ok', true, 'queued', false);
  end if;
  update bingo_rooms set claim_queue = claim_queue || jsonb_build_array(jsonb_build_object('p', p.id, 'm', to_jsonb(m), 'at', clock_timestamp()))
   where code = r.code;   -- someone is already being checked: wait in line
  return json_build_object('ok', true, 'queued', true);
end $$;

-- Polled by players. Never reveals which songs have played.
create or replace function bingo_get_state(p_room text, p_player uuid default null, p_secret uuid default null) returns json
language plpgsql security definer set search_path = public as $$
declare r bingo_rooms; p bingo_players; ok boolean := false;
begin
  select * into r from bingo_rooms where code = upper(btrim(p_room));
  if not found then raise exception 'Room not found'; end if;
  if p_player is not null then
    select * into p from bingo_players where id = p_player and room = r.code and secret = p_secret;
    ok := found;
  end if;
  if ok then
    update bingo_players set last_seen = clock_timestamp()
     where id = p.id and (last_seen is null or last_seen < clock_timestamp() - interval '3 seconds');
    perform _bdeal(p.id);
    select * into p from bingo_players where id = p.id;
  end if;
  return json_build_object(
    'state', r.state, 'prize', r.prizes -> r.prize_idx ->> 'n', 'pk', coalesce((r.prizes -> r.prize_idx ->> 'k')::int, 0), 'pt', coalesce(r.prizes -> r.prize_idx ->> 't', 'h'),
    'pnum', least(r.prize_idx + 1, jsonb_array_length(r.prizes)), 'ptotal', jsonb_array_length(r.prizes),
    'win', r.win, 'winners', r.winners,
    'caller', (select name from bingo_players where id = r.claim_by),
    'mine_call', coalesce(r.claim_by = p_player, false),
    'queued', case when ok then coalesce((select e.o from jsonb_array_elements(r.claim_queue) with ordinality e(q, o) where e.q ->> 'p' = p_player::text), 0) else 0 end,
    'late', case when ok then coalesce(p_player = any(r.claim_late), false) else false end,
    'me', case when ok then json_build_object('valid', true, 'name', p.name, 'marks', to_json(p.marks),
            'card', (select json_agg(r.songs ->> c order by o) from unnest(p.card) with ordinality t(c, o)),
            'cool', greatest(0, round(extract(epoch from (p.locked_until - clock_timestamp())) * 1000)))
          else json_build_object('valid', false) end);
end $$;
