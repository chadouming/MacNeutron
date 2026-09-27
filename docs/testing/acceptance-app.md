# App acceptance test (sub-project 3a)

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
