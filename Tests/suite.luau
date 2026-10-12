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
-- Raster unit
--=====================================================================

--- Write a float array into RAM.
local function putFloats(ram, address, values)
	for index, value in values do
		buffer.writef32(ram, address + (index - 1) * 4, value)
	end
end

--- identity matrix, then a mesh of one clip-space triangle
local function scene(chip)
	local ram = chip:ram()
	putFloats(ram, 0x6000, {
		1.0, 0.0, 0.0, 0.0,
		0.0, 1.0, 0.0, 0.0,
		0.0, 0.0, 1.0, 0.0,
		0.0, 0.0, 0.0, 1.0,
	})
	putFloats(ram, 0x6100, { -1.0, -1.0, 0.0, 1.0, -1.0, 0.0, -1.0, 1.0, 0.0 })
	buffer.writeu32(ram, 0x6200, 3)
	buffer.writeu32(ram, 0x6204, 0x6100)
	buffer.writeu32(ram, 0x6208, 0)
	buffer.writeu32(ram, 0x620C, 0)
	buffer.writeu32(ram, 0x6210, 0)
	buffer.writeu32(ram, 0x6214, 3)
	return ram
end

do
	local chip = Zindex.new({ ramSize = 0x10000, width = 16, height = 16, back = 0x4000, depth = 0x5000 })
	local ram = scene(chip)
	local raster = chip.gpu.raster
	raster.colourBase = 0x4000
	raster.depthBase = 0x5000
	raster:setScissor(0, 0, 16, 16)
	raster:clear(0xFF000000)

	local drawn = raster:drawMesh(0x6200, 0x6000, 0, 0, false, 0.0001)
	eq('one triangle reached the rasteriser', drawn, 1)
	eq('inside pixel is drawn', buffer.readu32(ram, 0x4000 + (5 * 16 + 2) * 4), 0xFFFFFFFF)
	eq('outside pixel keeps the clear colour', buffer.readu32(ram, 0x4000 + (2 * 16 + 5) * 4), 0xFF000000)
	check('depth holds 1/w', math.abs(buffer.readf32(ram, 0x5000 + (5 * 16 + 2) * 4) - 1.0) < 1e-6)
end

do
	-- Gouraud: red, green and blue at the three corners, then check that a
	-- pixel next to the red corner is dominated by red.
	local chip = Zindex.new({ ramSize = 0x10000, width = 16, height = 16, back = 0x4000, depth = 0x5000 })
	local ram = scene(chip)
	buffer.writeu32(ram, 0x6300, 0xFF0000FF)
	buffer.writeu32(ram, 0x6304, 0xFF00FF00)
	buffer.writeu32(ram, 0x6308, 0xFFFF0000)
	buffer.writeu32(ram, 0x6208, 0x6300)

	local raster = chip.gpu.raster
	raster.colourBase = 0x4000
	raster.depthBase = 0x5000
	raster:setScissor(0, 0, 16, 16)
	raster:clear(0xFF000000)
	raster:drawMesh(0x6200, 0x6000, 1, 0, false, 0.0001)

	local word = buffer.readu32(ram, 0x4000 + (14 * 16 + 1) * 4)
	local r = word % 256
	local g = math.floor(word / 256) % 256
	local b = math.floor(word / 65536) % 256
	check('gouraud interpolates toward the near corner', r > 180 and g < 80 and b < 80, r .. ',' .. g .. ',' .. b)
end

do
	-- Depth: the same screen triangle at w = 2 is farther, so it must lose.
	local chip = Zindex.new({ ramSize = 0x10000, width = 16, height = 16, back = 0x4000, depth = 0x5000 })
	local ram = scene(chip)
	buffer.writeu32(ram, 0x6300, 0xFF0000FF)
	putFloats(ram, 0x6400, {
		1.0, 0.0, 0.0, 0.0,
		0.0, 1.0, 0.0, 0.0,
		0.0, 0.0, 1.0, 0.0,
		0.0, 0.0, 0.0, 2.0,
	})

	local raster = chip.gpu.raster
	raster.colourBase = 0x4000
	raster.depthBase = 0x5000
	raster:setScissor(0, 0, 16, 16)
	raster:clear(0xFF000000)
	raster:drawMesh(0x6200, 0x6000, 0, 0, false, 0.0001)
	-- now give the mesh a colour, so a wrongly drawn far triangle would show up
	buffer.writeu32(ram, 0x6208, 0x6300)
	raster:drawMesh(0x6200, 0x6400, 1, 0, false, 0.0001)

	eq('nearer fragment wins the depth test', buffer.readu32(ram, 0x4000 + (5 * 16 + 2) * 4), 0xFFFFFFFF)
	check('depth still holds the near value', math.abs(buffer.readf32(ram, 0x5000 + (5 * 16 + 2) * 4) - 1.0) < 1e-6)
end

do
	-- Culling: reversing the winding makes it a back face.
	local chip = Zindex.new({ ramSize = 0x10000, width = 16, height = 16, back = 0x4000, depth = 0x5000 })
	local ram = scene(chip)
	local raster = chip.gpu.raster
	raster.colourBase = 0x4000
	raster.depthBase = 0x5000
	raster:setScissor(0, 0, 16, 16)
	raster:clear(0xFF000000)

	local front = raster:drawMesh(0x6200, 0x6000, 0, 0, true, 0.0001)
	eq('front face survives culling', front, 1)

	raster:clear(0xFF000000)
	raster.stats.culled = 0
	-- Reverse the winding with an index buffer: now it is a back face.
	buffer.writeu32(ram, 0x6340, 2)
	buffer.writeu32(ram, 0x6344, 1)
	buffer.writeu32(ram, 0x6348, 0)
	buffer.writeu32(ram, 0x6210, 0x6340)
	local back = raster:drawMesh(0x6200, 0x6000, 0, 0, true, 0.0001)
	eq('back face is culled', back, 0)
	eq('cull counter moved', raster.stats.culled, 1)
	eq('nothing was drawn for the back face', buffer.readu32(ram, 0x4000 + (5 * 16 + 2) * 4), 0xFF000000)
end

do
	-- Pin the matrix convention. Row-major, column-vector: translation belongs
	-- in the fourth column, which is elements 3, 7 and 11. Getting this wrong
	-- silently produces w = -1 for every vertex, so it is worth a test.
	local chip = Zindex.new({ ramSize = 0x10000, width = 16, height = 16, back = 0x4000, depth = 0x5000 })
	local ram = scene(chip)
	-- shift x by +1 in clip space: element 3 is the x translation
	local translation = {
		1.0, 0.0, 0.0, 1.0,
		0.0, 1.0, 0.0, 0.0,
		0.0, 0.0, 1.0, 0.0,
		0.0, 0.0, 0.0, 1.0,
	}
	putFloats(ram, 0x6500, translation)

	local raster = chip.gpu.raster
	raster.colourBase = 0x4000
	raster.depthBase = 0x5000
	raster:setScissor(0, 0, 16, 16)
	raster:clear(0xFF000000)
	raster:drawMesh(0x6200, 0x6500, 0, 0, false, 0.0001)

	-- The triangle originally covered x < y. One clip unit is half the screen, so
	-- it now covers 8 <= x <= y + 8: pixel (10, 14) is inside, and (2, 5) - which
	-- was inside before the shift - is now outside.
	eq('translation moves the triangle', buffer.readu32(ram, 0x4000 + (14 * 16 + 10) * 4), 0xFFFFFFFF)
	eq('the old region is now empty', buffer.readu32(ram, 0x4000 + (5 * 16 + 2) * 4), 0xFF000000)
	eq('depth stays 1/w for a w = 1 matrix', buffer.readf32(ram, 0x5000 + (14 * 16 + 10) * 4), 1.0)
end

--=====================================================================
-- Graphics unit, driven by guest machine code
--=====================================================================

do
	local chip = Zindex.new({ ramSize = 0x10000, width = 16, height = 16, back = 0x4000, depth = 0x5000 })
	chip:assemble[[
			li r1, 0x0F006000
			li r2, queue
			sw r2, 0(r1)
			li r2, 3
			sw r2, 4(r1)
			li r2, 1
			sw r2, 8(r1)
			halt

			.org 0x6000
		matrix:
			.f32 1.0, 0.0, 0.0, 0.0
			.f32 0.0, 1.0, 0.0, 0.0
			.f32 0.0, 0.0, 1.0, 0.0
			.f32 0.0, 0.0, 0.0, 1.0
		positions:
			.f32 -1.0, -1.0, 0.0
			.f32 1.0, -1.0, 0.0
			.f32 -1.0, 1.0, 0.0
		mesh:
			.word 3, positions, 0, 0, 0, 3
		queue:
			.word 1, 0xFF000000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
			.word 3, mesh, 0, 0, matrix, 0, 0, 1, 0, 0, 0, 0
			.word 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
	]]
	chip:run(1000)

	eq('guest ran the gpu queue', chip.gpu.commandsRun, 3)
	eq('guest draw reached the rasteriser', chip.gpu.raster.stats.triangles, 1)
	eq('guest-drawn pixel', buffer.readu32(chip:ram(), 0x4000 + (5 * 16 + 2) * 4), 0xFFFFFFFF)
	check('guest asked for a present', chip.devices.framebuffer.presentRequested == true)
	eq('gpu status is done', chip.gpu.status, 2)
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
