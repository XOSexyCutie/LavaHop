-- LavaHop: a lava tick timer. Shows when the next lava tick will land and tells
-- you to JUMP just before it, so you are in the air when it hits.
--
-- The Forever client (12.x style) doesn't give addons the combat log, which is
-- why the old WeakAura broke. LavaHop uses what is still available:
--   * UNIT_COMBAT on the player (fire damage hits), timing only if values are secret
--   * player health drops while out of combat
--   * the combat log, but only on clients without secret values
-- and IsFalling() to know whether you are in the air. The tick interval and
-- whether a jump restarts the lava timer are learned from your own ticks.
local ADDON = ...
local VERSION = "1.0.0"

local DEFAULT_INTERVAL = 1.0   -- seconds between lava ticks until measured
local GRACE = 0.3              -- server/latency slack after a predicted tick
local DEDUPE = 0.25            -- signals closer than this are the same tick
local REACT = 0.2              -- typical reaction time to a sound / text cue

local DEFAULTS = {
  enabled = true, shift = 0, interval = 0, model = "auto",
  sound = true, soundId = 856, locked = false, scale = 1, debug = false, strict = true,
}

local db
local S = {}
local frame, bar, zone, spark, tickMark, bigText, subText
local BAR_W = 260

local function Print(msg) print("|cffff6a00LavaHop|r: " .. msg) end
local function Debug(msg) if db and db.debug then Print("|cff999999" .. msg .. "|r") end end
local function readable(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local band = (bit and bit.band) or function(a, b) return (a % (2 * b) >= b) and b or 0 end

local function push(list, v, max)
  list[#list + 1] = v
  while #list > (max or 9) do table.remove(list, 1) end
end
local function median(list)
  if #list == 0 then return nil end
  local t = {}
  for i, v in ipairs(list) do t[i] = v end
  table.sort(t)
  local n = #t
  if n % 2 == 1 then return t[(n + 1) / 2] end
  return (t[n / 2] + t[n / 2 + 1]) / 2
end
local function mean(list)
  if #list == 0 then return nil end
  local s = 0
  for _, v in ipairs(list) do s = s + v end
  return s / #list
end

local function ResetState()
  S.active = false
  S.lastTick, S.lastLand, S.jumpAt = nil, nil, nil
  S.airborne = false
  S.jumpedSinceTick = false
  S.hits, S.dodges = 0, 0
  S.beepedFor = nil
  S.predAtJump = nil
  S.flash, S.flashUntil = nil, 0
  S.armAt = nil
  S.takeoff = nil
  S.note, S.noteUntil = nil, 0
  S.jumpEval, S.pendingDodges = nil, {}
end

local function ResetLearning()
  S.groundDeltas, S.landDeltas, S.errReset, S.errPhase = {}, {}, {}, {}
  S.airtimes = {}
  if db then db.learned = {} end
end

---------------------------------------------------------------- model
local function Interval()
  if db.interval and db.interval > 0 then return db.interval end
  return median(S.groundDeltas) or db.learned.interval or DEFAULT_INTERVAL
end

local function FirstDelay()   -- time from landing back in lava to its first tick
  return median(S.landDeltas) or db.learned.firstDelay or Interval()
end

local function Airtime()      -- how long one of your jumps keeps you off the ground
  return median(S.airtimes) or db.learned.airtime or 0.65
end

local function Latency()
  local ok, _, _, home, world = pcall(GetNetStats)
  local ms = ok and (tonumber(world) or tonumber(home)) or nil
  if not ms or ms <= 0 then ms = 100 end
  return math.min(ms, 600) / 1000
end

local function maxOf(list) local m; for _, v in ipairs(list) do if not m or v > m then m = v end end; return m end
local function minOf(list) local m; for _, v in ipairs(list) do if not m or v < m then m = v end end; return m end

-- The jump window, as seconds before the predicted tick: jump between `early` and `late`.
-- You must still be in the air when the server checks, and the server sees your jump
-- one ping later than you do, so the window closes a little before the tick.
-- That is only the starting guess: the game can report a tick a few tenths of a
-- second after the server applied it, so the real zone is learned from your own
-- jumps. Every jump is filed by how long before the tick you took off (0.1s bins)
-- and whether that tick hit you; the zone becomes the bins where jumps dodge.
local NB, BIN = 20, 0.1
local MIN_JUMPS = 8

local function JumpCount()
  local n, b = 0, db.learned.bins or {}
  for i = 0, NB - 1 do local c = b[i]; if c then n = n + c.d + c.h end end
  return n
end

local function LearnedZone()
  local b = db.learned.bins
  if not b or JumpCount() < MIN_JUMPS then return nil end
  -- a timing is "good" when most jumps there dodged; an untried gap between two good
  -- timings counts as good too. The zone is the middle of the best-supported run
  -- of good timings - its edges are where the hits start.
  local good, n, d = {}, {}, {}
  for i = 0, NB - 1 do
    local c = b[i]
    n[i], d[i] = c and (c.d + c.h) or 0, c and c.d or 0
    good[i] = n[i] >= 1 and (d[i] + 0.5) / (n[i] + 1) >= 0.6
  end
  for i = 1, NB - 2 do
    if n[i] == 0 and good[i - 1] and good[i + 1] then good[i] = true end
  end
  local bestLo, bestHi, bestScore = nil, nil, 0
  local i = 0
  while i < NB do
    if good[i] then
      local lo, score = i, 0
      while i < NB and good[i] do score = score + d[i]; i = i + 1 end
      if score > bestScore then bestLo, bestHi, bestScore = lo, i - 1, score end
    else
      i = i + 1
    end
  end
  if not bestLo or bestScore < 3 then return nil end
  local center = (bestLo + bestHi + 1) / 2 * BIN
  local half = math.min(0.15, (bestHi - bestLo + 1) * BIN / 2)
  return center + half, center - half, bestScore
end

local function Window()
  local early, late = LearnedZone()
  if not early then
    early, late = Airtime() - 0.12, Latency() + 0.08
  end
  if early - late < 0.15 then
    local mid = (early + late) / 2
    early, late = mid + 0.075, mid - 0.075
  end
  local sh = db.shift or 0
  return early + sh, math.max(0.02, late + sh)
end

local function Calibrated()
  return (db.interval and db.interval > 0) or #S.groundDeltas > 0 or db.learned.interval ~= nil
end

-- "reset": leaving the lava (jumping) stops the lava timer and landing restarts it.
-- "phase": the ticks keep their rhythm and a jump only skips the one it covers.
local function Model()
  if db.model == "reset" or db.model == "phase" then return db.model end
  if #S.errReset >= 2 and #S.errPhase >= 2 then
    return (mean(S.errReset) <= mean(S.errPhase)) and "reset" or "phase"
  end
  return db.learned.model or "reset"
end

-- Predicted time of the next tick, or nil while the lava timer is paused (in the air).
local function NextTick(now)
  if not S.lastTick and not S.lastLand then return nil end
  if Model() == "reset" then
    if S.airborne then return nil end
    if S.lastLand and (not S.lastTick or S.lastLand > S.lastTick) then
      return S.lastLand + FirstDelay()
    end
    return S.lastTick + Interval()
  end
  local base, iv = S.lastTick or S.lastLand, Interval()
  local k = math.max(1, math.ceil((now - base - GRACE) / iv))
  return base + k * iv
end

local function SaveLearned()
  db.learned.interval = median(S.groundDeltas) or db.learned.interval
  db.learned.firstDelay = median(S.landDeltas) or db.learned.firstDelay
  if #S.errReset >= 2 and #S.errPhase >= 2 then db.learned.model = Model() end
  db.learned.airtime = median(S.airtimes) or db.learned.airtime
end

---------------------------------------------------------------- ticks
local function RecordJump(o, dodged)
  local i = math.floor(o / BIN)
  if i < 0 or i >= NB then return end
  db.learned.bins = db.learned.bins or {}
  local c = db.learned.bins[i] or { d = 0, h = 0 }
  db.learned.bins[i] = c
  if dodged then c.d = c.d + 1 else c.h = c.h + 1 end
  Debug(string.format("jump %.2fs before the tick: %s  (%d jumps learned)", o, dodged and "dodged" or "hit", JumpCount()))
end

local function Deactivate(why)
  if S.active then Debug("off (" .. why .. ")  ticks " .. S.hits .. ", dodged " .. S.dodges) end
  S.active = false
  S.lastTick, S.lastLand, S.predAtJump = nil, nil, nil
  S.jumpEval, S.pendingDodges = nil, {}
end

local function OnTick(t, source)
  if S.lastTick and t - S.lastTick < DEDUPE then return end
  if S.active and S.lastTick then
    local d = t - S.lastTick
    if not S.jumpedSinceTick and d >= 0.4 and d <= 5 then push(S.groundDeltas, d) end
    if S.lastLand and S.lastLand > S.lastTick then
      local ld = t - S.lastLand
      if ld >= 0.05 and ld <= 5 then
        if Calibrated() then
          if #S.landDeltas > 0 then push(S.errReset, math.abs(ld - FirstDelay())) end
          local iv = Interval()
          local k = math.max(1, math.floor(d / iv + 0.5))
          push(S.errPhase, math.abs(d - k * iv))
        end
        push(S.landDeltas, ld)
      end
    end
  elseif S.lastLand and t - S.lastLand <= 5 then
    push(S.landDeltas, t - S.lastLand)
  end
  if S.active then
    for _, o in ipairs(S.pendingDodges) do RecordJump(o, true) end   -- still in lava: real dodges
    S.pendingDodges = {}
    local je = S.jumpEval
    if je and math.abs(t - je.pred) <= 0.45 then
      RecordJump(je.o, false)
      S.note = string.format("hit: you jumped %.2fs before the tick", je.o)
      S.jumpEval = nil
    elseif Calibrated() then
      S.note = "hit: you were on the ground"
    end
    S.noteUntil = t + 2
  end
  if not S.active then S.hits, S.dodges = 0, 0 end
  S.active = true
  S.lastTick = t
  S.jumpedSinceTick = S.airborne
  S.predAtJump = nil
  S.hits = S.hits + 1
  if S.airborne then S.flash, S.flashUntil = "hit", t + 0.6 end
  SaveLearned()
  Debug(string.format("tick (%s)  interval %.2fs  first-after-landing %.2fs  model %s",
    source, Interval(), FirstDelay(), Model()))
end

-- A hit that isn't known to be lava: accept only when it lines up with the rhythm.
local function OnMaybeTick(t, source)
  if not S.active then return end
  local nt = NextTick(t)
  if nt and math.abs(t - nt) <= 0.35 then OnTick(t, source) end
end

-- Is a gap between two hits a whole number of lava ticks (1-3, so a dodged tick is fine)?
local function OnRhythm(d, tol, maxK)
  local iv = Interval()
  tol = tol or math.max(0.15, 0.06 * iv)
  local k = math.floor(d / iv + 0.5)
  if k < 1 or k > (maxK or 3) then return false end
  return math.abs(d - k * iv) <= tol + 0.01 * k      -- a little drift per tick
end

-- A fire hit / health drop out of combat. Lava ticks on a steady beat; other fire
-- (campfires, flamethrowers, fire patches) doesn't. So one hit only arms the timer,
-- and it starts when a second hit lands on the lava rhythm. While running, hits
-- off the rhythm are ignored.
local function OnCandidate(t, source)
  if S.active then
    local nt = NextTick(t)
    if not Calibrated() or (nt and math.abs(t - nt) <= 0.35)
        or (S.lastTick and OnRhythm(t - S.lastTick, 0.25, 15)) then
      OnTick(t, source)
    else
      Debug(string.format("%s: off the lava rhythm, ignored", source))
    end
    return
  end
  if not db.strict then OnTick(t, source); return end
  local a = S.armAt
  S.armAt = t
  if not a then
    Debug(source .. ": waiting for a second hit on the lava rhythm")
    return
  end
  local d = t - a
  local ok
  if Calibrated() then ok = OnRhythm(d) else ok = d >= 0.4 and d <= 3 end
  if ok then
    S.armAt = nil
    OnTick(a, source); OnTick(t, source)
  else
    Debug(string.format("%s: %.2fs after the last one - not the lava rhythm (%.2fs), ignored", source, d, Interval()))
  end
end

---------------------------------------------------------------- display
local function Paint(now)
  if not frame then return end
  if S.test and now >= S.test.untilT then
    S.groundDeltas, S.landDeltas, S.errReset, S.errPhase = (unpack or table.unpack)(S.test.saved)
    db.learned = S.test.savedLearned
    S.test = nil
    Deactivate("test over")
    Print("test over.")
  end
  if not db.enabled or not S.active then
    if not db.locked then
      frame:Show()
      zone:Hide(); spark:Hide()
      bigText:SetText("LavaHop"); bigText:SetTextColor(1, 0.55, 0.1)
      subText:SetText("drag me - /lava lock")
    else
      frame:Hide()
    end
    return
  end
  frame:Show()
  local nt = NextTick(now)
  local early, late = Window()
  local span = math.max(Interval(), FirstDelay(), early + 0.3)
  local function X(t) return math.min(BAR_W, math.max(0, (t - (nt - span)) / span * BAR_W)) end

  if nt and Calibrated() then
    local zx1, zx2 = X(nt - early), X(nt - late)
    zone:ClearAllPoints()
    zone:SetPoint("LEFT", bar, "LEFT", zx1, 0)
    zone:SetWidth(math.max(2, zx2 - zx1))
    zone:Show()
    spark:ClearAllPoints()
    spark:SetPoint("CENTER", bar, "LEFT", X(now), 0)
    spark:Show()
  else
    zone:Hide(); spark:Hide()
  end

  local inZone = nt and now >= nt - early and now <= nt - late
  -- the beep / JUMP! text comes a reaction time early, so reacting to it lands mid-zone
  local cue = nt and now >= nt - ((early + late) / 2 + REACT) and now <= nt - late
  if inZone then spark:SetColorTexture(0.3, 1, 0.3, 1) else spark:SetColorTexture(1, 1, 1, 1) end
  if S.flash and now < S.flashUntil then
    if S.flash == "dodge" then
      bigText:SetText("Dodged!"); bigText:SetTextColor(0.3, 1, 0.3)
    else
      bigText:SetText("Hit"); bigText:SetTextColor(1, 0.3, 0.3)
    end
  elseif not Calibrated() then
    bigText:SetText("measuring..."); bigText:SetTextColor(1, 0.8, 0.2)
  elseif not nt then
    bigText:SetText("in the air"); bigText:SetTextColor(0.6, 0.8, 1)
  elseif cue then
    bigText:SetText("JUMP!"); bigText:SetTextColor(0.3, 1, 0.3)
    if db.sound and S.beepedFor ~= nt and not S.airborne then
      S.beepedFor = nt
      pcall(PlaySound, db.soundId, "Master")
    end
  elseif now > nt - late then
    bigText:SetText(S.airborne and "in the air" or "too late"); bigText:SetTextColor(1, 0.3, 0.2)
  else
    bigText:SetText("get ready"); bigText:SetTextColor(1, 0.8, 0.2)
  end

  if S.note and now < S.noteUntil then
    subText:SetText(S.note)
  elseif Calibrated() then
    local n = JumpCount()
    subText:SetText(string.format("tick every %.1fs  |  dodged %d, hit %d  |  %s", Interval(), S.dodges, S.hits,
      LearnedZone() and "zone learned" or string.format("learning %d/%d jumps", n, MIN_JUMPS)))
  else
    subText:SetText("stand still for one more tick to learn the timing")
  end
end

local function BuildFrame()
  frame = CreateFrame("Frame", "LavaHopFrame", UIParent)
  frame:SetSize(BAR_W + 16, 70)
  frame:SetScale(db.scale or 1)
  if db.point then
    frame:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
  end
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true)
  frame:EnableMouse(not db.locked)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) if not db.locked then self:StartMoving() end end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    db.point = { p, rp, x, y }
  end)
  local bg = frame:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.55)
  bigText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  bigText:SetPoint("TOP", frame, "TOP", 0, -4)
  -- the jump bar: the white marker slides right toward the tick (red line at the
  -- right end). Jump while the marker is inside the green zone.
  bar = CreateFrame("Frame", nil, frame)
  bar:SetSize(BAR_W, 16)
  bar:SetPoint("BOTTOM", frame, "BOTTOM", 0, 20)
  local bbg = bar:CreateTexture(nil, "BACKGROUND")
  bbg:SetAllPoints()
  bbg:SetColorTexture(0.3, 0.08, 0, 0.85)
  zone = bar:CreateTexture(nil, "BORDER")
  zone:SetColorTexture(0.1, 0.75, 0.2, 0.75)
  zone:SetHeight(16)
  tickMark = bar:CreateTexture(nil, "ARTWORK")
  tickMark:SetColorTexture(1, 0.1, 0.05, 1)
  tickMark:SetSize(3, 22)
  tickMark:SetPoint("CENTER", bar, "RIGHT", 0, 0)
  spark = bar:CreateTexture(nil, "OVERLAY")
  spark:SetColorTexture(1, 1, 1, 1)
  spark:SetSize(4, 24)
  subText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  subText:SetPoint("BOTTOM", frame, "BOTTOM", 0, 4)
end

---------------------------------------------------------------- update loop
local acc = 0
local function OnUpdate(_, elapsed)
  acc = acc + elapsed
  if acc < 0.02 then return end
  acc = 0
  local now = GetTime()
  local air = IsFalling() and true or false
  if air and not S.airborne then          -- took off
    S.predAtJump = NextTick(now)        -- before marking airborne (the reset model pauses in the air)
    if S.active and Calibrated() and S.predAtJump and S.predAtJump >= now and S.predAtJump - now < NB * BIN then
      -- hopping again in lava confirms the earlier dodges (the last jump before you
      -- walk out is never confirmed, so leaving the lava isn't learned as a dodge)
      for _, o in ipairs(S.pendingDodges) do RecordJump(o, true) end
      S.pendingDodges = {}
      S.jumpEval = { pred = S.predAtJump, o = S.predAtJump - now }
    end
    S.airborne = true
    S.jumpedSinceTick = true
    S.takeoff = now
  elseif not air and S.airborne then      -- landed
    S.airborne = false
    if S.takeoff then
      local a = now - S.takeoff
      if a >= 0.3 and a <= 1.2 then push(S.airtimes, a) end   -- longer = a fall, not a jump
    end
    if S.active then
      S.lastLand = now
    end
    S.predAtJump = nil
  end

  if S.jumpEval and now > S.jumpEval.pred + 0.45 then   -- the tick it aimed at never came
    S.pendingDodges[#S.pendingDodges + 1] = S.jumpEval.o
    S.dodges = S.dodges + 1
    S.flash, S.flashUntil = "dodge", now + 0.4
    S.jumpEval = nil
  end

  if S.test and not S.airborne then       -- fake lava: a "reset" style timer
    if S.test.landed ~= S.lastLand then S.test.landed = S.lastLand; S.test.fakeNext = (S.lastLand or now) + 1.0 end
    if now >= S.test.fakeNext then OnTick(now, "test"); S.test.fakeNext = now + 1.0 end
  end

  if S.active and not S.airborne then     -- stood still on ground past a tick: out of the lava
    local since = math.max(S.lastTick or 0, S.lastLand or 0)
    local limit = Calibrated() and (math.max(Interval(), FirstDelay()) * 1.6 + 0.4) or 4.5
    if now - since > limit then Deactivate("no tick on the ground") end
  end
  -- dodging every tick is the goal, so jumping keeps it up; standing on the ground
  -- past a tick (above) is how it knows you left. Safety net: 2 minutes without a tick.
  if S.active and S.lastTick and now - S.lastTick > 120 then Deactivate("2 minutes without a tick") end
  Paint(now)
end

---------------------------------------------------------------- events
local ev = CreateFrame("Frame")

local function OnEvent(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= ADDON then return end
    LavaHopDB = LavaHopDB or {}
    for k, v in pairs(DEFAULTS) do if LavaHopDB[k] == nil then LavaHopDB[k] = v end end
    local learned = LavaHopDB.learned or {}
    if LavaHopDB.version ~= VERSION then
      learned.tooLate, learned.tooEarly = nil, nil
      LavaHopDB.version = VERSION
    end
    db = LavaHopDB
    ResetState(); ResetLearning(); db.learned = learned
    BuildFrame()
    ev:SetScript("OnUpdate", OnUpdate)
    return
  end
  if not db then return end
  local now = GetTime()
  if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_DEAD" then
    Deactivate(event)
    S.lastHealth = nil
  elseif event == "UNIT_COMBAT" then
    local unit, action, _, amount, school = ...
    if unit ~= "player" then return end
    if readable(action) and action ~= "WOUND" then return end
    local fire = readable(school) and band(school, 4) > 0
    local known = readable(school)
    Debug(string.format("UNIT_COMBAT %s amount=%s school=%s%s",
      readable(action) and action or "?", readable(amount) and tostring(amount) or "secret",
      known and tostring(school) or "secret", UnitAffectingCombat("player") and " (in combat)" or ""))
    if fire and not UnitAffectingCombat("player") then OnCandidate(now, "fire hit")
    elseif fire or not known then OnMaybeTick(now, "hit") end
  elseif event == "UNIT_HEALTH" then
    local unit = ...
    if unit ~= "player" then return end
    local h = UnitHealth("player")
    if not readable(h) then S.lastHealth = nil; return end
    if S.lastHealth and h < S.lastHealth and not UnitAffectingCombat("player") and not UnitIsDeadOrGhost("player") then
      Debug("health drop " .. (S.lastHealth - h))
      OnCandidate(now, "health")
    end
    S.lastHealth = h
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    local _, sub, _, _, _, _, _, dst, _, _, _, envType = CombatLogGetCurrentEventInfo()
    if sub == "ENVIRONMENTAL_DAMAGE" and dst == UnitGUID("player") then
      Debug("combat log: " .. tostring(envType))
      if string.upper(tostring(envType)) == "LAVA" then OnTick(now, "combat log") end
    end
  elseif event == "MIRROR_TIMER_START" then
    Debug("mirror timer " .. tostring((...)))
  end
end

ev:SetScript("OnEvent", OnEvent)
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_DEAD")
pcall(ev.RegisterEvent, ev, "MIRROR_TIMER_START")
if ev.RegisterUnitEvent then
  pcall(ev.RegisterUnitEvent, ev, "UNIT_COMBAT", "player")
  pcall(ev.RegisterUnitEvent, ev, "UNIT_HEALTH", "player")
else
  pcall(ev.RegisterEvent, ev, "UNIT_COMBAT")
  pcall(ev.RegisterEvent, ev, "UNIT_HEALTH")
end
-- On secret-value clients (Forever) the combat log is off limits to addons; registering it would be blocked.
if not issecretvalue and CombatLogGetCurrentEventInfo then
  pcall(ev.RegisterEvent, ev, "COMBAT_LOG_EVENT_UNFILTERED")
end

---------------------------------------------------------------- slash
local function Status()
  local early, late = Window()
  Print(string.format("v%s %s. Jump %.2f-%.2fs before a tick (your jump lasts %.2fs, ping %dms). Tick every %.2fs%s, first tick %.2fs after landing, model: %s%s. Sound %s.",
    VERSION, db.enabled and "on" or "off", early, late, Airtime(), Latency() * 1000, Interval(),
    (db.interval > 0) and " (set by you)" or (Calibrated() and " (measured)" or " (guess, not measured yet)"),
    FirstDelay(), Model(), db.model == "auto" and " (auto)" or "",
    db.sound and ("on (" .. db.soundId .. ")") or "off"))
end

local function Help()
  Status()
  Print("/lava on | off - enable or disable")
  Print("/lava strict on | off - on: only lava (needs 2 hits on the lava rhythm), off: any fire")
  Print("/lava shift 0.1 - move the green zone earlier (negative = later)")
  Print("/lava interval auto | 1.0 - tick interval (auto = measured)")
  Print("/lava model auto | reset | phase - does a jump restart the lava timer?")
  Print("/lava sound on | off | <soundID> - beep when it's time to jump")
  Print("/lava lock | unlock - move the box, /lava scale 1.2")
  Print("/lava test - 10s of fake lava to practise, /lava forget - clear what it learned")
  Print("/lava stats - which jump timings dodged and which got hit")
  Print("/lava debug - print every signal it sees")
end

SLASH_LAVAHOP1, SLASH_LAVAHOP2 = "/lava", "/lavahop"
SlashCmdList.LAVAHOP = function(msg)
  if not db then return end
  local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  local n = tonumber(arg)
  if cmd == "on" or cmd == "off" then
    db.enabled = (cmd == "on"); Print(db.enabled and "enabled." or "disabled.")
  elseif (cmd == "shift" or cmd == "lead") and n and n >= -1 and n <= 1 then
    db.shift = n; Print(string.format("green zone moved %.2fs %s.", math.abs(n), n >= 0 and "earlier" or "later"))
  elseif cmd == "interval" and (arg == "auto" or (n and n >= 0.2 and n <= 10)) then
    db.interval = n or 0; Status()
  elseif cmd == "model" and (arg == "auto" or arg == "reset" or arg == "phase") then
    db.model = arg; Status()
  elseif cmd == "sound" then
    if arg == "off" then db.sound = false
    elseif n then db.sound = true; db.soundId = n; pcall(PlaySound, n, "Master")
    else db.sound = true; pcall(PlaySound, db.soundId, "Master") end
    Print("sound " .. (db.sound and ("on (" .. db.soundId .. ")") or "off") .. ".")
  elseif cmd == "lock" or cmd == "unlock" then
    db.locked = (cmd == "lock"); frame:EnableMouse(not db.locked)
    Print(db.locked and "locked (only shows in lava)." or "unlocked - drag the box.")
  elseif cmd == "scale" and n and n >= 0.5 and n <= 3 then
    db.scale = n; frame:SetScale(n)
  elseif cmd == "test" then
    S.test = { untilT = GetTime() + 10, fakeNext = GetTime() + 1.0,
               saved = { S.groundDeltas, S.landDeltas, S.errReset, S.errPhase },
               savedLearned = db.learned }
    S.groundDeltas, S.landDeltas, S.errReset, S.errPhase = {}, {}, {}, {}
    db.learned = { airtime = db.learned.airtime }
    Print("10 seconds of fake lava (1s ticks, a jump restarts the timer). Stand still for 2 ticks, then jump on JUMP!")
  elseif cmd == "stats" then
    local b = db.learned.bins or {}
    Print(string.format("%d jumps learned (%d needed for the zone)", JumpCount(), MIN_JUMPS))
    for i = 0, NB - 1 do
      local c = b[i]
      if c and c.d + c.h > 0 then
        Print(string.format("  jumped %.1f-%.1fs before: %d dodged, %d hit", i * BIN, (i + 1) * BIN, c.d, c.h))
      end
    end
    local e, l = Window()
    Print(string.format("green zone: %.2f-%.2fs before the tick%s", e, l, LearnedZone() and " (learned)" or " (starting guess)"))
  elseif cmd == "forget" then
    ResetLearning(); Print("forgot the measured timings.")
  elseif cmd == "strict" and (arg == "on" or arg == "off") then
    db.strict = (arg == "on")
    Print(db.strict and "lava only: starts after 2 hits on the lava rhythm." or "any fire hit starts the bar.")
  elseif cmd == "debug" then
    db.debug = not db.debug; Print("debug " .. (db.debug and "on" or "off") .. ".")
  else
    Help()
  end
end

-- for tests
LavaHop_Internal = { S = S, Window = Window, LearnedZone = LearnedZone, Airtime = Airtime, NextTick = NextTick, Interval = Interval, FirstDelay = FirstDelay, Model = Model }
