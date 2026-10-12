--!nonstrict
--[[
	Gpu - the Z32 graphics unit (docs/05-soc.md section 3, docs/06-gpu-avalon.md).

	The CPU never calls the GPU. It writes commands into RAM and kicks the queue
	by writing one MMIO register. The host drains the queue once per CPU budget.

	Also includes Avalon R1's adaptive resolution controller (`setResolutionScale`,
	`adapt`) and multi-tile rasterisation (`tileCount`).

	Registers, at Gpu.PAGE:
		+0x00  queue base address
		+0x04  queue length in commands
		+0x08  kick, write 1 to run the queue; reads 1 while commands are pending
		+0x0C  status: 0 idle, 1 pending, 2 done
		+0x10  commands run (stat)
		+0x14  triangles submitted (stat)
		+0x18  fragments written (stat)
		+0x1C  near plane, as float bits
		+0x20  colour buffer address
		+0x24  depth buffer address
		+0x28  scissor x
		+0x2C  scissor y
		+0x30  scissor width
		+0x34  scissor height
		+0x38  tile count (1 = single-tile, >1 = tiled raster + bulk composite)
		+0x3C  resolution scale, as float bits
]]

local Raster = require(script.Parent.Raster)

local Gpu = {}
Gpu.__index = Gpu

Gpu.PAGE = 0x0F006000
Gpu.COMMAND_SIZE = 48
Gpu.MAX_QUEUE_COMMANDS = 256

Gpu.OP = {
	NOP = 0,
	CLEAR = 1,
	SET_DEPTH = 2,
	DRAW_MESH = 3,
	PRESENT = 4,
	SET_COLOUR = 5,
}

local F_OP = 0x00
local F_SRC = 0x04
local F_DST = 0x08
local F_COUNT = 0x0C
local F_MATRIX = 0x10
local F_TEXTURE = 0x14
local F_SHADING = 0x18
local F_FLAGS = 0x1C
local F_X = 0x20
local F_Y = 0x24
local F_W = 0x28
local F_H = 0x2C

local function round(n: number): number
	return math.floor(n + 0.5)
end

function Gpu.attach(memory, options)
	local self = setmetatable({}, Gpu)
	self.memory = memory
	self.framebuffer = options.framebuffer
	self.baseWidth = options.width
	self.baseHeight = options.height
	self.scale = options.resolutionScale or 1.0
	self.minScale = options.minScale or 0.35
	self.maxScale = options.maxScale or 1.0
	self.adaptive = options.adaptive ~= false
	self.targetFps = options.targetFps or 60
	self.width = math.max(4, round(self.baseWidth * self.scale))
	self.height = math.max(4, round(self.baseHeight * self.scale))
	self.ram = memory:getRam()
	self.colourAddress = options.colour or 0
	self.depthAddress = options.depth or 0
	self.raster = Raster.new(memory, self.width, self.height, self.ram, self.ram, self.colourAddress, self.depthAddress)
	self.raster:setScissor(0, 0, self.width, self.height)
	self.queueBase = 0
	self.queueCount = 0
	self.pending = false
	self.status = 0
	self.queueFaults = 0
	self.near = 0.0001
	self.commandsRun = 0
	self.tileCount = 1
	self.scissorX = 0
	self.scissorY = 0
	self.scissorW = self.width
	self.scissorH = self.height
	self.scratch = buffer.create(4)
	self:setTileCount(options.tileCount or 1)

	if self.framebuffer ~= nil then
		self.framebuffer.width = self.width
		self.framebuffer.height = self.height
	end

	memory:registerDevice(Gpu.PAGE, {
		read32 = function(offset: number): number
			return self:readRegister(offset)
		end,
		write32 = function(offset: number, value: number)
			self:writeRegister(offset, value)
		end,
	})
	return self
end

function Gpu:floatBits(val: number): number
	buffer.writef32(self.scratch, 0, val)
	return buffer.readu32(self.scratch, 0)
end

function Gpu:bitsFloat(bits: number): number
	buffer.writeu32(self.scratch, 0, bits)
	return buffer.readf32(self.scratch, 0)
end

function Gpu:nearBits(): number
	return self:floatBits(self.near)
end

function Gpu:setNearBits(bits: number)
	self.near = self:bitsFloat(bits)
end

function Gpu:setTileCount(tiles: number)
	if tiles ~= tiles or tiles == math.huge or tiles == -math.huge then
		return
	end
	self.tileCount = math.clamp(math.floor(tiles), 1, math.max(1, math.min(64, self.height)))
end

--- Change the internal rendering resolution scale (Avalon R1 adaptive scale).
function Gpu:setResolutionScale(scale: number): (number, number)
	if scale ~= scale or scale == math.huge or scale == -math.huge then
		return self.width, self.height
	end
	local clamped = math.clamp(scale, self.minScale, self.maxScale)
	self.scale = clamped
	local w = math.max(4, round(self.baseWidth * clamped))
	local h = math.max(4, round(self.baseHeight * clamped))
	self.width = w
	self.height = h
	self.scissorX = 0
	self.scissorY = 0
	self.scissorW = w
	self.scissorH = h
	self.raster:resize(w, h)
	if self.framebuffer ~= nil then
		self.framebuffer.width = w
		self.framebuffer.height = h
	end
	return w, h
end

--- Adapt resolution scale from a measured frame time in seconds:
--- shrink by 0.85x when >125% of frame budget, grow by 1.08x when <70%.
function Gpu:adapt(frameSeconds: number): number
	if not self.adaptive then
		return self.scale
	end
	local budget = 1 / self.targetFps
	if frameSeconds > budget * 1.25 and self.scale > self.minScale then
		self:setResolutionScale(self.scale * 0.85)
	elseif frameSeconds < budget * 0.7 and self.scale < self.maxScale then
		self:setResolutionScale(self.scale * 1.08)
	end
	return self.scale
end

function Gpu:readRegister(offset: number): number
	if offset == 0x00 then
		return self.queueBase
	elseif offset == 0x04 then
		return self.queueCount
	elseif offset == 0x08 then
		return if self.pending then 1 else 0
	elseif offset == 0x0C then
		return self.status
	elseif offset == 0x10 then
		return self.commandsRun
	elseif offset == 0x14 then
		return self.raster.stats.triangles
	elseif offset == 0x18 then
		return self.raster.stats.drawn
	elseif offset == 0x1C then
		return self:nearBits()
	elseif offset == 0x20 then
		return self.colourAddress
	elseif offset == 0x24 then
		return self.depthAddress
	elseif offset == 0x28 then
		return self.scissorX
	elseif offset == 0x2C then
		return self.scissorY
	elseif offset == 0x30 then
		return self.scissorW
	elseif offset == 0x34 then
		return self.scissorH
	elseif offset == 0x38 then
		return self.tileCount
	elseif offset == 0x3C then
		return self:floatBits(self.scale)
	end
	return 0
end

function Gpu:writeRegister(offset: number, value: number)
	if offset == 0x00 then
		self.queueBase = value
	elseif offset == 0x04 then
		self.queueCount = value
	elseif offset == 0x08 then
		if value ~= 0 then
			self.pending = true
			self.status = 1
		end
	elseif offset == 0x0C then
		self.status = 0
	elseif offset == 0x1C then
		self:setNearBits(value)
	elseif offset == 0x20 then
		self.colourAddress = value
		self.raster.colourBase = value
	elseif offset == 0x24 then
		self.depthAddress = value
		self.raster.depthBase = value
	elseif offset == 0x28 then
		self.scissorX = value
	elseif offset == 0x2C then
		self.scissorY = value
	elseif offset == 0x30 then
		self.scissorW = value
	elseif offset == 0x34 then
		self.scissorH = value
	elseif offset == 0x38 then
		self:setTileCount(value)
	elseif offset == 0x3C then
		self:setResolutionScale(self:bitsFloat(value))
	end
end

--- Point the rasteriser at the region a command refers to.
function Gpu:applyScissor(command: number)
	local memory = self.memory
	local w = memory:read32(command + F_W)
	local h = memory:read32(command + F_H)
	if w == 0 or h == 0 then
		self.raster:setScissor(self.scissorX, self.scissorY, self.scissorW, self.scissorH)
	else
		self.raster:setScissor(memory:read32(command + F_X), memory:read32(command + F_Y), w, h)
	end
end

function Gpu:execute(command: number): boolean
	local memory = self.memory
	if not memory:containsRange(command, Gpu.COMMAND_SIZE) then
		return false
	end
	local op = memory:read32(command + F_OP)
	if op == Gpu.OP.NOP then
		return true
	elseif op == Gpu.OP.CLEAR then
		self.raster.colourBase = self.colourAddress
		self.raster.depthBase = self.depthAddress
		self:applyScissor(command)
		return self.raster:clear(memory:read32(command + F_SRC))
	elseif op == Gpu.OP.SET_COLOUR then
		self.colourAddress = memory:read32(command + F_SRC)
		self.raster.colourBase = self.colourAddress
		return true
	elseif op == Gpu.OP.SET_DEPTH then
		self.depthAddress = memory:read32(command + F_SRC)
		self.raster.depthBase = self.depthAddress
		return true
	elseif op == Gpu.OP.DRAW_MESH then
		local destination = memory:read32(command + F_DST)
		if destination == 0 then
			destination = self.colourAddress
		end
		self.raster.colourBase = destination
		self.raster.depthBase = self.depthAddress
		self:applyScissor(command)
		local mesh = memory:read32(command + F_SRC)
		local matrix = memory:read32(command + F_MATRIX)
		local shading = memory:read32(command + F_SHADING)
		local texture = memory:read32(command + F_TEXTURE)
		local cull = bit32.band(memory:read32(command + F_FLAGS), 1) ~= 0
		local _, accepted
		if self.tileCount > 1 then
			_, accepted = self.raster:drawMeshTiled(self.tileCount, mesh, matrix, shading, texture, cull, self.near)
		else
			_, accepted = self.raster:drawMesh(mesh, matrix, shading, texture, cull, self.near)
		end
		return accepted
	elseif op == Gpu.OP.PRESENT then
		if self.framebuffer ~= nil then
			self.framebuffer.presentRequested = true
		end
		return true
	end
	return false
end

--- Run a bounded guest command queue. Invalid descriptors or malformed commands
--- are rejected instead of allowing unbounded work or raw buffer exceptions.
function Gpu:pump(): number
	if not self.pending then
		return 0
	end
	self.pending = false
	if self.queueCount < 0 or self.queueCount % 1 ~= 0 or self.queueCount > Gpu.MAX_QUEUE_COMMANDS
		or (self.queueCount > 0 and not self.memory:containsRange(self.queueBase, self.queueCount * Gpu.COMMAND_SIZE))
	then
		self.queueFaults += 1
		self.status = 3
		return 0
	end

	self.raster.workRemaining = Raster.budgetFor(self.width, self.height)
	self.raster.workLimitHit = false
	local executed = 0
	local failed = false
	for index = 0, self.queueCount - 1 do
		executed += 1
		if not self:execute(self.queueBase + index * Gpu.COMMAND_SIZE) or self.raster.workLimitHit then
			self.queueFaults += 1
			failed = true
			break
		end
	end
	self.raster.workRemaining = nil
	self.commandsRun += executed
	self.status = if failed then 3 else 2
	return executed
end

function Gpu:resetStats()
	self.commandsRun = 0
	self.raster:resetStats()
end

return Gpu
