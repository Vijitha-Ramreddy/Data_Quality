import { FormEvent, useEffect, useState } from 'react'
import { Search } from 'lucide-react'
import { supabase } from '../services/supabase'
import { useNavigate } from 'react-router-dom'

type DemoOrder = {
  id: string
  sap_order_no: string
  product_description: string
  route_type: string
  qty: number
  sync_status: string
  current_stage?: number
  status?: string
}

const moduleStages: Record<string, number> = {
  Orders: 1,
  Drawings: 2,
  Planning: 3,
  Materials: 4,
  'Incoming QA': 5,
  'Shop Floor': 6,
  Inspections: 7,
  'NCR & CAPA': 7,
  'Final Acceptance': 8,
  Dossier: 9,
  Dashboard: 0,
  Administration: 0,
}

const nextRoutes: Record<number, string> = {
  2: '/planning',
  3: '/materials',
  4: '/incoming',
  5: '/shop-floor',
  6: '/inspections',
  7: '/acceptance',
  8: '/dossier',
}

const stageNames = ['', 'Order Receipt', 'Engineering & Drawings', 'Project/BOM Planning', 'Material Planning', 'Incoming QA', 'Fabrication & Assembly', 'In-process Quality', 'Final Acceptance', 'Dossier & Dispatch']

export default function WorkPage({ title }: { title: string }) {
  const navigate = useNavigate()
  const [demoOrders, setDemoOrders] = useState<DemoOrder[]>([])
  const [supabaseOrders, setSupabaseOrders] = useState<DemoOrder[]>([])
  const [newOpen, setNewOpen] = useState(false)
  const [message, setMessage] = useState('')
  const [nextStageRoute, setNextStageRoute] = useState('')
  const [records, setRecords] = useState<Array<{ id: string; title: string; status: string }>>([])
  const [statusFilter, setStatusFilter] = useState('All statuses')

  useEffect(() => {
    const savedOrders = JSON.parse(localStorage.getItem('demo-orders') ?? '[]') as DemoOrder[]
    setDemoOrders(savedOrders.map(order => ({ ...order, current_stage: order.current_stage ?? 1, status: order.status ?? 'active' })))
    const savedRecords = JSON.parse(localStorage.getItem(`demo-module-${title}`) ?? '[]') as Array<{ id: string; title: string; status: string }>
    setRecords(savedRecords)

    if (supabase) {
      supabase.from('orders').select('id,sap_order_no,product_description,route_type,qty,sync_status,current_stage,status').order('created_at', { ascending: false })
        .then(({ data, error }) => {
          if (!error) setSupabaseOrders((data ?? []) as DemoOrder[])
        })
    }
  }, [title])

  const orders = supabase ? supabaseOrders : demoOrders
  const moduleStage = moduleStages[title] ?? 0

  function orderStatus(order: DemoOrder) {
    const stage = order.current_stage ?? 1
    if (stage === 9 && (order.status === 'dispatched' || order.status === 'completed')) return 'Completed'
    if (stage <= 1) return 'Open'
    return 'In progress'
  }

  const filteredOrders = statusFilter === 'All statuses'
    ? orders
    : orders.filter(order => orderStatus(order) === statusFilter)
  const showNewButton = title === 'Administration'

  function saveLocalOrders(updated: DemoOrder[]) {
    localStorage.setItem('demo-orders', JSON.stringify(updated))
    setDemoOrders(updated)
  }

  async function completeStage(order: DemoOrder) {
    const stage = order.current_stage ?? 1
    if (supabase) {
      const { error } = await supabase.rpc('complete_stage', { p_order: order.id, p_stage: stage })
      if (error) {
        setMessage(error.message)
        return
      }
      setSupabaseOrders(current => current.map(item => item.id === order.id
        ? { ...item, current_stage: stage < 9 ? stage + 1 : 9, status: stage === 9 ? 'dispatched' : item.status }
        : item))
    } else {
      const updated = demoOrders.map(item => item.id === order.id
        ? { ...item, current_stage: stage < 9 ? stage + 1 : 9, status: stage === 9 ? 'dispatched' : 'active' }
        : item)
      saveLocalOrders(updated)
    }
    setMessage(stage === 9 ? `${order.sap_order_no} completed and dispatched.` : `${order.sap_order_no} advanced from Stage ${stage} to Stage ${Math.min(stage + 1, 9)}.`)
    const route = nextRoutes[stage]
    if (route) setNextStageRoute(route)
  }

  function createRecord(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    const record = {
      id: crypto.randomUUID(),
      title: String(form.get('title') ?? '').trim(),
      status: String(form.get('status') ?? 'Open'),
    }
    if (!record.title) return
    const updated = [record, ...records]
    localStorage.setItem(`demo-module-${title}`, JSON.stringify(updated))
    setRecords(updated)
    setNewOpen(false)
    setMessage(`${title} item created successfully.`)
  }

  return (
    <>
      <div className="page-heading"><div><h1>{title}</h1><p>Operational workspace</p></div>{showNewButton && <button className="primary" onClick={() => setNewOpen(true)}>New</button>}</div>
      {message && <div className="success-banner">{message}</div>}
      {nextStageRoute && stageNames[(moduleStages[title] ?? 0) + 1] && <div className="handoff-banner"><span>Next phase: <strong>{stageNames[(moduleStages[title] ?? 0) + 1]}</strong></span><button className="primary" onClick={() => { setNextStageRoute(''); navigate(nextStageRoute) }}>Open next phase</button></div>}
      {title === 'Dashboard' && <div className="dashboard-statuses">
        {(['Open', 'In progress', 'Completed'] as const).map(status => (
          <button key={status} className={statusFilter === status ? 'status-card active' : 'status-card'} onClick={() => setStatusFilter(statusFilter === status ? 'All statuses' : status)}>
            <span>{status}</span><strong>{orders.filter(order => orderStatus(order) === status).length}</strong>
          </button>
        ))}
      </div>}
      <div className="toolbar"><label><Search /><input placeholder={`Search ${title.toLowerCase()}…`} /></label><select aria-label="Filter" value={statusFilter} onChange={event => setStatusFilter(event.target.value)}><option>All statuses</option><option>Open</option><option>In progress</option><option>Completed</option></select></div>
      {filteredOrders.length > 0 && <div className="workflow-list">
        {filteredOrders.map(order => {
          const stage = order.current_stage ?? 1
          const activeHere = moduleStage === 0 || stage === moduleStage
          return <div className="workflow-order" key={order.id}>
            <div><strong>{order.sap_order_no}</strong><span>{order.product_description}</span></div>
            <span>Stage {stage}/9 · {stageNames[stage]}</span>
            <span className={`order-state state-${orderStatus(order).toLowerCase().replace(' ', '-')}`}>{orderStatus(order)}</span>
            <b>{order.route_type}</b>
            <div className="progress-track"><span style={{ width: `${stage / 9 * 100}%` }} /></div>
            {activeHere && stage < 9 && <button className="secondary" onClick={() => completeStage(order)}>Complete phase &amp; advance</button>}
            {activeHere && stage === 9 && order.status !== 'dispatched' && <button className="secondary" onClick={() => completeStage(order)}>Complete &amp; dispatch</button>}
            {order.status === 'dispatched' && <span className="status">Completed / Dispatched</span>}
          </div>
        })}
      </div>}
      {records.length > 0 && <div className="demo-orders">{records.map(record => <div className="demo-order" key={record.id}><div><strong>{record.title}</strong><span>{title}</span></div><span className="status">{record.status}</span></div>)}</div>}
      {filteredOrders.length === 0 && records.length === 0 && <section className="empty-panel"><h2>No {statusFilter === 'All statuses' ? title.toLowerCase() : statusFilter.toLowerCase()} orders found</h2><p>{statusFilter === 'All statuses' ? 'Create an order on Workflow Overview, then use its stage actions to move it through all nine phases.' : 'No orders currently match this dashboard status.'}</p>{showNewButton && statusFilter === 'All statuses' && <button className="primary" onClick={() => setNewOpen(true)}>Create first item</button>}</section>}
      {newOpen && <div className="modal-backdrop" role="presentation" onMouseDown={event => { if (event.target === event.currentTarget) setNewOpen(false) }}>
        <section className="order-modal" role="dialog" aria-modal="true"><div className="modal-heading"><div><span className="eyebrow">{title}</span><h2>Create new item</h2></div><button className="close-button" type="button" onClick={() => setNewOpen(false)}>×</button></div>
          <form onSubmit={createRecord}><label>Description or reference *<input name="title" required /></label><label>Status<select name="status"><option>Open</option><option>In progress</option><option>Awaiting approval</option><option>Completed</option></select></label><div className="modal-actions"><button type="button" className="secondary" onClick={() => setNewOpen(false)}>Cancel</button><button className="primary">Create</button></div></form>
        </section>
      </div>}
    </>
  )
}
