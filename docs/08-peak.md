# 08 - Pushing to the ceiling

What "the absolute limit of Roblox" actually means once the walls are accepted as permanent.

## 1. The four resources, ranked by remaining headroom

| Resource | Headroom | Lever | Ceiling |
| --- | --- | --- | --- |
| CPU cycles | large | server-side native codegen, Actors, typed allocation-free loops | host instruction throughput x busy cores |
| Raster throughput | moderate | tile parallelism, adaptive resolution, edge-function inner loop | pixels per frame within budget |
| Vector throughput | moderate | native vector ops, Actor fan-out | 3-lane float32 ops/sec x busy cores |
| GPU / NPU / storage | none | nothing exists | zero |

## 2. The ceiling, stated honestly

- **A real GPU pipeline is impossible.** The best available is an Avalon-class software rasteriser
  at low internal resolution with one upload per frame.
- **A real NPU is impossible.** The best available is 3-lane float32 vector maths fanned out
  across Actors.
- **Client-side native compilation is not available yet**; server-side is. So the client peak today
  is interpreted Luau times busy cores, and the same source becomes faster for free when client
  native lands, because the cores are written native-ready from line one.
- **Memory cannot grow.** Density can, and Zindex already fixes it at 1 byte per RAM byte and
  4 bytes per register, with no GC-scanned machine state.

## 3. Why "absolute limit" means wasting nothing

None of the four walls can be broken, so the maximum is defined by subtraction: the machine that
wastes the least of the headroom that exists. That means a design with no bit-packing the host
cannot decode cheaply, no tables in hot paths, no allocations per frame, no engine API calls in
the compute path, no idle Actors, no wall-clock reads inside the core, and exactly one present
per frame.

That is the entire performance strategy, and it is a strategy that works today, at the current
ceiling, without waiting for any new API.

## 4. The four rules

1. Every buffer is a buffer. No machine state, no pixels, no mesh data in tables.
2. Every hot function is typed, allocation-free, and `@native`-ready.
3. Every unit owns its memory and transfers only tiles and results, using bulk copies.
4. Every frame has exactly one present and a measured budget per unit.

## 5. Where the remaining risk is

The unknowns that actually decide the achievable ceiling, in order of impact:

1. Whether a `buffer` can cross an Actor boundary by message (doc 06 section 4). This decides
   whether rasterisation scales with core count or stays single-Actor.
2. Whether client-side native compilation arrives. This is a constant factor on every interpreted
   instruction in the whole machine.
3. The `EditableImage` client memory budget at the target resolution. This caps internal
   resolution independently of raster speed.
4. Actor count versus core count. More Actors than cores balances load better; too many adds
   scheduling overhead.
5. `SharedTable` throughput for atomics. This decides how finely cores can cooperate.

Every one of these is measurable, and every one should be measured before the architecture
promises a number.

## 6. Non-claims, restated

Not more RAM. Not a GPU. Not a client JIT. Not a disk. Not bit-exact audio. Not faster emulation
of existing hardware.

The claim is narrower and defensible: at the present ceiling, Zindex wastes none of the headroom
that exists, and it is the only design in this space built for the host from its first
instruction.
