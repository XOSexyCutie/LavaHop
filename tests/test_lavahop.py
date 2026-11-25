"""LavaHop tests: Lua 5.1 via lupa with a fake WoW API.  python3 tests/test_lavahop.py"""
import os
import random
import unittest
from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'LavaHop.lua')

FAKE = r"""
now, falling, incombat, health, secret = 100.0, false, false, 1000, false
printed, sounds = {}, {}
function GetTime() return now end
function IsFalling() return falling end
function UnitAffectingCombat() return incombat end
function UnitIsDeadOrGhost() return false end
function UnitHealth() return health end
function UnitGUID() return "Player-1" end
if not secret_client then function CombatLogGetCurrentEventInfo() return 0 end end
function PlaySound(id) sounds[#sounds + 1] = id end
function print(s) printed[#printed + 1] = s end
if secret_client then function issecretvalue(v) return v == "SECRET" end end
bit = { band = function(a, b) return (a % (2 * b) >= b) and b or 0 end }
SlashCmdList = {}
UIParent = {}
local function obj()
  local o = { shown = false, text = "", value = 0, events = {}, scripts = {} }
  local mt = { __index = function(t, k)
    return function(self, ...) return nil end end }
  o.Show = function(self) self.shown = true end
  o.Hide = function(self) self.shown = false end
  o.SetText = function(self, t) self.text = t end
  o.SetValue = function(self, v) self.value = v end
  o.RegisterEvent = function(self, e) self.events[e] = true end
  o.RegisterUnitEvent = function(self, e) self.events[e] = true end
  o.SetScript = function(self, k, f) self.scripts[k] = f end
  o.CreateTexture = function() return obj() end
  o.CreateFontString = function() local f = obj(); fonts[#fonts + 1] = f; return f end
  o.GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end
  return setmetatable(o, mt)
end
fonts, frames = {}, {}
ChatFrame2 = { AddMessage = function(self, text) end }
COMBATLOG = ChatFrame2
function hooksecurefunc(obj, name, fn)
  local orig = obj[name]
  obj[name] = function(...) local r = orig(...); fn(...); return r end
end
function UnitName() return "Tester" end
function CreateFrame() local f = obj(); frames[#frames + 1] = f; return f end
"""


class Sim:
    def __init__(self, secret_client=True):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(f'secret_client = {"true" if secret_client else "false"}')
        self.lua.execute(FAKE)
        with open(SRC, encoding='utf-8') as fh:
            code = fh.read()
        self.lua.execute(f'local f = load([==[{code}]==], "LavaHop.lua"); f("LavaHop")')
        g = self.lua.globals()
        self.g = g
        self.ev = g.frames[1]          # event frame (the box is built on ADDON_LOADED)
        self.fire('ADDON_LOADED', 'LavaHop')
        self.fire('PLAYER_LOGIN')
        self.big = g.fonts[1]

    def fire(self, event, *args):
        self.ev.scripts['OnEvent'](self.ev, event, *args)

    def step(self, dt=0.02):
        self.g.now = self.g.now + dt
        self.ev.scripts['OnUpdate'](self.ev, dt)

    def run(self, secs, dt=0.02):
        for _ in range(int(round(secs / dt))):
            self.step(dt)

    def hit(self, school=4):
        self.fire('UNIT_COMBAT', 'player', 'WOUND', '', 600, school)

    @property
    def S(self):
        return self.g.LavaHop_Internal.S


def lava_run(sim, server, total, jump_lead, interval=1.0, airtime=0.7, jump=True, stand_first=0.0, lag=0.0,
             delay=0.0):
    """Drive the sim through `total` seconds of lava. server: 'reset' (jumping stops
    the lava timer, landing restarts it) or 'phase' (fixed rhythm, ticks only miss
    while airborne). The player jumps when the addon says JUMP! (after jump_lead)."""
    if sim.g.falling:              # land from the previous run first
        sim.g.falling = False
        sim.step()
    if sim.S.active:               # walk out of the old lava before the new run
        sim.run(6)
    t_end = sim.g.now + total
    t_jump = sim.g.now + stand_first
    nxt = sim.g.now + interval
    air_until = None
    hits = 0
    jump_seen_at = None
    hist = []                      # (time, falling) - the server sees you `lag` late
    inbox = []                     # hits reach the client `delay` after the server applied them
    prev_air = False
    while sim.g.now < t_end:
        now = sim.g.now
        if air_until and now >= air_until:
            sim.g.falling = False
            air_until = None
        hist.append((now, sim.g.falling))
        seen = [f for (tt, f) in hist if tt <= now - lag]
        server_air = seen[-1] if seen else False
        if server == 'reset' and prev_air and not server_air:   # server saw the landing
            nxt = now + interval
        prev_air = server_air
        while inbox and inbox[0] <= now:
            inbox.pop(0); sim.hit()
        if not server_air and now >= nxt:
            inbox.append(now + delay); hits += 1
            nxt = now + interval
        elif server_air and server == 'phase' and now >= nxt:
            nxt += interval
        elif server_air and server == 'reset':
            nxt = float('inf')
        if jump == 'random' and now >= t_jump and not sim.g.falling and air_until is None and random.random() < 0.025:
            sim.g.falling = True
            air_until = now + airtime * random.uniform(0.85, 1.15)
        if jump is True and now >= t_jump and sim.big.text == 'JUMP!' and not sim.g.falling and air_until is None:
            jump_seen_at = jump_seen_at or now
            if now - jump_seen_at >= jump_lead * random.uniform(0.5, 1.5):
                sim.g.falling = True
                air_until = now + airtime * random.uniform(0.85, 1.15)   # real jumps vary
                jump_seen_at = None
        sim.step()
    return hits


def dodges_learned(sim):
    b = sim.g.LavaHopDB.learned.bins
    return sum(b[i].d for i in range(20) if b and b[i]) if b else 0


class LavaHopTests(unittest.TestCase):
    def setUp(self):
        random.seed(7)

    def test_loads_and_avoids_combat_log_on_secret_clients(self):
        sim = Sim(secret_client=True)
        self.assertNotIn('COMBAT_LOG_EVENT_UNFILTERED', sim.ev.events)
        self.assertIn('UNIT_COMBAT', sim.ev.events)
        sim2 = Sim(secret_client=False)
        self.assertIn('COMBAT_LOG_EVENT_UNFILTERED', sim2.ev.events)

    def test_learns_interval_standing_in_lava(self):
        sim = Sim()
        for i in range(5):
            sim.hit(); sim.run(1.5)
        self.assertAlmostEqual(sim.g.LavaHop_Internal.Interval(), 1.5, places=1)
        self.assertTrue(sim.S.active)
        sim.run(4)                          # walked out: no more ticks on the ground
        self.assertFalse(sim.S.active)

    def test_ignores_non_fire_and_in_combat_noise(self):
        sim = Sim()
        sim.hit(school=1); sim.run(0.5)
        self.assertFalse(sim.S.active)
        sim.g.incombat = True
        sim.hit(); sim.run(0.5)
        self.assertFalse(sim.S.active)

    def test_secret_hits_only_count_on_rhythm(self):
        sim = Sim()
        for _ in range(3):
            sim.hit(); sim.run(1.0)
        n = sim.S.hits
        sim.g.now = sim.S.lastTick + 0.6; sim.hit(school='SECRET')   # off rhythm
        self.assertEqual(sim.S.hits, n)
        sim.g.now = sim.S.lastTick + 1.0; sim.hit(school='SECRET')   # on rhythm
        self.assertEqual(sim.S.hits, n + 1)

    def test_health_drops_start_timer(self):
        sim = Sim()
        sim.fire('UNIT_HEALTH', 'player'); sim.step()
        sim.g.health = 900; sim.fire('UNIT_HEALTH', 'player')
        self.assertFalse(sim.S.active)
        sim.run(1.0); sim.g.health = 800; sim.fire('UNIT_HEALTH', 'player')
        self.assertTrue(sim.S.active)

    def test_jumping_dodges_reset_server(self):
        sim = Sim()
        hits = lava_run(sim, 'reset', 23, 0.2, stand_first=3) - 3   # stand for the first ticks
        self.assertEqual(sim.g.LavaHop_Internal.Model(), 'reset')
        self.assertLessEqual(hits, 6, f'took {hits} ticks, dodged {sim.S.dodges}')
        self.assertGreaterEqual(sim.S.dodges, 8)

    def test_dodges_fixed_rhythm_server(self):
        sim = Sim()
        hits = lava_run(sim, 'phase', 35, 0.2, interval=2.0, stand_first=5) - 2
        # either model can fit a steady jumper; what matters is the ticks get dodged
        self.assertLessEqual(hits, 3, f'took {hits} ticks, dodged {sim.S.dodges}')
        self.assertGreaterEqual(sim.S.dodges, 8)

    def test_laggy_server_moves_window_earlier(self):
        sim = Sim()
        # ~0.25s reaction after the zone opens; the server sees jumps 0.25s late
        lava_run(sim, 'phase', 40, 0.25, interval=1.5, stand_first=4, lag=0.25)     # learning
        early, late = sim.g.LavaHop_Internal.Window()
        self.assertGreaterEqual(late, 0.2 - 1e-9)   # jumps under 0.25s before got hit
        hits = lava_run(sim, 'phase', 34, 0.25, interval=1.5, stand_first=4, lag=0.25) - 2
        self.assertLessEqual(hits, 5, f'took {hits} of ~20 ticks after learning, zone {early:.2f}-{late:.2f}')

    def test_learns_zone_from_random_jumps_with_delayed_hits(self):
        sim = Sim()
        # hits show up 0.4s after the server applied them, so the physics guess is wrong
        lava_run(sim, 'phase', 120, 0.0, interval=2.0, jump='random', stand_first=5, delay=0.4, lag=0.05)
        self.assertIsNotNone(sim.g.LavaHop_Internal.LearnedZone())
        early, late = sim.g.LavaHop_Internal.Window()
        self.assertGreater(late, 0.35)
        d0 = dodges_learned(sim)
        h = lava_run(sim, 'phase', 40, 0.15, interval=2.0, delay=0.4, lag=0.05, stand_first=5) - 2
        self.assertLessEqual(h, 3, f'hit {h} times in 35s following the zone {early:.2f}-{late:.2f}')
        self.assertGreaterEqual(dodges_learned(sim) - d0, 12)

    def test_only_lava_rhythm_starts_it(self):
        sim = Sim()
        for _ in range(3):                       # learn real lava: 2.0s ticks
            sim.hit(); sim.run(2.0)
        sim.run(5)
        self.assertFalse(sim.S.active)
        sim.hit(); sim.run(0.5)                  # one campfire hit
        self.assertFalse(sim.S.active)
        for gap in (1.3, 0.8, 1.1, 2.6):         # flamethrower-style bursts, off the beat
            sim.run(gap); sim.hit()
            self.assertFalse(sim.S.active, f'started on a {gap}s gap')
        sim.run(5)
        sim.hit(); sim.run(2.0); sim.hit()       # back in lava
        self.assertTrue(sim.S.active)
        n = sim.S.hits
        sim.run(0.7); sim.hit()                  # stray fire while in lava: ignored
        self.assertEqual(sim.S.hits, n)
        sim.g.LavaHopDB.strict = False
        sim.run(6); sim.hit()
        self.assertTrue(sim.S.active)

    def log(self, sim, text):
        sim.g.ChatFrame2.AddMessage(sim.g.ChatFrame2, text)

    def test_combat_log_text_names_the_lava(self):
        sim = Sim()
        lava = '|cffff8000Lava|r damaged You 611 Fire.'
        # flamethrower hits on the beat, before any lava text: rhythm mode would start
        self.log(sim, '|Hunit:x|hIronhand Guardian|h Gout of Flame hit You 183 Fire.')
        self.log(sim, lava)                       # first lava line: starts at once
        self.assertTrue(sim.S.active)
        sim.run(2.0); self.log(sim, lava)
        n = sim.S.hits
        self.assertEqual(n, 2)
        sim.run(1.0); sim.hit()                   # Gout of Flame (UNIT_COMBAT fire): ignored now
        self.assertEqual(sim.S.hits, n)
        sim.run(8)
        self.assertFalse(sim.S.active)
        for gap in (2.0, 2.0, 2.0):               # flamethrower exactly on the lava beat
            sim.hit(); sim.run(gap)
        self.assertFalse(sim.S.active)
        self.log(sim, 'Lava Spawn hits You 50 Fire.')   # a mob called Lava..., not lava
        self.assertFalse(sim.S.active)
        self.log(sim, '12:01:02.345  Lava damaged Tester 611 Fire.')
        self.assertTrue(sim.S.active)

    def test_hidden_log_text_falls_back_to_rhythm(self):
        sim = Sim()
        self.log(sim, 'SECRET')
        sim.hit(); sim.run(2.0); sim.hit()
        self.assertTrue(sim.S.active)

    def test_stays_up_while_dodging(self):
        random.seed(7)                                       # a run with a 30s+ perfect streak
        sim = Sim()
        lava_run(sim, 'phase', 75, 0.2, interval=2.0, stand_first=5)
        self.assertTrue(sim.S.active, 'turned off while still hopping in lava')
        self.assertGreater(sim.g.now - sim.S.lastTick, 30)    # really went 30s+ without a hit
        sim.run(5)                                           # stop jumping, stand outside: off
        self.assertFalse(sim.S.active)

    def test_slash_and_test_mode(self):
        sim = Sim()
        cmd = sim.g.SlashCmdList.LAVAHOP
        for c in ['', 'shift 0.1', 'interval 1.2', 'interval auto', 'model phase', 'model auto',
                  'sound off', 'sound 8959', 'lock', 'unlock', 'scale 1.3', 'debug', 'forget',
                  'strict off', 'strict on']:
            cmd(c)
        self.assertAlmostEqual(sim.g.LavaHopDB.shift, 0.1); cmd('shift 0')
        cmd('stats')
        cmd('test')
        sim.run(3)
        self.assertTrue(sim.S.active)
        sim.run(8)
        self.assertFalse(sim.S.active)
        self.assertEqual(sim.g.LavaHopDB.learned.interval, None)   # test didn't pollute learning


if __name__ == '__main__':
    unittest.main(verbosity=2)
