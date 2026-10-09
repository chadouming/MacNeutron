# App acceptance test (sub-project 3a)

Historical: the Rosetta runtime was removed in 0.1.0; reproduce with the frozen reference (`tools/freeze-rosetta-reference.sh`).

Manual, on a Mac with at least one installed Mac-only game (Timberborn here) and GPTK available.
Record results at the bottom.

## Steps

1. `make app && open build/MacNeutron.app`. The setup window opens in front.
2. **Install runtime:** step 1 turns green.
3. **Import GPTK:** drop `~/Downloads/Game_Porting_Toolkit_*.dmg` on step 2. It turns green and shows the D3DMetal version.
4. **Turn on Steam Play mode:** the preview lists Timberborn under "Stay native". Click "Turn on and restart Steam". Steam restarts; the menu shows "Steam Play mode on".
5. **Timberborn is protected:** `grep "AppID 1062090" "$HOME/Library/Application Support/Steam/logs/content_log.txt" | tail -3` shows no new update, and it launches from Play.
6. **A Windows game:** install "Cats" from Steam and press Play. It renders; `launcher.log` shows `backend=d3dmetal`.
7. **Per-game graphics:** in Games…, set Cats to DXMT and play again. `launcher.log` shows `backend=dxmt`.
8. **Runs as:** switch a dual-platform game to "Windows version". The menu shows "Restart Steam to apply 1 change". Click it, and after the restart the game's Properties show MacNeutron.
9. **Free up space:** uninstall Cats in Steam. "Free up space" appears; delete its prefix.
10. **Turn off:** Settings → Turn off Steam Play mode → confirm. Steam restarts in Mac mode, and Timberborn is still installed with no download.

## Results

| Date | Steps passed | Notes |
|---|---|---|
| 2026-09-27 | 1–8 pass; 9 not run (no uninstalled game with a leftover prefix; covered by unit tests); 10 skipped on purpose (it would remove the user's installed SMITE 2, 26 GB; disable is unit-tested) | Windows game: SMITE 2 (app 2437170) instead of Cats. It runs on D3DMetal but slowly and can't log in ("can't find Steam"), which needs the Steam API bridge (sub-project 2). Found and fixed during the run: `.app` launch targets gave exit 126, and universal games ran under Rosetta (commit `1c308f3`). Timberborn was never unmounted and launches natively from Play. |

## Windows opened from the menu bar (UI-1)

Checks that Games… and Settings… come to the front, focused, from the menu-bar icon (Free up space and Finish setup…
use the same path). Run it on `build/MacNeutron.app` after `make app`, with physical clicks only: scripted clicks
refresh the event timestamp and hide the bug.

Do each step with Games…, then again with Settings…:

1. **Another app frontmost:** Finder is frontmost, the window is not open yet. Choose the item.
2. **Already open, behind:** click a Finder window so it covers the window, then choose the item again.
3. **Minimised:** press Cmd-M on the window, make Finder frontmost, then choose the item.
4. **Another Space or a full-screen app:** leave the window on Desktop 1, switch to Desktop 2 (then to a full-screen
   app's Space) with another app frontmost, and choose the item.
5. **Stage Manager on:** turn on Stage Manager and repeat steps 1 and 2.
6. **After Hide Others:** in Finder press Cmd-Opt-H, which hides MacNeutron's windows, then choose the item.

PASS: the window is on top, its traffic lights are coloured, and typing goes into it.

Only when a step fails, read the WindowServer log (a passing step can log a harmless duplicate "Rejecting" line):
`log show --last 5m --predicate 'eventMessage CONTAINS "CPS"'`. Then:

- Not focused, with a "Rejecting expired request" line for MacNeutron's pid: `activate(ignoringOtherApps:)` was
  refused. Switch to a temporary `.regular` activation policy while a window is open.
- Step 6 fails: add `NSApp.unhide(nil)` before the activate call in `raiseWindow`.
- Steps 1–2 pass but step 3 or 4 fails: print `NSApplication.shared.windows.map { $0.identifier?.rawValue }` once in
  `raiseWindow` to check SwiftUI's `<id>-AppWindow-<n>` naming.

| Step | Games… | Settings… | Notes |
|---|---|---|---|
| 1. Another app frontmost | | | |
| 2. Already open, behind | | | |
| 3. Minimised | | | |
| 4. Another Space / full-screen app | | | |
| 5. Stage Manager on | | | |
| 6. After Hide Others (Cmd-Opt-H) | | | |
