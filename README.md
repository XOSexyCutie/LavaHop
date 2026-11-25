# LavaHop

**Stop dying to lava.** LavaHop shows a jump bar while you're in lava. A marker slides toward the next lava tick, and a green zone shows when to jump so the tick lands while you're in the air. It learns the right timing from your own jumps.

Built for **WoW Forever**, where WeakAuras no longer work and addons can't read the combat log.

---

## How it works

- **Jump bar:** a white marker slides from left to right toward the red line, which is the next lava tick. Jump while the marker is in the **green zone**.
- **Beep and "JUMP!":** these come a reaction time ahead of the middle of the zone, so jumping when you hear the beep puts you in the zone. You can also time the jump off the marker, the same way you would a cast bar.
- **Learns the tick rhythm:** the first two ticks after you step into lava measure how often the lava ticks. Take those two standing still.
- **Learns your timing:** every jump is recorded by how long before the tick you took off and whether that tick hit you. After 8 jumps the green zone moves to the middle of the timings that actually dodge. This also corrects for your ping and for the game showing hits slightly late.
- **Remembers:** everything it learns is saved, so it's ready from the first tick next time.
- **Feedback:** after each hit it tells you how early you jumped, or that you were on the ground. The bottom line counts your dodges and hits.
- **Hides itself** when you leave the lava.

## Where it works

Jumping can only dodge lava where your feet actually leave it, so knee-deep lava is where it works. If the lava is deeper than your jump, you can't dodge it by jumping and LavaHop can't change that.

## Commands

| Command | What it does |
|---|---|
| `/lava` | Status and a list of commands |
| `/lava test` | 10 seconds of fake lava, to practise and place the bar |
| `/lava unlock` / `/lava lock` | Drag the bar while unlocked. Locked, it only shows in lava |
| `/lava scale 1.2` | Bar size |
| `/lava sound on\|off\|<soundID>` | The jump beep |
| `/lava shift 0.1` | Move the green zone earlier by 0.1 s (negative moves it later) |
| `/lava stats` | Every jump timing it has seen, with dodges and hits |
| `/lava forget` | Clear everything it learned and start over |
| `/lava interval auto\|<seconds>` | Set the tick interval by hand instead of measuring it |
| `/lava model auto\|reset\|phase` | Whether a jump restarts the lava timer (auto-detected) |
| `/lava on` / `/lava off` | Turn it on or off |
| `/lava debug` | Print every signal it sees, for bug reports |

## How it detects lava

Addons on Forever can't read the combat log, so LavaHop uses what the client still allows:
- fire damage hitting you outside of combat
- your health dropping outside of combat
- whether you're in the air

In combat, a hit only counts as lava if it lands on the lava's rhythm.

## Feedback

Bugs and ideas are welcome on the GitHub issues page. For a bug, `/lava debug` and `/lava stats` output helps a lot.
