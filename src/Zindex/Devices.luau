--!strict
--[[
	Devices - the Z32 device window (docs/02-memory-and-devices.md).

	Every device is a small register file behind the MMIO window. Reading one is
	an ordinary LW, so there is no second decode path in the core.

	Pages:
		0x0F000000  DEV    interrupt pending/enable mask, exit code, IRQ vector
		0x0F001000  TIMER  cycle counter, compare, reload, control, fired
		0x0F002000  INPUT  buttons, pointer, wheel
		0x0F003000  AUDIO  ring buffer descriptor (base, length, cursors, rate)
		0x0F004000  IPC    core id, core count, shared region, MMIO atomics
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

Devices.IRQ = {
	TIMER = 1,
}

--- Build a device from a read function and an optional write function.
local function registers(read: (number) -> number, write: ((number, number) -> ())?): Memory.Device
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

export type Dev = {
	pending: number,
	enable: number,
	exitCode: number,
	vector: number,
	returnPc: number,
}

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

export type Audio = {
	base: number,
	length: number,
	readCursor: number,
	writeCursor: number,
	sampleRate: number,
	channels: number,
	control: number,
}

export type Ipc = {
	coreId: number,
	coreCount: number,
	sharedBase: number,
	sharedSize: number,
	wordIndex: number,
	lastAtomic: number,
	barrierGen: number,
}

export type Handles = {
	dev: Dev,
	timer: Timer,
	framebuffer: Framebuffer,
	input: Input,
	audio: Audio,
	ipc: Ipc,
	tick: (cycles: number?) -> number,
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
	sharedSize: number?,
	onIrqConfig: ((enabled: boolean, vector: number) -> ())?,
}): Handles
	local dev: Dev = {
		pending = 0,
		enable = 0,
		exitCode = 0,
		vector = 0,
		returnPc = 0,
	}
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
	local audio: Audio = {
		base = 0,
		length = 0,
		readCursor = 0,
		writeCursor = 0,
		sampleRate = 44100,
		channels = 1,
		control = 0,
	}
	local ipc: Ipc = {
		coreId = options.coreId or 0,
		coreCount = options.coreCount or 1,
		sharedBase = 0,
		sharedSize = options.sharedSize or 0,
		wordIndex = 0,
		lastAtomic = 0,
		barrierGen = 0,
	}

	local function tick(nowCycles: number?): number
		if bit32.band(timer.control, 1) ~= 0 and timer.compare > 0 then
			local now = if nowCycles ~= nil then nowCycles else timer.clock()
			if now >= timer.compare then
				dev.pending = bit32.bor(dev.pending, Devices.IRQ.TIMER)
				if timer.reload > 0 then
					-- Advance by all elapsed periods in constant time. The guest
					-- controls reload, so a per-period loop would let reload=1 turn
					-- a timer read into work proportional to the chip's uptime.
					local elapsed = math.floor((now - timer.compare) / timer.reload) + 1
					timer.fired = (timer.fired + elapsed) % WRAP
					timer.compare += elapsed * timer.reload
				else
					timer.fired = (timer.fired + 1) % WRAP
					timer.control = bit32.band(timer.control, bit32.bnot(1))
				end
			end
		end
		return bit32.band(dev.pending, dev.enable)
	end

	local function syncIrqConfig()
		if options.onIrqConfig ~= nil then
			local active = dev.enable ~= 0 or bit32.band(timer.control, 1) ~= 0
			options.onIrqConfig(active, dev.vector)
		end
	end

	memory:registerPageDevice(Devices.PAGE.DEV, registers(function(offset: number): number
		if offset == 0x00 then
			return tick(nil)
		elseif offset == 0x04 then
			return dev.enable
		elseif offset == 0x08 then
			return dev.exitCode
		elseif offset == 0x0C then
			return dev.vector
		elseif offset == 0x10 then
			return dev.returnPc
		end
		return 0
	end, function(offset: number, value: number)
		if offset == 0x00 then
			dev.pending = value
		elseif offset == 0x04 then
			dev.enable = value
			syncIrqConfig()
		elseif offset == 0x08 then
			dev.exitCode = value
		elseif offset == 0x0C then
			dev.vector = value
			syncIrqConfig()
		elseif offset == 0x10 then
			dev.returnPc = value
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
			tick(nil)
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
			syncIrqConfig()
		elseif offset == 0x10 then
			timer.fired = 0
			if value == 0 then
				dev.pending = bit32.band(dev.pending, bit32.bnot(Devices.IRQ.TIMER))
			end
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
		if offset == 0x00 then
			return audio.base
		elseif offset == 0x04 then
			return audio.length
		elseif offset == 0x08 then
			return audio.readCursor
		elseif offset == 0x0C then
			return audio.writeCursor
		elseif offset == 0x10 then
			return audio.sampleRate
		elseif offset == 0x14 then
			return audio.channels
		elseif offset == 0x18 then
			return audio.control
		elseif offset == 0x1C then
			if audio.length > 0 then
				return (audio.writeCursor - audio.readCursor) % audio.length
			end
			return 0
		end
		return 0
	end, function(offset: number, value: number)
		if offset == 0x00 then
			audio.base = value
		elseif offset == 0x04 then
			audio.length = math.min(value, math.floor(memory.ramSize / 4))
			if audio.length > 0 then
				audio.readCursor %= audio.length
				audio.writeCursor %= audio.length
			else
				audio.readCursor = 0
				audio.writeCursor = 0
			end
		elseif offset == 0x08 then
			audio.readCursor = if audio.length > 0 then value % audio.length else value
		elseif offset == 0x0C then
			audio.writeCursor = if audio.length > 0 then value % audio.length else value
		elseif offset == 0x10 then
			audio.sampleRate = value
		elseif offset == 0x14 then
			audio.channels = value
		elseif offset == 0x18 then
			audio.control = value
		end
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
		elseif offset == 0x10 then
			return ipc.wordIndex
		elseif offset == 0x14 then
			return memory:readShared(ipc.wordIndex)
		elseif offset == 0x18 then
			return ipc.lastAtomic
		elseif offset == 0x1C then
			return ipc.barrierGen
		end
		return 0
	end, function(offset: number, value: number)
		if offset == 0x08 then
			ipc.sharedBase = value
		elseif offset == 0x0C then
			ipc.sharedSize = value
		elseif offset == 0x10 then
			ipc.wordIndex = value
		elseif offset == 0x14 then
			memory:writeShared(ipc.wordIndex, value)
		elseif offset == 0x18 then
			ipc.lastAtomic = memory:atomicAddShared(ipc.wordIndex, value)
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
			return if framebuffer.presentRequested then 1 else 0
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
		dev = dev,
		timer = timer,
		framebuffer = framebuffer,
		input = input,
		audio = audio,
		ipc = ipc,
		tick = tick,
	}
end

return Devices
