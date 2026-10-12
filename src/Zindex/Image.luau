--!strict
--[[
	Image - the Z32 program image (docs/02-memory-and-devices.md section 6).

	One buffer. Header, code, then initial data. No claim is made about where an
	image is stored; that is the host's problem, not the architecture's.

	+0x00  magic, the four bytes Z 3 2 0
	+0x04  entry PC
	+0x08  RAM size
	+0x0C  device profile id
	+0x10  code size
	+0x14  code load address
	+0x18  code bytes
	...    initial data bytes
]]

local Image = {}

Image.MAGIC = 0x0032335A
Image.HEADER_SIZE = 0x18

export type Program = {
	entry: number,
	ramSize: number,
	profile: number,
	codeAddress: number,
	code: buffer,
	data: buffer,
	dataAddress: number,
}

export type Options = {
	entry: number,
	code: buffer,
	codeAddress: number?,
	ramSize: number?,
	profile: number?,
	data: buffer?,
}

function Image.pack(options: Options): buffer
	local codeSize = buffer.len(options.code)
	local data = options.data
	local dataSize = if data ~= nil then buffer.len(data) else 0
	local out = buffer.create(Image.HEADER_SIZE + codeSize + dataSize)
	buffer.writeu32(out, 0x00, Image.MAGIC)
	buffer.writeu32(out, 0x04, options.entry)
	buffer.writeu32(out, 0x08, options.ramSize or 0)
	buffer.writeu32(out, 0x0C, options.profile or 0)
	buffer.writeu32(out, 0x10, codeSize)
	buffer.writeu32(out, 0x14, options.codeAddress or 0)
	buffer.copy(out, Image.HEADER_SIZE, options.code)
	if data ~= nil and dataSize > 0 then
		buffer.copy(out, Image.HEADER_SIZE + codeSize, data)
	end
	return out
end

function Image.isImage(blob: buffer): boolean
	if buffer.len(blob) < Image.HEADER_SIZE then
		return false
	end
	return buffer.readu32(blob, 0x00) == Image.MAGIC
end

function Image.unpack(blob: buffer): Program
	if not Image.isImage(blob) then
		error('image: bad magic', 0)
	end
	local blobSize = buffer.len(blob)
	local codeSize = buffer.readu32(blob, 0x10)
	local codeAddress = buffer.readu32(blob, 0x14)
	local ramSize = buffer.readu32(blob, 0x08)
	local entry = buffer.readu32(blob, 0x04)
	local available = blobSize - Image.HEADER_SIZE
	if codeSize > available then
		error('image: truncated code section', 0)
	end
	local dataSize = available - codeSize
	local dataAddress = codeAddress + codeSize
	if codeSize > 4294967296 - codeAddress or dataSize > 4294967296 - dataAddress then
		error('image: address range overflows the 32-bit address space', 0)
	end
	if ramSize > 0 and (dataAddress + dataSize > ramSize or entry >= ramSize) then
		error('image: segment or entry point exceeds declared RAM', 0)
	end

	local code = buffer.create(codeSize)
	buffer.copy(code, 0, blob, Image.HEADER_SIZE, codeSize)
	local data = buffer.create(dataSize)
	if dataSize > 0 then
		buffer.copy(data, 0, blob, Image.HEADER_SIZE + codeSize, dataSize)
	end
	return {
		entry = entry,
		ramSize = ramSize,
		profile = buffer.readu32(blob, 0x0C),
		codeAddress = codeAddress,
		code = code,
		data = data,
		dataAddress = dataAddress,
	}
end

return Image
