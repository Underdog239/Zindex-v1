# Zindex-32 (Z32)

A **virtual chip architecture** designed for Luau - an ISA built *for* Roblox's substrate instead
of borrowed from someone else's silicon, plus the heterogeneous SoC that surrounds it: Z-CPU
cores, an **Avalon R1** software rasteriser as the GPU, and a **Z-NPU** vector/tensor unit.

This repository currently contains **the architecture specification only**.
No execution engine, no emulator, no guest software.

## Documents

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

## One-paragraph summary

Roblox cannot give you more RAM, more storage, a GPU, or a client-side JIT. Those walls are
permanent. Zindex is designed around them instead of against them: 32-bit words because Luau
numbers are doubles, byte-aligned instruction encoding because `bit32` is a library of function
calls, machine state in `buffer`s rather than tables, a float unit that literally *is* Luau's
natively accelerated `vector` maths, a cycle-budget scheduler that cannot trip the watchdog, and
deterministic execution so save states and replay are exact. The result is a machine that wastes
none of the headroom that actually exists.
