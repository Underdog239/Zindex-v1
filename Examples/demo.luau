--[[
	Zindex example: fill a framebuffer from Z32 machine code, then ask the host
	to present it.

	In Roblox:
		local Zindex = require(game.ReplicatedStorage.Zindex)
		local view = Zindex.RobloxView.new(chip, { parent = script.Parent })
		view:start(50000)

	From the command line:
		python3 Tests/bundle.py Examples/demo.luau && luau Tests/debug.luau
]]

local Zindex = __mods and __mods.Zindex or require(game.ReplicatedStorage.Zindex)

local WIDTH = 64
local HEIGHT = 64
local FRAMEBUFFER = 0x4000

local chip = Zindex.new({
	ramSize = 0x10000,
	width = WIDTH,
	height = HEIGHT,
	back = FRAMEBUFFER,
})

chip:assemble[[
		li r1, 0x4000        ; framebuffer base
		li r2, 0             ; pixel index
		li r3, 4096          ; pixel count
		li r4, 0x00FF8040    ; packed RGBA
	fill:
		shli r6, r2, 2       ; index * 4, one word per pixel
		add r7, r1, r6
		sw r4, 0(r7)
		addi r2, r2, 1
		bltu r2, r3, fill

		li r1, 2             ; syscall: present
		ecall
		li r1, 1             ; syscall: print
		li r2, message
		ecall
		li r1, 0             ; syscall: exit
		li r2, 0
		ecall

		.org 0x8000
	message:
		.ascii "filled 4096 pixels and asked the host to present"
		.byte 0
]]

local used = chip:run(1000000)

print(string.format('cycles used:      %d', used))
print(string.format('present requests: %d', chip.presents))
print(string.format('first pixel:      0x%08X', buffer.readu32(chip:ram(), FRAMEBUFFER)))
print(string.format('last pixel:       0x%08X', buffer.readu32(chip:ram(), FRAMEBUFFER + (WIDTH * HEIGHT - 1) * 4)))
print(string.format('exit code:        %d', chip:exitCode()))
