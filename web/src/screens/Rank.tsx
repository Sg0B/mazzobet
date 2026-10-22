import { useState } from 'react'
import { cur } from '../lib/format'
import { useGame, type LeaderRow } from '../store/game'

type Mode = 'wealth' | 'picks' | 'bank'

export function Rank() {
  const s = useGame()
  const [mode, setMode] = useState<Mode>('wealth')
  const me = s.team
  const rows = s.leaderboard

  const table = (list: LeaderRow[], val: (r: LeaderRow) => string | number) => (
    <div className="tbl">
      {list.map((r, i) => (
        <div key={r.teamId} className={`row${r.name === me ? ' me' : ''}${i === 0 ? ' top1' : ''}`}>
          <span className="pos">{i + 1}</span>
          <span className="nm">{r.name}{r.name === me && <em>TU</em>}</span>
          <span className="val">{val(r)}</span>
        </div>
      ))}
    </div>
  )

  const bankList = rows.filter((r) => r.bankruptcies || r.readmissions).sort((a, b) => b.bankruptcies - a.bankruptcies)

  const seg = (k: Mode, label: string) => (
    <button className={mode === k ? 'on' : ''} onClick={() => setMode(k)}>{label}</button>
  )

  return (
    <>
      <div className="top"><div className="logo">CLASSIFICHE</div></div>
      <div className="seg">{seg('wealth', 'Patrimonio')}{seg('picks', 'Pronostici')}{seg('bank', 'Banco')}</div>
      {mode === 'wealth' && table(rows.slice().sort((a, b) => b.balance - a.balance || b.correct - a.correct), (r) => cur(r.balance))}
      {mode === 'picks' && (
        <>
          {table(rows.slice().sort((a, b) => b.correct - a.correct || b.balance - a.balance), (r) => r.correct)}
          <p className="note">Pronostici corretti. A parità conta il patrimonio.</p>
        </>
      )}
      {mode === 'bank' && (
        <>
          <div className="stat"><span>Cassa del Banco</span><b className={s.bankCash < 0 ? 'neg' : ''}>{s.bankCash < 0 ? '' : '+'}{cur(s.bankCash)}</b></div>
          <div className="stat" style={{ marginTop: 8 }}><span>di cui puntate in corso</span><b>{cur(s.bankInPlay)}</b></div>
          <h2 className="sec">Bancarotte e riammissioni</h2>
          <div className="tbl">
            {bankList.length ? bankList.map((r) => (
              <div key={r.teamId} className={`row${r.name === me ? ' me' : ''}`}>
                <span className="pos" />
                <span className="nm">{r.name}</span>
                <span className="val">{r.bankruptcies} / {r.readmissions}</span>
              </div>
            )) : <div className="row"><span /><span className="nm">Nessuna bancarotta</span><span /></div>}
          </div>
          <p className="note">Colonna: bancarotte / riammissioni. Cassa solo informativa: il Banco resta illimitato.</p>
        </>
      )}
    </>
  )
}
