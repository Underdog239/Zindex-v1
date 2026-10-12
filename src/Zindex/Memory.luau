--!strict
--!native
--[[
	Memory - the Z32 address space.

	One byte-addressed `buffer` holds RAM. Above it sits a memory-mapped device
	window, and above that a trap page. Every access records its cycle cost, so
	the core never re-derives it and the timing contract stays in one place.

	Also tracks the active code range `[codeLow, codeHigh)` so Tier 1 and Tier 2
	compiled basic blocks are invalidated immediately whenever a write touches
	assembled instructions (docs/02-memory-and-devices.md, docs/03-execution-model.md),
	and hosts the word-addressed shared region for multi-core communication.

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

export type State = {
	ram: buffer,
	ramSize: number,
	devices: { [number]: Device },
	rootDevice: Device?,
	lastCost: number,
	faults: number,
	codeLow: number,
	codeHigh: number,
	codeGen: number,
	onCodeWrite: ((address: number, width: number) -> ())?,
	onTrap: ((reason: number, address: number) -> ())?,
	sharedBuf: buffer?,
	sharedTable: { [number]: number }?,
	sharedWords: number,
}

export type Class = typeof(setmetatable({} :: State, Memory))

local WRAP = 4294967296
local PAGE = 4096

Memory.RAM_BASE = 0x00000000
Memory.DEVICE_BASE = 0x0F000000
Memory.DEVICE_END = 0x10000000
Memory.TRAP_BASE = 0xFF000000
Memory.FAULT = {
	INVALID_ACCESS = 1,
}

function Memory.new(ramSize: number): Class
	local self = setmetatable({}, Memory) :: any
	self.ramSize = ramSize
	self.ram = buffer.create(ramSize)
	self.devices = {}
	self.rootDevice = nil
	self.lastCost = 1
	self.faults = 0
	self.codeLow = 0xFFFFFFFF
	self.codeHigh = 0
	self.codeGen = 1
	self.onCodeWrite = nil
	self.sharedBuf = nil
	self.sharedTable = nil
	self.sharedWords = 0
	return self
end

--- Attach a device to a 4 KiB page, or to Memory.DEVICE_BASE to own the whole window.
function Memory.registerDevice(self: Class, pageBase: number, device: Device)
	if pageBase == Memory.DEVICE_BASE then
		self.rootDevice = device
	else
		self.devices[pageBase] = device
	end
end

--- Attach a page-local device at DEVICE_BASE without making it the window fallback.
function Memory.registerPageDevice(self: Class, pageBase: number, device: Device)
	self.devices[pageBase] = device
end

function Memory.getRam(self: Class): buffer
	return self.ram
end

--- Return whether a byte range is wholly contained in RAM. This is also used
--- by image, DMA, and accelerator input validation before touching raw buffers.
function Memory.containsRange(self: Class, address: number, size: number): boolean
	if address ~= address or size ~= size or address % 1 ~= 0 or size % 1 ~= 0 then
		return false
	end
	if address < 0 or size < 0 or address > self.ramSize then
		return false
	end
	return size <= self.ramSize - address
end

--- Record that a compiled basic block covers `[startAddress, endAddress)`.
function Memory.markCodeRange(self: Class, startAddress: number, endAddress: number)
	if startAddress < self.codeLow then
		self.codeLow = startAddress
	end
	if endAddress > self.codeHigh then
		self.codeHigh = endAddress
	end
end

--- Reset the tracked code range when the block cache is flushed.
function Memory.resetCodeRange(self: Class)
	self.codeLow = 0xFFFFFFFF
	self.codeHigh = 0
	self.codeGen += 1
end

--- Notify the core that `[address, address + width)` in RAM was modified.
function Memory.notifyCodeWrite(self: Class, address: number, width: number)
	self.codeGen += 1
	local hook = self.onCodeWrite
	if hook ~= nil then
		hook(address, width)
	end
end

--- Copy bytes into RAM, e.g. a program image's data section.
function Memory.copyIn(self: Class, address: number, source: buffer, sourceOffset: number?, count: number?)
	local offset = sourceOffset or 0
	local len = count or (buffer.len(source) - offset)
	local sourceSize = buffer.len(source)
	if offset < 0 or offset % 1 ~= 0 or len < 0 or len % 1 ~= 0 or offset > sourceSize or len > sourceSize - offset then
		error('memory: source copy range is outside its buffer', 0)
	end
	if not self:containsRange(address, len) then
		error('memory: destination copy range is outside RAM', 0)
	end
	buffer.copy(self.ram, address, source, offset, len)
	if address < self.codeHigh and address + len > self.codeLow then
		self:notifyCodeWrite(address, len)
	else
		self.codeGen += 1
	end
end

--- Attach a shared word region (either a `buffer` or a Roblox `SharedTable` / table).
function Memory.setShared(self: Class, storage: any, wordCount: number)
	self.sharedWords = wordCount
	if type(storage) == 'buffer' then
		self.sharedBuf = storage
		self.sharedTable = nil
	else
		self.sharedBuf = nil
		self.sharedTable = storage
	end
end

--- Read a 32-bit word from the shared region (docs/02-memory-and-devices.md section 5).
function Memory.readShared(self: Class, wordIndex: number): number
	self.lastCost = 4
	local idx = wordIndex % WRAP
	if idx >= self.sharedWords then
		self.faults += 1
		return 0
	end
	local sbuf = self.sharedBuf
	if sbuf ~= nil then
		return buffer.readu32(sbuf, idx * 4)
	end
	local stab = self.sharedTable
	if stab ~= nil then
		local v = stab[idx]
		if v ~= nil then
			return v % WRAP
		end
	end
	return 0
end

--- Write a 32-bit word to the shared region.
function Memory.writeShared(self: Class, wordIndex: number, value: number)
	self.lastCost = 4
	local idx = wordIndex % WRAP
	if idx >= self.sharedWords then
		self.faults += 1
		return
	end
	local word = value % WRAP
	local sbuf = self.sharedBuf
	if sbuf ~= nil then
		buffer.writeu32(sbuf, idx * 4, word)
		return
	end
	local stab = self.sharedTable
	if stab ~= nil then
		stab[idx] = word
	end
end

--- Atomically add `delta` to a shared word and return its previous value.
function Memory.atomicAddShared(self: Class, wordIndex: number, delta: number): number
	self.lastCost = 4
	local idx = wordIndex % WRAP
	if idx >= self.sharedWords then
		self.faults += 1
		return 0
	end
	local sbuf = self.sharedBuf
	if sbuf ~= nil then
		local prev = buffer.readu32(sbuf, idx * 4)
		buffer.writeu32(sbuf, idx * 4, (prev + delta) % WRAP)
		return prev
	end
	local stab = self.sharedTable
	if stab ~= nil then
		local raw = stab[idx]
		local prev = if raw ~= nil then raw % WRAP else 0
		stab[idx] = (prev + delta) % WRAP
		return prev
	end
	return 0
end

local function resolve(self: Class, address: number): (Device?, number)
	local page = address - (address % PAGE)
	local device = self.devices[page]
	if device ~= nil then
		return device, address - page
	end
	local root = self.rootDevice
	if root ~= nil then
		return root, address - Memory.DEVICE_BASE
	end
	return nil, 0
end

local function isDevice(address: number): boolean
	return address >= Memory.DEVICE_BASE and address < Memory.DEVICE_END
end

local function notifyFault(self: Class, address: number)
	if self.onTrap ~= nil then
		self.onTrap(Memory.FAULT.INVALID_ACCESS, address)
	end
end

function Memory.read8(self: Class, address: number): number
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
		self.faults += 1
		notifyFault(self, address)
		return 0
	end
	self.lastCost = 4
	self.faults += 1
	notifyFault(self, address)
	return 0
end

function Memory.read16(self: Class, address: number): number
	address = address % WRAP
	if address <= self.ramSize - 2 then
		self.lastCost = 1
		return buffer.readu16(self.ram, address)
	end
	if isDevice(address) and address <= Memory.DEVICE_END - 2 then
		self.lastCost = 4
		local device, offset = resolve(self, address)
		if device ~= nil and device.read16 ~= nil then
			return device.read16(offset)
		end
		self.faults += 1
		notifyFault(self, address)
		return 0
	end
	self.lastCost = 4
	self.faults += 1
	notifyFault(self, address)
	return 0
end

function Memory.read32(self: Class, address: number): number
	address = address % WRAP
	if address <= self.ramSize - 4 then
		self.lastCost = 1
		return buffer.readu32(self.ram, address)
	end
	if isDevice(address) and address <= Memory.DEVICE_END - 4 then
		self.lastCost = 4
		local device, offset = resolve(self, address)
		if device ~= nil and device.read32 ~= nil then
			return device.read32(offset)
		end
		self.faults += 1
		notifyFault(self, address)
		return 0
	end
	self.lastCost = 4
	self.faults += 1
	notifyFault(self, address)
	return 0
end

function Memory.write8(self: Class, address: number, value: number)
	address = address % WRAP
	if address < self.ramSize then
		self.lastCost = 1
		buffer.writeu8(self.ram, address, value)
		if address < self.codeHigh and address + 1 > self.codeLow then
			self:notifyCodeWrite(address, 1)
		end
		return
	end
	if isDevice(address) then
		self.lastCost = 4
		local device, offset = resolve(self, address)
		if device ~= nil and device.write8 ~= nil then
			device.write8(offset, value % 256)
			return
		end
		self.faults += 1
		notifyFault(self, address)
		return
	end
	self.lastCost = 4
	self.faults += 1
	notifyFault(self, address)
end

function Memory.write16(self: Class, address: number, value: number)
	address = address % WRAP
	if address <= self.ramSize - 2 then
		self.lastCost = 1
		buffer.writeu16(self.ram, address, value)
		if address < self.codeHigh and address + 2 > self.codeLow then
			self:notifyCodeWrite(address, 2)
		end
		return
	end
	if isDevice(address) and address <= Memory.DEVICE_END - 2 then
		self.lastCost = 4
		local device, offset = resolve(self, address)
		if device ~= nil and device.write16 ~= nil then
			device.write16(offset, value % 65536)
			return
		end
		self.faults += 1
		notifyFault(self, address)
		return
	end
	self.lastCost = 4
	self.faults += 1
	notifyFault(self, address)
end

function Memory.write32(self: Class, address: number, value: number)
	address = address % WRAP
	if address <= self.ramSize - 4 then
		self.lastCost = 1
		buffer.writeu32(self.ram, address, value)
		if address < self.codeHigh and address + 4 > self.codeLow then
			self:notifyCodeWrite(address, 4)
		end
		return
	end
	if isDevice(address) and address <= Memory.DEVICE_END - 4 then
		self.lastCost = 4
		local device, offset = resolve(self, address)
		if device ~= nil and device.write32 ~= nil then
			device.write32(offset, value % WRAP)
			return
		end
		self.faults += 1
		notifyFault(self, address)
		return
	end
	self.lastCost = 4
	self.faults += 1
	notifyFault(self, address)
end

function Memory.readf32(self: Class, address: number): number
	address = address % WRAP
	if address <= self.ramSize - 4 then
		self.lastCost = 1
		return buffer.readf32(self.ram, address)
	end
	self.lastCost = 4
	self.faults += 1
	notifyFault(self, address)
	return 0
end

function Memory.writef32(self: Class, address: number, value: number)
	address = address % WRAP
	if address <= self.ramSize - 4 then
		self.lastCost = 1
		buffer.writef32(self.ram, address, value)
		if address < self.codeHigh and address + 4 > self.codeLow then
			self:notifyCodeWrite(address, 4)
		end
		return
	end
	self.lastCost = 4
	self.faults += 1
	notifyFault(self, address)
end

return Memory
