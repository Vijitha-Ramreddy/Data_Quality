-- Seed / dummy data. Idempotent (deterministic md5 UUIDs + ON CONFLICT DO NOTHING).
-- Triggers/FK checks are bypassed during seeding so historical states can be inserted directly.
set session_replication_role = replica;

-- ---------- stage definitions ----------
insert into stage_definitions (id, stage_no, name, owner_roles, gate_name) values
 (md5('stage1')::uuid,1,'Order Receipt','{sales}','Order / Project Sync'),
 (md5('stage2')::uuid,2,'Engineering & Drawings','{engineering}','Revision Control'),
 (md5('stage3')::uuid,3,'Project, BOM & Quality Planning','{planning,qa}','Plan + Inspection Gate'),
 (md5('stage4')::uuid,4,'Material Planning & Procurement','{ppc,procurement}','Material Status Sync'),
 (md5('stage5')::uuid,5,'Material Receipt & Incoming QA','{stores,qa}','Incoming QA Gate'),
 (md5('stage6')::uuid,6,'Fabrication, Machining & Assembly','{production}','Operation Capture'),
 (md5('stage7')::uuid,7,'In-Process Quality Inspection','{qa,production}','Inspection + NCR Gate'),
 (md5('stage8')::uuid,8,'Final Inspection & Acceptance','{qa,customer_tpi}','Acceptance + Release'),
 (md5('stage9')::uuid,9,'Quality Dossier & Dispatch','{qa,stores}','Dossier + Dispatch')
on conflict (stage_no) do update set name=excluded.name, owner_roles=excluded.owner_roles, gate_name=excluded.gate_name;

-- ---------- demo users (password Demo@1234) + profiles ----------
with u(role,name,dept) as (values
 ('admin','System Admin','IT'),('sales','Rakesh Verma','Sales & Projects'),('engineering','Anita Deshmukh','Design Engineering'),
 ('planning','Suresh Iyer','Project Planning'),('qa','Meera Nair','Quality Assurance'),('ppc','Vikram Singh','PPC'),
 ('procurement','Pooja Sharma','Procurement'),('stores','Imran Khan','Stores & Incoming QA'),('production','Ganesh Patil','Shop Floor'),
 ('customer_tpi','Arun Kulkarni (TPI)','External Inspection'),('management','Dr. S. Rao','Plant Management')),
a as (
  insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,
    created_at,updated_at,confirmation_token,recovery_token,email_change_token_new,email_change,email_change_token_current,phone_change,phone_change_token,reauthentication_token)
  select '00000000-0000-0000-0000-000000000000', md5('user-'||role)::uuid, 'authenticated','authenticated',
    replace(role,'customer_','')||'@demo.com', crypt('Demo@1234', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), '','','','','','','',''
  from u on conflict (id) do nothing),
i as (
  insert into auth.identities (id,user_id,provider_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
  select md5('ident-'||role)::uuid, md5('user-'||role)::uuid, replace(role,'customer_','')||'@demo.com',
    jsonb_build_object('sub', md5('user-'||role)::uuid::text, 'email', replace(role,'customer_','')||'@demo.com', 'email_verified', true),
    'email', now(), now(), now()
  from u on conflict do nothing)
insert into profiles (id, full_name, role, department)
select md5('user-'||role)::uuid, name, role::user_role, dept from u on conflict (id) do nothing;

-- ---------- customers ----------
insert into customers (id, code, name, contact, city)
select md5('cust-'||n)::uuid, 'C'||lpad(n::text,3,'0'), name, 'purchase@'||lower(replace(split_part(name,' ',1),'&',''))||'.example', city
from (values (1,'Vindhya Steel Works','Bhilai'),(2,'Mahanadi Cement Ltd','Raipur'),(3,'Kalinga Power Corp','Angul'),
 (4,'Hindustan Mining Equipment','Dhanbad'),(5,'Sagar Ports & Cranes','Visakhapatnam'),(6,'Narmada Fertilizers','Bharuch'),
 (7,'Chhattisgarh Alloys','Korba'),(8,'Deccan Foundries','Hyderabad')) v(n,name,city)
on conflict (id) do nothing;

-- ---------- orders (12, spread across all 9 stages; 2 dispatched) ----------
insert into orders (id,sap_order_no,sap_project_no,customer_id,product_description,qty,due_date,route_type,current_stage,status,priority,sync_status,last_synced_at,created_by)
select md5('order-'||n)::uuid, '45001'||lpad(n::text,3,'0'), 'PRJ-JSPL-26-'||lpad(n::text,3,'0'), md5('cust-'||c)::uuid, p, q, current_date + d,
  r::route_type, s::smallint, st::order_status, pr, sy::sync_status, case when sy='synced' then now() - interval '1 day' end, md5('user-sales')::uuid
from (values
 (1,'EOT Crane Girder – 20T, 18 m span',2,'ETO',6,1,'active','high',25,'synced'),
 (2,'Gearbox Housing – Fabricated & Machined',4,'MTO',6,2,'active','medium',40,'synced'),
 (3,'Conveyor Pulley Ø1200 × 1600',6,'MTO',9,3,'dispatched','low',-15,'synced'),
 (4,'Hydraulic Press Frame – 500T',1,'ETO',3,4,'active','high',90,'synced'),
 (5,'Kiln Shell Segment – Ø4.2 m × 3 m',2,'ETO',5,5,'active','high',60,'synced'),
 (6,'Support Roller Assembly for Rotary Kiln',2,'MTO',8,6,'active','medium',10,'synced'),
 (7,'Ball Mill End Cover – Ø3.8 m',2,'ETO',7,7,'active','high',30,'synced'),
 (8,'Stacker Reclaimer Boom Section',1,'ETO',2,8,'active','medium',120,'synced'),
 (9,'Idler Roller Set – Troughed 35°',40,'MTO',1,1,'active','low',75,'pending'),
 (10,'Slag Ladle Carrier Frame',2,'MTO',4,2,'active','medium',55,'synced'),
 (11,'Jaw Crusher Main Frame',1,'ETO',9,3,'dispatched','medium',-30,'synced'),
 (12,'Furnace Charging Car Chassis',1,'MTO',9,4,'active','high',7,'synced')
) v(n,p,q,r,s,c,st,pr,d,sy)
on conflict (id) do nothing;

insert into order_stages (id, order_id, stage_no, status, started_at, completed_at)
select md5('os-'||o.id::text||'-'||g)::uuid, o.id, g,
  (case when o.status='dispatched' or g < o.current_stage then 'completed' when g = o.current_stage then 'in_progress' else 'pending' end)::stage_status,
  case when o.status='dispatched' or g <= o.current_stage then now() - make_interval(days => 12-g) end,
  case when o.status='dispatched' or g < o.current_stage then now() - make_interval(days => 11-g) end
from orders o cross join generate_series(1,9) g
on conflict (id) do nothing;
-- Order 1 is in the rework loop: stage 7 blocked, back on stage 6
update order_stages set status='blocked', started_at=null, completed_at=null
 where order_id=md5('order-1')::uuid and stage_no=7;
update order_stages set status='in_progress', completed_at=null
 where order_id=md5('order-1')::uuid and stage_no=6;

insert into route_steps (id, order_id, route_type, step_name, seq, status)
select md5('rs-'||o.id::text||'-'||s.seq)::uuid, o.id, o.route_type, s.name, s.seq,
  case when o.current_stage >= 3 then 'done' when o.current_stage = 2 and s.seq = 1 then 'in_progress' else 'pending' end
from orders o join (values ('MTO',1,'Approved design'),('MTO',2,'Order-specific verification'),('MTO',3,'Approved BOM / routing baseline'),
  ('ETO',1,'New / revised engineering'),('ETO',2,'Technical review'),('ETO',3,'Drawing & BOM approval'),('ETO',4,'Controlled release')) s(rt,seq,name)
  on s.rt = o.route_type::text
on conflict (id) do nothing;

-- ---------- drawings (multi-revision; one superseded chain; one pending EC) ----------
insert into drawings (id, order_id, drawing_no, revision, status, file_url, approved_by, released_at)
select md5('drw-'||o.id::text||'-A')::uuid, o.id, 'DWG-'||right(o.sap_order_no,3)||'-GA', 'A',
  (case when right(o.sap_order_no,3)::int in (1,5,7) then 'superseded' when o.current_stage = 2 then 'under_review' else 'released' end)::drawing_status,
  'https://placehold.co/1200x800?text=DWG-'||right(o.sap_order_no,3)||'+Rev+A',
  case when o.current_stage <> 2 then md5('user-engineering')::uuid end,
  case when o.current_stage <> 2 then now() - interval '30 days' end
from orders o where o.current_stage >= 2
on conflict (id) do nothing;
insert into drawings (id, order_id, drawing_no, revision, status, file_url, approved_by, released_at)
select md5('drw-'||o.id::text||'-B')::uuid, o.id, 'DWG-'||right(o.sap_order_no,3)||'-GA', 'B', 'released',
  'https://placehold.co/1200x800?text=DWG-'||right(o.sap_order_no,3)||'+Rev+B', md5('user-engineering')::uuid, now() - interval '15 days'
from orders o where right(o.sap_order_no,3)::int in (1,5,7)
on conflict (id) do nothing;
insert into drawings (id, order_id, drawing_no, revision, status, file_url)
values (md5('drw-'||md5('order-7')::uuid::text||'-C')::uuid, md5('order-7')::uuid, 'DWG-007-GA', 'C', 'under_review',
  'https://placehold.co/1200x800?text=DWG-007+Rev+C')
on conflict (id) do nothing;
insert into engineering_changes (id, order_id, drawing_id, new_drawing_id, reason, impact_summary, impact, status, requested_by)
values (md5('ec-1')::uuid, md5('order-7')::uuid, md5('drw-'||md5('order-7')::uuid::text||'-B')::uuid, md5('drw-'||md5('order-7')::uuid::text||'-C')::uuid,
  'Customer revised bolt-circle PCD on end cover', 'Re-drilling of 24 holes; machining WIP affected',
  '{"affected_stages":[6,7],"bom_items":["ITM-007-05","ITM-007-09"],"wip":"Machining ~60% complete"}', 'impact_review', md5('user-engineering')::uuid)
on conflict (id) do nothing;

-- ---------- BOM (8–15 items per order) & routing ----------
insert into bom_items (id, order_id, item_code, description, qty, uom, material_grade, sap_material_no)
select md5('bom-'||o.id::text||'-'||c.k)::uuid, o.id, 'ITM-'||right(o.sap_order_no,3)||'-'||lpad(c.k::text,2,'0'), c.d,
  ((c.k*3 + right(o.sap_order_no,3)::int) % 9) + 1, c.u, c.g, 'M'||(100000+c.k)
from orders o join (values
 (1,'Web plate 12 mm','IS 2062 E250 BR','NOS'),(2,'Flange plate 20 mm','IS 2062 E250 BR','NOS'),(3,'Stiffener plate 10 mm','IS 2062 E250 BR','NOS'),
 (4,'Shell plate 25 mm','SA 516 Gr.70','NOS'),(5,'Shaft blank Ø120 forging','EN8','NOS'),(6,'Hub forging','EN8','NOS'),
 (7,'Spherical roller bearing 22228','Bearing steel','NOS'),(8,'Gear blank','20MnCr5','NOS'),(9,'HT fastener set M24','Gr 8.8','SET'),
 (10,'Welding consumables E7018','AWS A5.1','KG'),(11,'Pipe 168.3 × 10 mm','API 5L Gr.B','M'),(12,'Channel ISMC 250','IS 2062 E250','M'),
 (13,'Lagging rubber 12 mm','Rubber 60 Shore A','M2'),(14,'Hydraulic seal kit','NBR/PTFE','SET'),(15,'Base plate 40 mm','SA 516 Gr.70','NOS')
) c(k,d,g,u) on c.k <= 8 + (right(o.sap_order_no,3)::int % 8)
where o.current_stage >= 3
on conflict (id) do nothing;

insert into routing_ops (id, order_id, op_no, work_center, description, std_hours)
select md5('rop-'||o.id::text||'-'||r.op)::uuid, o.id, r.op, r.wc, r.d, r.h
from orders o cross join (values (10,'CNC Plasma','Profile cutting of plates',6.0),(20,'Fabrication Bay','Fit-up & tack welding',12.0),
 (30,'Welding Bay','Main assembly welding (SAW/MIG)',24.0),(40,'HBM / VTL','Machining of bores & faces',16.0),
 (50,'Assembly & Paint','Final assembly, blasting & painting',10.0)) r(op,wc,d,h)
where o.current_stage >= 3
on conflict (id) do nothing;

-- ---------- ITP / QAP + checklists ----------
insert into itp_templates (id, name, stage_no)
select md5('itp-'||s)::uuid, 'ITP / QAP – Stage '||lpad(s::text,2,'0'), s from unnest(array[3,5,6,7,8,9]) s
on conflict (id) do nothing;
insert into itp_items (id, template_id, seq, activity, acceptance_criteria, point_type, responsible_role)
select md5('itpi-'||i.s||'-'||i.q)::uuid, md5('itp-'||i.s)::uuid, i.q, i.a, i.c, i.t::itp_point_type, i.r::user_role
from (values
 (3,1,'Review BOM against released drawing','BOM matches released revision','review','planning'),
 (3,2,'Approve ITP / QAP and hold points','Approved by QA','hold','qa'),
 (5,1,'MTC verification against specification','Chemical & mechanical properties within spec','hold','qa'),
 (5,2,'Visual & dimensional check on receipt','No lamination/pitting; thickness within tolerance','witness','stores'),
 (6,1,'Fit-up inspection before welding','Gap & alignment per drawing','hold','qa'),
 (6,2,'Weld visual inspection','No undercut, porosity or cracks','witness','production'),
 (7,1,'Dimensional check after welding','All dimensions within tolerance','hold','qa'),
 (7,2,'NDT – UT / MPI / DPT','No rejectable indications','witness','qa'),
 (8,1,'Final dimensional & functional check','As per approved drawing & test procedure','hold','qa'),
 (8,2,'Customer / TPI witness & release','Signed acceptance','witness','customer_tpi'),
 (9,1,'Dossier completeness review','100% completeness','hold','qa'),
 (9,2,'Dispatch clearance','Dossier signed off','review','stores')) i(s,q,a,c,t,r)
on conflict (id) do nothing;

insert into order_itp_points (id, order_id, itp_item_id, status, released_by, released_at)
select md5('oip-'||o.id::text||'-'||i.id::text)::uuid, o.id, i.id,
  case when t.stage_no < o.current_stage or o.status = 'dispatched' then 'released' else 'open' end,
  case when t.stage_no < o.current_stage or o.status = 'dispatched' then md5('user-qa')::uuid end,
  case when t.stage_no < o.current_stage or o.status = 'dispatched' then now() - interval '5 days' end
from orders o join itp_templates t on t.stage_no <= o.current_stage join itp_items i on i.template_id = t.id
where o.current_stage >= 3
on conflict (id) do nothing;

insert into checklist_templates (id, name, stage_no, itp_template_id)
select md5('clt-'||s)::uuid, 'Checklist – Stage '||lpad(s::text,2,'0'), s, md5('itp-'||s)::uuid from unnest(array[5,6,7,8]) s
on conflict (id) do nothing;
insert into checklist_fields (id, template_id, seq, label, field_type, unit, nominal, tol_min, tol_max, options)
select md5('clf-'||f.s||'-'||f.q)::uuid, md5('clt-'||f.s)::uuid, f.q, f.l, f.t::field_type, f.u, f.nom, f.lo, f.hi, f.o
from (values
 (5,1,'MTC heat no. matches material','pass_fail',null,null,null,null,null::jsonb),
 (5,2,'Plate thickness','numeric','mm',12,11.5,12.5,null),
 (5,3,'Surface condition','dropdown',null,null,null,null,'["Clean","Pitted","Rusted"]'::jsonb),
 (5,4,'Receiving remarks','text',null,null,null,null,null),
 (6,1,'Drawing revision verified at workstation','pass_fail',null,null,null,null,null),
 (6,2,'Fit-up gap','numeric','mm',2,1,3,null),
 (6,3,'Operator remarks','text',null,null,null,null,null),
 (7,1,'Overall length','numeric','mm',6000,5995,6005,null),
 (7,2,'Flatness','numeric','mm',0,0,3,null),
 (7,3,'Weld visual acceptable','pass_fail',null,null,null,null,null),
 (7,4,'Instrument ID used','dropdown',null,null,null,null,'["INS-VC-001","INS-MIC-014","INS-TAPE-007"]'::jsonb),
 (8,1,'Overall dimensions per drawing','pass_fail',null,null,null,null,null),
 (8,2,'Functional / load test','pass_fail',null,null,null,null,null),
 (8,3,'Paint DFT','numeric','µm',150,120,200,null)) f(s,q,l,t,u,nom,lo,hi,o)
on conflict (id) do nothing;

-- ---------- materials ----------
insert into material_requirements (id, bom_item_id, required_qty, stock_qty, pr_no, po_no, vendor, eta, status)
select md5('mr-'||b.id::text)::uuid, b.id, b.qty, x.stock,
  case when x.st = 'available' then null else 'PR-26-'||right(o.sap_order_no,3)||'-'||lpad(x.k::text,2,'0') end,
  case when x.st in ('available','pr_raised') then null else 'PO-45-'||right(o.sap_order_no,3)||'-'||lpad(x.k::text,2,'0') end,
  (array['SAIL Bhilai','Jindal Steel','Kalyani Forge','SKF India','Gabriel Fasteners'])[1 + x.k % 5],
  current_date + (x.k*3 - 20), x.st
from bom_items b join orders o on o.id = b.order_id
cross join lateral (select right(b.item_code,2)::int k,
  case when o.current_stage = 4 and right(b.item_code,2)::int % 4 = 0 then b.qty else 0 end stock,
  case when o.current_stage >= 6 then 'received'
       when o.current_stage = 5 then (case when right(b.item_code,2)::int <= 6 then 'received' else 'in_transit' end)
       when right(b.item_code,2)::int % 4 = 0 then 'available'
       when right(b.item_code,2)::int <= 8 then 'po_placed'
       when right(b.item_code,2)::int = 9 then 'delayed' else 'pr_raised' end st) x
where o.current_stage >= 4
on conflict (id) do nothing;

insert into material_receipts (id, order_id, bom_item_id, po_no, heat_no, batch_id, qr_code, mtc_url, mtc_verified, inspection_result, disposition, received_by)
select md5('mrc-'||b.id::text)::uuid, o.id, b.id, mr.po_no, 'H'||(7000 + x.n*10 + x.k),
  'B-'||lpad(x.n::text,3,'0')||'-'||lpad(x.k::text,2,'0'),
  'QR|B-'||lpad(x.n::text,3,'0')||'-'||lpad(x.k::text,2,'0')||'|H'||(7000 + x.n*10 + x.k),
  '/seed/mtc/MTC-H'||(7000 + x.n*10 + x.k)||'.pdf', not (x.n=5 and x.k=3),
  (case when x.n=5 and x.k=3 then 'pending' when x.n=2 and x.k=4 then 'fail' else 'pass' end)::result_type,
  (case when x.n=5 and x.k=3 then 'hold' when x.n=2 and x.k=4 then 'reject' else 'accept' end)::disposition_type,
  md5('user-stores')::uuid
from bom_items b join orders o on o.id=b.order_id join material_requirements mr on mr.bom_item_id=b.id
cross join lateral (select right(o.sap_order_no,3)::int n, right(b.item_code,2)::int k) x
where o.current_stage >= 5 and x.k <= 5 and mr.status = 'received'
on conflict (id) do nothing;

-- ---------- production ----------
insert into work_orders (id, order_id, wo_no, status, material_receipt_id, planned_start, planned_end)
select md5('wo-'||o.id::text)::uuid, o.id, 'WO-'||o.sap_order_no,
  case when o.current_stage > 6 then 'completed' else 'in_progress' end,
  (select r.id from material_receipts r join bom_items b on b.id=r.bom_item_id where r.order_id=o.id and right(b.item_code,2)='01'),
  current_date - 20, current_date + 5
from orders o where o.current_stage >= 6
on conflict (id) do nothing;

insert into work_order_ops (id, work_order_id, routing_op_id, op_no, status, operator, started_at, ended_at, qty_done)
select md5('woo-'||r.id::text)::uuid, w.id, r.id, r.op_no, x.st, 'Operator-'||(r.op_no/10),
  case when x.st <> 'pending' then now() - interval '10 days' end, case when x.st = 'completed' then now() - interval '6 days' end,
  case when x.st = 'completed' then o.qty else 0 end
from work_orders w join orders o on o.id=w.order_id join routing_ops r on r.order_id=o.id
cross join lateral (select case when o.current_stage > 6 then 'completed'
  when right(o.sap_order_no,3)='001' then (case when r.op_no = 30 then 'in_progress' else 'completed' end)
  else (case when r.op_no <= 20 then 'completed' when r.op_no = 30 then 'in_progress' else 'pending' end) end st) x
on conflict (id) do nothing;

-- ---------- instruments, inspections, measurements, NDT ----------
insert into instruments (id, id_no, description, calibration_due, status) values
 (md5('ins-INS-VC-001')::uuid,'INS-VC-001','Vernier caliper 0–300 mm', current_date + 90,'valid'),
 (md5('ins-INS-MIC-014')::uuid,'INS-MIC-014','Micrometer 25–50 mm', current_date + 60,'valid'),
 (md5('ins-INS-UT-003')::uuid,'INS-UT-003','UT flaw detector', current_date + 120,'valid'),
 (md5('ins-INS-MPI-002')::uuid,'INS-MPI-002','MPI yoke 220 V', current_date + 45,'valid'),
 (md5('ins-INS-TAPE-007')::uuid,'INS-TAPE-007','Steel measuring tape 30 m', current_date - 20,'expired'),
 (md5('ins-INS-DFT-004')::uuid,'INS-DFT-004','DFT gauge', current_date + 75,'valid')
on conflict (id) do nothing;

insert into inspections (id, order_id, stage_no, type, inspector_id, result, instrument_id, calibration_valid, remarks, inspected_at, created_at)
select md5('insp-in-'||o.id::text)::uuid, o.id, 5, 'incoming', md5('user-qa')::uuid,
  (case when right(o.sap_order_no,3)='005' then 'pending' else 'pass' end)::result_type,
  md5('ins-INS-VC-001')::uuid, true, 'Incoming inspection of plates & forgings', now() - interval '20 days', now() - interval '20 days'
from orders o where o.current_stage >= 5
on conflict (id) do nothing;

insert into inspections (id, order_id, stage_no, type, inspector_id, result, instrument_id, calibration_valid, remarks, inspected_at, created_at)
select md5('insp-ip-'||o.id::text)::uuid, o.id, 7, 'in_process', md5('user-qa')::uuid,
  (case x.n when 1 then 'fail' when 7 then 'blocked' else 'pass' end)::result_type,
  md5(case when x.n = 7 then 'ins-INS-TAPE-007' else 'ins-INS-VC-001' end)::uuid, x.n <> 7,
  case x.n when 1 then 'Overall length out of tolerance – NCR raised' when 7 then 'Blocked: instrument calibration expired' else 'In-process dimensional & NDT' end,
  now() - interval '5 days', now() - interval '5 days'
from orders o cross join lateral (select right(o.sap_order_no,3)::int n) x
where o.current_stage >= 7 or x.n = 1
on conflict (id) do nothing;

insert into inspections (id, order_id, stage_no, type, inspector_id, result, instrument_id, calibration_valid, remarks, inspected_at, created_at)
select md5('insp-fi-'||o.id::text)::uuid, o.id, 8, 'final', md5('user-qa')::uuid,
  (case when right(o.sap_order_no,3)='006' then 'pending' else 'pass' end)::result_type,
  md5('ins-INS-MIC-014')::uuid, true, 'Final dimensional & functional inspection', now() - interval '3 days', now() - interval '3 days'
from orders o where o.current_stage >= 8
on conflict (id) do nothing;

insert into inspection_measurements (id, inspection_id, characteristic, nominal, tol_min, tol_max, actual, result)
select md5('meas-'||i.id::text||'-'||m.q)::uuid, i.id, m.c, m.nom, m.lo, m.hi,
  case when i.result='blocked' then null when i.result='fail' and m.q=1 then 6012 else m.act end,
  (case when i.result='blocked' then 'pending' when i.result='fail' and m.q=1 then 'fail' else 'pass' end)::result_type
from inspections i cross join (values (1,'Overall length (mm)',6000,5995,6005,6001.5),(2,'Flatness (mm)',0,0,3,1.8),(3,'Web thickness (mm)',12,11.5,12.5,12.1)) m(q,c,nom,lo,hi,act)
where i.type = 'in_process'
on conflict (id) do nothing;
insert into inspection_measurements (id, inspection_id, characteristic, nominal, tol_min, tol_max, actual, result)
select md5('meas-'||i.id::text||'-'||m.q)::uuid, i.id, m.c, m.nom, m.lo, m.hi,
  case when i.result='pending' then null else m.act end, (case when i.result='pending' then 'pending' else 'pass' end)::result_type
from inspections i cross join (values (1,'Overall height (mm)',2500,2495,2505,2501.0),(2,'Bore diameter (mm)',250,249.95,250.05,250.01)) m(q,c,nom,lo,hi,act)
where i.type = 'final'
on conflict (id) do nothing;

insert into ndt_records (id, inspection_id, method, report_no, result, report_url)
select md5('ndt-'||i.id::text||'-'||m.method)::uuid, i.id, m.method, 'NDT-'||m.method||'-26-'||right(o.sap_order_no,3), 'pass', '/seed/ndt/NDT-'||m.method||'-'||right(o.sap_order_no,3)||'.pdf'
from inspections i join orders o on o.id=i.order_id cross join (values ('UT'),('MPI'),('DPT')) m(method)
where i.type='in_process' and i.result='pass' and right(o.sap_order_no,3)::int in (3,6,11,12)
on conflict (id) do nothing;

-- ---------- NCRs (1 open, 1 rework loop, 1 awaiting reinspection, 3 closed) + CAPA ----------
insert into ncrs (id, ncr_no, order_id, stage_no, inspection_id, description, severity, root_cause_category, disposition, status, raised_by,
                  reinspection_inspection_id, qa_approved_by, auto_raised, created_at, closed_at)
select md5('ncr-'||v.n)::uuid, 'NCR-2026-'||lpad(v.n::text,4,'0'), o.id, v.stg, i.id, v.descr, v.sev, v.rc, v.disp::disposition_type, v.st::ncr_status,
  md5('user-qa')::uuid, case when v.st='closed' then i.id end, case when v.st='closed' then md5('user-qa')::uuid end, v.auto,
  now() - make_interval(days => v.ago), case when v.st='closed' then now() - make_interval(days => v.ago - 2) end
from (values
 (1,1,7,'Overall length 6012 mm exceeds tolerance 5995–6005 after welding','major','Welding distortion','rework','rework',true,2),
 (2,7,7,'Measuring tape INS-TAPE-007 calibration expired – inspection blocked','minor','Measurement system',null,'open',true,3),
 (3,12,7,'Girder camber out of tolerance after welding','major','Welding distortion','rework','closed',false,40),
 (4,3,7,'Pulley shell ovality beyond limit after welding','major','Welding distortion','rework','closed',false,60),
 (5,11,7,'Frame bore misalignment due to weld shrinkage','major','Welding distortion','use_as_is','closed',false,75),
 (6,6,8,'Paint DFT below 120 µm on roller housing','minor','Process control','rework','awaiting_reinspection',false,2)
) v(n,o_n,stg,descr,sev,rc,disp,st,auto,ago)
join orders o on o.id = md5('order-'||v.o_n)::uuid
join inspections i on i.order_id = o.id and i.type = (case when v.stg = 8 then 'final' else 'in_process' end)::inspection_type
on conflict (id) do nothing;

insert into capas (id, capa_no, trigger_type, linked_ncr_ids, root_cause, corrective_action, preventive_action, owner, due_date, effectiveness_check, status)
values (md5('capa-1')::uuid, 'CAPA-2026-0001', 'auto_repeat_ncr',
  array[md5('ncr-1')::uuid, md5('ncr-3')::uuid, md5('ncr-4')::uuid, md5('ncr-5')::uuid],
  'Welding distortion – repeated across 4 fabrications (Welding distortion)',
  'Adopt back-step welding sequence with rigid jigs for girders, shells and frames',
  'Revise WPS and fit-up fixtures; weld-distortion training for welders',
  md5('user-production')::uuid, current_date + 30, 'Rework rate < 2% over next 3 fabrications', 'in_progress')
on conflict (id) do nothing;

-- ---------- evidence, approvals, dossiers, dispatch ----------
insert into evidence_files (id, order_id, stage_no, ref_table, type, file_url, caption, uploaded_by)
select md5('ev-'||o.id::text||'-'||s)::uuid, o.id, s, 'order_stages', 'photo',
  'https://placehold.co/800x600?text=Order+'||right(o.sap_order_no,3)||'+Stage+0'||s, 'Stage 0'||s||' evidence photo',
  md5('user-'||case s when 5 then 'stores' when 6 then 'production' else 'qa' end)::uuid
from orders o cross join generate_series(5,8) s
where (s < o.current_stage or o.status = 'dispatched' or (s = o.current_stage and s in (5,6,7)))
  and not (right(o.sap_order_no,3) = '012' and s = 8)
on conflict (id) do nothing;
insert into evidence_files (id, order_id, stage_no, ref_table, type, file_url, caption, uploaded_by, reused_from_id)
values (md5('ev-reuse-12')::uuid, md5('order-12')::uuid, 7, 'evidence_files', 'photo', 'https://placehold.co/800x600?text=Order+012+Stage+06',
  'Reused from stage 06 (assembly photo)', md5('user-qa')::uuid, md5('ev-'||md5('order-12')::uuid::text||'-6')::uuid)
on conflict (id) do nothing;

insert into approvals (id, order_id, stage_no, approver_id, decision, comment, signed_at)
select md5('apr-'||o.id::text||'-'||s)::uuid, o.id, s, md5('user-qa')::uuid, 'approved', 'Stage 0'||s||' gate cleared', now() - make_interval(days => 12 - s)
from orders o cross join unnest(array[3,5,7,8,9]) s
where s < o.current_stage or o.status = 'dispatched'
on conflict (id) do nothing;
insert into order_tpi_assignments (order_id, user_id)
select md5('order-'||n)::uuid, md5('user-customer_tpi')::uuid from unnest(array[3,6,11,12]) n on conflict do nothing;
insert into approvals (id, order_id, stage_no, approver_id, decision, comment, signed_at)
select md5('apr-tpi-'||n)::uuid, md5('order-'||n)::uuid, 8, md5('user-customer_tpi')::uuid, 'approved', 'Witnessed & accepted by TPI', now() - interval '3 days'
from unnest(array[3,11,12]) n on conflict (id) do nothing;

insert into dossiers (id, order_id, version, completeness_pct, missing_items, pdf_url, qa_signoff_by, signed_at) values
 (md5('dos-3')::uuid, md5('order-3')::uuid, 1, 100, '[]', '/seed/dossiers/DOS-45001003-v1.pdf', md5('user-qa')::uuid, now() - interval '16 days'),
 (md5('dos-11')::uuid, md5('order-11')::uuid, 1, 100, '[]', '/seed/dossiers/DOS-45001011-v1.pdf', md5('user-qa')::uuid, now() - interval '31 days'),
 (md5('dos-12')::uuid, md5('order-12')::uuid, 1, 90.9, '["Final inspection evidence"]', null, null, null)
on conflict (id) do nothing;
insert into dispatches (id, order_id, vehicle_no, lr_no, dispatch_date, sap_delivery_no, status) values
 (md5('dsp-3')::uuid, md5('order-3')::uuid, 'CG04-LT-4521', 'LR-88213', current_date - 15, '8000012345', 'dispatched'),
 (md5('dsp-11')::uuid, md5('order-11')::uuid, 'MH12-QP-9087', 'LR-77102', current_date - 30, '8000012301', 'dispatched')
on conflict (id) do nothing;

-- ---------- SAP log, notifications, audit, settings ----------
insert into sap_sync_log (id, entity, entity_id, direction, status, payload, message, synced_at)
select md5('sap-ord-'||o.id::text)::uuid, 'order', o.id, 'outbound', 'synced', jsonb_build_object('sap_order_no', o.sap_order_no),
  'Order/project synced to SAP S/4HANA (mock)', now() - interval '2 days' from orders o where o.sync_status = 'synced'
on conflict (id) do nothing;
insert into sap_sync_log (id, entity, entity_id, direction, status, payload, message, synced_at) values
 (md5('sap-9')::uuid,'order',md5('order-9')::uuid,'outbound','pending','{"sap_order_no":"45001009"}','Awaiting sync – queued',now()),
 (md5('sap-10')::uuid,'material_requirements',md5('order-10')::uuid,'inbound','failed','{"po":"PO-45-010-11"}','RFC timeout: PR/PO status read failed (simulated)',now() - interval '1 hour'),
 (md5('sap-5')::uuid,'goods_receipt',md5('order-5')::uuid,'outbound','synced','{"batch":"B-005-01"}','Goods receipt posted (mock)',now() - interval '4 days'),
 (md5('sap-d3')::uuid,'dispatch',md5('order-3')::uuid,'outbound','synced','{"delivery":"8000012345"}','Dispatch posted (mock)',now() - interval '15 days'),
 (md5('sap-d11')::uuid,'dispatch',md5('order-11')::uuid,'outbound','synced','{"delivery":"8000012301"}','Dispatch posted (mock)',now() - interval '30 days')
on conflict (id) do nothing;

insert into notifications (id, user_id, title, body, link, read)
select md5('notif-'||v.n)::uuid, md5('user-'||v.role)::uuid, v.t, v.b, '/orders/'||md5('order-'||v.o)::uuid::text, false
from (values
 (1,'qa','NCR-2026-0002 raised','Instrument calibration expired on order 45001007',7),
 (2,'qa','CAPA auto-raised','Repeat NCRs: Welding distortion',1),
 (3,'engineering','Engineering change pending','Impact review needed for DWG-007-GA Rev C',7),
 (4,'production','Rework required','NCR-2026-0001 – rework on order 45001001',1),
 (5,'production','Drawing released','DWG-005-GA Rev B released; Rev A superseded',5),
 (6,'stores','Material on hold','Batch B-005-03 awaiting MTC verification',5),
 (7,'ppc','PO status sync failed','SAP read failed for order 45001010',10),
 (8,'management','Dossier readiness','Order 45001012 dossier at 90.9%',12),
 (9,'sales','SAP sync pending','Order 45001009 not yet synced',9)) v(n,role,t,b,o)
on conflict (id) do nothing;

insert into audit_logs (id, user_id, action, table_name, record_id, new_data, created_at)
select md5('audit-'||v.n)::uuid, md5('user-'||v.role)::uuid, v.a, v.t, md5(v.r)::uuid, v.d::jsonb, now() - make_interval(hours => v.h)
from (values
 (1,'sales','INSERT','orders','order-9','{"sap_order_no":"45001009"}',48),
 (2,'engineering','UPDATE','drawings','drw-x','{"status":"released","revision":"B"}',36),
 (3,'qa','INSERT','ncrs','ncr-1','{"ncr_no":"NCR-2026-0001"}',30),
 (4,'qa','UPDATE','approvals','apr-x','{"decision":"approved","stage_no":8}',12),
 (5,'stores','UPDATE','material_receipts','mrc-x','{"disposition":"hold"}',6)) v(n,role,a,t,r,d,h)
on conflict (id) do nothing;

insert into app_settings (key, value) values ('sap_mode', '{"mode":"mock"}') on conflict (key) do nothing;

select setval('ncr_seq', 6, true);
select setval('capa_seq', 1, true);
set session_replication_role = origin;
