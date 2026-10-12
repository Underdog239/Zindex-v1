--!nonstrict
--[==[
	Zindex - a virtual chip architecture for Luau.

	Zindex.new{}          build a chip: RAM, devices, NPU, optional GPU, 1..N CPU cores
	chip:assemble(src)    assemble Z32 assembly, load it, return the symbols
	chip:loadImage(blob)  load a packed program image
	chip:run(cycles)      run a cycle budget and return what it used
	chip:setTier(tier)    select execution tier: 0 dispatch, 1 block, 2 native block
	chip:snapshot()       exact machine state, because execution is deterministic
	chip:restore(state)   put that state back

	The core touches no engine API, so this module runs unchanged in Roblox, in
	the Luau CLI, and under test. Roblox-only presentation lives in RobloxView.
]==]

local Assembler = require(script.Parent.Assembler)
local Core = require(script.Parent.Core)
local Devices = require(script.Parent.Devices)
local Gpu = require(script.Parent.Gpu)
local Image = require(script.Parent.Image)
local Memory = require(script.Parent.Memory)
local Npu = require(script.Parent.Npu)
local Opcodes = require(script.Parent.Opcodes)
local Raster = require(script.Parent.Raster)

local WRAP = 4294967296

local Zindex = {}
Zindex.__index = Zindex
Zindex.version = '0.2.0'

Zindex.assemble = Assembler.assemble
Zindex.Assembler = Assembler
Zindex.Core = Core
Zindex.Devices = Devices
Zindex.Gpu = Gpu
Zindex.Image = Image
Zindex.Memory = Memory
Zindex.Npu = Npu
Zindex.Opcodes = Opcodes
Zindex.Raster = Raster

--- Host call numbers, passed in R1 to ECALL.
Zindex.SYSCALL = {
	EXIT = 0,
	PRINT = 1,
	PRESENT = 2,
	TIME = 3,
}

local function defaultTrap(chip, activeCore, reason: number): (number, number)
	local core = activeCore or chip.core
	if reason == Zindex.SYSCALL.EXIT then
		core.halted = true
		core.exitCode = core:reg(2)
		return 0, 0
	elseif reason == Zindex.SYSCALL.PRINT then
		local address = core:reg(2)
		local ram = core.mem:getRam()
		local ramSize = core.mem.ramSize
		local out = {}
		while address < ramSize do
			local byte = buffer.readu8(ram, address)
			if byte == 0 then
				break
			end
			out[#out + 1] = string.char(byte)
			address += 1
		end
		print(table.concat(out))
		return 0, 0
	elseif reason == Zindex.SYSCALL.PRESENT then
		chip.presents += 1
		return 0, 0
	elseif reason == Zindex.SYSCALL.TIME then
		return core.cycles % WRAP, 0
	end
	return 0, 0
end

--- Build a chip (single-core by default, or multi-core when `coreCount > 1`).
function Zindex.new(options): any
	local opts = options or {}
	local self = setmetatable({}, Zindex)
	self.ramSize = opts.ramSize or 0x100000
	self.tier = if opts.tier ~= nil then opts.tier else 2
	self.coreCount = math.max(1, opts.coreCount or 1)
	self.sharedWords = opts.sharedWords or 1024
	self.shared = opts.shared or buffer.create(self.sharedWords * 4)

	self.memory = Memory.new(self.ramSize)
	self.memory:setShared(self.shared, self.sharedWords)
	self.core = nil
	self.cores = {}
	self.memories = { self.memory }
	self.coreDevices = {}
	self.presents = 0
	self.entry = 0
	self.onTrap = opts.onTrap
	self.onInterrupt = opts.onInterrupt

	self.devices = Devices.attach(self.memory, {
		clock = function(): number
			local core = self.core
			if core == nil then
				return 0
			end
			return core.cycles
		end,
		width = opts.width or 0,
		height = opts.height or 0,
		format = opts.format or 0,
		back = opts.back or 0,
		front = opts.front or 0,
		coreId = opts.coreId or 0,
		coreCount = self.coreCount,
		sharedSize = self.sharedWords,
		onIrqConfig = function(enabled: boolean, vector: number)
			if self.core ~= nil then
				self.core.irqEnabled = enabled
				self.core.irqVector = vector
			end
		end,
	})
	self.coreDevices[1] = self.devices

	-- Secondary cores each own a private RAM buffer and device window, sharing
	-- only the explicit word-addressed shared region (docs/02-memory-and-devices.md).
	for idx = 2, self.coreCount do
		local mem = Memory.new(self.ramSize)
		mem:setShared(self.shared, self.sharedWords)
		self.memories[idx] = mem
		self.coreDevices[idx] = Devices.attach(mem, {
			clock = function(): number
				local c = self.cores[idx]
				return if c ~= nil then c.cycles else 0
			end,
			coreId = idx - 1,
			coreCount = self.coreCount,
			sharedSize = self.sharedWords,
			onIrqConfig = function(enabled: boolean, vector: number)
				local c = self.cores[idx]
				if c ~= nil then
					c.irqEnabled = enabled
					c.irqVector = vector
				end
			end,
		})
	end

	-- The Z-NPU tensor / vector / DMA co-processor is always attached to the SoC.
	self.npu = Npu.attach(self.memory)

	-- The graphics unit exists when a framebuffer was configured.
	if (opts.width or 0) > 0 and (opts.height or 0) > 0 then
		self.gpu = Gpu.attach(self.memory, {
			framebuffer = self.devices.framebuffer,
			width = opts.width,
			height = opts.height,
			colour = opts.back or 0,
			depth = opts.depth or 0,
			resolutionScale = opts.resolutionScale,
			minScale = opts.minScale,
			maxScale = opts.maxScale,
			adaptive = opts.adaptive,
			targetFps = opts.targetFps,
			tileCount = opts.tileCount,
		})
	else
		self.gpu = nil
	end
	return self
end

local function wireCore(self, core, devHandles)
	local trapHandler = self.onTrap
	if trapHandler ~= nil then
		core.onTrap = function(inner, reason: number): (number?, number?)
			return trapHandler(self, reason, inner)
		end
	else
		core.onTrap = function(inner, reason: number)
			return defaultTrap(self, inner, reason)
		end
	end
	core.onPollInterrupts = function(cycles: number)
		devHandles.tick(cycles)
	end
	if self.onInterrupt ~= nil then
		core.onInterrupt = self.onInterrupt
	end
	core.irqEnabled = devHandles.dev.enable ~= 0 or bit32.band(devHandles.timer.control, 1) ~= 0
	core.irqVector = devHandles.dev.vector
	if self.coreCount > 1 then
		core.onSync = function(inner)
			inner.syncWaiting = true
		end
	end
end

--- Load an Assembler result: copy the code in, set the entry, build the core(s).
function Zindex:loadProgram(result): any
	self.entry = result.entry
	for idx = 1, self.coreCount do
		local mem = self.memories[idx]
		mem:copyIn(result.origin, result.code, 0, buffer.len(result.code))
		local core = Core.new(mem, result.entry, self.tier)
		wireCore(self, core, self.coreDevices[idx])
		self.cores[idx] = core
	end
	self.core = self.cores[1]
	return result
end

--- Assemble source and load it. Returns the Assembler result, so callers can
--- read the symbol table and the listing.
function Zindex:assemble(source: string, options): any
	local result = Assembler.assemble(source, options)
	return self:loadProgram(result)
end

--- Load a packed program image (see Image.luau).
function Zindex:loadImage(blob: buffer): any
	local program = Image.unpack(blob)
	self.entry = program.entry
	for idx = 1, self.coreCount do
		local mem = self.memories[idx]
		mem:copyIn(program.codeAddress, program.code, 0, buffer.len(program.code))
		if buffer.len(program.data) > 0 then
			mem:copyIn(program.dataAddress, program.data, 0, buffer.len(program.data))
		end
		local core = Core.new(mem, program.entry, self.tier)
		wireCore(self, core, self.coreDevices[idx])
		self.cores[idx] = core
	end
	self.core = self.cores[1]
	return program
end

--- Pack an assembler result into a program image.
function Zindex.pack(result: any): buffer
	return Image.pack({
		entry = result.entry,
		code = result.code,
		codeAddress = result.origin,
		ramSize = result.ramSize,
	})
end

--- Set the execution tier (0 = dispatch, 1 = block compiler, 2 = native block compiler).
function Zindex:setTier(tier: number)
	self.tier = tier
	for _, core in self.cores do
		core:setTier(tier)
	end
end

--- Flush compiled basic blocks (all of them, or those covering `[address, address + width)`).
function Zindex:invalidate(address: number?, width: number?)
	for _, core in self.cores do
		if address ~= nil then
			core:invalidateRange(address, width or 4)
		else
			core:invalidateAll()
		end
	end
end

function Zindex:run(cycles: number): number
	if self.core == nil then
		error('zindex: no program loaded', 0)
	end
	local used = 0
	if self.coreCount == 1 then
		used = self.core:run(cycles)
	else
		-- Multi-core scheduler: step cores in slices and release SYNC barriers
		-- once all non-halted cores arrive at the barrier.
		local perCoreUsed = table.create(self.coreCount, 0)
		local slice = math.min(64, math.max(1, cycles))
		while true do
			local anyProgress = false
			for idx = 1, self.coreCount do
				local c = self.cores[idx]
				local rem = cycles - perCoreUsed[idx]
				if rem > 0 and not c.halted and not c.yielded and not c.syncWaiting then
					local delta = c:run(math.min(slice, rem))
					perCoreUsed[idx] += delta
					anyProgress = true
				end
			end

			-- Check whether all active (non-halted) cores are waiting on SYNC.
			local waitingCount = 0
			local activeCount = 0
			for idx = 1, self.coreCount do
				local c = self.cores[idx]
				if not c.halted then
					activeCount += 1
					if c.syncWaiting then
						waitingCount += 1
					end
				end
			end
			if activeCount > 0 and waitingCount == activeCount then
				for idx = 1, self.coreCount do
					self.cores[idx].syncWaiting = false
					self.coreDevices[idx].ipc.barrierGen += 1
				end
				anyProgress = true
			end

			if not anyProgress then
				break
			end
		end
		used = perCoreUsed[1]
	end
	self:pumpGpu()
	self:pumpNpu()
	return used
end

--- Drain the graphics queue, if there is one and it has work.
function Zindex:pumpGpu(): number
	if self.gpu == nil then
		return 0
	end
	return self.gpu:pump()
end

--- Drain the Z-NPU command queue, if it has work.
function Zindex:pumpNpu(): number
	if self.npu == nil then
		return 0
	end
	return self.npu:pump()
end

function Zindex:step(): number
	return self.core:step()
end

function Zindex:reg(index: number, coreIndex: number?): number
	local c = if coreIndex ~= nil then self.cores[coreIndex] else self.core
	return c:reg(index)
end

function Zindex:setReg(index: number, value: number, coreIndex: number?)
	local c = if coreIndex ~= nil then self.cores[coreIndex] else self.core
	c:setReg(index, value)
end

function Zindex:ram(coreIndex: number?): buffer
	local m = if coreIndex ~= nil then self.memories[coreIndex] else self.memory
	return m:getRam()
end

function Zindex:readShared(wordIndex: number): number
	return self.memory:readShared(wordIndex)
end

function Zindex:writeShared(wordIndex: number, value: number)
	self.memory:writeShared(wordIndex, value)
end

function Zindex:halted(coreIndex: number?): boolean
	if coreIndex ~= nil then
		local c = self.cores[coreIndex]
		return c ~= nil and c.halted
	end
	return self.core ~= nil and self.core.halted
end

function Zindex:exitCode(coreIndex: number?): number
	local c = if coreIndex ~= nil then self.cores[coreIndex] else self.core
	return c ~= nil and c.exitCode or 0
end

function Zindex:cycles(coreIndex: number?): number
	local c = if coreIndex ~= nil then self.cores[coreIndex] else self.core
	return c ~= nil and c.cycles or 0
end

--- Host-side input, read by the guest through the INPUT device page.
function Zindex:setInput(buttons: number, pointerX: number, pointerY: number, wheel: number?)
	self.devices.input.buttons = buttons % WRAP
	self.devices.input.pointerX = pointerX or 0
	self.devices.input.pointerY = pointerY or 0
	self.devices.input.wheel = wheel or 0
end

--- Pull up to `maxSamples` float32 samples from the guest's AUDIO ring buffer.
function Zindex:pullAudio(maxSamples: number?): { number }
	local audio = self.devices.audio
	local ram = self.memory:getRam()
	local ramSize = self.ramSize
	if audio.length <= 0 or audio.base <= 0 then
		return {}
	end
	local available = (audio.writeCursor - audio.readCursor) % audio.length
	local count = if maxSamples ~= nil then math.min(available, maxSamples) else available
	local samples = table.create(count)
	for i = 1, count do
		local addr = audio.base + audio.readCursor * 4
		if addr + 4 <= ramSize then
			samples[i] = buffer.readf32(ram, addr)
		else
			samples[i] = 0
		end
		audio.readCursor = (audio.readCursor + 1) % audio.length
	end
	return samples
end

--- A framebuffer descriptor plus the RAM it points at.
function Zindex:framebuffer(): (any, buffer)
	return self.devices.framebuffer, self.memory:getRam()
end

--- Exact machine state. Deterministic execution is what makes this exact.
function Zindex:snapshot(): any
	local core = self.core
	local vecs = table.create(8)
	for i = 1, 8 do
		vecs[i] = core.vecs[i]
	end
	local regsCopy = buffer.create(128)
	buffer.copy(regsCopy, 0, core.regs, 0, 128)
	return {
		regs = regsCopy,
		ram = buffer.fromstring(buffer.tostring(self.memory:getRam())),
		pc = core.pc,
		cycles = core.cycles,
		steps = core.steps,
		halted = core.halted,
		exitCode = core.exitCode,
		vecs = vecs,
	}
end

function Zindex:restore(state)
	local core = self.core
	buffer.fill(core.regs, 0, 0, 132)
	buffer.copy(core.regs, 0, state.regs, 0, math.min(128, buffer.len(state.regs)))
	buffer.copy(self.memory:getRam(), 0, state.ram)
	core.pc = state.pc
	core.cycles = state.cycles
	core.steps = state.steps
	core.halted = state.halted
	core.exitCode = state.exitCode
	for i = 1, 8 do
		core.vecs[i] = state.vecs[i]
	end
	core:invalidateAll()
end

return Zindex
