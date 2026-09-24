// HTTP client for the agent: token handling, envelope unwrapping, timeouts.
import { translate } from '../i18n-core'

export const API_BASE = `http://${window.location.hostname}:9090`
export const AUTH_EXPIRED_EVENT = 'zte-auth-expired'

let _token: string | null = sessionStorage.getItem('zte_token')

export function setToken(t: string) {
  _token = t
  sessionStorage.setItem('zte_token', t)
}

export function clearToken() {
  _token = null
  sessionStorage.removeItem('zte_token')
}

export function hasToken() {
  return !!_token
}

export class ApiError extends Error {
  status?: number
  code?: string
  details?: string

  constructor(message: string, status?: number, code?: string, details?: string, vars?: Record<string, string | number>) {
    super()
    this.name = 'ApiError'
    this.status = status
    this.code = code
    this.details = details
    // Resolve at render time too, so an open error follows a language change.
    Object.defineProperty(this, 'message', { configurable: true, get: () => translate(message, vars) })
  }
}

const ERROR_MESSAGES: Record<string, string> = {
  TTL_SCHEMA_UPGRADE_REQUIRED: 'The TTL interface has changed. Reload this page to continue.',
  TTL_INVALID_CONFIGURATION: 'TTL values must be whole numbers from 1 to 255, or disabled.',
  TTL_MANAGER_UNAVAILABLE: 'The shared TTL manager is not installed on this modem.',
  TTL_MANAGER_INTEGRITY: 'The TTL manager version could not be verified. Reinstall it from the Mac app.',
  TTL_BUSY: 'Another modem operation is in progress. Try again when it finishes.',
  TTL_OTHER_TRANSACTION: 'Finish the pending modem operation before changing TTL.',
  TTL_TIMEOUT: 'The TTL operation timed out. Refresh its status before retrying.',
  TTL_INVALID_STATUS: 'The modem returned an invalid TTL status.',
  TTL_APPLY_UNCONFIRMED: 'The modem has not confirmed the requested TTL settings. Refresh its status.',
  TTL_MANAGER_FAILED: 'The TTL manager could not complete the operation. Refresh its status.',
  TTL_MANAGER_IO: 'The TTL manager could not be accessed on the modem.',
  TTL_UNSUPPORTED_PROFILE: 'This modem firmware is not supported by the TTL manager.',
}

function responseError(json: { error?: string; code?: string; manager_code?: string }, status: number): ApiError {
  const known = json.code ? ERROR_MESSAGES[json.code] : undefined
  const exact: Record<string, string> = {
    'invalid credentials': 'Incorrect password or PIN.',
    unauthorized: 'Your session has expired. Sign in again.',
    'PIN login is only available from mobile devices': 'PIN sign-in is only available on mobile devices.',
    'no password configured. Set ZTE_AGENT_PASSWORD environment variable.': 'No agent password is configured. Set one during modem setup.',
  }
  const fallback = status === 429 ? 'Too many sign-in attempts. Wait a moment and try again.'
    : status === 403 ? 'This action is not allowed.'
    : status === 503 ? 'This function is currently unavailable on the modem.'
    : 'The modem could not complete the request.'
  const details = [json.code, json.manager_code, json.error].filter(v => typeof v === 'string').join('\n').slice(0, 2048)
  return new ApiError(known ?? exact[json.error ?? ''] ?? fallback, status, json.code, details || undefined)
}

function emitAuthExpired() {
  clearToken()
  window.dispatchEvent(new Event(AUTH_EXPIRED_EVENT))
}

export async function req(
  method: string,
  path: string,
  body?: unknown,
  extraHeaders?: Record<string, string>,
  timeoutMs = 15_000,
  base = API_BASE,
  sendToken = true,
): Promise<Record<string, unknown>> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)
  const headers: Record<string, string> = { ...(extraHeaders ?? {}) }
  if (_token && sendToken) headers['Authorization'] = `Bearer ${_token}`
  if (body !== undefined) headers['Content-Type'] = 'application/json'
  try {
    let res: Response
    try {
      res = await fetch(`${base}${path}`, {
        method,
        headers,
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      })
    } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') {
        throw new ApiError('Timed out reaching the agent')
      }
      throw new ApiError('Failed to reach the agent at {address}', undefined, undefined, undefined, { address: base })
    }

    let json: { ok?: boolean; data?: unknown; error?: string; code?: string; manager_code?: string }
    try {
      json = await res.json()
      if (!json || typeof json !== 'object' || Array.isArray(json)) throw new Error('Invalid envelope')
    } catch {
      throw new ApiError('Invalid response from agent ({status})', res.status, undefined, undefined, { status: res.status })
    }

    if (res.status === 401 && sendToken && base === API_BASE && path !== '/api/auth/login') {
      emitAuthExpired()
    }
    if (!res.ok || !json.ok) {
      throw responseError(json, res.status)
    }
    return (json.data ?? {}) as Record<string, unknown>
  } finally {
    clearTimeout(timeout)
  }
}

export const get = (path: string) => req('GET', path)
export const post = (path: string, body?: unknown, extraHeaders?: Record<string, string>) =>
  req('POST', path, body, extraHeaders)
export const put = (path: string, body: unknown) => req('PUT', path, body)

export async function login(
  credentials: string | { password?: string; pin?: string },
): Promise<{ token: string }> {
  const body = typeof credentials === 'string' ? { password: credentials } : credentials
  const data = await req('POST', '/api/auth/login', body)
  return { token: data.token as string }
}

// Only the private IPv4 address explicitly submitted by the user may receive
// a single-use confirmation token during a LAN transition. Never transfer the
// general session token: the proposed address could already belong to another host.
export async function confirmLan(ip: string, confirmationToken: string) {
  const octets = ip.split('.').map(Number)
  if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(ip) || octets.some(n => n > 255) ||
      !(octets[0] === 10 || (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] === 192 && octets[1] === 168))) {
    throw new ApiError('Invalid LAN reconnect address')
  }
  return req('POST', '/api/router/lan/confirm', { token: confirmationToken }, undefined, 3000, `http://${ip}:9090`, false)
}

export async function readCsv(path: string): Promise<{ csv: string }> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 30_000)
  try {
    const response = await fetch(`${API_BASE}${path}`, {
      headers: _token ? { Authorization: `Bearer ${_token}` } : {}, signal: controller.signal,
    })
    if (response.status === 401) emitAuthExpired()
    if (!response.ok) throw new ApiError('CSV download failed ({status})', response.status, undefined, undefined, { status: response.status })
    // Older agents and the emulator return a JSON envelope.
    if (response.headers.get('content-type')?.includes('application/json')) {
      const body = await response.json()
      if (!body.ok || typeof body.data?.csv !== 'string') throw new ApiError('Invalid CSV response')
      return { csv: body.data.csv }
    }
    return { csv: await response.text() }
  } finally { clearTimeout(timeout) }
}
