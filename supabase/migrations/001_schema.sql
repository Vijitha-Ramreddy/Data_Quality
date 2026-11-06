-- JSPL Raipur – Integrated Manufacturing & Quality Workflow (TO-BE)
-- 001: enums + tables
create extension if not exists pgcrypto;

create type user_role as enum ('admin','sales','engineering','planning','qa','ppc','procurement','stores','production','customer_tpi','management');
create type route_type as enum ('MTO','ETO');
create type stage_status as enum ('pending','in_progress','awaiting_approval','completed','blocked');
create type order_status as enum ('active','on_hold','completed','dispatched','cancelled');
create type drawing_status as enum ('draft','under_review','approved','released','superseded');
create type itp_point_type as enum ('hold','witness','review');
create type inspection_type as enum ('incoming','in_process','final');
create type result_type as enum ('pending','pass','fail','blocked');
create type disposition_type as enum ('accept','reject','hold','rework','use_as_is','scrap','return_to_vendor');
create type sync_status as enum ('synced','pending','failed');
create type approval_decision as enum ('approved','rejected');
create type ncr_status as enum ('open','disposition_set','rework','awaiting_reinspection','closed');
create type capa_status as enum ('open','in_progress','effectiveness_check','closed');
create type field_type as enum ('pass_fail','numeric','text','dropdown');

create sequence ncr_seq start 1;
create sequence capa_seq start 1;

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null, role user_role not null,
  department text, plant text default 'Raipur',
  created_at timestamptz default now(), updated_at timestamptz default now());

create table customers (
  id uuid primary key default gen_random_uuid(),
  code text unique, name text not null unique, contact text, city text,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table orders (
  id uuid primary key default gen_random_uuid(),
  sap_order_no text not null unique, sap_project_no text,
  customer_id uuid references customers(id),
  product_description text not null, qty int not null default 1, due_date date,
  route_type route_type not null,
  current_stage smallint not null default 1 check (current_stage between 1 and 9),
  status order_status not null default 'active',
  priority text not null default 'medium' check (priority in ('high','medium','low')),
  sync_status sync_status not null default 'pending', last_synced_at timestamptz,
  created_by uuid references profiles(id),
  created_at timestamptz default now(), updated_at timestamptz default now());

create table stage_definitions (
  id uuid primary key default gen_random_uuid(),
  stage_no smallint not null unique, name text not null,
  owner_roles user_role[] not null, gate_name text not null,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table order_stages (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  stage_no smallint not null check (stage_no between 1 and 9),
  status stage_status not null default 'pending',
  started_at timestamptz, completed_at timestamptz, assigned_to uuid references profiles(id),
  created_at timestamptz default now(), updated_at timestamptz default now(),
  unique (order_id, stage_no));

create table route_steps (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  route_type route_type not null, step_name text not null, seq smallint not null,
  status text not null default 'pending' check (status in ('pending','in_progress','done')),
  created_at timestamptz default now(), updated_at timestamptz default now(),
  unique (order_id, seq));

create table drawings (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  drawing_no text not null, revision text not null,
  status drawing_status not null default 'draft', file_url text,
  approved_by uuid references profiles(id), released_at timestamptz,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  unique (order_id, drawing_no, revision));

create table engineering_changes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  drawing_id uuid references drawings(id), new_drawing_id uuid references drawings(id),
  reason text not null, impact_summary text, impact jsonb default '{}',
  status text not null default 'requested' check (status in ('requested','impact_review','approved','rejected','released')),
  requested_by uuid references profiles(id), approved_by uuid references profiles(id), approved_at timestamptz,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table bom_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  item_code text not null, description text, qty numeric not null default 1, uom text default 'NOS',
  material_grade text, sap_material_no text,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  unique (order_id, item_code));

create table routing_ops (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  op_no int not null, work_center text, description text, std_hours numeric,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  unique (order_id, op_no));

create table itp_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null, stage_no smallint not null, product_family text, active boolean default true,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table itp_items (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references itp_templates(id) on delete cascade,
  seq int not null, activity text not null, acceptance_criteria text,
  point_type itp_point_type not null, responsible_role user_role not null,
  created_at timestamptz default now(), updated_at timestamptz default now());

-- per-order instance of an ITP point (needed to evaluate open hold points)
create table order_itp_points (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  itp_item_id uuid not null references itp_items(id) on delete cascade,
  status text not null default 'open' check (status in ('open','released')),
  released_by uuid references profiles(id), released_at timestamptz,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  unique (order_id, itp_item_id));

create table checklist_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null, stage_no smallint not null,
  itp_template_id uuid references itp_templates(id),
  created_at timestamptz default now(), updated_at timestamptz default now());

create table checklist_fields (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references checklist_templates(id) on delete cascade,
  seq int not null, label text not null, field_type field_type not null,
  unit text, nominal numeric, tol_min numeric, tol_max numeric, options jsonb, required boolean default true,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table checklist_responses (
  id uuid primary key default gen_random_uuid(),
  order_stage_id uuid not null references order_stages(id) on delete cascade,
  field_id uuid not null references checklist_fields(id),
  value text, pass_fail boolean, measured_by uuid references profiles(id), measured_at timestamptz default now(),
  created_at timestamptz default now(), updated_at timestamptz default now());

create table material_requirements (
  id uuid primary key default gen_random_uuid(),
  bom_item_id uuid not null references bom_items(id) on delete cascade,
  required_qty numeric not null, stock_qty numeric not null default 0,
  pr_no text, po_no text, vendor text, eta date,
  status text not null default 'pending' check (status in ('pending','available','pr_raised','po_placed','in_transit','received','delayed')),
  created_at timestamptz default now(), updated_at timestamptz default now(),
  unique (bom_item_id));

create table material_receipts (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  bom_item_id uuid references bom_items(id),
  po_no text, heat_no text, batch_id text unique, qr_code text,
  mtc_url text, mtc_verified boolean not null default false,
  inspection_result result_type not null default 'pending',
  disposition disposition_type, received_by uuid references profiles(id), received_at timestamptz default now(),
  created_at timestamptz default now(), updated_at timestamptz default now());

create table work_orders (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  wo_no text not null unique,
  status text not null default 'planned' check (status in ('planned','in_progress','completed')),
  material_receipt_id uuid references material_receipts(id),
  planned_start date, planned_end date,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table work_order_ops (
  id uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references work_orders(id) on delete cascade,
  routing_op_id uuid references routing_ops(id), op_no int not null,
  status text not null default 'pending' check (status in ('pending','in_progress','completed')),
  operator text, started_at timestamptz, ended_at timestamptz, qty_done numeric default 0,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table instruments (
  id uuid primary key default gen_random_uuid(),
  id_no text not null unique, description text, calibration_due date not null,
  status text not null default 'valid',
  created_at timestamptz default now(), updated_at timestamptz default now());

create table inspections (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  stage_no smallint not null, type inspection_type not null,
  inspector_id uuid references profiles(id), result result_type not null default 'pending',
  instrument_id uuid references instruments(id), calibration_valid boolean default true,
  remarks text, inspected_at timestamptz default now(),
  created_at timestamptz default now(), updated_at timestamptz default now());

create table inspection_measurements (
  id uuid primary key default gen_random_uuid(),
  inspection_id uuid not null references inspections(id) on delete cascade,
  characteristic text not null, nominal numeric, tol_min numeric, tol_max numeric, actual numeric,
  result result_type not null default 'pending',
  created_at timestamptz default now(), updated_at timestamptz default now());

create table ndt_records (
  id uuid primary key default gen_random_uuid(),
  inspection_id uuid not null references inspections(id) on delete cascade,
  method text not null check (method in ('UT','MPI','DPT','RT')),
  report_no text, result result_type not null default 'pending', report_url text,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table evidence_files (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  stage_no smallint not null, ref_table text, ref_id uuid,
  file_url text not null, type text default 'photo', caption text,
  uploaded_by uuid references profiles(id), reused_from_id uuid references evidence_files(id),
  created_at timestamptz default now(), updated_at timestamptz default now());

create table ncrs (
  id uuid primary key default gen_random_uuid(),
  ncr_no text not null unique default ('NCR-' || to_char(now(),'YYYY') || '-' || lpad(nextval('ncr_seq')::text,4,'0')),
  order_id uuid not null references orders(id) on delete cascade,
  stage_no smallint not null, inspection_id uuid references inspections(id),
  description text not null, severity text default 'major' check (severity in ('minor','major','critical')),
  root_cause_category text, disposition disposition_type,
  status ncr_status not null default 'open', raised_by uuid references profiles(id),
  reinspection_inspection_id uuid references inspections(id), qa_approved_by uuid references profiles(id),
  auto_raised boolean default false, closed_at timestamptz,
  created_at timestamptz default now(), updated_at timestamptz default now());

create table capas (
  id uuid primary key default gen_random_uuid(),
  capa_no text not null unique default ('CAPA-' || to_char(now(),'YYYY') || '-' || lpad(nextval('capa_seq')::text,4,'0')),
  trigger_type text not null default 'manual' check (trigger_type in ('auto_repeat_ncr','manual')),
  linked_ncr_ids uuid[] default '{}', root_cause text, corrective_action text, preventive_action text,
  owner uuid references profiles(id), due_date date, effectiveness_check text,
  status capa_status not null default 'open',
  created_at timestamptz default now(), updated_at timestamptz default now());

create table approvals (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  stage_no smallint not null, approver_id uuid not null references profiles(id),
  decision approval_decision not null, comment text, signed_at timestamptz default now(),
  created_at timestamptz default now(), updated_at timestamptz default now());

create table dossiers (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  version int not null default 1, completeness_pct numeric not null default 0,
  missing_items jsonb not null default '[]', pdf_url text,
  qa_signoff_by uuid references profiles(id), signed_at timestamptz,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  unique (order_id, version));

create table dispatches (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  vehicle_no text, lr_no text, dispatch_date date, sap_delivery_no text,
  status text not null default 'planned' check (status in ('planned','dispatched','delivered')),
  created_at timestamptz default now(), updated_at timestamptz default now());

create table sap_sync_log (
  id uuid primary key default gen_random_uuid(),
  entity text not null, entity_id uuid, direction text not null check (direction in ('inbound','outbound')),
  status sync_status not null, payload jsonb default '{}', message text,
  synced_at timestamptz default now(), created_at timestamptz default now());

create table audit_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid, action text not null, table_name text not null, record_id uuid,
  old_data jsonb, new_data jsonb, ip text, created_at timestamptz default now());

create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  title text not null, body text, link text, read boolean not null default false,
  created_at timestamptz default now());

create table order_tpi_assignments (
  order_id uuid not null references orders(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  primary key (order_id, user_id));

create table app_settings (key text primary key, value jsonb not null, updated_at timestamptz default now());

create index on orders (current_stage, status);
create index on order_stages (order_id);
create index on inspections (order_id, stage_no);
create index on ncrs (order_id, status);
create index on ncrs (root_cause_category);
create index on evidence_files (order_id, stage_no);
create index on audit_logs (table_name, created_at desc);
create index on notifications (user_id, read);
