# Audio Trimming - Acceptance Criteria

## Waveform Display
- On page load, the entire audio file is visible (no scrollbar, no overflow)
- Zoom slider starts at 0% and corresponds to "fit entire file in view"
- Waveform is rendered from precomputed peaks JSON (files are 3-4 hours, no browser decoding)

## Zoom
- Slider at 0% = entire file visible, no scrollbar
- Slider at 100% = maximum zoom (capped so browser doesn't choke)
- Zooming never destroys or removes the region

## Region (the trim selection)
- A single region represents the audio to keep
- Region has draggable handles on left and right edges to resize
- Region body is draggable to reposition without changing its width
- Region start/end are synced to the server on every drag end

## Click behavior
- Clicking the waveform seeks the playhead to that position (default WaveSurfer behavior)
- Clicking never changes the scroll position or viewport

## Playback
- Play/pause button and spacebar toggle playback
- If playhead is outside the region when play is pressed, seek to region start first
- Playback pauses when it reaches the region end
- Current time display updates during playback

## Preview buttons
- "Preview Start" seeks to the region start and plays until the user pauses or it reaches the end of the region. **It does not stop on its own.**
- "Preview End" seeks to a few seconds before the region end and plays until it reches the end of the region, then pauses

## Time labels
- Start time, end time, and "keeping X of Y" labels update live during region drag
- Labels show HH:MM:SS format

## Confirm Trim
- Button sends trim start/end to the server
- Server trims all FLAC files and merged audio with ffmpeg
- On success, session status transitions to "trimmed"
- On failure, error flash, status stays "uploaded", trimmed files cleaned up

## Non-requirements
- No scroll position manipulation except during zoom

## Style
- The code should be simple and functional. It should not be imperative, complicated and brittle
- When making changes or fixing bugs, take a wide, holistic view of the entire functionality

## Implementation notes (lessons learned)

### audiowaveform peaks format
- `audiowaveform` outputs JSON: `{version, channels, sample_rate, samples_per_pixel, bits, length, data}`
- `data` is interleaved min/max pairs: `[min0, max0, min1, max1, ...]` — so `data.length = length * 2`
- Values are 8-bit signed integers (-128 to 127) when generated with `-b 8`
- To convert for WaveSurfer: normalize all values to [-1, 1] by dividing by `(1 << (bits - 1))` (128 for 8-bit), pass entire interleaved array as a single channel `peaks: [normalizedArray]`
- Duration from peaks metadata: `(length * samples_per_pixel) / sample_rate` — this is sample-accurate from the WAV

### WaveSurfer v7 — follow the docs examples
- The library is simple. Use it simply. Do NOT override internal behaviors with custom click handlers, manual scroll management, or wrapper event listeners
- **Creation pattern**: `const regions = RegionsPlugin.create()` then pass `plugins: [regions]` in WaveSurfer.create options
- **Pre-decoded peaks**: pass `url` (for playback streaming), `peaks` (for rendering), and `duration`. WaveSurfer skips blob fetching when peaks are provided and sets `media.src = url` for streaming playback
- **Add regions on `decode` event**: `ws.on("decode", () => { regions.addRegion({...}) })`
- **Zoom**: just call `ws.zoom(minPxPerSec)`. WaveSurfer handles scroll position internally. Do NOT manually calculate scroll centering

### WaveSurfer `interact` option
- `interact: true` (default) makes WaveSurfer auto-seek on click and emit `interaction(newTime)` and `click(relativeX)` events
- `interact: true` does NOT conflict with regions — region drag/resize uses pointer events with its own threshold-based drag detection, which calls `stopPropagation` on the click if a drag occurred, preventing auto-seek
- `interact: false` disables ALL click/interaction events from WaveSurfer — the `click` and `interaction` events will never fire. Do NOT use this and then try to add manual wrapper click listeners
- Leave `interact: true` (the default) and use the `interaction` event for custom click behavior

### Click handling with regions
- With `interact: true`, clicking the waveform auto-seeks AND emits `interaction(newTime)` where newTime is in seconds
- Region elements have `pointerEvents: "all"` — clicks on them bubble up to the wrapper, so `interaction` fires for ALL clicks (inside and outside regions)
- For inside-region clicks: `newTime` falls between `region.start` and `region.end`, so boundary-adjustment logic naturally skips. Auto-seek moves playhead to click position (desired behavior)
- For outside-region clicks: adjust the nearest region boundary in the `interaction` handler
- `regions.on("region-clicked", (region, e) => { e.stopPropagation() })` prevents the `interaction` event from firing for region clicks — use this ONLY if you want different behavior for region clicks vs waveform clicks
- Do NOT add manual click listeners on the wrapper element. Do NOT use `ws.on("click")` for coordinate math — use `ws.on("interaction")` which gives time in seconds directly

### Region events
- `regions.on("region-update", (region) => ...)` — fires continuously during drag/resize (for live label updates)
- `regions.on("region-updated", (region) => ...)` — fires once when drag/resize ends (for syncing to server)
- `region.setOptions({start, end})` — programmatic update, does NOT emit update/update-end events

### Zoom fit calculation
- The container has `p-2` (8px padding each side). `container.clientWidth` includes padding, so subtract 16px for fit zoom
- Max zoom should be capped so total waveform width stays reasonable

### Things to avoid
- Do NOT set `interact: false` — it breaks all WaveSurfer click/interaction events
- Do NOT add manual click listeners on `ws.getWrapper()` or shadow DOM elements
- Do NOT create manual Audio elements — just pass `url` and let WaveSurfer handle it
- Do NOT use `ws.registerPlugin()` — pass plugins in the constructor options
- Do NOT manually manage scroll position on zoom — WaveSurfer handles this
- Do NOT calculate click positions from `relativeX * duration` manually — use the `interaction` event which gives time directly
- Do NOT clamp/reposition the playhead on region update events
- Do NOT seek on decode/ready events trying to position the playhead
- Keep the hook flat and simple: fetch peaks, create WaveSurfer, wire up events, done

## Examples from the wavesurfer docs

Here are the most relevant examples distilled for this use case:

**Pre-decoded peaks + URL for playback:**
```js
const wavesurfer = WaveSurfer.create({
  container: document.body,
  url: '/examples/audio/demo.wav',
  peaks: [
    [0, 0.0023, 0.012, -0.313, 0.151, 0.247, ...],
  ],
  duration: 22,
})
```

**Regions plugin — creation, events, click handling:**
```js
const regions = RegionsPlugin.create()

const ws = WaveSurfer.create({
  container: '#waveform',
  url: '/examples/audio/audio.wav',
  plugins: [regions],
})

ws.on('decode', () => {
  regions.addRegion({
    start: 0,
    end: 8,
    content: 'Resize me',
    color: randomColor(),
    drag: false,
    resize: true,
  })
})

regions.on('region-updated', (region) => {
  console.log('Updated region', region)
})

regions.on('region-clicked', (region, e) => {
  e.stopPropagation() // prevent triggering a click on the waveform
  activeRegion = region
  region.play(true)
})

// Reset the active region when the user clicks anywhere in the waveform
ws.on('interaction', () => {
  activeRegion = null
})
```

**Zoom — just call ws.zoom():**
```js
ws.once('decode', () => {
  document.querySelector('input[type="range"]').oninput = (e) => {
    const minPxPerSec = Number(e.target.value)
    ws.zoom(minPxPerSec)
  }
})
```

**Play/pause:**
```js
document.querySelector('button').addEventListener('click', () => {
  wavesurfer.playPause()
})
```
