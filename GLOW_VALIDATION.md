Lilt ambient lighting validation — November 16, 2026

The reference is the supplied `Screen Recording 2026-11-16 at 5.48.28 PM.mov`: 17.57 seconds, 2940 × 1846, 672 variable-timestamp H.264 frames. There is no audio stream. It records a browser playing Lumn's demo, rather than an uncompressed capture of Lumn. The demo display has rounded corners but no visible notch.

The visible light is saturated blue with cyan variations. This clip does not contain the pink/red lighting mentioned in the task text. Bright concentrations travel mostly counterclockwise, overlap and change width, while substantial sections of the edge become nearly dark. The moving browser demo and brightness adjustments make a single exact velocity or native RGB value unreliable. The chosen region velocities, approximately 1100–1330 logical points/second on a 1470-point comparison display, are calibrated approximations, not measured native application settings.

Implementation changes:

- `Sources/Lilt/GlowBorder.swift`: three independently moving, wrapped perimeter light regions replace the broad two-colour split. Colours blend locally in linear light. A thin edge, filled inward wave, tight bloom and diffuse tail share the same perimeter field. All radial components peak at the physical outline; the bright wave cannot detach from it. Default colours use the observed blue/cyan character. Added persistent brightness, colour mode and beat sensitivity. Improved signed corner/notch masking and field resolution. Added RMS-based loudness modulation alongside normalized FFT bands and real onset events. Guarded stale capture operations and made the desktop panel explicitly unable to become key or main.
- `Sources/Lilt/AmbientLightingSettingsView.swift`: Reference Match / Album / Manual, brightness, beat sensitivity, numerical slider values, and an appearance reset. Existing lighting controls remain.
- `Sources/Lilt/LiltApp.swift`: added the `--glow-render` entry point; normal startup still starts the existing audio/overlay lifecycle.
- `Sources/Lilt/GlowValidation.swift`: repeatable offscreen exports through the production Metal shader, with no desktop/audio capture or permission prompts.
- `Sources/Lilt/SelfTest.swift`: FFT/silence fixtures, 30/120 fps equivalence, GPU edge-continuity and notch-transparency checks, alongside existing lyric/style tests.
- `tools/compare-glow.py`: reproducible image statistics, comparison frames and perimeter/time maps.

The player, lyrics, theme and lyric-style implementations were not changed for this request. The glow remains a transparent, non-activating, click-through desktop panel, hides on lock/sleep/session changes, and does not invoke the private lock-screen overlay. Normal capture is restricted to Spotify and Apple Music; captured content is not saved. Offline PNG exports are generated animation, not captured desktop frames.

Comparison method:

Extracted 141 reference frames at 8 fps. The demo display crop is x=518, y=438, width=1908, height=1242 in recording pixels; it is resized to 954 × 621. Compared the first 140 frames to 140 generated frames at the same dimensions. Baseline, first revision, second revision and final revision were rendered and inspected. Generated sequences use a fixed warm-up, 120 Hz elapsed-time simulation and Idle mode, keeping visual flow separate from unavailable reference audio.

The baseline and generated frames are composited over the per-pixel fifth-percentile reference background. This is an estimate, not an original clean desktop. It produces visible artifacts around changing menus and the moving display edge. All comparisons share that estimate. Motion phases are not synchronized; RGB differences are descriptive, not a claim of pixel parity. The moving concentrations use independently evolving positions, not a replay of the recording.

Final measurements at the 954 × 621 comparison scale:

| Measure | Reference | Final |
| --- | ---: | ---: |
| Dark perimeter fraction (blue minus red below 20/255) | 38.69% | 39.32% |
| Bright perimeter fraction (blue minus red above 100/255) | 47.32% | 44.45% |
| Edge blue excess, 90th percentile | 213 | 215 |
| Bright bottom-edge RGB median | (0, 82, 203) | (0, 83, 214) |
| Blue excess, 95th percentile, 12 px inward | 102 | 100 |
| Blue excess, 95th percentile, 20 px inward | 44 | 44 |
| Perimeter signal change per 125 ms | 27.12 | 26.55 |
| Estimated added linear luminance, dark bottom strip mean | 0.01189 | 0.01254 |
| Estimated added linear luminance, dark bottom strip 95th percentile | 0.08719 | 0.10326 |

Unaligned border RGB error fell from 34.96 to 21.78 levels/channel relative to the prior red/green implementation. This metric includes phase, background-estimation and browser-warping errors. Whole-border residual luminance remains substantially different (0.03703 reference mean versus 0.00875 final); the changing bright menu-bar wallpaper makes that estimate unreliable. The static dark bottom strip is a better constrained comparison, but its peak luminance is still higher in the generated result. Exact trajectories, native blend mode, compression-free colours and beat matching remain unverified. The visible notch treatment is an implementation check, not a match to a notch shown in the reference.

Artifacts (relative to this project):

- `build/glow-validation/after-comparison.jpg`: reference / baseline / final at 0, 2, 8 and 14 seconds.
- `build/glow-validation/preview.mp4`: final motion over the estimated background, sampled at 8 fps; desktop rendering uses the display refresh rate when active.
- `build/glow-validation/notch-check.png`: generated notch-following examples.
- `build/glow-validation/reference-motion.png` and `after-motion.png`: perimeter/time intensity maps for trajectory inspection.
- `build/glow-validation/after-metrics.json`: complete machine-readable measurements and limitations.

Build and verification:

`swift build -c release` and `./build.sh` succeed. The packaged app's `--selftest` passes, including actual Metal rendering, synthetic 80/900/6000 Hz tones and silence, different frame rates, edge fill and notch masking. The fixtures test DSP; they do not verify macOS permission handling or live Spotify/Music capture. The existing unhandled `LiltApp.swift.backup` warning remains; no new concurrency warnings were produced.

To reproduce generated frames:

```sh
build/Lilt.app/Contents/MacOS/Lilt --glow-render build/glow-validation/after 17.5 8 954 621
python3 tools/compare-glow.py build/glow-validation after
build/Lilt.app/Contents/MacOS/Lilt --glow-render build/glow-validation/notch 4 8 954 621 notch
```

Launch and manual checks:

1. Quit the running Lilt from its sparkles menu, then open `build/Lilt.app` (or run `open build/Lilt.app`).
2. Open Ambient Lighting, enable it, click Reset lighting appearance, and select Idle. Reference Match is the default colour mode. Check localized flowing blue/cyan light and continuously attached wave thickness around the edges and notch. Reset restores thickness 2, brightness 0.90, glow 0.70 and flow speed 1.00; earlier saved slider values otherwise remain intact.
3. Select Music Sync and play Spotify or Apple Music. Confirm the capture status, bass/beat modulation, quieter passages, and fade-out after pause. Album and Manual colours are optional. Audio capture permission is required only for Music Sync; no microphone permission is requested by this implementation.
4. Test ordinary clicks and typing, then lock/unlock and sleep/wake the Mac. Confirm the overlay remains on the unlocked desktop and cannot take focus. These live interaction and secure-surface checks have not been performed automatically.
