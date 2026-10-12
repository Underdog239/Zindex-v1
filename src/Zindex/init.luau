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
	self.onTrap = opts.onTrap -- ECALL host-call handler
	self.onMemoryTrap = opts.onMemoryTrap -- invalid memory-access notification
	self.onInterrupt = opts.onInterrupt
	if self.onMemoryTrap ~= nil then
		self.memory.onTrap = function(reason: number, address: number)
			self.onMemoryTrap(self, self.cores[1], reason, address)
		end
	end

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
		if self.onMemoryTrap ~= nil then
			mem.onTrap = function(reason: number, address: number)
				self.onMemoryTrap(self, self.cores[idx], reason, address)
			end
		end
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

local function validateLoadRange(memory: Memory.Class, address: number, size: number, label: string)
	if not memory:containsRange(address, size) then
		error('zindex: ' .. label .. ' is outside RAM', 0)
	end
end

--- Load an Assembler result: copy the code in, set the entry, build the core(s).
function Zindex:loadProgram(result): any
	local codeSize = buffer.len(result.code)
	validateLoadRange(self.memory, result.origin, codeSize, 'program image')
	validateLoadRange(self.memory, result.entry, 1, 'entry point')

	self.entry = result.entry
	for idx = 1, self.coreCount do
		local mem = self.memories[idx]
		mem:copyIn(result.origin, result.code, 0, codeSize)
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
	local codeSize = buffer.len(program.code)
	local dataSize = buffer.len(program.data)
	if program.ramSize > 0 and program.ramSize > self.ramSize then
		error('zindex: image requires more RAM than this chip provides', 0)
	end
	validateLoadRange(self.memory, program.codeAddress, codeSize, 'image code')
	validateLoadRange(self.memory, program.dataAddress, dataSize, 'image data')
	validateLoadRange(self.memory, program.entry, 1, 'image entry point')

	self.entry = program.entry
	for idx = 1, self.coreCount do
		local mem = self.memories[idx]
		mem:copyIn(program.codeAddress, program.code, 0, codeSize)
		if dataSize > 0 then
			mem:copyIn(program.dataAddress, program.data, 0, dataSize)
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

--- Pull up to `maxSamples` float32 samples from AUDIO (at most 4096 per call).
function Zindex:pullAudio(maxSamples: number?): { number }
	local audio = self.devices.audio
	local ram = self.memory:getRam()
	local ramSize = self.ramSize
	if audio.length <= 0 or audio.base <= 0 then
		return {}
	end
	local requested = 4096
	if maxSamples ~= nil then
		if maxSamples ~= maxSamples or maxSamples <= 0 then
			return {}
		end
		requested = math.min(math.floor(maxSamples), 4096)
	end
	local available = (audio.writeCursor - audio.readCursor) % audio.length
	local count = math.min(available, requested)
	local samples = table.create(count)
	for i = 1, count do
		local addr = audio.base + audio.readCursor * 4
		if addr >= 0 and addr + 4 <= ramSize then
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

local function cloneBuffer(source: buffer): buffer
	local copy = buffer.create(buffer.len(source))
	buffer.copy(copy, 0, source, 0, buffer.len(source))
	return copy
end

local function clonePlain(value: any): any
	if type(value) ~= 'table' then
		return value
	end
	local copy = {}
	for key, item in value do
		if type(item) ~= 'function' then
			copy[key] = clonePlain(item)
		end
	end
	return copy
end

local function restorePlain(target: any, saved: any)
	for key, value in saved do
		local current = target[key]
		if type(value) == 'table' and type(current) == 'table' then
			restorePlain(current, value)
		elseif type(current) ~= 'function' then
			target[key] = value
		end
	end
end

local function snapshotCore(core): any
	local regs = buffer.create(128)
	buffer.copy(regs, 0, core.regs, 0, 128)
	local vecs = table.create(8)
	for index = 1, 8 do
		vecs[index] = core.vecs[index]
	end
	return {
		regs = regs,
		vecs = vecs,
		pc = core.pc,
		cycles = core.cycles,
		steps = core.steps,
		halted = core.halted,
		exitCode = core.exitCode,
		yielded = core.yielded,
		syncWaiting = core.syncWaiting,
		traps = core.traps,
		tier = core.tier,
		irqEnabled = core.irqEnabled,
		irqVector = core.irqVector,
		irqReturnPc = core.irqReturnPc,
		stats = clonePlain(core.stats),
	}
end

local function snapshotGpu(gpu): any
	if gpu == nil then
		return nil
	end
	return {
		queueBase = gpu.queueBase,
		queueCount = gpu.queueCount,
		pending = gpu.pending,
		status = gpu.status,
		commandsRun = gpu.commandsRun,
		queueFaults = gpu.queueFaults,
		near = gpu.near,
		colourAddress = gpu.colourAddress,
		depthAddress = gpu.depthAddress,
		tileCount = gpu.tileCount,
		scissorX = gpu.scissorX,
		scissorY = gpu.scissorY,
		scissorW = gpu.scissorW,
		scissorH = gpu.scissorH,
		scale = gpu.scale,
		minScale = gpu.minScale,
		maxScale = gpu.maxScale,
		adaptive = gpu.adaptive,
		targetFps = gpu.targetFps,
		baseWidth = gpu.baseWidth,
		baseHeight = gpu.baseHeight,
		width = gpu.width,
		height = gpu.height,
		raster = {
			colourBase = gpu.raster.colourBase,
			depthBase = gpu.raster.depthBase,
			cull = gpu.raster.cull,
			scissorX = gpu.raster.scissorX,
			scissorY = gpu.raster.scissorY,
			scissorW = gpu.raster.scissorW,
			scissorH = gpu.raster.scissorH,
			stats = clonePlain(gpu.raster.stats),
		},
	}
end

local function snapshotNpu(npu): any
	return {
		queueBase = npu.queueBase,
		queueCount = npu.queueCount,
		pending = npu.pending,
		status = npu.status,
		commandsRun = npu.commandsRun,
		queueFaults = npu.queueFaults,
		stats = clonePlain(npu.stats),
	}
end

local function snapshotShared(storage): any
	if type(storage) == 'buffer' then
		return { kind = 'buffer', value = cloneBuffer(storage) }
	end
	local values = {}
	for key, value in storage do
		values[key] = value
	end
	return { kind = 'table', value = values }
end

local function restoreShared(storage, saved)
	if saved.kind == 'buffer' then
		if type(storage) ~= 'buffer' or buffer.len(storage) ~= buffer.len(saved.value) then
			error('zindex: save state shared-memory shape does not match chip', 0)
		end
		buffer.copy(storage, 0, saved.value, 0, buffer.len(saved.value))
		return
	end
	if type(storage) == 'buffer' then
		error('zindex: save state shared-memory shape does not match chip', 0)
	end
	local keys = {}
	for key in storage do
		keys[#keys + 1] = key
	end
	for _, key in keys do
		storage[key] = nil
	end
	for key, value in saved.value do
		storage[key] = value
	end
end

--- Snapshot all architectural state (cores, RAM, devices, shared memory, GPU and NPU).
--- Compiled blocks are deliberately omitted and rebuilt on restore.
function Zindex:snapshot(): any
	if self.core == nil then
		error('zindex: no program loaded', 0)
	end
	local coreStates = table.create(self.coreCount)
	local memoryStates = table.create(self.coreCount)
	local deviceStates = table.create(self.coreCount)
	for index = 1, self.coreCount do
		local core = self.cores[index]
		local memory = self.memories[index]
		coreStates[index] = snapshotCore(core)
		memoryStates[index] = {
			ram = cloneBuffer(memory:getRam()),
			lastCost = memory.lastCost,
			faults = memory.faults,
		}
		deviceStates[index] = clonePlain(self.coreDevices[index])
	end
	local primary = coreStates[1]
	return {
		format = 2,
		ramSize = self.ramSize,
		coreCount = self.coreCount,
		tier = self.tier,
		entry = self.entry,
		presents = self.presents,
		cores = coreStates,
		memories = memoryStates,
		devices = deviceStates,
		sharedWords = self.sharedWords,
		shared = snapshotShared(self.shared),
		gpu = snapshotGpu(self.gpu),
		npu = snapshotNpu(self.npu),
		-- Preserve the original single-core convenience fields.
		regs = primary.regs,
		ram = memoryStates[1].ram,
		pc = primary.pc,
		cycles = primary.cycles,
		steps = primary.steps,
		halted = primary.halted,
		exitCode = primary.exitCode,
		vecs = primary.vecs,
	}
end

function Zindex:restore(state)
	if type(state) ~= 'table' or state.format ~= 2 then
		error('zindex: unsupported or malformed save state', 0)
	end
	if type(state.cores) ~= 'table' or type(state.memories) ~= 'table' or type(state.devices) ~= 'table'
		or type(state.shared) ~= 'table' or type(state.npu) ~= 'table'
		or state.ramSize ~= self.ramSize or state.coreCount ~= self.coreCount or state.sharedWords ~= self.sharedWords
		or #state.cores ~= self.coreCount or #state.memories ~= self.coreCount or #state.devices ~= self.coreCount
		or ((state.gpu ~= nil) ~= (self.gpu ~= nil))
	then
		error('zindex: save state configuration does not match chip', 0)
	end
	if (state.shared.kind == 'buffer' and type(self.shared) ~= 'buffer')
		or (state.shared.kind == 'table' and type(self.shared) == 'buffer')
		or (state.shared.kind ~= 'buffer' and state.shared.kind ~= 'table')
		or (state.shared.kind == 'buffer' and (type(state.shared.value) ~= 'buffer' or buffer.len(state.shared.value) ~= buffer.len(self.shared)))
		or (state.shared.kind == 'table' and type(state.shared.value) ~= 'table')
		or type(state.npu.stats) ~= 'table'
		or (self.gpu ~= nil and (type(state.gpu) ~= 'table' or type(state.gpu.raster) ~= 'table'
			or type(state.gpu.raster.stats) ~= 'table'))
	then
		error('zindex: save state device shape does not match chip', 0)
	end
	for index = 1, self.coreCount do
		local coreState = state.cores[index]
		local memoryState = state.memories[index]
		if type(coreState) ~= 'table' or type(memoryState) ~= 'table' or type(state.devices[index]) ~= 'table'
			or type(coreState.stats) ~= 'table' or type(coreState.vecs) ~= 'table' or #coreState.vecs ~= 8
			or type(coreState.regs) ~= 'buffer' or buffer.len(coreState.regs) ~= 128
			or type(memoryState.ram) ~= 'buffer' or buffer.len(memoryState.ram) ~= self.ramSize
		then
			error('zindex: save state buffer shape does not match chip', 0)
		end
	end

	self.tier = state.tier
	self.entry = state.entry
	self.presents = state.presents
	for index = 1, self.coreCount do
		local memory = self.memories[index]
		local memoryState = state.memories[index]
		buffer.copy(memory:getRam(), 0, memoryState.ram, 0, self.ramSize)
		restorePlain(self.coreDevices[index], state.devices[index])
	end
	restoreShared(self.shared, state.shared)

	for index = 1, self.coreCount do
		local core = self.cores[index]
		local saved = state.cores[index]
		local memory = self.memories[index]
		buffer.fill(core.regs, 0, 0, 132)
		buffer.copy(core.regs, 0, saved.regs, 0, 128)
		for vectorIndex = 1, 8 do
			core.vecs[vectorIndex] = saved.vecs[vectorIndex]
		end
		core.pc = saved.pc
		core.cycles = saved.cycles
		core.steps = saved.steps
		core.halted = saved.halted
		core.exitCode = saved.exitCode
		core.yielded = saved.yielded
		core.syncWaiting = saved.syncWaiting
		core.traps = saved.traps
		core.tier = saved.tier
		core.irqEnabled = saved.irqEnabled
		core.irqVector = saved.irqVector
		core.irqReturnPc = saved.irqReturnPc
		core:invalidateAll()
		restorePlain(core.stats, saved.stats)
		memory.lastCost = state.memories[index].lastCost
		memory.faults = state.memories[index].faults
	end
	self.core = self.cores[1]

	if self.gpu ~= nil then
		local gpu = self.gpu
		local saved = state.gpu
		gpu.minScale = saved.minScale
		gpu.maxScale = saved.maxScale
		gpu.adaptive = saved.adaptive
		gpu.targetFps = saved.targetFps
		gpu.baseWidth = saved.baseWidth
		gpu.baseHeight = saved.baseHeight
		-- Restore the saved scale verbatim. Routing it through setResolutionScale
		-- would clamp it to the chip's current min/max and resize the framebuffer,
		-- so the host would upload a different size than the raster drew.
		gpu.scale = saved.scale
		gpu.width = saved.width
		gpu.height = saved.height
		gpu.raster:resize(saved.width, saved.height)
		if gpu.framebuffer ~= nil then
			gpu.framebuffer.width = saved.width
			gpu.framebuffer.height = saved.height
		end
		gpu.queueBase = saved.queueBase
		gpu.queueCount = saved.queueCount
		gpu.pending = saved.pending
		gpu.status = saved.status
		gpu.commandsRun = saved.commandsRun
		gpu.queueFaults = saved.queueFaults
		gpu.near = saved.near
		gpu.colourAddress = saved.colourAddress
		gpu.depthAddress = saved.depthAddress
		gpu.tileCount = saved.tileCount
		gpu.scissorX = saved.scissorX
		gpu.scissorY = saved.scissorY
		gpu.scissorW = saved.scissorW
		gpu.scissorH = saved.scissorH
		gpu.raster.colourBase = saved.raster.colourBase
		gpu.raster.depthBase = saved.raster.depthBase
		gpu.raster.cull = saved.raster.cull
		gpu.raster:setScissor(saved.raster.scissorX, saved.raster.scissorY, saved.raster.scissorW, saved.raster.scissorH)
		restorePlain(gpu.raster.stats, saved.raster.stats)
		gpu.raster.workRemaining = nil
		gpu.raster.workLimitHit = false
	end

	local npu = self.npu
	local savedNpu = state.npu
	npu.queueBase = savedNpu.queueBase
	npu.queueCount = savedNpu.queueCount
	npu.pending = savedNpu.pending
	npu.status = savedNpu.status
	npu.commandsRun = savedNpu.commandsRun
	npu.queueFaults = savedNpu.queueFaults
	restorePlain(npu.stats, savedNpu.stats)
end

return Zindex
