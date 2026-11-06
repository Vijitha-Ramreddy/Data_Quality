import { AlertTriangle, ArrowRight, CheckCircle2 } from 'lucide-react'
import { FormEvent, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { configured, supabase } from '../services/supabase'

const stages = [
  ['01', 'Order Receipt', 'Sales / Projects'], ['02', 'Engineering & Drawings', 'Engineering'],
  ['03', 'Project, BOM & Quality', 'Planning / QA'], ['04', 'Materials & Procurement', 'PPC / Procurement'],
  ['05', 'Incoming QA', 'Stores / QA'], ['06', 'Fabrication & Assembly', 'Production'],
  ['07', 'In-process Inspection', 'QA / Production'], ['08', 'Final Acceptance', 'QA / Customer'],
  ['09', 'Dossier & Dispatch', 'QA / Logistics'],
]

export default function Home() {
  const [open, setOpen] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [success, setSuccess] = useState('')
  const [customers, setCustomers] = useState<Array<{ id: string; name: string }>>([])

  useEffect(() => {
    if (!supabase) return
    supabase.from('customers').select('id,name').order('name')
      .then(({ data }) => setCustomers(data ?? []))
  }, [])

  async function createOrder(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError('')
    setSuccess('')
    setSaving(true)
    const form = new FormData(event.currentTarget)
    const product = String(form.get('product') ?? '').trim()
    const sapOrder = String(form.get('sapOrder') ?? '').trim()
    const sapProject = String(form.get('sapProject') ?? '').trim()
    const dueDate = String(form.get('dueDate') ?? '')
    const route = String(form.get('route') ?? 'ETO')
    const quantity = Number(form.get('quantity'))
    const customerId = String(form.get('customer') ?? '')

    try {
      if (!sapOrder || !product || !quantity || quantity < 1) {
        throw new Error('SAP order number, product description, and quantity are required.')
      }

      const order = {
        sap_order_no: sapOrder,
        sap_project_no: sapProject || null,
        product_description: product,
        qty: quantity,
        due_date: dueDate || null,
        route_type: route,
        customer_id: customerId || null,
      }

      if (supabase) {
        const { error: insertError } = await supabase.from('orders').insert(order).select().single()
        if (insertError) throw insertError
      } else {
        const demoOrders = JSON.parse(localStorage.getItem('demo-orders') ?? '[]') as object[]
        localStorage.setItem('demo-orders', JSON.stringify([{ ...order, id: crypto.randomUUID(), current_stage: 1, status: 'active', sync_status: 'synced' }, ...demoOrders]))
      }

      setSuccess(`${sapOrder} created successfully${configured ? ' and synced to Supabase' : ' in demo mode'}.`)
      setOpen(false)
      event.currentTarget.reset()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught))
    } finally {
      setSaving(false)
    }
  }

  return (
    <>
      <div className="page-heading"><div><h1>Workflow Overview</h1><p>Live execution status across the manufacturing digital thread</p></div><button className="primary" onClick={() => setOpen(true)}>Create / Sync Order</button></div>
      {success && <div className="success-banner">{success}</div>}
      <section className="route-banner"><b>MTO</b><ArrowRight /><span>Approved design → verification → BOM baseline</span><b>ETO</b><ArrowRight /><span>Engineering review → drawing &amp; BOM approval</span><strong>Both routes converge at Stage 03</strong></section>
      <div className="workflow-grid">{stages.map(([no, name, owner], index) => (
        <Link className={`stage-card stage-${index + 1}`} key={no} to="/orders">
          <span className="stage-number">{no}</span><div><h3>{name}</h3><small>{owner}</small></div><div className="stage-count"><strong>{12 - index * 1}</strong> orders</div><CheckCircle2 />
        </Link>
      ))}</div>
      <div className="overview-grid">
        <section className="panel"><h2>Digital Stage Checkpoint</h2><ol className="checkpoint">{['Login / identify', 'Approved task & drawing', 'Checklist / measures', 'Evidence & photos', 'QA approval', 'Gate & next stage'].map((step, i) => <li key={step}><span>{i + 1}</span>{step}</li>)}</ol></section>
        <section className="panel exceptions"><h2><AlertTriangle /> Exception Triggers</h2><div><b>Engineering Change</b><span>1 impact review pending</span></div><div><b>Quality Failure</b><span>6 NCRs · 1 in rework</span></div><div><b>Systemic Failure</b><span>1 CAPA active</span></div></section>
      </div>
      {open && (
        <div className="modal-backdrop" role="presentation" onMouseDown={(event) => {
          if (event.target === event.currentTarget) setOpen(false)
        }}>
          <section className="order-modal" role="dialog" aria-modal="true" aria-labelledby="create-order-title">
            <div className="modal-heading"><div><span className="eyebrow">Order receipt</span><h2 id="create-order-title">Create / sync order</h2></div><button className="close-button" type="button" aria-label="Close" onClick={() => setOpen(false)}>×</button></div>
            <form onSubmit={createOrder}>
              <label>SAP order number *<input name="sapOrder" placeholder="e.g. 4500123456" required /></label>
              <label>SAP project number<input name="sapProject" placeholder="Optional" /></label>
              <label>Customer<select name="customer" disabled={!customers.length}><option value="">Use seeded/default customer</option>{customers.map(customer => <option key={customer.id} value={customer.id}>{customer.name}</option>)}</select></label>
              <label>Product description *<input name="product" placeholder="e.g. EOT crane girder" required /></label>
              <div className="form-row">
                <label>Quantity *<input name="quantity" type="number" min="1" defaultValue="1" required /></label>
                <label>Due date<input name="dueDate" type="date" /></label>
              </div>
              <fieldset><legend>Manufacturing route *</legend><label><input type="radio" name="route" value="ETO" defaultChecked /> ETO</label><label><input type="radio" name="route" value="MTO" /> MTO</label></fieldset>
              {error && <div className="form-error">{error}</div>}
              <div className="modal-actions"><button type="button" className="secondary" onClick={() => setOpen(false)}>Cancel</button><button type="submit" className="primary" disabled={saving}>{saving ? 'Creating…' : 'Create & sync'}</button></div>
            </form>
          </section>
        </div>
      )}
    </>
  )
}
