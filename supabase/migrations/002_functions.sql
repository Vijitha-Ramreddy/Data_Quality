-- 002: helpers, audit, gates, auto-NCR, auto-CAPA, dossier, workflow RPCs

create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

do $$ declare t text; begin
  for t in select table_name from information_schema.columns
           where table_schema='public' and column_name='updated_at' loop
    execute format('create trigger trg_updated_at before update on public.%I for each row execute function set_updated_at()', t);
  end loop;
end $$;

create or replace function auth_role() returns user_role
language sql stable security definer set search_path = public as
$$ select role from profiles where id = auth.uid() $$;

create or replace function notify_roles(roles user_role[], p_title text, p_body text, p_link text) returns void
language sql security definer set search_path = public as
$$ insert into notifications(user_id,title,body,link)
   select id, p_title, p_body, p_link from profiles where role = any(roles) $$;

-- ---------- audit ----------
create or replace function audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_logs(user_id, action, table_name, record_id, old_data, new_data, ip)
  values (auth.uid(), tg_op, tg_table_name,
    coalesce(to_jsonb(new)->>'id', to_jsonb(old)->>'id')::uuid,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end,
    (nullif(current_setting('request.headers', true), '')::json)->>'x-forwarded-for');
  return coalesce(new, old);
end $$;

do $$ declare t text; begin
  foreach t in array array['profiles','customers','orders','order_stages','route_steps','drawings','engineering_changes',
    'bom_items','routing_ops','itp_templates','itp_items','order_itp_points','checklist_responses','material_requirements',
    'material_receipts','work_orders','work_order_ops','instruments','inspections','inspection_measurements','ndt_records',
    'evidence_files','ncrs','capas','approvals','dossiers','dispatches'] loop
    execute format('create trigger trg_audit after insert or update or delete on public.%I for each row execute function audit_row()', t);
  end loop;
end $$;

-- ---------- new order: stages + route steps ----------
create or replace function trg_order_init() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into order_stages(order_id, stage_no, status, started_at)
  select new.id, g, case when g=1 then 'in_progress'::stage_status else 'pending' end, case when g=1 then now() end
  from generate_series(1,9) g;
  insert into route_steps(order_id, route_type, step_name, seq)
  select new.id, new.route_type, s.name, s.seq from (
    select 1 seq,'Approved design' name where new.route_type='MTO' union all
    select 2,'Order-specific verification' where new.route_type='MTO' union all
    select 3,'Approved BOM / routing baseline' where new.route_type='MTO' union all
    select 1,'New / revised engineering' where new.route_type='ETO' union all
    select 2,'Technical review' where new.route_type='ETO' union all
    select 3,'Drawing & BOM approval' where new.route_type='ETO' union all
    select 4,'Controlled release' where new.route_type='ETO') s;
  return new;
end $$;
create trigger trg_order_init after insert on orders for each row execute function trg_order_init();

-- ---------- drawing release / supersede ----------
create or replace function trg_drawing_release() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'released' and (tg_op = 'INSERT' or old.status is distinct from 'released') then
    if exists (select 1 from engineering_changes ec where ec.new_drawing_id = new.id and ec.status not in ('approved','released')) then
      raise exception 'Engineering change impact review must be approved before release of % rev %', new.drawing_no, new.revision;
    end if;
    update drawings set status='superseded'
      where order_id=new.order_id and drawing_no=new.drawing_no and id<>new.id and status in ('released','approved');
    update engineering_changes set status='released' where new_drawing_id=new.id;
    new.released_at := now();
    perform notify_roles(array['production','qa','planning','engineering']::user_role[],
      'Drawing '||new.drawing_no||' Rev '||new.revision||' released',
      'Previous revision superseded. Use the new revision only.', '/orders/'||new.order_id||'?tab=drawings');
  end if;
  return new;
end $$;
create trigger trg_drawing_release before insert or update on drawings for each row execute function trg_drawing_release();

-- ---------- material rule: rejected/held material cannot be issued ----------
create or replace function trg_wo_material() returns trigger
language plpgsql security definer set search_path = public as $$
declare d disposition_type;
begin
  if new.material_receipt_id is not null then
    select disposition into d from material_receipts where id = new.material_receipt_id;
    if d is distinct from 'accept' then
      raise exception 'Material receipt is not accepted by Incoming QA (disposition: %); cannot issue to production', coalesce(d::text,'none');
    end if;
  end if;
  return new;
end $$;
create trigger trg_wo_material before insert or update on work_orders for each row execute function trg_wo_material();

-- ---------- inspection: calibration check ----------
create or replace function trg_inspection_calibration() returns trigger
language plpgsql security definer set search_path = public as $$
declare due date;
begin
  if new.instrument_id is not null then
    select calibration_due into due from instruments where id = new.instrument_id;
    if due < current_date then
      new.calibration_valid := false;
      if new.result in ('pending','pass') then new.result := 'blocked'; end if;
    else new.calibration_valid := true; end if;
  end if;
  return new;
end $$;
create trigger trg_inspection_calibration before insert or update on inspections for each row execute function trg_inspection_calibration();

-- ---------- measurement: tolerance eval + auto NCR ----------
create or replace function trg_meas_eval() returns trigger language plpgsql as $$
begin
  if new.actual is null then new.result := 'pending';
  elsif (new.tol_min is not null and new.actual < new.tol_min) or (new.tol_max is not null and new.actual > new.tol_max)
    then new.result := 'fail';
  else new.result := 'pass'; end if;
  return new;
end $$;
create trigger trg_meas_eval before insert or update on inspection_measurements for each row execute function trg_meas_eval();

create or replace function trg_meas_ncr() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.result = 'fail' then
    update inspections set result='fail' where id=new.inspection_id and result <> 'fail';
    insert into ncrs(order_id, stage_no, inspection_id, description, severity, status, auto_raised, raised_by)
    select i.order_id, i.stage_no, i.id,
      'Out of tolerance: '||new.characteristic||' actual '||new.actual||' (allowed '||coalesce(new.tol_min::text,'-')||' to '||coalesce(new.tol_max::text,'-')||')',
      'major', 'open', true, i.inspector_id
    from inspections i
    where i.id = new.inspection_id
      and not exists (select 1 from ncrs n where n.inspection_id=i.id and n.status<>'closed'
                      and n.description like 'Out of tolerance: '||new.characteristic||'%');
  end if;
  return new;
end $$;
create trigger trg_meas_ncr after insert or update of actual on inspection_measurements for each row execute function trg_meas_ncr();

-- ---------- NCR: status flow, close rules, repeat -> CAPA ----------
create or replace function trg_ncr_flow() returns trigger
language plpgsql security definer set search_path = public as $$
declare r result_type;
begin
  if tg_op = 'UPDATE' then
    if new.disposition is not null and new.disposition is distinct from old.disposition and new.status in ('open','disposition_set') then
      new.status := case when new.disposition = 'rework' then 'rework' else 'disposition_set' end;
    end if;
    if new.status = 'closed' and old.status <> 'closed' then
      if new.disposition is null then raise exception 'NCR % cannot close: disposition missing', new.ncr_no; end if;
      if new.disposition in ('rework','use_as_is') then
        select result into r from inspections where id = new.reinspection_inspection_id;
        if r is distinct from 'pass' then raise exception 'NCR % cannot close: reinspection has not passed', new.ncr_no; end if;
      end if;
      if new.qa_approved_by is null then raise exception 'NCR % cannot close: QA approval missing', new.ncr_no; end if;
      new.closed_at := now();
    end if;
  end if;
  return new;
end $$;
create trigger trg_ncr_flow before insert or update on ncrs for each row execute function trg_ncr_flow();

create or replace function trg_ncr_capa() returns trigger
language plpgsql security definer set search_path = public as $$
declare ids uuid[];
begin
  if new.root_cause_category is not null then
    select array_agg(id) into ids from ncrs
      where root_cause_category = new.root_cause_category and created_at > now() - interval '180 days';
    if cardinality(ids) >= 3 and not exists (
        select 1 from capas where trigger_type='auto_repeat_ncr' and status<>'closed' and linked_ncr_ids && ids) then
      insert into capas(trigger_type, linked_ncr_ids, root_cause, status)
      values ('auto_repeat_ncr', ids, new.root_cause_category, 'open');
      perform notify_roles(array['qa','management']::user_role[], 'CAPA auto-raised',
        'Repeat NCRs with root cause: '||new.root_cause_category, '/ncr-capa');
    end if;
  end if;
  return new;
end $$;
create trigger trg_ncr_capa after insert or update of root_cause_category on ncrs for each row execute function trg_ncr_capa();

-- ---------- stage gates ----------
create or replace function stage_blockers(p_order uuid, p_stage smallint) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare b text[] := '{}'; o orders%rowtype;
begin
  select * into o from orders where id = p_order;
  if exists (select 1 from order_itp_points p join itp_items i on i.id=p.itp_item_id join itp_templates t on t.id=i.template_id
             where p.order_id=p_order and t.stage_no=p_stage and i.point_type='hold' and p.status='open') then
    b := array_append(b, 'Open hold point(s)'); end if;
  if exists (select 1 from inspections x where x.order_id=p_order and x.stage_no=p_stage and x.result in ('fail','blocked')
             and not exists (select 1 from inspections y where y.order_id=x.order_id and y.stage_no=x.stage_no
                             and y.result='pass' and y.created_at > x.created_at)) then
    b := array_append(b, 'Failed or blocked inspection'); end if;
  if exists (select 1 from ncrs where order_id=p_order and stage_no=p_stage and status<>'closed') then
    b := array_append(b, 'Open NCR'); end if;
  if p_stage in (2,6,7,8) and not exists (select 1 from drawings where order_id=p_order and status='released') then
    b := array_append(b, 'No released drawing'); end if;
  if p_stage in (6,7,8) and exists (select 1 from engineering_changes where order_id=p_order and status in ('requested','impact_review')) then
    b := array_append(b, 'Engineering change pending impact review'); end if;
  if p_stage in (3,5,7,8,9) and not exists (select 1 from approvals where order_id=p_order and stage_no=p_stage and decision='approved') then
    b := array_append(b, 'QA approval missing'); end if;

  if p_stage = 1 and o.sync_status <> 'synced' then b := array_append(b, 'Order not synced to SAP'); end if;
  if p_stage = 3 then
    if not exists (select 1 from bom_items where order_id=p_order) then b := array_append(b, 'BOM not baselined'); end if;
    if exists (select 1 from route_steps where order_id=p_order and status<>'done') then b := array_append(b, 'Routing steps incomplete'); end if;
  end if;
  if p_stage = 4 and exists (select 1 from material_requirements m join bom_items bi on bi.id=m.bom_item_id
      where bi.order_id=p_order and m.stock_qty < m.required_qty and m.po_no is null) then
    b := array_append(b, 'Material requirement without PO'); end if;
  if p_stage = 5 and (not exists (select 1 from material_receipts where order_id=p_order)
      or exists (select 1 from material_receipts where order_id=p_order and (inspection_result='pending' or disposition='hold' or disposition is null))) then
    b := array_append(b, 'Material receipts pending Incoming QA decision'); end if;
  if p_stage = 6 and (not exists (select 1 from work_orders where order_id=p_order)
      or exists (select 1 from work_order_ops w join work_orders wo on wo.id=w.work_order_id where wo.order_id=p_order and w.status<>'completed')) then
    b := array_append(b, 'Operations incomplete'); end if;
  if p_stage = 8 and exists (select 1 from order_tpi_assignments where order_id=p_order)
     and not exists (select 1 from approvals a join profiles p on p.id=a.approver_id
                     where a.order_id=p_order and a.stage_no=8 and a.decision='approved' and p.role='customer_tpi') then
    b := array_append(b, 'Customer/TPI approval missing'); end if;
  if p_stage = 9 and (not exists (select 1 from dossiers where order_id=p_order and signed_at is not null)
                      or not exists (select 1 from dispatches where order_id=p_order and status in ('dispatched','delivered'))) then
    b := array_append(b, 'Dossier sign-off / dispatch missing'); end if;
  return b;
end $$;

create or replace function trg_stage_gate() returns trigger
language plpgsql security definer set search_path = public as $$
declare blockers text[]; prev stage_status;
begin
  if new.status = 'in_progress' and old.status is distinct from 'in_progress' then
    if new.stage_no > 1 then
      select status into prev from order_stages where order_id=new.order_id and stage_no=new.stage_no-1;
      if prev is distinct from 'completed' then
        raise exception 'Stage % cannot start: stage % gate not passed', new.stage_no, new.stage_no-1; end if;
    end if;
    if new.stage_no = 6 and not exists (select 1 from drawings where order_id=new.order_id and status='released') then
      raise exception 'Stage 06 cannot start: no released drawing'; end if;
    new.started_at := coalesce(new.started_at, now());
  end if;
  if new.status = 'completed' and old.status is distinct from 'completed' then
    blockers := stage_blockers(new.order_id, new.stage_no);
    if cardinality(blockers) > 0 then
      raise exception 'Gate failed for stage %: %', new.stage_no, array_to_string(blockers,'; '); end if;
    new.completed_at := coalesce(new.completed_at, now());
  end if;
  return new;
end $$;
create trigger trg_stage_gate before update on order_stages for each row execute function trg_stage_gate();

create or replace function complete_stage(p_order uuid, p_stage smallint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r user_role := auth_role(); owners user_role[]; nxt user_role[];
begin
  select owner_roles into owners from stage_definitions where stage_no = p_stage;
  if r is null or r = 'customer_tpi' or not (r = 'admin' or r = any(owners)) then
    raise exception 'Role % cannot complete stage %', r, p_stage; end if;
  update order_stages set status='completed' where order_id=p_order and stage_no=p_stage;
  if p_stage < 9 then
    update order_stages set status='in_progress' where order_id=p_order and stage_no=p_stage+1;
    update orders set current_stage=p_stage+1 where id=p_order;
    select owner_roles into nxt from stage_definitions where stage_no = p_stage+1;
    perform notify_roles(nxt, 'Stage '||lpad((p_stage+1)::text,2,'0')||' ready', 'Order moved to the next stage', '/orders/'||p_order);
  else
    update orders set status='dispatched' where id=p_order;
  end if;
  return jsonb_build_object('order_id', p_order, 'completed_stage', p_stage);
end $$;

-- ---------- rework loop (stage 7 -> 6 -> 7) ----------
create or replace function start_rework(p_ncr uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n ncrs%rowtype;
begin
  if auth_role() not in ('admin','qa') then raise exception 'Only QA can start rework'; end if;
  update ncrs set disposition='rework' where id=p_ncr returning * into n;
  if n.stage_no = 7 then
    update order_stages set status='blocked' where order_id=n.order_id and stage_no=7;
    update order_stages set status='in_progress', completed_at=null where order_id=n.order_id and stage_no=6;
    update orders set current_stage=6 where id=n.order_id;
    perform notify_roles(array['production']::user_role[], n.ncr_no||' – rework required', n.description, '/orders/'||n.order_id);
  end if;
end $$;

create or replace function finish_rework(p_ncr uuid, p_inspection uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n ncrs%rowtype; r result_type;
begin
  if auth_role() not in ('admin','qa','production') then raise exception 'Not permitted'; end if;
  select result into r from inspections where id = p_inspection;
  if r is distinct from 'pass' then raise exception 'Reinspection must pass before returning to stage 07'; end if;
  update ncrs set reinspection_inspection_id=p_inspection, status='awaiting_reinspection' where id=p_ncr returning * into n;
  if n.stage_no = 7 then
    update order_stages set status='completed' where order_id=n.order_id and stage_no=6;
    update order_stages set status='in_progress' where order_id=n.order_id and stage_no=7;
    update orders set current_stage=7 where id=n.order_id;
  end if;
end $$;

-- ---------- dossier ----------
create or replace function dossier_check(p_order uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with c(label, ok) as (values
    ('Released drawing', exists(select 1 from drawings where order_id=p_order and status='released')),
    ('BOM baselined', exists(select 1 from bom_items where order_id=p_order)),
    ('Material MTCs verified', exists(select 1 from material_receipts where order_id=p_order and disposition='accept')
        and not exists(select 1 from material_receipts where order_id=p_order and disposition='accept' and not mtc_verified)),
    ('Incoming QA evidence', exists(select 1 from evidence_files where order_id=p_order and stage_no=5)),
    ('Production evidence', exists(select 1 from evidence_files where order_id=p_order and stage_no=6)),
    ('In-process inspection passed', exists(select 1 from inspections where order_id=p_order and type='in_process' and result='pass')),
    ('In-process evidence', exists(select 1 from evidence_files where order_id=p_order and stage_no=7)),
    ('Final inspection passed', exists(select 1 from inspections where order_id=p_order and type='final' and result='pass')),
    ('Final inspection evidence', exists(select 1 from evidence_files where order_id=p_order and stage_no=8)),
    ('Final acceptance approval', exists(select 1 from approvals where order_id=p_order and stage_no=8 and decision='approved')),
    ('No open NCRs', not exists(select 1 from ncrs where order_id=p_order and status<>'closed')))
  select jsonb_build_object(
    'pct', round(100.0 * count(*) filter (where ok) / count(*), 1),
    'missing', coalesce(jsonb_agg(label) filter (where not ok), '[]'::jsonb)) from c
$$;

create or replace function refresh_dossier(p_order uuid) returns dossiers
language plpgsql security definer set search_path = public as $$
declare chk jsonb := dossier_check(p_order); d dossiers;
begin
  select * into d from dossiers where order_id=p_order and signed_at is null order by version desc limit 1;
  if found then
    update dossiers set completeness_pct=(chk->>'pct')::numeric, missing_items=chk->'missing' where id=d.id returning * into d;
  else
    insert into dossiers(order_id, version, completeness_pct, missing_items)
    values (p_order, coalesce((select max(version) from dossiers where order_id=p_order),0)+1, (chk->>'pct')::numeric, chk->'missing')
    returning * into d;
  end if;
  return d;
end $$;

create or replace function trg_dossier_signoff() returns trigger
language plpgsql security definer set search_path = public as $$
declare chk jsonb;
begin
  if new.signed_at is not null and old.signed_at is null then
    chk := dossier_check(new.order_id);
    if (chk->>'pct')::numeric < 100 then
      raise exception 'Dossier sign-off blocked: completeness is % percent; missing %', chk->>'pct', chk->>'missing'; end if;
    new.completeness_pct := 100; new.missing_items := '[]';
    new.qa_signoff_by := coalesce(new.qa_signoff_by, auth.uid());
  end if;
  return new;
end $$;
create trigger trg_dossier_signoff before update on dossiers for each row execute function trg_dossier_signoff();

create or replace function trg_dispatch_rule() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from dossiers where order_id=new.order_id and signed_at is not null) then
    raise exception 'Dispatch not allowed: quality dossier is not signed off'; end if;
  insert into sap_sync_log(entity, entity_id, direction, status, message, payload)
  values ('dispatch', new.order_id, 'outbound', 'pending', 'Dispatch posting queued (mock)', jsonb_build_object('lr_no', new.lr_no));
  return new;
end $$;
create trigger trg_dispatch_rule before insert on dispatches for each row execute function trg_dispatch_rule();

-- ---------- SAP mock ----------
create or replace function sap_sync_order(p_order uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth_role() not in ('admin','sales','planning') then raise exception 'Not permitted'; end if;
  update orders set sync_status='synced', last_synced_at=now() where id=p_order;
  insert into sap_sync_log(entity, entity_id, direction, status, message)
  values ('order', p_order, 'outbound', 'synced', 'Order/project synced to SAP S/4HANA (mock)');
  return jsonb_build_object('status','synced');
end $$;
