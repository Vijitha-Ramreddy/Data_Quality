# JSPL Raipur – Supabase backend (schema, RLS, seed)

## Run the application

```bash
npm install
npm run dev
```

Copy `.env.example` to `.env` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`. The demo role switcher also opens the frontend shell without a Supabase connection; database-backed features require the migrations and seed below.

## Files
- `supabase/migrations/001_schema.sql` – enums, 37 tables, indexes
- `supabase/migrations/002_functions.sql` – audit, stage gates, auto-NCR, auto-CAPA, rework loop, dossier check, dispatch rule, SAP mock RPC
- `supabase/migrations/003_rls.sql` – RLS for every table, realtime publication, storage buckets
- `supabase/seed.sql` – idempotent dummy data (12 orders, 11 demo users)

## Run (local)
```bash
supabase init            # once, if no supabase/ config exists
supabase start
supabase db reset        # applies migrations/ then seed.sql
```
## Run (hosted project)
SQL Editor → run `001`, `002`, `003`, then `seed.sql`, in that order.
(`seed.sql` uses `set session_replication_role = replica`; if your role can't, run it from `psql` as `postgres`.)

## Demo logins (password `Demo@1234`)
admin@, sales@, engineering@, planning@, qa@, ppc@, procurement@, stores@, production@, tpi@ (customer_tpi), management@ — all `@demo.com`

## RPCs for the frontend
| RPC | Purpose |
|---|---|
| `complete_stage(order, stage)` | Validates the gate, completes the stage, advances the order, notifies next owners |
| `stage_blockers(order, stage)` | Returns text[] of reasons the gate would fail (use to show blockers in the UI) |
| `start_rework(ncr)` / `finish_rework(ncr, inspection)` | Stage 07 → 06 → 07 rework loop |
| `refresh_dossier(order)` / `dossier_check(order)` | Completeness % and missing items |
| `sap_sync_order(order)` | Mock SAP sync + log entry |

## Notes
- `order_itp_points` is an extra table (not in the original list): per-order instance of ITP hold/witness points, needed to evaluate "open hold point" gates.
- `customer_tpi` is read-only except one narrow policy letting them insert their own Stage 08 approval for assigned orders.
- NCR closure requires reinspection pass only for `rework` / `use_as_is` dispositions (not scrap / return-to-vendor).
- Frontend env: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`.
