import { useEffect, useRef, useState } from 'react'
import { useI18n } from '../../i18n'
import { Button, Field, Input, Select } from '../../ui/controls'
import { Card, Chip } from '../../ui/primitives'
import { confirm } from '../../ui/feedback'
import { capabilities, runOperation } from './api'
import { activation, compose, mask, profileName, type EsimRequest, type Snapshot } from './model'
import { decodeImage } from './qr'
import { stageMessage } from './journal'
import { failureMessage, safeEsimErrors } from './errors'

export default function EsimPage() {
  const { t } = useI18n()
  const [ready, setReady] = useState(false), [busy, setBusy] = useState(false)
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null), [selected, setSelected] = useState('')
  const [mode, setMode] = useState('manual'), [address, setAddress] = useState(''), [matching, setMatching] = useState('')
  const [lpa, setLpa] = useState(''), [confirmation, setConfirmation] = useState(''), [message, setMessage] = useState('')
  const [failed, setFailed] = useState(false), [decoding, setDecoding] = useState(false)
  const [journal, setJournal] = useState<string[]>([])
  const lifetime = useRef<AbortController | null>(null), working = useRef(false), inputRevision = useRef(0)
  const profile = snapshot?.profiles.find(p => p.iccid === selected)
  let code = ''
  try { code = mode === 'manual' ? compose(address, matching) : activation(lpa) } catch { /* The form stays disabled until valid. */ }
  const confirmationValid = !confirmation || confirmation.length <= 512 && !confirmation.startsWith('-') && !Array.from(confirmation).some(c => c.charCodeAt(0) < 33 || c.charCodeAt(0) === 127 || /\s/.test(c))
  useEffect(() => {
    const controller = new AbortController(); lifetime.current = controller
    capabilities().then(value => {
      const operations = value.operations
      if (!controller.signal.aborted) {
        const supported = value.protocol === 1 && Array.isArray(operations) && ['list', 'download', 'enable', 'delete'].every(op => operations.includes(op))
        setReady(supported)
        if (!supported) { setFailed(true); setMessage('Install the eSIM agent and refresh this page.') }
      }
    }).catch(() => { if (!controller.signal.aborted) { setFailed(true); setMessage('Install the eSIM agent and refresh this page.') } })
    const leave = (e: BeforeUnloadEvent) => { if (working.current) { e.preventDefault(); e.returnValue = '' } }
    window.addEventListener('beforeunload', leave)
    return () => { controller.abort(); window.removeEventListener('beforeunload', leave) }
  }, [])
  function clearInputs() { inputRevision.current++; setAddress(''); setMatching(''); setLpa(''); setConfirmation('') }
  async function run(request: EsimRequest) {
    if (working.current || !ready || !lifetime.current || lifetime.current.signal.aborted) return
    working.current = true; setBusy(true); setFailed(false); clearInputs(); setSnapshot(null); setMessage('Reading the physical eUICC…')
    const started = Date.now()
    const append = (text: string) => setJournal(lines => [...lines, text].slice(-2000))
    append(`${new Date().toISOString()} · ${request.operation} · start`)
    try {
      const result = await runOperation(request, (stage, line) => { if (!lifetime.current?.signal.aborted) { setMessage(stageMessage(stage)); if (line) append(line) } }, lifetime.current.signal)
      if (lifetime.current.signal.aborted) return
      setSnapshot(result.snapshot)
      append(`${((Date.now()-started)/1000).toFixed(1)}s · ${request.operation} · verified${result.pending ? ' · notifications_pending' : ''}`)
      setSelected(result.snapshot.profiles.some(p => p.iccid === selected) ? selected : '')
      setMessage(result.pending ? 'Profiles verified. Operator notifications are pending; refresh before another operation.' : request.operation === 'list' ? 'Profiles read from the physical eUICC.' : request.operation === 'enable' ? 'The profile is active, the SIM was reread and normal radio mode was verified. Check mobile network registration separately.' : 'The profile change was verified on the card. Check mobile network registration separately.')
    } catch (error) {
      if (!lifetime.current?.signal.aborted) {
        const code = error instanceof Error && safeEsimErrors.has(error.message) ? error.message : ''
        append(`${((Date.now()-started)/1000).toFixed(1)}s · ${request.operation} · unconfirmed${code ? ` · error=${code}` : ''}`)
        setSnapshot(null); setSelected(''); setFailed(true)
        setMessage(failureMessage(code))
      }
    } finally { working.current = false; if (!lifetime.current?.signal.aborted) setBusy(false) }
  }
  async function mutate(operation: 'download' | 'enable' | 'delete') {
    if (!snapshot || busy || working.current || decoding) return
    const title = operation === 'download' ? t('Install eSIM profile?') : operation === 'enable' ? t(profile?.enabled ? 'Reread the active SIM?' : 'Make this profile active?') : t('Delete this profile?')
    const body = operation === 'download' ? t('The profile will be installed disabled. The modem needs internet access. The code may be single-use.') :
      `${profile ? profileName(profile) + ' · ' + mask(profile.iccid) : ''}\n${operation === 'delete' ? t('Deletion cannot be undone. The operator may require a new activation code.') : t('The modem will enter flight mode, reread the SIM and restore normal radio mode. Mobile connectivity will be interrupted.')}`
    const request: EsimRequest = { protocol: 1, operation, expected_snapshot: snapshot }
    if (operation === 'download') { if (!code || !confirmationValid) return; request.activation_code = code; if (confirmation) request.confirmation_code = confirmation }
    else { if (!profile || profile.state === 'unknown' || operation === 'delete' && profile.state !== 'disabled') return; request.iccid = profile.iccid; if (operation === 'delete') request.confirm_delete = true }
    const revision = inputRevision.current
    if (await confirm({ title, body, danger: operation === 'delete', confirmLabel: t('Confirm') })) {
      if (!lifetime.current?.signal.aborted && revision === inputRevision.current) await run(request)
    }
  }
  async function loadQR(file?: File) {
    if (!file || busy || decoding) return
    const revision = ++inputRevision.current
    setDecoding(true); setFailed(false)
    try {
      const text = await decodeImage(file)
      if (lifetime.current?.signal.aborted || inputRevision.current !== revision || working.current) return
      setLpa(text); setMessage('QR decoded locally. Review and confirm installation.'); setFailed(false)
    } catch { if (!lifetime.current?.signal.aborted && inputRevision.current === revision) { setLpa(''); setFailed(true); setMessage('Use a PNG, JPEG or WebP image with exactly one eSIM QR code, up to 10 MB.') } }
    finally { if (!lifetime.current?.signal.aborted) setDecoding(false) }
  }
  return <div className="space-y-4">
    <div><h1 className="text-xl font-semibold text-ink">{t('eSIM')}</h1><p className="mt-1 text-sm text-ink2">{t('Physical eUICC profile management')}</p></div>
    <Card title={t('Physical eUICC only')}>
      <p className="text-sm text-ink2">{t('Requires a removable eUICC in the physical SIM slot. Tested: 9eSIM V0 on MU5250 B31. Ordinary SIM cards and built-in ZTE eSIM are not supported.')}</p>
      <p className="mt-2 text-sm text-ink2">{t('Web downloads use the modem internet connection. If the card is empty and the modem is offline, use the macOS or Windows app with computer internet access.')}</p>
    </Card>
    <Card title={t('Profiles on the card')} action={<Button onClick={() => void run({ protocol: 1, operation: 'list' })} disabled={!ready || busy || decoding} loading={busy}>{t('Read profiles')}</Button>}>
      {snapshot && <p className="mb-3 text-xs text-ink3">{t('Card EID')}: {mask(snapshot.eid)}</p>}
      {!snapshot && <p className="text-sm text-ink3">{t('Read profiles to enable installation and profile selection.')}</p>}
      {snapshot?.profiles.length === 0 && <p className="text-sm text-ink3">{t('No profiles installed.')}</p>}
      <div className="space-y-2">{snapshot?.profiles.map(p => <button key={p.iccid} disabled={busy} onClick={() => setSelected(p.iccid)} aria-pressed={selected === p.iccid} className={`flex w-full items-center justify-between gap-3 rounded-lg border p-3 text-left ${selected === p.iccid ? 'border-accent bg-accent/10' : 'border-line/10 bg-surface2/50'}`}>
        <span className="min-w-0"><span className="block break-words text-sm font-semibold text-ink">{profileName(p)}</span><span className="mt-1 block break-words text-xs text-ink3">{p.service_provider} · {mask(p.iccid)}</span></span>
        <Chip tone={p.enabled ? 'ok' : 'default'}>{p.state === 'enabled' ? t('Active') : p.state === 'disabled' ? t('Disabled') : t('Unknown')}</Chip>
      </button>)}</div>
      <div className="mt-4 flex flex-wrap gap-2"><Button variant="primary" disabled={busy || !profile || profile.state === 'unknown'} onClick={() => void mutate('enable')}>{t(profile?.enabled ? 'Reread SIM' : 'Make active')}</Button><Button variant="danger" disabled={busy || !profile || profile.state !== 'disabled'} onClick={() => void mutate('delete')}>{t('Delete profile')}</Button></div>
      <p className="mt-2 text-xs text-ink3">{t('Only a disabled profile can be deleted.')}</p>
    </Card>
    <Card title={t('Add eSIM profile')}>
      <div className="space-y-3">
        <Field label={t('Input method')}><Select value={mode} disabled={busy || decoding} onChange={e => { clearInputs(); setMode(e.target.value) }}><option value="manual">{t('SM-DP+ and Activation code')}</option><option value="lpa">{t('LPA code or QR image')}</option></Select></Field>
        {mode === 'manual' ? <><Field label={t('SM-DP+ Address')}><Input autoComplete="off" spellCheck={false} value={address} disabled={busy} onChange={e => { inputRevision.current++; setAddress(e.target.value) }} placeholder={t('Example: rsp.example.com')} /></Field><Field label={t('Activation code (Matching ID)')}><Input type="password" autoComplete="new-password" value={matching} disabled={busy} onChange={e => { inputRevision.current++; setMatching(e.target.value) }} /></Field></> : <><Field label={t('Full LPA code')}><Input type="password" autoComplete="new-password" value={lpa} disabled={busy || decoding} onChange={e => { inputRevision.current++; setLpa(e.target.value) }} /></Field><Field label={t('Load QR image')}><input type="file" accept="image/png,image/jpeg,image/webp" disabled={busy || decoding} onChange={e => { const file = e.target.files?.[0]; e.target.value = ''; void loadQR(file) }} className="w-full text-sm text-ink2" /></Field></>}
        <Field label={t('Operator confirmation code (if required)')}><Input type="password" autoComplete="new-password" value={confirmation} disabled={busy} onChange={e => { inputRevision.current++; setConfirmation(e.target.value) }} /></Field>
        <p className="text-xs text-ink3">{t('New profiles are installed disabled. QR images and activation codes are not saved.')}</p>
        <Button variant="primary" disabled={!ready || !snapshot || busy || decoding || !code || !confirmationValid} onClick={() => void mutate('download')}>{t('Install profile')}</Button>
      </div>
    </Card>
    {message && <div role="status" className={`rounded-xl border p-3 text-sm ${failed ? 'border-danger/25 bg-danger/8 text-danger' : 'border-line/10 bg-surface text-ink2'}`}>{t(message)}</div>}
    <Card title={t('eSIM operation journal')}>
      <p className="mb-3 text-xs text-ink3">{t('Stages, waiting time, APDU counters and HTTPS status. Activation codes, profile contents and passwords are hidden. The journal is kept only while this page is open.')}</p>
      <pre className="max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-surface2 p-3 text-xs text-ink2" aria-label={t('eSIM operation journal')}>{journal.join('\n') || t('No eSIM operations in this session.')}</pre>
    </Card>
  </div>
}
