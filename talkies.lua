--
-- talkies
--
-- Copyright (c) 2017 twentytwoo, tanema
--
-- This library is free software; you can redistribute it and/or modify it
-- under the terms of the MIT license. See LICENSE for details.
--
local utf8 = require("utf8")

--  Substring function which gets a substring of `str` from character indices `start` to `stop`
--  Automatically calculates correct byte offsets
--  If `start` is nil, starts from index `1`
--  If `stop` is nil, stops at end of string
--
--    Modified from code by lhf
--    https://stackoverflow.com/a/43139063
function utf8.sub(str, start, stop)
  local strLength = utf8.len(str)
  local start = math.min(start or 1, strLength)
  start = utf8.offset(str, start)
  local stop = stop or strLength
  stop = math.min(stop, strLength)
  if stop == -1 then
    stop = strLength
  else
    stop = utf8.offset(str, stop + 1) - 1
  end
  return string.sub(str, start, stop)
end

local function playSound(sound, pitch)
  if type(sound) == "userdata" then
    sound:setPitch(pitch or 1)
    sound:play()
  end
end

local function parseSpeed(speed)
  if speed == "fast" then return 0.01
  elseif speed == "medium" then return 0.04
  elseif speed == "slow" then return 0.08
  else
    assert(tonumber(speed), "setSpeed() - Expected number, got " .. tostring(speed))
    return tonumber(speed)
  end
end

local function cloneColor(color)
  return {
    color[1] or 1,
    color[2] or 1,
    color[3] or 1,
    color[4] == nil and 1 or color[4],
  }
end

local function cloneStyle(style, tagName)
  return {
    color = cloneColor(style.color),
    font = style.font,
    speed = style.speed,
    tagName = tagName,
  }
end

local function sameRenderStyle(a, b)
  if a.font ~= b.font then
    return false
  end

  for i = 1, 4 do
    local av = a.color[i]
    local bv = b.color[i]
    if i == 4 then
      av = av == nil and 1 or av
      bv = bv == nil and 1 or bv
    end

    if av ~= bv then
      return false
    end
  end

  return true
end

local function parseHexColor(value)
  local hex = value:gsub("^#", "")
  if #hex ~= 6 and #hex ~= 8 then
    return nil
  end

  local red = tonumber(hex:sub(1, 2), 16)
  local green = tonumber(hex:sub(3, 4), 16)
  local blue = tonumber(hex:sub(5, 6), 16)
  if red == nil or green == nil or blue == nil then
    return nil
  end

  local color = {
    red / 255,
    green / 255,
    blue / 255,
  }

  if #hex == 8 then
    local alpha = tonumber(hex:sub(7, 8), 16)
    if alpha == nil then
      return nil
    end
    color[4] = alpha / 255
  else
    color[4] = 1
  end

  return color
end

local function findFirstCharacterSpeed(charSteps, defaultSpeed)
  local firstChar = charSteps[1]
  if firstChar ~= nil then
    return firstChar.speed
  end
  return defaultSpeed
end

local Fifo = {}
function Fifo.new () return setmetatable({first=1,last=0},{__index=Fifo}) end
function Fifo:peek() return self[self.first] end
function Fifo:len() return (self.last+1)-self.first end

function Fifo:push(value)
  self.last = self.last + 1
  self[self.last] = value
end

function Fifo:pop()
  if self.first > self.last then return end
  local value = self[self.first]
  self[self.first] = nil
  self.first = self.first + 1
  return value
end

local Typer = {}
local function isRichMessage(message)
  return type(message) == "table" and message._talkiesRich == true
end

local function addRenderText(message, text, style)
  if text == "" then
    return
  end

  local lastToken = message.renderTokens[#message.renderTokens]
  if lastToken ~= nil and lastToken.type == "text" and sameRenderStyle(lastToken.style, style) then
    lastToken.text = lastToken.text .. text
  else
    message.renderTokens[#message.renderTokens + 1] = {
      type = "text",
      text = text,
      style = style,
    }
  end

  for _, codepoint in utf8.codes(text) do
    local character = utf8.char(codepoint)
    message.visibleLength = message.visibleLength + 1
    message.charSteps[message.visibleLength] = {
      speed = style.speed,
      audible = character ~= " ",
    }
  end
end

local function addPause(message)
  local pauseIndex = message.visibleLength
  message.pauseCounts[pauseIndex] = (message.pauseCounts[pauseIndex] or 0) + 1
end

local function addNewline(message)
  message.renderTokens[#message.renderTokens + 1] = { type = "newline" }
end

local function tryHandleRichTag(rawTag, styleStack, message, context)
  local tag = rawTag:gsub("^%s+", ""):gsub("%s+$", "")
  if tag == "" then
    return false
  end

  local closingTag = tag:match("^/(%a+)$")
  if closingTag ~= nil then
    local currentStyle = styleStack[#styleStack]
    if #styleStack > 1 and currentStyle.tagName == closingTag then
      table.remove(styleStack)
      return true
    end
    return false
  end

  if tag == "pause" then
    addPause(message)
    return true
  elseif tag == "br" then
    addNewline(message)
    return true
  end

  local tagName, value = tag:match("^(%a+)%=(.+)$")
  if tagName == nil then
    return false
  end

  local currentStyle = styleStack[#styleStack]
  local nextStyle

  if tagName == "color" then
    local color = parseHexColor(value)
    assert(color ~= nil, "Talkies.rich() - Invalid color tag [" .. tag .. "]")
    nextStyle = cloneStyle(currentStyle, "color")
    nextStyle.color = color
  elseif tagName == "font" then
    local font = context.richFonts[value]
    assert(font ~= nil, "Talkies.rich() - Unknown rich font '" .. tostring(value) .. "'")
    nextStyle = cloneStyle(currentStyle, "font")
    nextStyle.font = font
  elseif tagName == "speed" then
    local ok, speed = pcall(parseSpeed, value)
    assert(ok, "Talkies.rich() - Invalid speed tag [" .. tag .. "]")
    nextStyle = cloneStyle(currentStyle, "speed")
    nextStyle.speed = speed
  else
    return false
  end

  styleStack[#styleStack + 1] = nextStyle
  return true
end

local function parseMessage(messageInput, context)
  local allowRichTags = false
  local source = messageInput

  if isRichMessage(messageInput) then
    allowRichTags = true
    source = messageInput.source
  end

  assert(type(source) == "string", "Talkies.say() - Expected message to be a string or Talkies.rich(...), got " .. type(source))

  local defaultStyle = {
    color = cloneColor(context.messageColor),
    font = context.font,
    speed = context.textSpeed,
  }

  local parsed = {
    renderTokens = {},
    charSteps = {},
    pauseCounts = {},
    visibleLength = 0,
  }

  local styleStack = { defaultStyle }
  local index = 1

  while index <= #source do
    local currentChar = source:sub(index, index)

    if allowRichTags and currentChar == "[" then
      local closeIndex = source:find("]", index, true)
      if closeIndex ~= nil then
        local rawTag = source:sub(index + 1, closeIndex - 1)
        if tryHandleRichTag(rawTag, styleStack, parsed, context) then
          index = closeIndex + 1
        else
          addRenderText(parsed, "[", styleStack[#styleStack])
          index = index + 1
        end
      else
        addRenderText(parsed, "[", styleStack[#styleStack])
        index = index + 1
      end
    elseif source:sub(index, index + 1) == "--" then
      addPause(parsed)
      index = index + 2
    elseif currentChar == "\n" then
      addNewline(parsed)
      index = index + 1
    else
      local stop = index
      while stop <= #source do
        local nextChar = source:sub(stop, stop)
        if nextChar == "\n" or source:sub(stop, stop + 1) == "--" or (allowRichTags and nextChar == "[") then
          break
        end
        stop = stop + 1
      end

      addRenderText(parsed, source:sub(index, stop - 1), styleStack[#styleStack])
      index = stop
    end
  end

  return parsed
end

local function newLayoutLine(defaultLineHeight)
  return {
    runs = {},
    width = 0,
    height = defaultLineHeight,
  }
end

local function appendLayoutRun(line, text, style)
  if text == "" then
    return
  end

  local width = style.font:getWidth(text)
  local length = utf8.len(text)
  local lastRun = line.runs[#line.runs]

  if lastRun ~= nil and sameRenderStyle(lastRun.style, style) then
    lastRun.text = lastRun.text .. text
    lastRun.width = lastRun.width + width
    lastRun.length = lastRun.length + length
  else
    line.runs[#line.runs + 1] = {
      text = text,
      style = style,
      width = width,
      length = length,
    }
  end

  line.width = line.width + width
  line.height = math.max(line.height, style.font:getHeight())
end

local function takeChunkThatFits(text, font, maxWidth)
  local chunk = ""
  local chunkWidth = 0

  for _, codepoint in utf8.codes(text) do
    local character = utf8.char(codepoint)
    local nextWidth = chunkWidth + font:getWidth(character)
    if chunk ~= "" and nextWidth > maxWidth then
      break
    end

    chunk = chunk .. character
    chunkWidth = nextWidth
  end

  if chunk == "" then
    local firstCharacter = utf8.sub(text, 1, 1)
    return firstCharacter, utf8.sub(text, 2, -1), font:getWidth(firstCharacter)
  end

  local chunkLength = utf8.len(chunk)
  local textLength = utf8.len(text)
  local rest = ""
  if chunkLength < textLength then
    rest = utf8.sub(text, chunkLength + 1, -1)
  end

  return chunk, rest, chunkWidth
end

local function layoutMessage(renderTokens, width, defaultLineHeight)
  local lines = { newLayoutLine(defaultLineHeight) }
  local currentLine = lines[1]

  local function startNewLine()
    currentLine = newLayoutLine(defaultLineHeight)
    lines[#lines + 1] = currentLine
  end

  local function placeText(text, style, isSpace)
    if text == "" then
      return
    end

    if isSpace then
      if currentLine.width == 0 then
        return
      end

      local textWidth = style.font:getWidth(text)
      if currentLine.width + textWidth <= width then
        appendLayoutRun(currentLine, text, style)
      else
        startNewLine()
      end
      return
    end

    local remaining = text
    while remaining ~= "" do
      local availableWidth = width - currentLine.width
      local remainingWidth = style.font:getWidth(remaining)

      if currentLine.width == 0 and remainingWidth <= width then
        appendLayoutRun(currentLine, remaining, style)
        remaining = ""
      elseif currentLine.width > 0 and remainingWidth <= availableWidth then
        appendLayoutRun(currentLine, remaining, style)
        remaining = ""
      elseif currentLine.width > 0 then
        startNewLine()
      else
        local chunk, rest = takeChunkThatFits(remaining, style.font, width)
        appendLayoutRun(currentLine, chunk, style)
        remaining = rest
        if remaining ~= "" then
          startNewLine()
        end
      end
    end
  end

  for _, token in ipairs(renderTokens) do
    if token.type == "newline" then
      startNewLine()
    else
      local currentText = ""
      local currentIsSpace = nil

      for _, codepoint in utf8.codes(token.text) do
        local character = utf8.char(codepoint)
        local isSpace = character == " " or character == "\t"

        if currentIsSpace == nil or currentIsSpace == isSpace then
          currentText = currentText .. character
        else
          placeText(currentText, token.style, currentIsSpace)
          currentText = character
        end

        currentIsSpace = isSpace
      end

      if currentText ~= "" then
        placeText(currentText, token.style, currentIsSpace)
      end
    end
  end

  local totalHeight = 0
  for _, line in ipairs(lines) do
    totalHeight = totalHeight + line.height
  end

  return {
    lines = lines,
    height = totalHeight,
  }
end

local function drawLayout(layout, visibleCount, x, y)
  local remaining = visibleCount
  local offsetY = 0

  for _, line in ipairs(layout.lines) do
    local lineX = x

    for _, run in ipairs(line.runs) do
      if remaining <= 0 then
        return
      end

      local charsToDraw = math.min(run.length, remaining)
      if charsToDraw > 0 then
        local text = run.text
        if charsToDraw < run.length then
          text = utf8.sub(run.text, 1, charsToDraw)
        end

        love.graphics.setFont(run.style.font)
        love.graphics.setColor(run.style.color)
        love.graphics.print(text, lineX, y + offsetY)

        lineX = lineX + run.style.font:getWidth(text)
        remaining = remaining - charsToDraw
      end
    end

    offsetY = offsetY + line.height
  end
end

function Typer.new(messageInput, context)
  local parsed = parseMessage(messageInput, context)
  local timeToType = findFirstCharacterSpeed(parsed.charSteps, context.textSpeed)

  return setmetatable({
    renderTokens = parsed.renderTokens,
    charSteps = parsed.charSteps,
    pauseCounts = parsed.pauseCounts,
    visibleLength = parsed.visibleLength,
    visibleCount = 0,
    complete = parsed.visibleLength == 0 and next(parsed.pauseCounts) == nil,
    paused = false,
    timer = timeToType,
    layout = nil,
    layoutWidth = nil,
    layoutDefaultLineHeight = nil,
  },{__index=Typer})
end

function Typer:resume()
  if not self.paused then return end
  self.paused = false
  self.complete = self.visibleCount >= self.visibleLength and self.pauseCounts[self.visibleCount] == nil
end

function Typer:finish()
  if self.complete then return end
  self.pauseCounts = {}
  self.visibleCount = self.visibleLength
  self.paused = false
  self.complete = true
end

function Typer:pauseAtCurrentBoundary()
  local pauseCount = self.pauseCounts[self.visibleCount]
  if pauseCount == nil then
    return false
  end

  if pauseCount == 1 then
    self.pauseCounts[self.visibleCount] = nil
  else
    self.pauseCounts[self.visibleCount] = pauseCount - 1
  end

  self.paused = true
  self.complete = false
  return true
end

function Typer:getLayout(width, defaultLineHeight)
  if self.layout == nil or self.layoutWidth ~= width or self.layoutDefaultLineHeight ~= defaultLineHeight then
    self.layout = layoutMessage(self.renderTokens, width, defaultLineHeight)
    self.layoutWidth = width
    self.layoutDefaultLineHeight = defaultLineHeight
  end

  return self.layout
end

function Typer:update(dt)
  local typed = false

  if self.complete then return typed end
  if not self.paused then
    if self:pauseAtCurrentBoundary() then
      return typed
    end

    self.timer = self.timer - dt
    while not self.paused and not self.complete and self.timer <= 0 do
      local nextChar = self.charSteps[self.visibleCount + 1]
      if nextChar == nil then
        self.complete = true
        break
      end

      typed = nextChar.audible
      self.visibleCount = self.visibleCount + 1

      self.timer = self.timer + nextChar.speed

      if self:pauseAtCurrentBoundary() then
        break
      end

      self.complete = self.visibleCount >= self.visibleLength
    end
  end

  return typed
end

local Talkies = {
  _VERSION     = '0.0.1',
  _URL         = 'https://github.com/tanema/talkies',
  _DESCRIPTION = 'A simple messagebox system for LÖVE',

  -- Theme
  indicatorCharacter      = ">",
  optionCharacter         = "-",
  padding                 = 10,
  talkSound               = nil,
  optionSwitchSound       = nil,
  inlineOptions           = true,
  richFonts               = {},
  
  titleColor              = {1, 1, 1},
  titleBackgroundColor    = nil,
  titleBorderColor        = nil,
  messageColor            = {1, 1, 1},
  messageBackgroundColor  = {0, 0, 0, 0.8},
  messageBorderColor      = nil,
  
  rounding                = 0,
  thickness               = 0,
  
  textSpeed               = 1 / 60,
  font                    = love.graphics.newFont(),

  typedNotTalked          = true,
  pitchValues             = {0.7, 0.8, 1.0, 1.2, 1.3},

  indicatorTimer          = 0,
  indicatorDelay          = 3,
  showIndicator           = false,
  dialogs                 = Fifo.new(),

  height                  = nil,
}

function Talkies.rich(message)
  assert(type(message) == "string", "Talkies.rich() - Expected string, got " .. type(message))

  return {
    _talkiesRich = true,
    source = message,
  }
end

function Talkies.say(title, messages, config)
  config = config or {}

  if type(messages) ~= "table" or isRichMessage(messages) then
    messages = { messages }
  end

  local font = config.font or Talkies.font
  local messageColor = config.messageColor or Talkies.messageColor
  local defaultSpeed = parseSpeed(config.textSpeed or Talkies.textSpeed)
  local richFonts = config.richFonts or Talkies.richFonts or {}
  local parseContext = {
    font = font,
    messageColor = messageColor,
    textSpeed = defaultSpeed,
    richFonts = richFonts,
  }

  local msgFifo = Fifo.new()
  for i=1, #messages do
    msgFifo:push(Typer.new(messages[i], parseContext))
  end

  -- Insert the Talkies.new into its own instance (table)
  local newDialog = {
    title         = title or "",
    messages      = msgFifo,
    image         = config.image,
    options       = config.options,
    onstart       = config.onstart or function(dialog) end,
    onmessage     = config.onmessage or function(dialog, left) end,
    oncomplete    = config.oncomplete or function(dialog) end,

    -- theme
    indicatorCharacter     = config.indicatorCharacter or Talkies.indicatorCharacter,
    optionCharacter        = config.optionCharacter or Talkies.optionCharacter,
    padding                = config.padding or Talkies.padding,
    rounding               = config.rounding or Talkies.rounding,
    thickness              = config.thickness or Talkies.thickness,
    talkSound              = config.talkSound or Talkies.talkSound,
    optionSwitchSound      = config.optionSwitchSound or Talkies.optionSwitchSound,
    inlineOptions          = config.inlineOptions == nil and Talkies.inlineOptions or config.inlineOptions,
    font                   = font,
    fontHeight             = font:getHeight(" "),
    typedNotTalked         = config.typedNotTalked == nil and Talkies.typedNotTalked or config.typedNotTalked,
    pitchValues            = config.pitchValues or Talkies.pitchValues,

    optionIndex   = 1,

    showOptions = function(dialog) return dialog.messages:len() == 1 and type(dialog.options) == "table" end,
    isShown     = function(dialog) return Talkies.dialogs:peek() == dialog end
  }
  
  newDialog.messageBackgroundColor = config.messageBackgroundColor or Talkies.messageBackgroundColor
  newDialog.titleBackgroundColor = config.titleBackgroundColor or Talkies.titleBackgroundColor or newDialog.messageBackgroundColor
  
  newDialog.messageColor = messageColor
  newDialog.titleColor = config.titleColor or Talkies.titleColor or newDialog.messageColor
  
  newDialog.messageBorderColor = config.messageBorderColor or Talkies.messageBorderColor or newDialog.messageBackgroundColor
  newDialog.titleBorderColor = config.titleBorderColor or Talkies.titleBorderColor or newDialog.messageBorderColor
  
  Talkies.dialogs:push(newDialog)
  if Talkies.dialogs:len() == 1 then
    Talkies.dialogs:peek():onstart()
  end

  return newDialog
end

function Talkies.update(dt)
  local currentDialog = Talkies.dialogs:peek()
  if currentDialog == nil then return end
  local currentMessage = currentDialog.messages:peek()

  if currentMessage.paused or currentMessage.complete then
    Talkies.indicatorTimer = Talkies.indicatorTimer + (10 * dt)
    if Talkies.indicatorTimer > Talkies.indicatorDelay then
      Talkies.showIndicator = not Talkies.showIndicator
      Talkies.indicatorTimer = 0
    end
  else
    Talkies.showIndicator = false
  end

  if currentMessage:update(dt) then
    if currentDialog.typedNotTalked then
      playSound(currentDialog.talkSound)
    elseif type(currentDialog.talkSound) == "userdata" and not currentDialog.talkSound:isPlaying() then
      local pitch = currentDialog.pitchValues[math.random(#currentDialog.pitchValues)]
      playSound(currentDialog.talkSound, pitch)
    end
  end
end

function Talkies.advanceMsg()
  local currentDialog = Talkies.dialogs:peek()
  if currentDialog == nil then return end
  currentDialog:onmessage(currentDialog.messages:len() - 1)
  if currentDialog.messages:len() == 1 then
    Talkies.dialogs:pop()
    currentDialog:oncomplete()
    if Talkies.dialogs:len() == 0 then
      Talkies.clearMessages()
    else
      Talkies.dialogs:peek():onstart()
    end
  end
  currentDialog.messages:pop()
end

function Talkies.isOpen()
  return Talkies.dialogs:peek() ~= nil
end

function Talkies.draw()
  local currentDialog = Talkies.dialogs:peek()
  if currentDialog == nil then return end

  local currentMessage = currentDialog.messages:peek()

  love.graphics.push()
  love.graphics.setDefaultFilter("nearest", "nearest")

  local function getDimensions()
    local canvas = love.graphics.getCanvas()
    if canvas then
      return canvas:getDimensions()
    end
    return love.graphics.getDimensions()
  end

  local windowWidth, windowHeight = getDimensions()
  
  love.graphics.setLineWidth(currentDialog.thickness)

  -- message box
  local boxW = windowWidth-(2*currentDialog.padding)
  local boxH = Talkies.height or (windowHeight/3)-(2*currentDialog.padding)
  local boxX = currentDialog.padding
  local boxY = windowHeight-(boxH+currentDialog.padding)

  -- image
  local imgX, imgY, imgW, imgScale = boxX+currentDialog.padding, boxY+currentDialog.padding, 0, 0
  if currentDialog.image ~= nil then
    imgScale = (boxH - (currentDialog.padding * 2)) / currentDialog.image:getHeight()
    imgW = currentDialog.image:getWidth() * imgScale
  end

  -- title box
  local textX, textY = imgX + imgW + currentDialog.padding, boxY + 4

  love.graphics.setFont(currentDialog.font)

  if currentDialog.title ~= "" then
    local titleBoxW = currentDialog.font:getWidth(currentDialog.title)+(2*currentDialog.padding)
    local titleBoxH = currentDialog.fontHeight+currentDialog.padding
    local titleBoxY = boxY-titleBoxH-(currentDialog.padding/2)
    local titleX, titleY = boxX + currentDialog.padding, titleBoxY + 2
    
    -- Message title
    love.graphics.setColor(currentDialog.titleBackgroundColor)
    love.graphics.rectangle("fill", boxX, titleBoxY, titleBoxW, titleBoxH, currentDialog.rounding, currentDialog.rounding)
    if currentDialog.thickness > 0 then
      love.graphics.setColor(currentDialog.titleBorderColor)
      love.graphics.rectangle("line", boxX, titleBoxY, titleBoxW, titleBoxH, currentDialog.rounding, currentDialog.rounding)
    end
    love.graphics.setColor(currentDialog.titleColor)
    love.graphics.print(currentDialog.title, titleX, titleY)
  end

  -- Main message box
  love.graphics.setColor(currentDialog.messageBackgroundColor)
  love.graphics.rectangle("fill", boxX, boxY, boxW, boxH, currentDialog.rounding, currentDialog.rounding)
  if currentDialog.thickness > 0 then
    love.graphics.setColor(currentDialog.messageBorderColor)
    love.graphics.rectangle("line", boxX, boxY, boxW, boxH, currentDialog.rounding, currentDialog.rounding)
  end

  -- Message avatar
  if currentDialog.image ~= nil then
    love.graphics.push()
      love.graphics.setColor(1, 1, 1)
      love.graphics.draw(currentDialog.image, imgX, imgY, 0, imgScale, imgScale)
    love.graphics.pop()
  end

  -- Message text
  love.graphics.setColor(currentDialog.messageColor)
  local textW = boxW - imgW - (4 * currentDialog.padding)
  local layout = currentMessage:getLayout(textW, currentDialog.fontHeight)

  drawLayout(layout, currentMessage.visibleCount, textX, textY)

  love.graphics.setFont(currentDialog.font)
  love.graphics.setColor(currentDialog.messageColor)

  -- Message options (when shown)
  if currentDialog:showOptions() and currentMessage.complete then
    if currentDialog.inlineOptions then
      local optionsY = textY + layout.height
      local optionLeftPad = currentDialog.font:getWidth(currentDialog.optionCharacter.." ")
      for k, option in pairs(currentDialog.options) do
        love.graphics.print(option[1], optionLeftPad+textX+currentDialog.padding, optionsY+((k-1)*currentDialog.fontHeight))
      end
      love.graphics.print(
        currentDialog.optionCharacter.." ",
        textX+currentDialog.padding,
        optionsY+((currentDialog.optionIndex-1)*currentDialog.fontHeight))
    else
      local optionWidth = 0
      
      local optionText = ""
      for k, option in pairs(currentDialog.options) do
        local newText = (currentDialog.optionIndex == k and currentDialog.optionCharacter or " ") .. " " .. option[1]
        optionWidth = math.max(optionWidth, currentDialog.font:getWidth(newText) )
        optionText = optionText .. newText .. "\n"
      end
      
      local optionsH = (currentDialog.font:getHeight() * #currentDialog.options)
      local optionsX = math.floor((windowWidth / 2) - (optionWidth / 2))
      local optionsY = math.floor((windowHeight / 3) - (optionsH / 2))
      
      love.graphics.setColor(currentDialog.messageBackgroundColor)
      love.graphics.rectangle("fill", optionsX - currentDialog.padding, optionsY - currentDialog.padding, optionWidth + currentDialog.padding * 2, optionsH + currentDialog.padding * 2, currentDialog.rounding, currentDialog.rounding)
      
      if currentDialog.thickness > 0 then
        love.graphics.setColor(currentDialog.messageBorderColor)
        love.graphics.rectangle("line", optionsX - currentDialog.padding, optionsY - currentDialog.padding, optionWidth + currentDialog.padding * 2, optionsH + currentDialog.padding * 2, currentDialog.rounding, currentDialog.rounding)
      end
      
      love.graphics.setColor(currentDialog.messageColor)
      love.graphics.print(optionText, optionsX, optionsY)
    end
  end

  -- Next message/continue indicator
  if Talkies.showIndicator then
    love.graphics.print(currentDialog.indicatorCharacter, boxX+boxW-(2.5*currentDialog.padding), boxY+boxH-currentDialog.fontHeight)
  end

  love.graphics.pop()

  -- Reset color so other draw operations won't be affected
  love.graphics.setColor(1, 1, 1, 1)
end

function Talkies.prevOption()
  local currentDialog = Talkies.dialogs:peek()
  if currentDialog == nil or not currentDialog:showOptions() then return end
  currentDialog.optionIndex = currentDialog.optionIndex - 1
  if currentDialog.optionIndex < 1 then currentDialog.optionIndex = #currentDialog.options end
  playSound(currentDialog.optionSwitchSound)
end

function Talkies.nextOption()
  local currentDialog = Talkies.dialogs:peek()
  if currentDialog == nil or not currentDialog:showOptions() then return end
  currentDialog.optionIndex = currentDialog.optionIndex + 1
  if currentDialog.optionIndex > #currentDialog.options then currentDialog.optionIndex = 1 end
  playSound(currentDialog.optionSwitchSound)
end

function Talkies.onAction()
  local currentDialog = Talkies.dialogs:peek()
  if currentDialog == nil then return end
  local currentMessage = currentDialog.messages:peek()

  if currentMessage.paused then currentMessage:resume()
  elseif not currentMessage.complete then currentMessage:finish()
  else
    if currentDialog:showOptions() then
      currentDialog.options[currentDialog.optionIndex][2]() -- Execute the selected function
      playSound(currentDialog.optionSwitchSound)
    end
    Talkies.advanceMsg()
  end
end

function Talkies.clearMessages()
  Talkies.dialogs = Fifo.new()
end

return Talkies
