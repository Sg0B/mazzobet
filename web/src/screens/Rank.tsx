import { useEffect, useState } from 'react'
import { fmt } from '../lib/format'
import { loadRankings, useGame, type RankRow, type Rankings } from '../store/game'

type Mode = 'patrimonio' | 'pronostici' | 'striscia' | 'puntate' | 'bancarotte'
const MODES: { id: Mode; label: string; title: string; note: string }[] = [
  { id: 'patrimonio', label: 'Patrimonio', title: 'Patrimonio (Carletti)', note: 'Saldo più le puntate ancora in corso.' },
  { id: 'pronostici', label: 'Pronostici', title: 'Pronostici corretti', note: '' },
  { id: 'striscia', label: 'Striscia', title: 'Striscia vincente', note: 'Record di vincite di fila nella serata, e quella in corso. Contano solo le vincite con quota e puntata abbastanza alte; le scommesse annullate non spezzano la striscia.' },
  { id: 'puntate', label: 'Puntate', title: 'Somma puntate (Carletti)', note: 'Totale puntato, scommesse aperte ed esitate; i rimborsi non contano.' },
  { id: 'bancarotte', label: 'Bancarotte', title: 'Bancarotte', note: 'A parità, chi è caduto più di recente.' },
]

/** Riga di classifica già pronta: posizione (null = fuori classifica) e testo del valore. */
interface Line { teamId: number; name: string; pos: number | null; val: string }

function lines(r: Rankings, mode: Mode): Line[] {
  const base = (x: RankRow, val: string): Line => ({ teamId: x.teamId, name: x.name, pos: x.pos, val })
  switch (mode) {
    case 'patrimonio': return r.patrimonio.map((x) => base(x, fmt(x.value)))
    case 'pronostici': return r.pronostici.map((x) => base(x, x.done ? `${x.won} su ${x.done} (${x.pct}%)` : '—'))
    case 'striscia': return r.striscia.map((x) => base(x, x.cur ? `${x.best} · in corso ${x.cur}` : String(x.best)))
    case 'puntate': return r.puntate.map((x) => base(x, fmt(x.value)))
    case 'bancarotte': return r.bancarotte.map((x) => base(x, String(x.value)))
  }
}

export function Rank() {
  const s = useGame()
  const [mode, setMode] = useState<Mode>('patrimonio')
  const me = s.team
  const r = s.rankings

  useEffect(() => {
    void loadRankings()
    const t = setInterval(() => void loadRankings(), 8000)
    return () => clearInterval(t)
  }, [])

  const cur = MODES.find((m) => m.id === mode)!
  const list = r ? lines(r, mode) : []
  const mine = list.find((l) => l.name === me)

  return (
    <>
      <div className="top"><div className="logo">CLASSIFICHE</div></div>
      <div className="rkchips" role="tablist">
        {MODES.map((m) => (
          <button key={m.id} role="tab" aria-selected={mode === m.id} className={`chip${mode === m.id ? ' on' : ''}`} onClick={() => setMode(m.id)}>
            {m.label}
          </button>
        ))}
      </div>
      <h2 className="sec">{cur.title}</h2>
      {!r && <p className="empty">Carico le classifiche…</p>}
      {r && mode === 'bancarotte' && list.length === 0 && <p className="empty">Nessun gregario caduto, per ora.</p>}
      {r && list.length > 0 && (
        <div className="tbl">
          {list.map((l) => (
            <div key={l.teamId} className={`row${l.name === me ? ' me' : ''}${l.pos !== null && l.pos <= 3 ? ' top3' : ''}`}>
              <span className="pos">{l.pos ?? ''}</span>
              <span className="nm">{l.name}{l.name === me && <em>TU</em>}</span>
              <span className="val">{l.val}</span>
            </div>
          ))}
        </div>
      )}
      {r && mode === 'pronostici' && (
        <p className="note">Vinte su esitate. Compaiono in classifica da {r.minEsitate} scommesse esitate; le altre squadre sono in fondo, senza posizione. A parità conta il numero di vincite.</p>
      )}
      {cur.note && <p className="note">{cur.note}</p>}
      {r && mine && (
        <div className="rkme" aria-live="polite">
          <span className="pos">{mine.pos ?? '—'}</span>
          <span className="nm">La tua squadra</span>
          <span className="val">{mine.val}</span>
        </div>
      )}
    </>
  )
}
