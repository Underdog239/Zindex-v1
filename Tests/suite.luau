--[[
	Z32 test suite. Bundled with the library by Tests/bundle.py and run with the
	Luau CLI. Every test drives the real core: assemble, load, run, inspect.
]]

local Zindex = __mods.Zindex
local Assembler = __mods.Assembler
local Image = __mods.Image

local passed = 0
local failed = 0
local failures = {}

local function check(name, condition, detail)
	if condition then
		passed += 1
	else
		failed += 1
		failures[#failures + 1] = name .. (detail and ('  (' .. tostring(detail) .. ')') or '')
	end
end

local function eq(name, actual, expected)
	check(name, actual == expected, 'got ' .. tostring(actual) .. ' want ' .. tostring(expected))
end

local function newChip(ramSize)
	return Zindex.new({ ramSize = ramSize or 0x10000 })
end

--- Assemble, run to completion (or the budget), return the chip.
local function run(source, budget)
	local chip = newChip()
	chip:assemble(source)
	chip:run(budget or 100000)
	return chip
end

local scratch = buffer.create(8)
local function f32bits(value)
	buffer.writef32(scratch, 0, value)
	return buffer.readu32(scratch, 0)
end

--=====================================================================
-- Arithmetic
--=====================================================================

do
	local chip = run[[
		li r1, 0xFFFFFFFF
		li r2, 3
		mul r3, r1, r2
		li r4, 0xFFFFFFFF
		addi r5, r4, 2
		li r6, 17
		li r7, 5
		div r8, r6, r7
		rem r9, r6, r7
		div r10, r6, r0
		sub r11, r0, r2
		halt
	]]
	eq('mul wraps exactly', chip:reg(3), 4294967293)
	eq('add wraps', chip:reg(5), 1)
	eq('div is floor', chip:reg(8), 3)
	eq('rem', chip:reg(9), 2)
	eq('divide by zero yields zero', chip:reg(10), 0)
	eq('subtract underflows to wrap', chip:reg(11), 4294967293)
end

do
	local chip = run[[
		li r1, 1
		shli r2, r1, 31
		shli r3, r1, 32
		li r4, 0x80000000
		li r5, 31
		sar r6, r4, r5
		shri r7, r4, 4
		not r9, r0
		halt
	]]
	eq('shift left 31', chip:reg(2), 2147483648)
	eq('shift of 32 or more yields zero', chip:reg(3), 0)
	eq('arithmetic shift right sign fills', chip:reg(6), 4294967295)
	eq('logical shift right', chip:reg(7), 134217728)
	eq('not zero is all ones', chip:reg(9), 4294967295)
end

do
	local chip = run[[
		li r1, 0xFFFFFFFF
		li r2, 1
		slt r3, r1, r2
		sltu r4, r1, r2
		seq r5, r1, r1
		sne r6, r1, r2
		halt
	]]
	eq('signed -1 is less than 1', chip:reg(3), 1)
	eq('unsigned 0xFFFFFFFF is not less than 1', chip:reg(4), 0)
	eq('equal', chip:reg(5), 1)
	eq('not equal', chip:reg(6), 1)
end

--=====================================================================
-- Memory
--=====================================================================

do
	local chip = run[[
		li r1, 0x8000
		li r2, 0xDEADBEEF
		sw r2, 0(r1)
		lw r3, 0(r1)
		li r4, 0xFF
		sb r4, 4(r1)
		lb r5, 4(r1)
		lbu r6, 4(r1)
		li r7, 0x1234
		sh r7, 6(r1)
		lhu r8, 6(r1)
		li r9, 0x8000
		sh r9, 8(r1)
		lh r10, 8(r1)
		halt
	]]
	eq('word store and load', chip:reg(3), 3735928559)
	eq('load byte sign extends', chip:reg(5), 4294967295)
	eq('load byte unsigned', chip:reg(6), 255)
	eq('half store and load', chip:reg(8), 4660)
	eq('load half sign extends', chip:reg(10), 4294934528)
end

--=====================================================================
-- Control flow
--=====================================================================

do
	local chip = run[[
		li r1, 0
		li r2, 1
		li r3, 10
	loop:
		add r1, r1, r2
		addi r2, r2, 1
		bgeu r3, r2, loop
		halt
	]]
	eq('loop sums 1 to 10', chip:reg(1), 55)
end

do
	local chip = run[[
		li r1, 5
		jal ra, double
		halt
	double:
		add r1, r1, r1
		jalr r0, ra, 0
	]]
	eq('call and return', chip:reg(1), 10)
end

do
	-- A loop that never ends, to test the cycle budget and determinism.
	local chip = newChip()
	chip:assemble[[
		li r1, 0x9000
		li r2, 0
	spin:
		addi r2, r2, 1
		sw r2, 0(r1)
		jmp spin
	]]
	local used = chip:run(200)
	-- run() may overshoot by the cost of the final instruction, by design
	check('budget is respected', used <= 210, used)
	check('budget is used', used > 100, used)

	local first = chip:snapshot()
	chip:run(200)
	local second = chip:snapshot()
	local advanced = buffer.readu32(chip:ram(), 0x9000)
	check('state advances', advanced > 0, advanced)

	chip:restore(first)
	chip:run(200)
	eq('replay from a save state is exact', buffer.readu32(chip:ram(), 0x9000), advanced)
	eq('replay leaves the same cycle count', chip:cycles(), second.cycles)
end

--=====================================================================
-- Vector / float unit
--=====================================================================

do
	local chip = run[[
			.org 0x8000
		vectorA:
			.f32 1.0, 2.0, 3.0
		vectorB:
			.f32 4.0, 5.0, 6.0
			.org 0x1000
			li r1, vectorA
			li r2, vectorB
			vlw v0, 0(r1)
			vlw v1, 0(r2)
			vadd v2, v0, v1
			vdot r3, v0, v1
			vlen r4, v0
			vsw v2, 12(r1)
			halt
	]]
	eq('vector add, lane 0', buffer.readf32(chip:ram(), 0x800C), 5.0)
	eq('vector add, lane 1', buffer.readf32(chip:ram(), 0x8010), 7.0)
	eq('vector add, lane 2', buffer.readf32(chip:ram(), 0x8014), 9.0)
	eq('dot product', chip:reg(3), f32bits(32.0))
	eq('magnitude', chip:reg(4), f32bits(math.sqrt(14)))
end

do
	local chip = run[[
			.org 0x8000
			.f32 3.0, 4.0, 0.0
			.org 0x1000
			li r1, 0x8000
			vlw v0, 0(r1)
			vnrm v1, v0
			vsw v1, 12(r1)
			halt
	]]
	local x = buffer.readf32(chip:ram(), 0x800C)
	local y = buffer.readf32(chip:ram(), 0x8010)
	check('normalize x', math.abs(x - 0.6) < 1e-5, x)
	check('normalize y', math.abs(y - 0.8) < 1e-5, y)
end

--=====================================================================
-- Devices
--=====================================================================

do
	local chip = Zindex.new({ ramSize = 0x10000, width = 320, height = 240, back = 0x4000 })
	chip:assemble[[
		li r1, 0x0F005000
		lw r2, 0(r1)
		lw r3, 4(r1)
		lw r4, 0x0C(r1)
		lw r5, 0x24(r1)
		li r6, 1
		sw r6, 0x24(r1)
		lw r7, 0x24(r1)
		li r8, 0x0F001000
		lw r9, 0(r8)
		halt
	]]
	chip:run(1000)
	eq('framebuffer width is readable', chip:reg(2), 320)
	eq('framebuffer height is readable', chip:reg(3), 240)
	eq('framebuffer back buffer is readable', chip:reg(4), 0x4000)
	eq('present flag starts clear', chip:reg(5), 0)
	eq('present flag reads back set', chip:reg(7), 1)
	check('present request reached the host', chip.devices.framebuffer.presentRequested == true)
	check('timer counts cycles', chip:reg(9) > 0, chip:reg(9))
end

do
	local chip = newChip()
	chip:setInput(3, 10, 20)
	chip:assemble[[
		li r1, 0x0F002000
		lw r2, 0(r1)
		lw r3, 4(r1)
		lw r4, 8(r1)
		halt
	]]
	chip:run(1000)
	eq('input buttons', chip:reg(2), 3)
	eq('input pointer x', chip:reg(3), 10)
	eq('input pointer y', chip:reg(4), 20)
end

--=====================================================================
-- Host calls
--=====================================================================

do
	local chip = newChip()
	chip:assemble[[
			li r1, 1
			li r2, message
			ecall
			li r1, 0
			li r2, 42
			ecall
			halt
			.org 0x8000
		message:
			.ascii "z32 syscall output"
			.byte 0
	]]
	chip:run(1000)
	check('exit syscall halts the core', chip:halted())
	eq('exit syscall sets the code', chip:exitCode(), 42)
end

--=====================================================================
-- Assembler
--=====================================================================

do
	local result = Assembler.assemble[[
			.entry start
			.org 0x2000
		start:
			li r1, table
			lw r2, 4(r1)
			halt
			.org 0x9000
		table:
			.word 0x11111111, 0x22222222
			.byte 0xAA, 0xBB
			.half 0xCCDD
			.zero 4
			.ascii "hi"
	]]
	eq('entry from .entry', result.entry, 0x2000)
	eq('label address', result.symbols.table, 0x9000)
	eq('word data', buffer.readu32(result.code, 0x9000 - result.origin), 0x11111111)
	eq('second word data', buffer.readu32(result.code, 0x9004 - result.origin), 0x22222222)
	eq('byte data', buffer.readu8(result.code, 0x9008 - result.origin), 0xAA)
	eq('half data', buffer.readu16(result.code, 0x900A - result.origin), 0xCCDD)
	eq('ascii data', buffer.readu8(result.code, 0x9010 - result.origin), 104)
	check('listing is produced', #result.listing >= 3, #result.listing)
	check('listing names instructions', result.listing[1]:find('li r1, table') ~= nil, result.listing[1])
end

do
	local result = Assembler.assemble[[
			.org 0x1000
			li r1, target + 8
			halt
			.org 0x2000
		target:
			.word 1
	]]
	local chip = newChip()
	chip:loadProgram(result)
	chip:run(100)
	eq('expression with a label', chip:reg(1), 0x2008)
end

--=====================================================================
-- Program images
--=====================================================================

do
	local result = Assembler.assemble[[
		li r1, 7
		halt
	]]
	local blob = Image.pack({
		entry = result.entry,
		code = result.code,
		codeAddress = result.origin,
		ramSize = 0x10000,
		profile = 2,
	})
	check('image has magic', Image.isImage(blob))
	local program = Image.unpack(blob)
	eq('image entry', program.entry, result.entry)
	eq('image ram size', program.ramSize, 0x10000)
	eq('image profile', program.profile, 2)
	eq('image code address', program.codeAddress, result.origin)
	eq('image code size', buffer.len(program.code), buffer.len(result.code))

	local chip = newChip()
	chip:loadImage(blob)
	chip:run(100)
	eq('image runs', chip:reg(1), 7)
end

--=====================================================================
-- Faults
--=====================================================================

do
	local chip = newChip()
	local result = chip:assemble[[
		li r1, 1
		halt
	]]
	buffer.writeu8(chip:ram(), result.origin, 0xFE)
	local ok = pcall(function()
		chip:run(10)
	end)
	check('illegal opcode is an error', ok == false)
end

--=====================================================================
-- Summary
--=====================================================================

print(string.format('z32 suite: %d passed, %d failed', passed, failed))
for _, name in failures do
	print('  FAIL ' .. name)
end
if failed == 0 then
	print('ALL TESTS PASS')
else
	error('suite failed', 0)
end
