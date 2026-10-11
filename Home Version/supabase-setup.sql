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
alter table answers add column if not exists blank boolean not null default false;
alter table teams add column if not exists last_seen timestamptz default now();

-- Nobody can touch the tables directly. Everything goes through the functions below.
alter table rooms   enable row level security;
alter table teams   enable row level security;
alter table answers enable row level security;
revoke all on rooms, teams, answers from anon, authenticated;

-- ---------- helpers ----------
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
-- p_evil_kind is 'none', 'evil' (wrong answers lose p_penalty points) or 'really' (wrong answers AND no answer lose p_penalty points).
-- p_qtype is 'letter', 'number' or 'multi'.
--   number: p_correct holds the one right whole number as text.
--   multi:  p_options holds 2 to 6 option texts and p_correct holds the position (0 to 5) of the right one.
drop function if exists open_question(text, text, text, text[]);
drop function if exists open_question(text, text, text, text[], text, text);
drop function if exists open_question(text, text, text, text[], text, text, int, int, int, int);
drop function if exists open_question(text, text, text, text[], text, text, int, int, int, int, text);
drop function if exists open_question(text, text, text, text[], text, text, int, int, int, int, text, text[]);
create or replace function open_question(p_room text, p_key text, p_qkey text, p_correct text[],
                                         p_question text default null, p_answer text default null,
                                         p_points int default 5, p_b1 int default 3, p_b2 int default 2, p_b3 int default 1,
                                         p_qtype text default 'letter', p_options text[] default null,
                                         p_evil_kind text default 'none', p_penalty int default 0) returns void
language plpgsql security definer set search_path = public as $$
declare r rooms;
        v_type text := case when p_qtype in ('number', 'multi') then p_qtype else 'letter' end;
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
  elsif v_type = 'multi' then
    if coalesce(array_length(p_options, 1), 0) not between 2 and 6 then raise exception 'Multiple choice needs 2 to 6 options'; end if;
    v_opts := p_options;
    c := coalesce((select array_agg(btrim(x)) from unnest(p_correct) x), '{}');
  else
    c := coalesce((select array_agg(upper(x)) from unnest(p_correct) x), '{}');
  end if;
  select * into r from rooms where code = upper(btrim(p_room));
  if r.qkey is not distinct from p_qkey and r.state <> 'idle' then
    update rooms set correct = c, qtext = p_question, atext = p_answer, qtype = v_type, qopts = v_opts,
                     pts = v_pts, b1 = v1, b2 = v2, b3 = v3, pen_kind = v_kind, pen = v_pen, phase = 'quiz', pinfo = null where code = r.code;
    return;
  end if;
  update rooms set
    qkey = p_qkey,
    correct = c,
    qtext = p_question,
    atext = p_answer,
    qtype = v_type, qopts = v_opts,
    pts = v_pts, b1 = v1, b2 = v2, b3 = v3, pen_kind = v_kind, pen = v_pen, phase = 'quiz', pinfo = null,
    timer_state = 'idle', timer_end = null, timer_left = null,
    state = case when p_qkey = any(done) then 'revealed' else 'open' end,
    opened_at = case when p_qkey = any(done) then opened_at else clock_timestamp() end
  where code = r.code;
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

  update rooms set state = 'revealed',
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
        'total', (select coalesce(sum(x.points), 0) from answers x where x.team_id = t.id)
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
                   from (select split_part(qkey, '-', 1) as rd, sum(points) as pts
                           from answers where team_id = t.id group by 1) z)
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
  if r.qtype = 'number' then
    l := btrim(coalesce(p_letter, ''));
    if l !~ '^[0-9]{1,9}$' then raise exception 'Enter a whole number'; end if;
    l := regexp_replace(l, '^0+(?=[0-9])', '');
  elsif r.qtype = 'multi' then
    l := btrim(coalesce(p_letter, ''));
    if l !~ '^[0-5]$' or l::int >= coalesce(array_length(r.qopts, 1), 0) then raise exception 'Pick one of the options'; end if;
  else
    l := upper(left(btrim(coalesce(p_letter, '')), 1));
    if l !~ '^[A-Z]$' then raise exception 'Pick a letter'; end if;
  end if;

  select * into a from answers where room = r.code and qkey = r.qkey and team_id = p_team;
  if found then return json_build_object('ok', false, 'locked', true, 'letter', a.letter); end if;
  if r.state <> 'open' then raise exception 'Answers are closed'; end if;

  insert into answers (room, qkey, team_id, letter) values (r.code, r.qkey, p_team, l)
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
      select coalesce(sum(points), 0) into tot from answers where room = r.code and team_id = me;
      select * into a from answers where room = r.code and qkey = r.qkey and team_id = me;
      mine := json_build_object(
        'valid', true, 'letter', case when a.blank then null else a.letter end,
        'ms', case when a.letter is null or a.blank or r.opened_at is null then null
                   else round(extract(epoch from (a.submitted_at - r.opened_at)) * 1000) end,
        'ok', case when r.state = 'revealed' then a.correct end,
        'points', case when r.state = 'revealed' then a.points end,
        'bonus', case when r.state = 'revealed' then a.bonus end,
        'total', tot,
        'rank', 1 + (select count(*) from (select sum(points) s from answers where room = r.code group by team_id) x where x.s > tot));
    else
      mine := json_build_object('valid', false);
    end if;
  end if;

  return json_build_object(
    'state', r.state, 'qkey', r.qkey, 'now', clock_timestamp(),
    'q', case when r.state <> 'idle' then r.qtext end,
    'qtype', case when r.state <> 'idle' then r.qtype end,
    'opts', case when r.state <> 'idle' and r.qtype = 'multi' then to_json(r.qopts) end,
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
  update rooms set done = array_remove(done, p_qkey) where code = rc;
  update rooms set state = 'open', opened_at = clock_timestamp(),
         timer_state = 'idle', timer_end = null, timer_left = null
   where code = rc and qkey = p_qkey;
end $$;
