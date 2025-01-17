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

	// Transfer from RAM to VRAM
	texture_buffer_transfer_info := vkjs.Texture_Buffer_Transfer_Info {
		src = image_data.pixels.buf[:],
		dst = texture.image,
		extent = texture.extent,
		image_subresource_layers = {
			aspectMask = { .COLOR },
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	transfer_result, transfer_success := vkjs.texture_transfer_buffers_to_images(gfx.device, gfx.command_pools[.Transfer], gfx.queues[.Transfer].handle, gfx.physical_device_memory_properties, slice.from_ptr(&texture_buffer_transfer_info, 1))
	if !transfer_success {
		vkjs.texture_destroy(gfx.device, texture)
		vk.DestroyImageView(gfx.device, view, nil)
		return {}, 0, false
	}
	vkjs.texture_wait_for_buffer_transfer(gfx.device, transfer_result)

	return texture, view, true
}
