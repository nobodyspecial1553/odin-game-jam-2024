package game

import "core:fmt"
import "core:log"
import "core:math/linalg"
import sa "core:container/small_array"
import "core:time"

import "vendor:glfw"
import vk "vendor:vulkan"

import vkjs "../vkjumpstart"

@(export)
draw :: proc() -> bool {
	#no_bounds_check command_buffer := gfx.draw.command_buffers[gfx.draw.current_frame]

	// Wait for cmd buffer to finish
	#no_bounds_check {
		vkjs.check_result(vk.WaitForFences(gfx.device, 1, &gfx.draw.command_complete_fences[gfx.draw.current_frame], true, max(u64)))
	}

	// Acquire swapchain image
	swapchain_image_index: u32 = ---
	#partial switch vk.AcquireNextImageKHR(gfx.device, gfx.swapchain.handle, max(u64), pImageIndex = &swapchain_image_index, semaphore=gfx.draw.acquire_image_semaphores[gfx.draw.current_frame], fence=0)
	{
	case .SUCCESS:
		break
	case .ERROR_OUT_OF_DATE_KHR, .SUBOPTIMAL_KHR:
		log.warn("Swapchain out of date, it must be re-created!")
		return false
	case:
		log.panic("Unable to acquire next image in swapchain!")
	}
	defer gfx.draw.current_frame = (gfx.draw.current_frame + 1) % CONCURRENT_FRAMES

	// Command Buffer Recording
	vkjs.check_result(vk.ResetCommandBuffer(command_buffer, {}))
	command_buffer_begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = { .ONE_TIME_SUBMIT },
	}
	vkjs.check_result(vk.BeginCommandBuffer(command_buffer, &command_buffer_begin_info))
	{ // Command Buffer Recording Scope
		#no_bounds_check image_memory_barriers := []vk.ImageMemoryBarrier2 {
			{ // Color Attachment
				sType = .IMAGE_MEMORY_BARRIER_2,
				srcStageMask = { .COLOR_ATTACHMENT_OUTPUT },
				srcAccessMask = { .COLOR_ATTACHMENT_WRITE },
				dstStageMask = { .COLOR_ATTACHMENT_OUTPUT },
				dstAccessMask = { .COLOR_ATTACHMENT_WRITE },
				oldLayout = .UNDEFINED,
				newLayout = .COLOR_ATTACHMENT_OPTIMAL,
				srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				image = gfx.swapchain.images[swapchain_image_index],
				subresourceRange = {
					aspectMask = { .COLOR },
					baseMipLevel = 0,
					levelCount = 1,
					baseArrayLayer = 0,
					layerCount = 1,
				},
			},
			{ // Depth-Stencil Attachment
				sType = .IMAGE_MEMORY_BARRIER_2,
				srcStageMask = { .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS },
				srcAccessMask = { .DEPTH_STENCIL_ATTACHMENT_WRITE },
				dstStageMask = { .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS },
				dstAccessMask = { .DEPTH_STENCIL_ATTACHMENT_WRITE },
				oldLayout = .UNDEFINED,
				newLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
				srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
				image = gfx.depth_stencil_images.images[swapchain_image_index],
				subresourceRange = {
					aspectMask = { .DEPTH, .STENCIL },
					baseMipLevel = 0,
					levelCount = 1,
					baseArrayLayer = 0,
					layerCount = 1,
				},
			},
		}
		dependency_info := vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = cast(u32)len(image_memory_barriers),
			pImageMemoryBarriers = raw_data(image_memory_barriers),
		}
		vk.CmdPipelineBarrier2(command_buffer, &dependency_info)

		// Render Pass Info
		#no_bounds_check color_attachment := vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = gfx.swapchain.views[swapchain_image_index],
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			resolveMode = {},
			loadOp = .CLEAR,
			storeOp = .STORE,
			clearValue = { color = { float32 = { 0.0, 0.6, 1, 1 } } },
		}

		#no_bounds_check depth_attachment := vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = gfx.depth_stencil_images.views[swapchain_image_index],
			imageLayout = .DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
			resolveMode = {},
			loadOp = .CLEAR,
			storeOp = .STORE,
			clearValue = { depthStencil = { depth = 1, stencil = 0 } },
		}

		window_width, window_height := glfw.GetWindowSize(gfx.window)
		rendering_info := vk.RenderingInfo {
			sType = .RENDERING_INFO,
			flags = {},
			renderArea = { { 0, 0 }, { cast(u32)window_width, cast(u32)window_height } },
			layerCount = 1,
			viewMask = 0,
			colorAttachmentCount = 1,
			pColorAttachments = &color_attachment,
			pDepthAttachment = &depth_attachment,
			pStencilAttachment = &depth_attachment,
		}
		vk.CmdBeginRendering(command_buffer, &rendering_info)
		{ // Render Pass Recording Scope
			draw_shader_ground(command_buffer)
			draw_shader_entity(command_buffer)
			draw_shader_fist(command_buffer)
		} // End Render Pass Recording Scope
		vk.CmdEndRendering(command_buffer)

		// Transition swapchain image to Presentation
		#no_bounds_check image_memory_barriers = []vk.ImageMemoryBarrier2 {
			{ // Color Attachment
				sType = .IMAGE_MEMORY_BARRIER_2,
				srcStageMask = { .COLOR_ATTACHMENT_OUTPUT },
				srcAccessMask = { .COLOR_ATTACHMENT_WRITE },
				dstStageMask = { .BOTTOM_OF_PIPE },
				dstAccessMask = {},
				oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
				newLayout = .PRESENT_SRC_KHR,
				srcQueueFamilyIndex = gfx.queues[.Graphics].family,
				dstQueueFamilyIndex = gfx.queues[.Presentation].family,
				image = gfx.swapchain.images[swapchain_image_index],
				subresourceRange = {
					aspectMask = { .COLOR },
					baseMipLevel = 0,
					levelCount = 1,
					baseArrayLayer = 0,
					layerCount = 1,
				},
			}
		}
		dependency_info = vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = cast(u32)len(image_memory_barriers),
			pImageMemoryBarriers = raw_data(image_memory_barriers),
		}
		vk.CmdPipelineBarrier2(command_buffer, &dependency_info)
	} // End Command Recording Buffer Scope
	vkjs.check_result(vk.EndCommandBuffer(command_buffer))

	// Submit
	#no_bounds_check  {
		vkjs.check_result(vk.ResetFences(gfx.device, 1, &gfx.draw.command_complete_fences[gfx.draw.current_frame]))
	}
	wait_dst_stage := vk.PipelineStageFlags { .COLOR_ATTACHMENT_OUTPUT }
	#no_bounds_check submit_info := vk.SubmitInfo {
		sType = .SUBMIT_INFO,
		pWaitDstStageMask = &wait_dst_stage,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &gfx.draw.acquire_image_semaphores[gfx.draw.current_frame],
		signalSemaphoreCount = 1,
		pSignalSemaphores = &gfx.draw.render_complete_semaphores[gfx.draw.current_frame],
		commandBufferCount = 1,
		pCommandBuffers = &command_buffer,
	}
	#no_bounds_check {
		vkjs.check_result(vk.QueueSubmit(gfx.queues[.Graphics].handle, 1, &submit_info, gfx.draw.command_complete_fences[gfx.draw.current_frame]))
	}

	// Present
	#no_bounds_check present_info := vk.PresentInfoKHR {
		sType = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores = &gfx.draw.render_complete_semaphores[gfx.draw.current_frame],
		swapchainCount = 1,
		pSwapchains = &gfx.swapchain.handle,
		pImageIndices = &swapchain_image_index,
	}
	#partial switch vk.QueuePresentKHR(gfx.queues[.Presentation].handle, &present_info) {
	case .SUCCESS, .SUBOPTIMAL_KHR: // Present even when suboptimal
		break
	case .ERROR_OUT_OF_DATE_KHR:
		log.error("Swapchain out of date, too late to present!")
		return false
	case:
		log.error("Unable to present swapchain image!")
		return false
	}

	// Post-drawing stuff
	return true
}

draw_shader_test :: proc(command_buffer: vk.CommandBuffer) {
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, shader_test.pipeline)

	vk.CmdDraw(command_buffer, 6, 1, 0, 0)
}

draw_shader_ground :: proc(command_buffer: vk.CommandBuffer) {
	window_width, window_height := glfw.GetWindowSize(gfx.window)
	scissor := vk.Rect2D {
		offset = { 0, 0 },
		extent = { cast(u32)window_width, cast(u32)window_height },
	}
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

	viewport := vk.Viewport {
		x = 0,
		y = 0,
		width = cast(f32)window_width,
		height = cast(f32)window_height,
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

	#no_bounds_check descriptor_sets := [?]vk.DescriptorSet {
		shader_ground.descriptor_sets[gfx.draw.current_frame],
		shader_ground.texture_set,
	}
	vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, shader_ground.pipeline_layout, 0, len(descriptor_sets), raw_data(&descriptor_sets), 0, nil)
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, shader_ground.pipeline)

	{ // Modify screen space memory
		#no_bounds_check screen_space := cast(^Shader_Ground_Screen_Space)shader_ground.screen_space_buffer_ptrs[gfx.draw.current_frame]

		projection_matrix := linalg.matrix4_perspective_f32(fovy = 70,
																										aspect = cast(f32)window_width / cast(f32)window_height,
																										near = 0.01,
																										far = 1000)

		camera: Camera
		camera.pos.y = 1
		view_matrix := camera_get_view_matrix(camera)

		screen_space^ = {
			mvp = projection_matrix * view_matrix,
			ground_scale = { GROUND_SCALE, GROUND_SCALE },
			cam_pos = [2]f32{ p.player.pos.x, -p.player.pos.z },
			rotation = linalg.to_radians(p.player.rot),
		}
	}

	vk.CmdDraw(command_buffer, 6, 1, 0, 0)
}

draw_shader_entity :: proc(command_buffer: vk.CommandBuffer) {
	window_width, window_height := glfw.GetWindowSize(gfx.window)
	scissor := vk.Rect2D {
		offset = { 0, 0 },
		extent = { cast(u32)window_width, cast(u32)window_height },
	}
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

	viewport := vk.Viewport {
		x = 0,
		y = 0,
		width = cast(f32)window_width,
		height = cast(f32)window_height,
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

	#no_bounds_check descriptor_sets := [?]vk.DescriptorSet {
		shader_entity.descriptor_sets[gfx.draw.current_frame],
		shader_entity.texture_set,
	}
	vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, shader_entity.pipeline_layout, 0, len(descriptor_sets), raw_data(&descriptor_sets), 0, nil)
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, shader_entity.pipeline)

	projection_matrix := linalg.matrix4_perspective_f32(fovy = 70, aspect = cast(f32)window_width / cast(f32)window_height, near = 0.01, far = GROUND_SCALE)

	// Modify entity buffer
	player := p.player
	for entity, idx in sa.slice(&p.entities) {
		#no_bounds_check entity_buffer := cast(^Shader_Entity_Buffer)shader_entity.entity_buffer_ptrs[gfx.draw.current_frame]

		translate_matrix := matrix[4, 4]f32 {
			1, 0, 0, entity.pos.x - player.pos.x,
			0, 1, 0, 1,
			0, 0, 1, entity.pos.z - player.pos.z,
			0, 0, 0, 1,
		}

		rot_y_amount := linalg.to_radians(player.rot)
		orbit_y_matrix := matrix[4, 4]f32 {
			linalg.cos(rot_y_amount), 0, linalg.sin(rot_y_amount), 0,
			0, 1, 0, 0,
			-linalg.sin(rot_y_amount), 0, linalg.cos(rot_y_amount), 0,
			0, 0, 0, 1,
		}
		rotate_y_matrix := matrix[4, 4]f32 {
			linalg.cos(rot_y_amount), 0, -linalg.sin(rot_y_amount), 0,
			0, 1, 0, 0,
			linalg.sin(rot_y_amount), 0, linalg.cos(rot_y_amount), 0,
			0, 0, 0, 1,
		}

		entity_buffer.mvp[idx] = projection_matrix * orbit_y_matrix * translate_matrix * rotate_y_matrix
	}

	vk.CmdDraw(command_buffer, vertexCount=6, instanceCount=cast(u32)sa.len(p.entities), firstVertex=0, firstInstance=0)
}

draw_shader_fist :: proc(command_buffer: vk.CommandBuffer) {
	window_width, window_height := glfw.GetWindowSize(gfx.window)
	scissor := vk.Rect2D {
		offset = { 0, 0 },
		extent = { cast(u32)window_width, cast(u32)window_height },
	}
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

	viewport := vk.Viewport {
		x = 0,
		y = 0,
		width = cast(f32)window_width,
		height = cast(f32)window_height,
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

	#no_bounds_check descriptor_sets := [?]vk.DescriptorSet {
		shader_fist.descriptor_sets[gfx.draw.current_frame],
		shader_fist.texture_set,
	}
	vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, shader_fist.pipeline_layout, 0, len(descriptor_sets), raw_data(&descriptor_sets), 0, nil)
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, shader_fist.pipeline)

	{
		#no_bounds_check fist := cast(^Shader_Fist)shader_fist.buffer_ptrs[gfx.draw.current_frame]

		fist.aspect_ratio = cast(f32)window_width / cast(f32)window_height
		fist.offset = 1 if time.duration_milliseconds(time.diff(p.player.attack_timestamp, time.now())) <= 200 else 0
	}

	vk.CmdDraw(command_buffer, vertexCount = 6, instanceCount = 1, firstVertex = 0, firstInstance = 0)
}
