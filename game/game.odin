package game

import "core:fmt"
import "core:log"
import "core:time"
import sa "core:container/small_array"
import "core:math/rand"

import "vendor:glfw"
import vk "vendor:vulkan"

import vkjs "../vkjumpstart"

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
gfx: ^GFX

ENTITY_CAP :: 250
Game_Data_Persistent :: struct {
	player: Player,
	entities: sa.Small_Array(ENTITY_CAP, Entity),
}
p: ^Game_Data_Persistent

@(export)
update :: proc() {
	player_update(&p.player)
	for &entity in sa.slice(&p.entities) {
		entity_update(&entity)
	}
}

@(export)
init :: proc(gfx_ptr: rawptr, game_data: rawptr = nil) {
	assert(gfx_ptr != nil)
	gfx = cast(^GFX)gfx_ptr
	// We'll leave it to the OS to unload
	vulkan_lib, vk_get_instance_proc_address, vulkan_lib_ok := vkjs.load_vulkan()
	if !vulkan_lib_ok {
		log.panic("Unable to load Vulkan!")
	}
	// Reload vulkan addresses
	vk.load_proc_addresses_global(vk_get_instance_proc_address)
	vk.load_proc_addresses_instance(gfx.instance)
	vk.load_proc_addresses_device(gfx.device)

	if game_data == nil {
		p = new(Game_Data_Persistent)
		// One Time Inits
		// Spawn guys
		for _ in 0..<min(1000, ENTITY_CAP) {
			RANGE :: 70
			x_pos := rand.float32_range(-RANGE, +RANGE)
			z_pos := rand.float32_range(-RANGE, +RANGE)
			sa.append(&p.entities, Entity {})
			entity := sa.get_ptr(&p.entities, sa.len(p.entities) - 1)
			entity.pos = { x_pos, 0, z_pos }
		}
	}
	else {
		p = cast(^Game_Data_Persistent)game_data
	}

	// Init Shaders
	log.info("Creating Shaders!")
	create_shaders()
	log.info("Finished creating shaders!")

	// GLFW Callbacks
	glfw.SetKeyCallback(gfx.window, glfw_key_callback)

	// Init Audio
	audio_init()
}

@(export, fini)
clean :: proc() {
	if p == nil { return }
	destroy_shaders()
	audio_destroy()
}

@(export)
destroy :: proc() {
	if p == nil { return }
	free(p)
	p = nil
}

@(export)
get_game_data :: proc() -> rawptr {
	return p
}
