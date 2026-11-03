begin;
create table if not exists rh_private.notifications(
 id bigint generated always as identity primary key,
 recipient text not null references public.employes(id) on delete restrict,
 request_id text not null, event_key text not null,
 kind text not null check(kind in ('request','pending','accepted','refused','cancelled')),
 title text not null, request_date date not null,
 created_at timestamptz not null default now(), read_at timestamptz,
 unique(recipient,request_id,event_key)
);
alter table rh_private.notifications enable row level security;
revoke all on rh_private.notifications from public,anon,authenticated;
create index if not exists notifications_unread on rh_private.notifications(recipient,id desc) where read_at is null;
create or replace function rh_private.notify_indispo() returns trigger language plpgsql security definer set search_path='' as $$
declare event text; status_name text; employee_name text;
begin
 if TG_OP='DELETE' then
 update rh_private.notifications set read_at=coalesce(read_at,now()) where request_id=old.id;
 return old;
 end if;
 if TG_OP='UPDATE' and (new.status,new.date,new.emp_id) is not distinct from (old.status,old.date,old.emp_id) then return new; end if;
 select nom into employee_name from public.employes where id=new.emp_id;
 if employee_name is null then return new; end if;
 if TG_OP='UPDATE' then update rh_private.notifications set read_at=coalesce(read_at,now()) where request_id=new.id and kind in ('request','pending'); end if;
 event:=case when TG_OP='INSERT' then 'created' else gen_random_uuid()::text end;
 if coalesce(new.status,'pending')='pending' then
 insert into rh_private.notifications(recipient,request_id,event_key,kind,title,request_date)
 select e.id,new.id,event,'request',employee_name||' : demande d’indisponibilité',new.date from public.employes e
 where e.is_manager and not exists(select 1 from rh_private.archive a where a.emp_id=e.id)
 on conflict do nothing;
 end if;
 status_name:=case coalesce(new.status,'pending') when 'accepted' then 'acceptée' when 'refused' then 'refusée' else 'en attente' end;
 insert into rh_private.notifications(recipient,request_id,event_key,kind,title,request_date)
 values(new.emp_id,new.id,event,case when new.status in ('accepted','refused') then new.status else 'pending' end,'Votre indisponibilité : '||status_name,new.date) on conflict do nothing;
 return new;
end $$;
revoke all on function rh_private.notify_indispo() from public,anon,authenticated;
drop trigger if exists notify_indispo on public.indisponibilites;
create trigger notify_indispo after insert or update or delete on public.indisponibilites for each row execute function rh_private.notify_indispo();
-- Seed only unresolved upcoming requests; reruns never resurrect read notices.
insert into rh_private.notifications(recipient,request_id,event_key,kind,title,request_date)
select e.id,i.id,'created','request',coalesce(p.nom,'Salarié')||' : demande d’indisponibilité',i.date
from public.indisponibilites i join public.employes p on p.id=i.emp_id cross join public.employes e
where i.status='pending' and i.date>=(now() at time zone 'Europe/Paris')::date and e.is_manager
and not exists(select 1 from rh_private.archive a where a.emp_id=e.id)
on conflict do nothing;
insert into rh_private.notifications(recipient,request_id,event_key,kind,title,request_date)
select emp_id,id,'created','pending','Votre indisponibilité : en attente',date from public.indisponibilites
where status='pending' and date>=(now() at time zone 'Europe/Paris')::date
and exists(select 1 from public.employes e where e.id=emp_id)
on conflict do nothing;
create or replace function public.internal_notifications_api(action text,session_token uuid,payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor public.employes%rowtype; result jsonb;
begin
 select e.* into actor from public.employes e join rh_private.sessions s on s.emp_id=e.id where s.token=session_token and s.expires_at>now();
 if actor.id is null or exists(select 1 from rh_private.archive where emp_id=actor.id) or (not coalesce(actor.is_manager,false) and actor.contract_end<(now() at time zone 'Europe/Paris')::date) then raise exception 'Session expirée : reconnectez-vous'; end if;
 if action='read' then
 update rh_private.notifications set read_at=now() where recipient=actor.id and read_at is null and id=(payload->>'id')::bigint;
 elsif action='read_all' then
 update rh_private.notifications set read_at=now() where recipient=actor.id and read_at is null and id<=coalesce((payload->>'through')::bigint,0);
 elsif action<>'list' then raise exception 'Action inconnue'; end if;
 select jsonb_build_object('count',count(*),'through',coalesce(max(id),0)) into result from rh_private.notifications where recipient=actor.id and read_at is null;
 return result||jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(x) order by id desc) from (select id,request_id,kind,title,request_date,created_at from rh_private.notifications where recipient=actor.id and read_at is null order by id desc limit 50) x),'[]'));
end $$;
revoke all on function public.internal_notifications_api(text,uuid,jsonb) from public;
grant execute on function public.internal_notifications_api(text,uuid,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
commit;
