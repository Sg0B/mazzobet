import { useEffect, type ReactNode } from 'react'

export function Sheet({ onClose, children }: { onClose: () => void; children: ReactNode }) {
  useEffect(() => {
    document.body.classList.add('lock')
    return () => document.body.classList.remove('lock')
  }, [])
  return (
    <div id="sheet">
      <div className="bd" onClick={onClose} />
      <div className="sh" role="dialog" aria-modal="true">
        {children}
      </div>
    </div>
  )
}
