module gltf;

import std::collections::object;
import std::io;
import std::math;
import std::math::vector;
import std::collections::list;
import std::encoding::json;
import std::collections::map;
import std::core::string;

// --- Find by name ---

fn Skin? Gltf.find_skin(Gltf* self, String name)
{
	foreach (data : self.skins)
	{
		if (data.name == name)
		{
			return data;
		}
	}
	return KEY_NOT_FOUND~;
}

fn Animation? Gltf.find_animation(Gltf* self, String name)
{
	foreach (data : self.animations)
	{
		if (data.name == name)
		{
			return data;
		}
	}
	return KEY_NOT_FOUND~;
}

fn uint? Gltf.find_animation_index(Gltf* self, String name)
{
	foreach (uint index, data : self.animations)
	{
		if (data.name == name)
		{
			return index;
		}
	}
	return KEY_NOT_FOUND~;
}

fn List{uint} Gltf.find_skin_animations(Gltf self, uint skin_index, Allocator allocator = mem)
{
	gltf::Skin skin = self.skins[skin_index];

	List{uint} results;
	results.init(allocator);
	foreach ANIMATIONS: (uint index, animation : self.animations)
	{
		foreach (joint_index : skin.joints)
		{
			gltf::Node joint_node = self.nodes[joint_index];

			foreach (channel : animation.channels)
			{
				uint node_index = channel.target.node;
				Node channel_node = self.nodes[node_index];

				if (channel_node.name == joint_node.name)
				{
					results.push(index);
					continue ANIMATIONS;
				}
			}
		}
	}

	return results;
}

macro bool Animation.equals(self, Animation b) @operator(==) => self.name == b.name;

fn usz Gltf.get_offset(&self, ulong attribute)
{
	Accessor accessor = self.accessors[(usz)attribute];
	BufferView bufferView = self.bufferViews[accessor.view];
	return accessor.offset + bufferView.offset;
}

fn BufferView Gltf.get_view(&self, ulong attribute)
{
	Accessor accessor = self.accessors[(usz)attribute];
	BufferView bufferView = self.bufferViews[accessor.view];
	return bufferView;
}

// --- AABB / Bounding box ---

struct Aabb
{
	Vec3 min;
	Vec3 max;
}

fn Vec3 Aabb.center(self) => (self.min + self.max) * 0.5;
fn Vec3 Aabb.size(self) => self.max - self.min;
fn Vec3 Aabb.extents(self) => (self.max - self.min) * 0.5;

fn Aabb Aabb.merge(self, Aabb other)
{
	return {
		.min = {
			math::min(self.min[0], other.min[0]),
			math::min(self.min[1], other.min[1]),
			math::min(self.min[2], other.min[2]),
		},
		.max = {
			math::max(self.max[0], other.max[0]),
			math::max(self.max[1], other.max[1]),
			math::max(self.max[2], other.max[2]),
		},
	};
}

fn Aabb Aabb.transform(self, Matrix4f mat)
{
	// Transform all 8 corners and compute new AABB
	Vec3[8] corners = {
		{ self.min[0], self.min[1], self.min[2] },
		{ self.max[0], self.min[1], self.min[2] },
		{ self.min[0], self.max[1], self.min[2] },
		{ self.max[0], self.max[1], self.min[2] },
		{ self.min[0], self.min[1], self.max[2] },
		{ self.max[0], self.min[1], self.max[2] },
		{ self.min[0], self.max[1], self.max[2] },
		{ self.max[0], self.max[1], self.max[2] },
	};

	Vec4 first = mat.apply({ corners[0][0], corners[0][1], corners[0][2], 1.0 });
	Vec3 new_min = { first[0], first[1], first[2] };
	Vec3 new_max = new_min;

	for (int i = 1; i < 8; i++)
	{
		Vec4 p = mat.apply({ corners[i][0], corners[i][1], corners[i][2], 1.0 });
		Vec3 p3 = { p[0], p[1], p[2] };
		new_min = { math::min(new_min[0], p3[0]), math::min(new_min[1], p3[1]), math::min(new_min[2], p3[2]) };
		new_max = { math::max(new_max[0], p3[0]), math::max(new_max[1], p3[1]), math::max(new_max[2], p3[2]) };
	}

	return { new_min, new_max };
}

// Get AABB from a primitive's POSITION accessor min/max
fn Aabb Gltf.primitive_aabb(&self, Primitive primitive)
{
	usz? pos_attr = primitive.attributes.get("POSITION");
	if (try pos_attr)
	{
		Accessor acc = self.accessors[pos_attr];
		return { .min = acc.min.xyz, .max = acc.max.xyz };
	}
	return { };
}

// Get AABB for entire mesh (union of all primitives)
fn Aabb Gltf.mesh_aabb(&self, Mesh mesh)
{
	Aabb result;
	bool first = true;

	foreach (primitive : mesh.primitives)
	{
		Aabb prim_aabb = self.primitive_aabb(primitive);
		if (first)
		{
			result = prim_aabb;
			first = false;
		}
		else
		{
			result = result.merge(prim_aabb);
		}
	}

	return result;
}

// Get world-space AABB for a node (applies global transform)
fn Aabb Gltf.node_world_aabb(&self, Node node)
{
	if (node.mesh < 0)
	{
		return { };
	}
	Mesh mesh = self.meshes[(uint)node.mesh];
	Aabb local = self.mesh_aabb(mesh);
	return local.transform(node.global_matrix());
}

// --- Material helpers ---

fn bool Material.has_base_color_texture(self) => self.baseColorTexture.source >= 0;
fn bool Material.has_metallic_roughness_texture(self) => self.metallicRoughnessTexture.source >= 0;
fn bool Material.has_normal_map(self) => self.normalTexture.source >= 0;
fn bool Material.has_occlusion_texture(self) => self.occlusionTexture.source >= 0;
fn bool Material.has_emissive_texture(self) => self.emissiveTexture.source >= 0;
fn bool Material.is_opaque(self) => self.alphaMode == OPAQUE;
fn bool Material.is_transparent(self) => self.alphaMode == BLEND;
fn bool Material.is_masked(self) => self.alphaMode == MASK || self.alphaMode == CUTOFF;

fn uint Material.texture_count(self)
{
	uint count = 0;
	bool[] checks = {self.has_base_color_texture() || self.has_normal_map() || self.has_occlusion_texture() || self.has_emissive_texture()};
	foreach (item: checks) if (item) count++;
	return count;
}

// --- Camera helpers ---

fn Matrix4f Camera.projection_matrix(self, float aspect_override)
{
	float aspect = aspect_override > 0 ? aspect_override : self.perspective.aspectRatio;
	float fov = self.perspective.yfov;
	float near = self.perspective.znear;
	float far = self.perspective.zfar;

	float tan_half_fov = (float)math::tan((double)fov * 0.5);
	float f = 1.0f / tan_half_fov;

	if (far > 0)
	{
		// Finite perspective
		float range_inv = 1.0f / (near - far);
		return {
			f / aspect, 0, 0, 0,
			0, f, 0, 0,
			0, 0, (far + near) * range_inv, 2.0 * far * near * range_inv,
			0, 0, -1, 0,
			};
	}
	else
	{
		// Infinite perspective (zfar = 0 means infinite)
		return {
			f / aspect, 0, 0, 0,
			0, f, 0, 0,
			0, 0, -1, -2.0 * near,
			0, 0, -1, 0,
			};
	}
}

// --- Node world transform decomposition ---

fn Vec3 Node.world_position(self)
{
	Matrix4f m = self.global_matrix();
	return { m.m03, m.m13, m.m23 };
}

macro float @col_len(float a, float b, float c) => (float)math::sqrt((double)(a * a + b * b + c * c));

fn Vec3 Node.world_scale(self)
{
	Matrix4f m = self.global_matrix();
	float sx = @col_len(m.m00, m.m10, m.m20);
	float sy = @col_len(m.m01, m.m11, m.m21);
	float sz = @col_len(m.m02, m.m12, m.m22);
	return { sx, sy, sz };
}

fn Quaternionf Node.world_rotation(self)
{
	Matrix4f m = self.global_matrix();
	// Extract rotation by removing scale
	float sx = @col_len(m.m00, m.m10, m.m20);
	float sy = @col_len(m.m01, m.m11, m.m21);
	float sz = @col_len(m.m02, m.m12, m.m22);

	if (sx == 0 || sy == 0 || sz == 0)
	{
		return { .v = { 0, 0, 0, 1 } };
	}

	// Normalized rotation matrix columns
	float r00 = m.m00 / sx;
	float r01 = m.m01 / sy;
	float r02 = m.m02 / sz;
	float r10 = m.m10 / sx;
	float r11 = m.m11 / sy;
	float r12 = m.m12 / sz;
	float r20 = m.m20 / sx;
	float r21 = m.m21 / sy;
	float r22 = m.m22 / sz;

	float trace = r00 + r11 + r22;
	Quaternionf q;
	if (trace > 0)
	{
		float s = 0.5f / (float)(float)math::sqrt((double)(double)trace + 1.0);
		q.v = { (r21 - r12) * s, (r02 - r20) * s, (r10 - r01) * s, 0.25f / s };
	}
	else if (r00 > r11 && r00 > r22)
	{
		float s = 2.0f * (float)math::sqrt((double)1.0 + r00 - r11 - r22);
		q.v = { 0.25f * s, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s };
	}
	else if (r11 > r22)
	{
		float s = 2.0f * (float)math::sqrt((double)1.0 + r11 - r00 - r22);
		q.v = { (r01 + r10) / s, 0.25f * s, (r12 + r21) / s, (r02 - r20) / s };
	}
	else
	{
		float s = 2.0f * (float)math::sqrt((double)1.0 + r22 - r00 - r11);
		q.v = { (r02 + r20) / s, (r12 + r21) / s, 0.25f * s, (r10 - r01) / s };
	}
	return q;
}

// --- Animation helpers ---

fn float Animation.duration(self) => self.max_time - self.min_time;

fn double Animation.loop_time(self, double time)
{
	float dur = self.duration();
	if (dur <= 0)
	{
		return self.min_time;
	}
	double t = time - self.min_time;
	t = t - math::floor(t / dur) * dur;
	return t + self.min_time;
}

fn double Animation.clamp_time(self, double time)
{
	if (time < self.min_time)
	{
		return self.min_time;
	}
	if (time > self.max_time)
	{
		return self.max_time;
	}
	return time;
}

// --- Extension helpers ---

fn bool Gltf.has_extension(&self, String name)
{
	foreach (ext : self.extensions)
	{
		if (ext == name)
		{
			return true;
		}
	}
	return false;
}

// --- Vertex layout descriptor ---

struct VertexAttribute
{
	String name;
	AccessorType type;
	DataType data_type;
	usz offset;
	uint stride;
	uint count;
	bool normalized;
}

struct VertexLayout
{
	VertexAttribute[16] attributes;
	uint attribute_count;
	uint vertex_count;
}

fn VertexLayout Gltf.primitive_layout(&self, Primitive primitive)
{
	VertexLayout layout;

	primitive.attributes.@each(; String name, usz accessor_index)
	{
		if (name != "indices" && layout.attribute_count < 16)
		{
			Accessor acc = self.accessors[accessor_index];
			BufferView view = self.bufferViews[acc.view];

			layout.attributes[layout.attribute_count] = {
				.name = name,
				.type = acc.type,
				.data_type = acc.data_type,
				.offset = acc.offset + view.offset,
				.stride = view.byteStride > 0 ? view.byteStride : (uint)acc.stride(),
				.count = acc.count,
				.normalized = acc.normalize,
			};
			layout.attribute_count++;

			if (acc.count > layout.vertex_count)
			{
				layout.vertex_count = acc.count;
			}
		}
	};

	return layout;
}

// --- Animation pointer resolution ---

fn void PointerTarget.free(&self)
{
	if (self.property.len > 0) self.property.free(mem);
	if (self.raw.len > 0) self.raw.free(mem);
}

fn PointerTarget Gltf.resolve_pointer(Gltf* self, String pointer)
{
	PointerTarget result;
	result.raw = pointer.copy(mem);
	result.property = "";
	result.category = CUSTOM;
	result.index = 0;
	result.type = SCALAR;

	if (pointer.len < 2 || pointer[0] != '/')
	{
		return result;
	}

	usz? slash1 = pointer.index_of_char_from('/', 1);
	if (try slash1)
	{
		String first = pointer[1..(slash1 - 1)];

		switch (first)
		{
			case "nodes":
				{
					usz? slash2 = pointer.index_of_char_from('/', slash1 + 1);
					if (try slash2)
					{
						result.index = (uint)(pointer[slash1 + 1..(slash2 - 1)].to_uint() ?? 0u);
						result.category = NODE;
						String property_path = pointer[slash2 + 1..];
						result.property = property_path.copy(mem);

						switch (property_path)
						{
							case "translation": result.type = VEC3;
							case "rotation": result.type = VEC4;
							case "scale": result.type = VEC3;
							case "weights": result.type = SCALAR;
							default:
								if (property_path.starts_with("weights/"))
								{
									result.type = SCALAR;
								}
						}
					}
				}
			case "materials":
				{
					usz? slash2 = pointer.index_of_char_from('/', slash1 + 1);
					if (try slash2)
					{
						result.index = (uint)(pointer[slash1 + 1..(slash2 - 1)].to_uint() ?? 0u);
						result.category = MATERIAL;
						String property_path = pointer[slash2 + 1..];
						result.property = property_path.copy(mem);

						switch (property_path)
						{
							case "alphaCutoff": result.type = SCALAR;
							case "emissiveFactor": result.type = VEC3;
							case "pbrMetallicRoughness/baseColorFactor": result.type = VEC4;
							case "pbrMetallicRoughness/metallicFactor": result.type = SCALAR;
							case "pbrMetallicRoughness/roughnessFactor": result.type = SCALAR;
							case "normalTexture/scale": result.type = SCALAR;
							case "occlusionTexture/strength": result.type = SCALAR;
							case "normalTexture/extensions/KHR_texture_transform/offset": result.category = TEXTURE_TRANSFORM; result.type = VEC2;
							case "normalTexture/extensions/KHR_texture_transform/rotation": result.category = TEXTURE_TRANSFORM; result.type = SCALAR;
							case "normalTexture/extensions/KHR_texture_transform/scale": result.category = TEXTURE_TRANSFORM; result.type = VEC2;
							case "occlusionTexture/extensions/KHR_texture_transform/offset": result.category = TEXTURE_TRANSFORM; result.type = VEC2;
							case "occlusionTexture/extensions/KHR_texture_transform/rotation": result.category = TEXTURE_TRANSFORM; result.type = SCALAR;
							case "occlusionTexture/extensions/KHR_texture_transform/scale": result.category = TEXTURE_TRANSFORM; result.type = VEC2;
							case "emissiveTexture/extensions/KHR_texture_transform/offset": result.category = TEXTURE_TRANSFORM; result.type = VEC2;
							case "emissiveTexture/extensions/KHR_texture_transform/rotation": result.category = TEXTURE_TRANSFORM; result.type = SCALAR;
							case "emissiveTexture/extensions/KHR_texture_transform/scale": result.category = TEXTURE_TRANSFORM; result.type = VEC2;
							case "pbrMetallicRoughness/baseColorTexture/extensions/KHR_texture_transform/offset": result.category = TEXTURE_TRANSFORM; result.type = VEC2;
							case "pbrMetallicRoughness/baseColorTexture/extensions/KHR_texture_transform/rotation": result.category = TEXTURE_TRANSFORM; result.type = SCALAR;
							case "pbrMetallicRoughness/baseColorTexture/extensions/KHR_texture_transform/scale": result.category = TEXTURE_TRANSFORM; result.type = VEC2;
							case "pbrMetallicRoughness/metallicRoughnessTexture/extensions/KHR_texture_transform/offset": result.category = TEXTURE_TRANSFORM; result.type = VEC2;
							case "pbrMetallicRoughness/metallicRoughnessTexture/extensions/KHR_texture_transform/rotation": result.category = TEXTURE_TRANSFORM; result.type = SCALAR;
							case "pbrMetallicRoughness/metallicRoughnessTexture/extensions/KHR_texture_transform/scale": result.category = TEXTURE_TRANSFORM; result.type = VEC2;
							default: { }
						}
					}
				}
			case "cameras":
				{
					usz? slash2 = pointer.index_of_char_from('/', slash1 + 1);
					if (try slash2)
					{
						result.index = (uint)(pointer[slash1 + 1..(slash2 - 1)].to_uint() ?? 0u);
						result.category = CAMERA;
						String property_path = pointer[slash2 + 1..];
						result.property = property_path.copy(mem);

						switch (property_path)
						{
							case "perspective/aspectRatio": result.type = SCALAR;
							case "perspective/yfov": result.type = SCALAR;
							case "perspective/zfar": result.type = SCALAR;
							case "perspective/znear": result.type = SCALAR;
							case "orthographic/xmag": result.type = SCALAR;
							case "orthographic/ymag": result.type = SCALAR;
							case "orthographic/zfar": result.type = SCALAR;
							case "orthographic/znear": result.type = SCALAR;
							default: { }
						}
					}
				}
			case "extensions":
				{
					usz? slash2 = pointer.index_of_char_from('/', slash1 + 1);
					if (try slash2)
					{
						String ext_name = pointer[slash1 + 1..(slash2 - 1)];

						switch (ext_name)
						{
							case "KHR_lights_punctual":
								{
									usz? slash3 = pointer.index_of_char_from('/', slash2 + 1);
									if (try slash3)
									{
										String lights_label = pointer[slash2 + 1..(slash3 - 1)];

										switch (lights_label)
										{
											case "lights":
												{
													usz? slash4 = pointer.index_of_char_from('/', slash3 + 1);
													if (try slash4)
													{
														result.index = (uint)(pointer[slash3
															+ 1..(slash4 - 1)].to_uint() ?? 0u);
														result.category = LIGHT;
														String property_path = pointer[slash4 + 1..];
														result.property = property_path.copy(mem);

														switch (property_path)
														{
															case "color": result.type = VEC3;
															case "intensity": result.type = SCALAR;
															case "range": result.type = SCALAR;
															case "spot/innerConeAngle": result.type = SCALAR;
															case "spot/outerConeAngle": result.type = SCALAR;
															default: { }
														}
													}
												}
											default:
												result.property = pointer[slash2 + 1..].copy(mem);
										}
									}
								}
							default:
								result.property = pointer[slash1 + 1..].copy(mem);
						}
					}
				}
			default:
				result.property = pointer[slash1 + 1..].copy(mem);
		}
	}

	return result;
}

fn void Gltf.apply_pointer_value(Gltf* self, PointerTarget target, Vec4 value)
{
	switch (target.category)
	{
		case NODE:
			if (target.index >= self.nodes.len())
			{
				return;
			}
			Node* node = self.nodes.get_ref(target.index);
			switch (target.property)
			{
				case "translation": node.translation = value.xyz;
				case "rotation": node.rotation = { .v = value };
				case "scale": node.scale = value.xyz;
				case "weights":
					{
						if (node.weights.len() == 0 && node.mesh >= 0)
						{
							Mesh mesh = self.meshes[(uint)node.mesh];
							for (usz i = 0; i < mesh.weights.len(); i++)
							{
								node.weights.push(0.0);
							}
						}
						for (usz i = 0; i < node.weights.len(); i++)
						{
							node.weights[i] = value[i];
						}
					}
				default:
					if (target.property.starts_with("weights/"))
					{
						uint? idx = target.property[8..].to_uint();
						if (try idx && (usz)idx < node.weights.len())
						{
							node.weights[idx] = value[0];
						}
					}
			}
		case MATERIAL:
			if (target.index >= self.materials.len())
			{
				return;
			}
			Material* mat = self.materials.get_ref(target.index);
			switch (target.property)
			{
				case "pbrMetallicRoughness/baseColorFactor": mat.baseColorFactor = value;
				case "pbrMetallicRoughness/metallicFactor": mat.metallicFactor = value[0];
				case "pbrMetallicRoughness/roughnessFactor": mat.roughnessFactor = value[0];
				case "emissiveFactor": mat.emissiveFactor = { value[0], value[1], value[2], 1.0 };
				case "alphaCutoff": mat.alphaCutOff = value[0];
				case "emissiveStrength": mat.emissiveStrength = value[0];
				default: { }
			}
		case CAMERA:
			if (target.index >= self.cameras.len())
			{
				return;
			}
			Camera* cam = &self.cameras[target.index];
			switch (target.property)
			{
				case "perspective/yfov": cam.perspective.yfov = value[0];
				case "perspective/znear": cam.perspective.znear = value[0];
				case "perspective/zfar": cam.perspective.zfar = value[0];
				case "perspective/aspectRatio": cam.perspective.aspectRatio = value[0];
				case "orthographic/xmag": cam.perspective.aspectRatio = value[0];
				case "orthographic/ymag": cam.perspective.yfov = value[0];
				case "orthographic/zfar": cam.perspective.zfar = value[0];
				case "orthographic/znear": cam.perspective.znear = value[0];
				default: { }
			}
		case LIGHT:
			if (target.index >= self.lights.len())
			{
				return;
			}
			Light* light = &self.lights[target.index];
			switch (target.property)
			{
				case "color": light.color = { value[0], value[1], value[2] };
				case "intensity": light.intensity = value[0];
				case "range": light.range = value[0];
				case "spot/innerConeAngle": light.inner_cone_angle = value[0];
				case "spot/outerConeAngle": light.outer_cone_angle = value[0];
				default: { }
			}
		case TEXTURE_TRANSFORM:
			self.apply_texture_transform(target, value);
		case CUSTOM:
			break;
	}
}

fn void Gltf.apply_texture_transform(Gltf* self, PointerTarget target, Vec4 value)
{
	if (target.index >= self.materials.len()) return;

	Material* mat = self.materials.get_ref(target.index);
	String prop = target.property;

	switch (prop)
	{
		case "normalTexture/extensions/KHR_texture_transform/offset": mat.normalTexture.offset = value.xy;
		case "normalTexture/extensions/KHR_texture_transform/rotation": mat.normalTexture.rotation = value[0];
		case "normalTexture/extensions/KHR_texture_transform/scale": mat.normalTexture.scale = value.xy;
		case "occlusionTexture/extensions/KHR_texture_transform/offset": mat.occlusionTexture.offset = value.xy;
		case "occlusionTexture/extensions/KHR_texture_transform/rotation": mat.occlusionTexture.rotation = value[0];
		case "occlusionTexture/extensions/KHR_texture_transform/scale": mat.occlusionTexture.scale = value.xy;
		case "emissiveTexture/extensions/KHR_texture_transform/offset": mat.emissiveTexture.offset = value.xy;
		case "emissiveTexture/extensions/KHR_texture_transform/rotation": mat.emissiveTexture.rotation = value[0];
		case "emissiveTexture/extensions/KHR_texture_transform/scale": mat.emissiveTexture.scale = value.xy;
		case "pbrMetallicRoughness/baseColorTexture/extensions/KHR_texture_transform/offset": mat.baseColorTexture.offset = value.xy;
		case "pbrMetallicRoughness/baseColorTexture/extensions/KHR_texture_transform/rotation": mat.baseColorTexture.rotation = value[0];
		case "pbrMetallicRoughness/baseColorTexture/extensions/KHR_texture_transform/scale": mat.baseColorTexture.scale = value.xy;
		case "pbrMetallicRoughness/metallicRoughnessTexture/extensions/KHR_texture_transform/offset": mat.metallicRoughnessTexture.offset = value.xy;
		case "pbrMetallicRoughness/metallicRoughnessTexture/extensions/KHR_texture_transform/rotation": mat.metallicRoughnessTexture.rotation = value[0];
		case "pbrMetallicRoughness/metallicRoughnessTexture/extensions/KHR_texture_transform/scale": mat.metallicRoughnessTexture.scale = value.xy;
		default: { }
	}
}
