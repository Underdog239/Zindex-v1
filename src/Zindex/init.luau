--!nonstrict
--[==[
	Zindex - a virtual chip architecture for Luau.

	Zindex.new{}          build a chip: RAM, devices, and a CPU core
	chip:assemble(src)    assemble Z32 assembly, load it, return the symbols
	chip:loadImage(blob)  load a packed program image
	chip:run(cycles)      run a cycle budget and return what it used
	chip:snapshot()       exact machine state, because execution is deterministic
	chip:restore(state)   put that state back

	Example

		local Zindex = require(game.ReplicatedStorage.Zindex)
		local chip = Zindex.new{ ramSize = 0x10000 }
		chip:assemble[[
			li r1, 0x2000
			li r2, 0x41424344
			sw r2, 0(r1)
			li r1, 0
			lw r2, 0x2000(r0)
			halt
		]]
		chip:run(1000)
		print(chip:reg(2))

	The core touches no engine API, so this module runs unchanged in Roblox, in
	the Luau CLI, and under test. Roblox-only presentation lives in RobloxView.
]==]

local Assembler = require(script.Parent.Assembler)
local Core = require(script.Parent.Core)
local Devices = require(script.Parent.Devices)
local Image = require(script.Parent.Image)
local Memory = require(script.Parent.Memory)

local WRAP = 4294967296

local Zindex = {}
Zindex.__index = Zindex
Zindex.version = '0.1.0'

Zindex.assemble = Assembler.assemble
Zindex.Assembler = Assembler
Zindex.Core = Core
Zindex.Devices = Devices
Zindex.Image = Image
Zindex.Memory = Memory

--- Host call numbers, passed in R1 to ECALL.
Zindex.SYSCALL = {
	EXIT = 0,
	PRINT = 1,
	PRESENT = 2,
	TIME = 3,
}

local function defaultTrap(chip, reason: number): (number, number)
	if reason == Zindex.SYSCALL.EXIT then
		chip.core.halted = true
		chip.core.exitCode = chip.core:reg(2)
		return 0, 0
	elseif reason == Zindex.SYSCALL.PRINT then
		local address = chip.core:reg(2)
		local ram = chip.memory:getRam()
		local out = {}
		while address < chip.ramSize do
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
		return chip.core.cycles % WRAP, 0
	end
	return 0, 0
end

--- Build a chip.
function Zindex.new(options): any
	local opts = options or {}
	local self = setmetatable({}, Zindex)
	self.ramSize = opts.ramSize or 0x100000
	self.memory = Memory.new(self.ramSize)
	self.core = nil
	self.presents = 0
	self.entry = 0
	self.onTrap = opts.onTrap
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
		coreCount = opts.coreCount or 1,
	})
	return self
end

--- Load an Assembler result: copy the code in, set the entry, build the core.
function Zindex:loadProgram(result): any
	self.memory:copyIn(result.origin, result.code, 0, buffer.len(result.code))
	self.entry = result.entry
	local core = Core.new(self.memory, result.entry)
	local handler = self.onTrap
	core.onTrap = function(inner, reason: number)
		return defaultTrap(self, reason)
	end
	if handler ~= nil then
		core.onTrap = function(inner, reason: number): (number?, number?)
			return handler(self, reason)
		end
	end
	self.core = core
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
	self.memory:copyIn(program.codeAddress, program.code, 0, buffer.len(program.code))
	if buffer.len(program.data) > 0 then
		self.memory:copyIn(program.dataAddress, program.data, 0, buffer.len(program.data))
	end
	self.entry = program.entry
	local core = Core.new(self.memory, program.entry)
	core.onTrap = function(inner, reason: number)
		return defaultTrap(self, reason)
	end
	self.core = core
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

function Zindex:run(cycles: number): number
	if self.core == nil then
		error('zindex: no program loaded', 0)
	end
	return self.core:run(cycles)
end

function Zindex:step(): number
	return self.core:step()
end

function Zindex:reg(index: number): number
	return self.core:reg(index)
end

function Zindex:setReg(index: number, value: number)
	self.core:setReg(index, value)
end

function Zindex:ram(): buffer
	return self.memory:getRam()
end

function Zindex:halted(): boolean
	return self.core ~= nil and self.core.halted
end

function Zindex:exitCode(): number
	return self.core ~= nil and self.core.exitCode or 0
end

function Zindex:cycles(): number
	return self.core ~= nil and self.core.cycles or 0
end

--- Host-side input, read by the guest through the INPUT device page.
function Zindex:setInput(buttons: number, pointerX: number, pointerY: number)
	self.devices.input.buttons = buttons % WRAP
	self.devices.input.pointerX = pointerX or 0
	self.devices.input.pointerY = pointerY or 0
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
	return {
		regs = buffer.fromstring(buffer.tostring(core.regs)),
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
	buffer.copy(core.regs, 0, state.regs)
	buffer.copy(self.memory:getRam(), 0, state.ram)
	core.pc = state.pc
	core.cycles = state.cycles
	core.steps = state.steps
	core.halted = state.halted
	core.exitCode = state.exitCode
	for i = 1, 8 do
		core.vecs[i] = state.vecs[i]
	end
end

return Zindex
