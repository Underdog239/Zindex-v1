--!nonstrict
--[[
	Gpu - the Z32 graphics unit (docs/05-soc.md section 3, docs/06-gpu-avalon.md).

	The CPU never calls the GPU. It writes commands into RAM and kicks the queue
	by writing one MMIO register. The host drains the queue once per CPU budget.

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

	A command is 48 bytes, 12 words:
		+0x00 op      +0x04 src     +0x08 dst     +0x0C count
		+0x10 matrix  +0x14 texture +0x18 shading +0x1C flags
		+0x20 rectX   +0x24 rectY   +0x28 rectW   +0x2C rectH

	The colour and depth planes live in RAM, so the rasteriser writes straight
	into the guest's framebuffer with no intermediate copy.
]]

local Raster = require(script.Parent.Raster)

local Gpu = {}
Gpu.__index = Gpu

Gpu.PAGE = 0x0F006000
Gpu.COMMAND_SIZE = 48

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

function Gpu.attach(memory, options)
	local self = setmetatable({}, Gpu)
	self.memory = memory
	self.framebuffer = options.framebuffer
	self.width = options.width
	self.height = options.height
	self.ram = memory:getRam()
	self.colourAddress = options.colour or 0
	self.depthAddress = options.depth or 0
	self.raster = Raster.new(memory, self.width, self.height, self.ram, self.ram, self.colourAddress, self.depthAddress)
	self.raster:setScissor(0, 0, self.width, self.height)
	self.queueBase = 0
	self.queueCount = 0
	self.pending = false
	self.status = 0
	self.near = 0.0001
	self.commandsRun = 0
	self.scissorX = 0
	self.scissorY = 0
	self.scissorW = self.width
	self.scissorH = self.height
	self.scratch = buffer.create(4)

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

function Gpu:nearBits(): number
	buffer.writef32(self.scratch, 0, self.near)
	return buffer.readu32(self.scratch, 0)
end

function Gpu:setNearBits(bits: number)
	buffer.writeu32(self.scratch, 0, bits)
	self.near = buffer.readf32(self.scratch, 0)
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

function Gpu:execute(command: number)
	local memory = self.memory
	local op = memory:read32(command + F_OP)
	if op == Gpu.OP.NOP then
		return
	elseif op == Gpu.OP.CLEAR then
		self.raster.colourBase = self.colourAddress
		self.raster.depthBase = self.depthAddress
		self:applyScissor(command)
		self.raster:clear(memory:read32(command + F_SRC))
	elseif op == Gpu.OP.SET_COLOUR then
		self.colourAddress = memory:read32(command + F_SRC)
		self.raster.colourBase = self.colourAddress
	elseif op == Gpu.OP.SET_DEPTH then
		self.depthAddress = memory:read32(command + F_SRC)
		self.raster.depthBase = self.depthAddress
	elseif op == Gpu.OP.DRAW_MESH then
		local destination = memory:read32(command + F_DST)
		if destination == 0 then
			destination = self.colourAddress
		end
		self.raster.colourBase = destination
		self.raster.depthBase = self.depthAddress
		self:applyScissor(command)
		self.raster:drawMesh(
			memory:read32(command + F_SRC),
			memory:read32(command + F_MATRIX),
			memory:read32(command + F_SHADING),
			memory:read32(command + F_TEXTURE),
			bit32.band(memory:read32(command + F_FLAGS), 1) ~= 0,
			self.near
		)
	elseif op == Gpu.OP.PRESENT then
		if self.framebuffer ~= nil then
			self.framebuffer.presentRequested = true
		end
	end
end

--- Run every queued command. Called by the host once per CPU budget.
function Gpu:pump(): number
	if not self.pending then
		return 0
	end
	self.pending = false
	local executed = 0
	for index = 0, self.queueCount - 1 do
		self:execute(self.queueBase + index * Gpu.COMMAND_SIZE)
		executed += 1
	end
	self.commandsRun += executed
	self.status = 2
	return executed
end

function Gpu:resetStats()
	self.commandsRun = 0
	self.raster:resetStats()
end

return Gpu
