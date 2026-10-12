# 01 - Instruction Set Architecture

## 1. Machine summary

- 32-bit word, byte-addressed, little-endian.
- 32 general-purpose registers, 32 bits each.
- 8 vector registers, each 3 x float32 (a Luau `vector`).
- Flat 32-bit address space (doc 02).
- Variable-length, byte-aligned instruction encoding, 1-6 bytes.
- Flagless: conditional branches compare registers directly.
- Interrupts via a pending mask checked at instruction boundaries.

## 2. Register file

| Register | Role |
| --- | --- |
| R0 | hardwired zero; writes are discarded |
| R1-R8 | arguments (R1-R2 also return values) |
| R9-R15 | caller-saved temporaries |
| R16-R28 | callee-saved |
| R29 | FP, frame pointer |
| R30 | SP, stack pointer |
| R31 | RA, return address |

Core state outside the file: PC, cycle counter, interrupt-pending word, trap reason. These are
core state, not addressable registers, so no instruction can alias them.

R0 = zero costs one comparison on each register-writing instruction and removes a whole class
of instructions (move-immediate is `ADDI rd, R0, imm`). That is a good trade.

V0-V7 hold 3-component float32 vectors. Host vectors are immutable, so there is no
write-single-component instruction; that is a property of the architecture, not a gap.

## 3. Encoding

Every operand begins on a byte boundary. Decoding is therefore a sequence of buffer reads and
never a shift-and-mask. This is the single most Luau-driven decision in Zindex: `bit32` calls
are function calls, so a bit-packed encoding would tax every instruction executed.

| Form | Layout | Bytes | Used by |
| --- | --- | --- | --- |
| F1 | op | 1 | NOP, HALT, ECALL, EBREAK, YIELD, SYNC |
| F2 | op rd rs rt | 4 | register-register ALU |
| F3 | op rd rs imm8 | 4 | register-immediate ALU, load/store base+disp |
| F4 | op rd imm32 | 6 | LI, JMP, JAL |
| F5 | op rs rt imm16 | 5 | conditional branches |
| F6 | op vd vs vt | 4 | VFU register-register |
| F7 | op vd rs imm8 | 4 | VFU load/store |

Register fields are single bytes (0-31). imm8 is sign-extended where arithmetic. Branch imm16
is a signed byte offset relative to the address of the branch instruction itself.

Word (LW/SW) addresses must be 4-byte aligned. Byte and half accesses may be unaligned.

## 4. Opcode map

| Opcode | Mnemonic | Form | Meaning |
| --- | --- | --- | --- |
| 0x00 | NOP | F1 | no operation |
| 0x10 | ADD | F2 | rd = rs + rt |
| 0x11 | SUB | F2 | rd = rs - rt |
| 0x12 | MUL | F2 | rd = rs * rt |
| 0x13 | DIV | F2 | rd = floor(rs / rt) |
| 0x14 | REM | F2 | rd = rs % rt |
| 0x15 | AND | F2 | bitwise and |
| 0x16 | OR | F2 | bitwise or |
| 0x17 | XOR | F2 | bitwise xor |
| 0x18 | SHL | F2 | shift left |
| 0x19 | SHR | F2 | logical shift right |
| 0x1A | SAR | F2 | arithmetic shift right |
| 0x1B | NOT | F2 | bitwise not (rt ignored) |
| 0x1C | SLT | F2 | rd = (rs < rt) signed |
| 0x1D | SLTU | F2 | rd = (rs < rt) unsigned |
| 0x1E | SEQ | F2 | rd = (rs == rt) |
| 0x1F | SNE | F2 | rd = (rs ~= rt) |
| 0x20 | ADDI | F3 | rd = rs + imm8 |
| 0x21 | ANDI | F3 | rd = rs and imm8 |
| 0x22 | ORI | F3 | rd = rs or imm8 |
| 0x23 | XORI | F3 | rd = rs xor imm8 |
| 0x24 | SHLI | F3 | rd = rs << imm8 |
| 0x25 | SHRI | F3 | rd = rs >> imm8 |
| 0x26 | MULI | F3 | rd = rs * imm8 |
| 0x28 | LI | F4 | rd = imm32 |
| 0x30 | LB | F3 | rd = sign-extended byte at [rs+imm8] |
| 0x31 | LBU | F3 | rd = zero-extended byte at [rs+imm8] |
| 0x32 | LH | F3 | rd = sign-extended half at [rs+imm8] |
| 0x33 | LHU | F3 | rd = zero-extended half at [rs+imm8] |
| 0x34 | LW | F3 | rd = word at [rs+imm8] |
| 0x35 | LWS | F3 | rd = shared word at index (rs + imm8) |
| 0x38 | SB | F3 | byte at [rs+imm8] = rt |
| 0x39 | SH | F3 | half at [rs+imm8] = rt |
| 0x3A | SW | F3 | word at [rs+imm8] = rt |
| 0x3B | SWS | F3 | shared word at index (rs + imm8) = rt |
| 0x3C | AMOADD | F2 | rd = shared[rs]; shared[rs] = (rd + rt) mod 2^32 |
| 0x40 | BEQ | F5 | branch if rs == rt |
| 0x41 | BNE | F5 | branch if rs ~= rt |
| 0x42 | BLT | F5 | branch if rs < rt (signed) |
| 0x43 | BGE | F5 | branch if rs >= rt (signed) |
| 0x44 | BLTU | F5 | branch if rs < rt (unsigned) |
| 0x45 | BGEU | F5 | branch if rs >= rt (unsigned) |
| 0x46 | JMP | F4 | PC = imm32 |
| 0x47 | JAL | F4 | rd = PC+6; PC = imm32 |
| 0x48 | JALR | F3 | rd = PC+4; PC = rs + imm8 |
| 0x50 | ECALL | F1 | host trap (reason in R1, args R2-R8) |
| 0x51 | EBREAK | F1 | debugger breakpoint |
| 0x52 | HALT | F1 | stop the core |
| 0x53 | YIELD | F1 | return control to the scheduler |
| 0x54 | SYNC | F1 | multi-core fence / barrier |
| 0x60 | VLW | F7 | vd = 3 floats at [rs+imm8] |
| 0x61 | VSW | F7 | 3 floats at [rs+imm8] = vd |
| 0x62 | VADD | F6 | vd = vs + vt |
| 0x63 | VSUB | F6 | vd = vs - vt |
| 0x64 | VMUL | F6 | vd = vs * vt |
| 0x65 | VDOT / VDP3 | F2 | rd = dot(vs, vt) as float bits |
| 0x66 | VLEN | F2 | rd = length(vs) as float bits |
| 0x67 | VNRM | F6 | vd = normalize(vs) |
| 0x68 | VCST | F3 | vd = constant imm8 (0 = zero, 1 = one) |
| 0x69 | VFMA | F6 | vd = vs * vt + vd |
| 0x6A | VRED | F2 | rd = vs.x + vs.y + vs.z as float bits |
| 0x6B | VSCL | F2 | vd = vs * f32(rt) |
| 0x6C | VMIN | F6 | vd = min(vs, vt) component-wise |
| 0x6D | VMAX | F6 | vd = max(vs, vt) component-wise |

## 5. Semantics

- Arithmetic is 32-bit two's complement. Registers hold unsigned values 0..2^32-1; results are
  reduced modulo 2^32. Signed comparison converts by subtracting 2^32 when the top bit is set.
- DIV and REM treat their operands as **unsigned** 32-bit values. Signed division is a short
  sign-fixup sequence, which is cheaper than a second opcode. Division by zero yields 0:
  defined, no trap, so the hot path stays branch-free and deterministic.
- Shifts of 32 or more yield 0 (SAR sign-fills). Shifts are the documented slow path; compilers
  should strength-reduce constant shifts to MUL/DIV by powers of two.
- LBU/LHU zero-extend; LB/LH sign-extend to 32 bits.
- Load and store displacements are **signed** 8-bit, so `[FP-4]` and friends work.
- `ADDI` takes a signed immediate; `ANDI`/`ORI`/`XORI`/`MULI` and shift counts take an
  unsigned one.
- There are no condition codes. Compare-and-branch is one instruction, which removes an entire
  class of dependency stalls and makes the ISA trivially serializable.

## 6. Vector/Float Unit (VFU)

The VFU is where Zindex does something no classic ISA can. Its registers are Luau `vector`
values and its arithmetic *is* Luau's natively accelerated vector math, so one VADD is one host
operation across three float32 lanes.

V0-V7 hold 3 x float32. VLW/VSW move three consecutive floats to and from memory.
VADD/VSUB/VMUL are component-wise. VDOT reduces to a scalar in a GPR. VLEN gives magnitude,
VNRM normalizes, VCST loads a constant.

Intended use: geometry, transforms, physics, DSP-style synthesis - anything with 3-wide float
work. It is **not** an integer SIMD unit: host vectors are float32, so integer packing is not
available, and Zindex does not pretend otherwise.

## 7. ABI

- Arguments: R1-R8. Return values: R1-R2.
- Caller-saved: R1-R15. Callee-saved: R16-R28.
- Stack grows down from the top of RAM. SP points at the last used word and is 16-byte aligned
  at call boundaries (keeps vector stores aligned).
- Frame: [FP-4] saved RA, [FP-8] saved FP, spilled arguments above.
- ECALL raises a host trap with a reason code in R1 and arguments in R2-R8; the host returns
  values in R1-R2.
- YIELD asks the scheduler to suspend the core. SYNC is the multi-core barrier and atomic fence.
