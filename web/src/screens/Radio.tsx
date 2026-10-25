import { ago, fmt } from '../lib/format'
import { useGame, type NewsKind } from '../store/game'

const BADGE: Record<NewsKind, [string, string]> = {
  bonus: ['BONUS', 'ok'],
  malus: ['MALUS', 'ko'],
  giuria: ['GIURIA', ''],
  bank: ['ALMANACCO', 'bank'],
  sponsor: ['SPONSOR', 'bank'],
}

export function Radio() {
  const s = useGame()
  return (
    <>
      <div className="top"><div className="logo">RADIOCORSA</div></div>
      <p className="bankbal">Saldo del Banco (indicativo): <b className={s.bankCash < 0 ? 'neg' : ''}>{fmt(s.bankCash)}</b></p>
      <div style={{ marginTop: 12 }}>
        {s.news.length === 0 && <p className="empty">Ancora nessuna notizia. Il Banco si farà sentire.</p>}
        {s.news.map((n) => (
          <article className="news" key={n.id}>
            <div className="h">
              <span className={`pill ${BADGE[n.kind][1]}`}>{BADGE[n.kind][0]}</span>
              <span className="when">{ago(n.at, s.now)}</span>
            </div>
            <h3 className="ti">{n.title}</h3>
            <p>{n.text}</p>
          </article>
        ))}
      </div>
    </>
  )
}
