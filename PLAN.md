# Smooth Cursor — Build Plan

Native macOS screen recorder that turns raw captures into polished, ready-to-post videos:
auto zoom, smooth cursor, backgrounds, motion blur, 3D phone mockups.

Toolchain detected: Xcode 26.2 · Swift 6.2 · macOS 26.6 · Apple M1 · XcodeGen installed.

## Decisions (confirmed)

- **Distribution:** Direct / Developer ID, notarized, **no sandbox** → full cursor / click / keystroke telemetry.
- **Minimum OS:** **macOS 26 only** → latest SwiftUI, ScreenCaptureKit, `SpeechAnalyzer` captions available everywhere.
- **Phone model:** **Procedural**, generated in code (no licensing issues, fully tweakable).
- **Phone sources:** iOS Simulator window (auto-detect + crop to device screen), real iPhone over USB (CoreMediaIO), imported video files.

---

## Architecture (decided up front, because everything depends on it)

| Layer | Technology | Why |
|---|---|---|
| UI | SwiftUI + AppKit where needed (timeline, canvas, HUD panels) | Native feel; AppKit for the hot, custom-drawn views |
| Capture | **ScreenCaptureKit** (`SCStream`, `SCContentSharingPicker`), system audio + mic in the same stream | Display / window / area / app capture, hardware-backed, low overhead |
| Raw encode | `AVAssetWriter` → HEVC (or ProRes 422 for "lossless-ish") via VideoToolbox | Hardware encoder, tiny CPU cost while recording |
| Cursor & input | Cursor hidden in capture; separate **120 Hz telemetry track** (position, clicks, scrolls, keys, cursor sprite + hotspot via `NSCursor.currentSystem`) | Lets us re-render the cursor smoothly at any size/sprite, and drives auto-zoom |
| Project | `.smoothcursor` **package** (folder): `recording.mov`, `mic.m4a`, `telemetry.bin`, `project.json`, thumbnails | Autosave = cheap JSON diff writes; media never rewritten |
| Render core | **One Metal render graph** shared by preview and export: decode (`AVPlayerItemVideoOutput` / `AVAssetReader`) → `CVMetalTextureCache` (zero-copy) → compositor passes | Preview == export pixel-for-pixel; GPU only, no CPU copies |
| 3D mockup | Custom **Metal PBR renderer** (glTF/procedural phone, IBL environment maps, soft shadow) in the same graph | SceneKit is soft-deprecated; RealityKit is hard to drive offline frame-exact. Our own pass keeps it fast & deterministic |
| Export | `AVAssetWriter` + VideoToolbox (H.264 / HEVC / HEVC-alpha / ProRes), GIF via ImageIO | Faster-than-realtime hardware export |

Compositor passes per frame: background → (3D mockup *or* 2D window: crop → zoom/pan transform → rounded corners → shadow) → cursor → click effects / overlays → motion blur (velocity-based, sub-frame transform sampling) → output.

---

## Steps (with suggested model reasoning effort)

Effort = what to set before starting that step. `max` only where the math/graphics is genuinely hard.

| # | Step | Scope | Effort |
|---|---|---|---|
| 0 | **Scaffold & architecture** | XcodeGen project, modules (`Capture`, `Project`, `Render`, `Timeline`, `Export`, `UI`), document model types, permissions plumbing (Screen Recording, Mic, Accessibility), app shell with Home / Editor windows | **medium** |
| 1 | **Recording engine** | Source picker (display / window / area selection overlay / app), mic + system audio toggles & device pick, quality (resolution scale, fps 30/60/120, codec, bitrate), countdown, menu-bar HUD (pause/resume/stop/restart), hotkeys, cursor + input telemetry, exclude own app windows | **high** |
| 2 | **Projects & persistence** | Package format, autosave (debounced), recents library grid with thumbnails, reopen, duplicate/rename/delete, crash-safe recording recovery, undo/redo | **medium** |
| 3 | **Metal render core + preview player** | Frame-accurate decode, A/V sync, scrubbing, canvas: crop, padding, corner radius, shadow, inset, output aspect ratios (16:9, 9:16, 1:1, 4:5, custom). Same graph headless for export | **xhigh** |
| 4 | **Cursor system** | Smoothing (critically-damped spring w/ tension/friction/mass), size, show/hide, auto-hide when idle, macOS sprites captured at record time, custom sprite packs (import PNG + hotspot), click effects (ripple / pulse / press-scale), optional click sound | **high** |
| 5a | **Auto-zoom engine** | Heuristics from clicks, typing bursts, dwell, scroll; merge/split rules; per-segment properties: zoom level, follow-cursor (with dead-zone), easing curve, in/out duration, manual focus point | **xhigh** |
| 5b | **Timeline & inspector UX** | Tracks: Video, Zoom, Cursor, Camera(3D), Audio; drag/resize/split/trim, multi-select batch edit, snapping, waveform, playhead, zoom-to-fit, keyboard shortcuts | **high** |
| 6 | **Backgrounds** | Solid, gradients (linear / radial / angular / mesh) with editable stops + angle, image/wallpaper, blurred-screenshot bg, noise/grain, presets | **medium** |
| 7 | **Motion blur** | Per-pixel velocity from transform deltas (zoom/pan/3D camera + cursor), N-tap directional blur, shutter angle control, quality tiers (preview fast / export full) | **high** |
| 8 | **Export** | Resolution presets (720p→4K, custom), fps, codec, quality, size estimate, export queue, background export, GIF, copy-to-clipboard, social presets | **high** |
| 9 | **3D phone mockup** | Phone model (bezel, dynamic island, screen as video texture), PBR + HDRI lighting (yaw/pitch/strength like your screenshot), contact shadow, camera presets (Front, Hero, Straight On, Orbit, Tilt…) dropped as clips on a Camera track with automatic eased transitions; phone colour/finish options | **max** |
| 10 | **Extras** (see below) | Each is independent | **medium–high** |
| 11 | **Performance & polish pass** | Instruments (Metal System Trace, Time Profiler), memory, cold start, edge cases, onboarding, icons | **high** |

Tip: steps 6 and 2 can run in parallel with others once step 3 exists.

---

## Extra features I'd add (step 10)

- **Webcam overlay** (circle/rounded, draggable, auto-shrinks during zooms) — high
- **Keystroke overlay** (shows ⌘⇧K etc. on screen, auto from telemetry) — medium
- **Auto captions** via on-device `SpeechAnalyzer` (macOS 26), styled, editable — high
- **Cut / speed segments**: trim, delete, speed-up idle parts automatically ("skip silence & idle") — high
- **Blur / redact regions** (track static rect) — medium
- **Text & arrow annotations** — medium
- **Audio polish**: voice isolation / noise removal, normalization, background music with ducking — medium
- **Style presets**: save a look (bg + padding + cursor + zoom defaults) and apply to new recordings — medium
- **Recording of iPhone over USB** (CoreMediaIO, like QuickTime) feeding straight into the phone mockup — high


---

## Progress

- [x] **Step 0 — Scaffold & architecture.** XcodeGen project (`project.yml`), `SmoothKit` package (`SCCore`, `SCCapture`, `SCProject`, `SCRender`, `SCExport`), document model + binary telemetry codec, `.smoothcursor` packages with autosave and undo, permissions, Home library + Editor shell (SwiftUI placeholder canvas, inspector, read-only timeline), video import.

- [x] **Step 1 — Recording engine.** `ScreenCaptureEngine` (display / window / area via ScreenCaptureKit, cursor hidden, system audio + mic as separate AAC tracks, HEVC / H.264 / ProRes, fps, resolution scale, quality→bitrate, 1 s keyframes, fragmented writes), `DeviceCaptureEngine` (iPhone over USB via CoreMediaIO), `RecordingClock` (pause/resume without gaps), `InputTelemetryRecorder` (120 Hz cursor, clicks, scrolls, keys, cursor sprites as PNG), source catalog with thumbnails, recorder window, drag-to-select area overlay (Shift = 16:9), countdown, floating HUD + menu bar item, global hotkeys ⌥⇧⌘R / ⌥⇧⌘P, recording → project → editor. Dev tool: `swift run sc-record`.

- [x] **Design system.** Dark-only custom UI in `App/Sources/DesignSystem`: tokens (`Palette`, `Radius`, `Typo`), buttons (primary / secondary / ghost / record / icon), segmented control, switch, slider (live value, double-click reset), dropdown with custom menu, text field, panels, badges, empty states, and a custom 52 pt title bar (`SCTitleBar` + `WindowChrome`: centered traffic lights, macOS 26 title bar glass and scroll pocket removed, clicks forwarded to content).
- [x] **Step 2 — Projects & persistence.** Library: search, sort, inline rename, duplicate, move to Trash, Show in Finder, Open… (any `.smoothcursor`), Open Recent, folder watching, lazy thumbnails, recovery of interrupted recordings. Documents: forward-compatible decoding (missing keys → defaults), save status in the editor, rename from the editor, undo/redo with coalesced slider drags, synchronous save on quit.

- [x] **Step 3 — Metal render core + preview player.** `FrameLayout` (resolution-independent layout: padding, aspect, crop, corner radius, shadow; zoom camera with fixed-point geometric interpolation, clamped to the recording), easing curves (cubic bezier solver, springs as normalized curves). `Compositor`: one render pass for background (color, linear/radial/angular/mesh gradients with dither, image + blur, grain), closed-form rounded-rect shadow, and the recording with SDF anti-aliased corners, trilinear mips when downscaling and bicubic when zoomed. `PreviewView` (CAMetalLayer + display link, idles at 0% CPU), `PlaybackController` (AVPlayer, frame-accurate chase seeking, scrub pause/resume), offline renderer + `swift run sc-render`. Editor: live preview, play/pause/frame step (Space, ←/→, ⇧←/→, Home/End), timeline scrubbing, crop editor with 8 handles and aspect lock.

- [x] **Step 4 — Cursor system.** `CursorTrack`: spring-smoothed path precomputed at 240 Hz (smoothing amount → frequency, spring preset → damping), lookahead so the cursor doesn't lag, exact landing on clicks, idle hide that fades back in before movement, press shrink, motion tilt, slow camera path for follow-zoom. Cursor packs: captured macOS sprites, built-in vector "White" and "Dot", custom PNG import with hotspot picker (replace arrow / pointer / text / all). Renderer: linear premultiplied mipmapped sprites, ripple/pulse click effects. Zoom segments set to "follow cursor" now track it. Cursor inspector. (Click sound: with export, step 8.)

- [x] **Step 5a — Auto-zoom engine.** `AutoZoom`: interests from clicks, typing bursts (focused on the clicked field), shortcuts and cursor rests (high sensitivity); merged by time, filtered by sensitivity, zoom level lowered so spread-out action fits; regenerate keeps manual zooms; runs on first open of a recording. `CameraTrack` (precomputed, resolution independent): dead-zone follow with the segment's spring, aimed where the cursor settles; segments < 0.9 s apart chain into pans (with a slight pull-back on long pans) instead of zooming out. Zoom inspector: auto toggle, zoom level, sensitivity (live), regenerate, zoom list.

## Build

```bash
xcodegen generate && xcodebuild -project SmoothCursor.xcodeproj -scheme SmoothCursor -derivedDataPath build/DerivedData build
```

Package tests: `cd Packages/SmoothKit && swift test`.
