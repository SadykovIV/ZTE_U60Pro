import { useEffect, useState } from 'react'
import { AUTH_EXPIRED_EVENT, clearToken, hasToken } from './data/client'
import { HomeProvider } from './app/HomeContext'
import Login from './app/Login'
import Shell, { type Group } from './app/Shell'
import { useTheme } from './app/theme'
import SectionBoundary from './app/SectionBoundary'
import { ConfirmHost, Toaster } from './ui/feedback'

import HomePage from './features/home/HomePage'
import SignalGroup from './features/signal/SignalGroup'
import NetworkGroup from './features/network/NetworkGroup'
import ModemGroup from './features/modem/ModemGroup'
import SystemGroup from './features/system/SystemGroup'
import EsimPage from './features/esim/EsimPage'

export default function App() {
  const [authed, setAuthed] = useState(hasToken())
  const [group, setGroup] = useState<Group>('home')
  const { theme, toggle } = useTheme()

  useEffect(() => {
    const onAuthExpired = () => setAuthed(false)
    window.addEventListener(AUTH_EXPIRED_EVENT, onAuthExpired)
    return () => window.removeEventListener(AUTH_EXPIRED_EVENT, onAuthExpired)
  }, [])

  if (!authed) {
    return (
      <>
        <Login onAuthed={() => setAuthed(true)} />
        <Toaster />
      </>
    )
  }

  return (
    <>
      <HomeProvider fast={group === 'home' || group === 'signal'}>
        <Shell group={group} onNavigate={setGroup} theme={theme} onToggleTheme={toggle}>
          <SectionBoundary key={group}>
          {group === 'home' && <HomePage />}
          {group === 'signal' && <SignalGroup />}
          {group === 'network' && <NetworkGroup />}
          {group === 'modem' && <ModemGroup />}
          {group === 'esim' && <EsimPage />}
          {group === 'system' && (
            <SystemGroup
              onLogout={() => {
                clearToken()
                setAuthed(false)
              }}
            />
          )}
          </SectionBoundary>
        </Shell>
      </HomeProvider>
      <Toaster />
      <ConfirmHost />
    </>
  )
}
