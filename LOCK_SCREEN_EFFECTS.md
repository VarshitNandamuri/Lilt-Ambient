# Display Location and lock-screen effects

Two independent settings live in the menu under **Display Location**. Both are stored in UserDefaults and both default to **Lock Screen**:

| Setting | Key | Options |
|---|---|---|
| Constellation Lyrics | `display.lyricsLocation` | Off · Desktop · Lock Screen · Both |
| Ambient Lighting | `display.lightingLocation` | Off · Desktop · Lock Screen · Both |

`OverlayPresentationPolicy.decide` is the only place visibility is decided. Its inputs are the session state, display sleep, both locations, the lighting switch, and whether lyrics are available. Lyrics count as available when they are loaded **and** music is playing, which is upstream's condition.

## Lock-screen mechanism (restored from upstream)

Upstream `20c5d75` showed lyrics on the lock screen with `OverlayWindow` in `LiltApp.swift`:
- a full-screen non-activating `NSPanel` hosting `LyricsView`, with its own black stage;
- `.screenSaver` level, `ignoresMouseEvents` and `canBecomeVisibleWithoutLogin`;
- after ordering it in, `SkyLightOperator.delegateWindow` moves it into a private Space at absolute level 400 (`NotificationCenterAtScreenLock`);
- `DisplayAwake` is held while it is shown.

The current code uses that same Space, level and condition. One window holds both effects:
- **Content tree:** `CombinedOverlayContentView` holds the existing `GlowBorderView` (Metal, unchanged) on top, with the black lyrics stage underneath. On the lock screen the stage hosts upstream's `LyricsView`.
- **On lock:** the tree moves into a click-through host window. The window is ordered in and delegated only when it is not already visible, which matches upstream's `guard !panel.isVisible`.
- **On unlock:** the host is destroyed and the tree returns to the desktop panel. The desktop panel stays at `.statusBar` and is never delegated.
- **On the desktop:** lyrics are a transparent, click-through `ConstellationView` over your apps.
- **Black lyrics screen:** any key, mouse or trackpad input fades it out together with the lyrics, revealing the wallpaper and login controls. It returns after 10 s without input. The border stays.
- **Auto-lock:** when an idle auto-lock turns the display off while music plays, Lilt turns the display back on once per lock. It never does this with the lid closed or during system sleep.
- **Music Sync:** when lighting includes Lock Screen and music is playing, capture keeps running on the desktop even when nothing is drawn there, so the real-audio stream is already live at lock. Starting ScreenCaptureKit while locked is unverified.
- **Display sleep:** nothing renders and the Metal view pauses.

## Evidence on this Mac (macOS 26.6)

- **Real lock at 2026-11-17 02:41Z (log):** the host was delegated. While locked, AppKit reported the window **not occluded**, the window server reported it on-screen at layer 1000, and the glow drew at about 48 fps with lyrics attached.
- **`--skylight-probe` (unlocked):** the window leaves the desktop Space. MTKView and SwiftUI `TimelineView` both keep rendering at 60 fps.
- **Return value:** `SLSSpaceAddWindowsAndRemoveFromSpaces` returns garbage on this build, so Space membership is checked instead.

Not provable without your eyes: whether the composited pixels appear above the macOS 26 lock screen, and whether ScreenCaptureKit keeps delivering audio while locked.

## Safety

- The host cannot become key or main and ignores mouse events, and every view returns `nil` from `hitTest`.
- Lilt installs no event taps and makes no authentication changes.
- Idle time is read from the HID idle counter.
- **Off switches:**
  - set either location to Off or Desktop;
  - launch with `--disable-lock-screen-effects` (lock screen only) or `--disable-overlays` (everything);
  - or set `LILT_DISABLE_LOCK_SCREEN_EFFECTS=1`.

## Diagnostics

```sh
cat ~/Library/Logs/Lilt/lockscreen.log
```
The log never records titles, lyrics, tokens or audio.
