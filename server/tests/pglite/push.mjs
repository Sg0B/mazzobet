// Prova della migration 016 (notifiche push) su Postgres in memoria: chi viene avvisato, quando e una volta sola.
// Uso (dalla radice):  node server/tests/pglite/push.mjs
import { boot } from './load.mjs'
const db = await boot(16)
let fails = 0
const ok = (c, m) => { console.log(c ? '  ok  ' : '  KO  ', m); if (!c) fails++ }
const q = async (sql, p = []) => (await db.query(sql, p)).rows
const rpc = async (fn, args = []) => { const ph = args.map((_, i) => '$' + (i + 1)).join(','); return (await q(`select public.${fn}(${ph}) as r`, args))[0].r }
await q(`select mazzobet.admin_new_session('Test')`)
const tok = {}
for (let i = 1; i <= 7; i++) tok[i] = (await rpc('mb_enter_team', [i, null, 'ua'])).token
const due = () => rpc('mb_push_due', [120])
const tick = () => rpc('mb_tick')
const mk = async (team, key) => Number((await rpc('mb_create_market', [tok[team], 'Domanda di prova numero ' + key, 200, 200, new Date(Date.now() + 120000).toISOString(), 'key-' + key + '-abcdef'])).marketId)
const bet = (team, m, side = 'yes') => rpc('mb_place_bet', [tok[team], m, side, 100])
const expire = (m, secsAgo) => q(`update mazzobet.markets set scheduled_close_at = now() - make_interval(secs => $2) where id = $1`, [m, secsAgo])
const st = async (m) => (await q(`select status from mazzobet.markets where id = $1`, [m]))[0].status
const forTeam = (r, team, kind) => r.find((x) => x.teamId === team && x.kind === kind)
const fails_ = async (fn, args) => { try { await rpc(fn, args); return false } catch { return true } }

console.log('# senza iscrizioni')
const m1 = await mk(1, 'a'); await bet(2, m1); await expire(m1, 5); await tick()
ok((await st(m1)) === 'closed', 'scaduta con puntate = closed')
ok((await due()).length === 0 && (await q(`select count(*)::int n from mazzobet.push_log`))[0].n === 0, 'nessuna iscrizione: nessuna notifica e niente prenotato')

console.log('# iscrizioni')
for (let i = 1; i <= 7; i++) await rpc('mb_push_subscribe', [tok[i], `https://push.test/${i}`, 'p256', 'auth', 'ua'])
await rpc('mb_push_subscribe', [tok[3], 'https://push.test/3b', 'p256', 'auth', 'ua2'])
ok((await q(`select count(*)::int n from mazzobet.push_subscriptions where disabled_at is null`))[0].n === 8, '8 iscrizioni (la squadra 3 ha due telefoni)')
ok(await fails_('mb_push_subscribe', [tok[1], 'http://push.test/x', 'p', 'a', null]), 'endpoint non https rifiutato')
ok(await fails_('mb_push_subscribe', ['00000000-0000-0000-0000-000000000000', 'https://x.test/1', 'p', 'a', null]), 'token sconosciuto rifiutato')

console.log('# A al creatore')
let r = await due()
const a = forTeam(r, 1, 'A')
ok(r.length === 1 && a && a.n === 1 && a.marketNo === 1 && a.subs.length === 1, 'solo A, solo al creatore, n. 1')
ok(!forTeam(r, 2, 'A') && !r.some((x) => x.kind === 'B'), 'chi ha puntato non riceve; B non ancora (precedenza del creatore)')
ok((await due()).length === 0, 'seconda chiamata: nulla (una volta sola)')

console.log('# scommessa senza puntate')
const e1 = await mk(1, 'e'); await expire(e1, 5); await tick()
ok((await st(e1)) === 'empty' && (await due()).length === 0, 'chiusa senza puntate: nessuna notifica')

console.log('# B dopo la precedenza')
await expire(m1, 130); await tick()
r = await due()
const bs = r.filter((x) => x.kind === 'B').map((x) => x.teamId).sort()
ok(JSON.stringify(bs) === '[3,4,5,6,7]', 'B a 3,4,5,6,7: non al creatore (1), non a chi ha puntato (2) ' + JSON.stringify(bs))
const b3 = forTeam(r, 3, 'B')
ok(b3 && b3.subs.length === 2, 'la squadra 3 è avvisata su entrambi i telefoni')
const feeUi = (await rpc('mb_get_state', [tok[3]])).markets.find((m) => m.id === m1).feeOther
ok(b3.fee === feeUi && b3.fee > 0, `Y (${b3.fee}) coincide con il compenso mostrato dall'interfaccia (${feeUi})`)
ok((await due()).length === 0, 'B una volta sola')

console.log('# bancarotta e raggruppamento')
const m2 = await mk(1, 'b'); await bet(2, m2); await expire(m2, 130)
await q(`update mazzobet.session_teams set status = 'bankrupt', bankrupt_until = now() + interval '5 minutes' where team_id = 7`)
await tick(); r = await due()
ok(!r.some((x) => x.kind === 'B'), 'B nuova bloccata dal limite di 1 ogni 2 minuti')
await q(`update mazzobet.push_log set sent_at = now() - interval '3 minutes' where kind = 'B'`)
r = await due()
const b3g = forTeam(r, 3, 'B')
ok(b3g && b3g.n === 2, 'passato il limite: B raggruppata «n scommesse da esitare»')
ok(!forTeam(r, 7, 'B'), 'in bancarotta non riceve la B')
ok(!forTeam(r, 2, 'B') && !forTeam(r, 1, 'B'), 'chi ha puntato e il creatore non ricevono mai la B')
await q(`update mazzobet.session_teams set status = 'in_game', bankrupt_until = null where team_id = 7`)

console.log('# A raggruppata')
const m8 = await mk(1, 'x1'); const m9 = await mk(1, 'x2'); await bet(2, m8); await bet(2, m9)
await expire(m8, 5); await expire(m9, 5); await tick()
r = await due()
const ag = forTeam(r, 1, 'A')
ok(ag && ag.n === 4, 'A: 4 scommesse ancora da esitare (n. 1, n. 2 e due nuove scadute insieme) → una sola notifica raggruppata')
ok(r.filter((x) => x.kind === 'A').length === 1, 'una sola A per il creatore')

console.log('# esitata, Regia, finestra scaduta')
const m3 = await mk(4, 'c'); await bet(5, m3); await expire(m3, 5); await tick()
await due()
await rpc('mb_resolve', [tok[4], m3, 'yes'])
await expire(m3, 130); await tick()
await q(`update mazzobet.push_log set sent_at = now() - interval '9 minutes'`)
ok(!(await due()).some((x) => x.kind === 'B' && x.marketId === m3), 'esitata dal creatore: nessuna B su quella scommessa')
const m4 = await mk(4, 'd'); await bet(5, m4); await expire(m4, 130); await tick()
await q(`select public.mb_admin_resolve($1, 'no')`, [m4])
await q(`update mazzobet.push_log set sent_at = now() - interval '9 minutes'`)
ok(!(await due()).some((x) => x.marketId === m4), 'esitata dalla Regia: nessuna notifica')
const m5 = await mk(4, 'f'); await bet(5, m5); await expire(m5, 20000); await tick()
await q(`update mazzobet.push_log set sent_at = now() - interval '9 minutes'`)
ok((await st(m5)) === 'void' && !(await due()).some((x) => x.marketId === m5), 'oltre la finestra di esito: annullata e nessuna notifica')

console.log('# iscrizioni morte, disiscrizione, reset')
const sid = (await q(`select id from mazzobet.push_subscriptions where endpoint = 'https://push.test/6'`))[0].id
await rpc('mb_push_mark', [[], [sid]])
ok((await q(`select disabled_at from mazzobet.push_subscriptions where id = $1`, [sid]))[0].disabled_at !== null, '410/404: iscrizione disattivata')
const m7 = await mk(1, 'h'); await bet(2, m7); await expire(m7, 130); await tick()
await q(`delete from mazzobet.push_log where team_id = 6`)
ok(!forTeam(await due(), 6, 'B'), 'una squadra con solo iscrizioni disattivate non riceve')
await rpc('mb_push_unsubscribe', [tok[5], 'https://push.test/5'])
ok((await q(`select disabled_at from mazzobet.push_subscriptions where endpoint = 'https://push.test/5'`))[0].disabled_at !== null, 'disiscrizione dal telefono')
await rpc('mb_push_unsubscribe', [tok[4], 'https://push.test/3'])
ok((await q(`select disabled_at from mazzobet.push_subscriptions where endpoint = 'https://push.test/3'`))[0].disabled_at === null, "una squadra non può disiscrivere un'altra")
await rpc('mb_push_subscribe', [tok[5], 'https://push.test/5', 'p256', 'auth', 'ua'])
ok((await q(`select disabled_at from mazzobet.push_subscriptions where endpoint = 'https://push.test/5'`))[0].disabled_at === null, 'riattivando il telefono la disiscrizione cade')
await rpc('mb_admin_reset_team', [2])
ok((await q(`select count(*)::int n from mazzobet.push_subscriptions where team_id = 2`))[0].n === 0, 'Resetta squadra cancella le iscrizioni push')

console.log('# permessi')
const g = await q(`select has_function_privilege('anon','public.mb_push_due(int)','execute') a, has_function_privilege('service_role','public.mb_push_due(int)','execute') s,
                          has_table_privilege('anon','mazzobet.push_subscriptions','select') t`)
ok(!g[0].a && g[0].s && !g[0].t, 'solo il server chiama le funzioni e legge le iscrizioni')
console.log(fails ? `\n${fails} FALLITI` : '\ntutto ok')
process.exit(fails ? 1 : 0)
