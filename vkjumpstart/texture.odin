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
