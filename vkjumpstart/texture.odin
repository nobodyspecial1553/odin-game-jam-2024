package ns_vkjumpstart_vkjs

import "core:log"
import "core:fmt"
import "core:mem"
import "core:image/png"
import "core:image"

import vk "vendor:vulkan"

Texture_Channels :: enum i8 {
	Invalid = 0,
	R = 1,
	RG = 2,
	RGB = 3,
	RGBA = 4,
}

Texture :: struct {
	width: u32,
	height: u32,
	depth: u32,
	mip_levels: u32,
	array_layers: u32,
	channels: Texture_Channels,

	image: vk.Image,
	view: vk.ImageView, // Default view that matches the image
	memory: vk.DeviceMemory,
}

Texture_Transfer_Info :: struct {
	src: union {
		[]byte, // CPU-local buffer
		vk.Buffer, // Device buffer (Host-Visible in most cases)
	},
	dst: vk.Image,
	width: u32,
	height: u32, // If zero, will be set to 1
	depth: u32, // If zero, will be set to 1
	image_subresource_layers: vk.ImageSubresourceLayers,
}

texture_transfer_buffers_to_images :: proc
(
	device: vk.Device,
	transfer_command_pool: vk.CommandPool,
	transfer_queue: vk.Queue,
	physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,
	transfers: []Texture_Transfer_Info
)
{
	assert(device != nil)
	assert(transfer_command_pool != 0)
	assert(transfer_queue != nil)

	Buffer_Free_Member :: struct {
		buffer: vk.Buffer,
		memory: vk.DeviceMemory,
	}
	buffer_free_list := make([dynamic]Buffer_Free_Member, 0, len(transfers))

	transfer_fence: vk.Fence = ---
	transfer_fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	check_result(vk.CreateFence(device, &transfer_fence_create_info, nil, &transfer_fence), "Unable to create tranfer fence!")

	transfer_command_buffer: vk.CommandBuffer = ---
	transfer_command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = transfer_command_pool,
		level = .PRIMARY,
		commandBufferCount = 1,
	}
	check_result(vk.AllocateCommandBuffers(device, &transfer_command_buffer_allocate_info, &transfer_command_buffer), "Unable to allocate transfer command buffer!")

	// Begin Recording Commands
	transfer_command_buffer_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = { .ONE_TIME_SUBMIT },
	}
	check_result(vk.BeginCommandBuffer(transfer_command_buffer, &transfer_command_buffer_begin_info), "Unable to begin recording commands for transferring buffers to images!")

	// Copy Buffers to Images
	for transfer in transfers {
		src_buffer: vk.Buffer = ---

		// Get source buffer
		switch src in transfer.src {
		case []byte: // Copy cpu-buffer to gpu-buffer
			buffer: vk.Buffer = ---
			buffer_create_info := vk.BufferCreateInfo {
				sType = .BUFFER_CREATE_INFO,
				size = cast(vk.DeviceSize)len(src),
				usage = { .TRANSFER_SRC },
				sharingMode = .EXCLUSIVE,
			}
			check_result(vk.CreateBuffer(device, &buffer_create_info, nil, &buffer), "Unable to create transfer source buffer!")

			buffer_memory_requirements: vk.MemoryRequirements = ---
			vk.GetBufferMemoryRequirements(device, buffer, &buffer_memory_requirements)
			buffer_memory_type_index := get_memory_type_index(buffer_memory_requirements.memoryTypeBits, { .HOST_VISIBLE }, physical_device_memory_properties)
			if buffer_memory_type_index == max(u32) {
				log.fatal("Unable to find valid transfer source buffer memory type!")
			}

			/*
				 We COULD aggregate all these allocations into ONE allocation
				 That would be a more complicated task with these interweaved cpu and gpu buffers
				 It would require having an array of offsets for binding/mapping
				 You would also need to track just how many cpu-buffers you've iterated over
				 It's something to consider for another time
			*/
			buffer_memory: vk.DeviceMemory = ---
			buffer_memory_allocate_info := vk.MemoryAllocateInfo {
				sType = .MEMORY_ALLOCATE_INFO,
				allocationSize = buffer_memory_requirements.size,
				memoryTypeIndex = buffer_memory_type_index,
			}
			vk.AllocateMemory(device, &buffer_memory_allocate_info, nil, &buffer_memory)

			check_result(vk.BindBufferMemory(device, buffer, buffer_memory, 0), "Unable to bind transfer source memory to buffer!")

			buffer_ptr: rawptr = ---
			check_result(vk.MapMemory(device, buffer_memory, 0, cast(vk.DeviceSize)len(src), {}, &buffer_ptr), "Unable to map transfer source memory!")
			mem.copy_non_overlapping(buffer_ptr, raw_data(src), len(src))

			flush_memory_range := vk.MappedMemoryRange {
				sType = .MAPPED_MEMORY_RANGE,
				memory = buffer_memory,
				offset = 0,
				size = cast(vk.DeviceSize)len(src),
			}
			check_result(vk.FlushMappedMemoryRanges(device, 1, &flush_memory_range), "Unable to flush transfer source memory!")
			vk.UnmapMemory(device, buffer_memory)

			// Append to free list
			append(&buffer_free_list, Buffer_Free_Member { buffer, buffer_memory })

			src_buffer = buffer
		case vk.Buffer:
			src_buffer = src
		}

		// Transition image to TRANSITION_DST_OPTIMAL
		texture_image_memory_barrier := vk.ImageMemoryBarrier2 {
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = { .TOP_OF_PIPE },
			srcAccessMask = {},
			dstStageMask = { .TRANSFER },
			dstAccessMask = { .TRANSFER_WRITE },
			oldLayout = .UNDEFINED,
			newLayout = .TRANSFER_DST_OPTIMAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = transfer.dst,
			subresourceRange = {
				aspectMask = transfer.image_subresource_layers.aspectMask,
				baseMipLevel = transfer.image_subresource_layers.mipLevel,
				levelCount = 1,
				baseArrayLayer = transfer.image_subresource_layers.baseArrayLayer,
				layerCount = transfer.image_subresource_layers.layerCount,
			},
		}
		texture_barrier_dependency_info := vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers = &texture_image_memory_barrier,
		}
		vk.CmdPipelineBarrier2(transfer_command_buffer, &texture_barrier_dependency_info)

		// Copy buffer to image
		copy_width := transfer.width
		copy_height := max(1, transfer.height)
		copy_depth := max(1, transfer.depth)
		buffer_copy_region := vk.BufferImageCopy {
			imageSubresource = transfer.image_subresource_layers,
			imageExtent = { copy_width, copy_height, copy_depth },
		}
		/*
			 TODO:
			 If images need to copy more than one thing from 'image_subresource_layers.aspectMask'
			 then it needs to handle that case!
			 This procedure is broken right now as-is!
		*/
		vk.CmdCopyBufferToImage(transfer_command_buffer, src_buffer, transfer.dst, .TRANSFER_DST_OPTIMAL, 1, &buffer_copy_region)

		// Transition image to SHADER_READ_ONLY_OPTIMAL
		texture_image_memory_barrier = vk.ImageMemoryBarrier2 {
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = { .TRANSFER },
			srcAccessMask = { .TRANSFER_WRITE },
			dstStageMask = { .ALL_TRANSFER },
			dstAccessMask = {},
			oldLayout = .TRANSFER_DST_OPTIMAL,
			newLayout = .SHADER_READ_ONLY_OPTIMAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = transfer.dst,
			subresourceRange = {
				aspectMask = transfer.image_subresource_layers.aspectMask,
				baseMipLevel = transfer.image_subresource_layers.mipLevel,
				levelCount = 1,
				baseArrayLayer = transfer.image_subresource_layers.baseArrayLayer,
				layerCount = transfer.image_subresource_layers.layerCount,
			},
		}
		vk.CmdPipelineBarrier2(transfer_command_buffer, &texture_barrier_dependency_info)
	}

	// Stop Recording Commands
	vk.EndCommandBuffer(transfer_command_buffer)

	// Submit Commands
	transfer_submit_info := vk.SubmitInfo {
		sType = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers = &transfer_command_buffer,
	}
	vk.QueueSubmit(transfer_queue, 1, &transfer_submit_info, transfer_fence)

	check_result(vk.WaitForFences(device, 1, &transfer_fence, true, max(u64)), "Unable to wait for transfer fence!")
	// Cleanup
	vk.DestroyFence(device, transfer_fence, nil)\
	vk.FreeCommandBuffers(device, transfer_command_pool, 1, &transfer_command_buffer)
	for member in buffer_free_list {
		vk.DestroyBuffer(device, member.buffer, nil) // buffer should never be zero, no need to check
		vk.FreeMemory(device, member.memory, nil) // memory should never be zero, no need to check
	}
	delete(buffer_free_list)
}

/*
	 This is a very generic, general-use procedure for creating a grayscale/colored (+alpha) image.
	 If you have more specific needs, you will need to call something else or do it manually.
*/
texture_create_from_buffer :: proc
(
	device: vk.Device,
	transfer_command_pool: vk.CommandPool,
	transfer_queue: vk.Queue,
	physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,
	buffer: []byte,
	channels: Texture_Channels,
	#any_int width: u32, #any_int height := u32(1), #any_int depth := u32(1),
	#any_int array_layers := u32(1), #any_int mip_levels := u32(1),
	usage: vk.ImageUsageFlags = {}
) -> (Texture, bool) #optional_ok
{
	assert(device != nil)
	assert(transfer_command_pool != 0)
	assert(transfer_queue != nil)
	assert(channels != .Invalid)
	assert(width > 0)
	assert(height > 0)
	assert(depth > 0)
	assert(array_layers > 0)
	assert(!(depth > 1 && array_layers > 1))
	assert(mip_levels > 0)

	texture := Texture {
		width = width,
		height = height,
		depth = depth,
		mip_levels = mip_levels,
		array_layers = array_layers,
		channels = channels,
	}

	image_type: vk.ImageType = .D1
	switch {
	case height > 1 && depth > 1: image_type = .D3
	case height > 1: image_type = .D2
	}

	// TODO: Check for format availability
	// TODO: If format unavailable, pad appropriately
	format: vk.Format = ---
	switch channels {
	case .R: format = .R8_UNORM
	case .RG: format = .R8G8_UNORM
	case .RGB: format = .R8G8B8_UNORM
	case .RGBA: format = .R8G8B8A8_UNORM
	case .Invalid: fallthrough
	case:
		log.fatal("Invalid format [" + #procedure + "]")
	}

	usage := usage + { .TRANSFER_DST, .SAMPLED }

	// Create Device-local Image
	texture_image_create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = image_type,
		format = format,
		extent = { width, height, depth },
		mipLevels = mip_levels,
		arrayLayers = array_layers,
		samples = { ._1 },
		tiling = .OPTIMAL,
		usage = usage,
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	check_result(vk.CreateImage(device, &texture_image_create_info, nil, &texture.image), "Unable to create texture handle!")

	texture_memory_requirements: vk.MemoryRequirements = ---
	vk.GetImageMemoryRequirements(device, texture.image, &texture_memory_requirements)
	texture_memory_type_index := get_memory_type_index(texture_memory_requirements.memoryTypeBits, { .DEVICE_LOCAL }, physical_device_memory_properties)
	if texture_memory_type_index == max(u32) {
		log.error("Unable to find memory type for Texture!")
		return {}, false
	}

	texture_memory_allocate_info := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = texture_memory_requirements.size,
		memoryTypeIndex = texture_memory_type_index,
	}
	check_result(vk.AllocateMemory(device, &texture_memory_allocate_info, nil, &texture.memory), "Unable to allocate memory for Texture!")

	check_result(vk.BindImageMemory(device, texture.image, texture.memory, vk.DeviceSize(0)), "Unable to bind memory to Texture!")

	view_type: vk.ImageViewType = .D1
	switch { // No Cube default
	case height > 1 && depth > 1: view_type = .D3
	case height > 1 && array_layers > 1: view_type = .D2_ARRAY
	case height > 1: view_type = .D2
	case array_layers > 1: view_type = .D1_ARRAY
	}

	texture_image_view_create_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = texture.image,
		viewType = view_type,
		format = format,
		components = { .IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY },
		subresourceRange = {
			aspectMask = { .COLOR },
			baseMipLevel = 0,
			levelCount = mip_levels,
			baseArrayLayer = 0,
			layerCount = array_layers,
		},
	}
	check_result(vk.CreateImageView(device, &texture_image_view_create_info, nil, &texture.view), "Unable to create default image view for Texture!")

	// TODO: Handle mip levels and array layers!
	texture_transfers := []Texture_Transfer_Info {
		{
			src = buffer,
			dst = texture.image,
			width = texture.width,
			height = texture.height,
			depth = texture.depth,
			image_subresource_layers = {
				aspectMask = { .COLOR },
				mipLevel = 0,
				baseArrayLayer = 0,
				layerCount = 1,
			}
		},
	}
	texture_transfer_buffers_to_images(device, transfer_command_pool, transfer_queue, physical_device_memory_properties, texture_transfers)

	return texture, true
}

/*
	 This is a very generic, general-use procedure for creating a grayscale/colored (+alpha) image.
	 If you have more specific needs, you will need to call something else or do it manually.
*/
texture_create_from_file :: proc
(
	device: vk.Device,
	transfer_command_pool: vk.CommandPool,
	transfer_queue: vk.Queue,
	physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,
	file_path: string,
	usage: vk.ImageUsageFlags = {}
) -> (Texture, bool) #optional_ok
{
	assert(device != nil)
	assert(transfer_command_pool != 0)
	assert(transfer_queue != nil)
	assert(file_path != "")

	// TODO: Write my own /* add x thing if needed */ stuff
	image_data, image_load_error := image.load_from_file(file_path, { .alpha_add_if_missing })
	if image_load_error != nil {
		log.errorf("Failed to load texture \"%s\": %v", image_load_error)
		return {}, false
	}
	defer image.destroy(image_data)
	return texture_create_from_buffer(device, transfer_command_pool, transfer_queue, physical_device_memory_properties, image_data.pixels.buf[:], cast(Texture_Channels)image_data.channels, image_data.width, image_data.height, usage=usage)
}

texture_destroy :: proc(device: vk.Device, texture: Texture) {
	if texture.view != 0 {
		vk.DestroyImageView(device, texture.view, nil)
	}
	if texture.image != 0 {
		vk.DestroyImage(device, texture.image, nil)
	}
	if texture.memory != 0 {
		vk.FreeMemory(device, texture.memory, nil)
	}
}

// For bindless textures
Texture_Descriptor_Pool :: struct {
	pool: vk.DescriptorPool,
	set_layout: vk.DescriptorSetLayout,
	/*
		 TODO:
		 - Track how many sets were allocated
		 - Track how many descriptors were allocated
	*/
}

TEXTURE_DEFAULT_MAX_ALLOCATABLE_DESCRIPTORS :: 1024 * 10
TEXTURE_DEFAULT_MAX_ALLOCATABLE_DESCRIPTOR_SETS :: 256
texture_create_descriptor_pool :: proc
(
	device: vk.Device,
	#any_int max_allocatable_descriptors := u32(TEXTURE_DEFAULT_MAX_ALLOCATABLE_DESCRIPTORS),
	#any_int max_allocatable_descriptor_sets := u32(TEXTURE_DEFAULT_MAX_ALLOCATABLE_DESCRIPTOR_SETS)
) -> (Texture_Descriptor_Pool, bool) #optional_ok
{
	texture_descriptor_pool: Texture_Descriptor_Pool

	// Descriptor Set Layout
	descriptor_set_layout_bindings := [?]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = max_allocatable_descriptors, // variable allocation
			stageFlags = { .FRAGMENT },
		},
	}

	descriptor_set_layout_binding_flags_array := [len(descriptor_set_layout_bindings)]vk.DescriptorBindingFlags {
		{ .PARTIALLY_BOUND, .UPDATE_AFTER_BIND, .VARIABLE_DESCRIPTOR_COUNT },
	}
	descriptor_set_layout_binding_flags_create_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount = len(descriptor_set_layout_binding_flags_array),
		pBindingFlags = raw_data(&descriptor_set_layout_binding_flags_array),
	}

	descriptor_set_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
		sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext = &descriptor_set_layout_binding_flags_create_info,
		flags = { .UPDATE_AFTER_BIND_POOL },
		bindingCount = len(descriptor_set_layout_bindings),
		pBindings = raw_data(&descriptor_set_layout_bindings),
	}
	check_result(vk.CreateDescriptorSetLayout(device, &descriptor_set_layout_create_info, nil, &texture_descriptor_pool.set_layout), "Unable to create Shader Terrain descriptor set layout!")

	// Descriptor Pool
	descriptor_pool_sizes := [?]vk.DescriptorPoolSize {
		{ // Textures
			type = .SAMPLED_IMAGE,
			descriptorCount = max_allocatable_descriptors,
		},
	}
	descriptor_pool_create_info := vk.DescriptorPoolCreateInfo {
		sType = .DESCRIPTOR_POOL_CREATE_INFO,
		flags = { .UPDATE_AFTER_BIND },
		maxSets = max_allocatable_descriptor_sets,
		poolSizeCount = len(descriptor_pool_sizes),
		pPoolSizes = raw_data(&descriptor_pool_sizes),
	}
	check_result(vk.CreateDescriptorPool(device, &descriptor_pool_create_info, nil, &texture_descriptor_pool.pool), "Unable to create Shader Terrain descriptor pool!")

	return texture_descriptor_pool, true
}

texture_destroy_descriptor_pool :: proc(device: vk.Device, texture_descriptor_pool: Texture_Descriptor_Pool) {
	if texture_descriptor_pool.pool != 0 {
		vk.DestroyDescriptorPool(device, texture_descriptor_pool.pool, nil)
	}
	if texture_descriptor_pool.set_layout != 0 {
		vk.DestroyDescriptorSetLayout(device, texture_descriptor_pool.set_layout, nil)
	}
}

/*
	 Can pass zero to descriptor_alloc_count if you don't need more than `descriptor_set_init_textures` allocated
*/
texture_allocate_descriptor_set :: proc
(
	device: vk.Device,
	texture_descriptor_pool: Texture_Descriptor_Pool,
	#any_int descriptor_alloc_count: u32,
	descriptor_set_init_textures: []Texture = {}
) -> (
	descriptor_set: vk.DescriptorSet,
	ok: bool
) #optional_ok
{
	texture_descriptor_pool := texture_descriptor_pool // For taking address of

	descriptor_alloc_count := descriptor_alloc_count
	descriptor_alloc_count = max(descriptor_alloc_count, cast(u32)len(descriptor_set_init_textures))

	descriptor_set_variable_descriptor_count_allocate_info := vk.DescriptorSetVariableDescriptorCountAllocateInfo {
		sType = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
		descriptorSetCount = 1,
		pDescriptorCounts = &descriptor_alloc_count,
	}
	descriptor_set_allocate_info := vk.DescriptorSetAllocateInfo {
		sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
		pNext = &descriptor_set_variable_descriptor_count_allocate_info,
		descriptorPool = texture_descriptor_pool.pool,
		descriptorSetCount = 1,
		pSetLayouts = &texture_descriptor_pool.set_layout,
	}
	check_result(vk.AllocateDescriptorSets(device, &descriptor_set_allocate_info, &descriptor_set), "Unable to allocate Texture Descriptor Set!")

	if len(descriptor_set_init_textures) > 0 {
		texture_update_descriptor_set(device, descriptor_set, descriptor_set_init_textures)
	}

	return descriptor_set, true
}

texture_update_descriptor_set :: proc
(
	device: vk.Device,
	descriptor_set: vk.DescriptorSet,
	textures: []Texture,
	#any_int texture_array_offset := u32(0)
)
{
	texture_infos := make([]vk.DescriptorImageInfo, len(textures))
	defer delete(texture_infos)

	for i in 0..<len(textures) {
		texture_infos[i] = vk.DescriptorImageInfo {
			imageView = textures[i].view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
	}

	write_descriptor_sets := [?]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = descriptor_set,
			dstBinding = 0,
			dstArrayElement = texture_array_offset,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = cast(u32)len(texture_infos),
			pImageInfo = raw_data(texture_infos),
		},
	}

	vk.UpdateDescriptorSets(device, len(write_descriptor_sets), raw_data(&write_descriptor_sets), 0, nil)
}
