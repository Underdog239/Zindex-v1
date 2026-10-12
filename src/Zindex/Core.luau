--!strict
--!native
--[[
	Core - a Z32 CPU core: registers, decode, execute, basic-block compiler.

	Implements all three execution tiers from docs/03-execution-model.md:
	  * Tier 0 - reference dispatch loop (`step`)
	  * Tier 1 - basic-block compiler (`compileBlock` + `runBlock`): decodes each
	    basic block once into a flat 16-byte-per-instruction buffer cached by entry
	    PC, with automatic invalidation on any write into the code region
	  * Tier 2 - native execution (`--!native`): strength-reduces constant shifts
	    (`SHLI`/`SHRI`) to multiply/divide by 2^k, remaps writes to R0 onto a
	    scratch sink slot so register writes need no branch, inlines RAM loads and
	    stores against the underlying buffer, and loops self-branching blocks in
	    place without leaving native code

	All three tiers share one instruction semantics and produce byte-identical
	machine states and cycle counts.
]]

local Opcodes = require(script.Parent.Opcodes)
local Memory = require(script.Parent.Memory)

local Core = {}
Core.__index = Core

local WRAP = 4294967296
local HALF = 2147483648
local SINK_OFFSET = 128
local UOP_SIZE = 16
local MAX_BLOCK_LEN = 64

local ZERO_VEC = vector.create(0, 0, 0)
local ONE_VEC = vector.create(1, 1, 1)

export type Block = {
	startPc: number,
	endPc: number,
	count: number,
	uops: buffer,
	codeGen: number,
	firstWord: number,
}

export type Stats = {
	blocksCompiled: number,
	blockRuns: number,
	blockInstructions: number,
	invalidations: number,
}

export type State = {
	mem: Memory.Class,
	regs: buffer,
	vecs: { vector },
	scratch: buffer,
	pc: number,
	cycles: number,
	halted: boolean,
	exitCode: number,
	yielded: boolean,
	syncWaiting: boolean,
	traps: number,
	steps: number,
	tier: number,
	blocks: { [number]: Block },
	stats: Stats,
	onTrap: ((core: any, reason: number) -> (number?, number?))?,
	onInterrupt: ((core: any, mask: number) -> ())?,
	onPollInterrupts: ((cycles: number) -> ())?,
	onSync: ((core: any) -> ())?,
	irqEnabled: boolean,
	irqVector: number,
	irqReturnPc: number,
}

export type Class = typeof(setmetatable({} :: State, Core))

--=====================================================================
-- 32-bit helpers
--=====================================================================

local function toSigned(value: number): number
	if value >= HALF then
		return value - WRAP
	end
	return value
end

--- Exact 32-bit multiply. A plain a*b loses precision above 2^53, so the
--- operands are split into 16-bit halves and only the surviving partial
--- products are kept.
local function mul32(a: number, b: number): number
	local a0 = a % 65536
	local a1 = (a - a0) / 65536
	local b0 = b % 65536
	local b1 = (b - b0) / 65536
	local mid = (a0 * b1 + a1 * b0) % 65536
	return (a0 * b0 + mid * 65536) % WRAP
end

local function shl(a: number, s: number): number
	if s >= 32 then
		return 0
	end
	return bit32.lshift(a, s)
end

local function shr(a: number, s: number): number
	if s >= 32 then
		return 0
	end
	return bit32.rshift(a, s)
end

local function sar(a: number, s: number): number
	if s >= 32 then
		if a >= HALF then
			return 4294967295
		end
		return 0
	end
	return bit32.arshift(a, s)
end

local function sign8(value: number): number
	if value >= 128 then
		return value - 256
	end
	return value
end

local function sign16(value: number): number
	if value >= 32768 then
		return value - 65536
	end
	return value
end

local function rget(regs: buffer, index: number): number
	return buffer.readu32(regs, (index % 32) * 4)
end

--- Writes are discarded for R0, the hardwired zero register.
local function rset(regs: buffer, index: number, value: number)
	local reg = index % 32
	if reg ~= 0 then
		buffer.writeu32(regs, reg * 4, value)
	end
end

--- Map destination register index `0..31` to its byte offset in `regs`,
--- routing R0 writes to the dummy sink slot at byte 128 so compiled blocks
--- never branch on `rd ~= 0`.
local function sinkOrReg(reg: number): number
	local r = reg % 32
	if r == 0 then
		return SINK_OFFSET
	end
	return r * 4
end

local function isBlockTerminator(op: number): boolean
	return (op >= 0x40 and op <= 0x48) or (op >= 0x50 and op <= 0x54)
end

--=====================================================================
-- Construction and state access
--=====================================================================

function Core.new(mem: Memory.Class, entry: number, tier: number?): Class
	local self = setmetatable({}, Core) :: any
	self.mem = mem
	-- 32 architectural registers (128 bytes) + 4-byte R0 write sink at offset 128.
	self.regs = buffer.create(132)
	self.vecs = table.create(8) :: { vector }
	for i = 1, 8 do
		self.vecs[i] = ZERO_VEC
	end
	self.scratch = buffer.create(8)
	self.pc = entry
	self.cycles = 0
	self.halted = false
	self.exitCode = 0
	self.yielded = false
	self.syncWaiting = false
	self.traps = 0
	self.steps = 0
	self.tier = if tier ~= nil then tier else 2
	self.blocks = {}
	self.stats = {
		blocksCompiled = 0,
		blockRuns = 0,
		blockInstructions = 0,
		invalidations = 0,
	}
	self.irqEnabled = false
	self.irqVector = 0
	self.irqReturnPc = 0

	local prevHook = mem.onCodeWrite
	mem.onCodeWrite = function(address: number, width: number)
		if prevHook ~= nil then
			prevHook(address, width)
		end
		self:invalidateRange(address, width)
	end

	return self
end

function Core.reset(self: Class, entry: number)
	buffer.fill(self.regs, 0, 0, 132)
	for i = 1, 8 do
		self.vecs[i] = ZERO_VEC
	end
	self.pc = entry
	self.cycles = 0
	self.halted = false
	self.exitCode = 0
	self.yielded = false
	self.syncWaiting = false
	self.steps = 0
	self:invalidateAll()
end

function Core.setTier(self: Class, tier: number)
	self.tier = tier
	self:invalidateAll()
end

function Core.invalidateAll(self: Class)
	table.clear(self.blocks)
	self.mem:resetCodeRange()
end

function Core.invalidateRange(self: Class, address: number, width: number)
	local finish = address + width
	local removed = false
	for pc, block in self.blocks do
		if address < block.endPc and finish > block.startPc then
			self.blocks[pc] = nil
			removed = true
		end
	end
	if removed then
		self.stats.invalidations += 1
	end
end

function Core.reg(self: Class, index: number): number
	return rget(self.regs, index)
end

function Core.setReg(self: Class, index: number, value: number)
	rset(self.regs, index, value)
end

function Core.vec(self: Class, index: number): vector
	return self.vecs[(index % 8) + 1]
end

function Core.setVec(self: Class, index: number, value: vector)
	self.vecs[(index % 8) + 1] = value
end

--- Reinterpret a float as its 32-bit pattern. Costs a buffer round trip,
--- which is the honest price of moving floats through 32-bit registers.
function Core.f32Bits(self: Class, value: number): number
	buffer.writef32(self.scratch, 0, value)
	return buffer.readu32(self.scratch, 0)
end

function Core.bitsF32(self: Class, bits: number): number
	buffer.writeu32(self.scratch, 0, bits)
	return buffer.readf32(self.scratch, 0)
end

function Core.pollInterrupts(self: Class)
	local pollHook = self.onPollInterrupts
	if pollHook ~= nil then
		pollHook(self.cycles)
	end
	local mem = self.mem
	local savedCost = mem.lastCost
	local pending = mem:read32(Memory.DEVICE_BASE)
	mem.lastCost = savedCost
	if pending ~= 0 then
		if self.onInterrupt ~= nil then
			self.onInterrupt(self, pending)
		end
		if self.irqVector ~= 0 then
			self.irqReturnPc = self.pc
			self.irqEnabled = false
			self.pc = self.irqVector
		end
	end
end

--=====================================================================
-- Tier 0: execute one instruction
--=====================================================================

--- Decode and execute one instruction. Returns the cycles it cost.
function Core.step(self: Class): number
	local mem = self.mem
	local regs = self.regs
	local pc = self.pc
	local op = mem:read8(pc)
	local cost = 1

	if op == 0x00 then -- NOP
		pc += 1

	--=================================================================
	-- Register-register ALU (form F2: op rd rs rt)
	--=================================================================
	elseif op == 0x10 then -- ADD
		rset(regs, mem:read8(pc + 1), rget(regs, mem:read8(pc + 2)) + rget(regs, mem:read8(pc + 3)))
		pc += 4
	elseif op == 0x11 then -- SUB
		rset(regs, mem:read8(pc + 1), rget(regs, mem:read8(pc + 2)) - rget(regs, mem:read8(pc + 3)))
		pc += 4
	elseif op == 0x12 then -- MUL
		rset(regs, mem:read8(pc + 1), mul32(rget(regs, mem:read8(pc + 2)), rget(regs, mem:read8(pc + 3))))
		pc += 4
	elseif op == 0x13 then -- DIV, unsigned; division by zero yields 0
		local divisor = rget(regs, mem:read8(pc + 3))
		if divisor == 0 then
			rset(regs, mem:read8(pc + 1), 0)
		else
			rset(regs, mem:read8(pc + 1), math.floor(rget(regs, mem:read8(pc + 2)) / divisor))
		end
		pc += 4
	elseif op == 0x14 then -- REM, unsigned; division by zero yields 0
		local divisor = rget(regs, mem:read8(pc + 3))
		if divisor == 0 then
			rset(regs, mem:read8(pc + 1), 0)
		else
			rset(regs, mem:read8(pc + 1), rget(regs, mem:read8(pc + 2)) % divisor)
		end
		pc += 4
	elseif op == 0x15 then -- AND
		rset(regs, mem:read8(pc + 1), bit32.band(rget(regs, mem:read8(pc + 2)), rget(regs, mem:read8(pc + 3))))
		pc += 4
	elseif op == 0x16 then -- OR
		rset(regs, mem:read8(pc + 1), bit32.bor(rget(regs, mem:read8(pc + 2)), rget(regs, mem:read8(pc + 3))))
		pc += 4
	elseif op == 0x17 then -- XOR
		rset(regs, mem:read8(pc + 1), bit32.bxor(rget(regs, mem:read8(pc + 2)), rget(regs, mem:read8(pc + 3))))
		pc += 4
	elseif op == 0x18 then -- SHL
		rset(regs, mem:read8(pc + 1), shl(rget(regs, mem:read8(pc + 2)), rget(regs, mem:read8(pc + 3))))
		pc += 4
	elseif op == 0x19 then -- SHR
		rset(regs, mem:read8(pc + 1), shr(rget(regs, mem:read8(pc + 2)), rget(regs, mem:read8(pc + 3))))
		pc += 4
	elseif op == 0x1A then -- SAR
		rset(regs, mem:read8(pc + 1), sar(rget(regs, mem:read8(pc + 2)), rget(regs, mem:read8(pc + 3))))
		pc += 4
	elseif op == 0x1B then -- NOT
		rset(regs, mem:read8(pc + 1), bit32.bnot(rget(regs, mem:read8(pc + 2))))
		pc += 4
	elseif op == 0x1C then -- SLT, signed
		if toSigned(rget(regs, mem:read8(pc + 2))) < toSigned(rget(regs, mem:read8(pc + 3))) then
			rset(regs, mem:read8(pc + 1), 1)
		else
			rset(regs, mem:read8(pc + 1), 0)
		end
		pc += 4
	elseif op == 0x1D then -- SLTU, unsigned
		if rget(regs, mem:read8(pc + 2)) < rget(regs, mem:read8(pc + 3)) then
			rset(regs, mem:read8(pc + 1), 1)
		else
			rset(regs, mem:read8(pc + 1), 0)
		end
		pc += 4
	elseif op == 0x1E then -- SEQ
		if rget(regs, mem:read8(pc + 2)) == rget(regs, mem:read8(pc + 3)) then
			rset(regs, mem:read8(pc + 1), 1)
		else
			rset(regs, mem:read8(pc + 1), 0)
		end
		pc += 4
	elseif op == 0x1F then -- SNE
		if rget(regs, mem:read8(pc + 2)) ~= rget(regs, mem:read8(pc + 3)) then
			rset(regs, mem:read8(pc + 1), 1)
		else
			rset(regs, mem:read8(pc + 1), 0)
		end
		pc += 4

	--=================================================================
	-- Register-immediate ALU (form F3: op rd rs imm8)
	--=================================================================
	elseif op == 0x20 then -- ADDI, sign-extended immediate
		rset(regs, mem:read8(pc + 1), rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3)))
		pc += 4
	elseif op == 0x21 then -- ANDI
		rset(regs, mem:read8(pc + 1), bit32.band(rget(regs, mem:read8(pc + 2)), mem:read8(pc + 3)))
		pc += 4
	elseif op == 0x22 then -- ORI
		rset(regs, mem:read8(pc + 1), bit32.bor(rget(regs, mem:read8(pc + 2)), mem:read8(pc + 3)))
		pc += 4
	elseif op == 0x23 then -- XORI
		rset(regs, mem:read8(pc + 1), bit32.bxor(rget(regs, mem:read8(pc + 2)), mem:read8(pc + 3)))
		pc += 4
	elseif op == 0x24 then -- SHLI
		rset(regs, mem:read8(pc + 1), shl(rget(regs, mem:read8(pc + 2)), mem:read8(pc + 3)))
		pc += 4
	elseif op == 0x25 then -- SHRI
		rset(regs, mem:read8(pc + 1), shr(rget(regs, mem:read8(pc + 2)), mem:read8(pc + 3)))
		pc += 4
	elseif op == 0x26 then -- MULI
		rset(regs, mem:read8(pc + 1), mul32(rget(regs, mem:read8(pc + 2)), mem:read8(pc + 3)))
		pc += 4
	elseif op == 0x28 then -- LI (form F4: op rd imm32)
		rset(regs, mem:read8(pc + 1), mem:read32(pc + 2))
		pc += 6

	--=================================================================
	-- Loads, stores, shared memory and atomics
	--=================================================================
	elseif op == 0x30 then -- LB
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		local value = mem:read8(address)
		cost += mem.lastCost
		if value >= 128 then
			value -= 256
		end
		rset(regs, mem:read8(pc + 1), value)
		pc += 4
	elseif op == 0x31 then -- LBU
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		local value = mem:read8(address)
		cost += mem.lastCost
		rset(regs, mem:read8(pc + 1), value)
		pc += 4
	elseif op == 0x32 then -- LH
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		local value = mem:read16(address)
		cost += mem.lastCost
		if value >= 32768 then
			value -= 65536
		end
		rset(regs, mem:read8(pc + 1), value)
		pc += 4
	elseif op == 0x33 then -- LHU
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		local value = mem:read16(address)
		cost += mem.lastCost
		rset(regs, mem:read8(pc + 1), value)
		pc += 4
	elseif op == 0x34 then -- LW
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		local value = mem:read32(address)
		cost += mem.lastCost
		rset(regs, mem:read8(pc + 1), value)
		pc += 4
	elseif op == 0x35 then -- LWS (shared word load)
		local wordIndex = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		local value = mem:readShared(wordIndex)
		cost += mem.lastCost
		rset(regs, mem:read8(pc + 1), value)
		pc += 4
	elseif op == 0x38 then -- SB
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		mem:write8(address, rget(regs, mem:read8(pc + 1)))
		cost += mem.lastCost
		pc += 4
	elseif op == 0x39 then -- SH
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		mem:write16(address, rget(regs, mem:read8(pc + 1)))
		cost += mem.lastCost
		pc += 4
	elseif op == 0x3A then -- SW
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		mem:write32(address, rget(regs, mem:read8(pc + 1)))
		cost += mem.lastCost
		pc += 4
	elseif op == 0x3B then -- SWS (shared word store)
		local wordIndex = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		mem:writeShared(wordIndex, rget(regs, mem:read8(pc + 1)))
		cost += mem.lastCost
		pc += 4
	elseif op == 0x3C then -- AMOADD (atomic shared word fetch-and-add)
		local wordIndex = rget(regs, mem:read8(pc + 2))
		local delta = rget(regs, mem:read8(pc + 3))
		local prev = mem:atomicAddShared(wordIndex, delta)
		cost += mem.lastCost
		rset(regs, mem:read8(pc + 1), prev)
		pc += 4

	--=================================================================
	-- Branches (form F5: op rs rt imm16, offset relative to this instruction)
	--=================================================================
	elseif op == 0x40 then -- BEQ
		if rget(regs, mem:read8(pc + 1)) == rget(regs, mem:read8(pc + 2)) then
			pc += sign16(mem:read16(pc + 3))
		else
			pc += 5
		end
	elseif op == 0x41 then -- BNE
		if rget(regs, mem:read8(pc + 1)) ~= rget(regs, mem:read8(pc + 2)) then
			pc += sign16(mem:read16(pc + 3))
		else
			pc += 5
		end
	elseif op == 0x42 then -- BLT, signed
		if toSigned(rget(regs, mem:read8(pc + 1))) < toSigned(rget(regs, mem:read8(pc + 2))) then
			pc += sign16(mem:read16(pc + 3))
		else
			pc += 5
		end
	elseif op == 0x43 then -- BGE, signed
		if toSigned(rget(regs, mem:read8(pc + 1))) >= toSigned(rget(regs, mem:read8(pc + 2))) then
			pc += sign16(mem:read16(pc + 3))
		else
			pc += 5
		end
	elseif op == 0x44 then -- BLTU
		if rget(regs, mem:read8(pc + 1)) < rget(regs, mem:read8(pc + 2)) then
			pc += sign16(mem:read16(pc + 3))
		else
			pc += 5
		end
	elseif op == 0x45 then -- BGEU
		if rget(regs, mem:read8(pc + 1)) >= rget(regs, mem:read8(pc + 2)) then
			pc += sign16(mem:read16(pc + 3))
		else
			pc += 5
		end

	--=================================================================
	-- Jumps (JMP and JAL are form F4, JALR is form F3)
	--=================================================================
	elseif op == 0x46 then -- JMP
		pc = mem:read32(pc + 2)
	elseif op == 0x47 then -- JAL
		local target = mem:read32(pc + 2)
		rset(regs, mem:read8(pc + 1), pc + 6)
		pc = target
	elseif op == 0x48 then -- JALR
		local target = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		rset(regs, mem:read8(pc + 1), pc + 4)
		pc = target

	--=================================================================
	-- System
	--=================================================================
	elseif op == 0x50 then -- ECALL, the only host boundary
		self.traps += 1
		local handler = self.onTrap
		if handler ~= nil then
			local first, second = handler(self, rget(regs, 1))
			rset(regs, 1, first or 0)
			rset(regs, 2, second or 0)
		else
			self.halted = true
			self.exitCode = rget(regs, 1)
		end
		pc += 1
	elseif op == 0x51 then -- EBREAK
		pc += 1
	elseif op == 0x52 then -- HALT
		self.halted = true
		self.exitCode = rget(regs, 1)
		pc += 1
	elseif op == 0x53 then -- YIELD
		self.yielded = true
		pc += 1
	elseif op == 0x54 then -- SYNC
		pc += 1
		if self.onSync ~= nil then
			self.onSync(self)
		end

	--=================================================================
	-- Vector / float unit + Z-NPU instructions (docs/01-isa.md, docs/07-npu.md)
	--=================================================================
	elseif op == 0x60 then -- VLW
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		cost += mem.lastCost
		self.vecs[(mem:read8(pc + 1) % 8) + 1] = vector.create(
			mem:readf32(address),
			mem:readf32(address + 4),
			mem:readf32(address + 8)
		)
		pc += 4
	elseif op == 0x61 then -- VSW
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		local value = self.vecs[(mem:read8(pc + 1) % 8) + 1]
		cost += mem.lastCost
		mem:writef32(address, value.x)
		mem:writef32(address + 4, value.y)
		mem:writef32(address + 8, value.z)
		pc += 4
	elseif op == 0x62 then -- VADD
		cost += 2
		self.vecs[(mem:read8(pc + 1) % 8) + 1] = self.vecs[(mem:read8(pc + 2) % 8) + 1] + self.vecs[(mem:read8(pc + 3) % 8) + 1]
		pc += 4
	elseif op == 0x63 then -- VSUB
		cost += 2
		self.vecs[(mem:read8(pc + 1) % 8) + 1] = self.vecs[(mem:read8(pc + 2) % 8) + 1] - self.vecs[(mem:read8(pc + 3) % 8) + 1]
		pc += 4
	elseif op == 0x64 then -- VMUL
		cost += 2
		self.vecs[(mem:read8(pc + 1) % 8) + 1] = self.vecs[(mem:read8(pc + 2) % 8) + 1] * self.vecs[(mem:read8(pc + 3) % 8) + 1]
		pc += 4
	elseif op == 0x65 then -- VDOT / VDP3, result as float bits
		cost += 2
		local a = self.vecs[(mem:read8(pc + 2) % 8) + 1]
		local b = self.vecs[(mem:read8(pc + 3) % 8) + 1]
		rset(regs, mem:read8(pc + 1), self:f32Bits(a.x * b.x + a.y * b.y + a.z * b.z))
		pc += 4
	elseif op == 0x66 then -- VLEN, result as float bits
		cost += 2
		local a = self.vecs[(mem:read8(pc + 2) % 8) + 1]
		rset(regs, mem:read8(pc + 1), self:f32Bits(math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)))
		pc += 4
	elseif op == 0x67 then -- VNRM
		cost += 2
		local a = self.vecs[(mem:read8(pc + 2) % 8) + 1]
		local magnitude = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
		if magnitude > 0 then
			self.vecs[(mem:read8(pc + 1) % 8) + 1] = vector.create(a.x / magnitude, a.y / magnitude, a.z / magnitude)
		else
			self.vecs[(mem:read8(pc + 1) % 8) + 1] = ZERO_VEC
		end
		pc += 4
	elseif op == 0x68 then -- VCST
		if mem:read8(pc + 3) == 1 then
			self.vecs[(mem:read8(pc + 1) % 8) + 1] = ONE_VEC
		else
			self.vecs[(mem:read8(pc + 1) % 8) + 1] = ZERO_VEC
		end
		pc += 4
	elseif op == 0x69 then -- VFMA: vd = vs * vt + vd
		cost += 2
		local vd = (mem:read8(pc + 1) % 8) + 1
		local vs = (mem:read8(pc + 2) % 8) + 1
		local vt = (mem:read8(pc + 3) % 8) + 1
		self.vecs[vd] = self.vecs[vs] * self.vecs[vt] + self.vecs[vd]
		pc += 4
	elseif op == 0x6A then -- VRED: rd = vs.x + vs.y + vs.z (as float bits)
		cost += 2
		local a = self.vecs[(mem:read8(pc + 2) % 8) + 1]
		rset(regs, mem:read8(pc + 1), self:f32Bits(a.x + a.y + a.z))
		pc += 4
	elseif op == 0x6B then -- VSCL: vd = vs * scalar(rt)
		cost += 2
		local vd = (mem:read8(pc + 1) % 8) + 1
		local vs = (mem:read8(pc + 2) % 8) + 1
		local s = self:bitsF32(rget(regs, mem:read8(pc + 3)))
		self.vecs[vd] = self.vecs[vs] * s
		pc += 4
	elseif op == 0x6C then -- VMIN: vd = min(vs, vt)
		cost += 2
		local vd = (mem:read8(pc + 1) % 8) + 1
		local vs = (mem:read8(pc + 2) % 8) + 1
		local vt = (mem:read8(pc + 3) % 8) + 1
		self.vecs[vd] = vector.min(self.vecs[vs], self.vecs[vt])
		pc += 4
	elseif op == 0x6D then -- VMAX: vd = max(vs, vt)
		cost += 2
		local vd = (mem:read8(pc + 1) % 8) + 1
		local vs = (mem:read8(pc + 2) % 8) + 1
		local vt = (mem:read8(pc + 3) % 8) + 1
		self.vecs[vd] = vector.max(self.vecs[vs], self.vecs[vt])
		pc += 4

	else
		-- Illegal instruction: stop the core with a distinctive exit code
		-- rather than silently executing whatever follows.
		self.halted = true
		self.exitCode = 255
		error(string.format('Z32 illegal opcode 0x%02X at 0x%08X', op, pc), 0)
	end

	self.pc = pc % WRAP
	self.cycles += cost
	self.steps += 1

	if self.irqEnabled and self.steps % 256 == 0 then
		self:pollInterrupts()
	end

	return cost
end

--=====================================================================
-- Tier 1 & Tier 2: Basic-Block Compiler and Native Block Executor
--=====================================================================

--- Decode a basic block starting at `entryPc` into a flat 16-byte-per-uop buffer.
--- In Tier 2 (`self.tier >= 2`), constant shifts (`SHLI`/`SHRI`) are strength-reduced
--- to precomputed power-of-two multipliers/divisors (`2^k`).
function Core.compileBlock(self: Class, entryPc: number): Block
	local mem = self.mem
	local ram = mem.ram
	local ramSize = mem.ramSize
	local tier = self.tier

	-- Temporary staging buffer for up to MAX_BLOCK_LEN instructions.
	local staging = buffer.create(MAX_BLOCK_LEN * UOP_SIZE)
	local pc = entryPc
	local count = 0

	while count < MAX_BLOCK_LEN and pc >= 0 and pc + 6 <= ramSize do
		local op = buffer.readu8(ram, pc)
		local size: number = Opcodes.sizeOf(op)
		local nextPc = (pc + size) % WRAP
		local base = count * UOP_SIZE

		buffer.writeu8(staging, base + 0, op)
		buffer.writeu32(staging, base + 8, pc)
		buffer.writeu32(staging, base + 12, nextPc)

		if op == 0x00 or (op >= 0x50 and op <= 0x54) then
			-- Form F1: no operands
			buffer.writeu8(staging, base + 1, 0)
			buffer.writeu8(staging, base + 2, 0)
			buffer.writeu8(staging, base + 3, 0)
			buffer.writeu32(staging, base + 4, 0)
		elseif op >= 0x10 and op <= 0x1F then
			-- Form F2 integer ALU: rd, rs, rt
			buffer.writeu8(staging, base + 1, sinkOrReg(buffer.readu8(ram, pc + 1)))
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 32) * 4)
			buffer.writeu8(staging, base + 3, (buffer.readu8(ram, pc + 3) % 32) * 4)
			buffer.writeu32(staging, base + 4, 0)
		elseif op == 0x20 then
			-- ADDI: rd, rs, signed imm8
			buffer.writeu8(staging, base + 1, sinkOrReg(buffer.readu8(ram, pc + 1)))
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 32) * 4)
			buffer.writeu8(staging, base + 3, 0)
			buffer.writei32(staging, base + 4, buffer.readi8(ram, pc + 3))
		elseif op >= 0x21 and op <= 0x26 then
			-- ANDI, ORI, XORI, SHLI, SHRI, MULI: rd, rs, unsigned imm8
			local imm8 = buffer.readu8(ram, pc + 3)
			buffer.writeu8(staging, base + 1, sinkOrReg(buffer.readu8(ram, pc + 1)))
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 32) * 4)
			buffer.writeu8(staging, base + 3, imm8)
			if tier >= 2 and (op == 0x24 or op == 0x25) then
				-- Tier 2 strength-reduction: precompute 2^k for SHLI/SHRI (0 if k >= 32).
				if imm8 >= 32 then
					buffer.writeu32(staging, base + 4, 0)
				else
					buffer.writeu32(staging, base + 4, bit32.lshift(1, imm8))
				end
			else
				buffer.writeu32(staging, base + 4, imm8)
			end
		elseif op == 0x28 then
			-- LI: rd, imm32
			buffer.writeu8(staging, base + 1, sinkOrReg(buffer.readu8(ram, pc + 1)))
			buffer.writeu8(staging, base + 2, 0)
			buffer.writeu8(staging, base + 3, 0)
			buffer.writeu32(staging, base + 4, buffer.readu32(ram, pc + 2))
		elseif op >= 0x30 and op <= 0x35 then
			-- LB, LBU, LH, LHU, LW, LWS: rd, rs, signed disp8
			buffer.writeu8(staging, base + 1, sinkOrReg(buffer.readu8(ram, pc + 1)))
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 32) * 4)
			buffer.writeu8(staging, base + 3, 0)
			buffer.writei32(staging, base + 4, buffer.readi8(ram, pc + 3))
		elseif op >= 0x38 and op <= 0x3B then
			-- SB, SH, SW, SWS: source rt (read!), base rs, signed disp8
			buffer.writeu8(staging, base + 1, (buffer.readu8(ram, pc + 1) % 32) * 4)
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 32) * 4)
			buffer.writeu8(staging, base + 3, 0)
			buffer.writei32(staging, base + 4, buffer.readi8(ram, pc + 3))
		elseif op == 0x3C then
			-- AMOADD: rd, rs, rt
			buffer.writeu8(staging, base + 1, sinkOrReg(buffer.readu8(ram, pc + 1)))
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 32) * 4)
			buffer.writeu8(staging, base + 3, (buffer.readu8(ram, pc + 3) % 32) * 4)
			buffer.writeu32(staging, base + 4, 0)
		elseif op >= 0x40 and op <= 0x45 then
			-- Branches (F5): rs, rt, precomputed target PC
			local offset16 = buffer.readi16(ram, pc + 3)
			buffer.writeu8(staging, base + 1, (buffer.readu8(ram, pc + 1) % 32) * 4)
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 32) * 4)
			buffer.writeu8(staging, base + 3, 0)
			buffer.writeu32(staging, base + 4, (pc + offset16) % WRAP)
		elseif op == 0x46 or op == 0x47 then
			-- JMP, JAL (F4): rd, target32
			buffer.writeu8(staging, base + 1, sinkOrReg(buffer.readu8(ram, pc + 1)))
			buffer.writeu8(staging, base + 2, 0)
			buffer.writeu8(staging, base + 3, 0)
			buffer.writeu32(staging, base + 4, buffer.readu32(ram, pc + 2))
		elseif op == 0x48 then
			-- JALR (F3): rd, rs, signed disp8
			buffer.writeu8(staging, base + 1, sinkOrReg(buffer.readu8(ram, pc + 1)))
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 32) * 4)
			buffer.writeu8(staging, base + 3, 0)
			buffer.writei32(staging, base + 4, buffer.readi8(ram, pc + 3))
		elseif op == 0x60 or op == 0x61 then
			-- VLW, VSW (F7): vd (1..8), rs, signed disp8
			buffer.writeu8(staging, base + 1, (buffer.readu8(ram, pc + 1) % 8) + 1)
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 32) * 4)
			buffer.writeu8(staging, base + 3, 0)
			buffer.writei32(staging, base + 4, buffer.readi8(ram, pc + 3))
		elseif op == 0x62 or op == 0x63 or op == 0x64 or op == 0x67 or op == 0x69 or op == 0x6C or op == 0x6D then
			-- VADD, VSUB, VMUL, VNRM, VFMA, VMIN, VMAX (F6): vd, vs, vt (1..8)
			buffer.writeu8(staging, base + 1, (buffer.readu8(ram, pc + 1) % 8) + 1)
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 8) + 1)
			buffer.writeu8(staging, base + 3, (buffer.readu8(ram, pc + 3) % 8) + 1)
			buffer.writeu32(staging, base + 4, 0)
		elseif op == 0x65 or op == 0x66 or op == 0x6A then
			-- VDOT, VLEN, VRED (F2): GPR rd, vs, vt (1..8)
			buffer.writeu8(staging, base + 1, sinkOrReg(buffer.readu8(ram, pc + 1)))
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 8) + 1)
			buffer.writeu8(staging, base + 3, (buffer.readu8(ram, pc + 3) % 8) + 1)
			buffer.writeu32(staging, base + 4, 0)
		elseif op == 0x68 then
			-- VCST (F3): vd (1..8), imm8
			buffer.writeu8(staging, base + 1, (buffer.readu8(ram, pc + 1) % 8) + 1)
			buffer.writeu8(staging, base + 2, 0)
			buffer.writeu8(staging, base + 3, buffer.readu8(ram, pc + 3))
			buffer.writeu32(staging, base + 4, buffer.readu8(ram, pc + 3))
		elseif op == 0x6B then
			-- VSCL (F2): vd (1..8), vs (1..8), scalar GPR rt
			buffer.writeu8(staging, base + 1, (buffer.readu8(ram, pc + 1) % 8) + 1)
			buffer.writeu8(staging, base + 2, (buffer.readu8(ram, pc + 2) % 8) + 1)
			buffer.writeu8(staging, base + 3, (buffer.readu8(ram, pc + 3) % 32) * 4)
			buffer.writeu32(staging, base + 4, 0)
		else
			-- Illegal opcode: include as the terminator uop so runBlock faults at this exact PC.
			count += 1
			pc = nextPc
			break
		end

		count += 1
		pc = nextPc
		if isBlockTerminator(op) then
			break
		end
	end

	local byteLen = count * UOP_SIZE
	local uops = buffer.create(if byteLen > 0 then byteLen else UOP_SIZE)
	if byteLen > 0 then
		buffer.copy(uops, 0, staging, 0, byteLen)
	end

	local firstWord = if entryPc + 4 <= ramSize then buffer.readu32(ram, entryPc) else 0
	local block: Block = {
		startPc = entryPc,
		endPc = pc,
		count = count,
		uops = uops,
		codeGen = mem.codeGen,
		firstWord = firstWord,
	}
	mem:markCodeRange(entryPc, pc)
	self.blocks[entryPc] = block
	self.stats.blocksCompiled += 1
	return block
end

--- Execute a compiled basic block up to `budget` cycles.
--- Self-looping blocks (`pc == startPc`) remain inside this native loop until
--- the branch falls through or the cycle budget is reached.
function Core.runBlock(self: Class, block: Block, budget: number): number
	local mem = self.mem
	local ram: buffer = mem.ram
	local ramSize: number = mem.ramSize
	local regs: buffer = self.regs
	local vecs: { vector } = self.vecs
	local scratch: buffer = self.scratch
	local uops: buffer = block.uops
	local endOffset: number = block.count * UOP_SIZE
	local startPc: number = block.startPc
	local blockCodeGen: number = block.codeGen
	local tier: number = self.tier

	local used: number = 0
	local cycles: number = self.cycles
	local steps: number = self.steps
	local pc: number = startPc
	local offset: number = 0
	local executedInBlock: number = 0

	while offset < endOffset do
		local op = buffer.readu8(uops, offset)
		local a = buffer.readu8(uops, offset + 1)
		local b = buffer.readu8(uops, offset + 2)
		local c = buffer.readu8(uops, offset + 3)
		local nextPc = buffer.readu32(uops, offset + 12)
		local cost = 1
		local branched = false

		if op == 0x00 then -- NOP
			pc = nextPc

		--=============================================================
		-- Form F2 register-register ALU
		--=============================================================
		elseif op == 0x10 then -- ADD
			buffer.writeu32(regs, a, buffer.readu32(regs, b) + buffer.readu32(regs, c))
			pc = nextPc
		elseif op == 0x11 then -- SUB
			buffer.writeu32(regs, a, buffer.readu32(regs, b) - buffer.readu32(regs, c))
			pc = nextPc
		elseif op == 0x12 then -- MUL
			buffer.writeu32(regs, a, mul32(buffer.readu32(regs, b), buffer.readu32(regs, c)))
			pc = nextPc
		elseif op == 0x13 then -- DIV
			local divisor = buffer.readu32(regs, c)
			if divisor == 0 then
				buffer.writeu32(regs, a, 0)
			else
				buffer.writeu32(regs, a, math.floor(buffer.readu32(regs, b) / divisor))
			end
			pc = nextPc
		elseif op == 0x14 then -- REM
			local divisor = buffer.readu32(regs, c)
			if divisor == 0 then
				buffer.writeu32(regs, a, 0)
			else
				buffer.writeu32(regs, a, buffer.readu32(regs, b) % divisor)
			end
			pc = nextPc
		elseif op == 0x15 then -- AND
			buffer.writeu32(regs, a, bit32.band(buffer.readu32(regs, b), buffer.readu32(regs, c)))
			pc = nextPc
		elseif op == 0x16 then -- OR
			buffer.writeu32(regs, a, bit32.bor(buffer.readu32(regs, b), buffer.readu32(regs, c)))
			pc = nextPc
		elseif op == 0x17 then -- XOR
			buffer.writeu32(regs, a, bit32.bxor(buffer.readu32(regs, b), buffer.readu32(regs, c)))
			pc = nextPc
		elseif op == 0x18 then -- SHL
			buffer.writeu32(regs, a, shl(buffer.readu32(regs, b), buffer.readu32(regs, c)))
			pc = nextPc
		elseif op == 0x19 then -- SHR
			buffer.writeu32(regs, a, shr(buffer.readu32(regs, b), buffer.readu32(regs, c)))
			pc = nextPc
		elseif op == 0x1A then -- SAR
			buffer.writeu32(regs, a, sar(buffer.readu32(regs, b), buffer.readu32(regs, c)))
			pc = nextPc
		elseif op == 0x1B then -- NOT
			buffer.writeu32(regs, a, bit32.bnot(buffer.readu32(regs, b)))
			pc = nextPc
		elseif op == 0x1C then -- SLT (signed)
			buffer.writeu32(regs, a, if buffer.readi32(regs, b) < buffer.readi32(regs, c) then 1 else 0)
			pc = nextPc
		elseif op == 0x1D then -- SLTU (unsigned)
			buffer.writeu32(regs, a, if buffer.readu32(regs, b) < buffer.readu32(regs, c) then 1 else 0)
			pc = nextPc
		elseif op == 0x1E then -- SEQ
			buffer.writeu32(regs, a, if buffer.readu32(regs, b) == buffer.readu32(regs, c) then 1 else 0)
			pc = nextPc
		elseif op == 0x1F then -- SNE
			buffer.writeu32(regs, a, if buffer.readu32(regs, b) ~= buffer.readu32(regs, c) then 1 else 0)
			pc = nextPc

		--=============================================================
		-- Form F3 / F4 register-immediate ALU
		--=============================================================
		elseif op == 0x20 then -- ADDI
			buffer.writeu32(regs, a, buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4))
			pc = nextPc
		elseif op == 0x21 then -- ANDI
			buffer.writeu32(regs, a, bit32.band(buffer.readu32(regs, b), c))
			pc = nextPc
		elseif op == 0x22 then -- ORI
			buffer.writeu32(regs, a, bit32.bor(buffer.readu32(regs, b), c))
			pc = nextPc
		elseif op == 0x23 then -- XORI
			buffer.writeu32(regs, a, bit32.bxor(buffer.readu32(regs, b), c))
			pc = nextPc
		elseif op == 0x24 then -- SHLI
			if tier >= 2 then
				local scale = buffer.readu32(uops, offset + 4)
				if scale == 0 then
					buffer.writeu32(regs, a, 0)
				else
					local val = buffer.readu32(regs, b)
					buffer.writeu32(regs, a, (val % (WRAP / scale)) * scale)
				end
			else
				buffer.writeu32(regs, a, shl(buffer.readu32(regs, b), c))
			end
			pc = nextPc
		elseif op == 0x25 then -- SHRI
			if tier >= 2 then
				local scale = buffer.readu32(uops, offset + 4)
				if scale == 0 then
					buffer.writeu32(regs, a, 0)
				else
					buffer.writeu32(regs, a, math.floor(buffer.readu32(regs, b) / scale))
				end
			else
				buffer.writeu32(regs, a, shr(buffer.readu32(regs, b), c))
			end
			pc = nextPc
		elseif op == 0x26 then -- MULI
			buffer.writeu32(regs, a, mul32(buffer.readu32(regs, b), c))
			pc = nextPc
		elseif op == 0x28 then -- LI
			buffer.writeu32(regs, a, buffer.readu32(uops, offset + 4))
			pc = nextPc

		--=============================================================
		-- Loads, stores, shared memory and atomics
		--=============================================================
		elseif op == 0x30 then -- LB
			local rawAddr = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			if rawAddr >= 0 and rawAddr < ramSize then
				mem.lastCost = 1
				cost += 1
				buffer.writeu32(regs, a, buffer.readi8(ram, rawAddr))
			else
				self.cycles = cycles
				local val = mem:read8(rawAddr)
				cost += mem.lastCost
				if val >= 128 then
					val -= 256
				end
				buffer.writeu32(regs, a, val)
			end
			pc = nextPc
		elseif op == 0x31 then -- LBU
			local rawAddr = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			if rawAddr >= 0 and rawAddr < ramSize then
				mem.lastCost = 1
				cost += 1
				buffer.writeu32(regs, a, buffer.readu8(ram, rawAddr))
			else
				self.cycles = cycles
				local val = mem:read8(rawAddr)
				cost += mem.lastCost
				buffer.writeu32(regs, a, val)
			end
			pc = nextPc
		elseif op == 0x32 then -- LH
			local rawAddr = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			if rawAddr >= 0 and rawAddr <= ramSize - 2 then
				mem.lastCost = 1
				cost += 1
				buffer.writeu32(regs, a, buffer.readi16(ram, rawAddr))
			else
				self.cycles = cycles
				local val = mem:read16(rawAddr)
				cost += mem.lastCost
				if val >= 32768 then
					val -= 65536
				end
				buffer.writeu32(regs, a, val)
			end
			pc = nextPc
		elseif op == 0x33 then -- LHU
			local rawAddr = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			if rawAddr >= 0 and rawAddr <= ramSize - 2 then
				mem.lastCost = 1
				cost += 1
				buffer.writeu32(regs, a, buffer.readu16(ram, rawAddr))
			else
				self.cycles = cycles
				local val = mem:read16(rawAddr)
				cost += mem.lastCost
				buffer.writeu32(regs, a, val)
			end
			pc = nextPc
		elseif op == 0x34 then -- LW
			local rawAddr = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			if rawAddr >= 0 and rawAddr <= ramSize - 4 then
				mem.lastCost = 1
				cost += 1
				buffer.writeu32(regs, a, buffer.readu32(ram, rawAddr))
			else
				self.cycles = cycles
				local val = mem:read32(rawAddr)
				cost += mem.lastCost
				buffer.writeu32(regs, a, val)
			end
			pc = nextPc
		elseif op == 0x35 then -- LWS
			local wordIndex = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			local val = mem:readShared(wordIndex)
			cost += mem.lastCost
			buffer.writeu32(regs, a, val)
			pc = nextPc
		elseif op == 0x38 then -- SB
			local rawAddr = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			if rawAddr >= 0 and rawAddr < ramSize then
				mem.lastCost = 1
				cost += 1
				buffer.writeu8(ram, rawAddr, buffer.readu32(regs, a))
				if rawAddr < mem.codeHigh and rawAddr + 1 > mem.codeLow then
					mem:notifyCodeWrite(rawAddr, 1)
				end
			else
				self.cycles = cycles
				mem:write8(rawAddr, buffer.readu32(regs, a))
				cost += mem.lastCost
			end
			pc = nextPc
		elseif op == 0x39 then -- SH
			local rawAddr = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			if rawAddr >= 0 and rawAddr <= ramSize - 2 then
				mem.lastCost = 1
				cost += 1
				buffer.writeu16(ram, rawAddr, buffer.readu32(regs, a))
				if rawAddr < mem.codeHigh and rawAddr + 2 > mem.codeLow then
					mem:notifyCodeWrite(rawAddr, 2)
				end
			else
				self.cycles = cycles
				mem:write16(rawAddr, buffer.readu32(regs, a))
				cost += mem.lastCost
			end
			pc = nextPc
		elseif op == 0x3A then -- SW
			local rawAddr = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			if rawAddr >= 0 and rawAddr <= ramSize - 4 then
				mem.lastCost = 1
				cost += 1
				buffer.writeu32(ram, rawAddr, buffer.readu32(regs, a))
				if rawAddr < mem.codeHigh and rawAddr + 4 > mem.codeLow then
					mem:notifyCodeWrite(rawAddr, 4)
				end
			else
				self.cycles = cycles
				mem:write32(rawAddr, buffer.readu32(regs, a))
				cost += mem.lastCost
			end
			pc = nextPc
		elseif op == 0x3B then -- SWS
			local wordIndex = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			mem:writeShared(wordIndex, buffer.readu32(regs, a))
			cost += mem.lastCost
			pc = nextPc
		elseif op == 0x3C then -- AMOADD
			local wordIndex = buffer.readu32(regs, b)
			local delta = buffer.readu32(regs, c)
			local prev = mem:atomicAddShared(wordIndex, delta)
			cost += mem.lastCost
			buffer.writeu32(regs, a, prev)
			pc = nextPc

		--=============================================================
		-- Branches and jumps
		--=============================================================
		elseif op == 0x40 then -- BEQ
			branched = true
			pc = if buffer.readu32(regs, a) == buffer.readu32(regs, b) then buffer.readu32(uops, offset + 4) else nextPc
		elseif op == 0x41 then -- BNE
			branched = true
			pc = if buffer.readu32(regs, a) ~= buffer.readu32(regs, b) then buffer.readu32(uops, offset + 4) else nextPc
		elseif op == 0x42 then -- BLT (signed)
			branched = true
			pc = if buffer.readi32(regs, a) < buffer.readi32(regs, b) then buffer.readu32(uops, offset + 4) else nextPc
		elseif op == 0x43 then -- BGE (signed)
			branched = true
			pc = if buffer.readi32(regs, a) >= buffer.readi32(regs, b) then buffer.readu32(uops, offset + 4) else nextPc
		elseif op == 0x44 then -- BLTU
			branched = true
			pc = if buffer.readu32(regs, a) < buffer.readu32(regs, b) then buffer.readu32(uops, offset + 4) else nextPc
		elseif op == 0x45 then -- BGEU
			branched = true
			pc = if buffer.readu32(regs, a) >= buffer.readu32(regs, b) then buffer.readu32(uops, offset + 4) else nextPc
		elseif op == 0x46 then -- JMP
			branched = true
			pc = buffer.readu32(uops, offset + 4)
		elseif op == 0x47 then -- JAL
			branched = true
			local target = buffer.readu32(uops, offset + 4)
			buffer.writeu32(regs, a, nextPc)
			pc = target
		elseif op == 0x48 then -- JALR
			branched = true
			local target = (buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)) % WRAP
			buffer.writeu32(regs, a, nextPc)
			pc = target

		--=============================================================
		-- System
		--=============================================================
		elseif op == 0x50 then -- ECALL
			branched = true
			self.pc = pc
			self.cycles = cycles
			self.steps = steps
			self.traps += 1
			local handler = self.onTrap
			if handler ~= nil then
				local first, second = handler(self, buffer.readu32(regs, 4))
				buffer.writeu32(regs, 4, first or 0)
				buffer.writeu32(regs, 8, second or 0)
			else
				self.halted = true
				self.exitCode = buffer.readu32(regs, 4)
			end
			pc = nextPc
		elseif op == 0x51 then -- EBREAK
			branched = true
			pc = nextPc
		elseif op == 0x52 then -- HALT
			branched = true
			self.halted = true
			self.exitCode = buffer.readu32(regs, 4)
			pc = nextPc
		elseif op == 0x53 then -- YIELD
			branched = true
			self.yielded = true
			pc = nextPc
		elseif op == 0x54 then -- SYNC
			branched = true
			pc = nextPc
			if self.onSync ~= nil then
				self.onSync(self)
			end

		--=============================================================
		-- Vector / float unit + Z-NPU instructions
		--=============================================================
		elseif op == 0x60 then -- VLW
			local rawAddr = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			if rawAddr >= 0 and rawAddr <= ramSize - 12 then
				mem.lastCost = 1
				cost += 1
				vecs[a] = vector.create(
					buffer.readf32(ram, rawAddr),
					buffer.readf32(ram, rawAddr + 4),
					buffer.readf32(ram, rawAddr + 8)
				)
			else
				vecs[a] = vector.create(
					mem:readf32(rawAddr),
					mem:readf32(rawAddr + 4),
					mem:readf32(rawAddr + 8)
				)
				cost += mem.lastCost
			end
			pc = nextPc
		elseif op == 0x61 then -- VSW
			local rawAddr = buffer.readu32(regs, b) + buffer.readi32(uops, offset + 4)
			local val: vector = vecs[a]
			if rawAddr >= 0 and rawAddr <= ramSize - 12 then
				mem.lastCost = 1
				cost += 1
				buffer.writef32(ram, rawAddr, val.x)
				buffer.writef32(ram, rawAddr + 4, val.y)
				buffer.writef32(ram, rawAddr + 8, val.z)
				if rawAddr < mem.codeHigh and rawAddr + 12 > mem.codeLow then
					mem:notifyCodeWrite(rawAddr, 12)
				end
			else
				mem:writef32(rawAddr, val.x)
				mem:writef32(rawAddr + 4, val.y)
				mem:writef32(rawAddr + 8, val.z)
				cost += mem.lastCost
			end
			pc = nextPc
		elseif op == 0x62 then -- VADD
			cost += 2
			local va: vector = vecs[b]
			local vb: vector = vecs[c]
			vecs[a] = va + vb
			pc = nextPc
		elseif op == 0x63 then -- VSUB
			cost += 2
			local va: vector = vecs[b]
			local vb: vector = vecs[c]
			vecs[a] = va - vb
			pc = nextPc
		elseif op == 0x64 then -- VMUL
			cost += 2
			local va: vector = vecs[b]
			local vb: vector = vecs[c]
			vecs[a] = va * vb
			pc = nextPc
		elseif op == 0x65 then -- VDOT / VDP3
			cost += 2
			local va: vector = vecs[b]
			local vb: vector = vecs[c]
			buffer.writef32(scratch, 0, va.x * vb.x + va.y * vb.y + va.z * vb.z)
			buffer.writeu32(regs, a, buffer.readu32(scratch, 0))
			pc = nextPc
		elseif op == 0x66 then -- VLEN
			cost += 2
			local va: vector = vecs[b]
			buffer.writef32(scratch, 0, math.sqrt(va.x * va.x + va.y * va.y + va.z * va.z))
			buffer.writeu32(regs, a, buffer.readu32(scratch, 0))
			pc = nextPc
		elseif op == 0x67 then -- VNRM
			cost += 2
			local va: vector = vecs[b]
			local mag = math.sqrt(va.x * va.x + va.y * va.y + va.z * va.z)
			if mag > 0 then
				vecs[a] = vector.create(va.x / mag, va.y / mag, va.z / mag)
			else
				vecs[a] = ZERO_VEC
			end
			pc = nextPc
		elseif op == 0x68 then -- VCST
			vecs[a] = if c == 1 then ONE_VEC else ZERO_VEC
			pc = nextPc
		elseif op == 0x69 then -- VFMA
			cost += 2
			local va: vector = vecs[b]
			local vb: vector = vecs[c]
			local vd: vector = vecs[a]
			vecs[a] = va * vb + vd
			pc = nextPc
		elseif op == 0x6A then -- VRED
			cost += 2
			local va: vector = vecs[b]
			buffer.writef32(scratch, 0, va.x + va.y + va.z)
			buffer.writeu32(regs, a, buffer.readu32(scratch, 0))
			pc = nextPc
		elseif op == 0x6B then -- VSCL
			cost += 2
			buffer.writeu32(scratch, 0, buffer.readu32(regs, c))
			local s = buffer.readf32(scratch, 0)
			local va: vector = vecs[b]
			vecs[a] = va * s
			pc = nextPc
		elseif op == 0x6C then -- VMIN
			cost += 2
			local va: vector = vecs[b]
			local vb: vector = vecs[c]
			vecs[a] = vector.min(va, vb)
			pc = nextPc
		elseif op == 0x6D then -- VMAX
			cost += 2
			local va: vector = vecs[b]
			local vb: vector = vecs[c]
			vecs[a] = vector.max(va, vb)
			pc = nextPc
		else
			local faultPc = buffer.readu32(uops, offset + 8)
			self.pc = faultPc
			self.cycles = cycles
			self.steps = steps
			self.halted = true
			self.exitCode = 255
			error(string.format('Z32 illegal opcode 0x%02X at 0x%08X', op, faultPc), 0)
		end

		used += cost
		cycles += cost
		steps += 1
		executedInBlock += 1

		if self.irqEnabled and steps % 256 == 0 then
			self.pc = pc
			self.cycles = cycles
			self.steps = steps
			self:pollInterrupts()
			if self.pc ~= pc then
				pc = self.pc
				break
			end
		end

		if used >= budget or self.halted or self.yielded or self.syncWaiting or mem.codeGen ~= blockCodeGen then
			break
		end

		if branched then
			-- Hot self-loop fast path: if the block branched back to its own entry
			-- PC and the code was not modified, restart this block in place without
			-- leaving native code or looking up the block cache.
			if pc == startPc then
				offset = 0
				self.stats.blockRuns += 1
			else
				break
			end
		else
			offset += UOP_SIZE
		end
	end

	self.pc = pc
	self.cycles = cycles
	self.steps = steps
	self.stats.blockRuns += 1
	self.stats.blockInstructions += executedInBlock
	return used
end

--=====================================================================
-- Scheduling
--=====================================================================

--- Run up to `budget` cycles. Stops early on HALT, YIELD or SYNC, so the core
--- can never run unbounded between yields and cannot trip the watchdog.
function Core.run(self: Class, budget: number): number
	local used = 0
	if self.tier == 0 then
		while used < budget do
			if self.halted or self.yielded or self.syncWaiting then
				break
			end
			used += self:step()
		end
		return used
	end

	local mem = self.mem
	local ram = mem.ram
	local ramSize = mem.ramSize
	local blocks = self.blocks

	while used < budget do
		if self.halted or self.yielded or self.syncWaiting then
			break
		end
		local pc = self.pc
		if pc >= 0 and pc + 6 <= ramSize then
			local block = blocks[pc]
			if block == nil or block.codeGen ~= mem.codeGen or buffer.readu32(ram, pc) ~= block.firstWord then
				block = self:compileBlock(pc)
			end
			if block.count > 0 then
				used += self:runBlock(block, budget - used)
			else
				used += self:step()
			end
		else
			used += self:step()
		end
	end

	return used
end

--- Clear the YIELD flag so a suspended core can be resumed.
function Core.resume(self: Class)
	self.yielded = false
end

--- Snapshot of the register file, for tests and debugging.
function Core.registers(self: Class): { number }
	local out: { number } = table.create(32)
	for i = 0, 31 do
		out[i + 1] = rget(self.regs, i)
	end
	return out
end

--- Decode one instruction to text without executing it.
function Core.disassemble(self: Class, address: number): string
	local mem = self.mem
	local op = mem:read8(address)
	local info = Opcodes.info[op]
	if info == nil then
		return string.format('db 0x%02X', op)
	end
	local name = info.name
	if info.form == 'F2' then
		if name == 'VDOT' or name == 'VLEN' or name == 'VRED' then
			return string.format('%s r%d, v%d, v%d', name, mem:read8(address + 1), mem:read8(address + 2), mem:read8(address + 3))
		elseif name == 'VSCL' then
			return string.format('%s v%d, v%d, r%d', name, mem:read8(address + 1), mem:read8(address + 2), mem:read8(address + 3))
		end
		return string.format('%s r%d, r%d, r%d', name, mem:read8(address + 1), mem:read8(address + 2), mem:read8(address + 3))
	elseif info.form == 'F3' then
		if name == 'VCST' then
			return string.format('%s v%d, %d', name, mem:read8(address + 1), mem:read8(address + 3))
		end
		return string.format('%s r%d, r%d, %d', name, mem:read8(address + 1), mem:read8(address + 2), sign8(mem:read8(address + 3)))
	elseif info.form == 'F4' then
		return string.format('%s r%d, 0x%X', name, mem:read8(address + 1), mem:read32(address + 2))
	elseif info.form == 'F5' then
		return string.format('%s r%d, r%d, %d', name, mem:read8(address + 1), mem:read8(address + 2), sign16(mem:read16(address + 3)))
	elseif info.form == 'F6' then
		return string.format('%s v%d, v%d, v%d', name, mem:read8(address + 1), mem:read8(address + 2), mem:read8(address + 3))
	elseif info.form == 'F7' then
		return string.format('%s v%d, r%d, %d', name, mem:read8(address + 1), mem:read8(address + 2), sign8(mem:read8(address + 3)))
	end
	return name
end

return Core
