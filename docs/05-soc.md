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

| Field | Meaning |
| --- | --- |
| op | draw mesh, set matrix, clear, set tile, composite, present, tensor op |
| src | source buffer address |
| dst | destination buffer address (tile or framebuffer) |
| count | triangle or element count |
| rect | tile rectangle, x y w h |
| arg | op-specific parameter |

The CPU writes commands into RAM and kicks the queue by writing the GPU kick register in the MMIO
window. The host bridge drains the queue each frame and dispatches work to Actors.

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
