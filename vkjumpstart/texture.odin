package ns_vkjumpstart_vkjs

import "core:log"
import "core:fmt"
import "core:mem"
import "core:slice"

import vk "vendor:vulkan"

Texture :: struct {
	// Metadata
	using extent: vk.Extent3D, // has 'width', 'height' and 'depth'
	format: vk.Format,
	mip_levels: u32,
	array_layers: u32,
	samples: vk.SampleCountFlags,
	usage: vk.ImageUsageFlags,

	// Data
	image: vk.Image,
	memory: vk.DeviceMemory,
	/*
		 The `views` member only exists as a convenience.
		 No "vkjumpstart" procedure will populate it.
		 However, some "vkjumpstart" procedures will do extra things if it is populated.
		 For example, `texture_destroy` will destroy the `views`
	*/
	views: []vk.ImageView,
}

@(require_results)
texture_create :: proc
(
	device: vk.Device,
	physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties, 
	image_create_info: vk.ImageCreateInfo,
	image_view_create_infos: []vk.ImageViewCreateInfo = nil,
	image_views_out: []vk.ImageView = nil,
) -> (
	texture: Texture,
	ok: bool,
) #optional_ok
{
	assert(device != nil)

	// Copy Metadata
	texture.extent = image_create_info.extent
	texture.format = image_create_info.format
	texture.mip_levels = image_create_info.mipLevels
	texture.array_layers = image_create_info.arrayLayers
	texture.samples = image_create_info.samples
	texture.usage = image_create_info.usage

	// Create the image
	image_create_info := image_create_info
	image_create_info.sType = .IMAGE_CREATE_INFO // Don't need to set yourself :)
	check_result(vk.CreateImage(device, &image_create_info, nil, &texture.image), "Unable to create image for texture! [" + #procedure + "]", panics = false) or_return

	// Allocate memory for image
	memory_requirements: vk.MemoryRequirements = ---
	vk.GetImageMemoryRequirements(device, texture.image, &memory_requirements)
	memory_type_index := get_memory_type_index(memory_requirements.memoryTypeBits, { .DEVICE_LOCAL }, physical_device_memory_properties)
	if memory_type_index == max(u32) {
		log.error("Failed to find valid memory heap! [" + #procedure + "]")
		return texture, false
	}

	memory_allocate_info := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = memory_requirements.size,
		memoryTypeIndex = memory_type_index,
	}
	check_result(vk.AllocateMemory(device, &memory_allocate_info, nil, &texture.memory), "Unable to allocate memory for texture! [" + #procedure + "]", panics = false) or_return

	// Bind memory to image
	check_result(vk.BindImageMemory(device, texture.image, texture.memory, memoryOffset=0), "Unable to bind memory to image for texture! [" + #procedure + "]", panics = false) or_return

	// Create views (if applicable)
	if len(image_views_out) == 0 || len(image_view_create_infos) == 0 { return texture, true }
	for &view, idx in image_views_out {
		image_view_create_info := image_view_create_infos[idx]
		image_view_create_info.sType = .IMAGE_VIEW_CREATE_INFO // Don't need to set yourself :)
		image_view_create_info.image = texture.image
		if vk.CreateImageView(device, &image_view_create_info, nil, &view) != .SUCCESS {
			log.errorf("Unable to create ImageView[%v]", idx)
			return texture, false
		}
	}

	return texture, true
}

texture_destroy :: proc(device: vk.Device, texture: Texture) {
	if texture.image != 0 {
		vk.DestroyImage(device, texture.image, nil)
	}
	if texture.memory != 0 {
		vk.FreeMemory(device, texture.memory, nil)
	}
	if texture.views != nil {
		texture_destroy_views(device, texture.views)
	}
}

texture_destroy_views :: proc(device: vk.Device, views: []vk.ImageView) {
	for view in views {
		vk.DestroyImageView(device, view, nil)
	}
}

Texture_Buffer_Transfer_Info :: struct {
	src: union {
		[]byte, // CPU-local buffer
		vk.Buffer, // Device buffer
	},
	dst: vk.Image,
	// If height or depth are zero, they will be set to one automatically
	using extent: vk.Extent3D,
	image_subresource_layers: vk.ImageSubresourceLayers,
}

/*
	 It is incumbent on the receiver of this struct to wait and free/destroy themselves
	 You may use the procedure `texture_wait_for_transfer` to handle this for you
*/

Texture_Buffer_Transfer_Result :: struct {
	fence: vk.Fence,
	command_buffer: vk.CommandBuffer,
	command_pool: vk.CommandPool,
	free_list: [dynamic]Texture_Buffer_Transfer_Buffer_Free_Member,
}

Texture_Buffer_Transfer_Buffer_Free_Member :: struct {
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
}

@(require_results)
texture_transfer_buffers_to_images :: proc
(
	device: vk.Device,
	transfer_command_pool: vk.CommandPool,
	transfer_queue: vk.Queue,
	physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,
	transfers: []Texture_Buffer_Transfer_Info,
) -> (
	result: Texture_Buffer_Transfer_Result,
	ok: bool,
) #optional_ok
{
	assert(device != nil)
	assert(transfer_command_pool != 0)
	assert(transfer_queue != nil)

	buffer_free_list := make([dynamic]Texture_Buffer_Transfer_Buffer_Free_Member, 0, len(transfers))

	transfer_command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = transfer_command_pool,
		level = .PRIMARY,
		commandBufferCount = 1,
	}
	check_result(vk.AllocateCommandBuffers(device, &transfer_command_buffer_allocate_info, &result.command_buffer), "Unable to allocate transfer command buffer!", panics = false) or_return
	result.command_pool = transfer_command_pool

	// Begin Recording Commands
	transfer_command_buffer_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = { .ONE_TIME_SUBMIT },
	}
	check_result(vk.BeginCommandBuffer(result.command_buffer, &transfer_command_buffer_begin_info), "Unable to begin recording commands for transferring buffers to images!", panics = false) or_return

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
			check_result(vk.CreateBuffer(device, &buffer_create_info, nil, &buffer), "Unable to create transfer source buffer!", panics = false) or_return

			buffer_memory_requirements: vk.MemoryRequirements = ---
			vk.GetBufferMemoryRequirements(device, buffer, &buffer_memory_requirements)
			buffer_memory_type_index := get_memory_type_index(buffer_memory_requirements.memoryTypeBits, { .HOST_VISIBLE }, physical_device_memory_properties)
			if buffer_memory_type_index == max(u32) {
				log.error("Unable to find valid transfer source buffer memory type!")
				return {}, false
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

			check_result(vk.BindBufferMemory(device, buffer, buffer_memory, 0), "Unable to bind transfer source memory to buffer!", panics = false) or_return

			buffer_ptr: rawptr = ---
			check_result(vk.MapMemory(device, buffer_memory, 0, cast(vk.DeviceSize)len(src), {}, &buffer_ptr), "Unable to map transfer source memory!", panics = false) or_return
			mem.copy_non_overlapping(buffer_ptr, raw_data(src), len(src))

			flush_memory_range := vk.MappedMemoryRange {
				sType = .MAPPED_MEMORY_RANGE,
				memory = buffer_memory,
				offset = 0,
				size = cast(vk.DeviceSize)len(src),
			}
			check_result(vk.FlushMappedMemoryRanges(device, 1, &flush_memory_range), "Unable to flush transfer source memory!", panics = false) or_return
			vk.UnmapMemory(device, buffer_memory)

			// Append to free list
			append(&buffer_free_list, Texture_Buffer_Transfer_Buffer_Free_Member { buffer, buffer_memory })

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
		vk.CmdPipelineBarrier2(result.command_buffer, &texture_barrier_dependency_info)

		// Copy buffer to image
		assert(transfer.width != 0)
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
		vk.CmdCopyBufferToImage(result.command_buffer, src_buffer, transfer.dst, .TRANSFER_DST_OPTIMAL, 1, &buffer_copy_region)

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
		vk.CmdPipelineBarrier2(result.command_buffer, &texture_barrier_dependency_info)
	}

	// Stop Recording Commands
	vk.EndCommandBuffer(result.command_buffer)

	// Submit Commands
	transfer_fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	if check_result(vk.CreateFence(device, &transfer_fence_create_info, nil, &result.fence), "Unable to create tranfer fence!", panics = false) == false {
		vk.FreeCommandBuffers(device, transfer_command_pool, 1, &result.command_buffer)
		return {}, false
	}

	transfer_submit_info := vk.SubmitInfo {
		sType = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers = &result.command_buffer,
	}
	if check_result(vk.QueueSubmit(transfer_queue, 1, &transfer_submit_info, result.fence), "Unable to submit buffer to image transfter to the queue!", panics = false) == false
	{
		vk.DestroyFence(device, result.fence, nil)
		vk.FreeCommandBuffers(device, transfer_command_pool, 1, &result.command_buffer)
		return {}, false
	}

	result.free_list = buffer_free_list
	return result, true
}

texture_wait_for_transfer :: proc
(
	device: vk.Device,
	transfer_result: Texture_Buffer_Transfer_Result,
	destroy_result := true,
) -> (
	ok: bool,
)
{
	transfer_result := transfer_result
	check_result(vk.WaitForFences(device, 1, &transfer_result.fence, true, max(u64)), "Failed to wait on texture buffer tranfer fence!", panics = false) or_return
	if destroy_result {
		texture_buffer_transfer_result_destroy(device, transfer_result)
	}
	return true
}

texture_buffer_transfer_result_destroy :: proc(device: vk.Device, transfer_result: Texture_Buffer_Transfer_Result) {
	vk.DeviceWaitIdle(device)
	transfer_result := transfer_result
	vk.DestroyFence(device, transfer_result.fence, nil)
	vk.FreeCommandBuffers(device, transfer_result.command_pool, 1, &transfer_result.command_buffer)
	for member in transfer_result.free_list {
		vk.DestroyBuffer(device, member.buffer, nil)
		vk.FreeMemory(device, member.memory, nil)
	}
	delete(transfer_result.free_list)
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
	descriptor_set_init_views: []vk.ImageView = {}
) -> (
	descriptor_set: vk.DescriptorSet,
	ok: bool
) #optional_ok
{
	texture_descriptor_pool := texture_descriptor_pool // For taking address of

	descriptor_alloc_count := descriptor_alloc_count
	descriptor_alloc_count = max(descriptor_alloc_count, cast(u32)len(descriptor_set_init_views))

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

	if len(descriptor_set_init_views) > 0 {
		texture_update_descriptor_set(device, descriptor_set, descriptor_set_init_views)
	}

	return descriptor_set, true
}

texture_update_descriptor_set :: proc
(
	device: vk.Device,
	descriptor_set: vk.DescriptorSet,
	views: []vk.ImageView,
	#any_int array_offset := u32(0)
)
{
	texture_infos := make([]vk.DescriptorImageInfo, len(views))
	defer delete(texture_infos)

	for i in 0..<len(views) {
		texture_infos[i] = vk.DescriptorImageInfo {
			imageView = views[i],
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
	}

	write_descriptor_sets := [?]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = descriptor_set,
			dstBinding = 0,
			dstArrayElement = array_offset,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = cast(u32)len(texture_infos),
			pImageInfo = raw_data(texture_infos),
		},
	}

	vk.UpdateDescriptorSets(device, len(write_descriptor_sets), raw_data(&write_descriptor_sets), 0, nil)
}
