import webpush from 'web-push'

export interface PushSub { id: number; endpoint: string; p256dh: string; auth: string }
export interface PushItem {
  teamId: number
  kind: 'A' | 'B'
  n: number
  marketNo: number
  marketId: number
  fee?: number
  subs: PushSub[] | null
}

/** Testi dei due soli tipi di notifica. Mai l'esito, mai le quote. Il tag fa sostituire la notifica precedente invece di accumularla. */
export function payloadFor(it: PushItem) {
  if (it.kind === 'A') {
    return {
      title: 'Da esitare',
      body: it.n > 1 ? `Hai ${it.n} scommesse da esitare.` : `La scommessa n. ${it.marketNo} è scaduta. Esitala ora.`,
      tag: 'mazzobet-da-esitare',
      url: `/?m=${it.marketId}`,
    }
  }
  return {
    title: 'Scommessa senza esito',
    body: it.n > 1 ? `Ci sono ${it.n} scommesse da esitare.` : `Nessuno ha esitato la n. ${it.marketNo}. Esitala e prendi fino a ${it.fee ?? 0} Carletti.`,
    tag: 'mazzobet-senza-esito',
    url: `/?m=${it.marketId}`,
  }
}

export interface PushConfig { publicKey: string; privateKey: string; subject: string }

export function configurePush(c: PushConfig) {
  webpush.setVapidDetails(c.subject, c.publicKey, c.privateKey)
}

/** Invia a tutte le iscrizioni della squadra. Non lancia mai: ritorna chi è andato bene e chi è morto (404/410). */
export async function sendItem(it: PushItem, log: (o: object, m: string) => void) {
  const ok: number[] = []
  const dead: number[] = []
  const body = JSON.stringify(payloadFor(it))
  await Promise.all((it.subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, body, { TTL: 900, urgency: 'high' })
      ok.push(s.id)
    } catch (e) {
      const status = (e as { statusCode?: number }).statusCode
      if (status === 404 || status === 410) dead.push(s.id)
      else log({ status, team: it.teamId }, 'push non inviato')
    }
  }))
  return { ok, dead }
}
