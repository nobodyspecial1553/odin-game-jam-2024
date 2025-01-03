package main

import "core:log"
import "core:fmt"
import "core:slice"
import "core:time"
import "core:dynlib"

import "vendor:glfw"
import vk "vendor:vulkan"

import vkjs "vkjumpstart"

DEFAULT_WIDTH :: 800
DEFAULT_HEIGHT :: 800
TITLE :: "Punchin' Penguins!"

CONCURRENT_FRAMES :: 3

GFX :: struct {
	window: glfw.WindowHandle,
	instance: vk.Instance,
	surface: vk.SurfaceKHR,
	swapchain: vkjs.Swapchain,
	physical_device: vk.PhysicalDevice,
	physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties,
	device: vk.Device,
	queues: vkjs.Queue_Array,
	command_pools: [vkjs.Queue_Type]vk.CommandPool,
	draw: struct {
		command_buffers: [CONCURRENT_FRAMES]vk.CommandBuffer,
		command_complete_fences: [CONCURRENT_FRAMES]vk.Fence,
		acquire_image_semaphores: [CONCURRENT_FRAMES]vk.Semaphore,
		render_complete_semaphores: [CONCURRENT_FRAMES]vk.Semaphore,
		current_frame: u32,
	},
	depth_stencil_images: struct {
		images: []vk.Image,
		views: []vk.ImageView,
		memory: vk.DeviceMemory,
		format: vk.Format,
	},
	timer: time.Stopwatch,
	delta_time: f32,
	last_updates_peak: int,
}
gfx: GFX

gfx_init :: proc() {
	// We'll leave it to the OS to unload
	vulkan_lib, vk_get_instance_proc_address, vulkan_lib_ok := vkjs.load_vulkan()
	if !vulkan_lib_ok {
		log.panic("Unable to load Vulkan!")
	}

	// Init Window & Vk
	if !glfw.VulkanSupported() {
		log.panic("GLFW declared: Vulkan not supported!")
	}

	// Create Surface
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	gfx.window = glfw.CreateWindow(DEFAULT_WIDTH, DEFAULT_HEIGHT, TITLE, nil, nil)
	if gfx.window == nil {
		log.panic("Failed to initialize GLFW window!")
	}

	// Create Instance
	vk_instance_extensions := glfw.GetRequiredInstanceExtensions()
	// vk_get_instance_proc_address := glfw.GetInstanceProcAddress(nil, "vkGetInstanceProcAddr")
	if !vkjs.create_instance(cast(rawptr)vk_get_instance_proc_address, &gfx.instance, vk_instance_extensions) {
		log.panic("Unable to create instance!")
	}

	// Create Surface
	vkjs.check_result(glfw.CreateWindowSurface(gfx.instance, gfx.window, nil, &gfx.surface), "Unable to create surface!")

	// Find Physical Device
	if !vkjs.find_optimal_physical_device(&gfx.physical_device, gfx.instance) {
		log.panic("Unable to find physical device!")
	}
	vk.GetPhysicalDeviceMemoryProperties(gfx.physical_device, &gfx.physical_device_memory_properties)

	// Create Device
	if !vkjs.create_device(&gfx.device, &gfx.queues, gfx.physical_device, gfx.surface) {
		log.panic("Unable to create Logical Device!")
	}

	// Create Swapchain
	window_width, window_height := glfw.GetWindowSize(gfx.window)
	gfx.swapchain = vkjs.create_swapchain({ cast(u32)window_width, cast(u32)window_height }, CONCURRENT_FRAMES, gfx.physical_device, gfx.device, gfx.surface, gfx.queues)
	if gfx.swapchain.handle == 0 {
		log.panic("Unable to create Swapchain!")
	}

	// Create General Purpose Command Pools
	for &command_pool, queue_type in gfx.command_pools {
		command_pool_create_info := vk.CommandPoolCreateInfo {
			sType = .COMMAND_POOL_CREATE_INFO,
			flags = { .RESET_COMMAND_BUFFER },
			queueFamilyIndex = gfx.queues[queue_type].family,
		}
		vkjs.check_result(vk.CreateCommandPool(gfx.device, &command_pool_create_info, nil, &command_pool), "Unable to create Command Pool!")
	}

	gfx_draw_init()
	gfx_depth_stencil_images_init()
}

gfx_clean :: proc() {
	// Vulkan
	vk.DeviceWaitIdle(gfx.device)

	gfx_depth_stencil_images_clean()
	gfx_draw_clean()

	for &command_pool in gfx.command_pools {
		if command_pool != 0 {
			vk.DestroyCommandPool(gfx.device, command_pool, nil)
		}
	}
	vkjs.free_swapchain(gfx.swapchain, gfx.device)
	if gfx.device != nil {
		vk.DestroyDevice(gfx.device, nil)
	}
	if gfx.surface != 0 {
		vk.DestroySurfaceKHR(gfx.instance, gfx.surface, nil)
	}
	if gfx.instance != nil {
		vk.DestroyInstance(gfx.instance, nil)
	}

	// GLFW
	if gfx.window != nil {
		glfw.DestroyWindow(gfx.window)
		gfx.window = nil
	}

	gfx = {}
}

gfx_draw_init :: proc() {
	// Command Buffers
	command_buffer_allocate_info := vk.CommandBufferAllocateInfo {
		sType = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool = gfx.command_pools[.Graphics],
		level = .PRIMARY,
		commandBufferCount = CONCURRENT_FRAMES,
	}
	vkjs.check_result(vk.AllocateCommandBuffers(gfx.device, &command_buffer_allocate_info, raw_data(&gfx.draw.command_buffers)))

	// Synchronization
	fence_create_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = { .SIGNALED },
	}
	semaphore_create_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	#no_bounds_check for i in 0..<CONCURRENT_FRAMES {
		vkjs.check_result(vk.CreateFence(gfx.device, &fence_create_info, nil, &gfx.draw.command_complete_fences[i]))
		vkjs.check_result(vk.CreateSemaphore(gfx.device, &semaphore_create_info, nil, &gfx.draw.acquire_image_semaphores[i]))
		vkjs.check_result(vk.CreateSemaphore(gfx.device, &semaphore_create_info, nil, &gfx.draw.render_complete_semaphores[i]))
	}
}

gfx_draw_clean :: proc() {
	vk.DeviceWaitIdle(gfx.device)
	#no_bounds_check for i in 0..<CONCURRENT_FRAMES {
		fence := gfx.draw.command_complete_fences[i]
		acquire_image_semaphore := gfx.draw.acquire_image_semaphores[i]
		render_complete_semaphore := gfx.draw.render_complete_semaphores[i]

		if fence != 0 {
			vk.DestroyFence(gfx.device, fence, nil)
		}
		if acquire_image_semaphore != 0 {
			vk.DestroySemaphore(gfx.device, acquire_image_semaphore, nil)
		}
		if render_complete_semaphore != 0 {
			vk.DestroySemaphore(gfx.device, render_complete_semaphore, nil)
		}
	}

	gfx.draw = {}
}

gfx_depth_stencil_images_init :: proc() {
	depth_stencil_images_count := len(gfx.swapchain.images)

	gfx.depth_stencil_images.images = make([]vk.Image, depth_stencil_images_count * 2)
	gfx.depth_stencil_images.views = slice.reinterpret([]vk.ImageView, gfx.depth_stencil_images.images[depth_stencil_images_count:])
	gfx.depth_stencil_images.images = gfx.depth_stencil_images.images[:depth_stencil_images_count]

	desired_depth_stencil_formats := [?]vk.Format {
		.D32_SFLOAT_S8_UINT,
		.D24_UNORM_S8_UINT,
		.D32_SFLOAT,
	}
	format_feature_flags := vk.FormatFeatureFlags {
		.DEPTH_STENCIL_ATTACHMENT,
	}
	find_image_format_success: bool = ---
	gfx.depth_stencil_images.format, find_image_format_success = vkjs.find_supported_image_format(gfx.physical_device, desired_depth_stencil_formats[:], .OPTIMAL, format_feature_flags)
	if !find_image_format_success {
		log.panic("Failed to find format for Depth-Stencil image!")
	}

	window_width, window_height := glfw.GetWindowSize(gfx.window)
	depth_stencil_images_create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = gfx.depth_stencil_images.format,
		extent = { cast(u32)window_width, cast(u32)window_height, 1 },
		mipLevels = 1,
		arrayLayers = 1,
		samples = { ._1 },
		tiling = .OPTIMAL,
		usage = { .DEPTH_STENCIL_ATTACHMENT },
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	for &image in gfx.depth_stencil_images.images {
		vkjs.check_result(vk.CreateImage(gfx.device, &depth_stencil_images_create_info, nil, &image))
	}

	memory_requirements: vk.MemoryRequirements = ---
	vk.GetImageMemoryRequirements(gfx.device, gfx.depth_stencil_images.images[0], &memory_requirements)
	memory_type_index := vkjs.get_memory_type_index(memory_requirements.memoryTypeBits, { .DEVICE_LOCAL }, gfx.physical_device_memory_properties)
	if memory_type_index == max(u32) {
		log.panic("Failed to find valid memory type for Depth-Stencil Image!")
	}

	memory_size_aligned := cast(vk.DeviceSize)vkjs.align_value(memory_requirements.size, memory_requirements.alignment)
	memory_allocate_info := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = memory_size_aligned * cast(vk.DeviceSize)depth_stencil_images_count,
		memoryTypeIndex = memory_type_index,
	}
	vkjs.check_result(vk.AllocateMemory(gfx.device, &memory_allocate_info, nil, &gfx.depth_stencil_images.memory))

	for &image, idx in gfx.depth_stencil_images.images {
		offset := cast(vk.DeviceSize)idx * memory_size_aligned
		vkjs.check_result(vk.BindImageMemory(gfx.device, image, gfx.depth_stencil_images.memory, offset))
	}

	// Create views
	aspect_mask := vk.ImageAspectFlags { .DEPTH, .STENCIL }
	image_view_create_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		viewType = .D2,
		format = gfx.depth_stencil_images.format,
		components = {},
		subresourceRange = {
			aspectMask = aspect_mask,
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	#no_bounds_check for &view, idx in gfx.depth_stencil_images.views {
		image_view_create_info.image = gfx.depth_stencil_images.images[idx]
		vkjs.check_result(vk.CreateImageView(gfx.device, &image_view_create_info, nil, &view))
	}
}

gfx_depth_stencil_images_clean :: proc() {
	vk.DeviceWaitIdle(gfx.device)
	#no_bounds_check for i in 0..<len(gfx.depth_stencil_images.images) {
		if gfx.depth_stencil_images.images[i] != 0 {
			vk.DestroyImage(gfx.device, gfx.depth_stencil_images.images[i], nil)
		}
		if gfx.depth_stencil_images.views[i] != 0 {
			vk.DestroyImageView(gfx.device, gfx.depth_stencil_images.views[i], nil)
		}
	}
	if gfx.depth_stencil_images.memory != 0 {
		vk.FreeMemory(gfx.device, gfx.depth_stencil_images.memory, nil)
	}

	free(raw_data(gfx.depth_stencil_images.images))

	gfx.depth_stencil_images = {}
}

gfx_recreate_swapchain :: proc() {
	vk.DeviceWaitIdle(gfx.device)

	window_width, window_height := glfw.GetWindowSize(gfx.window)
	window_size := vk.Extent2D { cast(u32)window_width, cast(u32)window_height }

	swapchain_recreate_success: bool = ---
	gfx.swapchain, swapchain_recreate_success = vkjs.create_swapchain(window_size, CONCURRENT_FRAMES, gfx.physical_device, gfx.device, gfx.surface, gfx.queues, gfx.swapchain)
	if !swapchain_recreate_success {
		log.panic("Unable to re-create swapchain!")
	}

	gfx_depth_stencil_images_clean()
	gfx_draw_clean()

	gfx_draw_init()
	gfx_depth_stencil_images_init()
}
