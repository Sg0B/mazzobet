import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto'

export const PIN_FORMAT = /^\d{4}$/

/** Hash scrypt con sale casuale: il PIN non viene mai salvato né scritto nei log. */
export function hashPin(pin: string): { hash: string; salt: string } {
  const salt = randomBytes(16).toString('hex')
  return { hash: scryptSync(pin, salt, 32).toString('hex'), salt }
}

export function checkPin(pin: string, hash: string, salt: string): boolean {
  const a = scryptSync(pin, salt, 32)
  const b = Buffer.from(hash, 'hex')
  return a.length === b.length && timingSafeEqual(a, b)
}
