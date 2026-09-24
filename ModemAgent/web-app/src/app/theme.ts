import { useCallback, useEffect, useState } from 'react'

export type Theme = 'light' | 'dark'

function currentTheme(): Theme {
  return document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light'
}

export function useTheme() {
  const [theme, setThemeState] = useState<Theme>(currentTheme)

  useEffect(() => {
    // Track OS-level changes when the user hasn't chosen explicitly.
    const mq = window.matchMedia('(prefers-color-scheme: dark)')
    const onChange = () => {
      if (!localStorage.getItem('u60.theme')) {
        const next = mq.matches ? 'dark' : 'light'
        document.documentElement.setAttribute('data-theme', next)
        setThemeState(next)
      }
    }
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [])

  const toggle = useCallback(() => {
    setThemeState((prev) => {
      const next = prev === 'dark' ? 'light' : 'dark'
      document.documentElement.setAttribute('data-theme', next)
      try {
        localStorage.setItem('u60.theme', next)
      } catch {
        /* private mode */
      }
      return next
    })
  }, [])

  return { theme, toggle }
}
