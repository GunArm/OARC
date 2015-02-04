
init()
while Running do
   state = getState()
   makeAdjustments(state)
   renderDisplay(state)
   getUserInput()
end
