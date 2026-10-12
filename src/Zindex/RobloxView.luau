--!nonstrict
--[[
	RobloxView - the host bridge, and the only file in this library that touches
	a Roblox API.

	It owns the EditableImage, performs exactly one upload per frame (the hard
	limit documented in docs/06-gpu-avalon.md section 5), honours Avalon-style
	adaptive resolution scaling, and keeps the core engine-free so the core stays
	native-compilable and testable off-platform.

	In a published experience EditableImage fails by default: it needs 13+ age
	verification and ID verification, plus "Enable Mesh / Image APIs" switched on
	in the Creator Dashboard. That is Roblox's rule, not a limitation of Zindex.

		local view = Zindex.RobloxView.new(chip, { parent = script.Parent, width = 320, height = 240 })
		view:start(20000)   -- cycles per frame, one present per frame
]]

local RunService = game:GetService('RunService')
local AssetService = game:GetService('AssetService')

local RobloxView = {}
RobloxView.__index = RobloxView

function RobloxView.new(chip, options)
	local opts = options or {}
	local width = opts.width or chip.devices.framebuffer.width
	local height = opts.height or chip.devices.framebuffer.height
	local self = setmetatable({}, RobloxView)
	self.chip = chip
	self.parent = opts.parent
	self.adaptive = opts.adaptive ~= false
	self.width = width
	self.height = height
	self.staging = nil
	self.image = nil
	self.label = nil
	self.connection = nil
	self:_allocate(width, height)
	return self
end

function RobloxView:_allocate(width: number, height: number)
	if self.label ~= nil then
		self.label:Destroy()
	end
	if self.image ~= nil then
		self.image:Destroy()
	end
	self.width = width
	self.height = height
	self.staging = buffer.create(width * height * 4)
	self.image = AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
	self.label = Instance.new('ImageLabel')
	self.label.Name = 'ZindexFramebuffer'
	self.label.Size = UDim2.fromOffset(width, height)
	self.label.BackgroundTransparency = 1
	self.label.ImageContent = Content.fromObject(self.image)
	self.label.Parent = self.parent
end

--- Copy the guest's back buffer into the image. Exactly one upload per call.
function RobloxView:present()
	local descriptor, ram = self.chip:framebuffer()
	if descriptor.width > 0 and descriptor.height > 0 and (descriptor.width ~= self.width or descriptor.height ~= self.height) then
		self:_allocate(descriptor.width, descriptor.height)
	end
	local back = descriptor.back
	local bytes = self.width * self.height * 4
	if back <= 0 or back + bytes > buffer.len(ram) then
		return false
	end
	buffer.copy(self.staging, 0, ram, back, bytes)
	self.image:WritePixelsBuffer(Vector2.zero, Vector2.new(self.width, self.height), self.staging)
	return true
end

--- Run a cycle budget each frame, and present once when the guest asks.
function RobloxView:start(cyclesPerFrame)
	if self.connection ~= nil then
		return
	end
	self.connection = RunService.RenderStepped:Connect(function(dt)
		self.chip:run(cyclesPerFrame)
		if self.adaptive and self.chip.gpu ~= nil then
			self.chip.gpu:adapt(dt)
		end
		if self.chip.devices.framebuffer.presentRequested then
			self:present()
			self.chip.devices.framebuffer.presentRequested = false
		end
	end)
end

function RobloxView:stop()
	if self.connection ~= nil then
		self.connection:Disconnect()
		self.connection = nil
	end
end

return RobloxView
