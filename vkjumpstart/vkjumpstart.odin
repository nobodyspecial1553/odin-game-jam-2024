package ns_vkjumpstart_vkjs

import "base:intrinsics"
import "base:runtime"

import "core:log"
import os "core:os/os2"
import "core:c"
import "core:mem"
import "core:slice"
import "core:dynlib"

import vk "vendor:vulkan"

when ODIN_OS == .Linux {
	VULKAN_LIB_PATH :: "libvulkan.so.1"
}
else when ODIN_OS == .Windows {
	VULKAN_LIB_PATH :: "vulkan-1.dll"
}
else when ODIN_OS == .Darwin {
	// VULKAN_LIB_PATH :: "libvulkan.1.dylib"
	#panic("vkjumpstart: Unsupported OS!")
}
else {
	#panic("vkjumpstart: Unsupported OS!")
}

@(private)
ENABLE_DEBUG_FEATURES_DEFAULT :: #config(VKJS_ENABLE_DEBUG_FEATURES_DEFAULT, ODIN_DEBUG)

check_result :: #force_inline proc(result: vk.Result, error_message: string = "", loc := #caller_location) {
	#partial switch(result) {
	case .SUCCESS, .INCOMPLETE:
		break
	case:
		if len(error_message) > 0 {
			log.panicf("CHECK_RESULT: %v - Message: \"%s\"", result, error_message, location = loc)
		}
		else {
			log.panicf("CHECK_RESULT: %v", result, location = loc)
		}
	}
}

load_vulkan :: proc() -> (vulkan_lib: dynlib.Library, vkGetInstanceProcAddr: rawptr, ok: bool) {
	vkGetInstanceProcAddr_Str :: "vkGetInstanceProcAddr"

	vulkan_lib, ok = dynlib.load_library(VULKAN_LIB_PATH)
	if !ok {
		log.fatal("Unable to load vulkan library: \"%s\"", VULKAN_LIB_PATH)
		return {}, nil, false
	}

	vkGetInstanceProcAddr, ok = dynlib.symbol_address(vulkan_lib, vkGetInstanceProcAddr_Str)
	if !ok {
		log.fatal("Unable to find symbol address: " + vkGetInstanceProcAddr_Str)
		dynlib.unload_library(vulkan_lib) or_return
		return {}, nil, false
	}

	return vulkan_lib, vkGetInstanceProcAddr, ok
}

create_instance :: proc(vkGetInstanceProcAddr_func_ptr: rawptr, instance: ^vk.Instance, instance_extensions: []cstring, enable_debug_features := ENABLE_DEBUG_FEATURES_DEFAULT) -> bool {
	assert(instance != nil)

	instance_extensions := instance_extensions

	arena_temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(arena_temp)

	extra_instance_extensions := []cstring {
		"VK_KHR_portability_enumeration",
	}
	instance_extensions = slice.concatenate([][]cstring { instance_extensions, extra_instance_extensions }, context.temp_allocator)

	// Load Global Procs
	if vkGetInstanceProcAddr_func_ptr != nil {
		vk.load_proc_addresses_global(vkGetInstanceProcAddr_func_ptr)
	}

	instance_extension_properties_count: u32 = ---
	vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_properties_count, nil)
	instance_extension_properties_array := make([]vk.ExtensionProperties, instance_extension_properties_count, context.temp_allocator)
	vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_properties_count, raw_data(instance_extension_properties_array))

	instance_extension_match_found: for instance_extension in instance_extensions {
		for &instance_extension_properties in instance_extension_properties_array {
			extension_name := cstring(raw_data(&instance_extension_properties.extensionName))
			if instance_extension == extension_name {
				// Print enable message
				log.infof("Enabling Instance Extension: \"%s\"", extension_name)
				// Match found
				continue instance_extension_match_found
			}
		}
		log.errorf("Instance Extension \"%s\" is unavailable!", instance_extension)
		return false
	}
	
	// Create Instance
	api_version: u32 = ---
	vk.EnumerateInstanceVersion(&api_version)
	log.infof("Vulkan Instance API version: %v.%v.%v", api_version >> 22, (api_version >> 12) & 0x3FF, api_version & 0xFFF)

	application_info := vk.ApplicationInfo {
		sType = .APPLICATION_INFO,
		pApplicationName = "",
		applicationVersion = 0,
		pEngineName = nil,
		engineVersion = 0,
		apiVersion = api_version,
	}

	instance_create_info := vk.InstanceCreateInfo {
		sType = .INSTANCE_CREATE_INFO,
		flags = { .ENUMERATE_PORTABILITY_KHR },
		pApplicationInfo = &application_info,
		enabledExtensionCount = cast(u32)len(instance_extensions),
		ppEnabledExtensionNames = raw_data(instance_extensions),
	}

	if enable_debug_features {
		// Verify required InstanceLayer existence
		@(static, rodata)
		required_layer_properties := [?]cstring {
			"VK_LAYER_KHRONOS_validation",
		}

		layer_properties_count: u32 = ---
		vk.EnumerateInstanceLayerProperties(&layer_properties_count, nil)
		layer_properties := make([]vk.LayerProperties, layer_properties_count, context.temp_allocator)
		vk.EnumerateInstanceLayerProperties(&layer_properties_count, &layer_properties[0])

		match_found: for required in required_layer_properties {
			for &properties in layer_properties {
				if required == cstring(raw_data(&properties.layerName)) {
					// Match found
					continue match_found
				}
			}
			// Match not found - Exit
			log.errorf("Instance Validation Layer \"%s\" is unavailable!", required)
			return false
		}

		for required_layer_property in required_layer_properties {
			// Print out all layers we will enable
			log.infof("Enabling Instance Layer: \"%v\"", required_layer_property)
		}

		instance_create_info.enabledLayerCount = len(required_layer_properties)
		instance_create_info.ppEnabledLayerNames = &required_layer_properties[0]
		// Validation Features
		log.info("Enabling extra VkInstance validation features")
		validation_features_enable := [?]vk.ValidationFeatureEnableEXT {
			.BEST_PRACTICES,
			.GPU_ASSISTED,
			.SYNCHRONIZATION_VALIDATION,
		}
		validation_features := vk.ValidationFeaturesEXT {
			sType = .VALIDATION_FEATURES_EXT,
			enabledValidationFeatureCount = len(validation_features_enable),
			pEnabledValidationFeatures = raw_data(&validation_features_enable),
		}
		instance_create_info.pNext = &validation_features
	}

	result := vk.CreateInstance(&instance_create_info, nil, instance)
	#partial switch result {
	case .SUCCESS:
	case .ERROR_LAYER_NOT_PRESENT:
		log.error("Instance Layer not present!")
		return false
	case .ERROR_EXTENSION_NOT_PRESENT:
		log.error("Instance Extension not present!")
		return false
	}

	// Load Instance Procs
	vk.load_proc_addresses_instance(instance^)

	return true
}

Queue_Type :: enum {
	Graphics,
	Compute,
	Transfer,
	Sparse_Binding,
	Presentation,
}

Queue :: struct {
	handle: vk.Queue,
	family: u32,
}

Queue_Array :: [Queue_Type]Queue

create_device :: proc(device: ^vk.Device, queues: ^Queue_Array, physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR, enable_debug_features := ENABLE_DEBUG_FEATURES_DEFAULT) -> bool {
	arena_temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(arena_temp)

	// Features
	synchronization2_features := vk.PhysicalDeviceSynchronization2Features {
		sType = .PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES_KHR,
		pNext = nil,
	}
	indexing_features := vk.PhysicalDeviceDescriptorIndexingFeatures {
		sType = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES_EXT,
		pNext = &synchronization2_features,
	}
	shader_object_features := vk.PhysicalDeviceShaderObjectFeaturesEXT {
		sType = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
		pNext = &indexing_features,
	}
	dynamic_rendering_feature := vk.PhysicalDeviceDynamicRenderingFeaturesKHR {
		sType = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES_KHR,
		pNext = &shader_object_features,
	}
	physical_device_features2 := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &dynamic_rendering_feature,
	}
	vk.GetPhysicalDeviceFeatures2(physical_device, &physical_device_features2)

	// Check desired feature availability
	if synchronization2_features.synchronization2 == false {
		log.error("Synchronization2 features not supported!")
		return false
	}
	if !indexing_features.descriptorBindingPartiallyBound || !indexing_features.runtimeDescriptorArray {
		log.error("Bindless Textures not supported on this device!")
		return false
	}
	if shader_object_features.shaderObject == false {
		log.error("Shader Object is not available on this device!")
		return false
	}
	if dynamic_rendering_feature.dynamicRendering == false {
		log.error("Dynamic Rendering is not available on this device!")
		return false
	}

	// Extensions
	device_extensions := [?]cstring {
		"VK_KHR_swapchain",
		"VK_KHR_dynamic_rendering",
		"VK_EXT_shader_object",
		"VK_EXT_descriptor_indexing",
		"VK_KHR_synchronization2",
	}

	// Check for extension availability
	device_extension_properties_count: u32 = ---
	vk.EnumerateDeviceExtensionProperties(physical_device, nil, &device_extension_properties_count, nil)
	device_extension_properties_array := make([]vk.ExtensionProperties, device_extension_properties_count, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(physical_device, nil, &device_extension_properties_count, raw_data(device_extension_properties_array))

	device_extension_match_found: for device_extension in device_extensions {
		for &device_extension_properties in device_extension_properties_array {
			#no_bounds_check extension_name := cstring(raw_data(&device_extension_properties.extensionName))
			if device_extension == extension_name {
				// Print enable message
				log.infof("Enabling Device Extension: \"%s\"", extension_name)
				// Match found
				continue device_extension_match_found
			}
		}
		log.errorf("Device Extension \"%s\" is unavailable!", device_extension)
		return false
	}


	// Get Physical Device Info
	physical_device_properties: vk.PhysicalDeviceProperties = ---
	vk.GetPhysicalDeviceProperties(physical_device, &physical_device_properties)

	// Print Physical Device Details
	log.infof("Chosen Device: \"%v\"", cstring(raw_data(&physical_device_properties.deviceName)))

	api_version := physical_device_properties.apiVersion
	log.infof("Vulkan Device API Version: %v.%v.%v", api_version >> 22, (api_version >> 12) & 0x3FF, api_version & 0xFFF)

	// PhysicalDevice must support { .GRAPHICS, .COMPUTE, .TRANSFER, .SPARSE_BINDING } and Surface
	found_flags: vk.QueueFlags
	// Ensure all queue families can be made
	queue_family_properties_count: u32 = ---
	vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_properties_count, nil)
	queue_family_properties := make([]vk.QueueFamilyProperties, queue_family_properties_count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_properties_count, &queue_family_properties[0])

	// Check that the PhysicalDevice supports all the Queue Flags
	for properties in queue_family_properties {
		found_flags |= properties.queueFlags
	}

	// Queue Create Infos
	queue_priority: [len(Queue_Type)]f32 = f32(1)
	queue_create_infos_count: u32
	queue_create_infos: [Queue_Type]vk.DeviceQueueCreateInfo = ---

	QUEUE_FAMILY_INVALID : u32 : max(u32) // If there are ever 4294967295 queue families, we're in funky town
	queues[.Graphics].family = QUEUE_FAMILY_INVALID
	queues[.Compute].family = QUEUE_FAMILY_INVALID
	queues[.Transfer].family = QUEUE_FAMILY_INVALID
	queues[.Sparse_Binding].family = QUEUE_FAMILY_INVALID
	queues[.Presentation].family = QUEUE_FAMILY_INVALID

	queue_family_counters := make([]int, queue_family_properties_count, context.temp_allocator)

	find_suitable_queue_family :: proc "contextless" (queue: ^Queue, queue_family_properties: []vk.QueueFamilyProperties, queue_flag: vk.QueueFlag, queue_family_counters: ^[]int) -> bool {
		// Find family
		for i in 0 ..< len(queue_family_counters) {
			// Spread the queues out more evenly
			if i != len(queue_family_counters) - 1 && queue_family_counters[i] < queue_family_counters[i + 1] { continue }
			if queue_flag in queue_family_properties[i].queueFlags {
				queue_family_counters[i] += 1
				queue.family = cast(u32)i
				return true
			}
		}

		return false
	}

	if !find_suitable_queue_family(&queues[.Graphics], queue_family_properties, .GRAPHICS, &queue_family_counters) { return false }
	if !find_suitable_queue_family(&queues[.Compute], queue_family_properties, .COMPUTE, &queue_family_counters) { return false }
	if !find_suitable_queue_family(&queues[.Transfer], queue_family_properties, .TRANSFER, &queue_family_counters) { return false }
	if !find_suitable_queue_family(&queues[.Sparse_Binding], queue_family_properties, .SPARSE_BINDING, &queue_family_counters) { return false }

	// Presentation queue is special case
	find_suitable_presentation_queue_family: {
		// Find family
		for &queue_family_counter, idx in queue_family_counters {
			surface_is_supported: b32 = false
			if vk.GetPhysicalDeviceSurfaceSupportKHR(physical_device, cast(u32)idx, surface, &surface_is_supported) == .SUCCESS && surface_is_supported {
				queue_family_counter += 1
				queues[.Presentation].family = cast(u32)idx
				break find_suitable_presentation_queue_family
			}
		}

		if queues[.Presentation].family == QUEUE_FAMILY_INVALID { return false }
	}

	for queue_family_counter, idx in queue_family_counters {
		if queue_family_counter == 0 { continue }
		queue_create_infos[cast(Queue_Type)queue_create_infos_count] = vk.DeviceQueueCreateInfo {
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = cast(u32)idx,
			queueCount = 1,
			pQueuePriorities = cast([^]f32)&queue_priority,
		}
		queue_create_infos_count += 1
	}

	// Device Create Info
	device_create_info := vk.DeviceCreateInfo {
		sType = .DEVICE_CREATE_INFO,
		pNext = &physical_device_features2,
		queueCreateInfoCount = queue_create_infos_count,
		pQueueCreateInfos = &queue_create_infos[cast(Queue_Type)0],
		enabledExtensionCount = cast(u32)len(device_extensions),
		ppEnabledExtensionNames = &device_extensions[0],
	}

	if enable_debug_features {
		// This stuff is deprecated, but we're doing it anyways
		// Verify required DeviceLayer existence
		@(static, rodata)
		required_layer_properties := [?]cstring {
			"VK_LAYER_KHRONOS_validation",
		}

		layer_properties_count: u32 = ---
		vk.EnumerateDeviceLayerProperties(physical_device, &layer_properties_count, nil)
		layer_properties := make([]vk.LayerProperties, layer_properties_count, context.temp_allocator)
		vk.EnumerateDeviceLayerProperties(physical_device, &layer_properties_count, &layer_properties[0])

		device_layer_match_found: for required in required_layer_properties {
			for &properties in layer_properties {
				#no_bounds_check if required == cstring(raw_data(&properties.layerName)) {
					// Match found
					continue device_layer_match_found
				}
			}
			// Match not found - Exit
			log.errorf("Device Validation Layer \"%s\" is unavailable!", required)
			return false
		}

		for required_layer_property in required_layer_properties {
			// Print out all layers we will enable
			log.infof("Enabling Device Layer: \"%v\"", required_layer_property)
		}

		device_create_info.enabledLayerCount = len(required_layer_properties)
		device_create_info.ppEnabledLayerNames = &required_layer_properties[0]
	}

	// Create Device
	if vk.CreateDevice(physical_device, &device_create_info, nil, device) != .SUCCESS {
		return false
	}
	vk.load_proc_addresses_device(device^) // Help avoid dispatch logic

	// Get Queue Handles
	vk.GetDeviceQueue(device^, queues[.Graphics].family, 0, &queues[.Graphics].handle)
	vk.GetDeviceQueue(device^, queues[.Compute].family, 0, &queues[.Compute].handle)
	vk.GetDeviceQueue(device^, queues[.Transfer].family, 0, &queues[.Transfer].handle)
	vk.GetDeviceQueue(device^, queues[.Sparse_Binding].family, 0, &queues[.Sparse_Binding].handle)
	vk.GetDeviceQueue(device^, queues[.Presentation].family, 0, &queues[.Presentation].handle)
	/*
	for &queue in queues^ {
		vk.GetDeviceQueue(device^, queue.family, 0, &queue.handle)
	}
	*/

	return true
}

Swapchain :: struct {
	handle: vk.SwapchainKHR,
	images: []vk.Image, // Delete
	views: []vk.ImageView, // Do not delete
	surface_format: vk.SurfaceFormatKHR,
}

free_swapchain :: proc(swapchain: Swapchain, device: vk.Device) {
	vk.DeviceWaitIdle(device)

	if swapchain.views != nil {
		for view in swapchain.views {
			if view != 0 {
				vk.DestroyImageView(device, view, nil)
			}
		}
	}
	if swapchain.images != nil {
		delete(swapchain.images)
	}
	if swapchain.handle != 0 {
		vk.DestroySwapchainKHR(device, swapchain.handle, nil)
	}
}

create_swapchain :: proc(window_size: vk.Extent2D, #any_int min_images: c.int, physical_device: vk.PhysicalDevice, device: vk.Device, surface: vk.SurfaceKHR, queues: Queue_Array, old_swapchain: Swapchain = {}) -> (Swapchain, bool) #optional_ok {
	arena_temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(arena_temp)

	swapchain: Swapchain

	surface_format_count: u32 = ---
	vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &surface_format_count, nil)
	surface_formats := make([]vk.SurfaceFormatKHR, surface_format_count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &surface_format_count, raw_data(surface_formats))

	required_format_arr := [?]vk.Format {
		.B8G8R8A8_SRGB,
		.B8G8R8A8_UNORM,
		.B8G8R8A8_SNORM,
		.R8G8B8A8_SRGB,
		.R8G8B8A8_SNORM,
		.R8G8B8A8_UNORM,
	}
	selected_format: vk.SurfaceFormatKHR
	format_match_found: for required_format in required_format_arr {
		for surface_format in surface_formats {
			if surface_format.format == required_format {
				selected_format = surface_format
				break format_match_found
			}
		}
	}
	if selected_format.format == .UNDEFINED {
		log.error("Unable to find suitable Surface format!")
		return swapchain, false
	}
	swapchain.surface_format = selected_format

	log.infof("Selected Surface Format: %v", selected_format.format)
	log.infof("Selected Surface Color Space: %v", selected_format.colorSpace)

	image_usage : vk.ImageUsageFlags = {
		.TRANSFER_SRC, .TRANSFER_DST, .COLOR_ATTACHMENT,
	}
	
	// Determine minimum image count
	surface_capabilities: vk.SurfaceCapabilitiesKHR = ---
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &surface_capabilities) != .SUCCESS {
		log.error("Unable to get physical device surface capabilities!")
		return swapchain, false
	}
	image_count: u32 = ---
	image_count = max(cast(u32)min_images, surface_capabilities.minImageCount)
	image_count = min(image_count, surface_capabilities.maxImageCount if surface_capabilities.maxImageCount != 0 else max(u32))

	presentation_queue_family := queues[.Presentation].family

	swapchain_create_info := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = surface,
		minImageCount = image_count,
		imageFormat = selected_format.format,
		imageColorSpace = selected_format.colorSpace,
		imageExtent = window_size,
		imageArrayLayers = 1,
		imageUsage = image_usage,
		imageSharingMode = .EXCLUSIVE,
		queueFamilyIndexCount = 1,
		pQueueFamilyIndices = &presentation_queue_family,
		preTransform = { .IDENTITY },
		compositeAlpha = { .OPAQUE },
		presentMode = .MAILBOX,
		clipped = true,
		oldSwapchain = old_swapchain.handle,
	}

	if vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &swapchain.handle) != .SUCCESS {
		log.error("Failed to create Swapchain!")
		return swapchain, false
	}

	if old_swapchain.handle != 0 {
		free_swapchain(old_swapchain, device)
	}

	// Get number of images actually allocated
	vk.GetSwapchainImagesKHR(device, swapchain.handle, &image_count, nil)
	log.infof("Swapchain Image Count: %v", image_count)

	#no_bounds_check {
		swapchain_images_alloc := make([]vk.Image, image_count * 2)
		swapchain.images = swapchain_images_alloc[:image_count]
		swapchain.views = slice.reinterpret([]vk.ImageView, swapchain_images_alloc[image_count:])
	}

	#partial switch vk.GetSwapchainImagesKHR(device, swapchain.handle, &image_count, raw_data(swapchain.images)) {
	case .SUCCESS:
	case .INCOMPLETE:
		// log.warnf("Incomplete Retrieval of Swapchain Images! Image Count: %v", image_count)
	case .ERROR_OUT_OF_HOST_MEMORY:
		log.error("Unable to get swapchain images!")
		log.error("OUT OF HOST MEMORY!")
		return {}, false
	case .ERROR_OUT_OF_DEVICE_MEMORY:
		log.error("Unable to get swapchain images!")
		log.error("OUT OF DEVICE MEMORY!")
		return {}, false
	}

	#no_bounds_check for i: u32 = 0; i < image_count; i += 1 {
		color_attachment_view_create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			format = selected_format.format,
			components = { .R, .G, .B, .A },
			subresourceRange = {
				aspectMask = { .COLOR },
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			viewType = .D2,
			image = swapchain.images[i],
		}

		if vk.CreateImageView(device, &color_attachment_view_create_info, nil, &swapchain.views[i]) != .SUCCESS {
			log.error("Unable to create swapchain image views!")
			return {}, false
		}
	}

	log.info("Swapchain created successfully")
	return swapchain, true
}

find_optimal_physical_device :: proc(physical_device: ^vk.PhysicalDevice, instance: vk.Instance) -> bool {
	arena_temp := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(arena_temp)

	physical_device_count: u32 = ---
	vk.EnumeratePhysicalDevices(instance, &physical_device_count, nil)
	physical_devices := make([]vk.PhysicalDevice, physical_device_count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(instance, &physical_device_count, &physical_devices[0])

	if physical_device_count == 0 {
		log.error("Unable to enumerate physical devices!")
		return false
	}

	chosen_physical_device_idx := -1
	chosen_physical_device_rating := -1
	chosen_physical_device_properties: vk.PhysicalDeviceProperties = ---
	for physical_device, idx in physical_devices {
		current_physical_device_rating := 0

		// Queue Family Properties
		required_flags := vk.QueueFlags { .GRAPHICS, .COMPUTE, .TRANSFER, .SPARSE_BINDING }
		found_flags: vk.QueueFlags

		queue_family_properties_count: u32 = ---
		vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_properties_count, nil)
		queue_family_properties := make([]vk.QueueFamilyProperties, queue_family_properties_count, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_properties_count, &queue_family_properties[0])

		for properties in queue_family_properties {
			found_flags |= properties.queueFlags
		}

		if found_flags < required_flags { // check: is found_flags only subset of required_flags
			continue
		}

		// Physical Device Properties
		physical_device_properties: vk.PhysicalDeviceProperties = ---
		vk.GetPhysicalDeviceProperties(physical_device, &physical_device_properties)

		if physical_device_properties.deviceType == .DISCRETE_GPU {
			current_physical_device_rating |= 0x8000_0000
		}

		/*
			 More can be done to measure the features and/or properties later.
		*/

		// Check competition
		if current_physical_device_rating > chosen_physical_device_rating {
			chosen_physical_device_rating = current_physical_device_rating
			chosen_physical_device_idx = idx
			chosen_physical_device_properties = physical_device_properties
		}
	}

	if chosen_physical_device_idx < 0 {
		log.error("No suitable physical device found!")
		return false
	}

	physical_device^ = physical_devices[chosen_physical_device_idx]
	return true
}

find_supported_image_format :: proc(physical_device: vk.PhysicalDevice, format_options: []vk.Format, tiling: vk.ImageTiling, features: vk.FormatFeatureFlags) -> (vk.Format, bool) #optional_ok {
	for format in format_options {
		format_properties: vk.FormatProperties = ---
		vk.GetPhysicalDeviceFormatProperties(physical_device, format, &format_properties)

		switch {
		case tiling == .LINEAR && (format_properties.linearTilingFeatures & features) == features:
			return format, true
		case tiling == .OPTIMAL && (format_properties.optimalTilingFeatures & features) == features:
			return format, true
		}
	}
	log.error("Unable to find supported image format!")
	return .UNDEFINED, false
}

format_has_stencil_component :: #force_inline proc "contextless" (format: vk.Format) -> bool {
	#partial switch format {
	case .D32_SFLOAT_S8_UINT,
			 .D24_UNORM_S8_UINT,
			 .D16_UNORM_S8_UINT:
		return true
	case:
		return false
	}
}

create_shader_module_from_spirv_file :: proc(device: vk.Device, file_path: string) -> (vk.ShaderModule, bool) #optional_ok {
	shader_file: ^os.File
	shader_file_open_error: os.Error
	shader_file_size: i64
	shader_code_buf: []byte
	shader_code_buf_alloc_error: mem.Allocator_Error

	shader_file, shader_file_open_error = os.open(file_path)
	if shader_file_open_error != nil {
		log.errorf("Failed to open shader file \"%s\": %v", file_path, shader_file_open_error)
		return 0, false
	}
	defer os.close(shader_file)

	shader_file_size, _ = os.file_size(shader_file)

	shader_code_buf, shader_code_buf_alloc_error = mem.alloc_bytes(int(shader_file_size), alignment = 4)
	if shader_code_buf_alloc_error != nil {
		log.errorf("Failed to allocate memory for shader module: %v", shader_code_buf_alloc_error)
		return 0, false
	}
	defer free(raw_data(shader_code_buf))

	if bytes_read, shader_file_read_error := os.read(shader_file, shader_code_buf); shader_file_read_error != nil {
		log.errorf("Failed to read shader file \"%s\": %v", file_path, shader_file_read_error)
		return 0, false
	}

	shader_module_create_info := vk.ShaderModuleCreateInfo {
		sType = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(shader_code_buf),
		pCode = cast(^u32)raw_data(shader_code_buf),
	}
	shader_module: vk.ShaderModule = ---
	shader_module_create_err: vk.Result = ---
	if shader_module_create_err = vk.CreateShaderModule(device, &shader_module_create_info, nil, &shader_module); shader_module_create_err != .SUCCESS {
		log.errorf("Failed to create shader module: %v", shader_module_create_err)
		return 0, false
	}

	return shader_module, true
}

get_memory_type_index :: proc(type_bits: u32, requested_properties: vk.MemoryPropertyFlags, memory_properties: vk.PhysicalDeviceMemoryProperties) -> (u32, bool) #optional_ok {
	type_bits := type_bits
	for i: u32 = 0; i < memory_properties.memoryTypeCount; i += 1 {
		if (type_bits & 1) == 1 && (memory_properties.memoryTypes[i].propertyFlags & requested_properties) == requested_properties {
			return i, true
		}
		type_bits >>= 1
	}
	return max(u32), false
}

align_value :: #force_inline proc "contextless" (value, alignment: $T) -> T where intrinsics.type_is_integer(T) {
	return (value + alignment - 1) / alignment * alignment
}
