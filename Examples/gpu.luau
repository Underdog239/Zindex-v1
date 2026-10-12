--[[
	Zindex example: a textured-and-lit 3D cube drawn entirely through the Z32
	graphics command queue.

	The host uploads assets (a matrix, a mesh, an index buffer) into RAM, exactly
	as a loader would. The guest then writes three commands into its own memory
	and kicks the queue. Nothing draws on the CPU.

	In Roblox:
		local view = Zindex.RobloxView.new(chip, { parent = script.Parent })
		view:start(50000)

	From the command line:
		python3 Tests/bundle.py Examples/gpu.luau && luau Tests/debug.luau
]]

local Zindex = __mods and __mods.Zindex or require(game.ReplicatedStorage.Zindex)

local WIDTH = 64
local HEIGHT = 64
local COLOUR = 0x10000
local DEPTH = 0x14000

local MATRIX = 0x6000
local POSITIONS = 0x6100
local INDICES = 0x6200
local MESH = 0x6300
local QUEUE = 0x6400

--=====================================================================
-- Host side: build a matrix and upload the mesh
--=====================================================================

local function multiply(a, b)
	local out = table.create(16)
	for row = 0, 3 do
		for column = 0, 3 do
			local sum = 0
			for k = 0, 3 do
				sum += a[row * 4 + k + 1] * b[k * 4 + column + 1]
			end
			out[row * 4 + column + 1] = sum
		end
	end
	return out
end

--- Row-major, column-vector convention: the projection row is the last one, so
--- w = -z and anything in front of the camera has w > 0.
local function perspective(fovY, aspect, near, far)
	local f = 1 / math.tan(fovY / 2)
	return {
		f / aspect, 0, 0, 0,
		0, f, 0, 0,
		0, 0, (far + near) / (near - far), (2 * far * near) / (near - far),
		0, 0, -1, 0,
	}
end

local angle = 0.7
local cosine, sine = math.cos(angle), math.sin(angle)
local rotation = {
	cosine, 0, sine, 0,
	0, 1, 0, 0,
	-sine, 0, cosine, 0,
	0, 0, 0, 1,
}
-- Column-vector convention puts translation in the fourth column, so the z
-- offset sits at element 11, not 14.
local view = {
	1, 0, 0, 0,
	0, 1, 0, 0,
	0, 0, 1, -4.5,
	0, 0, 0, 1,
}
local matrix = multiply(perspective(math.rad(60), 1, 0.1, 100), multiply(view, rotation))

local cubePositions = {
	-1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1,
	-1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1,
}

-- Vertices are listed 1-based here and converted to 0-based on upload, so
-- these indices refer to the corner numbers as written above. Each face is
-- wound counter-clockwise as seen from outside the cube.
local cubeIndices = {
	5, 6, 7, 5, 7, 8,
	2, 1, 4, 2, 4, 3,
	1, 5, 8, 1, 8, 4,
	6, 2, 3, 6, 3, 7,
	4, 8, 7, 4, 7, 3,
	1, 2, 6, 1, 6, 5,
}

--=====================================================================
-- Chip
--=====================================================================

local chip = Zindex.new({
	ramSize = 0x20000,
	width = WIDTH,
	height = HEIGHT,
	back = COLOUR,
	depth = DEPTH,
})

chip:assemble[[
	li r1, 0x0F006000
	li r2, 0x6400
	sw r2, 0(r1)
	li r2, 3
	sw r2, 4(r1)
	li r2, 1
	sw r2, 8(r1)
	halt
]]

local ram = chip:ram()

for index, value in matrix do
	buffer.writef32(ram, MATRIX + (index - 1) * 4, value)
end
for index, value in cubePositions do
	buffer.writef32(ram, POSITIONS + (index - 1) * 4, value)
end
for index, value in cubeIndices do
	buffer.writeu32(ram, INDICES + (index - 1) * 4, value - 1)
end

-- mesh descriptor
buffer.writeu32(ram, MESH + 0x00, 8)
buffer.writeu32(ram, MESH + 0x04, POSITIONS)
buffer.writeu32(ram, MESH + 0x08, 0)
buffer.writeu32(ram, MESH + 0x0C, 0)
buffer.writeu32(ram, MESH + 0x10, INDICES)
buffer.writeu32(ram, MESH + 0x14, #cubeIndices)

-- three commands: clear, draw, present
local function command(index, fields)
	local base = QUEUE + index * Zindex.Gpu.COMMAND_SIZE
	for slot, value in fields do
		buffer.writeu32(ram, base + (slot - 1) * 4, value)
	end
end

local CLEAR, DRAW_MESH, PRESENT = 1, 3, 4
local FLAT, GOURAUD, TEXTURED = 0, 1, 2

command(0, { CLEAR, 0xFF181820 })
command(1, { DRAW_MESH, MESH, COLOUR, 0, MATRIX, 0, FLAT, 1 })
command(2, { PRESENT })

--=====================================================================
-- Run
--=====================================================================

chip:run(1000)

local drawn = 0
for pixel = 0, WIDTH * HEIGHT - 1 do
	if buffer.readu32(ram, COLOUR + pixel * 4) ~= 0xFF181820 then
		drawn += 1
	end
end

print(string.format('commands run:       %d', chip.gpu.commandsRun))
print(string.format('triangles submitted: %d', chip.gpu.raster.stats.triangles))
print(string.format('back faces culled:  %d', chip.gpu.raster.stats.culled))
print(string.format('fragments written:  %d', chip.gpu.raster.stats.drawn))
print(string.format('pixels not clear:   %d of %d', drawn, WIDTH * HEIGHT))
print(string.format('present requested:  %s', tostring(chip.devices.framebuffer.presentRequested)))
