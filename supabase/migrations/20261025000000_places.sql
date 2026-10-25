-- Place search for Jalan.
--
-- `places` holds OpenStreetMap places: imported from Geofabrik's Malaysia extract by
-- scripts/import_osm_places.py, plus the places Photon and Nominatim find, which the `places`
-- Edge Function saves so the next search for them doesn't need to ask those services again.
-- Everything here is private: only the Edge Function, with the service role key, reads or writes it.

create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;

-- Lowercase, and spell out the abbreviations Malaysian names and addresses use, so that
-- "jln ampang" finds "Jalan Ampang" and "tmn sri muda" finds "Taman Seri Muda".
create function public.jalan_normalize(value text) returns text
language sql immutable parallel safe
as $$
  select regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
         regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
         regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           lower(value),
           '\mjln\M\.?', 'jalan', 'g'),
           '\mtmn\M\.?', 'taman', 'g'),
           '\mk(g|pg)\M\.?', 'kampung', 'g'),
           '\mbdr\M\.?', 'bandar', 'g'),
           '\mbkt\M\.?', 'bukit', 'g'),
           '\msgi?\M\.?', 'sungai', 'g'),
           '\mlrg\M\.?', 'lorong', 'g'),
           '\mpsn\M\.?', 'persiaran', 'g'),
           '\mtg\M\.?', 'tanjung', 'g'),
           '\msri\M', 'seri', 'g'),
           '\mkl\M', 'kuala lumpur', 'g'),
           '\mpj\M', 'petaling jaya', 'g'),
           '\mjb\M', 'johor bahru', 'g'),
           '\s+', ' ', 'g')
$$;

create table public.places (
  -- The OpenStreetMap object: n123 (node), w123 (way) or r123 (relation).
  id text primary key check (id ~ '^[nwr][0-9]+$'),
  name text not null check (name <> ''),
  -- Other names to search by: English, Malay, Chinese and Tamil names, short and old names.
  alt_names text not null default '',
  -- Where it is, for example "Bangsar, Kuala Lumpur".
  subtitle text not null default '',
  -- The main OpenStreetMap tag, for example "amenity=fuel" or "highway=residential".
  kind text not null default '',
  lat double precision not null check (lat between -90 and 90),
  lon double precision not null check (lon between -180 and 180),
  -- 'osm' for the import, otherwise the service that found it.
  source text not null check (source in ('osm', 'photon', 'nominatim')),
  updated_at timestamptz not null default now(),
  -- What searches match. Not the subtitle: a city name in it would match every place in that city.
  search_text text generated always as (public.jalan_normalize(name || ' ' || alt_names)) stored
);

-- Trigram matching tolerates typos and half-typed words; GiST can also return the closest matches first.
create index places_search_text on public.places using gist (search_text extensions.gist_trgm_ops (siglen = 256));
-- Narrows "matches near the driver" to a band of latitude before comparing text.
create index places_lat on public.places (lat);

-- The searches already sent to Photon or Nominatim and the places each answered with, so the same
-- search in the same area gets the same places from here instead of asking again.
create table public.place_lookups (
  service text not null check (service in ('photon', 'nominatim')),
  lookup_key text not null,
  place_ids text[] not null default '{}',
  asked_at timestamptz not null default now(),
  primary key (service, lookup_key)
);

-- When each service was last asked, to keep to Nominatim's limit of one request a second.
create table public.service_turns (
  service text primary key,
  last_at timestamptz not null
);

alter table public.places enable row level security;
alter table public.place_lookups enable row level security;
alter table public.service_turns enable row level security;

-- `search_places` (below) for a query already normalized. The query must be a plain argument, not
-- something worked out inside the statement, for the trigram index to return the closest matches first.
create function public.search_normalized_places(
  q text,
  near_lat double precision,
  near_lon double precision,
  max_results integer
) returns table (id text, name text, subtitle text, lat double precision, lon double precision,
                 name_score real, score real)
language sql stable
set search_path = public, extensions
set pg_trgm.word_similarity_threshold = 0.5
as $$
  with
  -- The closest text matches anywhere in the country.
  best as (
    select p.id from public.places p
    where q <% p.search_text
    order by q <<-> p.search_text
    limit 50
  ),
  -- Matches within about 30 km, which the country-wide 50 can miss for names with hundreds of
  -- matches, like "petronas" or "jalan 1".
  nearby as (
    select p.id from public.places p
    where near_lat is not null and near_lon is not null
      and p.lat between near_lat - 0.3 and near_lat + 0.3
      and p.lon between near_lon - 0.3 and near_lon + 0.3
      and q <% p.search_text
    order by word_similarity(q, p.search_text) desc
    limit 50
  ),
  scored as (
    select p.id, p.name, p.subtitle, p.lat, p.lon,
           word_similarity(q, public.jalan_normalize(p.name)) as name_score,
           word_similarity(q, p.search_text) as text_score,
           case when near_lat is not null and near_lon is not null then
             111.32 * sqrt(power(p.lat - near_lat, 2) + power((p.lon - near_lon) * cos(radians(near_lat)), 2))
           end as km
    from public.places p
    where p.id in (select best.id from best union select nearby.id from nearby)
  )
  select s.id, s.name, s.subtitle, s.lat, s.lon, s.name_score::real,
         (0.6 * s.name_score + 0.4 * s.text_score + coalesce(0.3 / (1 + s.km / 10), 0))::real as score
  from scored s
  order by score desc, s.name
  limit greatest(1, least(max_results, 50))
$$;

-- The best matches for `query`, ranked by how well the name matches, then by the rest of the
-- text, with a boost for places near (near_lat, near_lon) when given.
-- `name_score` is 1 when the whole query appears in the name.
create function public.search_places(
  query text,
  near_lat double precision default null,
  near_lon double precision default null,
  max_results integer default 8
) returns table (id text, name text, subtitle text, lat double precision, lon double precision,
                 name_score real, score real)
language sql stable
as $$
  select * from public.search_normalized_places(public.jalan_normalize(query), near_lat, near_lon, max_results)
$$;

-- What Photon and Nominatim answered for this search (`lookup_key`) within `max_age`: a row per place
-- in the order they gave them, and a row with a null id for a service that found nothing.
create function public.recall_lookups(lookup_key text, max_age interval)
returns table (service text, id text, name text, subtitle text, lat double precision, lon double precision)
language sql stable
as $$
  select l.service, p.id, p.name, p.subtitle, p.lat, p.lon
  from public.place_lookups l
  left join lateral unnest(l.place_ids) with ordinality as answer(id, position) on true
  left join public.places p on p.id = answer.id
  where l.lookup_key = recall_lookups.lookup_key and l.asked_at > now() - max_age
  order by l.service, answer.position
$$;

-- Claims the next request to `service`: true, and recorded, when at least `min_gap` has passed
-- since the last one claimed; false otherwise.
create function public.take_turn(service text, min_gap interval) returns boolean
language sql volatile
as $$
  with claimed as (
    insert into public.service_turns as t (service, last_at) values (take_turn.service, clock_timestamp())
    on conflict (service) do update set last_at = excluded.last_at
      where t.last_at <= excluded.last_at - min_gap
    returning 1
  )
  select count(*) > 0 from claimed
$$;

-- Saves what `service` found for a search: the places it found that aren't already saved, and which
-- places it answered with. `found_places` is a JSON array of {id, name, subtitle, kind, lat, lon}.
-- Returns how many places were new.
create function public.save_places(service text, lookup_key text, found_places jsonb) returns integer
language sql volatile
as $$
  with answer as (
    select f.id, f.name, coalesce(f.subtitle, '') as subtitle, coalesce(f.kind, '') as kind, f.lat, f.lon, f.position
    from rows from (jsonb_to_recordset(coalesce(found_places, '[]'))
                    as (id text, name text, subtitle text, kind text, lat double precision, lon double precision))
         with ordinality as f(id, name, subtitle, kind, lat, lon, position)
    where f.id ~ '^[nwr][0-9]+$' and coalesce(f.name, '') <> ''
      and f.lat between -90 and 90 and f.lon between -180 and 180
  ),
  saved as (
    insert into public.places (id, name, subtitle, kind, lat, lon, source)
    select distinct on (a.id) a.id, a.name, a.subtitle, a.kind, a.lat, a.lon, save_places.service
    from answer a
    order by a.id, a.position
    on conflict do nothing
    returning 1
  ),
  remembered as (
    insert into public.place_lookups (service, lookup_key, place_ids)
    select save_places.service, save_places.lookup_key, coalesce(array_agg(a.id order by a.position), '{}')
    from answer a
    on conflict on constraint place_lookups_pkey do update set place_ids = excluded.place_ids, asked_at = now()
  )
  select count(*)::integer from saved
$$;

-- Supabase lets the public `anon` and `authenticated` roles call functions in `public` by default.
revoke all on table public.places, public.place_lookups, public.service_turns from anon, authenticated;
revoke execute on function public.search_places(text, double precision, double precision, integer),
                           public.search_normalized_places(text, double precision, double precision, integer),
                           public.recall_lookups(text, interval),
                           public.take_turn(text, interval),
                           public.save_places(text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.search_places(text, double precision, double precision, integer),
                          public.search_normalized_places(text, double precision, double precision, integer),
                          public.recall_lookups(text, interval),
                          public.take_turn(text, interval),
                          public.save_places(text, text, jsonb)
  to service_role;
