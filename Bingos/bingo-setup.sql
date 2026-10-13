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
  ls int := 0; ok boolean;
  k int := coalesce((r.prizes -> r.prize_idx ->> 'k')::int, 1);
begin
  for i in 0..24 loop g[i+1] := (i = any(coalesce(m, '{}'))) and (c[i+1] = any(r.played)); end loop;
  for n in 1..12 loop
    if g[L[n][1]+1] and g[L[n][2]+1] and g[L[n][3]+1] and g[L[n][4]+1] and g[L[n][5]+1] then ls := ls + 1; end if;
  end loop;
  ok := case when k >= 25 then not (false = any(g)) else ls >= k end;
  return json_build_object('valid', ok, 'lines', ls, 'need', k,
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
         state = 'lobby', claim_by = null, claim_marks = null, claim_at = null, win = null, winners = '[]'
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
    update bingo_rooms set win = null,
           state = case when r.state = 'won' and prize_idx >= jsonb_array_length(prizes) then 'ended' else 'playing' end
     where code = r.code;
  elsif p_state = 'free' then
    update bingo_rooms set win = null, state = 'playing' where code = r.code and state = 'won';
  elsif p_state = 'ended' then
    update bingo_rooms set state = 'ended', claim_by = null, claim_marks = null where code = r.code;
  else raise exception 'Bad state';
  end if;
end $$;

-- Host verdict on a pending call. Good call: prize recorded, game stays stopped on 'won' (congratulations)
-- until the host continues. Bad call: caller gets a 30 second cooldown and the game carries on.
create or replace function bingo_judge(p_room text, p_key text, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r bingo_rooms; p bingo_players; w jsonb;
begin
  perform _bchk(p_room, p_key);
  select * into r from bingo_rooms where code = upper(btrim(p_room));
  if r.claim_by is null then raise exception 'No bingo call to judge'; end if;
  select * into p from bingo_players where id = r.claim_by;
  if p_ok then
    w := jsonb_build_object('name', p.name, 'prize', r.prizes -> r.prize_idx ->> 'n');
    update bingo_rooms set state = 'won', win = w, winners = winners || jsonb_build_array(w), prize_idx = prize_idx + 1,
           claim_by = null, claim_marks = null, claim_at = null where code = r.code;
  else
    update bingo_players set locked_until = clock_timestamp() + interval '30 seconds' where id = p.id;
    update bingo_rooms set state = 'playing', claim_by = null, claim_marks = null, claim_at = null where code = r.code;
  end if;
end $$;

-- Host removes one player. If they were the one calling bingo, the call is cleared and the game carries on.
create or replace function bingo_remove_player(p_room text, p_key text, p_player uuid) returns void
language plpgsql security definer set search_path = public as $$
declare rc text := upper(btrim(p_room));
begin
  perform _bchk(p_room, p_key);
  delete from bingo_players where id = p_player and room = rc;
  update bingo_rooms set claim_by = null, claim_marks = null, claim_at = null,
         state = case when state = 'paused' then 'playing' else state end
   where code = rc and claim_by = p_player;
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
    'players', (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'card', to_json(card),
                  'seen', round(extract(epoch from (clock_timestamp() - last_seen)))) order by joined_at), '[]'::json)
                from bingo_players where room = r.code),
    'claim', case when r.claim_by is not null then (
        select json_build_object('name', p.name, 'prize', r.prizes -> r.prize_idx ->> 'n', 'check', _bcheck(r, p.card, r.claim_marks))
          from bingo_players p where p.id = r.claim_by) end);
end $$;

create or replace function bingo_delete_room(p_room text, p_key text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _bchk(p_room, p_key);
  delete from bingo_rooms where code = upper(btrim(p_room));
end $$;

-- ---------- player functions ----------
create or replace function bingo_join(p_room text, p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare t bingo_players; n text := left(btrim(coalesce(p_name, '')), 24); rc text := upper(btrim(coalesce(p_room, '')));
begin
  if n = '' then raise exception 'Enter your name'; end if;
  if not exists (select 1 from bingo_rooms where code = rc) then raise exception 'Room not found'; end if;
  begin
    insert into bingo_players (room, name) values (rc, n) returning * into t;
  exception when unique_violation then
    raise exception 'That name is already taken';
  end;
  perform _bdeal(t.id);
  return json_build_object('id', t.id, 'secret', t.secret, 'name', t.name);
end $$;

-- A player says "bingo" and sends the squares (0-24) they have marked. Everything stops until the host judges.
-- Only the first call gets in; the server decides who was first.
create or replace function bingo_call(p_room text, p_player uuid, p_secret uuid, p_marks int[]) returns json
language plpgsql security definer set search_path = public as $$
declare p bingo_players; m int[];
begin
  select * into p from bingo_players where id = p_player and room = upper(btrim(p_room)) and secret = p_secret;
  if not found then raise exception 'You are not in this room'; end if;
  if p.locked_until is not null and p.locked_until > clock_timestamp() then raise exception 'Wait for your cooldown to finish'; end if;
  if (select prize_idx >= jsonb_array_length(prizes) from bingo_rooms where code = p.room) then raise exception 'All the prizes have been won'; end if;
  m := coalesce((select array_agg(distinct x) from unnest(p_marks) x where x between 0 and 24), '{}');
  update bingo_rooms set state = 'paused', claim_by = p.id, claim_marks = m, claim_at = clock_timestamp()
   where code = p.room and state in ('playing', 'paused') and claim_by is null;
  if not found then raise exception 'Bingo can''t be called right now'; end if;
  return json_build_object('ok', true);
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
    'state', r.state, 'prize', r.prizes -> r.prize_idx ->> 'n',
    'pnum', least(r.prize_idx + 1, jsonb_array_length(r.prizes)), 'ptotal', jsonb_array_length(r.prizes),
    'win', r.win, 'winners', r.winners,
    'caller', (select name from bingo_players where id = r.claim_by),
    'mine_call', coalesce(r.claim_by = p_player, false),
    'me', case when ok then json_build_object('valid', true, 'name', p.name,
            'card', (select json_agg(r.songs ->> c order by o) from unnest(p.card) with ordinality t(c, o)),
            'cool', greatest(0, round(extract(epoch from (p.locked_until - clock_timestamp())) * 1000)))
          else json_build_object('valid', false) end);
end $$;
