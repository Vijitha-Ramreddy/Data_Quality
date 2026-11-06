-- 003: Row Level Security, realtime, storage

do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname='public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

create or replace function tpi_can_see_order(p_order uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth_role() = 'customer_tpi'
     and exists (select 1 from order_tpi_assignments where order_id = p_order and user_id = auth.uid()) $$;

-- Internal staff + management: read everything (except tables with special rules)
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname='public'
           and tablename not in ('audit_logs','notifications','profiles','order_tpi_assignments') loop
    execute format('create policy read_internal on public.%I for select to authenticated using (auth_role() is not null and auth_role() <> ''customer_tpi'')', t);
  end loop;
end $$;

-- Write matrix (admin always allowed; management never writes; customer_tpi never writes except approvals below)
do $$
declare m jsonb := '{
 "customers":["sales"], "orders":["sales","planning"], "stage_definitions":[],
 "order_stages":["sales","engineering","planning","qa","ppc","procurement","stores","production"],
 "route_steps":["sales","engineering","planning"], "drawings":["engineering"],
 "engineering_changes":["engineering","planning","qa"], "bom_items":["planning","engineering"],
 "routing_ops":["planning"], "itp_templates":["planning","qa"], "itp_items":["planning","qa"],
 "order_itp_points":["planning","qa","production"], "checklist_templates":["planning","qa"],
 "checklist_fields":["planning","qa"], "checklist_responses":["qa","production","stores"],
 "material_requirements":["ppc","procurement"], "material_receipts":["stores","qa"],
 "work_orders":["production","ppc"], "work_order_ops":["production","ppc"], "instruments":["qa"],
 "inspections":["qa","production","stores"], "inspection_measurements":["qa","production","stores"],
 "ndt_records":["qa","production"],
 "evidence_files":["sales","engineering","planning","qa","ppc","procurement","stores","production"],
 "ncrs":["qa","production"], "capas":["qa"], "approvals":["qa","engineering","planning"],
 "dossiers":["qa"], "dispatches":["qa","stores"],
 "sap_sync_log":["sales","ppc","procurement","stores","qa"], "app_settings":[], "order_tpi_assignments":[]}';
 t text; roles text;
begin
  for t in select jsonb_object_keys(m) loop
    select string_agg(quote_literal(x), ',') into roles from (select jsonb_array_elements_text(m->t) x union select 'admin') s;
    execute format('create policy write_roles on public.%I for all to authenticated using (auth_role() in (%s)) with check (auth_role() in (%s))', t, roles, roles);
  end loop;
end $$;

-- profiles
create policy profiles_read on profiles for select to authenticated using (auth_role() is not null);
create policy profiles_self_update on profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid() and role = auth_role());
create policy profiles_admin on profiles for all to authenticated using (auth_role()='admin') with check (auth_role()='admin');
create policy tpi_assign_self on order_tpi_assignments for select to authenticated using (user_id = auth.uid());

-- notifications (own only; created by SECURITY DEFINER functions)
create policy notif_read on notifications for select to authenticated using (user_id = auth.uid());
create policy notif_update on notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- audit log: admin + management read only (written by triggers)
create policy audit_read on audit_logs for select to authenticated using (auth_role() in ('admin','management'));

-- customer_tpi: read-only, assigned orders, Stage 08/09 data
create policy tpi_orders on orders for select to authenticated using (tpi_can_see_order(id));
create policy tpi_drawings on drawings for select to authenticated using (tpi_can_see_order(order_id) and status = 'released');
create policy tpi_dossiers on dossiers for select to authenticated using (tpi_can_see_order(order_id) and signed_at is not null);
create policy tpi_dispatches on dispatches for select to authenticated using (tpi_can_see_order(order_id));
create policy tpi_stage_defs on stage_definitions for select to authenticated using (auth_role() = 'customer_tpi');
create policy tpi_inspection_meas on inspection_measurements for select to authenticated
  using (exists (select 1 from inspections i where i.id = inspection_id and i.stage_no = 8 and tpi_can_see_order(i.order_id)));
create policy tpi_ndt on ndt_records for select to authenticated
  using (exists (select 1 from inspections i where i.id = inspection_id and i.stage_no = 8 and tpi_can_see_order(i.order_id)));
do $$ declare t text; begin
  foreach t in array array['order_stages','inspections','evidence_files','approvals'] loop
    execute format('create policy tpi_stage_read on public.%I for select to authenticated using (tpi_can_see_order(order_id) and stage_no in (8,9))', t);
  end loop;
end $$;
-- Narrow exception: TPI may record their own Stage 08 approval/rejection (needed for the acceptance gate)
create policy tpi_sign_stage8 on approvals for insert to authenticated
  with check (auth_role()='customer_tpi' and stage_no=8 and approver_id=auth.uid() and tpi_can_see_order(order_id));

-- Realtime
do $$ declare t text; begin
  foreach t in array array['notifications','orders','order_stages','ncrs','inspections','approvals'] loop
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Storage buckets
insert into storage.buckets (id, name, public) values
  ('evidence','evidence',false),('drawings','drawings',false),('mtc','mtc',false),('dossiers','dossiers',false)
on conflict (id) do nothing;
create policy "staff read files" on storage.objects for select to authenticated
  using (bucket_id in ('evidence','drawings','mtc','dossiers') and auth_role() is not null);
create policy "staff write files" on storage.objects for insert to authenticated
  with check (bucket_id in ('evidence','drawings','mtc','dossiers') and auth_role() is not null and auth_role() not in ('management','customer_tpi'));
