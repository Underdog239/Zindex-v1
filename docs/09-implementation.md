# 09 - Implementation status

What exists in `src/Zindex`, what it has been tested against, and what remains
platform-bounded. Written so that nobody has to guess.

## 1. What exists

| Module | Role |
| --- | --- |
| `Opcodes.luau` | the instruction set as data: opcode, name, encoding form, size (including shared-memory `LWS`/`SWS`/`AMOADD` and Z-NPU `VFMA`/`VDP3`/`VRED`/`VSCL`/`VMIN`/`VMAX`) |
| `Memory.luau` | the address space: RAM buffer, device window, trap page, shared word region, per-access cycle cost, and code-region write tracking for block invalidation |
| `Devices.luau` | the standard device set: DEV (interrupt mask & vector), TIMER (cycle counter, compare/reload IRQ), INPUT, AUDIO (ring buffer descriptor), IPC (multi-core & shared atomics), FB |
| `Raster.luau` | the Avalon R1 raster unit: transform, near clip, project, cull, edge-function raster, multi-tile rendering and `buffer.copy` scanline compositing |
| `Gpu.luau` | the graphics unit (`0x0F006000`): 48-byte command queue, registers, tile control, and Avalon adaptive resolution scaling |
| `Npu.luau` | the Z-NPU tensor / vector / DMA unit (`0x0F007000`): 48-byte command queue for `DOT_BATCH`, `FMA_BATCH`, 3-lane `GEMM` (with bias + ReLU), `NORM_BATCH`, `DEQUANT_INT8`, and `DMA_COPY` / `DMA_FILL` |
| `Core.luau` | a CPU core implementing **Tier 0** (dispatch loop), **Tier 1** (basic-block compiler with code-write invalidation), and **Tier 2** (`--!native` block execution with strength-reduced constant shifts, R0 sink slot, inline RAM buffer fast paths, and in-place self-looping blocks) |
| `Assembler.luau` | two-pass assembler: labels, expressions (including scientific-notation floats like `1e-3`), `.equ`/`.const` constants, `.macro`/`.endm` macros with local-label hygiene, directives, listing |
| `Image.luau` | program image pack and unpack |
| `init.luau` | the public API: single-core and multi-core clusters (`coreCount = N`, `SYNC` barrier, shared memory), Tier 0/1/2 selection, GPU & NPU queue pumping, audio pull, snapshot/restore, host calls |
| `RobloxView.luau` | the only file that touches a Roblox API: EditableImage presentation and adaptive resolution resize |

Every opcode in doc 01 and doc 07 is implemented, and all three execution tiers
from doc 03 (`tier = 0`, `tier = 1`, `tier = 2`) are built into `Core.luau` and
verified to produce byte-identical RAM, registers, step counts and cycle counts.

## 2. How it is tested

```
python3 Tests/bundle.py && luau Tests/combined.luau
python3 Tests/bundle.py && luau --codegen Tests/combined.luau
```

`Tests/bundle.py` rewrites `require(script.Parent.X)` into a module table so the
library runs unchanged outside Roblox, then appends `Tests/suite.luau`. The
suite drives the real core through the real assembler; nothing is mocked. **157
checks, all passing** under both the Luau interpreter and `--codegen` native
code generation, and every module in `src/Zindex/*.luau` compiles cleanly with
`luau-compile --codegen`.

Covered:
- Arithmetic wrapping and 32-bit multiply exactness, shifts including the
  32-or-more rule, signed and unsigned comparison, byte/half/word load and store
  with sign extension, loops and branches, call and return.
- **Tier 0, Tier 1 and Tier 2 equivalence**: running the same loop/call/memory/shift
  workload across all three tiers and verifying identical checksums, identical
  cycle counts, identical step counts, and byte-identical RAM.
- **Self-modifying code invalidation**: guest code in Tier 2 rewriting its own
  immediate operand inside a loop, verifying automatic block invalidation and
  recompilation matching Tier 0.
- The vector unit (`VLW`, `VSW`, `VADD`, `VSUB`, `VMUL`, `VDOT`/`VDP3`, `VLEN`,
  `VNRM`, `VCST`, `VFMA`, `VRED`, `VSCL`, `VMIN`, `VMAX`) end to end.
- **Z-NPU command queue and DMA**: guest code queueing 3-lane `GEMM` (with bias
  and ReLU), `DOT_BATCH`, `NORM_BATCH`, `DEQUANT_INT8`, and `DMA_COPY`, checking
  both numerical outputs and that `vectorOps` matches `ceil(K / 3)` per element.
- **Multi-core execution (`coreCount = 4`)**: 4 cores reading `IPC` `coreId` and
  `coreCount`, writing to the shared region with `SWS`, accumulating atomically
  with `AMOADD`, synchronizing at `SYNC`, and reducing on core 0.
- **Avalon R1 GPU**: coverage, `1/w` depth, Gouraud and textured interpolation,
  back-face culling, matrix convention, **4-tile parallel rendering + per-scanline
  `buffer.copy` compositing** (verified pixel-identical to single-tile), and
  **adaptive resolution scaling** (`gpu:adapt`).
- **Timer interrupts and Audio ring buffer**: timer compare firing a guest
  interrupt vector (`0x0F00000C`) and callback, and guest code filling the `AUDIO`
  ring buffer followed by `chip:pullAudio()`.
- **Assembler conveniences**: `.equ` constants, `.macro`/`.endm` expansion with
  local labels, scientific-notation floats (`1e-3`, `-2.5e-2`, `1.5e+2`), image
  round trip, illegal opcode handling, and byte-exact save state replay.

`Examples/demo.luau` fills a framebuffer from machine code and asks the host to
present. `Examples/gpu.luau` uploads a mesh and a matrix, then has guest code
draw a 3D cube through the command queue. `Examples/soc.luau` benchmarks Tier 0
vs Tier 1 vs Tier 2 (~2.4x faster in interpreter, ~6.7x faster over native Tier 0
and >11x faster overall under `luau --codegen`), runs a 4-core atomic reduction,
and drives both the Z-NPU and 4-tile Avalon GPU from guest code in a single frame.

## 3. Platform boundaries that remain

Stated plainly (see doc 04 and doc 08):

1. **Cross-Actor `buffer` message transport in Roblox** (doc 06 section 4). The
   multi-tile rasteriser and `buffer.copy` scanline compositor are implemented
   and verified; fanning tiles across separate Roblox `Actor` instances depends
   on the Roblox runtime's `Actor:SendMessage` buffer copy behaviour in a live
   Place.
2. **Client-side `--!native` compilation in Roblox.** All hot modules (`Core`,
   `Memory`, `Raster`, `Npu`) carry `--!native` and compile cleanly with
   `luau-compile --codegen`. On the Roblox server and in `luau --codegen` they
   execute as native machine code today; on the Roblox client they run Tier 2's
   pre-decoded block loop until client native codegen is enabled by the platform.

## 4. Bugs the tests caught, as evidence they are worth running

- `not` is form F2, which has three operand slots, but it only needs two. The
  assembler demanded all three until the suite failed on `not r9, r0`.
- `Memory` had both a field `ram` and a method `ram`. Because the field exists on
  the instance, `self.memory:ram()` resolved to the buffer and tried to call it.
  The accessor is now `getRam()`.
- `buffer.fill` sets a **byte** value, not a word. Clearing the colour plane with
  a packed RGBA word silently wrote only its low byte, so every clear produced
  zeros. `Raster:clear` now writes one 32-bit word per pixel.
- The transform was doing row-vector maths while the spec says row-major,
  column-vector. It was invisible until a 3D cube rendered as an empty screen,
  because `w` came out as `-1` for every vertex and everything was culled.
- In Tier 1/2 `Core:runBlock`, keeping `cycles` in a local register meant an MMIO
  read of the `TIMER` page (`0x0F001000`) observed a stale `core.cycles` until
  `self.cycles = cycles` was synced on the MMIO slow path.

All five were found by running the suite and the examples, not by reading code.
