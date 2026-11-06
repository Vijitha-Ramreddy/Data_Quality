# JSPL Raipur Integrated Workflow Architecture

## Proposed folder structure

```text
/
├── src/
│   ├── components/          # Shared shell and workflow UI
│   ├── pages/               # Routed application modules
│   └── services/            # Supabase and SAP adapter services
├── supabase/
│   ├── migrations/          # Ordered database migrations
│   └── seed.sql             # Deterministic demo data
├── docs/ARCHITECTURE.md
├── package.json
└── .env.example
```

## Data model

```mermaid
erDiagram
  profiles ||--o{ orders : "owns work"
  customers ||--o{ orders : places
  orders ||--o{ order_stages : progresses
  orders ||--o{ route_steps : routes
  orders ||--o{ drawings : controlled_by
  drawings ||--o{ engineering_changes : revisioned_by
  orders ||--o{ bom_items : contains
  bom_items ||--o{ material_requirements : plans
  orders ||--o{ material_receipts : receives
  orders ||--o{ work_orders : executes
  work_orders ||--o{ work_order_ops : contains
  inspections ||--o{ inspection_measurements : measures
  inspections ||--o{ ndt_records : records
  orders ||--o{ inspections : quality_checks
  orders ||--o{ ncrs : exceptions
  ncrs ||--o{ capas : triggers
  orders ||--o{ approvals : authorizes
  orders ||--o{ dossiers : compiles
  dossiers ||--o{ dispatches : releases
  orders ||--o{ evidence_files : stores
  orders ||--o{ sap_sync_log : synchronizes
```

## Workflow state machine

```mermaid
stateDiagram-v2
  [*] --> Stage01
  Stage01 --> Stage02: order gate
  Stage02 --> Stage03: released drawing gate
  Stage03 --> Stage04: plan gate
  Stage04 --> Stage05: material gate
  Stage05 --> Stage06: incoming QA gate
  Stage06 --> Stage07: operation gate
  Stage07 --> Stage08: inspection and NCR gate
  Stage08 --> Stage09: customer acceptance gate
  Stage09 --> Dispatched: signed dossier gate
  Stage07 --> Stage06: NCR rework loop
  Stage06 --> Stage07: reinspection
```

## SAP adapter

The frontend uses an adapter interface with a mock implementation backed by Supabase tables. Production mode is a validated integration stub. Adapter calls write outcomes to `sap_sync_log`, expose synchronization status in the UI, and can be retried without bypassing database gates.
