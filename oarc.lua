local component = require("component")
local term = require("term")
local event = require("event")
local keyboard = require("keyboard")

local running = true
local loopNum = 0

-- config
local refreshInterval = 1
local minPowerLevel = 85
local maxPowerLevel = 90
local emaAlphaFast = .75   --  0 < alpha < 1
local emaAlphaSlow = .25   --  0 < alpha < 1
local skippedAdjustmentsInRange = 5
-- /config

local prevState

local function init()
   term.clear()
end

function calcEma(newValue, prevEma, alpha)
   return prevEma + alpha * (newValue - prevEma)
end

function calcFastEma(newValue, prevEma)
   return calcEma(newValue, prevEma, emaAlphaFast)
end

function calcSlowEma(newValue, prevEma)
   return calcEma(newValue, prevEma, emaAlphaSlow)
end

local function adjustRods(change)
   local reactor = component.br_reactor
   local level = reactor.getControlRodLevel(0)
   local newLevel = level + change
   if(newLevel >= 0 and newLevel <= 100) then 
      reactor.setAllControlRodLevels(newLevel) 
   end
end

local function increaseHeat()
   adjustRods(-1)
end

local function decreaseHeat()
   adjustRods(1)
end

local function readReactorState()
   local r = component.br_reactor
   local reactor = {}
   reactor.component = r
   reactor.active = r.getActive()
   reactor.energyStored = r.getEnergyStored()
   reactor.maxEnergyStored = 10000000 -- no method for this atm, hard coded constant
   reactor.coreTemp = r.getFuelTemperature()
   reactor.caseTemp = r.getCasingTemperature()
   reactor.reactivity = r.getFuelReactivity()
   reactor.mbPerTick = r.getFuelConsumedLastTick()
   reactor.activelyCooled = r.isActivelyCooled()
   reactor.rodInsertion = r.getControlRodLevel(0)
   
   if(reactor.activelyCooled) then
      reactor.steamProduced = r.getHotFluidProducedLastTick()
      reactor.coolantLevel = (r.getCoolantAmount() / r.getCoolantAmountMax()) * 100
   else -- passively cooled
      reactor.rfPerTick = r.getEnergyProducedLastTick()
   end
   
   local xmin, ymin, zmin = r.getMinimumCoordinate()
   local xmax, ymax, zmax = r.getMaximumCoordinate()
   reactor.interiorVolume = (xmax-xmin-1)*(ymax-ymin-1)*(zmax-zmin-1)
   reactor.exteriorVolume = (xmax-xmin+1)*(ymax-ymin+1)*(zmax-zmin+1)
   
   return reactor
end

local function readCapacitorState()
   local c = component.capacitor_bank
   local cap = {}
   cap.energyStored = c.getEnergyStored()
   cap.maxEnergyStored = c.getMaxEnergyStored()
   --cap.avgDetla = c.getAverageChangePerTick()
   return cap
end

local function getState()
   local state = {}
   if(component.isAvailable("br_reactor") == false) then
      state.errorMsg = "No reactor connection"
      return
   elseif(component.br_reactor.getConnected() == false) then
      state.errorMsg = "Reactor multiblock is invalid"
      return
   end
   state.reactor = readReactorState()
   if(state.reactor.activelyCooled) then
      --[[
      readTurbineState()   
      if(reactor.mbPerTick ~= 0) then
         state.rfPerIngot = poweroutputsum / (reactor.mbPerTick / 1000)
      end
      ]]
   else -- if passively cooled
      if(state.reactor.mbPerTick ~= 0) then
         state.rfPerIngot = state.reactor.rfPerTick / (state.reactor.mbPerTick / 1000)
      end
   end
   
   if(component.isAvailable("capacitor_bank")) then
      state.cap = readCapacitorState()
      state.energyStored = state.cap.energyStored
      state.energyLevel = (state.cap.energyStored / state.cap.maxEnergyStored) * 100
   else
      state.energyStored = state.reactor.energyStored
      state.energyLevel = (state.reactor.energyStored / state.reactor.maxEnergyStored) * 100
   end
   
   if(prevState == nil) then -- to seed the EMA spin-up
      prevState = state 
      prevState.energyLevelFastEma = prevState.energyLevel
      prevState.energyLevelSlowEma = prevState.energyLevel
   end   

   state.energyLevelFastEma = calcFastEma(state.energyLevel, prevState.energyLevelFastEma)
   state.energyLevelSlowEma = calcSlowEma(state.energyLevel, prevState.energyLevelSlowEma)
   state.energyLevelDelta = state.energyLevelFastEma - state.energyLevelSlowEma

   return state
end

local function makeAdjustments(state)
   if(state.errorMsg ~= nil) then
      -- if anything is connected, shut it all off
      return;
   end
   
   if(state.reactor.activelyCooled) then
      -- adjust accordingly
   else  -- passively cooled
      -- try to get us within desired range, then try to hold steady
      if(state.energyLevelFastEma <= minPowerLevel) then
         if(state.energyLevelDelta <= 0) then increaseHeat() end
      elseif(state.energyLevelFastEma >= maxPowerLevel) then
         if(state.energyLevelDelta >= 0) then decreaseHeat() end
      elseif(loopNum % skippedAdjustmentsInRange == 0) then -- energy level within range, hold steady 
         if(state.energyLevelDelta < 0) then increaseHeat() end
         if(state.energyLevelDelta > 0) then decreaseHeat() end
      end
   end
end

------------------------------------------------
-- helpers 
------------------------------------------------

function comma_value(amount)
  local formatted = tostring(amount)
  while true do  
    formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
    if (k==0) then
      break
    end
  end
  return formatted
end

function round(val, decimal)
  if (decimal) then
    return math.floor( (val * 10^decimal) + 0.5) / (10^decimal)
  else
    return math.floor(val+0.5)
  end
end

function format_num(amount, decimal)
  local formatted, famount, remain

  decimal = decimal or 2  -- default 2 decimal places

  famount = math.abs(round(amount,decimal))
  famount = math.floor(famount)

  remain = round(math.abs(amount) - famount, decimal)

        -- comma to separate the thousands
  formatted = comma_value(famount)

        -- attach the decimal portion
  if (decimal > 0) then
    remain = string.sub(tostring(remain),3)
    formatted = formatted .. "." .. remain ..
                string.rep("0", decimal - string.len(remain))
  end

        -- if negative add "-"
  if (amount<0) then formatted = "-" .. formatted end

  return formatted
end


function setTextColor(color)
   local code
   if(color == "white") then code = 0xFFFFFF
   elseif(color == "green") then code = 0x009000
   elseif(color == "red") then code = 0xFF0000
   elseif(color == "yellow") then code = 0xBBBB00
   elseif(color == "purple") then code = 0xBB00BB
   elseif(color == "blue") then code = 0x0000FF
   end
   component.gpu.setForeground(code)
end

function writeRight(value)
   local width, height = component.gpu.getResolution()
   local pos, line = term.getCursor()
   local remaining = width - pos + 1 
   local length = string.len(tostring(value))
   local spaces = remaining - length
   term.write(string.rep(" ", spaces) .. value)
end
--------------------------------------------------------
--- /helpers
--------------------------------------------------------

local function renderDisplay(state)
   term.setCursor(1,1)
   if(state.errorMsg ~= nil) then
      setTextColor("red")
      print(state.errorMsg)
   end
   
   term.write("Reactor Status: ")
   if state.reactor.active then
      setTextColor("green")
      status = "Online"
   else
      setTextColor("red")
      status = "Offline"
   end
   writeRight(status)
   setTextColor("white")

   term.setCursor(1,2)
   term.write("Core Temp:")
   writeRight(round(state.reactor.coreTemp, 0) .. " C")

   term.setCursor(1,3)
   term.write("Case Temp:")
   writeRight(round(state.reactor.caseTemp, 0) .. " C")

   term.setCursor(1,4)
   term.write("Power Stored:")
   writeRight(round(state.energyLevel,0) .. "% " .. format_num(state.energyStored, 0) .. " RF", -1)

   term.setCursor(1,5)
   term.write("Generating:")
   setTextColor("yellow")
   writeRight(format_num(state.reactor.rfPerTick, 2) .. " RF/t")
   setTextColor("white")

   term.setCursor(1,6)
   term.write("Fuel Reactivity:")
   writeRight(format_num(state.reactor.reactivity, 2) .. "%")

   term.setCursor(1,7)
   term.write("Fuel Consumption:")
   writeRight(format_num(state.reactor.mbPerTick, 3) .. " mB/t")

   term.setCursor(1,8)
   term.write("Efficiency:")
   setTextColor("purple")
   if(state.rfPerIngot == nil) then
      writeRight("n/a   RF/ing")
   else
      writeRight(format_num(state.rfPerIngot,0) .. " RF/ing")
   end
   setTextColor("white")

   term.setCursor(1,9)
   term.write("Rod Insertion:")
   setTextColor("blue")
   writeRight(state.reactor.rodInsertion .. "%")
   setTextColor("white")
   
   term.setCursor(1,10)
   local statecopy = state
   statecopy.reactor = nil
   statecopy.cap = nil
   for k,v in pairs(statecopy) do print(k .. ":       " .. v) end
end

function getUserInput()
   _, _, _, c = event.pull(refreshInterval, "key_down")
   if c == keyboard.keys.enter or c == keyboard.keys.numpadenter then
      running = false
   end
end


init()
while running do
   loopNum = loopNum + 1
   state = getState()
   makeAdjustments(state)
   renderDisplay(state)
   getUserInput()
   prevState = state
end
