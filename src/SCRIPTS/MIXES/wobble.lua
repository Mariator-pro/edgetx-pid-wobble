-- =====================================================================
-- wobble.lua  --  EdgeTX Mix Script for automated PID-tuning wobbles
-- =====================================================================
-- SD card path: /SCRIPTS/MIXES/wobble.lua
-- =====================================================================

-- ----- Configuration (user-adjustable as needed) ---------------------

-- Control-point tables for the wobble curves (33 points, Y values in -100..+100).
-- Source: Kontext/wobblekurven.md. Static changes to the wobble amplitude are
-- made by editing these tables; an optional runtime scaling via the third
-- script input "AmpScale" is additionally available (see run() and the spec
-- section on amplitude scaling via source).
local ROLL_CURVE_Y = {
  --  1    2    3    4    5
      0,   0,   0,   0,   0,
  --  6    7    8    9   10
     50,   0, -50,   0,  50,
  -- 11   12   13   14   15
      0, -50,   0,  50,   0,
  -- 16   17   18   19   20
    -50,   0,   0,   0,   0,
  -- 21   22   23   24   25
      0, -50,   0,  50,   0,
  -- 26   27   28   29   30
    -50,   0,  50,   0, -50,
  -- 31   32   33
      0,  50,   0,
}

local PITCH_CURVE_Y = {
  --  1    2    3    4    5
      0,  50,   0, -50,   0,
  --  6    7    8    9   10
     50,   0, -50,   0,   0,
  -- 11   12   13   14   15
      0,   0,   0, -50,   0,
  -- 16   17   18   19   20
     50,   0, -50,   0,  50,
  -- 21   22   23   24   25
      0, -50,   0,  50,   0,
  -- 26   27   28   29   30
      0,   0,   0,   0,  50,
  -- 31   32   33
      0, -50,   0,
}

-- Whitelist of accepted flight-mode substrings (sensor "FM").
-- "ANGL" covers Betaflight + INAV (including "ANGL*" when armed).
-- "STAB" covers ArduPilot Copter Stabilize.
local ANGLE_MODE_TOKENS = { "ANGL", "STAB" }

-- Stick-override threshold: when |value| > THRESHOLD on either the Roll or
-- Pitch stick, the wobble pauses (pilot correction takes precedence).
-- 205 corresponds to roughly 20% of the EdgeTX scale (-1024..+1024).
local STICK_OVERRIDE_THRESHOLD = 205

-- Stick-override release cooldown: once the sticks return centered, the
-- wobble stays paused for this duration so the pilot can re-stabilise the
-- copter before the next cycle starts.
local STICK_OVERRIDE_COOLDOWN_MS    = 2000
local STICK_OVERRIDE_COOLDOWN_TICKS = STICK_OVERRIDE_COOLDOWN_MS / 10

-- ----- Constants -----------------------------------------------------

local CYCLE_MS     = 3000              -- Cycle length in ms
local CYCLE_TICKS  = CYCLE_MS / 10     -- getTime() returns 10-ms ticks
local SWEEP_MIN    = -1024
local SWEEP_MAX    =  1024
local SWEEP_RANGE  = SWEEP_MAX - SWEEP_MIN
local OUTPUT_SCALE = 1024 / 100        -- Curve Y (-100..+100) -> EdgeTX (-1024..+1024)

-- Amplitude scaling via the "AmpScale" input: linearly mapped around 1.0.
-- AmpScale = -1024 -> factor 0.5 (-50% amplitude), +1024 -> 1.5 (+50%).
local SCALE_HALFRANGE = 0.5
local SCALE_MIN       = 1.0 - SCALE_HALFRANGE
local SCALE_MAX       = 1.0 + SCALE_HALFRANGE

-- ----- Persistent state (closure persistence across reload) ----------

local enabled            = false   -- Enable flag (set by EnableSwitch edge)
local prevEnableRaw      = nil     -- nil until the first tick (see spec)
local cycleStartTicks    = nil     -- 10-ms tick of the current cycle start; nil = not running
local stickOverrideTicks = nil     -- Most recent tick a stick override was active; nil after the cooldown expired

-- ----- Curve handling ------------------------------------------------

-- Cubic Hermite interpolation equivalent to Catmull-Rom
-- (matches the smoothing of EdgeTX custom curves with Smoothing=On).
local function hermite(p0, p1, p2, p3, t)
  local t2 = t * t
  local t3 = t2 * t
  local m1 = (p2 - p0) * 0.5
  local m2 = (p3 - p1) * 0.5
  return (2*t3 - 3*t2 + 1) * p1
       + (t3  - 2*t2 + t)  * m1
       + (-2*t3 + 3*t2)    * p2
       + (t3  - t2)        * m2
end

-- Applies the given control-point table to a sweep value in [-1024..+1024]
-- and returns the Y value in curve scale (-100..+100).
local function applyCurve(y, sweep)
  local n = #y
  if n < 2 then return y[1] or 0 end

  -- Map sweep to point index [1..n].
  local pos = (sweep - SWEEP_MIN) / SWEEP_RANGE * (n - 1) + 1
  if pos <= 1 then return y[1] end
  if pos >= n then return y[n] end

  local i  = math.floor(pos)
  local t  = pos - i
  local p0 = y[i - 1] or y[i]
  local p1 = y[i]
  local p2 = y[i + 1]
  local p3 = y[i + 2] or y[i + 1]
  return hermite(p0, p1, p2, p3, t)
end

-- ----- Safety checks -------------------------------------------------

local function isAngleMode()
  local fm = getValue("FM")
  if type(fm) ~= "string" or fm == "" then
    -- Sensor missing, telemetry loss, or numeric value -> fail-safe.
    return false
  end
  for i = 1, #ANGLE_MODE_TOKENS do
    if string.find(fm, ANGLE_MODE_TOKENS[i], 1, true) then
      return true
    end
  end
  return false
end

-- Stick-override check: returns true when both sticks (Roll/Pitch) are
-- within the threshold. EdgeTX trims are already baked into the values
-- (post-trim, pre-mixer).
local function isStickCentered()
  return math.abs(getValue("ail")) <= STICK_OVERRIDE_THRESHOLD
     and math.abs(getValue("ele")) <= STICK_OVERRIDE_THRESHOLD
end

-- ----- Main loop (mix-script tick, ~30 Hz) ---------------------------

local function run(enableRaw, wobbleRaw, ampScaleRaw)
  -- First tick after (re-)load: store reference, NO edge evaluation.
  if prevEnableRaw == nil then
    prevEnableRaw = enableRaw
    return 0, 0
  end

  -- Evaluate the enable switch as edge-triggered.
  if prevEnableRaw <= 0 and enableRaw > 0 then
    enabled = true
  elseif prevEnableRaw > 0 and enableRaw <= 0 then
    enabled = false
  end
  prevEnableRaw = enableRaw

  -- Activation switch is level-triggered (threshold > 0).
  local wobbleOn = wobbleRaw > 0

  -- Track stick-override release. While the sticks are outside the
  -- threshold, refresh stickOverrideTicks every tick; once they return
  -- centered the value freezes at the release tick and acts as the
  -- cooldown anchor.
  local now            = getTime()
  local sticksCentered = isStickCentered()
  if not sticksCentered then
    stickOverrideTicks = now
  end

  -- Stick-override cooldown: stay paused for STICK_OVERRIDE_COOLDOWN_TICKS
  -- after release so the pilot can re-stabilise before the next cycle.
  local cooldownActive = false
  if stickOverrideTicks ~= nil then
    if now - stickOverrideTicks < STICK_OVERRIDE_COOLDOWN_TICKS then
      cooldownActive = true
    else
      stickOverrideTicks = nil
    end
  end

  -- Four-condition interlock plus post-release cooldown. On any failure:
  -- immediately 0/0, reset cycle.
  if not (enabled and wobbleOn and isAngleMode() and sticksCentered)
     or cooldownActive then
    cycleStartTicks = nil
    return 0, 0
  end

  -- Active state: start or continue the cycle.
  if cycleStartTicks == nil then
    cycleStartTicks = now
  end

  -- Endless run: after point 33 wrap seamlessly back to point 1 within the
  -- same tick. The loop guards against dropped ticks spanning multiple cycles.
  local elapsedTicks = now - cycleStartTicks
  while elapsedTicks >= CYCLE_TICKS do
    cycleStartTicks = cycleStartTicks + CYCLE_TICKS
    elapsedTicks    = now - cycleStartTicks
  end

  local sweep  = SWEEP_MIN + (elapsedTicks * 10 / CYCLE_MS) * SWEEP_RANGE
  local rollY  = applyCurve(ROLL_CURVE_Y,  sweep)
  local pitchY = applyCurve(PITCH_CURVE_Y, sweep)

  -- Optional amplitude scaling. Unassigned source -> ampScaleRaw=0 ->
  -- scale=1.0 (current behavior). Clamping guards against sources with
  -- an extended value range (e.g. GVARs beyond +/-1024).
  local scale = 1.0 + (ampScaleRaw / 1024) * SCALE_HALFRANGE
  if scale < SCALE_MIN then scale = SCALE_MIN
  elseif scale > SCALE_MAX then scale = SCALE_MAX end

  return rollY * scale * OUTPUT_SCALE, pitchY * scale * OUTPUT_SCALE
end

return {
  input = {
    { "Enable", SOURCE },   -- EnableSwitch (enable, edge-triggered)
    { "Wobble", SOURCE },   -- WobbleSwitch (activation, level-triggered)
    { "AmpScale", SOURCE }, -- AmpScale (optional, -1024..+1024 -> 0.5x..1.5x)
  },
  output = { "Roll", "Pitch" },
  run = run,
}
