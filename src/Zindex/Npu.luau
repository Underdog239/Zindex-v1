--!strict
--!native
--[[
	Npu - the Z-NPU vector/tensor co-processor and DMA unit
	(docs/05-soc.md, docs/07-npu.md).

	Like the GPU, the NPU is fed through a 48-byte command queue in RAM and
	kicked via an MMIO register at `Npu.PAGE` (0x0F007000). Every numeric kernel
	is lowered onto Luau's native 3-lane `vector` (3 x float32) primitive or
	bulk `buffer.copy` / `buffer.fill` operations, with zero allocations in the
	compute loop.

	Registers at Npu.PAGE (0x0F007000):
		+0x00  queue base address
		+0x04  queue length in commands
		+0x08  kick, write 1 to run the queue; reads 1 while pending
		+0x0C  status: 0 idle, 1 pending, 2 done, 3 rejected/limited
		+0x10  commands run (stat)
		+0x14  3-lane vector operations executed (stat)
		+0x18  output elements written (stat)

	Commands (48 bytes, 12 words):
		+0x00 op       +0x04 src      +0x08 dst      +0x0C count (or M)
		+0x10 matrix   +0x14 bias/aux +0x18 mode     +0x1C flags (bit 0 = ReLU)
		+0x20 dimN     +0x24 dimK     +0x28 tileRow0 +0x2C tileRows
]]

local Memory = require(script.Parent.Memory)

local Npu = {}
Npu.__index = Npu

Npu.PAGE = 0x0F007000
Npu.COMMAND_SIZE = 48
Npu.MAX_QUEUE_COMMANDS = 256
Npu.MAX_QUEUE_WORK = 262144

Npu.OP = {
	NOP = 0,
	DOT_BATCH = 1,
	FMA_BATCH = 2,
	GEMM = 3,
	NORM_BATCH = 4,
	DEQUANT_INT8 = 5,
	DMA_COPY = 6,
	DMA_FILL = 7,
}

local F_OP = 0x00
local F_SRC = 0x04
local F_DST = 0x08
local F_COUNT = 0x0C
local F_MATRIX = 0x10
local F_AUX = 0x14
local F_MODE = 0x18
local F_FLAGS = 0x1C
local F_N = 0x20
local F_K = 0x24
local F_TILE_START = 0x28
local F_TILE_ROWS = 0x2C

export type Stats = {
	vectorOps: number,
	elements: number,
	dmaBytes: number,
}

export type State = {
	memory: Memory.Class,
	ram: buffer,
	ramSize: number,
	queueBase: number,
	queueCount: number,
	pending: boolean,
	status: number,
	commandsRun: number,
	queueFaults: number,
	stats: Stats,
	scratch: buffer,
}

export type Class = typeof(setmetatable({} :: State, Npu))

function Npu.attach(memory: Memory.Class): Class
	local self = setmetatable({}, Npu) :: any
	self.memory = memory
	self.ram = memory:getRam()
	self.ramSize = memory.ramSize
	self.queueBase = 0
	self.queueCount = 0
	self.pending = false
	self.status = 0
	self.commandsRun = 0
	self.queueFaults = 0
	self.stats = {
		vectorOps = 0,
		elements = 0,
		dmaBytes = 0,
	}
	self.scratch = buffer.create(8)

	memory:registerDevice(Npu.PAGE, {
		read32 = function(offset: number): number
			return self:readRegister(offset)
		end,
		write32 = function(offset: number, value: number)
			self:writeRegister(offset, value)
		end,
	})
	return self
end

function Npu.bitsToF32(self: Class, bits: number): number
	buffer.writeu32(self.scratch, 0, bits)
	return buffer.readf32(self.scratch, 0)
end

function Npu.readRegister(self: Class, offset: number): number
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
		return self.stats.vectorOps
	elseif offset == 0x18 then
		return self.stats.elements
	elseif offset == 0x1C then
		return self.stats.dmaBytes
	end
	return 0
end

function Npu.writeRegister(self: Class, offset: number, value: number)
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
	end
end

--- Batch of `count` 3-lane dot products: `dst[i] = dot(srcA[i], srcB[i])`.
function Npu.dotBatch(self: Class, srcA: number, srcB: number, dst: number, count: number)
	local ram: buffer = self.ram
	for i = 0, count - 1 do
		local aOff = srcA + i * 12
		local bOff = srcB + i * 12
		local va = vector.create(
			buffer.readf32(ram, aOff),
			buffer.readf32(ram, aOff + 4),
			buffer.readf32(ram, aOff + 8)
		)
		local vb = vector.create(
			buffer.readf32(ram, bOff),
			buffer.readf32(ram, bOff + 4),
			buffer.readf32(ram, bOff + 8)
		)
		buffer.writef32(ram, dst + i * 4, vector.dot(va, vb))
	end
	self.stats.vectorOps += count
	self.stats.elements += count
end

--- Batch of `count` 3-lane fused multiply-adds:
---   mode 0 (vector * vector + vector): `dst[i] = srcA[i] * srcB[i] + srcC[i]`
---   mode 1 (vector * scalar + vector): `dst[i] = srcA[i] * scale   + srcC[i]`
--- When `aux == 0`, the addend is taken from `dst[i]` in place.
function Npu.fmaBatch(self: Class, srcA: number, matrixOrScale: number, aux: number, dst: number, count: number, mode: number, relu: boolean)
	local ram: buffer = self.ram
	local addBase = if aux ~= 0 then aux else dst
	local scale = if mode == 1 then self:bitsToF32(matrixOrScale) else 1.0
	local zero = vector.create(0, 0, 0)

	for i = 0, count - 1 do
		local off = i * 12
		local aOff = srcA + off
		local cOff = addBase + off
		local dOff = dst + off
		local va = vector.create(
			buffer.readf32(ram, aOff),
			buffer.readf32(ram, aOff + 4),
			buffer.readf32(ram, aOff + 8)
		)
		local vc = vector.create(
			buffer.readf32(ram, cOff),
			buffer.readf32(ram, cOff + 4),
			buffer.readf32(ram, cOff + 8)
		)
		local out: vector
		if mode == 1 then
			out = va * scale + vc
		else
			local bOff = matrixOrScale + off
			local vb = vector.create(
				buffer.readf32(ram, bOff),
				buffer.readf32(ram, bOff + 4),
				buffer.readf32(ram, bOff + 8)
			)
			out = va * vb + vc
		end
		if relu then
			out = vector.max(out, zero)
		end
		buffer.writef32(ram, dOff, out.x)
		buffer.writef32(ram, dOff + 4, out.y)
		buffer.writef32(ram, dOff + 8, out.z)
	end
	self.stats.vectorOps += count
	self.stats.elements += count * 3
end

--- Batch normalize `count` float3 vectors.
function Npu.normBatch(self: Class, src: number, dst: number, count: number)
	local ram: buffer = self.ram
	for i = 0, count - 1 do
		local sOff = src + i * 12
		local dOff = dst + i * 12
		local x = buffer.readf32(ram, sOff)
		local y = buffer.readf32(ram, sOff + 4)
		local z = buffer.readf32(ram, sOff + 8)
		local mag = math.sqrt(x * x + y * y + z * z)
		if mag > 0 then
			local inv = 1 / mag
			buffer.writef32(ram, dOff, x * inv)
			buffer.writef32(ram, dOff + 4, y * inv)
			buffer.writef32(ram, dOff + 8, z * inv)
		else
			buffer.writef32(ram, dOff, 0)
			buffer.writef32(ram, dOff + 4, 0)
			buffer.writef32(ram, dOff + 8, 0)
		end
	end
	self.stats.vectorOps += count
	self.stats.elements += count * 3
end

--- 3-lane tiled GEMM: `C[M x N] = A[M x K] * B[K x N] + bias[N]`, with optional ReLU.
--- Inner dot products step 3 elements at a time using `vector.dot`, costing
--- exactly `ceil(K / 3)` native vector operations per output element as stated
--- in docs/07-npu.md section 2.
function Npu.gemm(
	self: Class,
	aAddr: number,
	bAddr: number,
	cAddr: number,
	biasAddr: number,
	mRows: number,
	nCols: number,
	kInner: number,
	relu: boolean,
	tileStart: number,
	tileRows: number
)
	if mRows <= 0 or nCols <= 0 or kInner <= 0 then
		return
	end
	local ram: buffer = self.ram
	local rowStart = tileStart
	local rowEnd = if tileRows > 0 then math.min(mRows, rowStart + tileRows) else mRows
	local vecChunks = math.floor(kInner / 3)
	local rem = kInner - vecChunks * 3
	local vecOpsPerElem = vecChunks + (if rem > 0 then 1 else 0)
	local totalVecOps = 0
	local totalElems = 0

	for r = rowStart, rowEnd - 1 do
		local aRowBase = aAddr + r * kInner * 4
		local cRowBase = cAddr + r * nCols * 4
		for col = 0, nCols - 1 do
			local sum = if biasAddr ~= 0 then buffer.readf32(ram, biasAddr + col * 4) else 0.0
			local k = 0
			for _ = 1, vecChunks do
				local aOff = aRowBase + k * 4
				local bOff0 = bAddr + (k * nCols + col) * 4
				local bOff1 = bOff0 + nCols * 4
				local bOff2 = bOff1 + nCols * 4
				local va = vector.create(
					buffer.readf32(ram, aOff),
					buffer.readf32(ram, aOff + 4),
					buffer.readf32(ram, aOff + 8)
				)
				local vb = vector.create(
					buffer.readf32(ram, bOff0),
					buffer.readf32(ram, bOff1),
					buffer.readf32(ram, bOff2)
				)
				sum += vector.dot(va, vb)
				k += 3
			end
			if rem == 1 then
				local a0 = buffer.readf32(ram, aRowBase + k * 4)
				local b0 = buffer.readf32(ram, bAddr + (k * nCols + col) * 4)
				local va = vector.create(a0, 0, 0)
				local vb = vector.create(b0, 0, 0)
				sum += vector.dot(va, vb)
			elseif rem == 2 then
				local aOff = aRowBase + k * 4
				local bOff0 = bAddr + (k * nCols + col) * 4
				local va = vector.create(buffer.readf32(ram, aOff), buffer.readf32(ram, aOff + 4), 0)
				local vb = vector.create(buffer.readf32(ram, bOff0), buffer.readf32(ram, bOff0 + nCols * 4), 0)
				sum += vector.dot(va, vb)
			end
			if relu and sum < 0 then
				sum = 0
			end
			buffer.writef32(ram, cRowBase + col * 4, sum)
			totalVecOps += vecOpsPerElem
			totalElems += 1
		end
	end

	self.stats.vectorOps += totalVecOps
	self.stats.elements += totalElems
end

--- Emulated INT8 dequantisation (docs/07-npu.md section 4):
--- unpack signed int8 bytes into float32 values with `val = q * scale + bias`,
--- processed 3 lanes at a time through the vector unit.
function Npu.dequantInt8(self: Class, src: number, dst: number, count: number, scaleBits: number, biasBits: number)
	local ram: buffer = self.ram
	local scale = self:bitsToF32(scaleBits)
	local bias = self:bitsToF32(biasBits)
	local biasVec = vector.create(bias, bias, bias)
	local triples = math.floor(count / 3)
	local index = 0

	for _ = 1, triples do
		local q = vector.create(
			buffer.readi8(ram, src + index),
			buffer.readi8(ram, src + index + 1),
			buffer.readi8(ram, src + index + 2)
		)
		local out = q * scale + biasVec
		local dOff = dst + index * 4
		buffer.writef32(ram, dOff, out.x)
		buffer.writef32(ram, dOff + 4, out.y)
		buffer.writef32(ram, dOff + 8, out.z)
		index += 3
	end
	while index < count do
		local q = buffer.readi8(ram, src + index)
		buffer.writef32(ram, dst + index * 4, q * scale + bias)
		index += 1
	end

	self.stats.vectorOps += triples + (if index > triples * 3 then 1 else 0)
	self.stats.elements += count
end

local function productWithinLimit(a: number, b: number, limit: number): number?
	if a < 0 or b < 0 then
		return nil
	end
	if a == 0 or b == 0 then
		return 0
	end
	if a > math.floor(limit / b) then
		return nil
	end
	return a * b
end

local function arrayRangeFits(memory: Memory.Class, address: number, count: number, stride: number): boolean
	if count < 0 or count % 1 ~= 0 then
		return false
	end
	return memory:containsRange(address, count * stride)
end

--- Validate and execute one guest command, returning whether it was accepted and
--- how much of the queue's bounded work budget it consumed.
function Npu.execute(self: Class, command: number, workBudget: number?): (boolean, number)
	local memory = self.memory
	if not memory:containsRange(command, Npu.COMMAND_SIZE) then
		return false, 0
	end
	local op = memory:read32(command + F_OP)
	if op == Npu.OP.NOP then
		return true, 0
	end

	local src = memory:read32(command + F_SRC)
	local dst = memory:read32(command + F_DST)
	local count = memory:read32(command + F_COUNT)
	local matrix = memory:read32(command + F_MATRIX)
	local aux = memory:read32(command + F_AUX)
	local mode = memory:read32(command + F_MODE)
	local flags = memory:read32(command + F_FLAGS)
	local relu = bit32.band(flags, 1) ~= 0
	local remaining = if workBudget ~= nil then math.min(workBudget, Npu.MAX_QUEUE_WORK) else Npu.MAX_QUEUE_WORK
	local work = 0

	if op == Npu.OP.DOT_BATCH then
		if count > math.floor(remaining / 3)
			or not arrayRangeFits(memory, src, count, 12)
			or not arrayRangeFits(memory, matrix, count, 12)
			or not arrayRangeFits(memory, dst, count, 4)
		then
			return false, 0
		end
		work = count * 3
		self:dotBatch(src, matrix, dst, count)
	elseif op == Npu.OP.FMA_BATCH then
		local addBase = if aux ~= 0 then aux else dst
		if (mode ~= 0 and mode ~= 1)
			or count > math.floor(remaining / 3)
			or not arrayRangeFits(memory, src, count, 12)
			or not arrayRangeFits(memory, addBase, count, 12)
			or not arrayRangeFits(memory, dst, count, 12)
			or (mode == 0 and not arrayRangeFits(memory, matrix, count, 12))
		then
			return false, 0
		end
		work = count * 3
		self:fmaBatch(src, matrix, aux, dst, count, mode, relu)
	elseif op == Npu.OP.GEMM then
		local nCols = memory:read32(command + F_N)
		local kInner = memory:read32(command + F_K)
		local tileStart = memory:read32(command + F_TILE_START)
		local tileRows = memory:read32(command + F_TILE_ROWS)
		if count > 0 and nCols > 0 and kInner > 0 then
			-- The budget is charged for the rows this command actually visits, so a
			-- guest can split a large matrix into bounded tile jobs. Validating the
			-- operands is a separate concern and still covers the whole command.
			if tileStart % 1 ~= 0 or tileRows % 1 ~= 0 or tileStart < 0 or tileStart > count or tileRows < 0 then
				return false, 0
			end
			local rowEnd = if tileRows > 0 then math.min(count, tileStart + tileRows) else count
			local rows = rowEnd - tileStart
			local outputElements = productWithinLimit(rows, nCols, remaining)
			if outputElements == nil then
				return false, 0
			end
			local multiplyAdds = productWithinLimit(outputElements, kInner, remaining)
			if multiplyAdds == nil then
				return false, 0
			end
			work = multiplyAdds
			if not arrayRangeFits(memory, src, count * kInner, 4)
				or not arrayRangeFits(memory, matrix, kInner * nCols, 4)
				or not arrayRangeFits(memory, dst, count * nCols, 4)
				or (aux ~= 0 and not arrayRangeFits(memory, aux, nCols, 4))
			then
				return false, 0
			end
		end
		self:gemm(src, matrix, dst, aux, count, nCols, kInner, relu, tileStart, tileRows)
	elseif op == Npu.OP.NORM_BATCH then
		if count > math.floor(remaining / 3)
			or not arrayRangeFits(memory, src, count, 12)
			or not arrayRangeFits(memory, dst, count, 12)
		then
			return false, 0
		end
		work = count * 3
		self:normBatch(src, dst, count)
	elseif op == Npu.OP.DEQUANT_INT8 then
		if count > remaining
			or not arrayRangeFits(memory, src, count, 1)
			or not arrayRangeFits(memory, dst, count, 4)
		then
			return false, 0
		end
		work = count
		self:dequantInt8(src, dst, count, matrix, aux)
	elseif op == Npu.OP.DMA_COPY then
		if count > remaining
			or not memory:containsRange(src, count)
			or not memory:containsRange(dst, count)
		then
			return false, 0
		end
		work = count
		if count > 0 then
			buffer.copy(self.ram, dst, self.ram, src, count)
			if dst < memory.codeHigh and dst + count > memory.codeLow then
				memory:notifyCodeWrite(dst, count)
			end
			self.stats.dmaBytes += count
		end
	elseif op == Npu.OP.DMA_FILL then
		if count > remaining or not memory:containsRange(dst, count) then
			return false, 0
		end
		work = count
		if count > 0 then
			buffer.fill(self.ram, dst, src % 256, count)
			if dst < memory.codeHigh and dst + count > memory.codeLow then
				memory:notifyCodeWrite(dst, count)
			end
			self.stats.dmaBytes += count
		end
	else
		return false, 0
	end

	return true, work
end

--- Drain the queue, validating guest ranges and bounding total accelerator work.
function Npu.pump(self: Class): number
	if not self.pending then
		return 0
	end
	self.pending = false
	if self.queueCount < 0 or self.queueCount % 1 ~= 0 or self.queueCount > Npu.MAX_QUEUE_COMMANDS
		or (self.queueCount > 0 and not self.memory:containsRange(self.queueBase, self.queueCount * Npu.COMMAND_SIZE))
	then
		self.queueFaults += 1
		self.status = 3
		return 0
	end

	local executed = 0
	local remainingWork = Npu.MAX_QUEUE_WORK
	local failed = false
	for index = 0, self.queueCount - 1 do
		local accepted, work = self:execute(self.queueBase + index * Npu.COMMAND_SIZE, remainingWork)
		executed += 1
		if not accepted then
			self.queueFaults += 1
			failed = true
			break
		end
		remainingWork -= work
	end
	self.commandsRun += executed
	self.status = if failed then 3 else 2
	return executed
end

function Npu.resetStats(self: Class)
	self.commandsRun = 0
	self.stats.vectorOps = 0
	self.stats.elements = 0
	self.stats.dmaBytes = 0
end

return Npu
