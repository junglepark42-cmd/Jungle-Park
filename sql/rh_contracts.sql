-- Additive RH migration. Never rewrites historical dates, hours or employee IDs.
begin;
create schema if not exists rh_private;
revoke all on schema rh_private from public, anon, authenticated;
create table if not exists rh_private.backup_20261102(table_name text primary key, captured_at timestamptz not null default now(), rows jsonb not null);
do $$ declare t text; begin
 foreach t in array array['employes','planning','conges','indisponibilites','mois_payes','activity_log'] loop
 execute format('insert into rh_private.backup_20261102(table_name,rows) select %L,coalesce(jsonb_agg(to_jsonb(x)),''[]''::jsonb) from public.%I x on conflict do nothing',t,t);
 end loop;
end $$;
create table if not exists rh_private.contracts(
 id uuid primary key default gen_random_uuid(), emp_id text not null references public.employes(id) on delete restrict,
 label text not null, kind text not null, mode text not null check(mode in ('legacy','seasonal','cdi')),
 start_date date, end_date date, base_hours numeric check(base_hours>0), monthly_hours numeric check(monthly_hours>=0),
 weekly_hours numeric check(weekly_hours>=0), yearly_hours numeric check(yearly_hours>=0),
 extra_pct numeric not null default 25 check(extra_pct between 0 and 100), monthly_targets jsonb not null default '{}',
 confirmed boolean not null default false, closed_at timestamptz, final_snapshot jsonb,
 source text not null default 'manual', legacy_snapshot jsonb, revision integer not null default 1,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(end_date is null or start_date is null or end_date>=start_date)
);
create unique index if not exists rh_contract_import_once on rh_private.contracts(emp_id) where source='legacy_import';
create table if not exists rh_private.archive(emp_id text primary key references public.employes(id), archived_at timestamptz not null default now());
create table if not exists rh_private.sessions(token uuid primary key default gen_random_uuid(),emp_id text not null references public.employes(id),expires_at timestamptz not null default now()+interval '8 hours');
create table if not exists rh_private.actuals(shift_id text primary key references public.planning(id) on delete restrict, minutes integer not null check(minutes>=0 and minutes<=1440), actor text not null, validated_at timestamptz not null default now(),note text not null default '');
create table if not exists rh_private.coverage(contract_id uuid not null references rh_private.contracts(id), week date not null, primary key(contract_id,week));
create table if not exists rh_private.audit(id bigint generated always as identity primary key, actor text not null, action text not null, payload jsonb not null, created_at timestamptz not null default now());
alter table rh_private.backup_20261102 enable row level security;
alter table rh_private.contracts enable row level security;
alter table rh_private.archive enable row level security;
alter table rh_private.sessions enable row level security;
alter table rh_private.actuals enable row level security;
alter table rh_private.coverage enable row level security;
alter table rh_private.audit enable row level security;
revoke all on all tables in schema rh_private from public,anon,authenticated;
insert into rh_private.contracts(emp_id,label,kind,mode,start_date,end_date,monthly_hours,weekly_hours,yearly_hours,monthly_targets,source,legacy_snapshot)
select id,'Contrat existant — à vérifier',coalesce(contract,'CDD'),case when ct='CDI annualise' and contract in ('CDI','SASU') then 'cdi' else 'legacy' end,since,contract_end,h_month,h_week,h_year,coalesce(h_mensuel,'{}'), 'legacy_import',to_jsonb(e)-'pin'-'nss'-'phone'-'formations'-'skills'-'tplanning'-'note' from public.employes e
where not exists(select 1 from rh_private.contracts c where c.emp_id=e.id and c.source='legacy_import');
alter table public.planning add column if not exists emp_id text references public.employes(id) on delete restrict;
alter table public.planning add column if not exists contract_id uuid references rh_private.contracts(id) on delete restrict;
create index if not exists planning_emp_date_idx on public.planning(emp_id,date);
create index if not exists planning_contract_date_idx on public.planning(contract_id,date);
-- Only unambiguous names; unknown contracts remain unassigned and visible.
update public.planning p set emp_id=e.id from public.employes e where p.emp_id is null and p.emp_nom=e.nom and (select count(*) from public.employes x where x.nom=p.emp_nom)=1;
create or replace function rh_private.link_shift() returns trigger language plpgsql security definer set search_path='' as $$
declare n integer; eid text; cid uuid;
begin
 if TG_OP='UPDATE' and exists(select 1 from rh_private.actuals a where a.shift_id=old.id) and (new.date,new.heure_debut,new.heure_fin,new.poste) is distinct from (old.date,old.heure_debut,old.heure_fin,old.poste) then
 raise exception 'Créneau validé : corriger les heures réelles dans le contrat.'; end if;
 if TG_OP='INSERT' or new.emp_nom is distinct from old.emp_nom or new.emp_id is null then
 select count(*),min(id) into n,eid from public.employes where nom=new.emp_nom;
 new.emp_id:=case when n=1 then eid else null end;
 end if;
 select count(*),(array_agg(id))[1] into n,cid from rh_private.contracts where emp_id=new.emp_id and confirmed and new.date>=start_date and (end_date is null or new.date<=end_date);
 new.contract_id:=case when n=1 then cid else null end;
 if TG_OP='UPDATE' and exists(select 1 from rh_private.actuals a where a.shift_id=old.id) and new.emp_id is distinct from old.emp_id then raise exception 'Créneau validé : salarié non modifiable'; end if;
 if new.contract_id is not null and exists(select 1 from rh_private.contracts where id=new.contract_id and closed_at is not null) and (TG_OP='INSERT' or (new.date,new.emp_id,new.heure_debut,new.heure_fin,new.poste) is distinct from (old.date,old.emp_id,old.heure_debut,old.heure_fin,old.poste)) then raise exception 'Contrat clôturé'; end if;
 return new;
end $$;
revoke all on function rh_private.link_shift() from public,anon,authenticated;
drop trigger if exists rh_link_shift on public.planning;
create trigger rh_link_shift before insert or update on public.planning for each row execute function rh_private.link_shift();
create or replace function rh_private.rename_employee() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.nom is distinct from old.nom then update public.planning set emp_nom=new.nom where emp_id=new.id; end if;
 return new;
end $$;
revoke all on function rh_private.rename_employee() from public,anon,authenticated;
drop trigger if exists rh_employee_rename on public.employes;
create trigger rh_employee_rename after update of nom on public.employes for each row execute function rh_private.rename_employee();
-- New data stay private. RPC authorizes every call using a short-lived server session.
create or replace function public.rh_contract_api(action text, payload jsonb default '{}', session_token uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor public.employes%rowtype; c rh_private.contracts%rowtype; oldc jsonb; result jsonb; cid uuid; eid text; tok uuid; sh public.planning%rowtype; n integer;
begin
 if action='login' then
 select * into actor from public.employes where id=payload->>'emp_id' and pin=payload->>'pin';
 if actor.id is null or exists(select 1 from rh_private.archive where emp_id=actor.id) or (not actor.is_manager and actor.contract_end is not null and actor.contract_end<(now() at time zone 'Europe/Paris')::date) then raise exception 'Accès refusé'; end if;
 insert into rh_private.sessions(emp_id) values(actor.id) returning token into tok;
 return jsonb_build_object('token',tok);
 end if;
 select e.* into actor from public.employes e join rh_private.sessions s on s.emp_id=e.id where s.token=session_token and s.expires_at>now();
 if actor.id is null or exists(select 1 from rh_private.archive where emp_id=actor.id) then raise exception 'Session expirée : reconnectez-vous'; end if;
 if action='logout' then delete from rh_private.sessions where token=session_token; return 'true'; end if;
 if not actor.is_manager then raise exception 'Accès réservé au gérant'; end if;
 if action='boot' then
 return jsonb_build_object('contracts',coalesce((select jsonb_agg(to_jsonb(x) order by start_date desc nulls last) from rh_private.contracts x),'[]'),'archived',coalesce((select jsonb_agg(emp_id) from rh_private.archive),'[]'),'unlinked', (select count(*) from public.planning where emp_id is null));
 elsif action='person_history' then
 return coalesce((select jsonb_agg(to_jsonb(p) order by p.date desc,p.id) from public.planning p where p.emp_id=payload->>'emp_id'),'[]');
 elsif action='detail' then
 select * into c from rh_private.contracts where id=(payload->>'id')::uuid;
 if c.id is null then raise exception 'Contrat introuvable'; end if;
 return jsonb_build_object('contract',to_jsonb(c),'shifts',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('actual',to_jsonb(a)) order by p.date,p.heure_debut,p.id) from public.planning p left join rh_private.actuals a on a.shift_id=p.id where p.contract_id=c.id),'[]'), 'unassigned',coalesce((select jsonb_agg(to_jsonb(p) order by p.date,p.id) from public.planning p where p.emp_id=c.emp_id and p.contract_id is null and (c.start_date is null or p.date>=c.start_date) and (c.end_date is null or p.date<=c.end_date)),'[]'),'coverage',coalesce((select jsonb_agg(week) from rh_private.coverage where contract_id=c.id),'[]'));
 elsif action='save' then
 eid:=payload->>'emp_id'; perform 1 from public.employes where id=eid for update;
 if not found then raise exception 'Salarié introuvable'; end if;
 cid:=nullif(payload->>'id','')::uuid;
 if cid is not null then
 select * into c from rh_private.contracts where id=cid for update;
 if c.id is null or c.emp_id<>eid then raise exception 'Contrat invalide'; end if;
 if c.closed_at is not null then raise exception 'Contrat clôturé'; end if;
 if c.revision<>(payload->>'revision')::integer then raise exception 'Contrat modifié ailleurs, actualisez'; end if;
 oldc:=to_jsonb(c);
 if c.confirmed and not coalesce((payload->>'confirmed')::boolean,false) then raise exception 'Une période confirmée reste historique : ne pas la désactiver'; end if;
 if c.confirmed and (c.start_date is distinct from nullif(payload->>'start_date','')::date or c.mode is distinct from payload->>'mode' or c.kind is distinct from payload->>'kind') then raise exception 'Contrat confirmé : créer une nouvelle période pour un changement de type ou de début'; end if;
 end if;
 c.emp_id:=eid; c.label:=coalesce(nullif(payload->>'label',''),'Contrat'); c.kind:=payload->>'kind'; c.mode:=payload->>'mode'; c.start_date:=nullif(payload->>'start_date','')::date;c.end_date:=nullif(payload->>'end_date','')::date;
 c.base_hours:=nullif(payload->>'base_hours','')::numeric;c.monthly_hours:=nullif(payload->>'monthly_hours','')::numeric;c.weekly_hours:=nullif(payload->>'weekly_hours','')::numeric;c.yearly_hours:=nullif(payload->>'yearly_hours','')::numeric;c.extra_pct:=coalesce((payload->>'extra_pct')::numeric,25);c.monthly_targets:=coalesce(payload->'monthly_targets','{}');c.confirmed:=coalesce((payload->>'confirmed')::boolean,false);
 if c.end_date is not null and c.start_date is not null and c.end_date>c.start_date+interval '10 years' then raise exception 'Période trop longue'; end if;
 if c.confirmed and c.mode='seasonal' and (c.base_hours<=0 or c.end_date<c.start_date) then raise exception 'Volume ou dates invalides'; end if;
 if c.mode not in ('legacy','seasonal','cdi') or c.kind is null then raise exception 'Type de contrat invalide'; end if;
 if c.confirmed and (c.start_date is null or (c.mode='seasonal' and (c.end_date is null or c.base_hours is null))) then raise exception 'Dates et volume de référence nécessaires'; end if;
 if c.confirmed and c.mode='seasonal' then
 select count(*) into n from generate_series(date_trunc('month',c.start_date::timestamp),date_trunc('month',c.end_date::timestamp),interval '1 month') m where c.monthly_targets->to_char(m,'YYYY')->(extract(month from m)::int::text) is null;
 if n>0 or abs((select coalesce(sum((c.monthly_targets->to_char(m,'YYYY')->>(extract(month from m)::int::text))::numeric),0) from generate_series(date_trunc('month',c.start_date::timestamp),date_trunc('month',c.end_date::timestamp),interval '1 month') m)-c.base_hours)>0.01 then raise exception 'Objectifs mensuels incomplets ou différents du volume de référence'; end if;
 end if;
 if c.confirmed and exists(select 1 from rh_private.contracts x where x.emp_id=eid and x.id is distinct from cid and x.confirmed and daterange(x.start_date,x.end_date,'[]') && daterange(c.start_date,c.end_date,'[]')) then raise exception 'Chevauchement avec un autre contrat confirmé'; end if;
 if cid is not null and exists(select 1 from public.planning where contract_id=cid and (date<c.start_date or (c.end_date is not null and date>c.end_date))) then raise exception 'Des créneaux sortiraient du contrat : conserver cette période et créer le nouveau contrat'; end if;
 if cid is null then
 insert into rh_private.contracts(emp_id,label,kind,mode,start_date,end_date,base_hours,monthly_hours,extra_pct,weekly_hours,yearly_hours,monthly_targets,confirmed) values(eid,c.label,c.kind,c.mode,c.start_date,c.end_date,c.base_hours,c.monthly_hours,c.extra_pct,c.weekly_hours,c.yearly_hours,c.monthly_targets,c.confirmed) returning id into cid;
 else
 update rh_private.contracts set label=c.label,kind=c.kind,mode=c.mode,start_date=c.start_date,end_date=c.end_date,base_hours=c.base_hours,monthly_hours=c.monthly_hours,extra_pct=c.extra_pct,weekly_hours=c.weekly_hours,yearly_hours=c.yearly_hours,monthly_targets=c.monthly_targets,confirmed=c.confirmed,revision=revision+1,updated_at=now() where id=cid;
 end if;
 if c.confirmed then
 update public.planning set contract_id=cid where emp_id=eid and contract_id is null and date>=c.start_date and (c.end_date is null or date<=c.end_date);
 end if;
 insert into rh_private.audit(actor,action,payload) values(actor.id,'contract_save',jsonb_build_object('before',oldc,'after',(select to_jsonb(x) from rh_private.contracts x where id=cid)));
 return jsonb_build_object('id',cid);
 elsif action='archive' then
 eid:=payload->>'emp_id';
 if eid=actor.id then raise exception 'Impossible d’archiver votre propre compte'; end if;
 if coalesce((payload->>'archived')::boolean,true) then insert into rh_private.archive(emp_id) values(eid) on conflict do nothing; delete from rh_private.sessions where emp_id=eid;
 else delete from rh_private.archive where emp_id=eid; end if;
 elsif action='validate' then
 select * into sh from public.planning where id=payload->>'shift_id' for update;
 if sh.id is null or sh.contract_id is null then raise exception 'Rattacher le créneau à un contrat confirmé'; end if;
 select * into c from rh_private.contracts where id=sh.contract_id for update;
 if c.closed_at is not null then raise exception 'Contrat clôturé'; end if;
 if sh.date>(now() at time zone 'Europe/Paris')::date then raise exception 'Impossible de valider des heures futures'; end if;
 if length(trim(coalesce(payload->>'note','')))=0 then raise exception 'Motif de validation ou correction requis'; end if;
 insert into rh_private.audit(actor,action,payload) values(actor.id,'actual_before',jsonb_build_object('shift_id',sh.id,'before',(select to_jsonb(a) from rh_private.actuals a where a.shift_id=sh.id)));
 insert into rh_private.actuals(shift_id,minutes,actor,note) values(sh.id,(payload->>'minutes')::integer,actor.id,payload->>'note') on conflict(shift_id) do update set minutes=excluded.minutes,actor=excluded.actor,note=excluded.note,validated_at=now();
 elsif action='coverage' then
 select * into c from rh_private.contracts where id=(payload->>'id')::uuid for update;
 if c.id is null or not c.confirmed or c.closed_at is not null then raise exception 'Contrat non modifiable'; end if;
 if extract(isodow from (payload->>'week')::date)<>1 or (payload->>'week')::date>c.end_date or (payload->>'week')::date+6<c.start_date then raise exception 'Semaine hors contrat'; end if;
 if (payload->>'prepared')::boolean then insert into rh_private.coverage values(c.id,(payload->>'week')::date) on conflict do nothing; else delete from rh_private.coverage where contract_id=c.id and week=(payload->>'week')::date; end if;
 elsif action='close' then
 select * into c from rh_private.contracts where id=(payload->>'id')::uuid for update;
 if c.id is null or not c.confirmed or c.end_date is null or c.end_date> (now() at time zone 'Europe/Paris')::date then raise exception 'Contrat non terminé'; end if;
 if exists(select 1 from public.planning p left join rh_private.actuals a on a.shift_id=p.id where p.contract_id=c.id and a.shift_id is null) then raise exception 'Valider tous les créneaux avant clôture'; end if;
 if exists(select 1 from public.planning where emp_id=c.emp_id and contract_id is null and date>=c.start_date and date<=c.end_date) then raise exception 'Des créneaux restent sans rattachement'; end if;
 update rh_private.contracts set closed_at=now(), final_snapshot=jsonb_build_object('contract',to_jsonb(c),'minutes',(select coalesce(sum(a.minutes),0) from rh_private.actuals a join public.planning p on p.id=a.shift_id where p.contract_id=c.id)),revision=revision+1 where id=c.id and closed_at is null;
 else raise exception 'Action inconnue'; end if;
 insert into rh_private.audit(actor,action,payload) values(actor.id,action,payload);
 return 'true';
end $$;
revoke all on function public.rh_contract_api(text,jsonb,uuid) from public;
grant execute on function public.rh_contract_api(text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
commit;
