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

 See skinning.c3 for the skeleton, weights and inverse bind matrices a rigged
 asset needs on top of this.
*>
module gltf;

import std::io;
import std::io::file;
import std::core::mem;
import std::core::mem::allocator;
import std::core::string;
import std::core::dstring;
import std::math;
import std::math::matrix;
import std::math::vector;
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
	List{uint} children;
}

struct WriteSkin
{
	String name;
	int skeleton;
	int inverse_bind;
	List{uint} joints;
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
	List{uint} roots;
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
	self.roots.init(allocator);
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
	node.children.init(self.allocator);
	self.nodes.push(node);
	return (uint)self.nodes.len() - 1;
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
