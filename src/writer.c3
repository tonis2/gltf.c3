<*
 glTF 2.0 writing — the inverse of the parser in main.c3.

 The parser is built around a file that already exists: it maps a document
 onto structs and hands out views into a buffer someone else laid out. Writing
 is the opposite problem — nothing is laid out yet, and the binary blob, the
 bufferViews indexing into it and the accessors indexing into those all have to
 be produced together and stay consistent. `GltfBuilder` owns that bookkeeping:
 every `add_*` call appends to one growing BIN chunk, registers the view and
 accessor describing what it just wrote, and returns the accessor index to
 reference it by.

     `GltfBuilder builder = gltf::builder();`
     `defer builder.free();`
     `uint positions = builder.add_positions(vertices);`
     `uint indices = builder.add_indices(triangles);`
     `uint mesh = builder.add_mesh("Body");`
     `builder.add_primitive(mesh, {{ "POSITION", positions }}, indices: (int)indices);`
     `builder.add_root(builder.add_node("Body", mesh: (int)mesh));`
     `builder.save_glb("out.glb")!;`

 Writing is deliberately not a round-trip of the read structs. A parsed `Gltf`
 is lossy in the places that matter here — `Primitive.attributes` folds
 `indices`, `material` and `mode` into the same map as the vertex attributes,
 and a `Node` carries both a matrix and a TRS without recording which the file
 authored — so re-emitting one would have to guess. Building from raw data
 instead means what comes out is always a document this library could have
 parsed, which is what writer_test.c3 checks.

 Animations are built the same way — `add_times` and `add_rotations` produce
 the accessors, `add_animation` opens a clip, and `add_sampler` / `add_channel`
 bind the curves to the nodes they drive. Application metadata goes through
 `set_extra`, which writes the root `extras` object the parser reads back into
 `Gltf.extras`.

 See skinning.c3 for the skeleton, weights and inverse bind matrices a rigged
 asset needs on top of this.
*>
module gltf;

import std::io;
import std::io::file;



import std::math;
import std::math::matrix;
import std::math::vector;
import std::math::quaternion;
import std::collections::list;
import std::encoding::base64;

faultdef WRITE_FAILED, NOTHING_TO_WRITE;

const uint GLB_MAGIC      @private = 0x46546C67; // "glTF"
const uint GLB_VERSION    @private = 2;
const uint GLB_CHUNK_JSON @private = 0x4E4F534A; // "JSON"
const uint GLB_CHUNK_BIN  @private = 0x004E4942; // "BIN\0"

const int ARRAY_BUFFER_TARGET         = 34962;
const int ELEMENT_ARRAY_BUFFER_TARGET = 34963;

// Widest value each index type can hold, used to pick the narrowest that fits.
const uint MAX_UBYTE  @private = 255;
const uint MAX_USHORT @private = 65535;

// The glTF componentType constants — the same ones Accessor.from_json decodes.
fn uint DataType.component_type(self)
{
	switch (self)
	{
		case ICHAR:  return 5120;
		case CHAR:   return 5121;
		case SHORT:  return 5122;
		case USHORT: return 5123;
		case UINT:   return 5125;
		case FLOAT:  return 5126;
	}
}

fn String AccessorType.gltf_name(self)
{
	switch (self)
	{
		case SCALAR: return "SCALAR";
		case VEC2:   return "VEC2";
		case VEC3:   return "VEC3";
		case VEC4:   return "VEC4";
		case MAT2:   return "MAT2";
		case MAT3:   return "MAT3";
		case MAT4:   return "MAT4";
	}
}

fn uint AccessorType.component_count(self)
{
	switch (self)
	{
		case SCALAR: return 1;
		case VEC2:   return 2;
		case VEC3:   return 3;
		case VEC4:   return 4;
		case MAT2:   return 4;
		case MAT3:   return 9;
		case MAT4:   return 16;
	}
}

// The spellings Animation.from_json decodes, so a sampler written here comes
// back as the interpolation it was given.
fn String Interpolation.gltf_name(self)
{
	switch (self)
	{
		case LINEAR:      return "LINEAR";
		case STEP:        return "STEP";
		case CUBICSPLINE: return "CUBICSPLINE";
	}
}

<*
 The spellings Animation.from_json decodes for a channel target.

 POINTER is spelled but not writable: the path alone is meaningless without the
 KHR_animation_pointer object naming what it points at, which this writer does
 not emit, so add_channel rejects it rather than producing a file whose target
 resolves to nothing.
*>
fn String AnimationProperty.gltf_name(self)
{
	switch (self)
	{
		case TRANSLATION: return "translation";
		case ROTATION:    return "rotation";
		case SCALE:       return "scale";
		case WEIGHTS:     return "weights";
		case POINTER:     return "pointer";
	}
}

// The spellings Shape.from_json decodes. A shape names its kind twice — once
// as "type" and once as the object its dimensions live in — so this is both.
fn String ShapeType.gltf_name(self)
{
	switch (self)
	{
		case BOX:      return "box";
		case CAPSULE:  return "capsule";
		case CYLINDER: return "cylinder";
		case SPHERE:   return "sphere";
	}
}

// The spellings PhysicsMaterial.from_json decodes.
fn String PhysicsCombine.gltf_name(self)
{
	switch (self)
	{
		case AVERAGE:  return "average";
		case MINIMUM:  return "minimum";
		case MAXIMUM:  return "maximum";
		case MULTIPLY: return "multiply";
	}
}

// The spellings PhysicsJoint.from_json decodes for a drive.
fn String DriveType.gltf_name(self)
{
	switch (self)
	{
		case ANGULAR: return "angular";
		case LINEAR:  return "linear";
	}
}

fn String DriveMode.gltf_name(self)
{
	switch (self)
	{
		case FORCE:        return "force";
		case ACCELERATION: return "acceleration";
	}
}

<*
 One named vertex attribute of a primitive: "POSITION", "JOINTS_0", and so on.

 Kept as an ordered list rather than the `AttributeMap` the parser uses, so
 that two builds of the same data produce byte-identical JSON. A hash map
 would reorder the attributes between runs and make output impossible to diff.
*>
struct WriteAttribute
{
	String name;
	uint accessor;
}

struct WritePrimitive
{
	List{WriteAttribute} attributes;
	int indices;
	int material;
	Mode mode;
}

struct WriteMesh
{
	String name;
	List{WritePrimitive} primitives;
}

struct WriteNode
{
	String name;
	Vec3 translation;
	Vec3 scale;
	Quaternionf rotation;
	int mesh;
	int skin;
	int physics;
	List{uint} children;
}

<*
 The KHR_physics_rigid_bodies object hanging off one node: what the node is as
 a rigid body, what shape it collides with, and what it is jointed to.

 A node holds at most one collider. The parser keeps a single collider index
 per node and reads "collider" and "trigger" into the same slot, so writing
 both would produce a file that reads back as the trigger alone.
*>
struct WriteNodePhysics
{
	bool has_collider;
	bool has_motion;
	bool has_joint;
	Collider collider;
	Motion motion;
	uint connected_node;
	uint joint;
	bool enable_collision;
}

struct WriteSkin
{
	String name;
	int skeleton;
	int inverse_bind;
	List{uint} joints;
}

struct WriteSampler
{
	uint input;
	uint output;
	Interpolation interpolation;
}

struct WriteChannel
{
	uint sampler;
	uint node;
	AnimationProperty path;
}

struct WriteAnimation
{
	String name;
	List{WriteSampler} samplers;
	List{WriteChannel} channels;
}

<*
 One root-level `extras` entry.

 Kept as an ordered list for the reason WriteAttribute gives: a map would
 reorder between runs and make two builds of the same data impossible to diff.
*>
struct WriteExtra
{
	String key;
	String value;
}

<*
 One image, as bytes inside the binary blob.

 A bufferView rather than a URI, because that is the only form a `.glb` can
 carry and the one a `.gltf` can carry too — an external `.png` beside the file
 would be a second thing to copy and a second thing to lose.
*>
struct WriteImage
{
	String name;
	uint view;
	ImageType mime;
}

struct WriteTexture
{
	uint source;
	int sampler;
}

<*
 A metallic-roughness material.

 The subset glTF calls the core PBR model and every consumer implements: a base
 colour, its texture, and the two factors. Normal, occlusion and emissive maps
 are absent because nothing in this writer produces them yet; adding one is a
 field, a parameter and three lines of JSON.
*>
struct WriteMaterial
{
	String name;
	Vec4 base_color;
	float metallic;
	float roughness;
	int base_color_texture;
	bool double_sided;
	AlphaMode alpha_mode;
	float alpha_cutoff;
}

struct WriteSamplerState
{
	MagFilter mag;
	MinFilter min;
	WrapMode wrap_s;
	WrapMode wrap_t;
}

struct WriteView
{
	sz offset;
	sz length;
	uint stride;
	int target;
}

struct WriteAccessor
{
	uint view;
	uint count;
	DataType data_type;
	AccessorType type;
	bool normalized;
	bool has_bounds;
	float[16] min;
	float[16] max;
}

struct GltfBuilder
{
	Allocator allocator;
	DString bin;
	List{WriteView} views;
	List{WriteAccessor} accessors;
	List{WriteMesh} meshes;
	List{WriteNode} nodes;
	List{WriteSkin} skins;
	List{WriteAnimation} animations;
	List{WriteExtra} extras;
	List{uint} roots;

	List{WriteImage} images;
	List{WriteTexture} textures;
	List{WriteMaterial} materials;
	List{WriteSamplerState} samplers;

	List{Shape} shapes;
	List{PhysicsMaterial} physics_materials;
	List{CollisionFilter} collision_filters;
	List{PhysicsJoint} physics_joints;
	List{WriteNodePhysics} node_physics;

	String generator;
}

<*
 @param allocator : `Owns the binary blob and every list; released by free.`
*>
fn GltfBuilder builder(Allocator allocator = mem)
{
	GltfBuilder self;
	self.allocator = allocator;
	self.bin = dstring::new_with_capacity(allocator, 65536);
	self.views.init(allocator);
	self.accessors.init(allocator);
	self.meshes.init(allocator);
	self.nodes.init(allocator);
	self.skins.init(allocator);
	self.animations.init(allocator);
	self.extras.init(allocator);
	self.roots.init(allocator);
	self.images.init(allocator);
	self.textures.init(allocator);
	self.materials.init(allocator);
	self.samplers.init(allocator);
	self.shapes.init(allocator);
	self.physics_materials.init(allocator);
	self.collision_filters.init(allocator);
	self.physics_joints.init(allocator);
	self.node_physics.init(allocator);
	self.generator = "gltf.c3";
	return self;
}

fn void GltfBuilder.free(&self)
{
	self.bin.free();
	self.views.free();
	self.accessors.free();

	foreach (mesh : self.meshes)
	{
		foreach (primitive : mesh.primitives)
		{
			foreach (attribute : primitive.attributes) attribute.name.free(self.allocator);
			primitive.attributes.free();
		}
		mesh.primitives.free();
		mesh.name.free(self.allocator);
	}
	self.meshes.free();

	foreach (node : self.nodes)
	{
		node.children.free();
		node.name.free(self.allocator);
	}
	self.nodes.free();

	foreach (skin : self.skins)
	{
		skin.joints.free();
		skin.name.free(self.allocator);
	}
	self.skins.free();

	foreach (animation : self.animations)
	{
		animation.samplers.free();
		animation.channels.free();
		animation.name.free(self.allocator);
	}
	self.animations.free();

	foreach (extra : self.extras)
	{
		extra.key.free(self.allocator);
		extra.value.free(self.allocator);
	}
	self.extras.free();

	// Freed here rather than through CollisionFilter.free: a filter the parser
	// produced holds names on the heap, while these were copied with whatever
	// allocator the builder was given.
	foreach (filter : self.collision_filters)
	{
		foreach (system : filter.systems) system.free(self.allocator);
		foreach (system : filter.colliding_with) system.free(self.allocator);
		foreach (system : filter.not_colliding) system.free(self.allocator);
		filter.systems.free();
		filter.colliding_with.free();
		filter.not_colliding.free();
	}
	self.collision_filters.free();

	foreach (joint : self.physics_joints) joint.free();
	self.physics_joints.free();

	foreach (physics : self.node_physics)
	{
		if (physics.has_collider) physics.collider.free();
	}
	self.node_physics.free();

	self.physics_materials.free();
	self.shapes.free();

	foreach (image : self.images) image.name.free(self.allocator);
	self.images.free();
	self.textures.free();

	foreach (material : self.materials) material.name.free(self.allocator);
	self.materials.free();
	self.samplers.free();

	self.roots.free();
}

// --- Binary blob ---

// Everything is written little-endian by hand rather than by copying the host
// representation: glTF fixes the byte order, and a big-endian target would
// otherwise produce a file that only it can read.
fn void GltfBuilder.append_u32(&self, uint value)
{
	char[4] bytes = { (char)value, (char)(value >> 8), (char)(value >> 16), (char)(value >> 24) };
	self.bin.append_bytes(bytes[..]);
}

fn void GltfBuilder.append_u16(&self, ushort value)
{
	char[2] bytes = { (char)value, (char)(value >> 8) };
	self.bin.append_bytes(bytes[..]);
}

fn void GltfBuilder.append_f32(&self, float value) => self.append_u32(bitcast(value, uint));

<*
 Pad the blob so the next view starts on a 4-byte boundary. glTF requires each
 accessor to be aligned to its component size, and 4 covers every type this
 writer emits.
*>
fn void GltfBuilder.align_bin(&self)
{
	sz remainder = self.bin.len() % 4;
	if (remainder != 0) self.bin.append_char_repeat(0, 4 - remainder);
}

<*
 Register a bufferView over an array of bytes.

 @param target : `ARRAY_BUFFER_TARGET, ELEMENT_ARRAY_BUFFER_TARGET, or -1 to leave it unstated.`
 @param stride : `Byte stride for interleaved data; 0 means tightly packed.`
*>
fn uint GltfBuilder.add_view(&self, char[] data, int target = -1, uint stride = 0)
{
	sz offset = self.begin_view();
	self.bin.append_bytes(data);
	return self.end_view(offset, target, stride);
}

fn uint GltfBuilder.add_accessor(&self, uint view, DataType data_type, AccessorType type, uint count, bool normalized = false)
{
	self.accessors.push({
		.view = view,
		.count = count,
		.data_type = data_type,
		.type = type,
		.normalized = normalized,
	});
	return (uint)self.accessors.len() - 1;
}

// Open a view, letting the caller append into the blob directly, and close it
// over whatever was written. Saves materialising a byte array for data that is
// generated element by element.
fn sz GltfBuilder.begin_view(&self)
{
	self.align_bin();
	return self.bin.len();
}

fn uint GltfBuilder.end_view(&self, sz offset, int target = -1, uint stride = 0)
{
	self.views.push({ .offset = offset, .length = self.bin.len() - offset, .stride = stride, .target = target });
	return (uint)self.views.len() - 1;
}

// --- Typed vertex data ---

<*
 Vertex positions, with the min/max bounds glTF requires on POSITION.

 @return `The accessor index to reference this data by.`
*>
fn uint GltfBuilder.add_positions(&self, Vec3[] data)
{
	uint index = self.add_vec3(data);

	WriteAccessor* accessor = self.accessors.get_ref(index);
	accessor.has_bounds = true;
	if (data.len == 0) return index;

	Vec3 low = data[0];
	Vec3 high = data[0];
	foreach (value : data)
	{
		low = { math::min(low.x, value.x), math::min(low.y, value.y), math::min(low.z, value.z) };
		high = { math::max(high.x, value.x), math::max(high.y, value.y), math::max(high.z, value.z) };
	}
	accessor.min[0] = low.x;  accessor.min[1] = low.y;  accessor.min[2] = low.z;
	accessor.max[0] = high.x; accessor.max[1] = high.y; accessor.max[2] = high.z;
	return index;
}

fn uint GltfBuilder.add_vec3(&self, Vec3[] data)
{
	sz offset = self.begin_view();
	foreach (value : data)
	{
		self.append_f32(value.x);
		self.append_f32(value.y);
		self.append_f32(value.z);
	}
	return self.add_accessor(self.end_view(offset, ARRAY_BUFFER_TARGET), FLOAT, VEC3, (uint)data.len);
}

fn uint GltfBuilder.add_vec2(&self, Vec2[] data)
{
	sz offset = self.begin_view();
	foreach (value : data)
	{
		self.append_f32(value.x);
		self.append_f32(value.y);
	}
	return self.add_accessor(self.end_view(offset, ARRAY_BUFFER_TARGET), FLOAT, VEC2, (uint)data.len);
}

fn uint GltfBuilder.add_vec4(&self, Vec4[] data)
{
	sz offset = self.begin_view();
	foreach (value : data)
	{
		self.append_f32(value.x);
		self.append_f32(value.y);
		self.append_f32(value.z);
		self.append_f32(value.w);
	}
	return self.add_accessor(self.end_view(offset, ARRAY_BUFFER_TARGET), FLOAT, VEC4, (uint)data.len);
}

<*
 Triangle indices. Narrowed to 16-bit when the mesh is small enough, which
 halves the index data and is what most exporters emit.
*>
fn uint GltfBuilder.add_indices(&self, uint[] data)
{
	bool narrow = true;
	foreach (value : data)
	{
		if (value > MAX_USHORT) { narrow = false; break; }
	}

	sz offset = self.begin_view();
	if (narrow)
	{
		foreach (value : data) self.append_u16((ushort)value);
	}
	else
	{
		foreach (value : data) self.append_u32(value);
	}
	uint view = self.end_view(offset, ELEMENT_ARRAY_BUFFER_TARGET);
	return self.add_accessor(view, narrow ? DataType.USHORT : DataType.UINT, SCALAR, (uint)data.len);
}

<*
 Column-major 4x4 matrices — the layout glTF and this library's Matrix4f
 share, so the 16 floats go out in storage order.
*>
fn uint GltfBuilder.add_matrices(&self, Matrix4f[] data)
{
	sz offset = self.begin_view();
	foreach (value : data)
	{
		for (uint i = 0; i < 16; i++) self.append_f32(value.m[i]);
	}
	return self.add_accessor(self.end_view(offset), FLOAT, MAT4, (uint)data.len);
}

<*
 Joint indices, four per vertex. Written as unsigned bytes when the skeleton
 fits in them, which is the common case and what most engines expect.

 @param data : `4 entries per vertex, indexing the skin's joints array.`
*>
fn uint GltfBuilder.add_joints(&self, ushort[] data)
{
	bool narrow = true;
	foreach (value : data)
	{
		if (value > MAX_UBYTE) { narrow = false; break; }
	}

	sz offset = self.begin_view();
	if (narrow)
	{
		foreach (value : data) self.bin.append_char((char)value);
	}
	else
	{
		foreach (value : data) self.append_u16(value);
	}
	uint view = self.end_view(offset, ARRAY_BUFFER_TARGET);
	return self.add_accessor(view, narrow ? DataType.CHAR : DataType.USHORT, VEC4, (uint)(data.len / 4));
}

<*
 Skin weights, four per vertex, matching the joints written alongside them.
*>
fn uint GltfBuilder.add_weights(&self, float[] data)
{
	sz offset = self.begin_view();
	foreach (value : data) self.append_f32(value);
	uint view = self.end_view(offset, ARRAY_BUFFER_TARGET);
	return self.add_accessor(view, FLOAT, VEC4, (uint)(data.len / 4));
}

// --- Animation data ---
//
// None of these tag their bufferView with a target. glTF reserves target for
// vertex and index data, and says a view without one holds animation or skin
// data — so borrowing add_vec3 for a translation track would write a file every
// validator complains about.

<*
 Key times for an animation sampler, in seconds.

 Carries min and max, which glTF requires of a sampler input and which is how a
 reader knows a clip's duration without walking the buffer.

 @param data : `Ascending times; a sampler pairs these with one value each.`
 @return `The accessor index to pass to add_sampler as its input.`
*>
fn uint GltfBuilder.add_times(&self, float[] data)
{
	sz offset = self.begin_view();
	foreach (value : data) self.append_f32(value);
	uint index = self.add_accessor(self.end_view(offset), FLOAT, SCALAR, (uint)data.len);

	WriteAccessor* accessor = self.accessors.get_ref(index);
	accessor.has_bounds = true;
	if (data.len == 0) return index;

	float low = data[0];
	float high = data[0];
	foreach (value : data)
	{
		low = math::min(low, value);
		high = math::max(high, value);
	}
	accessor.min[0] = low;
	accessor.max[0] = high;
	return index;
}

<*
 Rotation keys, one quaternion per key time.

 @return `The accessor index to pass to add_sampler as its output.`
*>
fn uint GltfBuilder.add_rotations(&self, Quaternionf[] data)
{
	sz offset = self.begin_view();
	foreach (value : data)
	{
		self.append_f32(value.v[0]);
		self.append_f32(value.v[1]);
		self.append_f32(value.v[2]);
		self.append_f32(value.v[3]);
	}
	return self.add_accessor(self.end_view(offset), FLOAT, VEC4, (uint)data.len);
}

<*
 Translation or scale keys, one vector per key time.

 @return `The accessor index to pass to add_sampler as its output.`
*>
fn uint GltfBuilder.add_vectors(&self, Vec3[] data)
{
	sz offset = self.begin_view();
	foreach (value : data)
	{
		self.append_f32(value.x);
		self.append_f32(value.y);
		self.append_f32(value.z);
	}
	return self.add_accessor(self.end_view(offset), FLOAT, VEC3, (uint)data.len);
}

// --- Scene graph ---

fn uint GltfBuilder.add_mesh(&self, String name)
{
	WriteMesh mesh;
	mesh.name = name.copy(self.allocator);
	mesh.primitives.init(self.allocator);
	self.meshes.push(mesh);
	return (uint)self.meshes.len() - 1;
}

<*
 Attach a primitive to a mesh.

 @param mesh : `Index returned by add_mesh.`
 @param attributes : `Named accessor indices — at minimum POSITION.`
 @param indices : `Accessor index for the index buffer, or -1 for a non-indexed draw.`
 @param material : `Material index, or -1 for none.`
*>
fn void GltfBuilder.add_primitive(&self, uint mesh, WriteAttribute[] attributes, int indices = -1, int material = -1, Mode mode = TRIANGLES)
{
	WritePrimitive primitive;
	primitive.attributes.init(self.allocator);
	primitive.indices = indices;
	primitive.material = material;
	primitive.mode = mode;

	foreach (attribute : attributes)
	{
		primitive.attributes.push({ .name = attribute.name.copy(self.allocator), .accessor = attribute.accessor });
	}

	self.meshes.get_ref(mesh).primitives.push(primitive);
}

<*
 @param mesh : `Mesh index this node draws, or -1.`
 @param skin : `Skin index deforming that mesh, or -1.`
*>
fn uint GltfBuilder.add_node(&self, String name, int mesh = -1, int skin = -1,
	Vec3 translation = { 0, 0, 0 }, Quaternionf rotation = { 0, 0, 0, 1 }, Vec3 scale = { 1, 1, 1 })
{
	WriteNode node;
	node.name = name.copy(self.allocator);
	node.translation = translation;
	node.rotation = rotation;
	node.scale = scale;
	node.mesh = mesh;
	node.skin = skin;
	node.physics = -1;
	node.children.init(self.allocator);
	self.nodes.push(node);
	return (uint)self.nodes.len() - 1;
}

// --- Materials, textures and images ---

<*
 The MIME type glTF names an image by.

 KTX2 is `image/ktx2` and is only legal under KHR_texture_basisu, so a writer
 that emits one has an extension to declare as well — which is why nothing here
 produces one and this exists to round-trip a file that already did.
*>
fn String ImageType.mime_name(self)
{
	switch (self)
	{
		case IMAGE_JPEG: return "image/jpeg";
		case IMAGE_PNG: return "image/png";
		case IMAGE_BMP: return "image/bmp";
		case IMAGE_GIF: return "image/gif";
		case IMAGE_KTX2: return "image/ktx2";
	}
}

fn String AlphaMode.gltf_name(self)
{
	switch (self)
	{
		case BLEND: return "BLEND";
		// The parser reads MASK and CUTOFF into two enumerants of one glTF value;
		// both write back as MASK, which is the only spelling the format has.
		case MASK: return "MASK";
		case CUTOFF: return "MASK";
		default: return "OPAQUE";
	}
}

// The sampler enums are ordinals here and GL constants in the file, so both
// directions of the mapping are written out rather than cast.
fn uint MagFilter.gl_value(self) => self == LINEAR ? 9729 : 9728;

fn uint MinFilter.gl_value(self)
{
	switch (self)
	{
		case NEAREST: return 9728;
		case LINEAR: return 9729;
		case NEAREST_MIPMAP_NEAREST: return 9984;
		case LINEAR_MIPMAP_NEAREST: return 9985;
		case NEAREST_MIPMAP_LINEAR: return 9986;
		case LINEAR_MIPMAP_LINEAR: return 9987;
	}
}

fn uint WrapMode.gl_value(self)
{
	switch (self)
	{
		case CLAMP_TO_EDGE: return 33071;
		case MIRRORED_REPEAT: return 33648;
		case REPEAT: return 10497;
	}
}

<*
 Put an encoded image into the blob and register it.

 `encoded` is the file's own bytes — the PNG or JPEG as it was compressed —
 rather than pixels. Nothing here decodes anything, which is what makes copying
 an image from one document to another lossless as well as cheap.

 The view carries no `target`: the spec forbids one on a bufferView an image
 reads, because the targets are the two vertex-buffer bindings.

 @param mime : `The container the bytes are in. glTF requires it for a bufferView image; it cannot be sniffed by the reader.`
 @return `The image index, for add_texture.`
*>
fn uint GltfBuilder.add_image(&self, String name, char[] encoded, ImageType mime)
{
	uint view = self.add_view(encoded);
	self.images.push({ .name = name.copy(self.allocator), .view = view, .mime = mime });
	return (uint)self.images.len() - 1;
}

<*
 @param sampler : `Index from add_texture_sampler, or -1 for the viewer's default — which is repeat with mipmapped linear filtering.`
*>
fn uint GltfBuilder.add_texture(&self, uint image, int sampler = -1)
{
	self.textures.push({ .source = image, .sampler = sampler });
	return (uint)self.textures.len() - 1;
}

fn uint GltfBuilder.add_texture_sampler(&self, MagFilter mag = LINEAR, MinFilter min = LINEAR_MIPMAP_LINEAR,
	WrapMode wrap_s = REPEAT, WrapMode wrap_t = REPEAT)
{
	self.samplers.push({ .mag = mag, .min = min, .wrap_s = wrap_s, .wrap_t = wrap_t });
	return (uint)self.samplers.len() - 1;
}

<*
 A metallic-roughness material, for `add_primitive`'s `material` argument.

 The defaults are glTF's own, so a material stating nothing is white, fully
 metallic and fully rough — which is what a consumer assumes for a primitive
 that names no material at all, and therefore the one set of defaults that
 cannot change how anything looks by being written down.

 @param base_color_texture : `Texture index from add_texture, or -1. Sampled through TEXCOORD_0.`
*>
fn uint GltfBuilder.add_material(&self, String name, Vec4 base_color = { 1, 1, 1, 1 },
	float metallic = 1.0, float roughness = 1.0, int base_color_texture = -1,
	bool double_sided = false, AlphaMode alpha_mode = OPAQUE, float alpha_cutoff = 0.5)
{
	self.materials.push({
		.name = name.copy(self.allocator),
		.base_color = base_color,
		.metallic = metallic,
		.roughness = roughness,
		.base_color_texture = base_color_texture,
		.double_sided = double_sided,
		.alpha_mode = alpha_mode,
		.alpha_cutoff = alpha_cutoff,
	});
	return (uint)self.materials.len() - 1;
}

fn void GltfBuilder.add_child(&self, uint parent, uint child) => self.nodes.get_ref(parent).children.push(child);

// Nodes not named as anyone's child have to be listed in the scene, or they
// are not part of the document at all.
fn void GltfBuilder.add_root(&self, uint node) => self.roots.push(node);

<*
 @param joints : `Node indices, in the order the JOINTS_0 attribute indexes them.`
 @param inverse_bind : `Accessor of MAT4 inverse bind matrices, or -1 to let them default to identity.`
 @param skeleton : `Node index of the common root of the joints, or -1.`
*>
fn uint GltfBuilder.add_skin(&self, String name, uint[] joints, int inverse_bind = -1, int skeleton = -1)
{
	WriteSkin skin;
	skin.name = name.copy(self.allocator);
	skin.inverse_bind = inverse_bind;
	skin.skeleton = skeleton;
	skin.joints.init(self.allocator);
	foreach (joint : joints) skin.joints.push(joint);
	self.skins.push(skin);
	return (uint)self.skins.len() - 1;
}

// --- Animation ---

<*
 Start an animation. Curves are attached to it by add_sampler and add_channel,
 which take the index this returns.

 An animation with no channels is legal glTF and plays nothing; the accessors
 its samplers would have referenced are simply never added.

 @return `The animation index, to reference from add_sampler and add_channel.`
*>
fn uint GltfBuilder.add_animation(&self, String name)
{
	WriteAnimation animation;
	animation.name = name.copy(self.allocator);
	animation.samplers.init(self.allocator);
	animation.channels.init(self.allocator);
	self.animations.push(animation);
	return (uint)self.animations.len() - 1;
}

<*
 One curve: key times paired with the values at them.

 A sampler drives nothing until a channel points it at a node, and one sampler
 may be shared by several channels — which is what lets every joint in a clip
 reference the same input accessor.

 @param animation : `Index returned by add_animation.`
 @param input : `Accessor of key times, from add_times.`
 @param output : `Accessor of values, one per key time — add_rotations or add_vectors.`
 @return `The sampler index within this animation, for add_channel.`
*>
fn uint GltfBuilder.add_sampler(&self, uint animation, uint input, uint output, Interpolation interpolation = LINEAR)
{
	WriteAnimation* target = self.animations.get_ref(animation);
	target.samplers.push({ .input = input, .output = output, .interpolation = interpolation });
	return (uint)target.samplers.len() - 1;
}

<*
 Bind a sampler to the node property it drives.

 @param animation : `Index returned by add_animation.`
 @param sampler : `Index returned by add_sampler on that same animation.`
 @param node : `Node index the curve drives.`
 @param path : `Which of the node's properties the sampler's values are.`
 @require path != AnimationProperty.POINTER : `KHR_animation_pointer targets are not written; see AnimationProperty.gltf_name.`
*>
fn void GltfBuilder.add_channel(&self, uint animation, uint sampler, uint node, AnimationProperty path)
{
	self.animations.get_ref(animation).channels.push({ .sampler = sampler, .node = node, .path = path });
}

// --- Extras ---

<*
 Set a root-level `extras` entry — the object glTF leaves entirely to whoever
 writes the file, and the one place application metadata can go without an
 extension.

 Strings only, matching what the parser keeps (see `Gltf.extras`): a number or
 an array written here would be dropped on the way back in, so offering them
 would be offering a silent round-trip loss. Numbers belong here spelled as
 text.

 Setting a key twice replaces the value, so metadata can be assembled in pieces
 without the caller tracking what it has already written.
*>
fn void GltfBuilder.set_extra(&self, String key, String value)
{
	foreach (i, extra : self.extras)
	{
		if (extra.key != key) continue;
		extra.value.free(self.allocator);
		self.extras.get_ref(i).value = value.copy(self.allocator);
		return;
	}
	self.extras.push({ .key = key.copy(self.allocator), .value = value.copy(self.allocator) });
}

// --- Physics ---
//
// KHR_implicit_shapes and KHR_physics_rigid_bodies, written as the parser in
// rigid_bodies.c3 reads them. The document-level arrays — shapes, materials,
// filters and joint settings — are built first and referenced by index; what
// hangs off a node is the collider, the motion and the joint binding it to
// another body.
//
// These write more explicitly than the rest of the writer does. A shape's
// dimensions, a motion's mass and damping and a material's combine rules all
// have non-zero defaults in the spec or in the parser, so omitting a field
// because it happens to be zero would read back as a different value; only
// fields whose absence the parser reads back as the value that was given are
// left out.

<*
 Register an implicit shape — the collision volume colliders refer to by index.

 @return `The shape index, to pass to add_collider as Collider.shape.`
*>
fn uint GltfBuilder.add_shape(&self, Shape shape)
{
	self.shapes.push(shape);
	return (uint)self.shapes.len() - 1;
}

<*
 Register a physics material — the friction and restitution a collider's
 surface answers a contact with.

 @return `The physicsMaterials index, for Collider.material.`
*>
fn uint GltfBuilder.add_physics_material(&self, PhysicsMaterial material)
{
	self.physics_materials.push(material);
	return (uint)self.physics_materials.len() - 1;
}

<*
 Register a collision filter — the systems a collider belongs to, and the ones
 it does and does not collide with.

 The system names are copied, so the lists handed in can be temporary.

 @return `The collisionFilters index, for Collider.collision_filter.`
*>
fn uint GltfBuilder.add_collision_filter(&self, CollisionFilter filter)
{
	CollisionFilter copy;
	copy.systems.init(self.allocator);
	copy.colliding_with.init(self.allocator);
	copy.not_colliding.init(self.allocator);

	foreach (system : filter.systems) copy.systems.push(system.copy(self.allocator));
	foreach (system : filter.colliding_with) copy.colliding_with.push(system.copy(self.allocator));
	foreach (system : filter.not_colliding) copy.not_colliding.push(system.copy(self.allocator));

	self.collision_filters.push(copy);
	return (uint)self.collision_filters.len() - 1;
}

<*
 Register the settings a joint constrains its two bodies by — its limits and
 its drives. Several joints may share one entry, which is what lets a rig
 describe a kind of joint once and use it on every limb.

 A limit is one entry per mask, not one per axis: a limit naming two angular
 axes constrains the angle between them as a cone, and splitting it into two
 hinges is a different constraint. Limits with an empty mask constrain nothing
 and are dropped.

 The limits and drives are copied, so the lists handed in can be freed straight
 after.

 @return `The physicsJoints index, to pass to add_node_joint.`
*>
fn uint GltfBuilder.add_physics_joint_settings(&self, PhysicsJoint joint)
{
	PhysicsJoint copy;
	copy.angular_limits.init(self.allocator);
	copy.linear_limits.init(self.allocator);
	copy.drives.init(self.allocator);

	foreach (limit : joint.angular_limits) copy.angular_limits.push(limit);
	foreach (limit : joint.linear_limits) copy.linear_limits.push(limit);
	foreach (drive : joint.drives) copy.drives.push(drive);

	self.physics_joints.push(copy);
	return (uint)self.physics_joints.len() - 1;
}

// The node's physics object, created on first use. A node with nothing
// physical about it carries no extensions object at all, so the slot stays -1
// until something is attached to it.
fn WriteNodePhysics* node_physics_ref(GltfBuilder* builder, uint node) @private
{
	WriteNode* target = builder.nodes.get_ref(node);
	if (target.physics < 0)
	{
		WriteNodePhysics fresh;
		builder.node_physics.push(fresh);
		target.physics = (int)builder.node_physics.len() - 1;
	}
	return builder.node_physics.get_ref((uint)target.physics);
}

<*
 Give a node a collider: the geometry it collides with, and optionally the
 material and filter that decide how.

 A collider with `is_trigger` set is written as a trigger instead — a volume
 that reports overlaps rather than resisting them.

 Absent references are -1, not 0. A zeroed Collider names shape 0, material 0
 and filter 0, so build one by naming every field it needs and setting the rest
 to -1, the way Collider.from_json leaves them.

 Geometry is an implicit shape, or another node whose mesh is the collision
 geometry, or neither — in which case the collider is the node's own mesh, and
 the node had better have one, since that is the only case the parser refuses.

 A node holds one collider, so calling this twice replaces the first rather
 than giving the node two.

 @param node : `Index returned by add_node.`
*>
fn void GltfBuilder.add_collider(&self, uint node, Collider collider)
{
	WriteNodePhysics* physics = node_physics_ref(self, node);
	if (physics.has_collider) physics.collider.free();
	physics.has_collider = true;
	physics.collider = collider;

	// The compound trigger list is copied, so the caller's can be temporary.
	physics.collider.nodes.init(self.allocator);
	foreach (child : collider.nodes) physics.collider.nodes.push(child);
}

<*
 Make a node a rigid body: something with mass that the simulation moves,
 rather than a fixture the world is nailed to.

 @param node : `Index returned by add_node.`
*>
fn void GltfBuilder.add_motion(&self, uint node, Motion motion)
{
	WriteNodePhysics* physics = node_physics_ref(self, node);
	physics.has_motion = true;
	physics.motion = motion;
}

<*
 Joint this node's body to another, constrained by settings registered with
 add_physics_joint_settings.

 The joint lives on one of the two bodies and names the other, so it is written
 once rather than from both ends.

 @param node : `Index returned by add_node — the body the joint hangs on.`
 @param connected_node : `The node holding the body at the joint's other end.`
 @param joint_settings : `Index returned by add_physics_joint_settings.`
 @param enable_collision : `Whether the two jointed bodies still collide with each other.`
*>
fn void GltfBuilder.add_node_joint(&self, uint node, uint connected_node, uint joint_settings, bool enable_collision = false)
{
	WriteNodePhysics* physics = node_physics_ref(self, node);
	physics.has_joint = true;
	physics.connected_node = connected_node;
	physics.joint = joint_settings;
	physics.enable_collision = enable_collision;
}

// --- JSON ---

fn void append_json_string(DString* out, String value) @private
{
	out.append_char('"');
	foreach (c : value)
	{
		switch (c)
		{
			case '"':  out.append_string(`\"`);
			case '\\': out.append_string(`\\`);
			case '\n': out.append_string(`\n`);
			case '\r': out.append_string(`\r`);
			case '\t': out.append_string(`\t`);
			default:
				if (c < 0x20)
				{
					out.appendf(`\u%04x`, (uint)c)!!;
				}
				else
				{
					out.append_char(c);
				}
		}
	}
	out.append_char('"');
}

<*
 JSON has no NaN or Infinity spelling, so a non-finite value would produce a
 file no parser accepts. Writing zero keeps the document loadable and leaves
 the damage visible in the geometry rather than in the syntax.

 9 significant digits is the shortest form that round-trips a float exactly.
*>
fn void append_json_float(DString* out, float value) @private
{
	if (!math::is_finite(value))
	{
		out.append_char('0');
		return;
	}
	out.appendf("%.9g", value)!!;
}

fn void append_json_floats(DString* out, float[] values) @private
{
	out.append_char('[');
	foreach (i, value : values)
	{
		if (i > 0) out.append_char(',');
		append_json_float(out, value);
	}
	out.append_char(']');
}

fn void append_json_uints(DString* out, List{uint}* values) @private
{
	out.append_char('[');
	foreach (i, value : *values)
	{
		if (i > 0) out.append_char(',');
		out.appendf("%d", value)!!;
	}
	out.append_char(']');
}

fn void append_json_strings(DString* out, List{String}* values) @private
{
	out.append_char('[');
	foreach (i, value : *values)
	{
		if (i > 0) out.append_char(',');
		append_json_string(out, value);
	}
	out.append_char(']');
}

fn void append_json_vec3(DString* out, Vec3 value) @private
{
	float[3] values = { value.x, value.y, value.z };
	append_json_floats(out, values[..]);
}

fn bool is_nonzero(Vec3 value) @private => value.x != 0 || value.y != 0 || value.z != 0;

// --- Physics JSON ---

fn void append_shape_json(DString* out, Shape shape) @private
{
	out.append_string(`{"type":`);
	append_json_string(out, shape.type.gltf_name());
	out.append_char(',');
	append_json_string(out, shape.type.gltf_name());
	out.append_string(":{");

	switch (shape.type)
	{
		case BOX:
			out.append_string(`"size":`);
			append_json_vec3(out, shape.size);
		case SPHERE:
			out.append_string(`"radius":`);
			append_json_float(out, shape.radius);
		case CAPSULE:
		case CYLINDER:
			out.append_string(`"height":`);
			append_json_float(out, shape.height);
			out.append_string(`,"radiusBottom":`);
			append_json_float(out, shape.radius_bottom);
			out.append_string(`,"radiusTop":`);
			append_json_float(out, shape.radius_top);
	}

	out.append_string("}}");
}

fn void append_physics_material_json(DString* out, PhysicsMaterial material) @private
{
	out.append_string(`{"staticFriction":`);
	append_json_float(out, material.static_friction);
	out.append_string(`,"dynamicFriction":`);
	append_json_float(out, material.dynamic_friction);
	out.append_string(`,"restitution":`);
	append_json_float(out, material.restitution);
	// Both combine rules are always written: the parser defaults them to
	// multiply and maximum, so an average — which is what a zeroed struct says
	// — would read back as neither.
	out.append_string(`,"frictionCombine":`);
	append_json_string(out, material.friction_combine.gltf_name());
	out.append_string(`,"restitutionCombine":`);
	append_json_string(out, material.restitution_combine.gltf_name());
	out.append_char('}');
}

fn void append_collision_filter_json(DString* out, CollisionFilter filter) @private
{
	out.append_char('{');
	bool first = true;

	if (filter.systems.len() > 0)
	{
		out.append_string(`"collisionSystems":`);
		append_json_strings(out, &filter.systems);
		first = false;
	}
	if (filter.colliding_with.len() > 0)
	{
		if (!first) out.append_char(',');
		out.append_string(`"collideWithSystems":`);
		append_json_strings(out, &filter.colliding_with);
		first = false;
	}
	if (filter.not_colliding.len() > 0)
	{
		if (!first) out.append_char(',');
		out.append_string(`"notCollideWithSystems":`);
		append_json_strings(out, &filter.not_colliding);
	}

	out.append_char('}');
}

<*
 One limit, over every axis its mask names.

 Written as a single entry rather than one per axis, because a limit spanning
 several axes constrains the length of the vector across them — two angular
 axes are a cone, not two independent hinges — and splitting it would change
 what the file says.

 min and max are always written. An absent bound means unconstrained, so a
 locked axis, whose min and max are both zero, would come out free.

 stiffness and damping are left out at zero: a limit with no spring in it is a
 hard stop, which is what an absent spring already means.
*>
fn void append_limit_json(DString* out, Limit limit, String axes_name, bool* first) @private
{
	if (!is_nonzero(limit.axes)) return;

	if (!*first) out.append_char(',');
	*first = false;

	out.append_char('{');
	append_json_string(out, axes_name);
	out.append_string(":[");
	bool axis_first = true;
	for (uint axis = 0; axis < 3; axis++)
	{
		if (limit.axes[axis] == 0) continue;
		if (!axis_first) out.append_char(',');
		out.appendf("%d", axis)!!;
		axis_first = false;
	}
	out.append_string(`],"min":`);
	append_json_float(out, limit.min);
	out.append_string(`,"max":`);
	append_json_float(out, limit.max);
	if (limit.stiffness != 0)
	{
		out.append_string(`,"stiffness":`);
		append_json_float(out, limit.stiffness);
	}
	if (limit.damping != 0)
	{
		out.append_string(`,"damping":`);
		append_json_float(out, limit.damping);
	}
	out.append_char('}');
}

fn void append_drive_json(DString* out, Drive drive) @private
{
	out.append_string(`{"type":`);
	append_json_string(out, drive.type.gltf_name());
	out.append_string(`,"mode":`);
	append_json_string(out, drive.drive.gltf_name());
	out.appendf(`,"axis":%d`, drive.axis)!!;

	if (drive.position_target != 0)
	{
		out.append_string(`,"positionTarget":`);
		append_json_float(out, drive.position_target);
	}
	if (drive.velocity_target != 0)
	{
		out.append_string(`,"velocityTarget":`);
		append_json_float(out, drive.velocity_target);
	}
	// Zero is not a force ceiling anyone means, so it is spelled by leaving the
	// field out — which the spec reads as unlimited.
	if (drive.max_force != 0)
	{
		out.append_string(`,"maxForce":`);
		append_json_float(out, drive.max_force);
	}
	if (drive.stiffness != 0)
	{
		out.append_string(`,"stiffness":`);
		append_json_float(out, drive.stiffness);
	}
	if (drive.damping != 0)
	{
		out.append_string(`,"damping":`);
		append_json_float(out, drive.damping);
	}
	out.append_char('}');
}

fn void append_physics_joint_json(DString* out, PhysicsJoint joint) @private
{
	out.append_string(`{"limits":[`);
	bool first = true;
	foreach (limit : joint.linear_limits) append_limit_json(out, limit, "linearAxes", &first);
	foreach (limit : joint.angular_limits) append_limit_json(out, limit, "angularAxes", &first);
	out.append_char(']');

	if (joint.drives.len() > 0)
	{
		out.append_string(`,"drives":[`);
		foreach (i, drive : joint.drives)
		{
			if (i > 0) out.append_char(',');
			append_drive_json(out, drive);
		}
		out.append_char(']');
	}
	out.append_char('}');
}

fn void append_collider_json(DString* out, Collider collider) @private
{
	out.append_char('{');
	bool first = true;

	if (collider.has_shape() || collider.has_node() || collider.convex_hull)
	{
		out.append_string(`"geometry":{`);
		bool geometry_first = true;
		if (collider.has_shape())
		{
			out.appendf(`"shape":%d`, collider.shape)!!;
			geometry_first = false;
		}
		if (collider.has_node())
		{
			if (!geometry_first) out.append_char(',');
			out.appendf(`"node":%d`, collider.node)!!;
			geometry_first = false;
		}
		if (collider.convex_hull)
		{
			if (!geometry_first) out.append_char(',');
			out.append_string(`"convexHull":true`);
		}
		out.append_char('}');
		first = false;
	}

	if (collider.has_material())
	{
		if (!first) out.append_char(',');
		out.appendf(`"physicsMaterial":%d`, collider.material)!!;
		first = false;
	}
	if (collider.has_filter())
	{
		if (!first) out.append_char(',');
		out.appendf(`"collisionFilter":%d`, collider.collision_filter)!!;
		first = false;
	}
	// Compound triggers name the nodes they are made of.
	if (collider.nodes.len() > 0)
	{
		if (!first) out.append_char(',');
		out.append_string(`"nodes":`);
		append_json_uints(out, &collider.nodes);
	}

	out.append_char('}');
}

<*
 A motion's mass, gravity factor and both damping factors are always written.
 The parser defaults them to 1 and 0.9 rather than to zero, so a body that
 really is massless or undamped has to say so out loud or read back as
 something else.

 The vectors are written only when they hold something, which is exactly when
 the parser reads them back as given: it leaves an absent one alone, and what
 it leaves alone is zero.
*>
fn void append_motion_json(DString* out, Motion motion) @private
{
	out.append_string(`{"mass":`);
	append_json_float(out, motion.mass);
	out.append_string(`,"gravityFactor":`);
	append_json_float(out, motion.gravity_factor);
	out.append_string(`,"linearDamping":`);
	append_json_float(out, motion.linear_dampening);
	out.append_string(`,"angularDamping":`);
	append_json_float(out, motion.angular_dampening);

	if (motion.is_kinematic) out.append_string(`,"isKinematic":true`);

	if (is_nonzero(motion.mass_center))
	{
		out.append_string(`,"centerOfMass":`);
		append_json_vec3(out, motion.mass_center);
	}
	if (is_nonzero(motion.inertia_diagonal))
	{
		out.append_string(`,"inertiaDiagonal":`);
		append_json_vec3(out, motion.inertia_diagonal);
	}
	Quaternionf orientation = motion.inertia_orientation;
	if (orientation.v[0] != 0 || orientation.v[1] != 0 || orientation.v[2] != 0 || orientation.v[3] != 0)
	{
		out.append_string(`,"inertiaOrientation":`);
		float[4] values = { orientation.v[0], orientation.v[1], orientation.v[2], orientation.v[3] };
		append_json_floats(out, values[..]);
	}
	if (is_nonzero(motion.linear_velocity))
	{
		out.append_string(`,"linearVelocity":`);
		append_json_vec3(out, motion.linear_velocity);
	}
	if (is_nonzero(motion.angular_velocity))
	{
		out.append_string(`,"angularVelocity":`);
		append_json_vec3(out, motion.angular_velocity);
	}
	out.append_char('}');
}

fn void append_node_physics_json(DString* out, WriteNodePhysics physics) @private
{
	out.append_char('{');
	bool first = true;

	if (physics.has_motion)
	{
		out.append_string(`"motion":`);
		append_motion_json(out, physics.motion);
		first = false;
	}
	if (physics.has_collider)
	{
		if (!first) out.append_char(',');
		// A trigger is the same object under a different key — the parser takes
		// the flag from the key it found it under, not from the object.
		append_json_string(out, physics.collider.is_trigger ? "trigger" : "collider");
		out.append_char(':');
		append_collider_json(out, physics.collider);
		first = false;
	}
	if (physics.has_joint)
	{
		if (!first) out.append_char(',');
		out.appendf(`"joint":{"connectedNode":%d,"joint":%d`, physics.connected_node, physics.joint)!!;
		if (physics.enable_collision) out.append_string(`,"enableCollision":true`);
		out.append_char('}');
	}

	out.append_char('}');
}

<*
 Serialise the document to glTF JSON. Written to be read back by this
 library's own parser, so nothing is emitted that the parser ignores, and
 defaults are left out rather than written explicitly.

 @param buffer_uri : `Where the binary lives. Empty means the GLB convention — a buffer with a length and no uri, referring to the BIN chunk.`
*>
fn DString GltfBuilder.to_json(&self, Allocator allocator, String buffer_uri = "")
{
	DString out = dstring::new_with_capacity(allocator, 4096);
	DString* o = &out;

	o.append_string(`{"asset":{"version":"2.0","generator":`);
	append_json_string(o, self.generator);
	o.append_char('}');

	// An extension is named in extensionsUsed once, however many objects in the
	// document turn out to use it. KHR_physics_rigid_bodies counts as used by a
	// node that carries one as much as by a document-level array, since a
	// collider on a node is the extension too.
	bool uses_shapes = self.shapes.len() > 0;
	bool rigid_body_arrays = self.physics_materials.len() > 0 || self.collision_filters.len() > 0
		|| self.physics_joints.len() > 0;
	bool uses_rigid_bodies = rigid_body_arrays || self.node_physics.len() > 0;

	if (uses_shapes || uses_rigid_bodies)
	{
		o.append_string(`,"extensionsUsed":[`);
		if (uses_shapes) append_json_string(o, IMPLICIT_SHAPES_EXTENSION);
		if (uses_shapes && uses_rigid_bodies) o.append_char(',');
		if (uses_rigid_bodies) append_json_string(o, RIGID_BODIES_EXTENSION);
		o.append_char(']');
	}

	if (uses_shapes || rigid_body_arrays)
	{
		o.append_string(`,"extensions":{`);

		if (uses_shapes)
		{
			append_json_string(o, IMPLICIT_SHAPES_EXTENSION);
			o.append_string(`:{"shapes":[`);
			foreach (i, shape : self.shapes)
			{
				if (i > 0) o.append_char(',');
				append_shape_json(o, shape);
			}
			o.append_string("]}");
		}

		if (rigid_body_arrays)
		{
			if (uses_shapes) o.append_char(',');
			append_json_string(o, RIGID_BODIES_EXTENSION);
			o.append_string(":{");
			bool first = true;

			if (self.physics_materials.len() > 0)
			{
				o.append_string(`"physicsMaterials":[`);
				foreach (i, material : self.physics_materials)
				{
					if (i > 0) o.append_char(',');
					append_physics_material_json(o, material);
				}
				o.append_char(']');
				first = false;
			}
			if (self.collision_filters.len() > 0)
			{
				if (!first) o.append_char(',');
				o.append_string(`"collisionFilters":[`);
				foreach (i, filter : self.collision_filters)
				{
					if (i > 0) o.append_char(',');
					append_collision_filter_json(o, filter);
				}
				o.append_char(']');
				first = false;
			}
			if (self.physics_joints.len() > 0)
			{
				if (!first) o.append_char(',');
				o.append_string(`"physicsJoints":[`);
				foreach (i, joint : self.physics_joints)
				{
					if (i > 0) o.append_char(',');
					append_physics_joint_json(o, joint);
				}
				o.append_char(']');
			}
			o.append_char('}');
		}

		o.append_char('}');
	}

	if (self.extras.len() > 0)
	{
		o.append_string(`,"extras":{`);
		foreach (i, extra : self.extras)
		{
			if (i > 0) o.append_char(',');
			append_json_string(o, extra.key);
			o.append_char(':');
			append_json_string(o, extra.value);
		}
		o.append_char('}');
	}

	if (self.roots.len() > 0)
	{
		o.append_string(`,"scene":0,"scenes":[{"nodes":`);
		append_json_uints(o, &self.roots);
		o.append_string("}]");
	}

	if (self.nodes.len() > 0)
	{
		o.append_string(`,"nodes":[`);
		foreach (i, node : self.nodes)
		{
			if (i > 0) o.append_char(',');
			o.append_char('{');
			bool first = true;

			if (node.name.len > 0)
			{
				o.append_string(`"name":`);
				append_json_string(o, node.name);
				first = false;
			}
			if (node.mesh >= 0)
			{
				if (!first) o.append_char(',');
				o.appendf(`"mesh":%d`, node.mesh)!!;
				first = false;
			}
			if (node.skin >= 0)
			{
				if (!first) o.append_char(',');
				o.appendf(`"skin":%d`, node.skin)!!;
				first = false;
			}
			if (node.translation.x != 0 || node.translation.y != 0 || node.translation.z != 0)
			{
				if (!first) o.append_char(',');
				o.append_string(`"translation":`);
				float[3] values = { node.translation.x, node.translation.y, node.translation.z };
				append_json_floats(o, values[..]);
				first = false;
			}
			if (node.rotation.v[0] != 0 || node.rotation.v[1] != 0 || node.rotation.v[2] != 0 || node.rotation.v[3] != 1)
			{
				if (!first) o.append_char(',');
				o.append_string(`"rotation":`);
				float[4] values = { node.rotation.v[0], node.rotation.v[1], node.rotation.v[2], node.rotation.v[3] };
				append_json_floats(o, values[..]);
				first = false;
			}
			if (node.scale.x != 1 || node.scale.y != 1 || node.scale.z != 1)
			{
				if (!first) o.append_char(',');
				o.append_string(`"scale":`);
				float[3] values = { node.scale.x, node.scale.y, node.scale.z };
				append_json_floats(o, values[..]);
				first = false;
			}
			if (node.children.len() > 0)
			{
				if (!first) o.append_char(',');
				o.append_string(`"children":`);
				append_json_uints(o, &node.children);
				first = false;
			}
			if (node.physics >= 0)
			{
				if (!first) o.append_char(',');
				o.append_string(`"extensions":{`);
				append_json_string(o, RIGID_BODIES_EXTENSION);
				o.append_char(':');
				append_node_physics_json(o, self.node_physics[(uint)node.physics]);
				o.append_char('}');
			}
			o.append_char('}');
		}
		o.append_char(']');
	}

	if (self.meshes.len() > 0)
	{
		o.append_string(`,"meshes":[`);
		foreach (i, mesh : self.meshes)
		{
			if (i > 0) o.append_char(',');
			o.append_char('{');
			if (mesh.name.len > 0)
			{
				o.append_string(`"name":`);
				append_json_string(o, mesh.name);
				o.append_char(',');
			}
			o.append_string(`"primitives":[`);
			foreach (j, primitive : mesh.primitives)
			{
				if (j > 0) o.append_char(',');
				o.append_string(`{"attributes":{`);
				foreach (k, attribute : primitive.attributes)
				{
					if (k > 0) o.append_char(',');
					append_json_string(o, attribute.name);
					o.appendf(":%d", attribute.accessor)!!;
				}
				o.append_char('}');
				if (primitive.indices >= 0) o.appendf(`,"indices":%d`, primitive.indices)!!;
				if (primitive.material >= 0) o.appendf(`,"material":%d`, primitive.material)!!;
				// 4 (TRIANGLES) is the glTF default and is left implicit.
				if (primitive.mode != TRIANGLES) o.appendf(`,"mode":%d`, primitive.mode.ordinal)!!;
				o.append_char('}');
			}
			o.append_string("]}");
		}
		o.append_char(']');
	}

	if (self.materials.len() > 0)
	{
		o.append_string(`,"materials":[`);
		foreach (i, material : self.materials)
		{
			if (i > 0) o.append_char(',');
			o.append_char('{');
			if (material.name.len > 0)
			{
				o.append_string(`"name":`);
				append_json_string(o, material.name);
				o.append_char(',');
			}
			o.append_string(`"pbrMetallicRoughness":{"baseColorFactor":`);
			append_json_floats(o, material.base_color[..]);
			o.append_string(`,"metallicFactor":`);
			append_json_float(o, material.metallic);
			o.append_string(`,"roughnessFactor":`);
			append_json_float(o, material.roughness);
			if (material.base_color_texture >= 0)
			{
				o.appendf(`,"baseColorTexture":{"index":%d}`, material.base_color_texture)!!;
			}
			o.append_char('}');
			// OPAQUE and single-sided are the defaults, so stating them would only
			// make two documents that mean the same thing fail to compare equal.
			if (material.alpha_mode != OPAQUE)
			{
				o.append_string(`,"alphaMode":`);
				append_json_string(o, material.alpha_mode.gltf_name());
				if (material.alpha_mode == MASK || material.alpha_mode == CUTOFF)
				{
					o.append_string(`,"alphaCutoff":`);
					append_json_float(o, material.alpha_cutoff);
				}
			}
			if (material.double_sided) o.append_string(`,"doubleSided":true`);
			o.append_char('}');
		}
		o.append_char(']');
	}

	if (self.textures.len() > 0)
	{
		o.append_string(`,"textures":[`);
		foreach (i, texture : self.textures)
		{
			if (i > 0) o.append_char(',');
			o.appendf(`{"source":%d`, texture.source)!!;
			if (texture.sampler >= 0) o.appendf(`,"sampler":%d`, texture.sampler)!!;
			o.append_char('}');
		}
		o.append_char(']');
	}

	if (self.images.len() > 0)
	{
		o.append_string(`,"images":[`);
		foreach (i, image : self.images)
		{
			if (i > 0) o.append_char(',');
			o.append_char('{');
			if (image.name.len > 0)
			{
				o.append_string(`"name":`);
				append_json_string(o, image.name);
				o.append_char(',');
			}
			o.appendf(`"bufferView":%d,"mimeType":`, image.view)!!;
			append_json_string(o, image.mime.mime_name());
			o.append_char('}');
		}
		o.append_char(']');
	}

	if (self.samplers.len() > 0)
	{
		o.append_string(`,"samplers":[`);
		foreach (i, sampler : self.samplers)
		{
			if (i > 0) o.append_char(',');
			o.appendf(`{"magFilter":%d,"minFilter":%d,"wrapS":%d,"wrapT":%d}`,
				sampler.mag.gl_value(), sampler.min.gl_value(),
				sampler.wrap_s.gl_value(), sampler.wrap_t.gl_value())!!;
		}
		o.append_char(']');
	}

	if (self.skins.len() > 0)
	{
		o.append_string(`,"skins":[`);
		foreach (i, skin : self.skins)
		{
			if (i > 0) o.append_char(',');
			o.append_char('{');
			if (skin.name.len > 0)
			{
				o.append_string(`"name":`);
				append_json_string(o, skin.name);
				o.append_char(',');
			}
			if (skin.inverse_bind >= 0) o.appendf(`"inverseBindMatrices":%d,`, skin.inverse_bind)!!;
			if (skin.skeleton >= 0) o.appendf(`"skeleton":%d,`, skin.skeleton)!!;
			o.append_string(`"joints":`);
			append_json_uints(o, &skin.joints);
			o.append_char('}');
		}
		o.append_char(']');
	}

	if (self.animations.len() > 0)
	{
		o.append_string(`,"animations":[`);
		foreach (i, animation : self.animations)
		{
			if (i > 0) o.append_char(',');
			o.append_char('{');
			if (animation.name.len > 0)
			{
				o.append_string(`"name":`);
				append_json_string(o, animation.name);
				o.append_char(',');
			}

			o.append_string(`"samplers":[`);
			foreach (j, sampler : animation.samplers)
			{
				if (j > 0) o.append_char(',');
				o.appendf(`{"input":%d,"output":%d`, sampler.input, sampler.output)!!;
				// LINEAR is the glTF default and is left implicit.
				if (sampler.interpolation != LINEAR)
				{
					o.append_string(`,"interpolation":`);
					append_json_string(o, sampler.interpolation.gltf_name());
				}
				o.append_char('}');
			}

			o.append_string(`],"channels":[`);
			foreach (j, channel : animation.channels)
			{
				if (j > 0) o.append_char(',');
				o.appendf(`{"sampler":%d,"target":{"node":%d,"path":`, channel.sampler, channel.node)!!;
				append_json_string(o, channel.path.gltf_name());
				o.append_string("}}");
			}
			o.append_string("]}");
		}
		o.append_char(']');
	}

	if (self.accessors.len() > 0)
	{
		o.append_string(`,"accessors":[`);
		foreach (i, accessor : self.accessors)
		{
			if (i > 0) o.append_char(',');
			o.appendf(`{"bufferView":%d,"componentType":%d,"count":%d,"type":`,
				accessor.view, accessor.data_type.component_type(), accessor.count)!!;
			append_json_string(o, accessor.type.gltf_name());
			if (accessor.normalized) o.append_string(`,"normalized":true`);
			if (accessor.has_bounds)
			{
				uint components = accessor.type.component_count();
				o.append_string(`,"min":`);
				append_json_floats(o, accessor.min[0:components]);
				o.append_string(`,"max":`);
				append_json_floats(o, accessor.max[0:components]);
			}
			o.append_char('}');
		}
		o.append_char(']');
	}

	if (self.views.len() > 0)
	{
		o.append_string(`,"bufferViews":[`);
		foreach (i, view : self.views)
		{
			if (i > 0) o.append_char(',');
			o.appendf(`{"buffer":0,"byteOffset":%d,"byteLength":%d`, view.offset, view.length)!!;
			if (view.stride > 0) o.appendf(`,"byteStride":%d`, view.stride)!!;
			if (view.target >= 0) o.appendf(`,"target":%d`, view.target)!!;
			o.append_char('}');
		}
		o.append_char(']');
	}

	if (self.bin.len() > 0)
	{
		o.appendf(`,"buffers":[{"byteLength":%d`, self.bin.len())!!;
		if (buffer_uri.len > 0)
		{
			o.append_string(`,"uri":`);
			append_json_string(o, buffer_uri);
		}
		o.append_string("}]");
	}

	o.append_char('}');
	return out;
}

// --- Output ---

fn void put_u32(char[] destination, sz offset, uint value) @private
{
	destination[offset]     = (char)value;
	destination[offset + 1] = (char)(value >> 8);
	destination[offset + 2] = (char)(value >> 16);
	destination[offset + 3] = (char)(value >> 24);
}

<*
 Serialise to the binary container: a 12-byte header followed by a JSON chunk
 and a BIN chunk.

 Both chunks are padded to 4 bytes, each with the byte the spec names for it —
 spaces for JSON so it stays valid to a parser that reads to the declared
 length, zeros for the binary.

 @return `The GLB file contents, owned by the caller.`
 @return? NOTHING_TO_WRITE : `No scene root was added, so the document would have no content.`
*>
fn char[]? GltfBuilder.to_glb(&self, Allocator allocator)
{
	if (self.roots.len() == 0) return NOTHING_TO_WRITE~;

	@pool()
	{
		DString json = self.to_json(tmem);
		String json_text = json.str_view();

		sz json_padding = (4 - (json_text.len % 4)) % 4;
		sz bin_length = self.bin.len();
		sz bin_padding = (4 - (bin_length % 4)) % 4;

		sz json_chunk = json_text.len + json_padding;
		sz bin_chunk = bin_length + bin_padding;
		bool has_bin = bin_length > 0;

		sz total = 12 + 8 + json_chunk + (has_bin ? 8 + bin_chunk : 0);
		char[] out = alloc::new_array(allocator, char, total);

		put_u32(out, 0, GLB_MAGIC);
		put_u32(out, 4, GLB_VERSION);
		put_u32(out, 8, (uint)total);

		put_u32(out, 12, (uint)json_chunk);
		put_u32(out, 16, GLB_CHUNK_JSON);
		mem::copy(&out[20], json_text.ptr, json_text.len);
		for (sz i = 0; i < json_padding; i++) out[20 + json_text.len + i] = ' ';

		if (has_bin)
		{
			sz base = 20 + json_chunk;
			put_u32(out, base, (uint)bin_chunk);
			put_u32(out, base + 4, GLB_CHUNK_BIN);
			mem::copy(&out[base + 8], self.bin.str_view().ptr, bin_length);
			for (sz i = 0; i < bin_padding; i++) out[base + 8 + bin_length + i] = 0;
		}

		return out;
	};
}

<*
 Write a self-contained .glb.

 @return? NOTHING_TO_WRITE : `No scene root was added.`
 @return? WRITE_FAILED : `The file could not be opened, written or flushed.`
*>
fn void? GltfBuilder.save_glb(&self, String path)
{
	char[] data = self.to_glb(self.allocator)!;
	defer alloc::free(self.allocator, data);
	return write_file(path, data);
}

<*
 Write a .gltf with the binary embedded as a base64 data URI, so the result is
 still a single file. Roughly a third larger than the equivalent .glb — prefer
 save_glb unless the JSON needs to be readable.

 @return? NOTHING_TO_WRITE : `No scene root was added.`
 @return? WRITE_FAILED : `The file could not be opened, written or flushed.`
*>
fn void? GltfBuilder.save_gltf(&self, String path)
{
	if (self.roots.len() == 0) return NOTHING_TO_WRITE~;

	@pool()
	{
		String uri = "";
		if (self.bin.len() > 0)
		{
			String encoded = base64::encode(tmem, self.bin.str_view());
			uri = string::tformat("data:application/octet-stream;base64,%s", encoded);
		}

		DString json = self.to_json(tmem, uri);
		return write_file(path, json.str_view());
	};
}

// Close is checked as well as write: the data is buffered, so a full disk
// surfaces on flush rather than on the write itself.
fn void? write_file(String path, char[] data) @private
{
	File? handle = file::open(path, "wb");
	if (catch handle) return WRITE_FAILED~;

	if (catch handle.write(data))
	{
		if (catch handle.close()) {}
		return WRITE_FAILED~;
	}

	if (catch handle.close()) return WRITE_FAILED~;
}
