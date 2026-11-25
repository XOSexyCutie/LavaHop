# LavaHop Changelog

## 1.0.0

First release.

- Jump bar for lava: a marker slides toward the next lava tick, and a green zone shows when to jump so the tick lands while you're in the air.
- A beep and "JUMP!" come a reaction time early, so jumping on the beep lands in the zone.
- Measures the lava's tick interval and whether jumping restarts the lava timer.
- Learns the jump timing that dodges from your own jumps, which covers ping and the game showing hits late. What it learns is saved.
- Tells you after each hit how early you jumped. Counts dodges and hits.
- Lava only: reads "Lava damaged You" from the Combat Log chat tab when it can, so the bar starts on the first tick and flamethrowers and other fire are ignored. Otherwise the bar starts when a second fire hit lands on the lava's rhythm, so campfires, fire traps and flamethrowers don't set it off (`/lava strict off` for any fire).
- Works without the combat log (WoW Forever): uses fire hits and health drops outside of combat, plus whether you're in the air.
- Commands: `/lava` (also `/lavahop`), including `test`, `stats`, `shift`, `strict`, `forget`, `lock`/`unlock` and `sound`.
