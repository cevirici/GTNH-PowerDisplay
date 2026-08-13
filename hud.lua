local graphics  = require('graphics')
local config    = require('config')
local events    = require('events')
local component = require('component')
local term      = require('term')
local glasses   = {}
local lscConfigs = config.LSCs or {
  {name = 'Left', address = '', color = config.primaryColor},
  {name = 'Right', address = '', color = 0xFFA500},
}

local function resolveLSCs()
  local available = {}
  local availableSet = {}
  local resolved = {}
  local used = {}

  for address in component.list('gt_machine', true) do
    table.insert(available, address)
    availableSet[address] = true
  end
  table.sort(available)

  if #available < #lscConfigs then
    error(string.format(
      'Found %d gt_machine component(s), but config.lua defines %d LSC(s). Check both adapters and cables.',
      #available,
      #lscConfigs
    ))
  end

  -- Reserve explicitly configured components first. This prevents an
  -- auto-detected entry from taking a component requested by a later entry.
  for index, lscConfig in ipairs(lscConfigs) do
    if lscConfig.address and lscConfig.address ~= '' then
      local address = component.get(lscConfig.address, 'gt_machine')
      if not address or not availableSet[address] then
        error(string.format(
          "Could not find gt_machine '%s' configured for %s.",
          lscConfig.address,
          lscConfig.name or ('LSC ' .. index)
        ))
      end
      if used[address] then
        error(string.format("gt_machine '%s' is assigned more than once.", address))
      end

      resolved[index] = address
      used[address] = true
    end
  end

  for index in ipairs(lscConfigs) do
    if not resolved[index] then
      for _, address in ipairs(available) do
        if not used[address] then
          resolved[index] = address
          used[address] = true
          break
        end
      end
    end
  end

  local lscs = {}
  for index, lscConfig in ipairs(lscConfigs) do
    table.insert(lscs, {
      name = lscConfig.name or ('LSC ' .. index),
      color = lscConfig.color or config.primaryColor,
      address = resolved[index],
      machine = component.proxy(resolved[index]),
      lastPercentage = nil,
    })
  end
  return lscs
end

local function readLSC(lsc)
  local scan = lsc.machine.getSensorInformation()
  local power
  local capacity

  if config.wirelessMode then
    power = tonumber((scan[23] or ''):gsub('%D', '')) or 0
    capacity = config.wirelessMax
  else
    power = lsc.machine.getEUStored()
    capacity = lsc.machine.getEUMaxStored()
  end

  local percentage = 0
  if capacity and capacity > 0 then
    percentage = math.max(0, math.min(power / capacity, 1))
  end

  local currentText = ''
  if config.showCurrentEU then
    if config.metric then
      currentText = graphics.metricParser(power)
    else
      currentText = graphics.scientificParser(power)
    end
  end

  local rate = ''
  if config.showRate and lsc.lastPercentage then
    rate = graphics.calcRate(percentage, lsc.lastPercentage, config.rateThreshold)
  end
  lsc.lastPercentage = percentage

  local capacityText = ''
  if config.showMaxEU then
    if config.metric then
      capacityText = graphics.metricParser(capacity)
    else
      capacityText = graphics.scientificParser(capacity)
    end
  end

  return {
    percentage = percentage,
    currentText = currentText,
    rate = rate,
    capacityText = capacityText,
    hasProblems = scan[17] and #scan[17] < 43,
  }
end

local function currentLabel(lsc, reading)
  local value = reading.currentText
  if reading.rate ~= '' then
    value = value .. ' ' .. reading.rate
  end
  if value ~= '' then
    return lsc.name .. ': ' .. value
  end
  return lsc.name
end

-- Initialization
term.clear()
graphics.fox()

local lscs = resolveLSCs()

print('LSC component assignment:')
for _, lsc in ipairs(lscs) do
  print(string.format('  %s -> %s', lsc.name, lsc.address))
end

for address in component.list('glasses') do
  table.insert(glasses, component.proxy(component.get(address)))
end

-- Configure Graphics
local l = config.length
local h = config.height
local b1 = config.borderBottom
local b2 = config.borderTop
local bottomY = config.resolution[2] / config.GUIscale
local rowPitch = h + b1 + b2 + (config.barSpacing or 0)

if not config.fullscreen then
  bottomY = bottomY - graphics.calcOffset(config.GUIscale)
end

for i = 1, #glasses do
  glasses[i].removeAll()
  glasses[i].bars = {}

  for lscIndex, lsc in ipairs(lscs) do
    local y = bottomY - rowPitch * (#lscs - lscIndex)
    local bar = {}

    -- Draw Static Shapes
    graphics.quad(glasses[i], {0, y-b1}, {3.5*h+l+b2+1, y-b1}, {2.5*h+l+1, y-b1-h-b2}, {0, y-b1-h-b2}, config.borderColor)
    graphics.quad(glasses[i], {0, y}, {3.5*h+l+b2+1, y}, {3.5*h+l+b2+1, y-b1}, {0, y-b1}, config.borderColor)
    graphics.quad(glasses[i], {3.5*h, y-b1}, {3.5*h+l, y-b1}, {2.5*h+l, y-b1-h}, {2.5*h, y-b1-h}, config.secondaryColor)

    -- Draw Energy Bar
    bar.energyBar = graphics.quad(glasses[i], {b2+3.25*h, y-b1}, {b2+3.25*h, y-b1}, {b2+2.25*h, y-b1-h}, {b2+2.25*h, y-b1-h}, lsc.color)
    bar.textPercent = graphics.text(glasses[i], 'X.X%', {0.5*h, y-b1-h/1.8-config.fontSize}, config.fontSize, lsc.color)
    bar.textCurr = graphics.text(glasses[i], lsc.name, {b2+3.25*h+1, y-b1-h/2-config.fontSize}, config.fontSize/1.3, config.textColor)
    bar.textMax = graphics.text(glasses[i], '', {-2.25*h+l, y-b1-h/2-config.fontSize}, config.fontSize/1.3, config.textColor)
    bar.textMaintenance = graphics.text(glasses[i], '', {b2+3.25*h+1, y-b1-h/2-config.fontSize}, config.fontSize/1.3, config.issueColor)
    bar.y = y

    glasses[i].bars[lscIndex] = bar
  end
end

-- Stand Ready for Exit Command
events.hookEvents()

-- ===== MAIN LOOP =====
while true do
  local readings = {}
  for index, lsc in ipairs(lscs) do
    readings[index] = readLSC(lsc)
  end

  for i = 1, #glasses do
    for lscIndex, lsc in ipairs(lscs) do
      local bar = glasses[i].bars[lscIndex]
      local reading = readings[lscIndex]
      local percentage = reading.percentage
      local y = bar.y

      -- Adjust Energy Bar
      bar.energyBar.setVertex(2, b2+3.25*h+l*percentage, y-b1)
      bar.energyBar.setVertex(3, b2+2.25*h+l*percentage, y-b1-h)

      if percentage > 0.999 then
        bar.textPercent.setText('100%')
        bar.textPercent.setPosition(b2+2.1*h-2*config.fontSize*(#bar.textPercent.getText()), y-b1-h/1.8-config.fontSize)
      else
        bar.textPercent.setText(string.format('%.1f%%', percentage*100))
        bar.textPercent.setPosition(b2+2*h-2*config.fontSize*(#bar.textPercent.getText()-1), y-b1-h/1.8-config.fontSize)
      end

      bar.textMax.setText(reading.capacityText)
      if reading.capacityText ~= '' then
        bar.textMax.setPosition(2.25*h+l-1.5*config.fontSize*(#reading.capacityText-1), y-b1-h/2-config.fontSize)
      end

      if reading.hasProblems then
        bar.textCurr.setText('')
        bar.textMaintenance.setText(lsc.name .. ': Has Problems!')
      else
        bar.textCurr.setText(currentLabel(lsc, reading))
        bar.textMaintenance.setText('')
      end
    end
  end

  -- Terminal Condition
  if events.needExit() then
    break
  end

  -- Pause
  os.sleep(config.sleep)
end

events.unhookEvents()
for i = 1, #glasses do
  glasses[i].removeAll()
end
