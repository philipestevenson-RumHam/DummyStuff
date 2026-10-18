-- RumHam Quiz: play-at-home setup. Run once in Supabase > SQL Editor.
-- Safe to re-run: tables use "if not exists", functions use "create or replace".

create table if not exists rooms (
  code       text primary key,
  host_key   text not null,
  state      text not null default 'idle' check (state in ('idle','open','closed','revealed')),
  qkey       text,
  opened_at  timestamptz,
  correct    text[] not null default '{}',
  done       text[] not null default '{}',
  created_at timestamptz not null default now()
);

create table if not exists teams (
  id        uuid primary key default gen_random_uuid(),
  room      text not null references rooms(code) on delete cascade,
  name      text not null,
  secret    uuid not null default gen_random_uuid(),
  joined_at timestamptz not null default now()
);
create unique index if not exists teams_room_name on teams (room, lower(name));

create table if not exists answers (
  room         text not null references rooms(code) on delete cascade,
  qkey         text not null,
  team_id      uuid not null references teams(id) on delete cascade,
  letter       text not null,
  submitted_at timestamptz not null default clock_timestamp(),
  correct      boolean,
  bonus        int not null default 0,
  points       int not null default 0,
  primary key (room, qkey, team_id)
);
alter table answers add column if not exists opened_at timestamptz;

-- Added later: question text, answer text and a synced timer (safe to re-run).
alter table rooms add column if not exists qtext text;
alter table rooms add column if not exists atext text;
alter table rooms add column if not exists timer_state text not null default 'idle';
alter table rooms add column if not exists timer_end timestamptz;
alter table rooms add column if not exists timer_left int;
alter table rooms add column if not exists pts int not null default 5;
alter table rooms add column if not exists b1  int not null default 3;
alter table rooms add column if not exists b2  int not null default 2;
alter table rooms add column if not exists b3  int not null default 1;
alter table rooms add column if not exists qtype text not null default 'letter';
alter table rooms add column if not exists qopts text[];
alter table rooms add column if not exists phase text not null default 'contents';
alter table rooms add column if not exists pinfo jsonb;
alter table rooms add column if not exists pen_kind text not null default 'none';
alter table rooms add column if not exists pen int not null default 0;
alter table rooms add column if not exists qshow boolean not null default true;
alter table rooms add column if not exists kpshow boolean not null default true;
alter table rooms add column if not exists voided text[] not null default '{}';
alter table rooms add column if not exists fast boolean not null default false;
alter table answers add column if not exists blank boolean not null default false;
alter table teams add column if not exists last_seen timestamptz default now();

-- One-off point changes made by the host: gifts and steals. Each steal is a pair of rows that share a "pair" id.
create table if not exists adjustments (
  id         bigserial primary key,
  room       text not null references rooms(code) on delete cascade,
  team_id    uuid not null references teams(id) on delete cascade,
  delta      int not null,
  kind       text not null,
  pair       uuid not null,
  qkey       text,
  created_at timestamptz not null default now()
);

-- Nobody can touch the tables directly. Everything goes through the functions below.
alter table rooms   enable row level security;
alter table teams   enable row level security;
alter table answers enable row level security;
alter table adjustments enable row level security;
revoke all on rooms, teams, answers, adjustments from anon, authenticated;

-- ---------- helpers ----------
-- A team's total: question points (with bonuses and penalties) plus gifts and steals.
create or replace function _tot(p_team uuid) returns int
language sql stable as $$
  select coalesce((select sum(points) from answers where team_id = p_team), 0)::int
       + coalesce((select sum(delta) from adjustments where team_id = p_team), 0)::int
$$;

create or replace function _chk(p_room text, p_key text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from rooms where code = upper(btrim(p_room)) and host_key = p_key) then
    raise exception 'Bad room code or host key';
  end if;
end $$;

-- ---------- host functions ----------
create or replace function create_room(p_code text, p_key text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into rooms (code, host_key) values (upper(btrim(p_code)), p_key) on conflict (code) do nothing;
  perform _chk(p_code, p_key);
end $$;

create or replace function delete_room(p_room text, p_key text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  delete from rooms where code = upper(btrim(p_room));
end $$;

-- Opens a question for answers. Calling it again for the same open question only updates the accepted answers, text and scoring.
-- p_fast: fast track question. A new question starts with qshow = false (the question text is hidden from the phones until set_qshow).
-- p_evil_kind is 'none', 'evil' (wrong answers lose p_penalty points) or 'really' (wrong answers AND no answer lose p_penalty points).
-- p_qtype is 'letter', 'number', 'multi', 'multisel' or 'sort'.
--   sort: like multi, but p_correct holds ONE string with the positions in the right order, e.g. '5,4,3,2,1,0'.
--   multisel: like multi, but p_correct holds ONE string of every right position, sorted, e.g. '1,3,5'.
--   number: p_correct holds the one right whole number as text.
--   multi:  p_options holds 2 to 6 option texts and p_correct holds the position (0 to 5) of the right one.
drop function if exists open_question(text, text, text, text[]);
drop function if exists open_question(text, text, text, text[], text, text);
drop function if exists open_question(text, text, text, text[], text, text, int, int, int, int);
drop function if exists open_question(text, text, text, text[], text, text, int, int, int, int, text);
drop function if exists open_question(text, text, text, text[], text, text, int, int, int, int, text, text[]);
drop function if exists open_question(text, text, text, text[], text, text, int, int, int, int, text, text[], text, int);
create or replace function open_question(p_room text, p_key text, p_qkey text, p_correct text[],
                                         p_question text default null, p_answer text default null,
                                         p_points int default 5, p_b1 int default 3, p_b2 int default 2, p_b3 int default 1,
                                         p_qtype text default 'letter', p_options text[] default null,
                                         p_evil_kind text default 'none', p_penalty int default 0, p_fast boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare r rooms;
        v_type text := case when p_qtype in ('number', 'multi', 'multisel', 'sort') then p_qtype else 'letter' end;
        c text[];
        v_opts text[] := null;
        v_pen int := greatest(0, coalesce(p_penalty, 0));
        v_kind text := case when p_evil_kind in ('evil', 'really') and coalesce(p_penalty, 0) > 0 then p_evil_kind else 'none' end;
        v_pts int := greatest(0, coalesce(p_points, 5)); v1 int := greatest(0, coalesce(p_b1, 3));
        v2 int := greatest(0, coalesce(p_b2, 2));         v3 int := greatest(0, coalesce(p_b3, 1));
begin
  perform _chk(p_room, p_key);
  if v_type = 'number' then
    c := coalesce((select array_agg(regexp_replace(btrim(x), '^0+(?=[0-9])', '')) from unnest(p_correct) x), '{}');
  elsif v_type in ('multi', 'multisel', 'sort') then
    if coalesce(array_length(p_options, 1), 0) not between 2 and 6 then raise exception 'Multiple choice needs 2 to 6 options'; end if;
    v_opts := p_options;
    c := coalesce((select array_agg(btrim(x)) from unnest(p_correct) x), '{}');
  else
    c := coalesce((select array_agg(upper(x)) from unnest(p_correct) x), '{}');
  end if;
  select * into r from rooms where code = upper(btrim(p_room));
  if r.qkey is not distinct from p_qkey and r.state <> 'idle' then
    update rooms set correct = c, qtext = p_question, atext = p_answer, qtype = v_type, qopts = v_opts,
                     pts = v_pts, b1 = v1, b2 = v2, b3 = v3, pen_kind = v_kind, pen = v_pen, fast = coalesce(p_fast, false), phase = 'quiz', pinfo = null where code = r.code;
    return;
  end if;
  update rooms set
    qkey = p_qkey,
    correct = c,
    qtext = p_question,
    atext = p_answer,
    qtype = v_type, qopts = v_opts,
    pts = v_pts, b1 = v1, b2 = v2, b3 = v3, pen_kind = v_kind, pen = v_pen, fast = coalesce(p_fast, false), qshow = (p_qkey = any(done) or p_qkey = any(voided)), kpshow = (p_qkey = any(done) or p_qkey = any(voided)), phase = 'quiz', pinfo = null,
    timer_state = 'idle', timer_end = null, timer_left = null,
    state = case when p_qkey = any(voided) then 'closed' when p_qkey = any(done) then 'revealed' else 'open' end,
    opened_at = case when p_qkey = any(done) or p_qkey = any(voided) then opened_at else clock_timestamp() end
  where code = r.code;
end $$;

-- Opens (or closes) the answer inputs on the phones. A new question starts closed. Answers are refused until it is open.
create or replace function set_kpshow(p_room text, p_key text, p_show boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  update rooms set kpshow = coalesce(p_show, true) where code = upper(btrim(p_room));
end $$;

-- Shows (or hides) the question text on the phones. A new question starts hidden; reveal also shows it.
create or replace function set_qshow(p_room text, p_key text, p_show boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  update rooms set qshow = coalesce(p_show, true) where code = upper(btrim(p_room));
end $$;

-- Tells the phones which screen the host is on (contents, round, quiz, score or end) and what to show there.
create or replace function set_phase(p_room text, p_key text, p_phase text, p_info jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  if p_phase not in ('contents', 'round', 'quiz', 'score', 'end') then raise exception 'Bad phase'; end if;
  update rooms set phase = p_phase, pinfo = p_info where code = upper(btrim(p_room));
end $$;

-- Keeps the players' countdown in step with the host's timer.
create or replace function set_timer(p_room text, p_key text, p_state text, p_left int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  if p_state not in ('idle', 'run', 'pause', 'done') then raise exception 'Bad timer state'; end if;
  update rooms set
    timer_state = p_state,
    timer_left  = greatest(0, coalesce(p_left, 0)),
    timer_end   = case when p_state = 'run' then clock_timestamp() + (greatest(0, coalesce(p_left, 0)) * interval '1 millisecond') end
  where code = upper(btrim(p_room));
end $$;

-- 'idle' (between questions) or 'closed' (timer ran out; only from open).
create or replace function set_state(p_room text, p_key text, p_state text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  if p_state = 'idle' then
    update rooms set state = 'idle' where code = upper(btrim(p_room));
  elsif p_state = 'closed' then
    update rooms set state = 'closed' where code = upper(btrim(p_room)) and state = 'open';
  else
    raise exception 'Bad state';
  end if;
end $$;

-- Marks the question: the question's points for a correct answer, plus the 1st / 2nd / 3rd fastest bonuses (by server time).
create or replace function reveal_question(p_room text, p_key text) returns void
language plpgsql security definer set search_path = public as $$
declare r rooms;
begin
  perform _chk(p_room, p_key);
  select * into r from rooms where code = upper(btrim(p_room));
  if r.qkey is null then raise exception 'No question is open'; end if;
  if r.qkey = any(r.voided) then raise exception 'This question has been voided'; end if;

  delete from adjustments where room = r.code and qkey = r.qkey and kind = 'fasttrack';
  delete from answers where room = r.code and qkey = r.qkey and blank;
  update answers set correct = (letter = any(r.correct)), bonus = 0, points = 0
   where room = r.code and qkey = r.qkey;

  with ranked as (
    select team_id, row_number() over (order by submitted_at, team_id) as rn
      from answers where room = r.code and qkey = r.qkey and correct
  )
  update answers a set
    bonus  = case when k.rn = 1 then r.b1 when k.rn = 2 then r.b2 when k.rn = 3 then r.b3 else 0 end,
    points = r.pts + case when k.rn = 1 then r.b1 when k.rn = 2 then r.b2 when k.rn = 3 then r.b3 else 0 end
  from ranked k
  where a.room = r.code and a.qkey = r.qkey and a.team_id = k.team_id;

  if r.pen_kind in ('evil', 'really') and r.pen > 0 then
    update answers set points = -r.pen where room = r.code and qkey = r.qkey and not correct;
    if r.pen_kind = 'really' then
      -- teams that were already in the room when the question opened and gave no answer also lose the points
      insert into answers (room, qkey, team_id, letter, correct, bonus, points, blank)
      select r.code, r.qkey, t.id, '', false, 0, -r.pen, true
        from teams t
       where t.room = r.code and t.joined_at <= coalesce(r.opened_at, clock_timestamp())
         and not exists (select 1 from answers a where a.room = r.code and a.qkey = r.qkey and a.team_id = t.id);
    end if;
  end if;

  -- Fast track: if exactly ONE team is correct and it is below the leader, lift it to one point above the leader.
  if r.fast then
    declare nc int; ct uuid; mine int; lead int;
    begin
      select count(*) into nc from answers where room = r.code and qkey = r.qkey and correct;
      if nc = 1 then
        select team_id into ct from answers where room = r.code and qkey = r.qkey and correct;
        mine := _tot(ct);
        select max(_tot(t.id)) into lead from teams t where t.room = r.code and t.id <> ct;
        if lead is not null and mine < lead then
          insert into adjustments (room, team_id, delta, kind, pair, qkey)
          values (r.code, ct, lead + 1 - mine, 'fasttrack', gen_random_uuid(), r.qkey);
        end if;
      end if;
    end;
  end if;

  update rooms set state = 'revealed', qshow = true, kpshow = true,
         done = case when r.qkey = any(done) then done else array_append(done, r.qkey) end
   where code = r.code;
end $$;

create or replace function host_state(p_room text, p_key text) returns json
language plpgsql security definer set search_path = public as $$
declare r rooms;
begin
  perform _chk(p_room, p_key);
  select * into r from rooms where code = upper(btrim(p_room));
  return json_build_object(
    'state', r.state, 'qkey', r.qkey, 'opened_at', r.opened_at, 'now', clock_timestamp(), 'correct', r.correct,
    'fast', r.fast, 'void', (r.qkey = any(r.voided)), 'voided', r.voided,
    'ft', (select json_build_object('name', t.name, 'delta', j.delta, 'after', _tot(t.id))
             from adjustments j join teams t on t.id = j.team_id
            where j.room = r.code and j.qkey = r.qkey and j.kind = 'fasttrack' limit 1),
    'answered', (select count(*) from answers where room = r.code and qkey = r.qkey and not blank),
    'lost',     (select count(*) from answers where room = r.code and qkey = r.qkey and points < 0),
    'right',    (select count(*) from answers where room = r.code and qkey = r.qkey and correct),
    'teams', (
      select coalesce(json_agg(json_build_object(
        'id', t.id, 'name', t.name, 'letter', case when a.blank then null else a.letter end,
        'seen', round(extract(epoch from (clock_timestamp() - t.last_seen))),
        'ms', case when a.letter is null or a.blank or r.opened_at is null then null
                   else round(extract(epoch from (a.submitted_at - r.opened_at)) * 1000) end,
        'ok', a.correct, 'bonus', coalesce(a.bonus, 0), 'points', coalesce(a.points, 0),
        'total', _tot(t.id)
      ) order by t.joined_at), '[]'::json)
      from teams t
      left join answers a on a.team_id = t.id and a.room = r.code and a.qkey = r.qkey
      where t.room = r.code)
  );
end $$;

-- Points per team per round (round = the part of qkey before the dash), for importing into the Scores slide.
create or replace function host_rounds(p_room text, p_key text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  return (
    select coalesce(json_agg(json_build_object(
      'id', t.id, 'name', t.name,
      'rounds', (select coalesce(json_object_agg(z.rd, z.pts), '{}'::json)
                   from (select u.rd, sum(u.pts) as pts
                           from (select split_part(qkey, '-', 1) as rd, points as pts from answers where team_id = t.id
                                 union all
                                 select split_part(qkey, '-', 1), delta from adjustments where team_id = t.id and qkey is not null) u
                          group by u.rd) z)
    ) order by t.joined_at), '[]'::json)
    from teams t where t.room = upper(btrim(p_room)));
end $$;

-- Rename (p_name given) or remove (p_name null) a team.
create or replace function host_team(p_room text, p_key text, p_team uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  if p_name is null then
    delete from teams where id = p_team and room = upper(btrim(p_room));
  else
    update teams set name = left(btrim(p_name), 24) where id = p_team and room = upper(btrim(p_room));
  end if;
exception when unique_violation then
  raise exception 'That team name is already taken';
end $$;

-- ---------- player functions ----------
create or replace function join_team(p_room text, p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare t teams; n text := left(btrim(coalesce(p_name, '')), 24); rc text := upper(btrim(coalesce(p_room, '')));
begin
  if n = '' then raise exception 'Enter a team name'; end if;
  if not exists (select 1 from rooms where code = rc) then raise exception 'Room not found'; end if;
  begin
    insert into teams (room, name) values (rc, n) returning * into t;
  exception when unique_violation then
    raise exception 'That team name is already taken';
  end;
  return json_build_object('id', t.id, 'secret', t.secret, 'name', t.name);
end $$;

-- The server stamps the time. The first tap locks the answer.
create or replace function submit_answer(p_room text, p_team uuid, p_secret uuid, p_letter text) returns json
language plpgsql security definer set search_path = public as $$
declare r rooms; a answers; l text;
begin
  select * into r from rooms where code = upper(btrim(p_room));
  if not found then raise exception 'Room not found'; end if;
  if not exists (select 1 from teams where id = p_team and room = r.code and secret = p_secret) then
    raise exception 'You are not in this room';
  end if;
  if r.state = 'open' and not r.kpshow then raise exception 'The keypad is not open yet'; end if;
  if r.qtype = 'number' then
    l := btrim(coalesce(p_letter, ''));
    if l !~ '^[0-9]{1,9}$' then raise exception 'Enter a whole number'; end if;
    l := regexp_replace(l, '^0+(?=[0-9])', '');
  elsif r.qtype = 'multi' then
    l := btrim(coalesce(p_letter, ''));
    if l !~ '^[0-5]$' or l::int >= coalesce(array_length(r.qopts, 1), 0) then raise exception 'Pick one of the options'; end if;
  elsif r.qtype = 'multisel' then
    l := btrim(coalesce(p_letter, ''));
    if l !~ '^[0-5]$' or l::int >= coalesce(array_length(r.qopts, 1), 0) then raise exception 'Pick one of the options'; end if;
  elsif r.qtype = 'sort' then
    -- the whole order arrives at once, e.g. '5,4,3,2,1,0': every option exactly once
    l := regexp_replace(coalesce(p_letter, ''), '\s', '', 'g');
    if l !~ '^[0-5](,[0-5])*$'
       or array_length(string_to_array(l, ','), 1) <> coalesce(array_length(r.qopts, 1), 0)
       or (select count(distinct x) from unnest(string_to_array(l, ',')) x) <> coalesce(array_length(r.qopts, 1), 0)
       or exists (select 1 from unnest(string_to_array(l, ',')) x where x::int >= coalesce(array_length(r.qopts, 1), 0))
    then raise exception 'Put every option in order'; end if;
  else
    l := upper(left(btrim(coalesce(p_letter, '')), 1));
    if l !~ '^[A-Z]$' then raise exception 'Pick a letter'; end if;
  end if;

  -- Select-many: every tap adds one position to the team's selection. Taps can't be undone.
  -- The answer time is the time of the LAST new tap.
  if r.qtype = 'multisel' then
    if r.state <> 'open' then raise exception 'Answers are closed'; end if;
    insert into answers (room, qkey, team_id, letter, opened_at) values (r.code, r.qkey, p_team, l, r.opened_at)
    on conflict (room, qkey, team_id) do update set
      letter = case when l = any(string_to_array(answers.letter, ','))
                    then answers.letter
                    else (select string_agg(x, ',' order by x::int)
                            from unnest(array_append(string_to_array(answers.letter, ','), l)) x) end,
      submitted_at = case when l = any(string_to_array(answers.letter, ','))
                          then answers.submitted_at else clock_timestamp() end
    returning * into a;
    return json_build_object('ok', true, 'letter', a.letter,
      'ms', round(extract(epoch from (a.submitted_at - r.opened_at)) * 1000));
  end if;

  select * into a from answers where room = r.code and qkey = r.qkey and team_id = p_team;
  if found then return json_build_object('ok', false, 'locked', true, 'letter', a.letter); end if;
  if r.state <> 'open' then raise exception 'Answers are closed'; end if;

  insert into answers (room, qkey, team_id, letter, opened_at) values (r.code, r.qkey, p_team, l, r.opened_at)
    on conflict do nothing returning * into a;
  if not found then
    select * into a from answers where room = r.code and qkey = r.qkey and team_id = p_team;
    return json_build_object('ok', false, 'locked', true, 'letter', a.letter);
  end if;
  return json_build_object('ok', true, 'letter', a.letter,
    'ms', round(extract(epoch from (a.submitted_at - r.opened_at)) * 1000));
end $$;

-- Polled by players about once a second. The correct letter is only sent after the reveal.
create or replace function get_state(p_room text, p_team uuid default null, p_secret uuid default null) returns json
language plpgsql security definer set search_path = public as $$
declare r rooms; me uuid; tot int; mine json := null; a answers;
begin
  select * into r from rooms where code = upper(btrim(p_room));
  if not found then raise exception 'Room not found'; end if;

  if p_team is not null then
    if exists (select 1 from teams where id = p_team and room = r.code and secret = p_secret) then
      me := p_team;
      update teams set last_seen = clock_timestamp()
       where id = me and (last_seen is null or last_seen < clock_timestamp() - interval '3 seconds');
      tot := _tot(me);
      select * into a from answers where room = r.code and qkey = r.qkey and team_id = me;
      mine := json_build_object(
        'valid', true, 'letter', case when a.blank then null else a.letter end,
        'ms', case when a.letter is null or a.blank or r.opened_at is null then null
                   else round(extract(epoch from (a.submitted_at - r.opened_at)) * 1000) end,
        'ok', case when r.state = 'revealed' then a.correct end,
        'points', case when r.state = 'revealed' then a.points end,
        'bonus', case when r.state = 'revealed' then a.bonus end,
        'total', tot,
        'rank', 1 + (select count(*) from teams tt where tt.room = r.code and _tot(tt.id) > tot));
    else
      mine := json_build_object('valid', false);
    end if;
  end if;

  return json_build_object(
    'state', r.state, 'qkey', r.qkey, 'now', clock_timestamp(),
    'void', (r.state <> 'idle' and r.qkey = any(r.voided)),
    'q', case when r.state <> 'idle' and r.qshow then r.qtext end,
    'qhidden', (r.state <> 'idle' and not r.qshow),
    'fast', case when r.state <> 'idle' and r.fast then true end,
    'ft', case when r.state = 'revealed' then (select json_build_object('name', t.name, 'delta', j.delta)
            from adjustments j join teams t on t.id = j.team_id
           where j.room = r.code and j.qkey = r.qkey and j.kind = 'fasttrack' limit 1) end,
    'qtype', case when r.state <> 'idle' then r.qtype end,
    'opts', case when r.state <> 'idle' and r.kpshow and r.qtype in ('multi', 'multisel', 'sort') then to_json(r.qopts) end,
    'kphidden', (r.state <> 'idle' and not r.kpshow),
    'evil', case when r.state <> 'idle' and r.pen_kind <> 'none' then json_build_object('kind', r.pen_kind, 'pts', r.pen) end,
    'phase', r.phase,
    'pinfo', case when r.state = 'idle' then r.pinfo end,
    'a', case when r.state = 'revealed' then r.atext end,
    'timer', json_build_object('state', r.timer_state,
        'left', case when r.timer_state = 'run'
                     then greatest(0, round(extract(epoch from (r.timer_end - clock_timestamp())) * 1000))
                     else r.timer_left end),
    'correct', case when r.state = 'revealed' then to_json(r.correct) end,
    'me', mine,
    'fastest', case when r.state = 'revealed' then (
        select coalesce(json_agg(json_build_object('name', t.name, 'bonus', x.bonus) order by x.bonus desc), '[]'::json)
          from answers x join teams t on t.id = x.team_id
         where x.room = r.code and x.qkey = r.qkey and x.bonus > 0) end
  );
end $$;

-- ---------- clean-up controls (used by the Controls tab) ----------
create or replace function _reset_room(p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update rooms set state = 'idle', qkey = null, qtext = null, atext = null, correct = '{}', done = '{}',
         opened_at = null, timer_state = 'idle', timer_end = null, timer_left = null
   where code = p_code;
end $$;

-- Wipes every answer and point. Teams stay in the room.
create or replace function clear_answers(p_room text, p_key text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  delete from answers where room = upper(btrim(p_room));
  delete from adjustments where room = upper(btrim(p_room));
  perform _reset_room(upper(btrim(p_room)));
end $$;

-- Removes every team (and so every answer and point). The room and its code stay.
create or replace function clear_teams(p_room text, p_key text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  delete from teams where room = upper(btrim(p_room));
  perform _reset_room(upper(btrim(p_room)));
end $$;

-- Wipes the answers for one question and opens it again if it is the current one.
create or replace function clear_question(p_room text, p_key text, p_qkey text) returns void
language plpgsql security definer set search_path = public as $$
declare rc text := upper(btrim(p_room));
begin
  perform _chk(p_room, p_key);
  delete from answers where room = rc and qkey = p_qkey;
  delete from adjustments where room = rc and qkey = p_qkey and kind = 'fasttrack';
  update rooms set done = array_remove(done, p_qkey), voided = array_remove(voided, p_qkey) where code = rc;
  update rooms set state = 'open', opened_at = clock_timestamp(),
         timer_state = 'idle', timer_end = null, timer_left = null
   where code = rc and qkey = p_qkey;
end $$;

-- ---------- gifts and steals (the ADJUST button) ----------
-- gift: p_pts points appear for p_to. steal: p_pts points move from p_from to p_to. Totals may go below zero.
create or replace function host_adjust(p_room text, p_key text, p_kind text, p_from uuid, p_to uuid, p_pts int, p_qkey text default null) returns void
language plpgsql security definer set search_path = public as $$
declare rc text := upper(btrim(p_room)); pr uuid := gen_random_uuid(); qk text; n int := coalesce(p_pts, 0);
begin
  perform _chk(p_room, p_key);
  if p_kind not in ('gift', 'steal') then raise exception 'Bad adjustment'; end if;
  if n < 1 or n > 100000 then raise exception 'Enter a number of points'; end if;
  if not exists (select 1 from teams where id = p_to and room = rc) then raise exception 'Choose the team that receives the points'; end if;
  select coalesce(p_qkey, r.qkey, '0-0') into qk from rooms r where r.code = rc;
  if p_kind = 'steal' then
    if p_from is null or p_from = p_to or not exists (select 1 from teams where id = p_from and room = rc) then
      raise exception 'Choose two different teams';
    end if;
    insert into adjustments (room, team_id, delta, kind, pair, qkey) values (rc, p_from, -n, 'steal', pr, qk), (rc, p_to, n, 'steal', pr, qk);
  else
    insert into adjustments (room, team_id, delta, kind, pair, qkey) values (rc, p_to, n, 'gift', pr, qk);
  end if;
end $$;

-- The adjustments made so far, newest first, one row per gift or steal.
create or replace function host_adjustments(p_room text, p_key text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  return (
    select coalesce(json_agg(x order by x.at desc), '[]'::json) from (
      select j.pair, min(j.kind) as kind, max(j.created_at) as at,
             max(case when j.delta < 0 then t.name end) as from_name,
             max(case when j.delta > 0 then t.name end) as to_name,
             max(abs(j.delta)) as pts, min(j.qkey) as qkey
        from adjustments j join teams t on t.id = j.team_id
       where j.room = upper(btrim(p_room))
       group by j.pair) x);
end $$;

create or replace function host_undo_adjust(p_room text, p_key text, p_pair uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_room, p_key);
  delete from adjustments where room = upper(btrim(p_room)) and pair = p_pair;
end $$;

-- ---------- void a question (Controls tab) ----------
-- Wipes every answer, bonus and penalty for the question (gifts and steals stay), and marks it void:
-- it can't be opened, answered or revealed again. If it is the question on screen, phones and OBS show "Question void".
create or replace function void_question(p_room text, p_key text, p_qkey text) returns void
language plpgsql security definer set search_path = public as $$
declare rc text := upper(btrim(p_room));
begin
  perform _chk(p_room, p_key);
  if p_qkey is null or btrim(p_qkey) = '' then raise exception 'Choose a question'; end if;
  delete from answers where room = rc and qkey = p_qkey;
  delete from adjustments where room = rc and qkey = p_qkey and kind = 'fasttrack';
  update rooms set voided = case when p_qkey = any(voided) then voided else array_append(voided, p_qkey) end,
                   done = array_remove(done, p_qkey)
   where code = rc;
  update rooms set state = 'closed', qshow = true, kpshow = true, timer_state = 'idle', timer_end = null, timer_left = null
   where code = rc and qkey = p_qkey and state <> 'idle';
end $$;

-- Takes the void off. If it is the question on screen it opens again, with the keypad and question hidden.
create or replace function unvoid_question(p_room text, p_key text, p_qkey text) returns void
language plpgsql security definer set search_path = public as $$
declare rc text := upper(btrim(p_room));
begin
  perform _chk(p_room, p_key);
  update rooms set voided = array_remove(voided, p_qkey) where code = rc;
  update rooms set state = 'open', opened_at = clock_timestamp(), qshow = false, kpshow = false,
                   timer_state = 'idle', timer_end = null, timer_left = null
   where code = rc and qkey = p_qkey and state <> 'idle';
end $$;

-- ---------- version marker (the Test connection button compares this with the host page) ----------
create or replace function app_version() returns text
language sql immutable as $$ select '2026-10-17'::text $$;

-- ---------- everything that happened, for the results CSV ----------
create or replace function host_results(p_room text, p_key text) returns json
language plpgsql security definer set search_path = public as $$
declare r rooms;
begin
  perform _chk(p_room, p_key);
  select * into r from rooms where code = upper(btrim(p_room));
  return json_build_object(
    'done', r.done, 'voided', r.voided, 'qkey', r.qkey,
    'teams', (select coalesce(json_agg(json_build_object('id', t.id, 'name', t.name, 'joined', t.joined_at, 'total', _tot(t.id)) order by t.joined_at), '[]'::json)
                from teams t where t.room = r.code),
    'answers', (select coalesce(json_agg(json_build_object(
                  'team', a.team_id, 'q', a.qkey, 'v', case when a.blank then null else a.letter end, 'ok', a.correct,
                  'bonus', a.bonus, 'pts', a.points,
                  'ms', case when a.blank or a.opened_at is null then null
                             else round(extract(epoch from (a.submitted_at - a.opened_at)) * 1000) end)), '[]'::json)
                  from answers a where a.room = r.code),
    'adjustments', (select coalesce(json_agg(json_build_object('team', j.team_id, 'kind', j.kind, 'delta', j.delta, 'q', j.qkey) order by j.created_at), '[]'::json)
                      from adjustments j where j.room = r.code)
  );
end $$;
