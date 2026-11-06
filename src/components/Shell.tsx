import { Bell, ChevronRight, Factory, LogOut, Menu } from 'lucide-react'
import { useState } from 'react'
import { NavLink, Outlet } from 'react-router-dom'

const nav = [
  ['Workflow', '/'], ['Task Inbox', '/inbox'], ['Orders', '/orders'],
  ['Drawings', '/drawings'], ['Planning', '/planning'], ['Materials', '/materials'], ['Incoming QA', '/incoming'], ['Shop Floor', '/shop-floor'],
  ['Inspections', '/inspections'], ['NCR / CAPA', '/quality'], ['Final Acceptance', '/acceptance'], ['Dossier', '/dossier'],
  ['Dashboard', '/dashboard'], ['Admin', '/admin'],
]

export default function Shell() {
  const [open, setOpen] = useState(false)
  const role = localStorage.getItem('demo-role') || 'Demo user'
  return (
    <div className="app-shell">
      <aside className={open ? 'sidebar open' : 'sidebar'}>
        <div className="brand"><Factory /><span>JSPL Raipur<small>Integrated Workflow</small></span></div>
        <nav>{nav.map(([label, to]) => (
          <NavLink key={to} to={to} end={to === '/'} onClick={() => setOpen(false)}>{label}</NavLink>
        ))}</nav>
        <div className="sidebar-user"><strong>{role}</strong><a href="/login"><LogOut size={16} /> Sign out</a></div>
      </aside>
      <main>
        <header>
          <button className="icon-button" aria-label="Open navigation" onClick={() => setOpen(!open)}><Menu /></button>
          <div className="header-title"><b>PROPOSED · FIT-GAP PENDING</b><span>Secure bidirectional integration • interface availability to be validated</span></div>
          <button className="icon-button" aria-label="Notifications"><Bell /></button>
        </header>
        <div className="content"><Outlet /></div>
        <footer>Lumbini Elite Group | JSPL Raipur | Proposed TO-BE | November 2026. Target design — subject to functional and SAP fit-gap validation.</footer>
      </main>
    </div>
  )
}
