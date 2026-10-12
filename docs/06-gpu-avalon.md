# 06 - Avalon R1 raster unit

This document binds the existing Avalon R1 software renderer to the Zindex SoC. Avalon's own
pipeline is unchanged; what follows is the contract the CPU sees.

## 1. What the unit is

A scanline edge-function rasteriser. Per triangle:

1. MVP transform (structure-of-arrays, flat arrays, no table indirection)
2. Near-plane clip, Sutherland-Hodgman, producing 0, 3 or 4 vertices
3. Perspective divide, giving screen coordinates and `1/w`
4. Back-face cull by signed area
5. Edge-function raster with incremental adds, depth test, attribute interpolation
6. Composite, then exactly one upload per frame

Features retained as-is: perspective-correct interpolation via attribute/w over 1/w, depth
buffer, three shading modes (`flat`, `gouraud`, `textured`), nearest texture sampling with
repeat/clamp, per-vertex directional lighting, procedural and asset-loaded textures, adaptive
resolution, and zero allocation in the draw loop.

## 2. Pixel format contract

The SoC does not redefine Avalon's formats. They are:

| Plane | Format | Notes |
| --- | --- | --- |
| colour | `width * height * 4` bytes, RGBA8 | one `buffer.writeu32` per pixel |
| depth | `width * height * 4` bytes, f32 | stores `1/w`, so larger is nearer; cleared to 0 |
| texture | `width * height * 4` bytes, packed RGBA | sampled with one `buffer.readu32` |

Packing is little-endian: `packRGBA(r, g, b, a) = r + g*256 + b*65536 + a*16777216`, channels 0-255,
using `bit32` so the hot path never allocates a Color3. Clearing depth to 0 means any visible
fragment (`1/w > 0`) passes the first depth test.

## 3. Command interface

The GPU is fed, not called. Commands are written into RAM and kicked through the MMIO window
(doc 05 section 3):

**Implemented** in `src/Zindex/Gpu.luau`, which registers itself on the GPU page
`0x0F006000` and is drained by the host once per CPU budget.

Registers:

| Offset | Register |
| --- | --- |
| +0x00 | queue base address |
| +0x04 | queue length in commands |
| +0x08 | kick, write 1 to run the queue; reads 1 while work is pending |
| +0x0C | status: 0 idle, 1 pending, 2 done, 3 rejected/limited |
| +0x10 | commands run (stat) |
| +0x14 | triangles submitted (stat) |
| +0x18 | fragments written (stat) |
| +0x1C | near plane, as float bits |
| +0x20 | colour buffer address |
| +0x24 | depth buffer address |
| +0x28 | scissor x |
| +0x2C | scissor y |
| +0x30 | scissor width |
| +0x34 | scissor height |

Commands, 48 bytes each (see doc 05 for the field list):

| Op | Meaning |
| --- | --- |
| `NOP` (0) | nothing |
| `CLEAR` (1) | `src` is a packed colour; fill the rect, clear depth to 0 |
| `SET_DEPTH` (2) | `src` becomes the depth plane address |
| `DRAW_MESH` (3) | `src` mesh, `matrix` matrix, `texture` texture, `shading` mode, `flags` culling |
| `PRESENT` (4) | request this frame's single upload |
| `SET_COLOUR` (5) | `src` becomes the colour plane address |

Guest queues are limited to 256 commands and the complete queue must fit in RAM. Each pump has a
raster budget of `max(1,000,000, 8 x viewport pixels)` work units: screen-space candidate pixels,
submitted triangle work, and tiled viewport copying. A `CLEAR` charges one unit per colour pixel
plus one per row of bulk depth clear. The budget scales with the viewport because the work does - a
fixed ceiling rejected every `CLEAR` above 500,000 pixels and every tiled draw above 1,000,000 -
and it stays bounded because the viewport is host configuration, never guest input. Scissor
rectangles are clipped to the viewport, and each mesh is limited to 8,192 triangles.
Mesh, matrix, texture, colour, depth, index, and attribute ranges are checked before raw buffer
access. Invalid descriptors or exhausted work set status 3 and stop draining the queue.

Compositing is per band and best-effort: a tiled draw composites each band as soon as that band is
drawn, so a band the budget cut short reaches the target with the fragments it did write, exactly the
way a single-tile draw keeps the triangles that finished before the budget ran out. A faulted frame
is therefore partial by construction - status 3 is what tells the host not to present it.

The colour and depth planes live in RAM, so the rasteriser writes straight into
the guest's framebuffer with no intermediate copy.

Mesh descriptor:

| Offset | Field |
| --- | --- |
| +0x00 | vertexCount |
| +0x04 | positions address, float3 per vertex |
| +0x08 | colours address, RGBA8 per vertex, or 0 |
| +0x0C | uvs address, float2 per vertex, or 0 |
| +0x10 | indices address, u32 per index, or 0 for a plain triangle list |
| +0x14 | indexCount |

Texture descriptor: +0x00 width, +0x04 height, +0x08 pixels address (RGBA8, row
major).

The matrix is 16 floats, row major, column-vector convention: the translation is
in elements 3, 7 and 11, and the projection row is 12..15. Getting that backwards
is silent - every vertex ends up with `w = -1` - so the suite pins it with a test.

## 4. Tiling and parallel rasterisation

Single-Actor rasterisation is Avalon's current behaviour and remains the default. It is known to
work and is the safe configuration.

Multi-tile mode: split the screen into T tiles, one Actor per tile. Each tile renders into its own
colour and depth buffers, then the host composites each tile into the framebuffer with one
`buffer.copy` per scanline row, followed by a single upload. `buffer.copy` is a bulk copy in the
host, so compositing is cheap relative to rasterisation - for a 360-row frame split into 6 tiles,
that is roughly 360 bulk copies per frame, which is noise next to the raster cost.

**PENDING VALIDATION.** This path depends on whether a `buffer` can be transferred between Actors
by message. The documentation states that message arguments are passed **by copy** across VM
boundaries and that functions cannot be passed, but it does not publish a definitive supported-type
list. Before the parallel raster path is specified further, this must be tested:

```
actor:SendMessage("tile", someBuffer)   -- does the receiver get a buffer, or an error?
```

If buffers cannot cross, the options are: composite through a shared representation (a
`SharedTable` word grid, which is far slower per pixel), or keep rasterisation single-Actor and
parallelise only the transform stage. The spec does not assume either outcome.

## 5. Hard limits

- **No shaders, no compute shaders, no GPU access.** Every pixel is host work. There is no path
  to offload this, and no future API is promised.
- **One displayed `EditableImage` per frame.** Exactly one upload, by construction.
- **Resolution is the dial.** Cost scales with pixels, which is why adaptive scale is the primary
  performance lever and why internal resolution is expected to be low.
- **No mipmaps** unless the CPU builds them in RAM.
- **No MSAA, no stencil, no blending hardware.** Alpha is a value in a packed word, not a fixed
  function; any blending is rasteriser code.
