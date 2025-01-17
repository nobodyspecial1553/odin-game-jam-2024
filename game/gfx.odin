package game

import "core:fmt"
import "core:log"
import "core:slice"

import "vendor:glfw"
import vk "vendor:vulkan"

import vkjs "../vkjumpstart"

texture_descriptor_pool: vkjs.Texture_Descriptor_Pool

shader_test: struct {
	descriptor_set_layout: vk.DescriptorSetLayout,
	pipeline_layout: vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

GROUND_SCALE :: 40
GROUND_SCALE_HALF :: GROUND_SCALE / 2
Shader_Ground_Screen_Space :: struct {
	mvp: matrix[4, 4]f32,
	ground_scale: [2]f32,
	cam_pos: [2]f32,
	rotation: f32,
}
shader_ground: struct {
	// Samplers
	general_sampler: vk.Sampler,

	// Textures
	textures: []vkjs.Texture,
	texture_set: vk.DescriptorSet,

	// UBO
	screen_space_buffers: [CONCURRENT_FRAMES]vk.Buffer,
	screen_space_buffer_ptrs: [CONCURRENT_FRAMES]rawptr,
	screen_space_buffer_memory: vk.DeviceMemory,

	// Pipeline
	descriptor_pool: vk.DescriptorPool,
	descriptor_sets: [CONCURRENT_FRAMES]vk.DescriptorSet,
	descriptor_set_layout: vk.DescriptorSetLayout,
	pipeline_layout: vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

Shader_Entity_Buffer :: struct {
	mvp: [ENTITY_CAP]matrix[4, 4]f32,
}
shader_entity: struct {
	// Samplers
	general_sampler: vk.Sampler,

	// Textures
	textures: []vkjs.Texture,
	texture_set: vk.DescriptorSet,

	// UBO
	entity_buffers: [CONCURRENT_FRAMES]vk.Buffer,
	entity_buffer_ptrs: [CONCURRENT_FRAMES]rawptr,
	entity_buffer_memory: vk.DeviceMemory,

	// Pipeline
	descriptor_pool: vk.DescriptorPool,
	descriptor_sets: [CONCURRENT_FRAMES]vk.DescriptorSet,
	descriptor_set_layout: vk.DescriptorSetLayout,
	pipeline_layout: vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

Shader_Fist :: struct {
	aspect_ratio: f32,
	offset: i32,
}
shader_fist: struct {
	// Samplers
	general_sampler: vk.Sampler,

	// Textures
	textures: []vkjs.Texture,
	texture_set: vk.DescriptorSet,

	// UBO
	buffers: [CONCURRENT_FRAMES]vk.Buffer,
	buffer_ptrs: [CONCURRENT_FRAMES]rawptr,
	buffer_memory: vk.DeviceMemory,

	// Pipeline
	descriptor_pool: vk.DescriptorPool,
	descriptor_sets: [CONCURRENT_FRAMES]vk.DescriptorSet,
	descriptor_set_layout: vk.DescriptorSetLayout,
	pipeline_layout: vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

create_shaders :: proc() {
	// Bindless Texture Descriptor Pool
	texture_descriptor_pool = vkjs.texture_create_descriptor_pool(gfx.device)

	// Pipelines
	window_width, window_height := glfw.GetWindowSize(gfx.window)
	// General Pipeline Stuff 
	pipeline_viewport := vk.Viewport { 0, 0, cast(f32)window_width, cast(f32)window_height, 0, 1 }
	pipeline_scissor := vk.Rect2D { { 0, 0 }, { cast(u32)window_width, cast(u32)window_height } }

	pipeline_viewport_state_create_info := vk.PipelineViewportStateCreateInfo {
		sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports = &pipeline_viewport,
		scissorCount = 1,
		pScissors = &pipeline_scissor,
	}

	pipeline_dynamic_states := [?]vk.DynamicState {
		.SCISSOR,
		.VIEWPORT,
	}
	pipeline_dynamic_state_create_info := vk.PipelineDynamicStateCreateInfo {
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(pipeline_dynamic_states),
		pDynamicStates = raw_data(&pipeline_dynamic_states),
	}

	pipeline_rasterization_state_create_info := vk.PipelineRasterizationStateCreateInfo {
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode = { .BACK },
		frontFace = .COUNTER_CLOCKWISE,
	}

	pipeline_multisample_state_create_info := vk.PipelineMultisampleStateCreateInfo {
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = { ._1 },
	}

	pipeline_depth_stencil_state_create_info := vk.PipelineDepthStencilStateCreateInfo {
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable = false,
		depthWriteEnable = false,
		depthCompareOp = .LESS,
		depthBoundsTestEnable = false,
	}

	pipeline_color_blend_attachment_state := vk.PipelineColorBlendAttachmentState {
		blendEnable = true,
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ZERO,
		colorBlendOp = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ZERO,
		alphaBlendOp = .ADD,
		colorWriteMask = { .R, .G, .B, .A },
	}
	pipeline_color_blend_state_create_info := vk.PipelineColorBlendStateCreateInfo {
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable = false,
		attachmentCount = 1,
		pAttachments = &pipeline_color_blend_attachment_state,
		blendConstants = { 1, 1, 1, 1 },
	}

	pipeline_rendering_create_info := vk.PipelineRenderingCreateInfo {
		sType = .PIPELINE_RENDERING_CREATE_INFO,
		viewMask = 0,
		colorAttachmentCount = 1,
		pColorAttachmentFormats = &gfx.swapchain.surface_format.format,
		depthAttachmentFormat = gfx.depth_stencil_images.format,
		stencilAttachmentFormat = gfx.depth_stencil_images.format,
	}

	// Test Shader
	{
		descriptor_set_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = 0,
			pBindings = nil,
		}
		vkjs.check_result(vk.CreateDescriptorSetLayout(gfx.device, &descriptor_set_layout_create_info, nil, &shader_test.descriptor_set_layout))

		pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
			sType = .PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount = 1,
			pSetLayouts = &shader_test.descriptor_set_layout,
		}
		vkjs.check_result(vk.CreatePipelineLayout(gfx.device, &pipeline_layout_create_info, nil, &shader_test.pipeline_layout))

		pipeline_stages := [?]vk.PipelineShaderStageCreateInfo {
			{ // Vertex
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = { .VERTEX },
				module = vkjs.create_shader_module_from_spirv_file(gfx.device, "shaders/test/vert.spv"),
				pName = "main",
				pSpecializationInfo = nil,
			},
			{ // Fragment
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = { .FRAGMENT },
				module = vkjs.create_shader_module_from_spirv_file(gfx.device, "shaders/test/frag.spv"),
				pName = "main",
				pSpecializationInfo = nil,
			},
		}
		for stage in pipeline_stages {
			if stage.module == 0 {
				log.panicf("failed to load Test %v shader module!", stage.stage)
			}
		}
		defer {
			for stage in pipeline_stages {
				vk.DestroyShaderModule(gfx.device, stage.module, nil)
			}
		}

		pipeline_vertex_input_binding_descriptions := [?]vk.VertexInputBindingDescription {
		}
		pipeline_vertex_input_attribute_descriptions := [?]vk.VertexInputAttributeDescription {
		}
		pipeline_vertex_input_state_create_info := vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount = cast(u32)len(pipeline_vertex_input_binding_descriptions),
			pVertexBindingDescriptions = raw_data(&pipeline_vertex_input_binding_descriptions),
			vertexAttributeDescriptionCount = cast(u32)len(pipeline_vertex_input_attribute_descriptions),
			pVertexAttributeDescriptions = raw_data(&pipeline_vertex_input_attribute_descriptions),
		}

		pipeline_input_assembly_state_create_info := vk.PipelineInputAssemblyStateCreateInfo {
			sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
		}

		graphics_pipeline_create_info := vk.GraphicsPipelineCreateInfo {
			sType = .GRAPHICS_PIPELINE_CREATE_INFO,
			pNext = &pipeline_rendering_create_info,
			stageCount = cast(u32)len(pipeline_stages),
			pStages = raw_data(&pipeline_stages),
			pVertexInputState = &pipeline_vertex_input_state_create_info,
			pInputAssemblyState = &pipeline_input_assembly_state_create_info,
			pTessellationState = nil,
			pViewportState = &pipeline_viewport_state_create_info,
			pRasterizationState = &pipeline_rasterization_state_create_info,
			pMultisampleState = &pipeline_multisample_state_create_info,
			pDepthStencilState = &pipeline_depth_stencil_state_create_info,
			pColorBlendState = &pipeline_color_blend_state_create_info,
			pDynamicState = &pipeline_dynamic_state_create_info,
			layout = shader_test.pipeline_layout,
		}
		vkjs.check_result(vk.CreateGraphicsPipelines(gfx.device, 0, 1, &graphics_pipeline_create_info, nil, &shader_test.pipeline), "Failed to create Shader Test pipeline!")
	}
	// Shader: Ground
	{
		// Textures
		textures_to_load := [?]string {
			"images/snow.png",
		}
		shader_ground.textures = make([]vkjs.Texture, len(textures_to_load))
		for &texture, idx in shader_ground.textures {
			texture_file_path := textures_to_load[idx]
			texture_load_success: bool = ---
			texture_views := make([]vk.ImageView, 1)
			texture, texture_views[0], texture_load_success = texture_load_from_file(texture_file_path)
			texture.views = texture_views
			if !texture_load_success {
				log.panicf("Failed to load texture: \"%s\"", texture_file_path)
			}
		}
		shader_ground.texture_set = vkjs.texture_allocate_descriptor_set(gfx.device, texture_descriptor_pool, 0, shader_ground.textures[0].views)

		// Sampler
		general_sampler_create_info := vk.SamplerCreateInfo {
			sType = .SAMPLER_CREATE_INFO,
			magFilter = .NEAREST,
			minFilter = .NEAREST,
			mipmapMode = .NEAREST,
			addressModeU = .REPEAT,
			addressModeV = .REPEAT,
			addressModeW = .REPEAT,
			minLod = 0,
			maxLod = vk.LOD_CLAMP_NONE,
		}
		vkjs.check_result(vk.CreateSampler(gfx.device, &general_sampler_create_info, nil, &shader_ground.general_sampler))

		// Buffer Creation
		screen_space_buffer_create_info := vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			size = size_of(Shader_Ground_Screen_Space),
			usage = { .UNIFORM_BUFFER },
			sharingMode = .EXCLUSIVE,
		}
		for &buffer in shader_ground.screen_space_buffers {
			vkjs.check_result(vk.CreateBuffer(gfx.device, &screen_space_buffer_create_info, nil, &buffer))
		}

		// Allocate Memory
		screen_space_buffer_memory_requirements: vk.MemoryRequirements = ---
		vk.GetBufferMemoryRequirements(gfx.device, shader_ground.screen_space_buffers[0], &screen_space_buffer_memory_requirements)
		screen_space_buffer_memory_index := vkjs.get_memory_type_index(screen_space_buffer_memory_requirements.memoryTypeBits, { .HOST_VISIBLE, .HOST_COHERENT }, gfx.physical_device_memory_properties)
		if screen_space_buffer_memory_index == max(u32) {
			log.panic("Unable to find memory type for screen space buffer!")
		}

		shader_ground_screen_space_aligned_size := vkjs.align_value(cast(vk.DeviceSize)size_of(Shader_Ground_Screen_Space), screen_space_buffer_memory_requirements.alignment)
		screen_space_buffer_memory_allocation_size := max(shader_ground_screen_space_aligned_size * CONCURRENT_FRAMES, screen_space_buffer_memory_requirements.size)
		screen_space_buffer_memory_allocate_info := vk.MemoryAllocateInfo {
			sType = .MEMORY_ALLOCATE_INFO,
			allocationSize = screen_space_buffer_memory_allocation_size,
			memoryTypeIndex = screen_space_buffer_memory_index,
		}
		vkjs.check_result(vk.AllocateMemory(gfx.device, &screen_space_buffer_memory_allocate_info, nil, &shader_ground.screen_space_buffer_memory))

		// Bind Memory and Map
		screen_space_buffer_ptr: rawptr = ---
		vkjs.check_result(vk.MapMemory(gfx.device, shader_ground.screen_space_buffer_memory, 0, cast(vk.DeviceSize)vk.WHOLE_SIZE, {}, &screen_space_buffer_ptr))
		#no_bounds_check for i in 0..<CONCURRENT_FRAMES {
			vkjs.check_result(vk.BindBufferMemory(gfx.device, shader_ground.screen_space_buffers[i], shader_ground.screen_space_buffer_memory, cast(vk.DeviceSize)i * shader_ground_screen_space_aligned_size))
			shader_ground.screen_space_buffer_ptrs[i] = rawptr(uintptr(screen_space_buffer_ptr) + cast(uintptr)i * cast(uintptr)shader_ground_screen_space_aligned_size)
		}

		// Pipeline Creation
		descriptor_set_layout_bindings := [?]vk.DescriptorSetLayoutBinding {
			{ // Screen Space
				binding = 0,
				descriptorType = .UNIFORM_BUFFER,
				descriptorCount = 1,
				stageFlags = { .VERTEX },
			},
			{ // General Sampler
				binding = 1,
				descriptorType = .SAMPLER,
				descriptorCount = 1,
				stageFlags = { .FRAGMENT },
			},
		}
		descriptor_set_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = len(descriptor_set_layout_bindings),
			pBindings = raw_data(&descriptor_set_layout_bindings),
		}
		vkjs.check_result(vk.CreateDescriptorSetLayout(gfx.device, &descriptor_set_layout_create_info, nil, &shader_ground.descriptor_set_layout))

		descriptor_pool_sizes := [?]vk.DescriptorPoolSize {
			{
				type = .UNIFORM_BUFFER,
				descriptorCount = CONCURRENT_FRAMES,
			},
			{
				type = .SAMPLER,
				descriptorCount = CONCURRENT_FRAMES,
			},
		}
		descriptor_pool_create_info := vk.DescriptorPoolCreateInfo {
			sType = .DESCRIPTOR_POOL_CREATE_INFO,
			maxSets = CONCURRENT_FRAMES,
			poolSizeCount = len(descriptor_pool_sizes),
			pPoolSizes = raw_data(&descriptor_pool_sizes),
		}
		vkjs.check_result(vk.CreateDescriptorPool(gfx.device, &descriptor_pool_create_info, nil, &shader_ground.descriptor_pool))

		for i in 0..<CONCURRENT_FRAMES {
			descriptor_set_allocate_info := vk.DescriptorSetAllocateInfo {
				sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
				descriptorPool = shader_ground.descriptor_pool,
				descriptorSetCount = 1,
				pSetLayouts = &shader_ground.descriptor_set_layout,
			}
			vkjs.check_result(vk.AllocateDescriptorSets(gfx.device, &descriptor_set_allocate_info, &shader_ground.descriptor_sets[i]))

			screen_space_descriptor_buffer_info := vk.DescriptorBufferInfo {
				buffer = shader_ground.screen_space_buffers[i],
				offset = 0,
				range = cast(vk.DeviceSize)vk.WHOLE_SIZE,
			}

			general_sampler_descriptor_image_info := vk.DescriptorImageInfo {
				sampler = shader_ground.general_sampler,
			}

			write_descriptor_sets := [?]vk.WriteDescriptorSet {
				{ // Screen Space
					sType = .WRITE_DESCRIPTOR_SET,
					dstSet = shader_ground.descriptor_sets[i],
					dstBinding = 0,
					dstArrayElement = 0,
					descriptorCount = 1,
					descriptorType = .UNIFORM_BUFFER,
					pBufferInfo = &screen_space_descriptor_buffer_info,
				},
				{ // Sampler
					sType = .WRITE_DESCRIPTOR_SET,
					dstSet = shader_ground.descriptor_sets[i],
					dstBinding = 1,
					dstArrayElement = 0,
					descriptorCount = 1,
					descriptorType = .SAMPLER,
					pImageInfo = &general_sampler_descriptor_image_info,
				},
			}

			vk.UpdateDescriptorSets(gfx.device, len(write_descriptor_sets), raw_data(&write_descriptor_sets), 0, nil)
		}

		descriptor_set_layouts := [?]vk.DescriptorSetLayout {
			shader_ground.descriptor_set_layout,
			texture_descriptor_pool.set_layout,
		}
		pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
			sType = .PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount = len(descriptor_set_layouts),
			pSetLayouts = raw_data(&descriptor_set_layouts),
		}
		vkjs.check_result(vk.CreatePipelineLayout(gfx.device, &pipeline_layout_create_info, nil, &shader_ground.pipeline_layout))

		pipeline_depth_stencil_state_create_info := vk.PipelineDepthStencilStateCreateInfo {
			sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable = false,
			depthWriteEnable = true,
			depthCompareOp = .LESS,
			depthBoundsTestEnable = false,
		}

		pipeline_stages := [?]vk.PipelineShaderStageCreateInfo {
			{ // Vertex
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = { .VERTEX },
				module = vkjs.create_shader_module_from_spirv_file(gfx.device, "shaders/ground/vert.spv"),
				pName = "main",
				pSpecializationInfo = nil,
			},
			{ // Fragment
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = { .FRAGMENT },
				module = vkjs.create_shader_module_from_spirv_file(gfx.device, "shaders/ground/frag.spv"),
				pName = "main",
				pSpecializationInfo = nil,
			},
		}
		for stage in pipeline_stages {
			if stage.module == 0 {
				log.panicf("failed to load Test %v shader module!", stage.stage)
			}
		}
		defer {
			for stage in pipeline_stages {
				vk.DestroyShaderModule(gfx.device, stage.module, nil)
			}
		}

		pipeline_vertex_input_binding_descriptions := [?]vk.VertexInputBindingDescription {
		}
		pipeline_vertex_input_attribute_descriptions := [?]vk.VertexInputAttributeDescription {
		}
		pipeline_vertex_input_state_create_info := vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount = cast(u32)len(pipeline_vertex_input_binding_descriptions),
			pVertexBindingDescriptions = raw_data(&pipeline_vertex_input_binding_descriptions),
			vertexAttributeDescriptionCount = cast(u32)len(pipeline_vertex_input_attribute_descriptions),
			pVertexAttributeDescriptions = raw_data(&pipeline_vertex_input_attribute_descriptions),
		}

		pipeline_input_assembly_state_create_info := vk.PipelineInputAssemblyStateCreateInfo {
			sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
		}

		graphics_pipeline_create_info := vk.GraphicsPipelineCreateInfo {
			sType = .GRAPHICS_PIPELINE_CREATE_INFO,
			pNext = &pipeline_rendering_create_info,
			stageCount = cast(u32)len(pipeline_stages),
			pStages = raw_data(&pipeline_stages),
			pVertexInputState = &pipeline_vertex_input_state_create_info,
			pInputAssemblyState = &pipeline_input_assembly_state_create_info,
			pTessellationState = nil,
			pViewportState = &pipeline_viewport_state_create_info,
			pRasterizationState = &pipeline_rasterization_state_create_info,
			pMultisampleState = &pipeline_multisample_state_create_info,
			pDepthStencilState = &pipeline_depth_stencil_state_create_info,
			pColorBlendState = &pipeline_color_blend_state_create_info,
			pDynamicState = &pipeline_dynamic_state_create_info,
			layout = shader_ground.pipeline_layout,
		}
		vkjs.check_result(vk.CreateGraphicsPipelines(gfx.device, 0, 1, &graphics_pipeline_create_info, nil, &shader_ground.pipeline), "Failed to create Shader Ground pipeline!")
	}
	// Shader: Entity
	{
		// Textures
		textures_to_load := [?]string {
			"images/penguin.png",
			"images/test.png",
		}
		shader_entity.textures = make([]vkjs.Texture, len(textures_to_load))
		for &texture, idx in shader_entity.textures {
			texture_file_path := textures_to_load[idx]
			texture_load_success: bool = ---
			texture_views := make([]vk.ImageView, 1)
			texture, texture_views[0], texture_load_success = texture_load_from_file(texture_file_path)
			texture.views = texture_views
			if !texture_load_success {
				log.panicf("Failed to load texture: \"%s\"", texture_file_path)
			}
		}
		texture_views := slice.concatenate([][]vk.ImageView { shader_entity.textures[0].views, shader_entity.textures[1].views }, context.temp_allocator)
		shader_entity.texture_set = vkjs.texture_allocate_descriptor_set(gfx.device, texture_descriptor_pool, 0, texture_views)

		// Sampler
		general_sampler_create_info := vk.SamplerCreateInfo {
			sType = .SAMPLER_CREATE_INFO,
			magFilter = .NEAREST,
			minFilter = .NEAREST,
			mipmapMode = .NEAREST,
			addressModeU = .REPEAT,
			addressModeV = .REPEAT,
			addressModeW = .REPEAT,
			minLod = 0,
			maxLod = vk.LOD_CLAMP_NONE,
		}
		vkjs.check_result(vk.CreateSampler(gfx.device, &general_sampler_create_info, nil, &shader_entity.general_sampler))

		// Buffer Creation
		entity_buffer_create_info := vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			size = size_of(Shader_Entity_Buffer),
			usage = { .STORAGE_BUFFER },
			sharingMode = .EXCLUSIVE,
		}
		for &buffer in shader_entity.entity_buffers {
			vkjs.check_result(vk.CreateBuffer(gfx.device, &entity_buffer_create_info, nil, &buffer))
		}

		// Allocate Memory
		entity_buffer_memory_requirements: vk.MemoryRequirements = ---
		vk.GetBufferMemoryRequirements(gfx.device, shader_entity.entity_buffers[0], &entity_buffer_memory_requirements)
		entity_buffer_memory_index := vkjs.get_memory_type_index(entity_buffer_memory_requirements.memoryTypeBits, { .HOST_VISIBLE, .HOST_COHERENT }, gfx.physical_device_memory_properties)
		if entity_buffer_memory_index == max(u32) {
			log.panic("Unable to find memory type for entity buffer!")
		}

		shader_entity_buffer_aligned_size := vkjs.align_value(cast(vk.DeviceSize)size_of(Shader_Entity_Buffer), entity_buffer_memory_requirements.alignment)
		entity_buffer_memory_allocation_size := vkjs.align_value(shader_entity_buffer_aligned_size * CONCURRENT_FRAMES, entity_buffer_memory_requirements.size)
		entity_buffer_memory_allocate_info := vk.MemoryAllocateInfo {
			sType = .MEMORY_ALLOCATE_INFO,
			allocationSize = entity_buffer_memory_allocation_size,
			memoryTypeIndex = entity_buffer_memory_index,
		}
		vkjs.check_result(vk.AllocateMemory(gfx.device, &entity_buffer_memory_allocate_info, nil, &shader_entity.entity_buffer_memory))

		// Bind Memory and Map
		entity_buffer_ptr: rawptr = ---
		vkjs.check_result(vk.MapMemory(gfx.device, shader_entity.entity_buffer_memory, 0, cast(vk.DeviceSize)vk.WHOLE_SIZE, {}, &entity_buffer_ptr))
		for buffer, idx in shader_entity.entity_buffers {
			offset := cast(vk.DeviceSize)idx * shader_entity_buffer_aligned_size
			vkjs.check_result(vk.BindBufferMemory(gfx.device, buffer, shader_entity.entity_buffer_memory, offset))
			shader_entity.entity_buffer_ptrs[idx] = rawptr(uintptr(entity_buffer_ptr) + cast(uintptr)offset)
		}

		// Pipeline Creation
		descriptor_set_layout_bindings := [?]vk.DescriptorSetLayoutBinding {
			{ // Screen Space
				binding = 0,
				descriptorType = .STORAGE_BUFFER,
				descriptorCount = 1,
				stageFlags = { .VERTEX },
			},
			{ // General Sampler
				binding = 1,
				descriptorType = .SAMPLER,
				descriptorCount = 1,
				stageFlags = { .FRAGMENT },
			},
		}
		descriptor_set_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = len(descriptor_set_layout_bindings),
			pBindings = raw_data(&descriptor_set_layout_bindings),
		}
		vkjs.check_result(vk.CreateDescriptorSetLayout(gfx.device, &descriptor_set_layout_create_info, nil, &shader_entity.descriptor_set_layout))

		descriptor_pool_sizes := [?]vk.DescriptorPoolSize {
			{
				type = .STORAGE_BUFFER,
				descriptorCount = CONCURRENT_FRAMES,
			},
			{
				type = .SAMPLER,
				descriptorCount = CONCURRENT_FRAMES,
			},
		}
		descriptor_pool_create_info := vk.DescriptorPoolCreateInfo {
			sType = .DESCRIPTOR_POOL_CREATE_INFO,
			maxSets = CONCURRENT_FRAMES,
			poolSizeCount = len(descriptor_pool_sizes),
			pPoolSizes = raw_data(&descriptor_pool_sizes),
		}
		vkjs.check_result(vk.CreateDescriptorPool(gfx.device, &descriptor_pool_create_info, nil, &shader_entity.descriptor_pool))

		for i in 0..<CONCURRENT_FRAMES {
			descriptor_set_allocate_info := vk.DescriptorSetAllocateInfo {
				sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
				descriptorPool = shader_entity.descriptor_pool,
				descriptorSetCount = 1,
				pSetLayouts = &shader_entity.descriptor_set_layout,
			}
			vkjs.check_result(vk.AllocateDescriptorSets(gfx.device, &descriptor_set_allocate_info, &shader_entity.descriptor_sets[i]))

			entity_descriptor_buffer_info := vk.DescriptorBufferInfo {
				buffer = shader_entity.entity_buffers[i],
				offset = 0,
				range = cast(vk.DeviceSize)vk.WHOLE_SIZE,
			}

			general_sampler_descriptor_image_info := vk.DescriptorImageInfo {
				sampler = shader_entity.general_sampler,
			}

			write_descriptor_sets := [?]vk.WriteDescriptorSet {
				{ // Entity Buffers
					sType = .WRITE_DESCRIPTOR_SET,
					dstSet = shader_entity.descriptor_sets[i],
					dstBinding = 0,
					dstArrayElement = 0,
					descriptorCount = 1,
					descriptorType = .STORAGE_BUFFER,
					pBufferInfo = &entity_descriptor_buffer_info,
				},
				{ // Sampler
					sType = .WRITE_DESCRIPTOR_SET,
					dstSet = shader_entity.descriptor_sets[i],
					dstBinding = 1,
					dstArrayElement = 0,
					descriptorCount = 1,
					descriptorType = .SAMPLER,
					pImageInfo = &general_sampler_descriptor_image_info,
				},
			}

			vk.UpdateDescriptorSets(gfx.device, len(write_descriptor_sets), raw_data(&write_descriptor_sets), 0, nil)
		}

		descriptor_set_layouts := [?]vk.DescriptorSetLayout {
			shader_entity.descriptor_set_layout,
			texture_descriptor_pool.set_layout,
		}
		pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
			sType = .PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount = len(descriptor_set_layouts),
			pSetLayouts = raw_data(&descriptor_set_layouts),
		}
		vkjs.check_result(vk.CreatePipelineLayout(gfx.device, &pipeline_layout_create_info, nil, &shader_entity.pipeline_layout))

		pipeline_depth_stencil_state_create_info := vk.PipelineDepthStencilStateCreateInfo {
			sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable = true,
			depthWriteEnable = true,
			depthCompareOp = .LESS,
			depthBoundsTestEnable = false,
		}

		pipeline_color_blend_attachment_state := vk.PipelineColorBlendAttachmentState {
			blendEnable = true,
			srcColorBlendFactor = .SRC_ALPHA,
			dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
			colorBlendOp = .ADD,
			srcAlphaBlendFactor = .ONE,
			dstAlphaBlendFactor = .ZERO,
			alphaBlendOp = .ADD,
			colorWriteMask = { .R, .G, .B, .A },
		}
		pipeline_color_blend_state_create_info := vk.PipelineColorBlendStateCreateInfo {
			sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			logicOpEnable = false,
			attachmentCount = 1,
			pAttachments = &pipeline_color_blend_attachment_state,
			blendConstants = { 1, 1, 1, 1 },
		}

		pipeline_stages := [?]vk.PipelineShaderStageCreateInfo {
			{ // Vertex
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = { .VERTEX },
				module = vkjs.create_shader_module_from_spirv_file(gfx.device, "shaders/entity/vert.spv"),
				pName = "main",
				pSpecializationInfo = nil,
			},
			{ // Fragment
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = { .FRAGMENT },
				module = vkjs.create_shader_module_from_spirv_file(gfx.device, "shaders/entity/frag.spv"),
				pName = "main",
				pSpecializationInfo = nil,
			},
		}
		for stage in pipeline_stages {
			if stage.module == 0 {
				log.panicf("failed to load Test %v shader module!", stage.stage)
			}
		}
		defer {
			for stage in pipeline_stages {
				vk.DestroyShaderModule(gfx.device, stage.module, nil)
			}
		}

		pipeline_vertex_input_binding_descriptions := [?]vk.VertexInputBindingDescription {
		}
		pipeline_vertex_input_attribute_descriptions := [?]vk.VertexInputAttributeDescription {
		}
		pipeline_vertex_input_state_create_info := vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount = cast(u32)len(pipeline_vertex_input_binding_descriptions),
			pVertexBindingDescriptions = raw_data(&pipeline_vertex_input_binding_descriptions),
			vertexAttributeDescriptionCount = cast(u32)len(pipeline_vertex_input_attribute_descriptions),
			pVertexAttributeDescriptions = raw_data(&pipeline_vertex_input_attribute_descriptions),
		}

		pipeline_input_assembly_state_create_info := vk.PipelineInputAssemblyStateCreateInfo {
			sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
		}

		graphics_pipeline_create_info := vk.GraphicsPipelineCreateInfo {
			sType = .GRAPHICS_PIPELINE_CREATE_INFO,
			pNext = &pipeline_rendering_create_info,
			stageCount = cast(u32)len(pipeline_stages),
			pStages = raw_data(&pipeline_stages),
			pVertexInputState = &pipeline_vertex_input_state_create_info,
			pInputAssemblyState = &pipeline_input_assembly_state_create_info,
			pTessellationState = nil,
			pViewportState = &pipeline_viewport_state_create_info,
			pRasterizationState = &pipeline_rasterization_state_create_info,
			pMultisampleState = &pipeline_multisample_state_create_info,
			pDepthStencilState = &pipeline_depth_stencil_state_create_info,
			pColorBlendState = &pipeline_color_blend_state_create_info,
			pDynamicState = &pipeline_dynamic_state_create_info,
			layout = shader_entity.pipeline_layout,
		}
		vkjs.check_result(vk.CreateGraphicsPipelines(gfx.device, 0, 1, &graphics_pipeline_create_info, nil, &shader_entity.pipeline), "Failed to create Shader Entity pipeline!")
	}
	// Shader: Fist
	{
		// Textures
		textures_to_load := [?]string {
			"images/fist.png",
		}
		shader_fist.textures = make([]vkjs.Texture, len(textures_to_load))
		for &texture, idx in shader_fist.textures {
			texture_file_path := textures_to_load[idx]
			texture_load_success: bool = ---
			texture_views := make([]vk.ImageView, 1)
			texture, texture_views[0], texture_load_success = texture_load_from_file(texture_file_path)
			texture.views = texture_views
			if !texture_load_success {
				log.panicf("Failed to load texture: \"%s\"", texture_file_path)
			}
		}
		shader_fist.texture_set = vkjs.texture_allocate_descriptor_set(gfx.device, texture_descriptor_pool, 0, shader_fist.textures[0].views)

		// Sampler
		general_sampler_create_info := vk.SamplerCreateInfo {
			sType = .SAMPLER_CREATE_INFO,
			magFilter = .NEAREST,
			minFilter = .NEAREST,
			mipmapMode = .NEAREST,
			addressModeU = .REPEAT,
			addressModeV = .REPEAT,
			addressModeW = .REPEAT,
			minLod = 0,
			maxLod = vk.LOD_CLAMP_NONE,
		}
		vkjs.check_result(vk.CreateSampler(gfx.device, &general_sampler_create_info, nil, &shader_fist.general_sampler))

		// Buffer Creation
		buffer_create_info := vk.BufferCreateInfo {
			sType = .BUFFER_CREATE_INFO,
			size = size_of(Shader_Entity_Buffer),
			usage = { .UNIFORM_BUFFER },
			sharingMode = .EXCLUSIVE,
		}
		for &buffer in shader_fist.buffers {
			vkjs.check_result(vk.CreateBuffer(gfx.device, &buffer_create_info, nil, &buffer))
		}

		// Allocate Memory
		buffer_memory_requirements: vk.MemoryRequirements = ---
		vk.GetBufferMemoryRequirements(gfx.device, shader_fist.buffers[0], &buffer_memory_requirements)
		buffer_memory_index := vkjs.get_memory_type_index(buffer_memory_requirements.memoryTypeBits, { .HOST_VISIBLE, .HOST_COHERENT }, gfx.physical_device_memory_properties)
		if buffer_memory_index == max(u32) {
			log.panic("Unable to find memory type for fist buffer!")
		}

		shader_buffer_aligned_size := vkjs.align_value(cast(vk.DeviceSize)size_of(Shader_Entity_Buffer), buffer_memory_requirements.alignment)
		buffer_memory_allocation_size := vkjs.align_value(shader_buffer_aligned_size * CONCURRENT_FRAMES, buffer_memory_requirements.size)
		buffer_memory_allocate_info := vk.MemoryAllocateInfo {
			sType = .MEMORY_ALLOCATE_INFO,
			allocationSize = buffer_memory_allocation_size,
			memoryTypeIndex = buffer_memory_index,
		}
		vkjs.check_result(vk.AllocateMemory(gfx.device, &buffer_memory_allocate_info, nil, &shader_fist.buffer_memory))

		// Bind Memory and Map
		buffer_ptr: rawptr = ---
		vkjs.check_result(vk.MapMemory(gfx.device, shader_fist.buffer_memory, 0, cast(vk.DeviceSize)vk.WHOLE_SIZE, {}, &buffer_ptr))
		for buffer, idx in shader_fist.buffers {
			offset := cast(vk.DeviceSize)idx * shader_buffer_aligned_size
			vkjs.check_result(vk.BindBufferMemory(gfx.device, buffer, shader_fist.buffer_memory, offset))
			shader_fist.buffer_ptrs[idx] = rawptr(uintptr(buffer_ptr) + cast(uintptr)offset)
		}

		// Pipeline Creation
		descriptor_set_layout_bindings := [?]vk.DescriptorSetLayoutBinding {
			{ // Screen Space
				binding = 0,
				descriptorType = .UNIFORM_BUFFER,
				descriptorCount = 1,
				stageFlags = { .VERTEX },
			},
			{ // General Sampler
				binding = 1,
				descriptorType = .SAMPLER,
				descriptorCount = 1,
				stageFlags = { .FRAGMENT },
			},
		}
		descriptor_set_layout_create_info := vk.DescriptorSetLayoutCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = len(descriptor_set_layout_bindings),
			pBindings = raw_data(&descriptor_set_layout_bindings),
		}
		vkjs.check_result(vk.CreateDescriptorSetLayout(gfx.device, &descriptor_set_layout_create_info, nil, &shader_fist.descriptor_set_layout))

		descriptor_pool_sizes := [?]vk.DescriptorPoolSize {
			{
				type = .UNIFORM_BUFFER,
				descriptorCount = CONCURRENT_FRAMES,
			},
			{
				type = .SAMPLER,
				descriptorCount = CONCURRENT_FRAMES,
			},
		}
		descriptor_pool_create_info := vk.DescriptorPoolCreateInfo {
			sType = .DESCRIPTOR_POOL_CREATE_INFO,
			maxSets = CONCURRENT_FRAMES,
			poolSizeCount = len(descriptor_pool_sizes),
			pPoolSizes = raw_data(&descriptor_pool_sizes),
		}
		vkjs.check_result(vk.CreateDescriptorPool(gfx.device, &descriptor_pool_create_info, nil, &shader_fist.descriptor_pool))

		for i in 0..<CONCURRENT_FRAMES {
			descriptor_set_allocate_info := vk.DescriptorSetAllocateInfo {
				sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
				descriptorPool = shader_fist.descriptor_pool,
				descriptorSetCount = 1,
				pSetLayouts = &shader_fist.descriptor_set_layout,
			}
			vkjs.check_result(vk.AllocateDescriptorSets(gfx.device, &descriptor_set_allocate_info, &shader_fist.descriptor_sets[i]))

			descriptor_buffer_info := vk.DescriptorBufferInfo {
				buffer = shader_fist.buffers[i],
				offset = 0,
				range = cast(vk.DeviceSize)vk.WHOLE_SIZE,
			}

			general_sampler_descriptor_image_info := vk.DescriptorImageInfo {
				sampler = shader_fist.general_sampler,
			}

			write_descriptor_sets := [?]vk.WriteDescriptorSet {
				{ // Entity Buffers
					sType = .WRITE_DESCRIPTOR_SET,
					dstSet = shader_fist.descriptor_sets[i],
					dstBinding = 0,
					dstArrayElement = 0,
					descriptorCount = 1,
					descriptorType = .UNIFORM_BUFFER,
					pBufferInfo = &descriptor_buffer_info,
				},
				{ // Sampler
					sType = .WRITE_DESCRIPTOR_SET,
					dstSet = shader_fist.descriptor_sets[i],
					dstBinding = 1,
					dstArrayElement = 0,
					descriptorCount = 1,
					descriptorType = .SAMPLER,
					pImageInfo = &general_sampler_descriptor_image_info,
				},
			}

			vk.UpdateDescriptorSets(gfx.device, len(write_descriptor_sets), raw_data(&write_descriptor_sets), 0, nil)
		}

		descriptor_set_layouts := [?]vk.DescriptorSetLayout {
			shader_fist.descriptor_set_layout,
			texture_descriptor_pool.set_layout,
		}
		pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
			sType = .PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount = len(descriptor_set_layouts),
			pSetLayouts = raw_data(&descriptor_set_layouts),
		}
		vkjs.check_result(vk.CreatePipelineLayout(gfx.device, &pipeline_layout_create_info, nil, &shader_fist.pipeline_layout))

		pipeline_depth_stencil_state_create_info := vk.PipelineDepthStencilStateCreateInfo {
			sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable = false,
			depthWriteEnable = false,
			depthCompareOp = .LESS,
			depthBoundsTestEnable = false,
		}

		pipeline_color_blend_attachment_state := vk.PipelineColorBlendAttachmentState {
			blendEnable = true,
			srcColorBlendFactor = .SRC_ALPHA,
			dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
			colorBlendOp = .ADD,
			srcAlphaBlendFactor = .ONE,
			dstAlphaBlendFactor = .ZERO,
			alphaBlendOp = .ADD,
			colorWriteMask = { .R, .G, .B, .A },
		}
		pipeline_color_blend_state_create_info := vk.PipelineColorBlendStateCreateInfo {
			sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			logicOpEnable = false,
			attachmentCount = 1,
			pAttachments = &pipeline_color_blend_attachment_state,
			blendConstants = { 1, 1, 1, 1 },
		}

		pipeline_stages := [?]vk.PipelineShaderStageCreateInfo {
			{ // Vertex
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = { .VERTEX },
				module = vkjs.create_shader_module_from_spirv_file(gfx.device, "shaders/fist/vert.spv"),
				pName = "main",
				pSpecializationInfo = nil,
			},
			{ // Fragment
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = { .FRAGMENT },
				module = vkjs.create_shader_module_from_spirv_file(gfx.device, "shaders/fist/frag.spv"),
				pName = "main",
				pSpecializationInfo = nil,
			},
		}
		for stage in pipeline_stages {
			if stage.module == 0 {
				log.panicf("failed to load Test %v shader module!", stage.stage)
			}
		}
		defer {
			for stage in pipeline_stages {
				vk.DestroyShaderModule(gfx.device, stage.module, nil)
			}
		}

		pipeline_vertex_input_binding_descriptions := [?]vk.VertexInputBindingDescription {
		}
		pipeline_vertex_input_attribute_descriptions := [?]vk.VertexInputAttributeDescription {
		}
		pipeline_vertex_input_state_create_info := vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount = cast(u32)len(pipeline_vertex_input_binding_descriptions),
			pVertexBindingDescriptions = raw_data(&pipeline_vertex_input_binding_descriptions),
			vertexAttributeDescriptionCount = cast(u32)len(pipeline_vertex_input_attribute_descriptions),
			pVertexAttributeDescriptions = raw_data(&pipeline_vertex_input_attribute_descriptions),
		}

		pipeline_input_assembly_state_create_info := vk.PipelineInputAssemblyStateCreateInfo {
			sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
		}

		graphics_pipeline_create_info := vk.GraphicsPipelineCreateInfo {
			sType = .GRAPHICS_PIPELINE_CREATE_INFO,
			pNext = &pipeline_rendering_create_info,
			stageCount = cast(u32)len(pipeline_stages),
			pStages = raw_data(&pipeline_stages),
			pVertexInputState = &pipeline_vertex_input_state_create_info,
			pInputAssemblyState = &pipeline_input_assembly_state_create_info,
			pTessellationState = nil,
			pViewportState = &pipeline_viewport_state_create_info,
			pRasterizationState = &pipeline_rasterization_state_create_info,
			pMultisampleState = &pipeline_multisample_state_create_info,
			pDepthStencilState = &pipeline_depth_stencil_state_create_info,
			pColorBlendState = &pipeline_color_blend_state_create_info,
			pDynamicState = &pipeline_dynamic_state_create_info,
			layout = shader_fist.pipeline_layout,
		}
		vkjs.check_result(vk.CreateGraphicsPipelines(gfx.device, 0, 1, &graphics_pipeline_create_info, nil, &shader_fist.pipeline), "Failed to create Shader Fist pipeline!")
	}
}

destroy_shaders :: proc() {
	vk.DeviceWaitIdle(gfx.device)

	// Shader: Test
	{
		if shader_test.pipeline != 0 {
			vk.DestroyPipeline(gfx.device, shader_test.pipeline, nil)
		}
		if shader_test.pipeline_layout != 0 {
			vk.DestroyPipelineLayout(gfx.device, shader_test.pipeline_layout, nil)
		}
		if shader_test.descriptor_set_layout != 0 {
			vk.DestroyDescriptorSetLayout(gfx.device, shader_test.descriptor_set_layout, nil)
		}
	}
	// Shader: Ground
	{
		// Sampler
		if shader_ground.general_sampler != 0 {
			vk.DestroySampler(gfx.device, shader_ground.general_sampler, nil)
		}

		// Textures
		for texture in shader_ground.textures {
			vkjs.texture_destroy(gfx.device, texture)
			delete(texture.views)
		}
		delete(shader_ground.textures)

		// UBO
		for buffer in shader_ground.screen_space_buffers {
			if buffer != 0 {
				vk.DestroyBuffer(gfx.device, buffer, nil)
			}
		}
		if shader_ground.screen_space_buffer_memory != 0 {
			vk.FreeMemory(gfx.device, shader_ground.screen_space_buffer_memory, nil)
		}

		// Pipeline
		if shader_ground.pipeline != 0 {
			vk.DestroyPipeline(gfx.device, shader_ground.pipeline, nil)
		}
		if shader_ground.pipeline_layout != 0 {
			vk.DestroyPipelineLayout(gfx.device, shader_ground.pipeline_layout, nil)
		}
		if shader_ground.descriptor_set_layout != 0 {
			vk.DestroyDescriptorSetLayout(gfx.device, shader_ground.descriptor_set_layout, nil)
		}
		if shader_ground.descriptor_pool != 0 {
			vk.DestroyDescriptorPool(gfx.device, shader_ground.descriptor_pool, nil)
		}
	}
	// Shader: Entity
	{
		// Sampler
		if shader_entity.general_sampler != 0 {
			vk.DestroySampler(gfx.device, shader_entity.general_sampler, nil)
		}

		// Textures
		for texture in shader_entity.textures {
			vkjs.texture_destroy(gfx.device, texture)
			delete(texture.views)
		}
		delete(shader_entity.textures)

		// UBO
		for buffer in shader_entity.entity_buffers {
			if buffer != 0 {
				vk.DestroyBuffer(gfx.device, buffer, nil)
			}
		}
		if shader_entity.entity_buffer_memory != 0 {
			vk.FreeMemory(gfx.device, shader_entity.entity_buffer_memory, nil)
		}

		// Pipeline
		if shader_entity.pipeline != 0 {
			vk.DestroyPipeline(gfx.device, shader_entity.pipeline, nil)
		}
		if shader_entity.pipeline_layout != 0 {
			vk.DestroyPipelineLayout(gfx.device, shader_entity.pipeline_layout, nil)
		}
		if shader_entity.descriptor_set_layout != 0 {
			vk.DestroyDescriptorSetLayout(gfx.device, shader_entity.descriptor_set_layout, nil)
		}
		if shader_entity.descriptor_pool != 0 {
			vk.DestroyDescriptorPool(gfx.device, shader_entity.descriptor_pool, nil)
		}
	}
	// Shader: Fist
	{
		// Sampler
		if shader_fist.general_sampler != 0 {
			vk.DestroySampler(gfx.device, shader_fist.general_sampler, nil)
		}

		// Textures
		for texture in shader_fist.textures {
			vkjs.texture_destroy(gfx.device, texture)
			delete(texture.views)
		}
		delete(shader_fist.textures)

		// UBO
		for buffer in shader_fist.buffers {
			if buffer != 0 {
				vk.DestroyBuffer(gfx.device, buffer, nil)
			}
		}
		if shader_fist.buffer_memory != 0 {
			vk.FreeMemory(gfx.device, shader_fist.buffer_memory, nil)
		}

		// Pipeline
		if shader_fist.pipeline != 0 {
			vk.DestroyPipeline(gfx.device, shader_fist.pipeline, nil)
		}
		if shader_fist.pipeline_layout != 0 {
			vk.DestroyPipelineLayout(gfx.device, shader_fist.pipeline_layout, nil)
		}
		if shader_fist.descriptor_set_layout != 0 {
			vk.DestroyDescriptorSetLayout(gfx.device, shader_fist.descriptor_set_layout, nil)
		}
		if shader_fist.descriptor_pool != 0 {
			vk.DestroyDescriptorPool(gfx.device, shader_fist.descriptor_pool, nil)
		}
	}

	// Texture Descriptor Pool
	vkjs.texture_destroy_descriptor_pool(gfx.device, texture_descriptor_pool)
}
