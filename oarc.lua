local component = require("component")
local term = require("term")
local event = require("event")
local keyboard = require("keyboard")

local running = true
local loopNum = 0

-- config
local refreshInterval = 1
local minDesiredFullness = .85
local maxDesiredFullness = .90
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

local function increaseThrottle()
   adjustRods(-1)
end

local function decreaseThrottle()
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

--[[
   local xmin, ymin, zmin = r.getMinimumCoordinate()
   local xmax, ymax, zmax = r.getMaximumCoordinate()
   reactor.interiorVolume = (xmax-xmin-1)*(ymax-ymin-1)*(zmax-zmin-1)
   reactor.exteriorVolume = (xmax-xmin+1)*(ymax-ymin+1)*(zmax-zmin+1)
   ]]

   return reactor
end

local function readCapacitorState()
   local c = component.capacitor_bank
   local cap = {}
   cap.energyStored = c.getEnergyStored()
   cap.maxEnergyStored = c.getMaxEnergyStored()
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
      state.maxEnergyStored = state.cap.maxEnergyStored
      state.energyFullness = state.cap.energyStored / state.maxEnergyStored
   else
      state.energyStored = state.reactor.energyStored
      state.maxEnergyStored = state.reactor.maxEnergyStored
      state.energyFullness = state.reactor.energyStored / state.maxEnergyStored
   end

   if(prevState == nil) then -- to seed the initial EMA spin-up at startup
      prevState = state
      prevState.energyStoredFastEma = prevState.energyStored
      prevState.energyStoredSlowEma = prevState.energyStored
   end

   state.energyStoredFastEma = calcFastEma(state.energyStored, prevState.energyStoredFastEma)
   state.energyStoredSlowEma = calcSlowEma(state.energyStored, prevState.energyStoredSlowEma)
   state.energyStoredDelta = state.energyStoredFastEma - state.energyStoredSlowEma

   return state
end

local function makeAdjustments(state)
   if(state.errorMsg ~= nil) then
      -- if anything is connected, shut it all off
      return;
   end
   state.adjustment = "n/a"
   state.adjustmentColor = "white"
   if(state.reactor.activelyCooled) then
      -- adjust accordingly
   else  -- passively cooled
      -- try to get us within desired range, then try to hold steady
      if(state.energyStoredFastEma <= minDesiredFullness * state.maxEnergyStored) then
         if(state.energyStoredDelta <= 0) then
            increaseThrottle()
            state.adjustmentColor = "red"
            state.adjustment = "Increasing throttle"
         else
            -- no adjustment
            state.adjustmentColor = "green"
            state.adjustment = "Rising toward range"
         end
      elseif(state.energyStoredFastEma >= maxDesiredFullness * state.maxEnergyStored) then
         if(state.energyStoredDelta >= 0) then
            decreaseThrottle()
            state.adjustmentColor = "red"
            state.adjustment = "Decreasing throttle"
         else
            -- no adjustment
            state.adjustmentColor = "green"
            state.adjustment = "Lowering toward range"
         end
      else
         state.adjustmentColor = "white"
         state.adjustment = "Maintaining Range"
         if(loopNum % skippedAdjustmentsInRange == 0) then -- energy within range, hold steady
            if(state.energyStoredDelta < 0) then increaseThrottle() end
            if(state.energyStoredDelta > 0) then decreaseThrottle() end
         end
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
   elseif(color == "orange") then code = 0xFF8000
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
   line = 1
   term.setCursor(1,line)
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

   line = line + 1
   term.setCursor(1,line)
   term.write("Power Stored:")
   writeRight(round(state.energyFullness * 100,2) .. "%  " .. format_num(state.energyStored, 0) .. " RF")

   line = line + 1
   term.setCursor(1,line)
   term.write("Generating:")
   setTextColor("yellow")
   writeRight(format_num(state.reactor.rfPerTick, 0) .. " RF/t")
   setTextColor("white")

--[[
   -- this will only be accurate if the reactor is the only thing charging the buffer
   line = line + 1
   term.setCursor(1,line)
   term.write("Load:")
   setTextColor("orange")
   writeRight("(~) " .. format_num(state.reactor.rfPerTick - state.energyStoredDelta, 0) .. " RF/t")
   setTextColor("white")
]]
   
   line = line + 1
   term.setCursor(1,line)
   term.write("Delta:")
   --setTextColor((state.energyStoredDelta >= 0) and "green" or "red"))
   writeRight(format_num(state.energyStoredDelta, 2) .. " RF/t")
   --setTextColor("white")

   line = line + 1
   term.setCursor(1,line)
   term.write("Throttle:")
   setTextColor("blue")
   writeRight(100 - state.reactor.rodInsertion .. "%")
   setTextColor("white")

   line = line + 1
   term.setCursor(1,line)
   term.write("Status:")
   setTextColor(state.adjustmentColor)
   writeRight(state.adjustment)
   setTextColor("white")

   line = line + 2
   term.setCursor(1,line)
   term.write("Core Temp:")
   writeRight(round(state.reactor.coreTemp, 0) .. " C")

--[[
   line = line + 1
   term.setCursor(1,line)
   term.write("Case Temp:")
   writeRight(round(state.reactor.caseTemp, 0) .. " C")
   ]]

   line = line + 1
   term.setCursor(1,line)
   term.write("Fuel Reactivity:")
   writeRight(format_num(state.reactor.reactivity, 0) .. "%")

   line = line + 1
   term.setCursor(1,line)
   term.write("Fuel Consumption:")
   writeRight(format_num(state.reactor.mbPerTick, 3) .. " mB/t")

   line = line + 1
   term.setCursor(1,line)
   term.write("Efficiency:")
   setTextColor("purple")
   if(state.rfPerIngot == nil) then
      writeRight("n/a   RF/ing")
   else
      writeRight(format_num(state.rfPerIngot,0) .. " RF/ing")
   end
   setTextColor("white")

--[[
   -- dump state values for debug
   line = line + 1
   term.setCursor(1,line)
   local statecopy = state
   statecopy.reactor = nil
   statecopy.cap = nil
   for k,v in pairs(statecopy) do print(k .. ":       " .. v) end
   ]]
end

function showInputOptions()
   term.clear()
   print("Options")
   print("")
   print("  q     -  quit")
   print("  pgUp  -  increase resolution")
   print("  pgDn  -  decrease resolution")
   getUserInput()
end

function adjustResolution(change)
   local maxWidth, maxHeight = component.gpu.maxResolution()
   local curWidth, curHeight = component.gpu.getResolution()
   local newWidth = curWidth * change
   local newHeight = curHeight * change
   newWidth = newWidth <= maxWidth and newWidth or curWidth
   newHeight = newHeight <= maxHeight and newHeight or curHeight
   component.gpu.setResolution(newWidth, newHeight)
end


local inputActions = {
   [keyboard.keys.q] = function() running = false end,
   [keyboard.keys.pageUp] = function() adjustResolution(.9) end,
   [keyboard.keys.pageDown] = function() adjustResolution(1.1) end
}


function getUserInput()
   _, _, _, key = event.pull(refreshInterval, "key_down")
   if key == nil then return end
   if type(inputActions[key]) ~= "function" then
      showInputOptions()
   else
      inputActions[key]()
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
