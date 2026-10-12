# 05 - System-on-Chip

The SoC view: Z-CPU cores + an Avalon R1 raster unit + a Z-NPU tensor unit, on one interconnect,
driven by one scheduler.

## 1. Units

| Unit | What it is | Host realisation |
| --- | --- | --- |
| Z-CPU cluster | 1..N Z32 cores | N Actors, each running `core:run(cycles)` |
| Avalon R1 GPU | tile rasteriser + texture sampler | Luau rasteriser writing packed RGBA8 into a buffer; one EditableImage upload per frame |
| Z-NPU | float32 dot / matrix unit | Luau native `vector` ops fanned out across Actors |
| DMA | bulk memory movement | `buffer.copy` / `buffer.fill` |
| TIMER / IRQ | cycle counter, interrupts | MMIO page |
| HOST BRIDGE | the only place engine APIs exist | one small function boundary |

**Rule: the CPU never calls an engine API.** Units talk through memory and the command queue, or
through the bridge. This keeps the entire compute graph native-compilable, and confines the
platform-dependent code to one small, replaceable surface.

## 2. Memory domains

| Domain | Type | Sharable | Used by |
| --- | --- | --- | --- |
| D0 private | `buffer` | no | each core's RAM |
| D1 frame | `buffer` | no | framebuffer colour + depth, owned by the GPU |
| D2 shared | `SharedTable` | yes, word-addressed uint32 | cross-core flags, atomics |
| D3 asset | `buffer` (read-only by convention) | no | meshes (structure-of-arrays), textures |

Buffers cannot cross Actors, so any cross-unit buffer movement is either a serialising message or
a SharedTable. Both copy. The design therefore minimises transfers: each unit owns its buffers,
and only tiles and results ever cross a boundary.

## 3. Command queue

The GPU and NPU are not called. They are fed.

A command is 48 bytes, 12 words:

| Word | Field | Meaning |
| --- | --- | --- |
| +0x00 | op | NOP, CLEAR, SET_DEPTH, DRAW_MESH, PRESENT, SET_COLOUR |
| +0x04 | src | source buffer address |
| +0x08 | dst | destination buffer address, or 0 for the default |
| +0x0C | count | triangle or element count |
| +0x10 | matrix | matrix address |
| +0x14 | texture | texture descriptor address, or 0 |
| +0x18 | shading | 0 flat, 1 gouraud, 2 textured |
| +0x1C | flags | bit 0 = back-face culling |
| +0x20 | rectX | scissor rectangle, 0 0 0 0 means the whole target |
| +0x24 | rectY | |
| +0x28 | rectW | |
| +0x2C | rectH | |

The CPU writes commands into RAM and kicks the queue by writing the GPU kick register in the MMIO
window. Queues are limited to 256 commands and must fit wholly in RAM. The host bridge validates
the descriptors before reading them; oversized queues or invalid work set status 3 (rejected).
GPU raster work is also capped per pump so a guest cannot turn a frame callback into unbounded
host work.

## 4. Frame model

1. CPU cores run for their cycle budget.
2. The bridge drains the GPU queue: transform stage, raster stage, composite, one present.
3. NPU jobs run alongside raster tiles, because they are independent Actor work.
4. Present: exactly one `EditableImage:WritePixelsBuffer` for the frame.

The reference budget split is 45% CPU / 40% GPU / 15% NPU, and it is a starting point to be tuned
per scene with the profiler - not a law.

## 5. Measuring the ceiling

Because the client is interpreted, the only honest ceiling statement is a measured one:

```
client peak  ~=  (interpreted instructions/sec) x (busy cores)
server peak  ~=  (native instructions/sec)      x (busy cores)
```

Avalon already ships a headless harness, so throughput per unit can be measured outside Roblox
and then checked inside it. Any spec claim that is not backed by that measurement is marketing.
