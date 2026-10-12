# Zindex-32 (Z32)

A **virtual chip architecture** designed for Luau - an ISA built *for* Roblox's substrate
instead of borrowed from someone else's silicon - plus a working implementation of it.

You can use the chip today. It runs in Roblox and it runs in the Luau CLI.

## Quick start

```lua
local Zindex = require(game.ReplicatedStorage.Zindex)

local chip = Zindex.new({ ramSize = 0x10000 })
chip:assemble[[
	li r1, 0
	li r2, 1
	li r3, 10
loop:
	add r1, r1, r2
	addi r2, r2, 1
	bgeu r3, r2, loop
	halt
]]
chip:run(10000)
print(chip:reg(1))   --> 55
```

Draw to a framebuffer and let the host present it once per frame:

```lua
local chip = Zindex.new({ ramSize = 0x10000, width = 320, height = 240, back = 0x4000 })
chip:assemble(program)

local view = Zindex.RobloxView.new(chip, { parent = script.Parent })
view:start(50000)   -- cycles per frame
```

Or upload a mesh and let guest machine code draw it through the graphics command queue:

```lua
chip.gpu.raster.stats.drawn   -- fragments written
chip.devices.framebuffer.presentRequested
```

`Examples/demo.luau` fills 4096 pixels from machine code, asks the host to present, prints
through a host call, and exits. `Examples/gpu.luau` uploads a mesh and a matrix, then has guest
code draw a 3D cube through the command queue - transform, near clip, perspective divide,
back-face cull, depth test and edge-function raster, all of it.

## Layout

```
src/Zindex/Opcodes.luau     the instruction set as data
src/Zindex/Memory.luau      address space: RAM buffer, device window, trap page
src/Zindex/Devices.luau     DEV, TIMER, INPUT, AUDIO, IPC, FB
src/Zindex/Raster.luau      transform, near clip, project, cull, edge-function raster
src/Zindex/Gpu.luau         graphics unit: command queue, registers, queue pump
src/Zindex/Core.luau        a CPU core: decode, execute, cycle accounting, disassembler
src/Zindex/Assembler.luau   two-pass assembler: labels, expressions, directives, listing
src/Zindex/Image.luau       program image pack and unpack
src/Zindex/init.luau        public API: build, load, run, snapshot, restore, host calls
src/Zindex/RobloxView.luau  the only file that touches a Roblox API
```

## Running the tests

```
python3 Tests/bundle.py && luau Tests/combined.luau
```

The bundler rewrites `require(script.Parent.X)` into a module table so the library runs unchanged
outside Roblox. The suite drives the real core through the real assembler - 83 checks covering
arithmetic wrapping, 32-bit multiply exactness, shifts, signed and unsigned comparison, memory
access with sign extension, control flow, calls, the vector unit, devices, host calls, the
assembler, images, illegal opcodes, byte-exact save state replay, and on the graphics side
coverage, depth, interpolation, culling and the matrix convention, ending with assembled guest
code that writes its own command queue and kicks the GPU.

## Documentation

| Doc | Contents |
| --- | --- |
| [`docs/00-overview.md`](docs/00-overview.md) | why Zindex exists, design principles, scope |
| [`docs/01-isa.md`](docs/01-isa.md) | registers, encoding, opcode map, vector unit, ABI |
| [`docs/02-memory-and-devices.md`](docs/02-memory-and-devices.md) | address space, memory map, MMIO, shared memory, image format |
| [`docs/03-execution-model.md`](docs/03-execution-model.md) | execution tiers, timing contract, scheduler, save states |
| [`docs/04-barriers.md`](docs/04-barriers.md) | the walls Zindex is shaped around, and what it does *not* claim |
| [`docs/05-soc.md`](docs/05-soc.md) | units, memory domains, command queue, frame model |
| [`docs/06-gpu-avalon.md`](docs/06-gpu-avalon.md) | the Avalon R1 raster unit, its contract and its hard limits |
| [`docs/07-npu.md`](docs/07-npu.md) | the Z-NPU vector/tensor unit, and its 3-lane ceiling |
| [`docs/08-peak.md`](docs/08-peak.md) | what the real ceiling is, and where the remaining risk is |
| [`docs/09-implementation.md`](docs/09-implementation.md) | what is built, what is tested, and what is not there yet |

## Why it is shaped this way

Roblox cannot give you more RAM, more storage, a GPU, or a client-side JIT. Those walls are
permanent, so Zindex is designed around them: 32-bit words because Luau numbers are doubles,
byte-aligned instruction encoding because `bit32` is a library of function calls and a bit-packed
format would tax every instruction executed, machine state in `buffer`s rather than tables so a
register costs 4 bytes instead of 20-30, a float unit that literally *is* Luau's natively
accelerated `vector` maths, a cycle-budget scheduler that cannot trip the watchdog, and
deterministic execution so save states and replay are exact.

Start with `docs/09-implementation.md` for the honest state of things.
