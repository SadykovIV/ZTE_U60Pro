import jsQR from 'jsqr'
import { activation } from './model'

// Decode locally; the image is never uploaded or persisted.
export function decodePixels(pixels: Uint8ClampedArray, width: number, height: number): string {
  if (width < 1 || height < 1 || width * height > 16_000_000 || pixels.length !== width * height * 4) throw new Error('invalid_image')
  const data = new Uint8ClampedArray(pixels), found = new Set<string>()
  for (let count = 0; count < 8; count++) {
    const code = jsQR(data, width, height, { inversionAttempts: 'attemptBoth' })
    if (!code) break
    found.add(code.data)
    if (found.size > 1) throw new Error('multiple_qr')
    const points = [code.location.topLeftCorner, code.location.topRightCorner, code.location.bottomLeftCorner, code.location.bottomRightCorner]
    const left = Math.max(0, Math.floor(Math.min(...points.map(p => p.x))) - 3)
    const right = Math.min(width, Math.ceil(Math.max(...points.map(p => p.x))) + 3)
    const top = Math.max(0, Math.floor(Math.min(...points.map(p => p.y))) - 3)
    const bottom = Math.min(height, Math.ceil(Math.max(...points.map(p => p.y))) + 3)
    for (let y = top; y < bottom; y++) data.fill(255, (y * width + left) * 4, (y * width + right) * 4)
  }
  if (found.size !== 1) throw new Error('qr_missing')
  return activation([...found][0])
}
export async function decodeImage(file: File): Promise<string> {
  if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type) || file.size > 10 * 1024 * 1024) throw new Error('invalid_image')
  const url = URL.createObjectURL(file)
  try {
    const img = new Image()
    img.src = url
    await img.decode()
    if (img.naturalWidth * img.naturalHeight > 16_000_000) throw new Error('invalid_image')
    const canvas = document.createElement('canvas')
    canvas.width = img.naturalWidth; canvas.height = img.naturalHeight
    const ctx = canvas.getContext('2d', { willReadFrequently: true })
    if (!ctx) throw new Error('invalid_image')
    ctx.drawImage(img, 0, 0)
    const result = decodePixels(ctx.getImageData(0, 0, canvas.width, canvas.height).data, canvas.width, canvas.height)
    canvas.width = 0; canvas.height = 0
    return result
  } finally { URL.revokeObjectURL(url) }
}
