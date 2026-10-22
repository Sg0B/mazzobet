import { useEffect } from 'react'
import { actions, mustResolve, useGame } from '../store/game'
import { Countdown } from './Countdown'

/** Schermata obbligatoria e bloccante per il creatore (PRD §7, §10). Coda: un mercato alla volta. */
export function MustResolve() {
  const s = useGame()
  const queue = mustResolve(s)
  const m = queue[0]
  useEffect(() => {
    if (!m) return
    document.body.classList.add('lock')
    return () => document.body.classList.remove('lock')
  }, [m])
  if (!m) return null
  return (
    <div id="must">
      <div className="box">
        <h2>ESITA LA SCOMMESSA!</h2>
        <p className="q">{m.text}</p>
        <p className="s">
          Scommessa n. {m.num}. Le puntate sono chiuse. Restano <b><Countdown until={m.resolveBy ?? 0} /></b>.
          {queue.length > 1 && ` Altre ${queue.length - 1} in coda.`}
        </p>
        <div className="btns" style={{ marginTop: 22 }}>
          <button onClick={() => actions.resolve(m.id, 'yes')}>SÌ</button>
          <button onClick={() => actions.resolve(m.id, 'no')}>NO</button>
        </div>
      </div>
    </div>
  )
}
