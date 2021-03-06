-- Copyright (C) 2016 Pau Carré Cardona - All Rights Reserved
-- You may use, distribute and modify this code under the
-- terms of the Apache License v2.0 (http://www.apache.org/licenses/LICENSE-2.0.txt).

local torchFolder = require('paths').thisfile('..')
package.path = string.format("%s;%s/?.lua", os.getenv("LUA_PATH"), torchFolder)

require 'inn'
require 'optim'
require 'xlua'
local image = require 'image'
local torch = require 'torch'

local tiefvision_commons = require '0-tiefvision-commons/tiefvision_commons'

local bboxlib = {}

local function loadLocator(index)
  return torch.load(tiefvision_commons.modelPath('locatorconv-' .. index .. '.model'))
end

local function loadClassifier()
  return torch.load(tiefvision_commons.modelPath('classifier.model'))
end

local function loadEncoder()
  return torch.load(tiefvision_commons.modelPath('encoder.model'))
end

local function getBoundingBoxes(model, encodedInputs, index)
  local avg = torch.load(tiefvision_commons.modelPath('bbox-train-mean'))[index]
  local avgTensor = torch.Tensor(1):cuda()
  avgTensor[1] = avg
  local std = torch.load(tiefvision_commons.modelPath('bbox-train-std'))[index]
  local stdTensor = torch.Tensor(1):cuda()
  stdTensor[1] = std
  local output = model:forward(encodedInputs)
  output = output:transpose(1, 3)
  output = output:transpose(1, 2)
  local avgExt = torch.repeatTensor(avgTensor, output:size()[1], output:size()[2], 1)
  local stdExt = torch.repeatTensor(stdTensor, output:size()[1], output:size()[2], 1)
  local outputTrans = torch.cmul(output, stdExt) + avgExt
  return outputTrans
end

local function toOutputCoordinate(coord)
  return math.max(math.floor((math.floor((math.floor((coord - 10) / 4) - 2) / 2) - 2) / 2) - 2 + 1 - 10, 1)
end

local function toOutputCoordinates(x, y) --, reduction, xdelta, ydelta)
  --  local xo = math.floor((x - (xdelta / 2.0)) / reduction)
  --  local yo = math.floor((y - (ydelta / 2.0)) / reduction)
  --  if xo <= 0 then xo = 1 end
  --  if yo <= 0 then yo = 1 end
  --  return xo, yo
  return toOutputCoordinate(x), toOutputCoordinate(y)
end

local function toImageCoordinate(coord)
  return ((((((coord - 1 + 2 + 10) * 2) + 2) * 2) + 2) * 4) + 10 + 7 - 224
end

local function toImageCoordinates(x, y)
  return toImageCoordinate(x), toImageCoordinate(y)
end

local function meanBoundingBox(boundingBoxes)
  local sum = { 0.0, 0.0, 0.0, 0.0 }
  for i = 1, #boundingBoxes do
    local boundingBox = boundingBoxes[i]
    sum = { sum[1] + boundingBox[1], sum[2] + boundingBox[2], sum[3] + boundingBox[3], sum[4] + boundingBox[4] }
  end
  local mean = { sum[1] / #boundingBoxes, sum[2] / #boundingBoxes, sum[3] / #boundingBoxes, sum[4] / #boundingBoxes }
  return mean
end

local function boundingBoxOutputCenter(boundingBox)
  local xcenter = boundingBox[1] + ((boundingBox[3] - boundingBox[1]) / 2.0)
  local ycenter = boundingBox[2] + ((boundingBox[4] - boundingBox[2]) / 2.0)
  return toOutputCoordinates(xcenter, ycenter)
end

local function getExpectedBoundingBox(boundingBoxes)
  local mean = meanBoundingBox(boundingBoxes)
  local xcenter, ycenter = boundingBoxOutputCenter(mean)
  local eminx, eminy, emaxx, emaxy = 0.0, 0.0, 0.0, 0.0
  local eminxCount, eminyCount, emaxxCount, emaxyCount = 0, 0, 0, 0
  for i = 1, #boundingBoxes do
    local boundingBox = boundingBoxes[i]
    local minx, miny, maxx, maxy, xo, yo = boundingBox[1], boundingBox[2], boundingBox[3], boundingBox[4], boundingBox[6], boundingBox[7]
    if xo < xcenter then
      eminx = eminx + minx
      eminxCount = eminxCount + 1
    end
    if xo > xcenter then
      emaxx = emaxx + maxx
      emaxxCount = emaxxCount + 1
    end
    if yo < ycenter then
      eminy = eminy + miny
      eminyCount = eminyCount + 1
    end
    if yo > ycenter then
      emaxy = emaxy + maxy
      emaxyCount = emaxyCount + 1
    end
  end

  if eminxCount == 0 then
    eminx = mean[1]
    eminxCount = 1
  end
  if eminyCount == 0 then
    eminy = mean[2]
    eminyCount = 1
  end
  if emaxxCount == 0 then
    emaxx = mean[3]
    emaxxCount = 1
  end
  if emaxyCount == 0 then
    emaxy = mean[4]
    emaxyCount = 1
  end

  return eminx / eminxCount, eminy / eminyCount, emaxx / emaxxCount, emaxy / emaxyCount
end

local function cleanBoundingBox(x, y, imageW, imageH)
  if (x < 1) then
    x = 1
  elseif (x > imageW) then
    x = imageW
  end
  if (y < 1) then
    y = 1
  elseif (y > imageH) then
    y = imageH
  end
  return math.floor(x), math.floor(y)
end

local function getImageBoundingBox(x, y, bboxMinx, bboxMiny, bboxMaxx, bboxMaxy, imageW, imageH)
  local xbi, ybi = toImageCoordinates(x, y)
  local minx = xbi + bboxMinx[y][x][1]
  local miny = ybi + bboxMiny[y][x][1]
  local maxx = xbi + bboxMaxx[y][x][1]
  local maxy = ybi + bboxMaxy[y][x][1]
  minx, miny = cleanBoundingBox(minx, miny, imageW, imageH)
  maxx, maxy = cleanBoundingBox(maxx, maxy, imageW, imageH)
  return minx, miny, maxx, maxy
end

local function getEncodedInput(input)
  local encoder = loadEncoder()
  local encodedInput = encoder:forward(input)[2]
  return encodedInput, input:size()[3], input:size()[2]
end

local function locate(encodedInput, index)
  local locator = loadLocator(index)
  local boundingBoxes = getBoundingBoxes(locator, encodedInput, index)
  return boundingBoxes
end

local function getProbabilities(encodedInput)
  local classifier = loadClassifier()
  local classes = classifier:forward(encodedInput)
  return classes[1]
end

function bboxlib.loadImageFromFile(imagePath)
  local input = image.load(imagePath)
  return input
end

local function getInitialScales(input)
  local scaleBase
  if input:size()[2] > input:size()[3] then
    scaleBase = (1 * 224) / input:size()[3]
  else
    scaleBase = (1 * 224) / input:size()[2]
  end
  local scales = {}
  local numScales = 4
  for s = 1, numScales do
    scales[s] = s * scaleBase
  end
  return scales
end

local function getScaledImages(input, scales)
  local pyramidProc = {}
  local pyramid = image.gaussianpyramid(input, scales)
  for s = 1, #scales do
    pyramidProc[s] = tiefvision_commons.loadImage(pyramid[s])
  end
  return pyramidProc
end

local function getBboxes(input)
  local encodedInput = getEncodedInput(input)
  local bboxMinx = locate(encodedInput, 1)
  local bboxMiny = locate(encodedInput, 2)
  local bboxMaxx = locate(encodedInput, 3)
  local bboxMaxy = locate(encodedInput, 4)
  local probabilities = getProbabilities(encodedInput)
  local bboxes = {}
  local width = input:size()[3]
  local height = input:size()[2]
  local i = 1
  for x = 1, bboxMinx:size()[2] do
    for y = 1, bboxMinx:size()[1] do
      if (probabilities[y][x] > 0.85) then
        local xmin, ymin, xmax, ymax = getImageBoundingBox(x, y, bboxMinx, bboxMiny, bboxMaxx, bboxMaxy, width, height)
        bboxes[i] = { xmin, ymin, xmax, ymax, probabilities[y][x], x, y }
        i = i + 1
      end
    end
  end
  return bboxes, probabilities
end

local function getCroppedImage(input)
  local scale = getInitialScales(input)[2]
  local scaledImage = getScaledImages(input, { scale })[1]
  local bboxes, probabilities = getBboxes(scaledImage)
  local xminNew, yminNew, xmaxNew, ymaxNew = getExpectedBoundingBox(bboxes)
  return xminNew / scale, yminNew / scale, xmaxNew / scale, ymaxNew / scale
end

function bboxlib.getImageBoundingBoxesTable(input)
  local boundingBoxes = {}
  local xmin, ymin, xmax, ymax = getCroppedImage(input)
  table.insert(boundingBoxes, { xmin, ymin, xmax, ymax })
  return boundingBoxes
end

return bboxlib
