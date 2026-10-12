--!nonstrict
--[[
	Assembler - Z32 assembly text to a program image.

	Two passes: the first walks the source to place labels and work out how much
	space everything needs, the second emits bytes with every symbol resolved.

	Syntax
		label:                      define a label
		addi r1, r0, 5              register-immediate ALU
		add r1, r2, r3              register-register ALU
		lw r1, 8(r2)                load, base plus displacement
		sw r1, 8(r2)                store
		lw r1, r2, 8                same, alternate operand order
		beq r1, r2, loop            branch, offset relative to the branch
		jal ra, function            call
		li r1, 0x2000               load a 32-bit immediate
		vadd v0, v1, v2             vector unit
		vlw v0, 0(r1)               load three floats
		.entry start                set the entry point
		.org 0x2000                 move the assembly pointer
		.word 1, 2, 3               data
		.byte 0xFF, 0x00
		.half 1000
		.f32 1.5, 2.25
		.ascii "hello"
		.zero 64

	Expressions may use labels and $ (the current address), for example
	li r1, buffer + 16 or beq r1, r2, skip + 4.
]]

local Opcodes = require(script.Parent.Opcodes)

local Assembler = {}

local DEFAULT_ORIGIN = 0x1000

local REGISTER_ALIASES: { [string]: number } = {
	zero = 0,
	sp = 30,
	fp = 29,
	ra = 31,
}

local LOADS: { [string]: boolean } = { LB = true, LBU = true, LH = true, LHU = true, LW = true }
local STORES: { [string]: boolean } = { SB = true, SH = true, SW = true }
local VEC_FULL: { [string]: boolean } = { VADD = true, VSUB = true, VMUL = true }

export type Result = {
	code: buffer,
	origin: number,
	entry: number,
	symbols: { [string]: number },
	listing: { string },
	size: number,
}

local function fail(message: string): never
	error('assembler: ' .. message, 0)
end

local function parseRegister(token: string): number
	if token == nil then
		fail('missing register operand')
	end
	local text = token:lower()
	local alias = REGISTER_ALIASES[text]
	if alias ~= nil then
		return alias
	end
	local index = text:match('^r(%d+)$')
	if index == nil then
		fail('not a register: ' .. token)
	end
	local value = tonumber(index) or 0
	if value > 31 then
		fail('register out of range: ' .. token)
	end
	return value
end

local function parseVector(token: string): number
	if token == nil then
		fail('missing vector register operand')
	end
	local index = token:lower():match('^v(%d+)$')
	if index == nil then
		fail('not a vector register: ' .. token)
	end
	local value = tonumber(index) or 0
	if value > 7 then
		fail('vector register out of range: ' .. token)
	end
	return value
end

local function trim(text: string): string
	return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function splitOperands(text: string): { string }
	local out = {}
	for piece in text:gmatch('[^,]+') do
		out[#out + 1] = trim(piece)
	end
	return out
end

--- Parse "8(r2)" into a displacement and a base register token.
local function parseMemory(text: string): (string, string)
	local offset, base = text:match('^([^%(]*)%(([^%)]+)%)$')
	if base ~= nil then
		return offset, base
	end
	return nil, text
end

--- Evaluate a constant expression, which may reference labels and $.
local function evaluate(expression: string, symbols: { [string]: number }, here: number): number
	local text = expression:gsub('%s+', '')
	if text == '' then
		return 0
	end
	text = text:gsub('%$', tostring(here))
	local total = 0
	local sign = 1
	local position = 1
	while position <= #text do
		local char = text:sub(position, position)
		if char == '+' then
			sign = 1
			position += 1
		elseif char == '-' then
			sign = -1
			position += 1
		end
		local start = position
		while position <= #text do
			local current = text:sub(position, position)
			if current == '+' or current == '-' then
				break
			end
			position += 1
		end
		local term = text:sub(start, position - 1)
		if term ~= '' then
			local number = tonumber(term)
			if number == nil then
				number = symbols[term]
			end
			if number == nil then
				fail('unknown symbol: ' .. term)
			end
			total += sign * number
		end
	end
	return total
end

--=====================================================================
-- Pass 1: lay out the program
--=====================================================================

local function plan(source: string, origin: number)
	local records = {}
	local symbols: { [string]: number } = {}
	local address = origin
	local entryName: string? = nil

	for rawLine in source:gmatch('[^\n]+') do
		local line = rawLine:gsub('%-%-.*$', ''):gsub(';.*$', '')
		local rest = line

		-- Labels, possibly several on one line.
		while true do
			local label = rest:match('^%s*([%a_][%w_]*):')
			if label == nil then
				break
			end
			if symbols[label] ~= nil then
				fail('duplicate label: ' .. label)
			end
			symbols[label] = address
			records[#records + 1] = { kind = 'label', name = label, address = address }
			rest = rest:sub((rest:find(':', 1, true) or 0) + 1)
		end

		local text = trim(rest)
		if text == '' then
			continue
		end

		if text:sub(1, 1) == '.' then
			local directive, argument = text:match('^(%S+)%s*(.*)$')
			directive = directive:lower()
			if directive == '.org' then
				local value = tonumber(argument)
				if value == nil then
					fail('.org needs a number')
				end
				address = value
			elseif directive == '.entry' then
				entryName = trim(argument)
			elseif directive == '.word' or directive == '.half' or directive == '.byte' then
				local width = 1
				if directive == '.word' then
					width = 4
				elseif directive == '.half' then
					width = 2
				end
				local values = splitOperands(argument)
				records[#records + 1] = { kind = 'data', width = width, values = values, address = address }
				address += width * #values
			elseif directive == '.f32' then
				local values = splitOperands(argument)
				records[#records + 1] = { kind = 'f32', values = values, address = address }
				address += 4 * #values
			elseif directive == '.ascii' then
				local literal = argument:match('^"(.*)"$')
				if literal == nil then
					fail('.ascii needs a quoted string')
				end
				records[#records + 1] = { kind = 'ascii', value = literal, address = address }
				address += #literal
			elseif directive == '.zero' or directive == '.space' then
				local count = tonumber(argument)
				if count == nil then
					fail(directive .. ' needs a count')
				end
				records[#records + 1] = { kind = 'zero', count = count, address = address }
				address += count
			else
				fail('unknown directive: ' .. directive)
			end
		else
			local mnemonic, operandText = text:match('^(%S+)%s*(.*)$')
			local name = mnemonic:upper()
			local info = Opcodes.byName[name]
			if info == nil then
				fail('unknown mnemonic: ' .. mnemonic)
			end
			records[#records + 1] = {
				kind = 'instr',
				name = name,
				form = info.form,
				op = info.op,
				operands = splitOperands(operandText),
				address = address,
				text = text,
			}
			address += Opcodes.sizes[info.form]
		end
	end

	return records, symbols, entryName, address
end

--=====================================================================
-- Pass 2: emit bytes
--=====================================================================

local function encode(record, symbols, emit8, emitN)
	local name = record.name
	local op = record.op
	local operands = record.operands
	local address = record.address
	local form = record.form

	if form == 'F1' then
		emit8(address, op)
		return
	end

	if form == 'F2' then
		if name == 'VDOT' then
			emit8(address, op)
			emit8(address + 1, parseRegister(operands[1]))
			emit8(address + 2, parseVector(operands[2]))
			emit8(address + 3, parseVector(operands[3]))
			return
		elseif name == 'VLEN' then
			emit8(address, op)
			emit8(address + 1, parseRegister(operands[1]))
			emit8(address + 2, parseVector(operands[2]))
			emit8(address + 3, 0)
			return
		end
		local rt = 0
		if operands[3] ~= nil then
			rt = parseRegister(operands[3])
		end
		emit8(address, op)
		emit8(address + 1, parseRegister(operands[1]))
		emit8(address + 2, parseRegister(operands[2]))
		emit8(address + 3, rt)
		return
	end

	if form == 'F3' then
		if LOADS[name] then
			local displacement, base = parseMemory(operands[2])
			if displacement == nil then
				displacement = operands[3]
				base = operands[2]
			end
			emit8(address, op)
			emit8(address + 1, parseRegister(operands[1]))
			emit8(address + 2, parseRegister(base))
			emit8(address + 3, evaluate(displacement, symbols, address) % 256)
			return
		elseif STORES[name] then
			local displacement, base = parseMemory(operands[2])
			if displacement == nil then
				displacement = operands[3]
				base = operands[2]
			end
			emit8(address, op)
			emit8(address + 1, parseRegister(operands[1]))
			emit8(address + 2, parseRegister(base))
			emit8(address + 3, evaluate(displacement, symbols, address) % 256)
			return
		elseif name == 'VCST' then
			emit8(address, op)
			emit8(address + 1, parseVector(operands[1]))
			emit8(address + 2, 0)
			emit8(address + 3, evaluate(operands[2], symbols, address) % 256)
			return
		end
		emit8(address, op)
		emit8(address + 1, parseRegister(operands[1]))
		emit8(address + 2, parseRegister(operands[2]))
		emit8(address + 3, evaluate(operands[3], symbols, address) % 256)
		return
	end

	if form == 'F4' then
		emit8(address, op)
		if name == 'JMP' then
			emit8(address + 1, 0)
			emitN(address + 2, evaluate(operands[1], symbols, address) % 4294967296, 4)
		else
			emit8(address + 1, parseRegister(operands[1]))
			emitN(address + 2, evaluate(operands[2], symbols, address) % 4294967296, 4)
		end
		return
	end

	if form == 'F5' then
		local target = evaluate(operands[3], symbols, address)
		emit8(address, op)
		emit8(address + 1, parseRegister(operands[1]))
		emit8(address + 2, parseRegister(operands[2]))
		emitN(address + 3, (target - address) % 65536, 2)
		return
	end

	if form == 'F6' then
		emit8(address, op)
		emit8(address + 1, parseVector(operands[1]))
		emit8(address + 2, parseVector(operands[2]))
		if VEC_FULL[name] then
			emit8(address + 3, parseVector(operands[3]))
		else
			emit8(address + 3, 0)
		end
		return
	end

	if form == 'F7' then
		local displacement, base = parseMemory(operands[2])
		if displacement == nil then
			displacement = operands[3]
			base = operands[2]
		end
		emit8(address, op)
		emit8(address + 1, parseVector(operands[1]))
		emit8(address + 2, parseRegister(base))
		emit8(address + 3, evaluate(displacement, symbols, address) % 256)
		return
	end

	fail('unhandled encoding form: ' .. tostring(form))
end

--=====================================================================
-- Public entry point
--=====================================================================

--- Assemble source text into a program image.
function Assembler.assemble(source: string, options: { origin: number? }?): Result
	local origin = DEFAULT_ORIGIN
	if options ~= nil and options.origin ~= nil then
		origin = options.origin
	end

	local records, symbols, entryName = plan(source, origin)

	local image: { [number]: number } = {}
	local highest = origin
	local lowest: number? = nil
	local listing = {}

	local function emit8(address: number, value: number)
		image[address] = value % 256
		if lowest == nil or address < lowest then
			lowest = address
		end
		if address + 1 > highest then
			highest = address + 1
		end
	end

	local function emitN(address: number, value: number, width: number)
		for i = 0, width - 1 do
			emit8(address + i, math.floor(value / (2 ^ (8 * i))) % 256)
		end
	end

	for _, record in records do
		if record.kind == 'data' then
			for index, expression in record.values do
				emitN(record.address + (index - 1) * record.width, evaluate(expression, symbols, record.address), record.width)
			end
		elseif record.kind == 'f32' then
			local scratch = buffer.create(4)
			for index, expression in record.values do
				buffer.writef32(scratch, 0, evaluate(expression, symbols, record.address))
				for i = 0, 3 do
					emit8(record.address + (index - 1) * 4 + i, buffer.readu8(scratch, i))
				end
			end
		elseif record.kind == 'ascii' then
			for i = 1, #record.value do
				emit8(record.address + i - 1, string.byte(record.value, i))
			end
		elseif record.kind == 'zero' then
			for i = 0, record.count - 1 do
				emit8(record.address + i, 0)
			end
		elseif record.kind == 'instr' then
			encode(record, symbols, emit8, emitN)
			listing[#listing + 1] = string.format('%08X  %s', record.address, record.text)
		end
	end

	-- The image spans exactly the addresses the source used, so a program that
	-- starts with .org produces a tight buffer rather than a padded one.
	if lowest ~= nil then
		origin = lowest
	end

	local size = highest - origin
	if size < 1 then
		size = 1
	end
	local code = buffer.create(size)
	for address, value in image do
		if address >= origin and address < highest then
			buffer.writeu8(code, address - origin, value)
		end
	end

	local entry = origin
	if entryName ~= nil then
		local value = symbols[entryName]
		if value == nil then
			value = tonumber(entryName)
		end
		if value == nil then
			fail('unknown entry point: ' .. entryName)
		end
		entry = value
	end

	return {
		code = code,
		origin = origin,
		entry = entry,
		symbols = symbols,
		listing = listing,
		size = size,
	}
end

return Assembler
