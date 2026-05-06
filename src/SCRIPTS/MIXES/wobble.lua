-- =====================================================================
-- wobble.lua  --  EdgeTX Mix Script for automated PID-tuning wobbles
-- =====================================================================
-- Vollstaendige Architektur- und Verhaltensbeschreibung: siehe CLAUDE.md
-- Pfad auf SD-Karte: /SCRIPTS/MIXES/wobble.lua
-- =====================================================================

-- ----- Konfiguration (vom Anwender bei Bedarf anpassbar) -------------

-- Stuetzpunkt-Tabellen der Wobble-Kurven (33 Punkte, Y-Werte in -100..+100).
-- Quelle: Kontext/wobblekurven.md. Statische Aenderungen der Wobble-Amplitude
-- erfolgen durch Editieren dieser Tabellen; eine optionale Laufzeit-Skalierung
-- ueber den dritten Script-Input "AmpScale" ist zusaetzlich verfuegbar (siehe
-- run() und Spec-Abschnitt "Amplituden-Skalierung per Quelle").
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

-- Whitelist der zulaessigen Flight-Mode-Substrings (Sensor "FM").
-- "ANGL" deckt Betaflight + INAV ab (inkl. "ANGL*" wenn armed).
-- "STAB" deckt ArduPilot-Copter Stabilize ab.
local ANGLE_MODE_TOKENS = { "ANGL", "STAB" }

-- Stick-Override-Schwelle: ab Betragswert > THRESHOLD auf Roll- ODER
-- Pitch-Stick pausiert der Wobble (Pilot-Korrektur hat Vorrang).
-- 205 entspricht ca. 20 % der EdgeTX-Skala (-1024..+1024).
local STICK_OVERRIDE_THRESHOLD = 205

-- ----- Konstanten ----------------------------------------------------

local CYCLE_MS     = 3000              -- Zykluslaenge in ms
local CYCLE_TICKS  = CYCLE_MS / 10     -- getTime() liefert 10-ms-Ticks
local SWEEP_MIN    = -1024
local SWEEP_MAX    =  1024
local SWEEP_RANGE  = SWEEP_MAX - SWEEP_MIN
local OUTPUT_SCALE = 1024 / 100        -- Curve-Y (-100..+100) -> EdgeTX (-1024..+1024)

-- Amplituden-Skalierung via "AmpScale"-Input: linear gemappt um 1.0 herum.
-- AmpScale = -1024 -> Faktor 0.5 (-50 % Amplitude),  +1024 -> 1.5 (+50 %).
local SCALE_HALFRANGE = 0.5
local SCALE_MIN       = 1.0 - SCALE_HALFRANGE
local SCALE_MAX       = 1.0 + SCALE_HALFRANGE

-- ----- Persistenter Zustand (Closure-Persistenz beim Reload) ---------

local enabled         = false   -- Freigabe (durch EnableSwitch-Flanke gesetzt)
local prevEnableRaw   = nil     -- nil bis zum ersten Tick (siehe Spec)
local cycleStartTicks = nil     -- 10-ms-Tick des aktuellen Zyklus-Starts; nil = nicht laufend

-- ----- Curve-Handling ------------------------------------------------

-- Catmull-Rom-aequivalente kubische Hermite-Interpolation
-- (entspricht dem Smoothing der EdgeTX-Custom-Curves bei Smoothing=Ein).
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

-- Wendet die uebergebene Stuetzpunkt-Tabelle auf einen Sweep-Wert
-- aus [-1024..+1024] an und liefert den Y-Wert in Curve-Skala (-100..+100).
local function applyCurve(y, sweep)
  local n = #y
  if n < 2 then return y[1] or 0 end

  -- Sweep auf Punktindex [1..n] mappen.
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

-- ----- Sicherheits-Checks --------------------------------------------

local function isAngleMode()
  local fm = getValue("FM")
  if type(fm) ~= "string" or fm == "" then
    -- Sensor fehlt, Telemetrie-Ausfall, oder numerischer Wert -> Fail-Safe.
    return false
  end
  for i = 1, #ANGLE_MODE_TOKENS do
    if string.find(fm, ANGLE_MODE_TOKENS[i], 1, true) then
      return true
    end
  end
  return false
end

-- Stick-Override-Check: liefert true, wenn beide Sticks (Roll/Pitch)
-- innerhalb der Schwelle liegen. Die EdgeTX-Trims sind in den Werten
-- bereits enthalten (post-Trim, pre-Mixer).
local function isStickCentered()
  return math.abs(getValue("ail")) <= STICK_OVERRIDE_THRESHOLD
     and math.abs(getValue("ele")) <= STICK_OVERRIDE_THRESHOLD
end

-- ----- Hauptschleife (Mix-Script-Tick, ~30 Hz) -----------------------

local function run(enableRaw, wobbleRaw, ampScaleRaw)
  -- Erster Tick nach (Re-)Load: Referenz speichern, KEINE Flankenauswertung.
  if prevEnableRaw == nil then
    prevEnableRaw = enableRaw
    return 0, 0
  end

  -- Freigabe-Schalter flankengetriggert auswerten.
  if prevEnableRaw <= 0 and enableRaw > 0 then
    enabled = true
  elseif prevEnableRaw > 0 and enableRaw <= 0 then
    enabled = false
  end
  prevEnableRaw = enableRaw

  -- Aktivierungs-Schalter level-getriggert (Schwelle > 0).
  local wobbleOn = wobbleRaw > 0

  -- Vier-Bedingungen-Verriegelung. Bei jedem Fail: sofort 0/0, Zyklus reset.
  if not (enabled and wobbleOn and isAngleMode() and isStickCentered()) then
    cycleStartTicks = nil
    return 0, 0
  end

  -- Aktiver Zustand: Zyklus starten oder fortsetzen.
  local now = getTime()
  if cycleStartTicks == nil then
    cycleStartTicks = now
  end

  -- Endlos-Lauf: nach Punkt 33 nahtlos im selben Tick zurueck zu Punkt 1.
  -- Schleife schuetzt vor verschluckten Ticks ueber mehrere Zyklen hinweg.
  local elapsedTicks = now - cycleStartTicks
  while elapsedTicks >= CYCLE_TICKS do
    cycleStartTicks = cycleStartTicks + CYCLE_TICKS
    elapsedTicks    = now - cycleStartTicks
  end

  local sweep  = SWEEP_MIN + (elapsedTicks * 10 / CYCLE_MS) * SWEEP_RANGE
  local rollY  = applyCurve(ROLL_CURVE_Y,  sweep)
  local pitchY = applyCurve(PITCH_CURVE_Y, sweep)

  -- Optionale Amplituden-Skalierung. Nicht zugewiesene Quelle -> ampScaleRaw=0
  -- -> scale=1.0 (heutiges Verhalten). Clamping schuetzt vor Quellen mit
  -- erweitertem Wertebereich (z. B. GVARs ueber +/-1024).
  local scale = 1.0 + (ampScaleRaw / 1024) * SCALE_HALFRANGE
  if scale < SCALE_MIN then scale = SCALE_MIN
  elseif scale > SCALE_MAX then scale = SCALE_MAX end

  return rollY * scale * OUTPUT_SCALE, pitchY * scale * OUTPUT_SCALE
end

return {
  input = {
    { "Enable", SOURCE },   -- EnableSwitch (Freigabe, flankengetriggert)
    { "Wobble", SOURCE },   -- WobbleSwitch (Aktivierung, level-getriggert)
    { "AmpScale", SOURCE }, -- AmpScale (optional, -1024..+1024 -> 0.5x..1.5x)
  },
  output = { "Roll", "Pitch" },
  run = run,
}
