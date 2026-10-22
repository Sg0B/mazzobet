import { useEffect, useState } from 'react'
import { CREATE_FEE, READMIT_BALANCE } from '../lib/rules'
import { cur } from '../lib/format'
import { actions, committed, useGame, type Side } from '../store/game'
import { Countdown } from '../components/Countdown'
import { MarketCard } from '../components/MarketCard'

export function Home({ onBet, onCreate }: { onBet: (id: number, side: Side) => void; onCreate: () => void }) {
  const s = useGame()
  const [i, setI] = useState(0)
  useEffect(() => {
    const t = setInterval(() => setI((x) => x + 1), 4500)
    return () => clearInterval(t)
  }, [])

  const latest = s.news.slice(0, 4)
  const shown = latest.length ? latest[i % latest.length] : undefined
  const open = s.markets.filter((m) => m.status === 'open').sort((a, b) => a.expiresAt - b.expiresAt)
  const mineOpen = s.markets.filter((m) => m.my && (m.status === 'open' || m.status === 'closed')).length
  const bankrupt = s.bankruptUntil !== null
  const lockOver = bankrupt && s.now >= s.bankruptUntil!
  const frozen = s.sessionStatus === 'closing' || s.sessionStatus === 'closed'
  const canCreate = s.balance >= CREATE_FEE && !bankrupt && !frozen

  return (
    <>
      <div className="top">
        <div className="logo">MAZZO<b>BET</b></div>
        <span className="teamchip">{s.team}</span>
      </div>
      <div className="bal">
        <div className="l">Saldo disponibile</div>
        <div className="v">{cur(s.balance)}</div>
        <div className="s">{mineOpen ? `Impegnati ${cur(committed(s))} in ${mineOpen} ${mineOpen === 1 ? 'puntata' : 'puntate'}` : 'Nessuna puntata in corso'}</div>
      </div>

      <button className="radio" onClick={() => actions.setTab('radio')} aria-label="Apri RadioCorsa">
        <span className="k">RADIOCORSA</span>
        <div className="t">{shown ? shown.title : 'In attesa del Banco'}</div>
        <p>{shown ? shown.text : 'Le notizie della corsa appariranno qui.'}</p>
        <div className="dots">
          {latest.map((n, j) => (
            <i key={n.id} className={j === i % latest.length ? 'on' : ''} />
          ))}
        </div>
      </button>

      {frozen && (
        <div className="bk" style={{ background: 'var(--surface)', borderColor: 'var(--lime)' }}>
          <h3 style={{ color: 'var(--lime)' }}>{s.sessionStatus === 'closed' ? 'SERATA CHIUSA' : 'SERATA IN CHIUSURA'}</h3>
          <p>
            {s.sessionStatus === 'closed'
              ? 'La classifica è congelata. Puoi guardare saldi, movimenti e RadioCorsa, ma non si può più giocare.'
              : 'Nuove puntate e scommesse sospese. Gli esiti e i ricorsi in corso si concludono, poi la classifica si congela.'}
          </p>
        </div>
      )}

      {bankrupt && !frozen && (
        <div className="bk">
          <h3>SEI IN BANCAROTTA</h3>
          <p>
            Nuove puntate sospese.{' '}
            {lockOver ? `Il blocco è finito: puoi chiedere la riammissione a ${cur(READMIT_BALANCE)}.` : <>Puoi chiedere la riammissione tra <b><Countdown until={s.bankruptUntil!} /></b>.</>}
          </p>
          <button className="cta sm" disabled={!lockOver} onClick={() => void actions.readmit()}>RICHIEDI RIAMMISSIONE</button>
        </div>
      )}

      <button className="cta" disabled={!canCreate} onClick={onCreate}>CREA UNA SCOMMESSA</button>
      {!canCreate && !frozen && <p className="note" style={{ textAlign: 'center' }}>Servono almeno {cur(CREATE_FEE)} e nessuna bancarotta in corso.</p>}

      <h2 className="sec"><span className="dot" />Live betting</h2>
      {open.length ? open.map((m) => <MarketCard key={m.id} m={m} onBet={onBet} />) : <p className="empty">{frozen ? 'Nessuna scommessa aperta.' : 'Nessuna scommessa aperta. Crea la prima.'}</p>}
    </>
  )
}
