-- Pin the search path of the place-search functions, as Supabase's security advisor recommends, so
-- they can't be pointed at other objects with the same names. They already name their tables in full,
-- and the built-in functions they use are always found.
alter function public.jalan_normalize(text) set search_path = '';
alter function public.search_places(text, double precision, double precision, integer) set search_path = '';
alter function public.recall_lookups(text, interval) set search_path = '';
alter function public.take_turn(text, interval) set search_path = '';
alter function public.save_places(text, text, jsonb) set search_path = '';
