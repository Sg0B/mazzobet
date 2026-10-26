import { api } from './api'

export type PushState = 'unsupported' | 'off-server' | 'blocked' | 'off' | 'on'

export const pushSupported = () =>
  typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window

const b64ToBytes = (b64: string) => {
  const pad = '='.repeat((4 - (b64.length % 4)) % 4)
  const raw = atob((b64 + pad).replace(/-/g, '+').replace(/_/g, '/'))
  return Uint8Array.from(raw, (c) => c.charCodeAt(0))
}

const registration = () => navigator.serviceWorker.register('/sw.js')

/** Registra il service worker (serve per ricevere e per il tocco sulla notifica). Mai un errore visibile. */
export function registerWorker() {
  if (!pushSupported()) return
  void registration().catch(() => { /* senza SW il gioco funziona uguale */ })
}

export async function pushState(): Promise<PushState> {
  if (!pushSupported()) return 'unsupported'
  try {
    const k = await api<{ enabled: boolean }>('/push/key')
    if (!k.enabled) return 'off-server'
    if (Notification.permission === 'denied') return 'blocked'
    const reg = await navigator.serviceWorker.getRegistration('/sw.js')
    const sub = await reg?.pushManager.getSubscription()
    return Notification.permission === 'granted' && sub ? 'on' : 'off'
  } catch {
    return 'unsupported'
  }
}

/** Da chiamare SOLO dopo un tocco dell'utente: è qui che il browser chiede il permesso. */
export async function enablePush(): Promise<PushState> {
  const k = await api<{ enabled: boolean; key?: string }>('/push/key')
  if (!k.enabled || !k.key) return 'off-server'
  const perm = await Notification.requestPermission()
  if (perm !== 'granted') return perm === 'denied' ? 'blocked' : 'off'
  const reg = await registration()
  await navigator.serviceWorker.ready
  const sub = (await reg.pushManager.getSubscription()) ?? (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(k.key) }))
  await api('/push/subscribe', { body: { subscription: sub.toJSON() } })
  return 'on'
}

export async function disablePush(): Promise<PushState> {
  const reg = await navigator.serviceWorker.getRegistration('/sw.js')
  const sub = await reg?.pushManager.getSubscription()
  if (sub) {
    await api('/push/unsubscribe', { body: { endpoint: sub.endpoint } }).catch(() => undefined)
    await sub.unsubscribe().catch(() => undefined)
  }
  return 'off'
}

/** Riallinea il server se il telefono ha già l'iscrizione (es. dopo un cambio di sessione). */
export async function resyncPush() {
  try {
    if (!pushSupported() || Notification.permission !== 'granted') return
    const reg = await navigator.serviceWorker.getRegistration('/sw.js')
    const sub = await reg?.pushManager.getSubscription()
    if (sub) await api('/push/subscribe', { body: { subscription: sub.toJSON() } })
  } catch { /* ignora */ }
}
