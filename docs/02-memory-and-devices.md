# 02 - Memory and Devices

## 1. Address space

Flat, byte-addressed, 32-bit. One address space, one address type. No segmentation, no paging,
no MMU: an MMU would cost instructions on every access and buy nothing here.

Default profile:

| Range | Region |
| --- | --- |
| 0x0000_0000 - 0x03FF_FFFF | RAM (up to 64 MiB; recommended 1-16 MiB) |
| 0x0400_0000 - 0x0EFF_FFFF | reserved |
| 0x0F00_0000 - 0x0FFF_FFFF | device window (16 MiB, 4 KiB per device page) |
| 0xFF00_0000 - 0xFFFF_FFFF | reserved trap page |

RAM is a single `buffer`. Code, data, stack and heap all live in it (von Neumann). Every
multi-byte RAM access must fit wholly inside RAM; crossing or unmapped accesses return zero on reads,
discard writes, and increment the memory fault counter instead of throwing a host buffer error.
If supplied, `Zindex.new({ onMemoryTrap = fn })` is called for each such access as
`fn(chip, coreOrNil, reason, address)`; this is separate from `onTrap`, the ECALL host-call
handler. `reason` is `Zindex.Memory.FAULT.INVALID_ACCESS`. This includes addresses outside RAM,
missing device pages, and unsupported MMIO access widths. Without a callback, the safe
zero/discard behavior still applies.

The code region is write-protected *by convention*, not by hardware. A write into the code
region must invalidate any compiled blocks covering that address (doc 03). Self-modifying code
is legal.

## 2. Device window

Devices are memory-mapped. Each device owns a 4 KiB page. The window is the architecture's only
I/O mechanism, and it is deliberately narrow: everything the host must do is reachable through
a handful of registers.

| Page | Device | Purpose |
| --- | --- | --- |
| 0x0F000000 | DEV | device table base, pending interrupt mask |
| 0x0F001000 | TIMER | free-running cycle counter, compare, reload |
| 0x0F002000 | INPUT | buttons, pointer, axes snapshot |
| 0x0F003000 | AUDIO | ring buffer descriptor (base, length, read/write cursors) |
| 0x0F004000 | IPC | shared-region descriptor, core id, atomics |
| 0x0F005000 | FB | framebuffer descriptor |
| 0x0F006000 | GPU | Avalon R1 graphics command queue and registers |
| 0x0F007000 | NPU | Z-NPU tensor / vector / DMA command queue and registers |
| 0x0F008000+ | user | reserved for future devices |

Reading a device register is an ordinary LW. There is no separate I/O instruction class, so
there is no second decode path to maintain. The AUDIO ring length is capped at the number of
float32 samples that fit in RAM, and the host returns at most 4096 samples per `pullAudio()` call.

## 3. Framebuffer device

The FB page holds a descriptor, not pixels:

| Offset | Field |
| --- | --- |
| +0x00 | width |
| +0x04 | height |
| +0x08 | format (0 = RGBA8, 1 = RGB332, 2 = indexed8 + palette) |
| +0x0C | back buffer address in RAM |
| +0x10 | front buffer address (read-only to the guest) |
| +0x14 | dirty rect x |
| +0x18 | dirty rect y |
| +0x1C | dirty rect width |
| +0x20 | dirty rect height |
| +0x24 | present flag (write 1 to request a present) |

The guest draws into the back buffer. Once per host frame the host copies the back buffer into a
displayed `EditableImage` and swaps. This is designed around the hard rule that only one
displayed EditableImage can be updated per frame: one blit per frame, partial-region updates
driven by the dirty rect, never per-pixel host calls.

## 4. Interrupts

A pending-interrupt word lives at the DEV page. The core checks it at instruction boundaries
every K instructions (K is a core constant, default 256) and at block ends. Keeping the check
out of the per-instruction path is what lets the hot loop stay clean and native-compilable.

## 5. Multi-core and shared memory

The only genuinely extra resource in the host is parallel execution (Actors). Zindex designs for
it, and is honest about the cost.

The problem: `buffer` cannot be shared between Actors, and shared mutable Lua objects do not
exist between Actors. Therefore shared RAM cannot be a buffer.

The design:

- Each core has a private RAM `buffer`. Fast, dense, native-friendly.
- The shared region is a `SharedTable`, word-addressed: shared word `r` is `SharedTable[r]`,
  holding a number that is exactly a uint32.
- Shared access is explicit: LWS/SWS opcodes address the shared region through the IPC
  descriptor. They are not as fast as LW/SW, and the ISA says so rather than hiding it.
- Atomic operations map onto `SharedTable.increment` and `SharedTable.update`, both atomic.
- SYNC is the fence and barrier.
- Message passing with cloned buffers is the alternative transport. It copies; it does not share.

Rule of thumb, stated in the ISA so compilers can follow it: keep hot state private per core,
share rarely and in word-sized units, and synchronize with atomics rather than with hope.

## 6. Program image

A Zindex program image is one buffer:

| Offset | Field |
| --- | --- |
| +0x00 | magic, ASCII Z32 |
| +0x04 | entry PC |
| +0x08 | RAM size |
| +0x0C | device profile id |
| +0x10 | code size |
| +0x14 | code load address |
| +0x18 | code bytes |
| ... | initial data bytes |

The unpacker verifies that the declared code section fits in the supplied buffer, that segment
address arithmetic does not wrap the 32-bit address space, and (when `ramSize` is nonzero) that
segments and the entry fit in the declared RAM. `chip:loadImage()` additionally verifies all
segments against the actual chip RAM before copying any bytes. An empty data section stays empty.

No claim is made about where images are stored. Persistence is a host concern, and the host's
options are limited (doc 04). Zindex defines the image, not the shelf.
