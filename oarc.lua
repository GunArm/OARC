local component = require("component")
local term = require("term")
local event = require("event")
local keyboard = require("keyboard")

local running = true

local refreshInterval = 1

local function init()
end

local function readReactorState()
   local r = component.br_reactor
   local reactor = {}
   reactor.component = r
   reactor.active = r.getActive()
   reactor.energyStored = r.getEnergyStored()
   reactor.coreTemp = r.getFuelTemperature()
   reactor.caseTemp = r.getCasingTemperature()
   reactor.reactivity = r.getFuelReactivity()
   reactor.mbPerTick = r.getFuelConsumedLastTick()
   reactor.activelyCooled = r.isActivelyCooled()
   reactor.rodInsertion = r.getControlRodLevel(0)
   
   if(reactor.activelyCooled) then
      reactor.steamProduced = r.getHotFluidProducedLastTick()
      reactor.coolantLevel = r.getCoolantAmount() / r.getCoolantAmountMax()
   else -- passively cooled
      reactor.rfPerTick = r.getEnergyProducedLastTick()
   end
   
   local xmin, ymin, zmin = r.getMinimumCoordinate()
   local xmax, ymax, zmax = r.getMaximumCoordinate()
   reactor.interiorVolume = (xmax-xmin-1)*(ymax-ymin-1)*(zmax-zmin-1)
   reactor.exteriorVolume = (xmax-xmin+1)*(ymax-ymin+1)*(zmax-zmin+1)
   
   return reactor
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
   
   return state
end



local function makeAdjustments(state)
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

--------------------------------------------------------
--------------------------------------------------------

local function renderDisplay(state)
   term.setCursor(1,1)
   term.write("Reactor Status: ")

   if state.reactor.active then
      setTextColor("green")
      status = "       Online"
   else
      setTextColor("red")
      status = "      Offline"
   end

   term.write(status .. "        ")
   setTextColor("white")
   term.setCursor(1,2)
   term.write("Core Temp:             " .. round(state.reactor.coreTemp, 0) .. " C         ")
   term.setCursor(1,3)
   term.write("Case Temp:             " .. round(state.reactor.caseTemp, 0) .. " C         ")
   term.setCursor(1,4)
   term.write("Energy Buffer:           " .. format_num(state.reactor.energyStored, 0) .. " RF         ")
   term.setCursor(1,5)
   term.write("Energy Output: ")
   setTextColor("yellow")
   term.write(format_num(state.reactor.rfPerTick, 2) .. " RF/t         ")
   setTextColor("white")

   term.setCursor(1,6)
   term.write("Fuel Reactivity:      " .. format_num(state.reactor.reactivity, 2) .. "%         ")
   term.setCursor(1,7)
   term.write("Fuel Consumption:  " .. format_num(state.reactor.mbPerTick, 3) .. " mB/t         ")
   term.setCursor(1,8)
   term.write("Efficiency: ")
   setTextColor("purple")
   term.write(format_num(state.rfPerIngot,0) .. " RF/ing")
   setTextColor("white")
   term.setCursor(1,9)
   term.write("Rod Insertion:             ")
   setTextColor("blue")
   term.write(state.reactor.rodInsertion .. "%          ")
   setTextColor("white")
   
end

function getUserInput()
   _, _, _, c = event.pull(refreshInterval, "key_down")
   if c == keyboard.keys.enter or c == keyboard.keys.numpadenter then
      running = false
   end
end


init()
while running do
   state = getState()
   makeAdjustments(state)
   renderDisplay(state)
   os.sleep(1)
   getUserInput()
end
