--!strict
--[[
	Memory - the Z32 address space.

	One byte-addressed `buffer` holds RAM. Above it sits a memory-mapped device
	window, and above that a trap page. Every access records its cycle cost, so
	the core never re-derives it and the timing contract stays in one place.

	Little-endian throughout, matching `buffer`'s own read/write helpers.
]]

local Memory = {}
Memory.__index = Memory

export type Device = {
	read8: ((offset: number) -> number)?,
	write8: ((offset: number, value: number) -> ())?,
	read16: ((offset: number) -> number)?,
	write16: ((offset: number, value: number) -> ())?,
	read32: ((offset: number) -> number)?,
	write32: ((offset: number, value: number) -> ())?,
}

export type Class = typeof(setmetatable(
	{} :: {
		ram: buffer,
		ramSize: number,
		devices: { [number]: Device },
		lastCost: number,
		faults: number,
		onTrap: ((reason: number, address: number) -> ())?,
	},
	Memory
))

local WRAP = 4294967296
local PAGE = 4096

Memory.RAM_BASE = 0x00000000
Memory.DEVICE_BASE = 0x0F000000
Memory.DEVICE_END = 0x10000000
Memory.TRAP_BASE = 0xFF000000

function Memory.new(ramSize: number): Class
	local self = setmetatable({}, Memory) :: any
	self.ramSize = ramSize
	self.ram = buffer.create(ramSize)
	self.devices = {}
	self.lastCost = 1
	self.faults = 0
	return self
end

--- Attach a device to a 4 KiB page, or to Memory.DEVICE_BASE to own the window.
function Memory:registerDevice(pageBase: number, device: Device)
	self.devices[pageBase] = device
end

function Memory:getRam(): buffer
	return self.ram
end

--- Copy bytes into RAM, e.g. a program image's data section.
function Memory:copyIn(address: number, source: buffer, sourceOffset: number?, count: number?)
	buffer.copy(self.ram, address, source, sourceOffset or 0, count)
end

local function resolve(self: Class, address: number): (Device?, number)
	local page = address - (address % PAGE)
	local device = self.devices[page]
	if device ~= nil then
		return device, address - page
	end
	local root = self.devices[Memory.DEVICE_BASE]
	if root ~= nil then
		return root, address - Memory.DEVICE_BASE
	end
	return nil, 0
end

local function isDevice(address: number): boolean
	return address >= Memory.DEVICE_BASE and address < Memory.DEVICE_END
end

function Memory:read8(address: number): number
	address = address % WRAP
	if address < self.ramSize then
		self.lastCost = 1
		return buffer.readu8(self.ram, address)
	end
	if isDevice(address) then
		self.lastCost = 4
		local device, offset = resolve(self, address)
		if device ~= nil and device.read8 ~= nil then
			return device.read8(offset)
		end
		return 0
	end
	self.lastCost = 4
	if self.onTrap ~= nil then
		self.onTrap(address, address)
	end
	return 0
end

function Memory:read16(address: number): number
	address = address % WRAP
	if address < self.ramSize then
		self.lastCost = 1
		return buffer.readu16(self.ram, address)
	end
	if isDevice(address) then
		self.lastCost = 4
		local device, offset = resolve(self, address)
		if device ~= nil and device.read16 ~= nil then
			return device.read16(offset)
		end
		return 0
	end
	self.lastCost = 4
	if self.onTrap ~= nil then
		self.onTrap(address, address)
	end
	return 0
end

function Memory:read32(address: number): number
	address = address % WRAP
	if address < self.ramSize then
		self.lastCost = 1
		return buffer.readu32(self.ram, address)
	end
	if isDevice(address) then
		self.lastCost = 4
		local device, offset = resolve(self, address)
		if device ~= nil and device.read32 ~= nil then
			return device.read32(offset)
		end
		return 0
	end
	self.lastCost = 4
	if self.onTrap ~= nil then
		self.onTrap(address, address)
	end
	return 0
end

function Memory:write8(address: number, value: number)
	address = address % WRAP
	if address < self.ramSize then
		self.lastCost = 1
		buffer.writeu8(self.ram, address, value % 256)
		return
	end
	if isDevice(address) then
		self.lastCost = 4
		local device, offset = resolve(self, address)
		if device ~= nil and device.write8 ~= nil then
			device.write8(offset, value % 256)
		end
		return
	end
	self.lastCost = 4
	self.faults += 1
end

function Memory:write16(address: number, value: number)
	address = address % WRAP
	if address < self.ramSize then
		self.lastCost = 1
		buffer.writeu16(self.ram, address, value % 65536)
		return
	end
	if isDevice(address) then
		self.lastCost = 4
		local device, offset = resolve(self, address)
		if device ~= nil and device.write16 ~= nil then
			device.write16(offset, value % 65536)
		end
		return
	end
	self.lastCost = 4
	self.faults += 1
end

function Memory:write32(address: number, value: number)
	address = address % WRAP
	if address < self.ramSize then
		self.lastCost = 1
		buffer.writeu32(self.ram, address, value % WRAP)
		return
	end
	if isDevice(address) then
		self.lastCost = 4
		local device, offset = resolve(self, address)
		if device ~= nil and device.write32 ~= nil then
			device.write32(offset, value % WRAP)
		end
		return
	end
	self.lastCost = 4
	self.faults += 1
end

function Memory:readf32(address: number): number
	address = address % WRAP
	if address < self.ramSize then
		self.lastCost = 1
		return buffer.readf32(self.ram, address)
	end
	self.lastCost = 4
	if self.onTrap ~= nil then
		self.onTrap(address, address)
	end
	return 0
end

function Memory:writef32(address: number, value: number)
	address = address % WRAP
	if address < self.ramSize then
		self.lastCost = 1
		buffer.writef32(self.ram, address, value)
		return
	end
	self.lastCost = 4
	self.faults += 1
end

return Memory
