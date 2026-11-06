import { Factory, ShieldCheck } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../services/supabase'

const roles = ['admin', 'sales', 'engineering', 'planning', 'qa', 'ppc', 'procurement', 'stores', 'production', 'customer_tpi', 'management']

export default function Login() {
  const navigate = useNavigate()
  async function quickLogin(role: string) {
    localStorage.setItem('demo-role', role)
    if (supabase) await supabase.auth.signInWithPassword({ email: `${role.replace('customer_tpi', 'tpi')}@demo.com`, password: 'Demo@1234' })
    navigate('/')
  }
  return (
    <div className="login">
      <section className="login-brand"><Factory /><h1>JSPL Raipur</h1><p>Integrated Manufacturing &amp; Quality Workflow</p><strong>One digital thread, multiple manufacturing routes, integrated quality governance, SAP-connected execution.</strong></section>
      <section className="login-card">
        <ShieldCheck />
        <h2>Welcome</h2>
        <p>Use a demo role to explore the proposed workflow.</p>
        <div className="role-grid">{roles.map(role => (
          <button key={role} onClick={() => quickLogin(role)}>{role.replaceAll('_', ' ')}</button>
        ))}</div>
      </section>
    </div>
  )
}
