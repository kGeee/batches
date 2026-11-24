// Send one photo as a printed postcard: write a note, add a US address, see both sides, send.
// Both sides are drawn here as PDFs and put in your prints folder; the server hands them to Lob.
import { useEffect, useRef, useState } from 'react'
import { Sheet } from '../ui.jsx'
import * as api from '../api.js'
import { card, cleanAddress } from './format.js'
import { drawBack, drawFront, loadPhoto, postcardPDFs } from './print.js'
import './postcard.css'

const blank = { name: '', line1: '', line2: '', city: '', state: '', zip: '' }
const previewScale = 72

export default function PostcardSheet({ photo, me, onClose, onSent }) {
  const [message, setMessage] = useState('')
  const [to, setTo] = useState(blank)
  const [img, setImg] = useState(undefined)
  const [busy, setBusy] = useState(null)
  const [problem, setProblem] = useState('')
  const [result, setResult] = useState(null)
  const [fits, setFits] = useState(true)
  const frontRef = useRef(null)
  const backRef = useRef(null)
  const from = `From ${me.display_name || `@${me.handle}`}`
  const aspect = photo.pixel_width / photo.pixel_height

  useEffect(() => {
    let live = true
    loadPhoto(photo).then((loaded) => live && setImg(loaded ?? null))
    return () => { live = false }
  }, [photo.id])

  useEffect(() => {
    if (frontRef.current) drawFront(frontRef.current, img, aspect, previewScale * devicePixelRatio)
  }, [img, aspect])

  useEffect(() => {
    if (backRef.current) setFits(drawBack(backRef.current, { message: message || ' ', from }, previewScale * devicePixelRatio))
  }, [message, from])

  const field = (key, label, props = {}) => (
    <input aria-label={label} placeholder={label} value={to[key]} {...props}
           onChange={(e) => setTo((t) => ({ ...t, [key]: e.target.value }))} />
  )

  const send = async () => {
    const { address, problems } = cleanAddress(to)
    if (!message.trim()) return setProblem('Write a message for the back.')
    if (!fits) return setProblem('The message is too long to fit. Make it a little shorter.')
    if (problems.length) return setProblem(problems[0])
    if (!img) return setProblem('The photo didn\'t load, so it can\'t be printed. Try again in a moment.')
    setProblem('')
    try {
      setBusy('Making the print files')
      const { front, back } = await postcardPDFs({ photo, img, message: message.trim(), from })
      const id = crypto.randomUUID()
      const folder = `${me.id}/postcards/${id}`
      setBusy('Uploading')
      await api.uploadPrint(`${folder}/front.pdf`, front)
      await api.uploadPrint(`${folder}/back.pdf`, back)
      await api.requestPostcard({ id, photoID: photo.id, message: message.trim(), address, frontPath: `${folder}/front.pdf`, backPath: `${folder}/back.pdf` })
      setBusy('Sending')
      const answer = await api.sendPostcard(id)
      setResult(answer)
      if (answer.status === 'sent') onSent?.(answer)
    } catch (e) {
      setProblem(e.message || 'Something went wrong. Try again.')
    } finally {
      setBusy(null)
    }
  }

  if (result) return <Sheet title="Postcard" onClose={onClose}><Outcome result={result} onClose={onClose} /></Sheet>

  return (
    <Sheet title="Send as a postcard" onClose={() => !busy && onClose()} className="postcard-sheet">
      <p className="sheet-text">A 4 by 6 in postcard, printed and mailed first class anywhere in the US.</p>
      <div className="postcard-previews">
        <canvas ref={frontRef} className="postcard-preview" aria-label="Front of the postcard" />
        <canvas ref={backRef} className="postcard-preview" aria-label="Back of the postcard" />
      </div>
      <textarea placeholder="Your message" value={message} maxLength={card.messageMax} rows={4}
                onChange={(e) => setMessage(e.target.value)} />
      <p className={`meta postcard-count ${fits ? '' : 'over'}`}>
        {fits ? `${card.messageMax - message.length} left` : 'Too long to fit on the card'}
      </p>
      <div className="postcard-address">
        {field('name', 'Name', { autoComplete: 'name', maxLength: 40 })}
        {field('line1', 'Street address', { autoComplete: 'address-line1', maxLength: 64 })}
        {field('line2', 'Apartment, suite (optional)', { autoComplete: 'address-line2', maxLength: 64 })}
        <div className="postcard-city">
          {field('city', 'City', { autoComplete: 'address-level2' })}
          {field('state', 'State', { autoComplete: 'address-level1', maxLength: 2, className: 'state' })}
          {field('zip', 'ZIP', { autoComplete: 'postal-code', inputMode: 'numeric', maxLength: 10, className: 'zip' })}
        </div>
      </div>
      {problem && <p className="problem">{problem}</p>}
      <div className="actions">
        <button className="secondary" disabled={!!busy} onClick={onClose}>Cancel</button>
        <button className="primary" disabled={!!busy} onClick={send}>{busy ? `${busy}…` : 'Send postcard'}</button>
      </div>
    </Sheet>
  )
}

function Outcome({ result, onClose }) {
  const when = result.expectedDelivery && new Date(`${result.expectedDelivery}T12:00:00`).toLocaleDateString(undefined, { month: 'long', day: 'numeric' })
  let text
  if (result.status === 'sent' && result.lobEnv === 'test') {
    text = <>Lob made a proof of your card. This is a test setup, so nothing was printed or mailed.{' '}
      {result.proofUrl && <a href={result.proofUrl} target="_blank" rel="noreferrer">See the proof</a>}</>
  } else if (result.status === 'sent') {
    text = when ? `It's on its way, and should arrive by ${when}.` : 'It\'s on its way.'
  } else if (result.httpStatus === 402 || result.httpStatus === 503) {
    text = 'Your card is saved, but it can\'t be mailed yet. Postcards aren\'t open for sending.'
  } else {
    text = `It couldn't be sent. ${result.failure || result.error || ''}`.trim()
  }
  return (
    <>
      <p className="sheet-text">{text}</p>
      <div className="actions"><button className="primary" onClick={onClose}>Done</button></div>
    </>
  )
}
