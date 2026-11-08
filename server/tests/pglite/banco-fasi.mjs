// Migration 027: fasi del Banco (tranquillo → imbizzarrito → serata), notte, sponsor solo dalla serata.
// Uso (dalla radice del progetto):  node server/tests/pglite/banco-fasi.mjs
import { boot } from './load.mjs'
const db = await boot(99)
let ok = 0, ko = 0
const t = (name, cond, extra = '') => { if (cond) { ok++; console.log('  ok  ', name) } else { ko++; console.log('  FAIL', name, extra) } }
const q = async (sql, p) => (await db.query(sql, p)).rows
const one = async (sql, p) => (await q(sql, p))[0]
const rpc = async (fn, args = []) => { const ph = args.map((_, i) => '$' + (i + 1)).join(','); return (await one(`select public.${fn}(${ph}) as r`, args)).r }
const tick = () => rpc('mb_tick')
const sess = () => one(`select bank_next_at, sponsor_next_at, bank_phase from mazzobet.game_sessions where status='active'`)
const minsFromNow = (ts) => (Date.parse(ts) - Date.now()) / 60_000
// orari delle fasi relativi ad adesso (il test non può spostare l'orologio)
const setPhase = (name, offsetMin) => q(`update mazzobet.bank_phases set starts_at = now() + ($2 || ' minutes')::interval where name = $1`, [name, String(offsetMin)])
const setSerata = (offsetMin) => q(`update mazzobet.config set value = extract(epoch from now() + ($1 || ' minutes')::interval) where key = 'banco_inizio'`, [String(offsetMin)])

await q(`select mazzobet.admin_new_session('Test')`)
for (let i = 1; i <= 6; i++) await rpc('mb_enter_team', [i, null, 'ua'])
await q(`update mazzobet.bank_phases set quiet_night = false`)   // la notte la provo a parte

console.log('# prima della prima fase')
await setPhase('tranquillo', 60); await setPhase('imbizzarrito', 120); await setPhase('serata', 180); await setSerata(180)
await tick()
let s = await sess()
t('niente Banco né sponsor prima della fase tranquilla', s.bank_next_at === null && s.sponsor_next_at === null)

console.log('# fase tranquilla')
await setPhase('tranquillo', -1); await tick(); s = await sess()
const m1 = minsFromNow(s.bank_next_at)
t('Banco armato fra 60 e 120 minuti', m1 >= 59 && m1 <= 121, m1)
t('sponsor ancora fermo', s.sponsor_next_at === null)
t('notizia «si sveglia» una volta', (await one(`select count(*)::int n from mazzobet.news where title = 'IL BANCO SI SVEGLIA'`)).n === 1)
await tick()
t('niente doppioni della notizia e nessun riarmo a vuoto',
  (await one(`select count(*)::int n from mazzobet.news where title = 'IL BANCO SI SVEGLIA'`)).n === 1 && +(await sess()).bank_next_at === +s.bank_next_at)
await q(`update mazzobet.game_sessions set bank_next_at = now() - interval '1 second' where status='active'`)
await tick()
let ev = await one(`select amount, detail->>'fase' fase from mazzobet.bank_events order by id desc limit 1`)
t('intervento con importo 50–100', ev && Number(ev.amount) >= 50 && Number(ev.amount) <= 100 && ev.fase === 'tranquillo', JSON.stringify(ev))
const m1b = minsFromNow((await sess()).bank_next_at)
t('riarmato a 60–120 minuti', m1b >= 59 && m1b <= 121, m1b)

console.log('# si imbizzarrisce')
await setPhase('imbizzarrito', -1); await tick(); s = await sess()
const m2 = minsFromNow(s.bank_next_at)
t('cambio fase: riarmato subito a 20–40 minuti', m2 >= 19 && m2 <= 41, m2)
t('notizia «imbizzarrito»', (await one(`select count(*)::int n from mazzobet.news where title = 'IL BANCO SI È IMBIZZARRITO'`)).n === 1)
t('sponsor ancora fermo', s.sponsor_next_at === null)
await q(`update mazzobet.game_sessions set bank_next_at = now() - interval '1 second' where status='active'`)
await tick()
ev = await one(`select amount, detail->>'fase' fase from mazzobet.bank_events order by id desc limit 1`)
t('importo 100–250 da imbizzarrito', Number(ev.amount) >= 100 && Number(ev.amount) <= 250 && ev.fase === 'imbizzarrito', JSON.stringify(ev))

console.log('# serata (da banco_inizio)')
await setSerata(-1); await tick(); s = await sess()
const m3 = minsFromNow(s.bank_next_at)
t('serata: Banco a 8–14 minuti', m3 >= 7.9 && m3 <= 14.1, m3)
t('serata: sponsor armato', s.sponsor_next_at !== null)
t('notizia «a tutta»', (await one(`select count(*)::int n from mazzobet.news where title = 'BANCO A TUTTA'`)).n === 1)
t('fase in corso = serata anche se la riga «serata» è nel futuro',
  (await one(`select (mazzobet.bank_phase_now()).name n`)).n === 'serata')

console.log('# Avvia adesso dalla Regia porta subito alla serata')
await setSerata(300); await setPhase('serata', 300); await tick()
t('tornati a imbizzarrito, sponsor fermato', (await one(`select (mazzobet.bank_phase_now()).name n`)).n === 'imbizzarrito' && (await sess()).sponsor_next_at === null)
await rpc('mb_admin_bank_now'); await tick(); s = await sess()
t('dopo Avvia adesso: fase serata e sponsor armato', (await one(`select (mazzobet.bank_phase_now()).name n`)).n === 'serata' && s.sponsor_next_at !== null)

console.log('# di notte il Banco dorme')
await setSerata(5000); await setPhase('serata', 5000); await setPhase('imbizzarrito', 4000)
// intervallo calcolato per finire all'01:30 di Roma della prossima notte
const target = (await one(`select extract(epoch from ((date_trunc('day', now() at time zone 'Europe/Rome') + interval '1 day 1 hour 30 minutes') at time zone 'Europe/Rome') - now())::int s`)).s
await q(`update mazzobet.bank_phases set quiet_night = true, interval_min_sec = $1, interval_max_sec = $1 where name = 'tranquillo'`, [target])
const night = await one(`select extract(hour from (mazzobet.next_bank_at(id) at time zone 'Europe/Rome'))::int h,
                                extract(minute from (mazzobet.next_bank_at(id) at time zone 'Europe/Rome'))::int mi
                           from mazzobet.game_sessions where status='active'`)
t('intervento che cadrebbe all\'01:30 spostato tra le 09:00 e le 09:30', night.h === 9 && night.mi <= 30, JSON.stringify(night))
await q(`update mazzobet.bank_phases set quiet_night = false where name = 'tranquillo'`)
const day = await one(`select extract(hour from (mazzobet.next_bank_at(id) at time zone 'Europe/Rome'))::int h from mazzobet.game_sessions where status='active'`)
t('senza «fermo di notte» resta all\'01', day.h === 1, JSON.stringify(day))

console.log('# senza fasi: come prima della 027')
await q(`delete from mazzobet.bank_phases where true`)
await q(`update mazzobet.game_sessions set bank_next_at = null, sponsor_next_at = null, bank_phase = null where status='active'`)
await setSerata(60); await tick(); s = await sess()
t('senza fasi e prima di banco_inizio: tutto fermo', s.bank_next_at === null && s.sponsor_next_at === null)
await setSerata(-1); await tick(); s = await sess()
const m4 = minsFromNow(s.bank_next_at)
t('senza fasi dopo banco_inizio: Banco 8–14 e sponsor', m4 >= 7.9 && m4 <= 14.1 && s.sponsor_next_at !== null, m4)

console.log(`\n${ok} ok, ${ko} falliti`)
process.exit(ko ? 1 : 0)
