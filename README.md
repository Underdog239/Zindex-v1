# Zindex-32 (Z32)

A **virtual chip architecture** designed for Luau - an ISA built *for* Roblox's
substrate instead of borrowed from someone else's silicon.

This repository currently contains **the architecture specification only**.
No execution engine, no emulator, no guest software.

- [`docs/00-overview.md`](docs/00-overview.md) - why Zindex exists, design principles, scope
- [`docs/01-isa.md`](docs/01-isa.md) - registers, encoding, instruction set, vector unit, ABI
- [`docs/02-memory-and-devices.md`](docs/02-memory-and-devices.md) - address space, memory map, MMIO, multi-core sharing
- [`docs/03-execution-model.md`](docs/03-execution-model.md) - execution tiers, scheduler, timing, save states
- [`docs/04-barriers.md`](docs/04-barriers.md) - the walls Zindex is shaped around, and what it does *not* claim
