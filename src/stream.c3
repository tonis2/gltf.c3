module gltf;

import std::io;
import std::io::file;
import std::io::file::mmap;
import std::core::mem;
import std::core::mem::allocator;
import std::core::string;
import std::math;
import std::math::matrix;
import std::math::vector;
import std::collections::list;
import std::encoding::base64;

enum LoadState
{
	UNLOADED,
	MMAP,
	HEAP,
}

struct BufferSlot
{
	LoadState state;
	uint ref_count;
	char* ptr;
	usz len;
	void* mmap_handle; // Opaque handle for cleanup (FileMmap* on POSIX)
	char[] data; // Only used when state == HEAP
}

struct ImageSlot
{
	LoadState state;
	uint ref_count;
	char[] data;
}

struct GltfStream
{
	Gltf gltf;
	String source_path;
	String source_dir;
	bool is_glb;
	usz glb_binary_offset;
	usz glb_binary_length;
	BufferSlot[] buffer_slots;
	ImageSlot[] image_slots;
	Allocator allocator;
}

fn GltfStream? open(String path, Allocator allocator = mem)
{
	File? file = file::open(path, "r");
	defer file.close()!!;

	if (catch err = file)
	{
		io::printfn("Failed to find the gltf file");
		return FILE_NOT_FOUND~;
	}

	ParseResult result = parse_metadata(&file, allocator)!;

	GltfStream stream;
	stream.gltf = result.gltf;
	stream.is_glb = result.is_glb;
	stream.glb_binary_offset = result.glb_binary_offset;
	stream.glb_binary_length = result.glb_binary_length;
	stream.allocator = allocator;

	// Store path and compute source directory
	stream.source_path = path.copy(allocator);

	usz sep_pos = path.rindex_of_char('/') ?? path.rindex_of_char('\\') ?? 0;
	if (sep_pos > 0)
	{
		stream.source_dir = path[..sep_pos].copy(allocator);
	}
	else
	{
		stream.source_dir = ".".copy(allocator);
	}

	// Initialize buffer slots
	usz num_buffers = stream.gltf.buffers.len();
	if (num_buffers > 0)
	{
		stream.buffer_slots = alloc::new_array(allocator, BufferSlot, num_buffers);
	}

	// Initialize image slots
	usz num_images = stream.gltf.images.len();
	if (num_images > 0)
	{
		stream.image_slots = alloc::new_array(allocator, ImageSlot, num_images);
	}

	return stream;
}

fn void GltfStream.close(&self)
{
	self.unload_all_buffers();
	self.unload_all_images();

	if (self.buffer_slots.len > 0)
	{
		alloc::free(self.allocator, self.buffer_slots);
	}
	if (self.image_slots.len > 0)
	{
		alloc::free(self.allocator, self.image_slots);
	}

	self.source_path.free(self.allocator);
	self.source_dir.free(self.allocator);
	self.gltf.free();
}

// --- Buffer loading ---

fn void? GltfStream.load_buffer(&self, uint index)
{
	BufferSlot* slot = &self.buffer_slots[index];

	if (slot.state != UNLOADED)
	{
		slot.ref_count += 1;
		return;
	}

	Buffer buffer = self.gltf.buffers[index];

	switch (buffer.type)
	{
		case ENCODED_BIN:
			// GLB embedded binary -- mmap or read the binary chunk
			usz file_offset = self.glb_binary_offset + buffer.source_offset;
			$if env::LIBC &&& env::POSIX:
				file::mmap::FileMmap* mm = alloc::new(self.allocator, file::mmap::FileMmap);
				*mm = file::mmap_open(self.source_path, "r", file_offset, buffer.size)!;
				slot.ptr = (char*)mm.vm.ptr + mm.offset;
				slot.len = buffer.size;
				slot.mmap_handle = mm;
				slot.state = MMAP;
			$else
				// Fallback: read into heap
				File file = file::open(self.source_path, "r")!;
				defer file.close()!!;
				slot.data = alloc::new_array(self.allocator, char, buffer.size);
				file.seek(file_offset, Seek.SET)!;
				file.read(slot.data)!;
				slot.ptr = slot.data.ptr;
				slot.len = buffer.size;
				slot.state = HEAP;
			$endif

		case EXTERNAL_BIN:
			// External .bin file
			String bin_path = string::tformat("%s/%s", self.source_dir, buffer.uri);
			$if env::LIBC &&& env::POSIX:
				file::mmap::FileMmap* mm = alloc::new(self.allocator, file::mmap::FileMmap);
				*mm = file::mmap_open(bin_path, "r")!;
				slot.ptr = (char*)mm.vm.ptr + mm.offset;
				slot.len = buffer.size;
				slot.mmap_handle = mm;
				slot.state = MMAP;
			$else
				File file = file::open(bin_path, "r")!;
				defer file.close()!!;
				slot.data = alloc::new_array(self.allocator, char, buffer.size);
				file.read(slot.data)!;
				slot.ptr = slot.data.ptr;
				slot.len = buffer.size;
				slot.state = HEAP;
			$endif

		case ENCODED_BASE64:
			// Decode base64 data from URI
			slot.data = parse_base64(buffer.uri, buffer.size)!;
			slot.ptr = slot.data.ptr;
			slot.len = slot.data.len;
			slot.state = HEAP;
	}

	slot.ref_count = 1;
}

fn void GltfStream.unload_buffer(&self, uint index)
{
	BufferSlot* slot = &self.buffer_slots[index];

	if (slot.state == UNLOADED) return;

	if (slot.ref_count > 1)
	{
		slot.ref_count -= 1;
		return;
	}

	switch (slot.state)
	{
		case MMAP:
			$if env::LIBC &&& env::POSIX:
				file::mmap::FileMmap* mm = slot.mmap_handle;
				mm.destroy()!!;
				alloc::free(self.allocator, mm);
			$endif
		case HEAP:
			if (slot.data.len > 0)
			{
				alloc::free(self.allocator, slot.data);
			}
		default:
	}

	slot.ptr = null;
	slot.len = 0;
	slot.data = { };
	slot.mmap_handle = null;
	slot.state = UNLOADED;
	slot.ref_count = 0;
}

fn bool GltfStream.is_buffer_loaded(&self, uint index) => self.buffer_slots[index].state != UNLOADED;

fn void? GltfStream.load_all_buffers(&self)
{
	foreach (uint i, buffer : self.gltf.buffers)
	{
		self.load_buffer(i)!;
	}
}

fn void GltfStream.unload_all_buffers(&self)
{
	foreach (uint i, buffer : self.buffer_slots)
	{
		self.force_unload_buffer(i);
	}
}

fn void GltfStream.force_unload_buffer(&self, uint index)
{
	BufferSlot* slot = &self.buffer_slots[index];
	if (slot.state == UNLOADED)
	{
		return;
	}

	switch (slot.state)
	{
		case MMAP:
			$if env::LIBC &&& env::POSIX:
				file::mmap::FileMmap* mm = slot.mmap_handle;
				mm.destroy()!!;
				alloc::free(self.allocator, mm);
			$endif
		case HEAP:
			if (slot.data.len > 0)
			{
				alloc::free(self.allocator, slot.data);
			}
		default:
	}

	slot.ptr = null;
	slot.len = 0;
	slot.data = { };
	slot.mmap_handle = null;
	slot.state = UNLOADED;
	slot.ref_count = 0;
}

fn void? GltfStream.load_mesh_buffers(&self, uint mesh_index)
{
	Mesh mesh = self.gltf.meshes[mesh_index];

	foreach (primitive : mesh.primitives)
	{
		primitive.attributes.@each(; String attr_name, usz accessor_index)
		{
			Accessor accessor = self.gltf.accessors[accessor_index];
			BufferView view = self.gltf.bufferViews[accessor.view];
			self.load_buffer(view.buffer)!;
		};
	}
}

fn void? GltfStream.load_animation_buffers(&self, uint anim_index)
{
	Animation animation = self.gltf.animations[anim_index];

	foreach (sampler : animation.samplers)
	{
		// Input accessor (time)
		Accessor input = self.gltf.accessors[sampler.input];
		BufferView input_view = self.gltf.bufferViews[input.view];
		self.load_buffer(input_view.buffer)!;

		// Output accessor (values)
		Accessor output = self.gltf.accessors[sampler.output];
		BufferView output_view = self.gltf.bufferViews[output.view];
		self.load_buffer(output_view.buffer)!;
	}
}

fn void? GltfStream.load_skin_buffers(&self, uint skin_index)
{
	Skin skin = self.gltf.skins[skin_index];
	Accessor accessor = self.gltf.accessors[skin.inverseBindAccessor];
	BufferView view = self.gltf.bufferViews[accessor.view];
	self.load_buffer(view.buffer)!;
}

// --- Image loading ---

fn void? GltfStream.load_image(&self, uint index)
{
	ImageSlot* slot = &self.image_slots[index];

	if (slot.state != UNLOADED)
	{
		slot.ref_count += 1;
		return;
	}

	Image image = self.gltf.images[index];

	switch (image.type)
	{
		case ENCODED_BASE64:
			slot.data = parse_base64(image.uri, image.uri.len)!;

		case ENCODED_BIN:
			// Image data is in a buffer view
			if (image.view >= 0)
			{
				BufferView view = self.gltf.bufferViews[(usz)image.view];
				// Ensure the underlying buffer is loaded
				self.load_buffer(view.buffer)!;

				BufferSlot* buf_slot = &self.buffer_slots[view.buffer];
				// Copy image data from buffer
				slot.data = alloc::new_array(self.allocator, char, view.byteLength);
				mem::copy(slot.data.ptr, buf_slot.ptr + view.offset, view.byteLength);
			}

		case EXTERNAL_BIN:
			String img_path = string::tformat("%s/%s", self.source_dir, (String)image.uri);
			File file = file::open(img_path, "r")!;
			defer file.close()!!;
			usz file_size = file.seek(0, Seek.END)!;
			file.seek(0, Seek.SET)!;
			slot.data = alloc::new_array(self.allocator, char, file_size);
			file.read(slot.data)!;
	}

	slot.state = HEAP;
	slot.ref_count = 1;
}

fn void GltfStream.unload_image(&self, uint index)
{
	ImageSlot* slot = &self.image_slots[index];

	if (slot.state == UNLOADED) return;

	if (slot.ref_count > 1)
	{
		slot.ref_count -= 1;
		return;
	}

	if (slot.data.len > 0)
	{
		alloc::free(self.allocator, slot.data);
	}
	slot.data = { };
	slot.state = UNLOADED;
	slot.ref_count = 0;
}

fn void? GltfStream.load_all_images(&self)
{
	for (uint i = 0; i < (uint)self.gltf.images.len(); i++)
	{
		self.load_image(i)!;
	}
}

fn void GltfStream.unload_all_images(&self)
{
	for (uint i = 0; i < (uint)self.image_slots.len; i++)
	{
		ImageSlot* slot = &self.image_slots[i];
		if (slot.state == UNLOADED)
		{
			continue;
		}
		if (slot.data.len > 0)
		{
			alloc::free(self.allocator, slot.data);
		}
		slot.data = { };
		slot.state = UNLOADED;
		slot.ref_count = 0;
	}
}

fn void? GltfStream.load_material_images(&self, uint mat_index)
{
	Material mat = self.gltf.materials[mat_index];

	if (mat.baseColorTexture.source >= 0)
	{
		self.load_image((uint)mat.baseColorTexture.source)!;
	}
	if (mat.metallicRoughnessTexture.source >= 0)
	{
		self.load_image((uint)mat.metallicRoughnessTexture.source)!;
	}
	if (mat.normalTexture.source >= 0)
	{
		self.load_image((uint)mat.normalTexture.source)!;
	}
	if (mat.occlusionTexture.source >= 0)
	{
		self.load_image((uint)mat.occlusionTexture.source)!;
	}
	if (mat.emissiveTexture.source >= 0)
	{
		self.load_image((uint)mat.emissiveTexture.source)!;
	}
}

// --- Scene-level loading ---

fn void? GltfStream.load_scene(&self, uint scene_index)
{
	Scene scene = self.gltf.scenes[scene_index];

	foreach (node_index : scene.nodes)
	{
		self.load_node_recursive(node_index)!;
	}
}

fn void? GltfStream.load_node_recursive(&self, uint node_index)
{
	Node node = self.gltf.nodes[node_index];

	// Load mesh buffers
	if (node.mesh >= 0)
	{
		self.load_mesh_buffers((uint)node.mesh)!;
	}

	// Load skin buffers
	if (node.skin >= 0)
	{
		self.load_skin_buffers((uint)node.skin)!;
	}

	// Recurse into children
	foreach (child_index : node.children)
	{
		self.load_node_recursive(child_index)!;
	}
}

fn void GltfStream.unload_scene(&self, uint scene_index)
{
	Scene scene = self.gltf.scenes[scene_index];

	foreach (node_index : scene.nodes)
	{
		self.unload_node_recursive(node_index);
	}
}

fn void GltfStream.unload_node_recursive(&self, uint node_index)
{
	Node node = self.gltf.nodes[node_index];

	if (node.mesh >= 0)
	{
		Mesh mesh = self.gltf.meshes[(uint)node.mesh];
		foreach (primitive : mesh.primitives)
		{
			primitive.attributes.@each(; String attr_name, usz accessor_index)
			{
				Accessor accessor = self.gltf.accessors[accessor_index];
				BufferView view = self.gltf.bufferViews[accessor.view];
				self.unload_buffer(view.buffer);
			};
		}
	}

	if (node.skin >= 0)
	{
		Skin skin = self.gltf.skins[(uint)node.skin];
		Accessor accessor = self.gltf.accessors[skin.inverseBindAccessor];
		BufferView view = self.gltf.bufferViews[accessor.view];
		self.unload_buffer(view.buffer);
	}

	foreach (child_index : node.children)
	{
		self.unload_node_recursive(child_index);
	}
}

// --- Name-based convenience ---

fn void? GltfStream.load_mesh_by_name(&self, String name)
{
	foreach (uint i, mesh : self.gltf.meshes)
	{
		if (mesh.name == name)
		{
			self.load_mesh_buffers(i)!;
			return;
		}
	}
	return KEY_NOT_FOUND~;
}

fn void? GltfStream.load_animation_by_name(&self, String name)
{
	foreach (uint i, animation : self.gltf.animations)
	{
		if (animation.name == name)
		{
			self.load_animation_buffers(i)!;
			return;
		}
	}
	return KEY_NOT_FOUND~;
}

fn void? GltfStream.load_scene_by_name(&self, String name)
{
	foreach (uint i, scene : self.gltf.scenes)
	{
		if (scene.name == name)
		{
			self.load_scene(i)!;
			return;
		}
	}
	return KEY_NOT_FOUND~;
}

// --- Data access ---

fn char[]? GltfStream.get_image_data(&self, uint index)
{
	ImageSlot* slot = &self.image_slots[index];
	if (slot.state == UNLOADED) return IMAGE_NOT_LOADED~;
	return slot.data;
}

macro GltfStream.@cast_buffer(&self, #target, usz index, #type)
{
	Accessor accessor;
	$if $typeof(#target).nameof == "Accessor":
		{
			accessor = #target;
		}
	$else
		{
			accessor = self.gltf.accessors[#target]!;
		}
	$endif

	BufferView bufferView = self.gltf.bufferViews[accessor.view];
	usz index_offset = bufferView.byteStride > 0 ? bufferView.byteStride : accessor.stride();
	usz start_offset = accessor.offset + bufferView.offset;

	BufferSlot* slot = &self.buffer_slots[bufferView.buffer];
	char* data_ptr = slot.ptr + start_offset + (index * index_offset);
	return bitcast(*(char[#type.sizeof]*)data_ptr, #type);
}

fn void* GltfStream.get_data_array(&self, Accessor accessor)
{
	BufferView bufferView = self.gltf.bufferViews[accessor.view];
	BufferSlot* slot = &self.buffer_slots[bufferView.buffer];
	usz start_offset = accessor.offset + bufferView.offset;
	return slot.ptr[start_offset..(start_offset + bufferView.byteLength)];
}

fn char* GltfStream.get_data(&self, BufferView view)
{
	BufferSlot* slot = &self.buffer_slots[view.buffer];
	return slot.ptr + view.offset;
}

// --- Ported helper macros ---

macro void GltfStream.@run_animation_channels(
	&self,
	double frame_time,
	gltf::Animation animation; @callback(uint node_index, AnimationProperty path, Vec4 animation_value)
)
{
	foreach (channel : animation.channels)
	{
		if (channel.target.path == POINTER) continue;

		AnimationSampler sampler = animation.samplers[channel.sampler];
		Accessor time_accessor = self.gltf.accessors[sampler.input];
		Accessor value_accessor = self.gltf.accessors[sampler.output];

		float max_frame_time = time_accessor.max[0];
		float min_frame_time = time_accessor.min[0];

		for TIMES: (ulong j; j < time_accessor.count; j++)
		{
			float current_time = self.@cast_buffer(time_accessor, j, float);

			if (current_time > frame_time && frame_time < max_frame_time && current_time > min_frame_time)
			{
				Vec4 current_value = self.@cast_buffer(value_accessor, j, Vec4);

				if (sampler.interpolation == STEP)
				{
					@callback(channel.target.node, channel.target.path, current_value);
				}
				else if (sampler.interpolation == LINEAR)
				{
					AnimationValue prev_value = {
						.time = self.@cast_buffer(time_accessor, j - 1, float),
						.value = self.@cast_buffer(value_accessor, j - 1, Vec4),
					};

					Vec4 new_value;
					float interpolation_value = (float)(frame_time - prev_value.time)
						/ (float)(current_time - prev_value.time);

					switch (channel.target.path)
					{
						case TRANSLATION:
							new_value.xyz = prev_value.value.xyz.lerp(current_value.xyz, interpolation_value).xyz;
						case ROTATION:
							new_value = (Quaternionf) {
								.v = prev_value.value
							}.slerp({ .v = current_value }, interpolation_value).v;
						case SCALE:
							new_value.xyz = prev_value.value.xyz.lerp(current_value.xyz, interpolation_value).xyz;
						default:
							{
							}
					}

					@callback(channel.target.node, channel.target.path, new_value);
				}
				else if (sampler.interpolation == CUBICSPLINE)
				{
					// CUBICSPLINE: each keyframe stores 3 Vec4 values:
					// [in-tangent, value, out-tangent] at indices [j*3, j*3+1, j*3+2]
					float prev_time = self.@cast_buffer(time_accessor, j - 1, float);
					float dt = current_time - prev_time;
					float t = (float)(frame_time - prev_time) / dt;
					float t2 = t * t;
					float t3 = t2 * t;

					// Hermite basis functions
					float h00 = 2 * t3 - 3 * t2 + 1;
					float h10 = t3 - 2 * t2 + t;
					float h01 = -2 * t3 + 3 * t2;
					float h11 = t3 - t2;

					Vec4 prev_val = self.@cast_buffer(value_accessor, (j - 1) * 3 + 1, Vec4);
					Vec4 prev_out_tangent = self.@cast_buffer(value_accessor, (j - 1) * 3 + 2, Vec4);
					Vec4 cur_in_tangent = self.@cast_buffer(value_accessor, j * 3, Vec4);
					Vec4 cur_val = self.@cast_buffer(value_accessor, j * 3 + 1, Vec4);

					Vec4 new_value = prev_val * h00 + prev_out_tangent * (dt * h10) + cur_val * h01
						+ cur_in_tangent * (dt * h11);

					if (channel.target.path == ROTATION)
					{
						// Normalize quaternion result
						float len = math::sqrt(
							new_value[0] * new_value[0] + new_value[1] * new_value[1] + new_value[2] * new_value[2]
								+ new_value[3] * new_value[3]
						);
						if (len > 0)
						{
							new_value = new_value / len;
						}
					}

					@callback(channel.target.node, channel.target.path, new_value);
				}

				break TIMES;
			}
		}
	}
}

macro void GltfStream.@run_pointer_channels(
	&self,
	double frame_time,
	gltf::Animation animation; @callback(String pointer, Vec4 animation_value)
)
{
	foreach (channel : animation.channels)
	{
		if (channel.target.path != POINTER) continue;

		AnimationSampler sampler = animation.samplers[channel.sampler];
		Accessor time_accessor = self.gltf.accessors[sampler.input];
		Accessor value_accessor = self.gltf.accessors[sampler.output];

		float max_frame_time = time_accessor.max[0];
		float min_frame_time = time_accessor.min[0];

		for TIMES: (ulong j; j < time_accessor.count; j++)
		{
			float current_time = self.@cast_buffer(time_accessor, j, float);

			if (current_time > frame_time && frame_time < max_frame_time && current_time > min_frame_time)
			{
				Vec4 current_value = self.@cast_buffer(value_accessor, j, Vec4);

				if (sampler.interpolation == STEP)
				{
					@callback(channel.target.pointer, current_value);
				}
				else if (sampler.interpolation == LINEAR)
				{
					AnimationValue prev_value = {
						.time = self.@cast_buffer(time_accessor, j - 1, float),
						.value = self.@cast_buffer(value_accessor, j - 1, Vec4),
					};

					float interpolation_value = (float)(frame_time - prev_value.time)
						/ (float)(current_time - prev_value.time);

					Vec4 new_value = prev_value.value + (current_value - prev_value.value) * interpolation_value;

					@callback(channel.target.pointer, new_value);
				}
				else if (sampler.interpolation == CUBICSPLINE)
				{
					float prev_time = self.@cast_buffer(time_accessor, j - 1, float);
					float dt = current_time - prev_time;
					float t = (float)(frame_time - prev_time) / dt;
					float t2 = t * t;
					float t3 = t2 * t;

					float h00 = 2 * t3 - 3 * t2 + 1;
					float h10 = t3 - 2 * t2 + t;
					float h01 = -2 * t3 + 3 * t2;
					float h11 = t3 - t2;

					Vec4 prev_val = self.@cast_buffer(value_accessor, (j - 1) * 3 + 1, Vec4);
					Vec4 prev_out_tangent = self.@cast_buffer(value_accessor, (j - 1) * 3 + 2, Vec4);
					Vec4 cur_in_tangent = self.@cast_buffer(value_accessor, j * 3, Vec4);
					Vec4 cur_val = self.@cast_buffer(value_accessor, j * 3 + 1, Vec4);

					Vec4 new_value = prev_val * h00 + prev_out_tangent * (dt * h10) + cur_val * h01
						+ cur_in_tangent * (dt * h11);

					@callback(channel.target.pointer, new_value);
				}

				break TIMES;
			}
		}
	}
}

macro void GltfStream.@build_skin_matrixes(&self, gltf::Skin skin; @callback(uint joint, Matrix4f matrix))
{
	Accessor skin_accessor = self.gltf.accessors[skin.inverseBindAccessor];
	foreach (uint index, joint : skin.joints)
	{
		gltf::Node joint_node = self.gltf.nodes[joint];
		Matrix4f inverse_matrix = self.@cast_buffer(skin_accessor, index, Matrix4f).transpose();
		Matrix4f matrix = joint_node.global_matrix().mul(inverse_matrix).transpose();
		@callback(joint, matrix);
	}
}

macro void? GltfStream.@get_positions(GltfStream* self, Mesh mesh, #type; @callback(position, index))
{
	List{Vec3} positions;
	List{ushort} indices;
	positions.init(mem);
	indices.init(mem);

	defer
	{
		positions.free();
		indices.free();
	}

	foreach (uint prim_index, primitive : mesh.primitives)
	{
		Accessor index_accessor = self.gltf.accessors[primitive.attributes["indices"]!!];
		Accessor pos_accessor = self.gltf.accessors[primitive.attributes["POSITION"]!!];

		for (usz i = 0; i < pos_accessor.count; i++)
		{
			Vec3 position = self.@cast_buffer(pos_accessor, i, Vec3);
			positions.push(position);
		}

		for (usz i = 0; i < index_accessor.count; i++)
		{
			ushort index = self.@cast_buffer(index_accessor, i, ushort);
			indices.push(index);
		}

		$if #type.kindof == ARRAY:
			for (usz i = 0; i < indices.len(); i += #type.len)
			{
				$typefrom(#type.typeid) value;
				for (usz j = 0; j < #type.len; j++)
				{
					usz index = indices[i + j];
					value[j] = positions[index];
				}
				@callback(value, indices);
			}
		$else
			foreach (i, index : indices) @callback(positions[index], i);
		$endif
	}
}

fn void GltfStream.debug_buffer(GltfStream* self, Accessor accessor)
{
	BufferView bufferView = self.gltf.bufferViews[accessor.view];

	for (uint i = 0; i < accessor.count; i += 1)
	{
		BufferSlot* slot = &self.buffer_slots[bufferView.buffer];
		char* data = slot.ptr + (accessor.offset + bufferView.offset + (usz)(i * accessor.stride()));

		switch (accessor.type)
		{
			case AccessorType.SCALAR:
				ushort value = bitcast(*(char[ushort.sizeof]*)data, ushort);
				io::printfn("Parsed scalar %d", value);
			case AccessorType.VEC2:
				Vec2 vec = bitcast(*(char[Vec2.sizeof]*)data, Vec2);
				io::printfn("Parsed Vec2 %f %f", vec.x, vec.y);
			case AccessorType.VEC3:
				Vec3 vec = bitcast(*(char[Vec3.sizeof]*)data, Vec3);
				io::printfn("Parsed Vec3 %f %f %f", vec.x, vec.y, vec.z);
			case AccessorType.VEC4:
				Vec4 vec = bitcast(*(char[Vec4.sizeof]*)data, Vec4);
				io::printfn("Parsed Vec4 %f %f %f %f", vec.x, vec.y, vec.z, vec.w);
			default:
				{
				}
		}
	}

	io::printf(" \n _______ \n");
}

// --- Vertex attribute extraction macros ---

macro void GltfStream.@each_position(&self, Primitive primitive; @callback(Vec3 position, usz index))
{
	usz? attr = primitive.attributes.get("POSITION");
	if (try attr)
	{
		Accessor accessor = self.gltf.accessors[attr];
		for (usz i = 0; i < accessor.count; i++)
		{
			@callback(self.@cast_buffer(accessor, i, Vec3), i);
		}
	}
}

macro void GltfStream.@each_normal(&self, Primitive primitive; @callback(Vec3 normal, usz index))
{
	usz? attr = primitive.attributes.get("NORMAL");
	if (try attr)
	{
		Accessor accessor = self.gltf.accessors[attr];
		for (usz i = 0; i < accessor.count; i++)
		{
			@callback(self.@cast_buffer(accessor, i, Vec3), i);
		}
	}
}

macro void GltfStream.@each_tangent(&self, Primitive primitive; @callback(Vec4 tangent, usz index))
{
	usz? attr = primitive.attributes.get("TANGENT");
	if (try attr)
	{
		Accessor accessor = self.gltf.accessors[attr];
		for (usz i = 0; i < accessor.count; i++)
		{
			@callback(self.@cast_buffer(accessor, i, Vec4), i);
		}
	}
}

macro void GltfStream.@each_texcoord(&self, Primitive primitive, uint set; @callback(Vec2 uv, usz index))
{
	String attr_name = string::tformat("TEXCOORD_%d", set);
	usz? attr = primitive.attributes.get(attr_name);
	if (try attr)
	{
		Accessor accessor = self.gltf.accessors[attr];
		for (usz i = 0; i < accessor.count; i++)
		{
			@callback(self.@cast_buffer(accessor, i, Vec2), i);
		}
	}
}

macro void GltfStream.@each_color(&self, Primitive primitive, uint set; @callback(Vec4 color, usz index))
{
	String attr_name = string::tformat("COLOR_%d", set);
	usz? attr = primitive.attributes.get(attr_name);
	if (try attr)
	{
		Accessor accessor = self.gltf.accessors[attr];
		for (usz i = 0; i < accessor.count; i++)
		{
			@callback(self.@cast_buffer(accessor, i, Vec4), i);
		}
	}
}

macro void GltfStream.@each_joint(&self, Primitive primitive, uint set; @callback(ushort[<4>] joints, usz index))
{
	String attr_name = string::tformat("JOINTS_%d", set);
	usz? attr = primitive.attributes.get(attr_name);
	if (try attr)
	{
		Accessor accessor = self.gltf.accessors[attr];
		for (usz i = 0; i < accessor.count; i++)
		{
			@callback(self.@cast_buffer(accessor, i, ushort[<4>]), i);
		}
	}
}

macro void GltfStream.@each_weight(&self, Primitive primitive, uint set; @callback(Vec4 weights, usz index))
{
	String attr_name = string::tformat("WEIGHTS_%d", set);
	usz? attr = primitive.attributes.get(attr_name);
	if (try attr)
	{
		Accessor accessor = self.gltf.accessors[attr];
		for (usz i = 0; i < accessor.count; i++)
		{
			@callback(self.@cast_buffer(accessor, i, Vec4), i);
		}
	}
}

macro void GltfStream.@each_index_as_ushort(&self, Primitive primitive; @callback(ushort index_val, usz index))
{
	usz? attr = primitive.attributes.get("indices");
	if (try attr)
	{
		Accessor accessor = self.gltf.accessors[attr];
		for (usz i = 0; i < accessor.count; i++)
		{
			@callback(self.@cast_buffer(accessor, i, ushort), i);
		}
	}
}

macro void GltfStream.@each_index_as_uint(&self, Primitive primitive; @callback(uint index_val, usz index))
{
	usz? attr = primitive.attributes.get("indices");
	if (try attr)
	{
		Accessor accessor = self.gltf.accessors[attr];
		for (usz i = 0; i < accessor.count; i++)
		{
			@callback(self.@cast_buffer(accessor, i, uint), i);
		}
	}
}

// --- Scene/node iteration macros ---

// Walk all nodes in a scene depth-first using explicit stack.
macro void GltfStream.@each_node_in_scene(&self, uint scene_index; @callback(Node node, uint node_index))
{
	Scene scene = self.gltf.scenes[scene_index];
	uint[256] stack;
	usz stack_top = 0;

	usz root_count = scene.nodes.len();
	for (usz i = root_count; i > 0; i--)
	{
		stack[stack_top++] = scene.nodes[i - 1];
	}

	while (stack_top > 0)
	{
		uint node_index = stack[--stack_top];
		Node node = self.gltf.nodes[node_index];
		@callback(node, node_index);

		usz child_count = node.children.len();
		for (usz i = child_count; i > 0; i--)
		{
			stack[stack_top++] = node.children[i - 1];
		}
	}
}

macro void GltfStream.@each_mesh_in_scene(
	&self,
	uint scene_index; @callback(Mesh mesh, uint mesh_index, Node node, uint node_index)
)
{
	Scene scene = self.gltf.scenes[scene_index];
	uint[256] stack;
	usz stack_top = 0;

	usz root_count = scene.nodes.len();
	for (usz ri = root_count; ri > 0; ri--)
	{
		stack[stack_top++] = scene.nodes[ri - 1];
	}

	while (stack_top > 0)
	{
		uint node_index = stack[--stack_top];
		Node node = self.gltf.nodes[node_index];
		if (node.mesh >= 0)
		{
			@callback(self.gltf.meshes[(uint)node.mesh], (uint)node.mesh, node, node_index);
		}
		usz child_count = node.children.len();
		for (usz ci = child_count; ci > 0; ci--)
		{
			stack[stack_top++] = node.children[ci - 1];
		}
	}
}

macro void GltfStream.@each_light_in_scene(&self, uint scene_index; @callback(Light light, uint light_index, Node node))
{
	Scene scene = self.gltf.scenes[scene_index];
	uint[256] stack;
	usz stack_top = 0;

	usz root_count = scene.nodes.len();
	for (usz ri = root_count; ri > 0; ri--)
	{
		stack[stack_top++] = scene.nodes[ri - 1];
	}

	while (stack_top > 0)
	{
		uint node_index = stack[--stack_top];
		Node node = self.gltf.nodes[node_index];
		if (node.has_light())
		{
			@callback(self.gltf.lights[node.light], (uint)node.light, node);
		}
		usz child_count = node.children.len();
		for (usz ci = child_count; ci > 0; ci--)
		{
			stack[stack_top++] = node.children[ci - 1];
		}
	}
}

macro void GltfStream.@each_camera_in_scene(
	&self,
	uint scene_index; @callback(Camera camera, uint camera_index, Node node)
)
{
	Scene scene = self.gltf.scenes[scene_index];
	uint[256] stack;
	usz stack_top = 0;

	usz root_count = scene.nodes.len();
	for (usz ri = root_count; ri > 0; ri--)
	{
		stack[stack_top++] = scene.nodes[ri - 1];
	}

	while (stack_top > 0)
	{
		uint node_index = stack[--stack_top];
		Node node = self.gltf.nodes[node_index];
		if (node.has_camera())
		{
			@callback(self.gltf.cameras[node.camera], (uint)node.camera, node);
		}
		usz child_count = node.children.len();
		for (usz ci = child_count; ci > 0; ci--)
		{
			stack[stack_top++] = node.children[ci - 1];
		}
	}
}

// --- Morph target helpers ---

macro void? GltfStream.@each_morph_position(
	&self,
	Primitive primitive,
	uint target_index; @callback(Vec3 delta, usz index)
)
{
	if (target_index < primitive.targets.len())
	{
		AttributeMap target = primitive.targets[target_index];
		usz? attr = target.get("POSITION");
		if (try attr)
		{
			Accessor accessor = self.gltf.accessors[attr];
			for (usz i = 0; i < accessor.count; i++)
			{
				@callback(self.@cast_buffer(accessor, i, Vec3), i);
			}
		}
	}
}

macro void? GltfStream.@each_morph_normal(
	&self,
	Primitive primitive,
	uint target_index; @callback(Vec3 delta, usz index)
)
{
	if (target_index < primitive.targets.len())
	{
		AttributeMap target = primitive.targets[target_index];
		usz? attr = target.get("NORMAL");
		if (try attr)
		{
			Accessor accessor = self.gltf.accessors[attr];
			for (usz i = 0; i < accessor.count; i++)
			{
				@callback(self.@cast_buffer(accessor, i, Vec3), i);
			}
		}
	}
}

// --- CPU skinning ---

fn Vec3 GltfStream.skin_vertex(&self, Vec3 position, ushort[<4>] joints, Vec4 weights, Matrix4f[] joint_matrices)
{
	Vec4 pos = { position[0], position[1], position[2], 1.0 };
	Vec4 skinned = { };

	for (int i = 0; i < 4; i++)
	{
		if (weights[i] > 0.0)
		{
			Matrix4f mat = joint_matrices[joints[i]];
			skinned += mat.apply(pos) * weights[i];
		}
	}

	return { skinned[0], skinned[1], skinned[2] };
}
