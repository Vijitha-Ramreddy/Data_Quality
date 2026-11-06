import { Navigate, Route, Routes } from 'react-router-dom'
import Shell from './components/Shell'
import Home from './pages/Home'
import Login from './pages/Login'
import WorkPage from './pages/WorkPage'

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route element={<Shell />}>
        <Route index element={<Home />} />
        <Route path="/orders" element={<WorkPage title="Orders" />} />
        <Route path="/inbox" element={<WorkPage title="My Task Inbox" />} />
        <Route path="/drawings" element={<WorkPage title="Drawings" />} />
        <Route path="/planning" element={<WorkPage title="Planning" />} />
        <Route path="/materials" element={<WorkPage title="Materials" />} />
        <Route path="/incoming" element={<WorkPage title="Incoming QA" />} />
        <Route path="/shop-floor" element={<WorkPage title="Shop Floor" />} />
        <Route path="/inspections" element={<WorkPage title="Inspections" />} />
        <Route path="/quality" element={<WorkPage title="NCR & CAPA" />} />
        <Route path="/acceptance" element={<WorkPage title="Final Acceptance" />} />
        <Route path="/dossier" element={<WorkPage title="Dossier" />} />
        <Route path="/dashboard" element={<WorkPage title="Dashboard" />} />
        <Route path="/admin" element={<WorkPage title="Administration" />} />
      </Route>
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}
