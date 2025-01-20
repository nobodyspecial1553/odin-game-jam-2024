package ns_vkjumpstart_vkjs

@(require) import "core:fmt"
@(require) import "core:log"

import vk "vendor:vulkan"

Copy_Info_Buffer :: struct {
	buffer: vk.Buffer,
}

Copy_Info_Image :: struct {
	image: vk.Image,
	initial_layout: vk.ImageLayout,
	final_layout: vk.ImageLayout,
}

Copy_Info_Buffer_To_Buffer :: struct {
	src: Copy_Info_Buffer,
	dst: Copy_Info_Buffer,
	copy_regions: []vk.BufferCopy,
}

Copy_Info_Buffer_To_Image :: struct {
	src: Copy_Info_Buffer,
	dst: Copy_Info_Image,
	copy_regions: []vk.BufferImageCopy,
}

Copy_Info_Image_To_Buffer :: struct {
	src: Copy_Info_Image,
	dst: Copy_Info_Buffer,
	copy_regions: []vk.BufferImageCopy,
}

Copy_Info_Image_To_Image :: struct {
	src: Copy_Info_Image,
	dst: Copy_Info_Image,
	copy_regions: []vk.ImageCopy,
}

Copy_Info :: union {
	Copy_Info_Buffer_To_Buffer,
	Copy_Info_Buffer_To_Image,
	Copy_Info_Image_To_Buffer,
	Copy_Info_Image_To_Image,
}

Copy_Fence :: struct {
	fence: vk.Fence,
	command_pool: vk.CommandPool,
	command_buffer: vk.CommandBuffer,
}

/*
	 Batches together a bunch of copy commands into one submission and returns a Copy_Fence object.
	 You must wait on the fence with `copy_wait_on_fences`
	 If you set the argument `destroy_fence` in `copy_wait_on_fence` to false, you must call `copy_fence_destroy`
	 Please check 'ok' for failure. There are many failure points!
*/
@(require_results)
copy :: proc
(
	device: vk.Device,
	transfer_command_pool: vk.CommandPool,
	transfer_queue: vk.Queue,
	physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,
	copy_infos: []Copy_Info,
) -> (
	copy_fence: Copy_Fence,
	ok: bool,
)
{
	INITIAL_TEXTURE_MEMORY_BARRIER_TEMPLATE :: vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = { .TOP_OF_PIPE },
		srcAccessMask = {},
		dstStageMask = { .TRANSFER },
		dstAccessMask = { .TRANSFER_WRITE },
		oldLayout = .UNDEFINED, // Replace with initial layout
		newLayout = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = 0, // Replace with image
		subresourceRange = { // Replace
			aspectMask = {},
			baseMipLevel = 0,
			levelCount = 0,
			baseArrayLayer = 0,
			layerCount = 0,
		},
	}
	FINAL_TEXTURE_MEMORY_BARRIER_TEMPLATE :: vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = { .TRANSFER },
		srcAccessMask = { .TRANSFER_WRITE },
		dstStageMask = { .ALL_TRANSFER },
		dstAccessMask = {},
		oldLayout = .TRANSFER_DST_OPTIMAL,
		newLayout = .UNDEFINED, // Replace with final layout
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = 0, // Replace with image
		subresourceRange = { // Replace
			aspectMask = {},
			baseMipLevel = max(u32),
			levelCount = 0,
			baseArrayLayer = max(u32),
			layerCount = 0,
		},
	}

	copy_fence.command_pool = transfer_command_pool
	command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = copy_fence.command_pool,
		level = .PRIMARY,
		commandBufferCount = 1,
	}
	check_result(vk.AllocateCommandBuffers(device, &command_buffer_allocate_info, &copy_fence.command_buffer), "Failed to allocate command buffer for transfer! [" + #procedure + "]", panics = false) or_return
	command_buffer_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = { .ONE_TIME_SUBMIT },
	}
	check_result(vk.BeginCommandBuffer(copy_fence.command_buffer, &command_buffer_begin_info), "Failed to begin transfer command buffer! [" + #procedure + "]", panics = false) or_return

	image_transitions := make([dynamic]vk.ImageMemoryBarrier2, 0, len(copy_infos), context.temp_allocator)
	// Transition all images into TRANSFER_DST_OPTIMAL
	for _copy_info in copy_infos do switch copy_info in _copy_info {
	case Copy_Info_Buffer_To_Buffer:
		break
	case Copy_Info_Buffer_To_Image:
		aspect_mask: vk.ImageAspectFlags
		min_mip_level := max(u32)
		max_mip_level := u32(0)
		min_array_layer := max(u32)
		max_array_layer := u32(0)
		for copy_region in copy_info.copy_regions {
			aspect_mask |= copy_region.imageSubresource.aspectMask
			min_mip_level = min(min_mip_level, copy_region.imageSubresource.mipLevel)
			max_mip_level = max(max_mip_level, copy_region.imageSubresource.mipLevel)
			min_array_layer = min(min_array_layer, copy_region.imageSubresource.baseArrayLayer)
			max_array_layer = max(max_array_layer, copy_region.imageSubresource.baseArrayLayer + copy_region.imageSubresource.layerCount - 1)
		}
		texture_image_memory_barrier := INITIAL_TEXTURE_MEMORY_BARRIER_TEMPLATE
		texture_image_memory_barrier.image = copy_info.dst.image
		texture_image_memory_barrier.oldLayout = copy_info.dst.initial_layout
		texture_image_memory_barrier.subresourceRange = {
			aspectMask = aspect_mask,
			baseMipLevel = min_mip_level,
			levelCount = max_mip_level - min_mip_level + 1,
			baseArrayLayer = min_array_layer,
			layerCount = max_array_layer - min_array_layer + 1,
		}
		append(&image_transitions, texture_image_memory_barrier)
	case Copy_Info_Image_To_Buffer:
	case Copy_Info_Image_To_Image:
	}
	texture_barrier_dependency_info := vk.DependencyInfo {
		sType = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = cast(u32)len(image_transitions),
		pImageMemoryBarriers = raw_data(image_transitions),
	}
	vk.CmdPipelineBarrier2(copy_fence.command_buffer, &texture_barrier_dependency_info)

	// Record copies into command buffer
	for _copy_info in copy_infos do switch copy_info in _copy_info {
	case Copy_Info_Buffer_To_Buffer:
		vk.CmdCopyBuffer(copy_fence.command_buffer, copy_info.src.buffer, copy_info.dst.buffer, cast(u32)len(copy_info.copy_regions), raw_data(copy_info.copy_regions))
	case Copy_Info_Buffer_To_Image:
		vk.CmdCopyBufferToImage(copy_fence.command_buffer, copy_info.src.buffer, copy_info.dst.image, .TRANSFER_DST_OPTIMAL, cast(u32)len(copy_info.copy_regions), raw_data(copy_info.copy_regions))
	case Copy_Info_Image_To_Buffer:
	case Copy_Info_Image_To_Image:
	}

	// Transition all images into .final_layout
	image_transitions_index := 0
	for _copy_info in copy_infos {
		switch copy_info in _copy_info {
		case Copy_Info_Buffer_To_Buffer:
			break
		case Copy_Info_Buffer_To_Image:
			texture_image_memory_barrier := &image_transitions[image_transitions_index]
			subresource_range := texture_image_memory_barrier.subresourceRange
			texture_image_memory_barrier^ = FINAL_TEXTURE_MEMORY_BARRIER_TEMPLATE
			texture_image_memory_barrier.image = copy_info.dst.image
			texture_image_memory_barrier.newLayout = copy_info.dst.final_layout
			texture_image_memory_barrier.subresourceRange = subresource_range

			image_transitions_index += 1
		case Copy_Info_Image_To_Buffer:
			image_transitions_index += 1
		case Copy_Info_Image_To_Image:
			image_transitions_index += 2
		}
	}
	vk.CmdPipelineBarrier2(copy_fence.command_buffer, &texture_barrier_dependency_info)

	check_result(vk.EndCommandBuffer(copy_fence.command_buffer), "Failed to end transfer command buffer! [" + #procedure + "]", panics = false) or_return

	transfer_fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	if check_result(vk.CreateFence(device, &transfer_fence_create_info, nil, &copy_fence.fence), "Unable to create transfer fence [" + #procedure + "]", panics = false) == false {
		vk.FreeCommandBuffers(device, copy_fence.command_pool, 1, &copy_fence.command_buffer)
		return {}, false
	}

	transfer_submit_info := vk.SubmitInfo {
		sType = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers = &copy_fence.command_buffer,
	}
	if check_result(vk.QueueSubmit(transfer_queue, 1, &transfer_submit_info, copy_fence.fence), "Unable to submit copy commands to the queue!", panics = false) == false {
		vk.DestroyFence(device, copy_fence.fence, nil)
		vk.FreeCommandBuffers(device, copy_fence.command_pool, 1, &copy_fence.command_buffer)
		return {}, false
	}

	return copy_fence, true
}

copy_fence_wait :: proc(device: vk.Device, copy_fence: Copy_Fence, destroy_fence := true) -> (ok: bool) {
	copy_fence := copy_fence
	check_result(vk.WaitForFences(device, 1, &copy_fence.fence, true, max(u64)), "Failed to wait on copy fence! [" + #procedure + "]", panics = false) or_return
	if destroy_fence {
		copy_fence_destroy(device, copy_fence)
	}
	return true
}

copy_fence_destroy :: proc(device: vk.Device, copy_fence: Copy_Fence) {
	copy_fence := copy_fence
	assert(copy_fence.fence != 0)
	vk.DestroyFence(device, copy_fence.fence, nil)
	assert(copy_fence.command_pool != 0)
	assert(copy_fence.command_buffer != nil)
	vk.FreeCommandBuffers(device, copy_fence.command_pool, 1, &copy_fence.command_buffer)
}
