package game

import "core:fmt"
import "core:log"
import "core:image/png"
import "core:image"
import "core:slice"

import vk "vendor:vulkan"

import vkjs "../vkjumpstart"

/*
	 This procedure only exists to help shift between my old version of vkjumpstart and the new one.
	 The jam game I made doesn't do textures in a way I would like to do going forward.
	 So I'm gonna create this helper function just to bridge the gap and keep it functional.
	 Why didn't I just leave the old version of the vkjumpstart for this jam game, you ask.
	 Well, because this is a nice testing ground for updating my vkjumpstart. :D

	 Please ignore the horribleness going on in `gfx.odin`
	 Since I had to change how images are loaded, it is now complete garbage. XD
*/
@(require_results)
texture_load_from_file :: proc
(
	file_path: string,
) -> (
	texture: vkjs.Texture,
	view: vk.ImageView, // Default view since my jam game never did anything more than that
	ok: bool,
)
{
	// Load image into RAM
	image_data, image_load_from_file_error := image.load_from_file(file_path, { .alpha_add_if_missing })
	if image_load_from_file_error != nil {
		log.errorf("Failed to load image, error: %v", image_load_from_file_error)
		return {}, 0, false
	}
	defer image.destroy(image_data)

	// Create buffer to hold pixel data
	buffer_create_info := vk.BufferCreateInfo {
		size = cast(vk.DeviceSize)len(image_data.pixels.buf),
		usage = { .TRANSFER_SRC },
		sharingMode = .EXCLUSIVE,
	}
	buffer: vk.Buffer
	buffer_memory := vkjs.buffer_create(gfx.device, gfx.physical_device_memory_properties, slice.from_ptr(&buffer_create_info, 1), { .HOST_VISIBLE, .HOST_COHERENT }, slice.from_ptr(&buffer, 1)) or_return
	defer {
		vk.DestroyBuffer(gfx.device, buffer, nil)
		vk.FreeMemory(gfx.device, buffer_memory, nil)
	}
	
	buffer_ptr: rawptr = ---
	vkjs.check_result(vk.MapMemory(gfx.device, buffer_memory, 0, cast(vk.DeviceSize)vk.WHOLE_SIZE, {}, &buffer_ptr), panics = false) or_return
	copy(slice.bytes_from_ptr(buffer_ptr, len(image_data.pixels.buf)), image_data.pixels.buf[:])
	vk.UnmapMemory(gfx.device, buffer_memory)

	// Create Texture
	image_views := slice.from_ptr(&view, 1)
	image_view_create_infos := []vk.ImageViewCreateInfo {
		{
			/* image = 0 // will be filled in during creation */
			viewType = .D2,
			format = .R8G8B8A8_UNORM,
			components = {}, // Identity
			subresourceRange = {
				aspectMask = { .COLOR },
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		},
	}

	image_create_info := vk.ImageCreateInfo {
		imageType = .D2,
		format = .R8G8B8A8_UNORM,
		extent = { cast(u32)image_data.width, cast(u32)image_data.height, 1 },
		mipLevels = 1,
		arrayLayers = 1,
		samples = { ._1 },
		tiling = .OPTIMAL,
		usage = { .TRANSFER_DST, .SAMPLED },
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	texture_create_success: bool = ---
	texture, texture_create_success = vkjs.texture_create(gfx.device, gfx.physical_device_memory_properties, image_create_info, image_view_create_infos, image_views)
	if !texture_create_success {
		log.error("Failed to create texture!")
		return {}, 0, false
	}

	// Copy Buffer to Image
	copy_info: vkjs.Copy_Info = vkjs.Copy_Info_Buffer_To_Image {
		src = {
			buffer = buffer,
		},
		dst = {
			image = texture.image,
			initial_layout = .UNDEFINED,
			final_layout = .SHADER_READ_ONLY_OPTIMAL,
		},
		copy_regions = []vk.BufferImageCopy {
			{
				imageSubresource = {
					aspectMask = { .COLOR },
					mipLevel = 0,
					baseArrayLayer = 0,
					layerCount = 1,
				},
				imageExtent = texture.extent,
			},
		},
	}
	copy_fence, copy_success := vkjs.copy(gfx.device, gfx.command_pools[.Transfer], gfx.queues[.Transfer].handle, gfx.physical_device_memory_properties, slice.from_ptr(&copy_info, 1))
	if !copy_success {
		vkjs.texture_destroy(gfx.device, texture)
	}
	vkjs.copy_fence_wait(gfx.device, copy_fence)

	return texture, view, true
}
