# Changelog — EUI RestedXP Skin

## 0.10.0 (beta)

Tested on the World of Warcraft Forever beta (Interface 16001, German client) with ShortestPathForever 1.20.0.

### ShortestPathForever: Journey and compass
- The Journey section in the objective tracker column (ShortestPathForever's "Show journey in tracker") now looks
  like the EllesmereUI quest tracker: section header in the accent colour with a thin accent line, journey title in
  the quest title colour, steps in the quest tracker's font and grey, the current step in the accent colour, a
  dark panel behind it (colour of the EllesmereUI quest tracker background, opacity adjustable).
- The compass ("Show the compass" in ShortestPathForever) gets light ticks and letters in the EllesmereUI font,
  north, the centre mark and the walking marks in the accent colour, and with a background the window colour and
  a thin accent edge instead of black.
- New options page Navigation › Journey; the Compass bar page gets "Restyle the compass" and "Show the time left
  under the compass". Switching a skin off gives ShortestPathForever's own look back.
- `/euirxp spf` shows whether the skin found ShortestPathForever's frames.

## 0.9.0 (beta)

Tested on the World of Warcraft Forever beta (Interface 16001, build 70374, German client) with
RestedXP Guides 4.11.23, EllesmereUI 9.6 and ShortestPathForever 1.19.2.

### Guide window
- Restyles the RestedXP guide window in the EllesmereUI look: header with title, step counter, progress bar
  and ‹ › step buttons; current step with goals, counters and progress bars; list of upcoming steps
  (one line per goal, up to five per step, mouse wheel scrolls the whole guide, right-click = go to step).
- Window grows up or down, can be dragged to the screen edges, keeps RestedXP's saved position and width;
  "Reset window position" in the options.
- Target and item boxes sit at an edge of the window (auto, bottom, top, left, right) and can be dragged
  along it; they stay usable in combat.
- Optional: hide the window in combat and/or in instances (the guide logic keeps running).
- Blocks RestedXP's guide window v2 on request (one chat note, `/reload` needed).
- Dragging a box shows an accent line on the window edge where it will dock.
- The cog in the header uses the accent colour; right-click on it opens the EUI RestedXP Skin options.
- "Restyle RestedXP" off restores RestedXP's own look.

### Colours and theme
- Follows the EllesmereUI accent colour live; registers a "EUIRestedXPSkin" theme in RestedXP.
- The window colour is 161618 by default; custom accent, window background and progress colours; fonts from EllesmereUI or the game.
- With EllesmereUI third-party skinning switched off, a fallback colour is used and the options say so.

### Navigation arrow
- Own arrow (default size 70 %) fed by the ShortestPathForever route (falls back to a straight line to the RestedXP step target).
- Four styles, colour by direction or accent, states for travelling, transport (flight path, boat, zeppelin,
  lift, tram, portal, teleport, passage, with departure time) and "arrived".
- Keeps turning in combat; dragging is locked in combat. Optional "keep arrow centred".
- Hides RestedXP's own arrow on request and restores it when switched off.

### Options
- All settings live in the EllesmereUI options window, section "RestedXP" (`/euirxp`, addon compartment).
- Live arrow preview with state chips and route source.
- Selected ShortestPathForever settings (arrow, map, pins, transport kinds) can be changed from there;
  previous values are remembered and written back by "Reset to defaults".

### Languages
- English and German. The language follows "EUI Options Language" in the EllesmereUI global settings, otherwise the game client; any language other than German shows English.

### Known limitations
- Only tested on the Forever beta (Interface 16001); the TOC lists no other game version.
- Not tested inside instances (the arrow switches off there by design).
- With "lock boxes" on, RestedXP's window cannot be moved or resized during combat (protected boxes are
  anchored to it); height changes are applied after combat.
