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

| Command | Args | Effect |
| --- | --- | --- |
| `SET_CAMERA` | view-proj matrix address, near | set clip state |
| `CLEAR` | r, g, b, a | fill colour, clear depth to 0 |
| `SET_TILE` | x, y, w, h | restrict raster to a tile rectangle |
| `DRAW_MESH` | mesh address, triangle count, matrix address, shading mode, texture address | enqueue a mesh draw |
| `COMPOSITE` | source tile address, framebuffer address, rect | bulk copy a finished tile |
| `PRESENT` | - | request this frame's single upload |

`DRAW_MESH` is the only command the CPU issues per object; everything else is per frame.

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
