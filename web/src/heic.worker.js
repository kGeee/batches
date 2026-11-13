// Turns a HEIC shared copy into a JPEG for browsers that can't show HEIC (Chrome, Firefox).
// libheif runs here, off the main thread, and is only loaded the first time it's needed.
import factory from 'libheif-js/libheif-wasm/libheif-bundle.mjs'

let lib = null

self.onmessage = async ({ data: { id, bytes } }) => {
  try {
    lib ??= factory()
    const decoder = new lib.HeifDecoder()
    const images = decoder.decode(new Uint8Array(bytes))
    if (!images?.length) throw new Error('No image in HEIC')
    const image = images[0]
    const width = image.get_width(), height = image.get_height()
    const pixels = await new Promise((resolve, reject) => {
      image.display({ data: new Uint8ClampedArray(width * height * 4), width, height },
        (out) => (out ? resolve(out) : reject(new Error('HEIC decode failed'))))
    })
    for (const im of images) im.free?.()
    const canvas = new OffscreenCanvas(width, height)
    canvas.getContext('2d').putImageData(new ImageData(pixels.data, width, height), 0, 0)
    const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.9 })
    self.postMessage({ id, blob })
  } catch (error) {
    self.postMessage({ id, error: String(error?.message ?? error) })
  }
}
