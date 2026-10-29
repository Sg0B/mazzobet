// Prova della corsa simulata «La Teramana» (migration 017–018) su un Postgres in memoria (PGlite): non tocca nessun database vero.
// Uso (dalla radice del progetto):  npm i --no-save @electric-sql/pglite  poi  node server/tests/pglite/corsa.mjs
// Il tempo di gara si sposta riscrivendo l'istante di partenza (come «banco_inizio nel passato»): nessuna attesa di 3 ore.
import { boot } from './load.mjs'
import { buildRace, readRace } from '../../src/race.ts'
import { fileURLToPath } from 'node:url'

let ok = 0, ko = 0
const t = (name, cond, extra = '') => { if (cond) { ok++; console.log('  ok  ', name) } else { ko++; console.log('  FAIL', name, extra) } }
const ACT = `(select id from mazzobet.game_sessions where status='active')`

const { timeline, banco } = readRace(fileURLToPath(new URL('../../data/', import.meta.url)))
const built = buildRace(timeline, banco)
t('i due file sono validi', built.payload !== null && built.problems.length === 0, JSON.stringify(built.problems))
const payload = built.payload

async function fresh(nTeams = 6) {
  const db = await boot(18)
  const q = async (sql, p) => (await db.query(sql, p)).rows
  const one = async (sql, p) => (await q(sql, p))[0]
  const rpc = async (fn, args = []) => { const ph = args.map((_, i) => '$' + (i + 1)).join(','); return (await one(`select public.${fn}(${ph}) as r`, args)).r }
  const fails = async (fn, args, msg) => { try { await rpc(fn, args); return false } catch (e) { return e.message.includes(msg) } }
  await q(`select mazzobet.admin_new_session('Corsa')`)
  await q(`update mazzobet.config set value = extract(epoch from timestamptz '2099-01-01') where key = 'banco_inizio'`)
  await q(`update mazzobet.game_sessions set ends_at = now() + interval '12 hours'`)
  const tok = {}
  for (let i = 1; i <= nTeams; i++) tok[i] = (await rpc('mb_enter_team', [i, null, 'ua'])).token
  // sposta il tempo di gara a `sec` secondi dalla partenza (non in pausa) e, se serve, dà un passo di corsa
  const jump = async (sec, tick = true) => {
    await q(`update mazzobet.race_runs set started_at = now() - make_interval(secs => ($1::double precision + paused_secs)) where session_id = ${ACT}`, [sec])
    if (tick) await rpc('mb_race_tick')
  }
  const bal = async (team) => Number((await one(`select balance from mazzobet.session_teams where session_id = ${ACT} and team_id = $1`, [team])).balance)
  const mk = async (rid) => one(`select m.* from mazzobet.markets m where m.session_id = ${ACT} and m.race_market_id = $1`, [rid])
  const bet = (team, m, side, amount) => rpc('mb_place_bet', [tok[team], m.id, side, amount])
  const feedIds = async () => (await q(`select event_id from mazzobet.race_feed where session_id = ${ACT} order by at_seconds, seq`)).map((r) => r.event_id)
  return { db, q, one, rpc, fails, tok, jump, bal, mk, bet, feedIds }
}

// ---------------------------------------------------------------------------------------------------------------
console.log('# Caricamento e prima della partenza')
{
  const { q, one, rpc, fails, tok } = await fresh()
  t('senza definizione la corsa non parte', await fails('mb_admin_race_start', [], 'race_not_loaded'))
  const r1 = await rpc('mb_race_load', [JSON.stringify(payload)])
  t('caricate 73 notizie e 10 scommesse', r1.events === 73 && r1.markets === 10, JSON.stringify(r1))
  const r2 = await rpc('mb_race_load', [JSON.stringify(payload)])
  t('ricaricare prima della partenza è ammesso', r2.skipped === false && r2.events === 73)
  const st = await rpc('mb_race_state', [tok[1]])
  t('prima del via: non partita, nessuna notizia, nessuna scommessa', st.status === 'not_started' && st.feed.length === 0 && st.markets.length === 0 && st.elapsed === 0)
  t('prima del via nessuna scommessa nel database', (await one(`select count(*)::int n from mazzobet.markets where race_market_id is not null`)).n === 0)
  t('pausa senza corsa avviata rifiutata', await fails('mb_admin_race_pause', [true], 'race_not_running'))
  await rpc('mb_admin_race_start')
  t('seconda partenza rifiutata', await fails('mb_admin_race_start', [], 'race_already_started'))
  const r3 = await rpc('mb_race_load', [JSON.stringify(payload)])
  t('dopo la partenza la definizione non si cambia', r3.skipped === true)
  const st2 = await rpc('mb_race_state', [tok[1]])
  t('alla partenza esce solo la notizia di via', st2.status === 'running' && st2.feed.length === 1 && st2.feed[0].id === 'PCS001')
  t('alla partenza si apre solo B01', st2.markets.length === 1 && st2.markets[0].raceId === 'B01' && st2.markets[0].yesOdds === 175 && st2.markets[0].noOdds === 205)
  const s = JSON.stringify(st2)
  t('nessun esito né notizia futura nello stato per i telefoni',
    !s.includes('winning') && !s.includes('VINCE LA TERAMANA') && !s.includes('Pennello') && !s.includes('B08') && !s.includes('settlement') && st2.markets[0].outcome === null)
  const gs = JSON.stringify(await rpc('mb_get_state', [tok[1]]))
  t('mb_get_state non contiene esiti né notizie future', !gs.includes('winning') && !gs.includes('VINCE LA TERAMANA'))
  t('un esito non esce nemmeno dalla Regia', !JSON.stringify(await rpc('mb_admin_race_state')).includes('winning'))
}

// ---------------------------------------------------------------------------------------------------------------
console.log('# Scenario completo: B01 → B02 → B07 → B03/B04 → B05 → pausa → B06 → finale')
{
  const { q, one, rpc, fails, tok, jump, bal, mk, bet, feedIds } = await fresh()
  await rpc('mb_race_load', [JSON.stringify(payload)])
  await rpc('mb_admin_race_start')

  // --- B01: puntate, chiusura a +33:30, risultato a +34:00
  let b01 = await mk('B01')
  await bet(1, b01, 'yes', 100); await bet(2, b01, 'no', 50); await bet(3, b01, 'yes', 20)
  t('puntata minima 10', await fails('mb_place_bet', [tok[4], b01.id, 'yes', 5], 'invalid_amount'))
  t('saldo insufficiente', await fails('mb_place_bet', [tok[4], b01.id, 'yes', 5000], 'insufficient_funds'))
  t('puntata uguale ripetuta = nessun secondo addebito', (await bet(1, b01, 'yes', 100)).replay === true && (await bal(1)) === 900)
  t('lato opposto sulla stessa scommessa rifiutato', await fails('mb_place_bet', [tok[1], b01.id, 'no', 100], 'already_bet'))
  await jump(2009)
  t('+33:29 si può ancora puntare', (await bet(4, b01, 'yes', 10)).replay === false)
  await jump(2011, false)    // il timer non ha ancora girato: la chiusura la decide l'orologio di gara
  t('+33:31 la puntata è rifiutata anche prima del passo del timer', await fails('mb_place_bet', [tok[5], b01.id, 'yes', 10], 'market_closed'))
  await rpc('mb_race_tick')
  b01 = await mk('B01')
  t('+33:31 B01 chiusa, non liquidata', b01.status === 'closed' && b01.outcome === null && !(await feedIds()).includes('PCS009'))
  await rpc('mb_tick')
  t('mb_tick non annulla né svuota una scommessa della corsa', (await mk('B01')).status === 'closed')
  t('le notifiche A e B non toccano la corsa',
    await (async () => {
      await q(`insert into mazzobet.push_subscriptions (session_id, team_id, endpoint, p256dh, auth) select ${ACT}, 5, 'e1', 'p', 'a'`)
      await q(`insert into mazzobet.push_subscriptions (session_id, team_id, endpoint, p256dh, auth) select ${ACT}, 6, 'e2', 'p', 'a'`)
      return (await rpc('mb_push_due', [0])).length === 0
    })())
  t('player: ESITA sulla scommessa della corsa rifiutato', await fails('mb_resolve', [tok[1], b01.id, 'yes'], 'not_resolvable'))
  t('Regia: esito manuale rifiutato', await fails('mb_admin_resolve', [b01.id, 'yes'], 'not_resolvable'))
  t('ricorso rifiutato', await fails('mb_appeal', [tok[2], b01.id], 'not_appealable'))
  await jump(2039)
  t('+33:59 niente risultato', (await mk('B01')).status === 'closed' && !(await feedIds()).includes('PCS009'))
  await jump(2040)
  b01 = await mk('B01')
  t('+34:00 pubblicato il GPM e liquidata B01 SÌ', (await feedIds()).includes('PCS009') && b01.status === 'resolved' && b01.outcome === 'yes')
  t('pagamenti B01: 100×1,75=175, 20×1,75=35, 10×1,75=17; perde chi ha detto NO',
    (await bal(1)) === 1075 && (await bal(3)) === 1015 && (await bal(4)) === 1007 && (await bal(2)) === 950)
  const wins1 = (await one(`select count(*)::int n from mazzobet.ledger_transactions where kind='win'`)).n
  await rpc('mb_race_tick'); await rpc('mb_race_tick'); await rpc('mb_tick')
  t('altri passi non pagano due volte', (await one(`select count(*)::int n from mazzobet.ledger_transactions where kind='win'`)).n === wins1 && (await bal(1)) === 1075)
  t('esiti: statistica «azzeccate» aggiornata', Number((await one(`select correct_picks from mazzobet.session_teams where session_id=${ACT} and team_id=1`)).correct_picks) === 1)

  // --- B02 (apre +35:00, chiude +56:30, risultato +57:00): NO
  await jump(2099); t('+34:59 B02 non è ancora aperta', (await mk('B02')) === undefined)
  await jump(2100); let b02 = await mk('B02')
  t('+35:00 si apre B02 con quote 1,90/1,90', b02 && b02.status === 'open' && b02.yes_odds === 190 && b02.no_odds === 190)
  await bet(1, b02, 'yes', 100); await bet(2, b02, 'no', 100)
  await jump(3420); b02 = await mk('B02')
  t('+57:00 B02 liquidata NO: paga 190', b02.outcome === 'no' && (await bal(2)) === 950 - 100 + 190 && (await bal(1)) === 1075 - 100)

  // --- B07 foratura (apre +60:00, chiude +79:45, SÌ a +80:00) con recupero dopo un'interruzione del server
  await jump(3599); t('+59:59 B07 non aperta', (await mk('B07')) === undefined)
  await jump(3601); let b07 = await mk('B07')
  t('+60:01 B07 aperta a 3,50/2,20', b07.status === 'open' && b07.yes_odds === 350 && b07.no_odds === 220)
  await bet(2, b07, 'no', 100); await bet(3, b07, 'yes', 40)
  await jump(4784); t('+79:44 puntata ancora ammessa', (await bet(4, b07, 'yes', 10)).replay === false)
  await jump(4786); t('+79:46 B07 chiusa', (await mk('B07')).status === 'closed' && await fails('mb_place_bet', [tok[5], b07.id, 'yes', 10], 'market_closed'))
  await jump(6200, false)    // il server «dorme» fino a +103:20: un solo passo deve recuperare tutto, in ordine
  await rpc('mb_race_tick')
  const ids = await feedIds()
  const expected = payload.events.filter((e) => e.at_seconds <= 6200).map((e) => e.id)
  t('recupero: tutte le notizie maturate sono uscite, nell\'ordine giusto, senza buchi né doppioni', JSON.stringify(ids) === JSON.stringify(expected), `${ids.length}/${expected.length}`)
  b07 = await mk('B07')
  t('B07 liquidata SÌ (prima foratura PCS021)', b07.status === 'resolved' && b07.outcome === 'yes')
  t('pagamenti B07: 40×3,50=140, 10×3,50=35; perde il NO', (await bal(3)) === 1015 - 40 + 140 && (await bal(4)) === 1007 - 10 + 35 && (await bal(2)) === 1040 - 100)
  const b03 = await mk('B03'), b04 = await mk('B04')
  t('B03 e B04 aperte e chiuse nel recupero, liquidate a +103:00 (SÌ e NO)', b03.outcome === 'yes' && b04.outcome === 'no' && b03.status === 'resolved')
  t('la foratura Rabobank (+116:00) non fa una seconda liquidazione',
    (await one(`select count(*)::int n from mazzobet.markets where race_market_id='B07' and status='resolved'`)).n === 1)

  // --- B05 con una pausa
  await jump(6250); let b05 = await mk('B05')
  t('+104:10 B05 aperta', b05.status === 'open')
  const e0 = (await rpc('mb_race_state', [tok[1]])).elapsed
  await rpc('mb_admin_race_pause', [true])
  await new Promise((r) => setTimeout(r, 1300))
  const e1 = (await rpc('mb_race_state', [tok[1]])).elapsed
  t('in pausa il tempo di gara non avanza', Math.abs(e1 - e0) < 0.5, `${e0} → ${e1}`)
  t('in pausa non si punta', await fails('mb_place_bet', [tok[1], b05.id, 'yes', 10], 'race_paused'))
  t('doppia pausa rifiutata', await fails('mb_admin_race_pause', [true], 'race_not_running'))
  const closeBefore = new Date((await mk('B05')).scheduled_close_at).getTime()
  await rpc('mb_admin_race_pause', [false])
  const e2 = (await rpc('mb_race_state', [tok[1]])).elapsed
  t('alla ripresa il tempo riparte da dove era', Math.abs(e2 - e0) < 0.6, `${e0} → ${e2}`)
  t('alla ripresa il conto alla rovescia si sposta della pausa', new Date((await mk('B05')).scheduled_close_at).getTime() - closeBefore > 1000)
  t('dopo la ripresa si punta', (await bet(1, await mk('B05'), 'yes', 100)).replay === false)
  await bet(2, await mk('B05'), 'no', 60)
  await jump(6720); b05 = await mk('B05')
  t('+112:00 B05 liquidata SÌ', b05.outcome === 'yes' && (await bal(2)) === 940 - 60)

  // --- B06 fotofinish
  await jump(6780); let b06 = await mk('B06')
  t('+113:00 B06 aperta a 2,10/1,75', b06.status === 'open' && b06.yes_odds === 210 && b06.no_odds === 175)
  const bal1 = await bal(1); const bal2 = await bal(2)
  await bet(1, b06, 'yes', 200); await bet(2, b06, 'no', 100)
  await jump(8489); t('+141:29 puntata ancora ammessa', (await bet(3, b06, 'yes', 10)).replay === false)
  await jump(8491); t('+141:31 chiusa', await fails('mb_place_bet', [tok[4], b06.id, 'yes', 10], 'market_closed'))
  await jump(8520); b06 = await mk('B06')
  t('+142:00 fotofinish: B06 in attesa di conferma, nessun esito, nessun pagamento',
    b06.status === 'closed' && b06.race_awaiting === true && b06.outcome === null && (await bal(1)) === bal1 - 200)
  const stAw = await rpc('mb_race_state', [tok[1]])
  const mAw = stAw.markets.find((m) => m.raceId === 'B06')
  t('ai telefoni B06 risulta «in attesa» senza esito', mAw.awaiting === true && mAw.outcome === null && !JSON.stringify(stAw).includes('confermata la vittoria'))
  await jump(9000); await jump(10259)
  t('+170:59 ancora in attesa', (await mk('B06')).status === 'closed' && !(await feedIds()).includes('PCS064'))
  await jump(10260); b06 = await mk('B06')
  t('+171:00 conferma ufficiale: B06 liquidata SÌ', b06.status === 'resolved' && b06.outcome === 'yes' && !b06.race_awaiting)
  t('pagamenti B06: 200×2,10=420; perde il NO', (await bal(1)) === bal1 - 200 + 420 && (await bal(2)) === bal2 - 100)

  // --- Finale B08–B10
  await jump(10559); t('+175:59 le finali non esistono ancora', (await mk('B08')) === undefined)
  await jump(10560)
  const [f8, f9, f10] = [await mk('B08'), await mk('B09'), await mk('B10')]
  t('+176:00 B08, B09, B10 si aprono insieme', f8?.status === 'open' && f9?.status === 'open' && f10?.status === 'open')
  t('quote finali 3,00/1,40 · 2,75/1,50 · 2,40/1,65', f8.yes_odds === 300 && f8.no_odds === 140 && f9.yes_odds === 275 && f10.no_odds === 165)
  const bal1f = await bal(1), bal2f = await bal(2), bal5f = await bal(5)
  await bet(1, f8, 'yes', 100); await bet(1, f9, 'yes', 100); await bet(2, f10, 'no', 100); await bet(5, f8, 'no', 50)
  await jump(10739); t('+178:59 si può ancora puntare', (await bet(3, f9, 'no', 10)).replay === false)
  await jump(10741); t('+179:01 finali chiuse', await fails('mb_place_bet', [tok[4], f10.id, 'yes', 10], 'market_closed'))
  await jump(10799); t('+179:59 nessun esito', (await mk('B08')).outcome === null)
  await jump(10800)
  const fin = [await mk('B08'), await mk('B09'), await mk('B10')]
  t('+180:00 vittoria pubblicata e B08=SÌ, B09=NO, B10=NO', (await feedIds()).includes('PCS073') && fin.map((m) => m.outcome).join() === 'yes,no,no')
  t('pagamenti finali: team1 SÌ B08 → +300, perde B09; team2 NO B10 → 165; team5 NO B08 perde',
    (await bal(1)) === bal1f - 200 + 300 && (await bal(2)) === bal2f - 100 + 165 && (await bal(5)) === bal5f - 50)
  const run = await one(`select status from mazzobet.race_runs where session_id = ${ACT}`)
  t('corsa finita', run.status === 'finished')
  const all = await feedIds()
  t('tutte le 73 notizie pubblicate una sola volta', all.length === 73 && new Set(all).size === 73)
  const sumLedger = await one(`select coalesce(sum(amount),0)::int s from mazzobet.ledger_entries where session_id = ${ACT}`)
  t('il registro dei Carletti somma a zero', sumLedger.s === 0)
  t('nessuna scommessa della corsa resta aperta o chiusa', (await one(`select count(*)::int n from mazzobet.markets where race_market_id is not null and status in ('open','closed')`)).n === 0)
  const wins = (await one(`select count(*)::int n from mazzobet.ledger_transactions where kind='win'`)).n
  await rpc('mb_race_tick'); await rpc('mb_tick')
  t('a corsa finita nessun passo cambia niente', (await one(`select count(*)::int n from mazzobet.ledger_transactions where kind='win'`)).n === wins)
  const reg = await rpc('mb_admin_race_state')
  t('la Regia vede le 10 scommesse liquidate', reg.markets.length === 10 && reg.markets.every((m) => m.status === 'resolved') && reg.status === 'finished')
}

// ---------------------------------------------------------------------------------------------------------------
console.log('# B07: nessuna foratura valida → NO alla prima notizia oltre il km 107')
{
  const { q, rpc, jump, mk, bet, bal } = await fresh()
  await rpc('mb_race_load', [JSON.stringify(payload)])
  await rpc('mb_admin_race_start')
  await jump(3601)
  await q(`update mazzobet.race_events set is_puncture = false`)
  const b07 = await mk('B07')
  await bet(1, b07, 'yes', 100); await bet(2, b07, 'no', 100)
  await jump(8219)
  t('+136:59 B07 ancora senza esito', (await mk('B07')).status === 'closed')
  await jump(8221)
  const r = await mk('B07')
  t('+137:00 (PCS050, km 107,1) B07 liquidata NO', r.status === 'resolved' && r.outcome === 'no' && (await bal(2)) === 1000 - 100 + 220 && (await bal(1)) === 900)
}

// ---------------------------------------------------------------------------------------------------------------
console.log('# Chiusura serata e Reset totale con la corsa in corso')
{
  const { q, one, rpc, tok, jump, bal, mk, bet } = await fresh()
  await rpc('mb_race_load', [JSON.stringify(payload)])
  await rpc('mb_admin_race_start')
  await jump(100)
  await bet(1, await mk('B01'), 'yes', 300)
  t('puntata registrata', (await bal(1)) === 700)
  await rpc('mb_admin_close_session')
  await rpc('mb_tick')
  await rpc('mb_tick')
  t('chiusura serata: corsa interrotta, puntata rimborsata, serata chiusa',
    (await one(`select status from mazzobet.race_runs`)).status === 'aborted' && Number((await one(`select balance from mazzobet.session_teams where team_id = 1`)).balance) === 1000)
  t('serata chiusa', (await one(`select status from mazzobet.game_sessions order by created_at desc limit 1`)).status === 'closed')

  // Reset totale a corsa in corso
  await rpc('mb_admin_reset_all', ['RESET', false])
  const t2 = {}
  for (let i = 1; i <= 3; i++) t2[i] = (await rpc('mb_enter_team', [i, null, 'ua'])).token
  await rpc('mb_admin_race_start')
  await jump(200)
  const m = await mk('B01')
  await rpc('mb_place_bet', [t2[1], m.id, 'no', 250])
  const oldSession = (await one(`select id from mazzobet.game_sessions where status='active'`)).id
  await rpc('mb_admin_reset_all', ['RESET', false])
  const oldBal = await one(`select balance from mazzobet.session_teams where session_id = $1 and team_id = 1`, [oldSession])
  t('Reset totale: puntata della corsa rimborsata', Number(oldBal.balance) === 1000)
  t('Reset totale: nuova serata con corsa da avviare', (await rpc('mb_admin_race_state')).status === 'not_started')
  const st = await rpc('mb_admin_race_state')
  t('nuova serata senza scommesse della corsa', st.markets.length === 0)
}

console.log(`\n${ko === 0 ? 'TUTTO OK' : 'CI SONO ERRORI'}: ${ok} controlli passati, ${ko} falliti`)
process.exit(ko === 0 ? 0 : 1)
