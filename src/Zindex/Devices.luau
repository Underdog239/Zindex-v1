--!strict
--!nonstrict
--[[
	Devices - the Z32 device window (docs/02-memory-and-devices.md).

	Every device is a small register file behind the MMIO window. Reading one is
	an ordinary LW, so there is no second decode path in the core.

	Pages:
		0x0F000000  DEV    interrupt mask, exit code
		0x0F001000  TIMER  cycle counter, compare, reload, control
		0x0F002000  INPUT  buttons, pointer
		0x0F003000  AUDIO  ring buffer descriptor
		0x0F004000  IPC    core id, core count, shared region
		0x0F005000  FB     framebuffer descriptor
]]

local Memory = require(script.Parent.Memory)

local Devices = {}

local WRAP = 4294967296

Devices.PAGE = {
	DEV = 0x0F000000,
	TIMER = 0x0F001000,
	INPUT = 0x0F002000,
	AUDIO = 0x0F003000,
	IPC = 0x0F004000,
	FB = 0x0F005000,
}

--- Build a device from a read function and an optional write function.
local function registers(read: (number) -> number, write: ((number, number) -> ())?)
	local device: Memory.Device = {
		read32 = function(offset: number): number
			return read(offset) % WRAP
		end,
	}
	if write ~= nil then
		device.write32 = function(offset: number, value: number)
			write(offset, value % WRAP)
		end
	end
	return device
end

export type Framebuffer = {
	width: number,
	height: number,
	format: number,
	back: number,
	front: number,
	dirtyX: number,
	dirtyY: number,
	dirtyW: number,
	dirtyH: number,
	presentRequested: boolean,
}

export type Timer = {
	clock: () -> number,
	compare: number,
	reload: number,
	control: number,
	fired: number,
}

export type Input = {
	buttons: number,
	pointerX: number,
	pointerY: number,
	wheel: number,
}

export type Ipc = {
	coreId: number,
	coreCount: number,
	sharedBase: number,
	sharedSize: number,
}

export type Handles = {
	timer: Timer,
	framebuffer: Framebuffer,
	input: Input,
	ipc: Ipc,
}

--- Attach the standard device set to a memory bus.
function Devices.attach(memory: Memory.Class, options: {
	clock: () -> number,
	width: number?,
	height: number?,
	format: number?,
	back: number?,
	front: number?,
	coreId: number?,
	coreCount: number?,
}): Handles
	local timer: Timer = {
		clock = options.clock,
		compare = 0,
		reload = 0,
		control = 0,
		fired = 0,
	}
	local framebuffer: Framebuffer = {
		width = options.width or 0,
		height = options.height or 0,
		format = options.format or 0,
		back = options.back or 0,
		front = options.front or 0,
		dirtyX = 0,
		dirtyY = 0,
		dirtyW = 0,
		dirtyH = 0,
		presentRequested = false,
	}
	local input: Input = { buttons = 0, pointerX = 0, pointerY = 0, wheel = 0 }
	local ipc: Ipc = {
		coreId = options.coreId or 0,
		coreCount = options.coreCount or 1,
		sharedBase = 0,
		sharedSize = 0,
	}
	local pending = 0
	local enable = 0
	local exitCode = 0

	memory:registerDevice(Devices.PAGE.DEV, registers(function(offset: number): number
		if offset == 0x00 then
			return bit32.band(pending, enable)
		elseif offset == 0x04 then
			return enable
		elseif offset == 0x08 then
			return exitCode
		end
		return 0
	end, function(offset: number, value: number)
		if offset == 0x00 then
			pending = value
		elseif offset == 0x04 then
			enable = value
		elseif offset == 0x08 then
			exitCode = value
		end
	end))

	memory:registerDevice(Devices.PAGE.TIMER, registers(function(offset: number): number
		if offset == 0x00 then
			return timer.clock()
		elseif offset == 0x04 then
			return timer.compare
		elseif offset == 0x08 then
			return timer.reload
		elseif offset == 0x0C then
			return timer.control
		elseif offset == 0x10 then
			return timer.fired
		end
		return 0
	end, function(offset: number, value: number)
		if offset == 0x04 then
			timer.compare = value
		elseif offset == 0x08 then
			timer.reload = value
		elseif offset == 0x0C then
			timer.control = value
		elseif offset == 0x10 then
			timer.fired = 0
		end
	end))

	memory:registerDevice(Devices.PAGE.INPUT, registers(function(offset: number): number
		if offset == 0x00 then
			return input.buttons
		elseif offset == 0x04 then
			return input.pointerX
		elseif offset == 0x08 then
			return input.pointerY
		elseif offset == 0x0C then
			return input.wheel
		end
		return 0
	end, nil))

	memory:registerDevice(Devices.PAGE.AUDIO, registers(function(offset: number): number
		return 0
	end, function(offset: number, value: number)
		-- The audio ring descriptor is a host concern; the guest only points at
		-- it. Kept addressable so guests can be written against it today.
	end))

	memory:registerDevice(Devices.PAGE.IPC, registers(function(offset: number): number
		if offset == 0x00 then
			return ipc.coreId
		elseif offset == 0x04 then
			return ipc.coreCount
		elseif offset == 0x08 then
			return ipc.sharedBase
		elseif offset == 0x0C then
			return ipc.sharedSize
		end
		return 0
	end, function(offset: number, value: number)
		if offset == 0x08 then
			ipc.sharedBase = value
		elseif offset == 0x0C then
			ipc.sharedSize = value
		end
	end))

	memory:registerDevice(Devices.PAGE.FB, registers(function(offset: number): number
		if offset == 0x00 then
			return framebuffer.width
		elseif offset == 0x04 then
			return framebuffer.height
		elseif offset == 0x08 then
			return framebuffer.format
		elseif offset == 0x0C then
			return framebuffer.back
		elseif offset == 0x10 then
			return framebuffer.front
		elseif offset == 0x14 then
			return framebuffer.dirtyX
		elseif offset == 0x18 then
			return framebuffer.dirtyY
		elseif offset == 0x1C then
			return framebuffer.dirtyW
		elseif offset == 0x20 then
			return framebuffer.dirtyH
		elseif offset == 0x24 then
			return framebuffer.presentRequested and 1 or 0
		end
		return 0
	end, function(offset: number, value: number)
		if offset == 0x14 then
			framebuffer.dirtyX = value
		elseif offset == 0x18 then
			framebuffer.dirtyY = value
		elseif offset == 0x1C then
			framebuffer.dirtyW = value
		elseif offset == 0x20 then
			framebuffer.dirtyH = value
		elseif offset == 0x24 then
			framebuffer.presentRequested = value ~= 0
		end
	end))

	return {
		timer = timer,
		framebuffer = framebuffer,
		input = input,
		ipc = ipc,
	}
end

return Devices
