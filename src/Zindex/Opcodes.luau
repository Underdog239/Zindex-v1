--!strict
--[[
	Opcodes - the Z32 instruction set, as data.

	One source of truth for opcode numbers, names and encoding forms, shared by
	the assembler and the core so the two can never drift apart.

	Forms:
		F1  op                       1 byte
		F2  op rd rs rt              4 bytes
		F3  op rd rs imm8            4 bytes
		F4  op rd imm32              6 bytes
		F5  op rs rt imm16           5 bytes
		F6  op vd vs vt              4 bytes
		F7  op vd rs imm8            4 bytes
]]

export type Form = 'F1' | 'F2' | 'F3' | 'F4' | 'F5' | 'F6' | 'F7'

export type Info = {
	name: string,
	op: number,
	form: Form,
}

local defs = {
	{ 'NOP', 0x00, 'F1' },

	{ 'ADD', 0x10, 'F2' },
	{ 'SUB', 0x11, 'F2' },
	{ 'MUL', 0x12, 'F2' },
	{ 'DIV', 0x13, 'F2' },
	{ 'REM', 0x14, 'F2' },
	{ 'AND', 0x15, 'F2' },
	{ 'OR', 0x16, 'F2' },
	{ 'XOR', 0x17, 'F2' },
	{ 'SHL', 0x18, 'F2' },
	{ 'SHR', 0x19, 'F2' },
	{ 'SAR', 0x1A, 'F2' },
	{ 'NOT', 0x1B, 'F2' },
	{ 'SLT', 0x1C, 'F2' },
	{ 'SLTU', 0x1D, 'F2' },
	{ 'SEQ', 0x1E, 'F2' },
	{ 'SNE', 0x1F, 'F2' },

	{ 'ADDI', 0x20, 'F3' },
	{ 'ANDI', 0x21, 'F3' },
	{ 'ORI', 0x22, 'F3' },
	{ 'XORI', 0x23, 'F3' },
	{ 'SHLI', 0x24, 'F3' },
	{ 'SHRI', 0x25, 'F3' },
	{ 'MULI', 0x26, 'F3' },
	{ 'LI', 0x28, 'F4' },

	{ 'LB', 0x30, 'F3' },
	{ 'LBU', 0x31, 'F3' },
	{ 'LH', 0x32, 'F3' },
	{ 'LHU', 0x33, 'F3' },
	{ 'LW', 0x34, 'F3' },
	{ 'LWS', 0x35, 'F3' },
	{ 'SB', 0x38, 'F3' },
	{ 'SH', 0x39, 'F3' },
	{ 'SW', 0x3A, 'F3' },
	{ 'SWS', 0x3B, 'F3' },
	{ 'AMOADD', 0x3C, 'F2' },

	{ 'BEQ', 0x40, 'F5' },
	{ 'BNE', 0x41, 'F5' },
	{ 'BLT', 0x42, 'F5' },
	{ 'BGE', 0x43, 'F5' },
	{ 'BLTU', 0x44, 'F5' },
	{ 'BGEU', 0x45, 'F5' },
	{ 'JMP', 0x46, 'F4' },
	{ 'JAL', 0x47, 'F4' },
	{ 'JALR', 0x48, 'F3' },

	{ 'ECALL', 0x50, 'F1' },
	{ 'EBREAK', 0x51, 'F1' },
	{ 'HALT', 0x52, 'F1' },
	{ 'YIELD', 0x53, 'F1' },
	{ 'SYNC', 0x54, 'F1' },

	{ 'VLW', 0x60, 'F7' },
	{ 'VSW', 0x61, 'F7' },
	{ 'VADD', 0x62, 'F6' },
	{ 'VSUB', 0x63, 'F6' },
	{ 'VMUL', 0x64, 'F6' },
	{ 'VDOT', 0x65, 'F2' },
	{ 'VLEN', 0x66, 'F2' },
	{ 'VNRM', 0x67, 'F6' },
	{ 'VCST', 0x68, 'F3' },
	{ 'VFMA', 0x69, 'F6' },
	{ 'VRED', 0x6A, 'F2' },
	{ 'VSCL', 0x6B, 'F2' },
	{ 'VMIN', 0x6C, 'F6' },
	{ 'VMAX', 0x6D, 'F6' },
}

local Opcodes = {
	info = {} :: { [number]: Info },
	byName = {} :: { [string]: Info },
	sizes = {
		F1 = 1,
		F2 = 4,
		F3 = 4,
		F4 = 6,
		F5 = 5,
		F6 = 4,
		F7 = 4,
	} :: { [Form]: number },
}

for _, d in defs do
	local entry: Info = { name = d[1] :: string, op = d[2] :: number, form = d[3] :: Form }
	Opcodes.info[entry.op] = entry
	Opcodes.byName[entry.name] = entry
end

-- Z-NPU alias for 3-lane dot product (docs/07-npu.md).
Opcodes.byName.VDP3 = Opcodes.byName.VDOT

--- Byte size of an instruction given its opcode.
function Opcodes.sizeOf(op: number): number
	local entry = Opcodes.info[op]
	if entry == nil then
		return 1
	end
	return Opcodes.sizes[entry.form]
end

return Opcodes
