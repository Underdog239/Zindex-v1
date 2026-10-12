--!strict
--!native
--[[
	Core - a Z32 CPU core: registers, decode, execute.

	Tier 0 reference implementation of the ISA in docs/01-isa.md.

	Design rules it obeys, because the architecture requires them:
	  * machine state lives in buffers, never tables (4 bytes per register,
	    one byte per RAM byte, nothing for the garbage collector to scan)
	  * decode reads whole bytes, so no bit32 call is ever needed to unpack
	    an instruction
	  * no engine API is touched, so the whole core stays native-compilable
	  * nothing is allocated inside the step loop
]]

local Opcodes = require(script.Parent.Opcodes)
local Memory = require(script.Parent.Memory)

local Core = {}
Core.__index = Core

local WRAP = 4294967296
local HALF = 2147483648

export type Class = typeof(setmetatable(
	{} :: {
		mem: Memory.Class,
		regs: buffer,
		vecs: { vector },
		scratch: buffer,
		pc: number,
		cycles: number,
		halted: boolean,
		exitCode: number,
		yielded: boolean,
		traps: number,
		steps: number,
		onTrap: ((core: any, reason: number) -> (number?, number?))?,
		onInterrupt: ((core: any, mask: number) -> ())?,
		irqEnabled: boolean,
	},
	Core
))

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
	return buffer.readu32(regs, index * 4)
end

--- Writes are discarded for R0, the hardwired zero register.
local function rset(regs: buffer, index: number, value: number)
	if index ~= 0 then
		buffer.writeu32(regs, index * 4, value % WRAP)
	end
end

--=====================================================================
-- Construction and state access
--=====================================================================

function Core.new(mem: Memory.Class, entry: number): Class
	local self = setmetatable({}, Core) :: any
	self.mem = mem
	self.regs = buffer.create(128)
	self.vecs = table.create(8) :: { vector }
	for i = 1, 8 do
		self.vecs[i] = vector.create(0, 0, 0)
	end
	self.scratch = buffer.create(8)
	self.pc = entry
	self.cycles = 0
	self.halted = false
	self.exitCode = 0
	self.yielded = false
	self.traps = 0
	self.steps = 0
	self.irqEnabled = false
	return self
end

function Core:reset(entry: number)
	buffer.fill(self.regs, 0, 0, 128)
	for i = 1, 8 do
		self.vecs[i] = vector.create(0, 0, 0)
	end
	self.pc = entry
	self.cycles = 0
	self.halted = false
	self.exitCode = 0
	self.yielded = false
	self.steps = 0
end

function Core:reg(index: number): number
	return rget(self.regs, index)
end

function Core:setReg(index: number, value: number)
	rset(self.regs, index, value)
end

function Core:vec(index: number): vector
	return self.vecs[index + 1]
end

--- Reinterpret a float as its 32-bit pattern. Costs a buffer round trip,
--- which is the honest price of moving floats through 32-bit registers.
function Core:f32Bits(value: number): number
	buffer.writef32(self.scratch, 0, value)
	return buffer.readu32(self.scratch, 0)
end

function Core:bitsF32(bits: number): number
	buffer.writeu32(self.scratch, 0, bits % WRAP)
	return buffer.readf32(self.scratch, 0)
end

--=====================================================================
-- Execute one instruction
--=====================================================================

--- Decode and execute one instruction. Returns the cycles it cost.
function Core:step(): number
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
	-- Loads and stores (form F3, displacement is signed)
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

	--=================================================================
	-- Vector / float unit
	--=================================================================
	elseif op == 0x60 then -- VLW
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		cost += mem.lastCost
		self.vecs[mem:read8(pc + 1) + 1] = vector.create(
			mem:readf32(address),
			mem:readf32(address + 4),
			mem:readf32(address + 8)
		)
		pc += 4
	elseif op == 0x61 then -- VSW
		local address = rget(regs, mem:read8(pc + 2)) + sign8(mem:read8(pc + 3))
		local value = self.vecs[mem:read8(pc + 1) + 1]
		cost += mem.lastCost
		mem:writef32(address, value.x)
		mem:writef32(address + 4, value.y)
		mem:writef32(address + 8, value.z)
		pc += 4
	elseif op == 0x62 then -- VADD
		cost += 2
		self.vecs[mem:read8(pc + 1) + 1] = self.vecs[mem:read8(pc + 2) + 1] + self.vecs[mem:read8(pc + 3) + 1]
		pc += 4
	elseif op == 0x63 then -- VSUB
		cost += 2
		self.vecs[mem:read8(pc + 1) + 1] = self.vecs[mem:read8(pc + 2) + 1] - self.vecs[mem:read8(pc + 3) + 1]
		pc += 4
	elseif op == 0x64 then -- VMUL
		cost += 2
		self.vecs[mem:read8(pc + 1) + 1] = self.vecs[mem:read8(pc + 2) + 1] * self.vecs[mem:read8(pc + 3) + 1]
		pc += 4
	elseif op == 0x65 then -- VDOT, result as float bits
		cost += 2
		local a = self.vecs[mem:read8(pc + 2) + 1]
		local b = self.vecs[mem:read8(pc + 3) + 1]
		rset(regs, mem:read8(pc + 1), self:f32Bits(a.x * b.x + a.y * b.y + a.z * b.z))
		pc += 4
	elseif op == 0x66 then -- VLEN, result as float bits
		cost += 2
		local a = self.vecs[mem:read8(pc + 2) + 1]
		rset(regs, mem:read8(pc + 1), self:f32Bits(math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)))
		pc += 4
	elseif op == 0x67 then -- VNRM
		cost += 2
		local a = self.vecs[mem:read8(pc + 2) + 1]
		local magnitude = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
		if magnitude > 0 then
			self.vecs[mem:read8(pc + 1) + 1] = vector.create(a.x / magnitude, a.y / magnitude, a.z / magnitude)
		else
			self.vecs[mem:read8(pc + 1) + 1] = vector.create(0, 0, 0)
		end
		pc += 4
	elseif op == 0x68 then -- VCST
		if mem:read8(pc + 3) == 1 then
			self.vecs[mem:read8(pc + 1) + 1] = vector.create(1, 1, 1)
		else
			self.vecs[mem:read8(pc + 1) + 1] = vector.create(0, 0, 0)
		end
		pc += 4

	else
		-- Illegal instruction: stop the core with a distinctive exit code
		-- rather than silently executing whatever follows.
		self.halted = true
		self.exitCode = 255
		error(string.format('Z32 illegal opcode 0x%02X at 0x%08X', op, pc), 0)
	end

	self.pc = pc
	self.cycles += cost
	self.steps += 1

	if self.irqEnabled and self.steps % 256 == 0 then
		local pending = mem:read32(Memory.DEVICE_BASE)
		if pending ~= 0 and self.onInterrupt ~= nil then
			self.onInterrupt(self, pending)
		end
	end

	return cost
end

--=====================================================================
-- Scheduling
--=====================================================================

--- Run up to `budget` cycles. Stops early on HALT or YIELD, so the core can
--- never run unbounded between yields and cannot trip the watchdog.
function Core:run(budget: number): number
	local used = 0
	while used < budget do
		if self.halted or self.yielded then
			break
		end
		used += self:step()
	end
	return used
end

--- Clear the YIELD flag so a suspended core can be resumed.
function Core:resume()
	self.yielded = false
end

--- Snapshot of the register file, for tests and debugging.
function Core:registers(): { number }
	local out = table.create(32)
	for i = 0, 31 do
		out[i + 1] = rget(self.regs, i)
	end
	return out
end

--- Decode one instruction to text without executing it.
function Core:disassemble(address: number): string
	local mem = self.mem
	local op = mem:read8(address)
	local info = Opcodes.info[op]
	if info == nil then
		return string.format('db 0x%02X', op)
	end
	local name = info.name
	if info.form == 'F2' then
		return string.format('%s r%d, r%d, r%d', name, mem:read8(address + 1), mem:read8(address + 2), mem:read8(address + 3))
	elseif info.form == 'F3' then
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
