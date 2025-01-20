package ns_vkjumpstart_vkjs

import "base:runtime"

@(require) import "core:fmt"
@(require) import "core:log"

import vk "vendor:vulkan"

/*
	 Batch creates all the buffers and binds them all to one single DeviceMemory
	 All the buffers will share the same memory properties defined by `memory_property_flags`

	 Returns the buffers through `buffers_out`
	 Returns the memory via the returns: `memory`
*/
@(require_results)
buffer_create :: proc
(
	device: vk.Device,
	physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,
	buffer_create_infos: []vk.BufferCreateInfo,
	memory_property_flags: vk.MemoryPropertyFlags,
	buffers_out: []vk.Buffer,
) -> (
	memory: vk.DeviceMemory,
	ok: bool,
)
{
	assert(len(buffers_out) > 0)
	assert(len(buffer_create_infos) == len(buffers_out))

	destroy_buffers :: proc(device: vk.Device, buffers: []vk.Buffer, #any_int end := max(int)) {
		for buffer, idx in buffers {
			if idx == end { break }
			vk.DestroyBuffer(device, buffer, nil)
		}
	}

	// Create buffers
	#no_bounds_check for &buffer_out, idx in buffers_out {
		buffer_create_info := &buffer_create_infos[idx]
		buffer_create_info.sType = .BUFFER_CREATE_INFO
		if check_result(vk.CreateBuffer(device, buffer_create_info, nil, &buffer_out), panics = false) == false {
			log.errorf("Failed to create buffer '%v' [" + #procedure + "]", idx)
			destroy_buffers(device, buffers_out, idx)
			return 0, false
		}
	}

	// Allocate Memory
	memory_alloc_size: int
	memory_type_bits: u32
	for buffer in buffers_out {
		memory_requirements: vk.MemoryRequirements = ---
		vk.GetBufferMemoryRequirements(device, buffer, &memory_requirements)

		memory_type_bits |= memory_requirements.memoryTypeBits
		memory_alloc_size += runtime.align_forward_int(memory_alloc_size, cast(int)memory_requirements.alignment)
		memory_alloc_size += cast(int)memory_requirements.size
	}
	memory_type_index := get_memory_type_index(memory_type_bits, memory_property_flags, physical_device_memory_properties)
	if memory_type_index == max(u32) {
		log.error("Failed to find valid memory type index for buffer memory! [" + #procedure + "]")
		destroy_buffers(device, buffers_out)
		return 0, false
	}

	memory_allocate_info := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = cast(vk.DeviceSize)memory_alloc_size,
		memoryTypeIndex = memory_type_index,
	}
	if check_result(vk.AllocateMemory(device, &memory_allocate_info, nil, &memory), "Failed to allocate memory for buffers! [" + #procedure + "]", panics = false) == false {
		destroy_buffers(device, buffers_out)
	}

	// Bind buffers to memory
	buffer_offset: int
	for buffer, idx in buffers_out {
		memory_requirements: vk.MemoryRequirements = ---
		vk.GetBufferMemoryRequirements(device, buffer, &memory_requirements)

		buffer_offset += runtime.align_forward_int(buffer_offset, cast(int)memory_requirements.alignment)
		if check_result(vk.BindBufferMemory(device, buffer, memory, memoryOffset = cast(vk.DeviceSize)buffer_offset), panics = false) == false {
			log.errorf("Failed to bind buffer '%v' to memory!", idx)

			vk.FreeMemory(device, memory, nil)
			destroy_buffers(device, buffers_out)

			return 0, false
		}
		buffer_offset += cast(int)memory_requirements.size
	}

	return memory, true
}
