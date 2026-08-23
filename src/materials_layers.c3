// ============================================================================
// CUSTOM_materials_layers — vendor extension, NOT part of core glTF.
//
// An ordered stack of extra material layers blended on top of the base
// material (terrain splatting, weathering, decals). The base material stays
// in the core pbrMetallicRoughness/normalTexture fields, so viewers without
// this extension still render correctly; this file only parses the *extra*
// layers plus the base material's height/bump data (which core glTF cannot
// hold).
//
// Spec: gltf-exporter addon, extensions/materials_layers.md.
//
// Everything for the extension lives in this file — the writing half at the
// bottom as well as the parsing half. The core loader touches it in exactly
// three places, each marked with a "CUSTOM_materials_layers" comment:
//   - struct Material carries a `MaterialLayers layers_ext` field
//   - parse_metadata's material loop calls MaterialLayers.from_json
//   - Gltf.free calls MaterialLayers.free
//
// The writer touches it in four, marked the same way:
//   - struct WriteMaterial carries a `layers` slot
//   - GltfBuilder carries the `material_layers` list, inited and freed with it
//   - the material loop in build_json calls append_material_layers_json
//   - extensionsUsed names it when the list is non-empty
// ============================================================================
module gltf;

import std::collections::object;
import std::collections::list;

import std::math;
import std::math::vector;

const MATERIALS_LAYERS_EXTENSION = "CUSTOM_materials_layers";

// Blend of a layer over the surface below it; result is
// lerp(below, f(below, layer), mask). Matches Blender's Mix node modes.
// Unrecognized modes fall back to MIX per spec.
enum LayerBlendMode : uint
{
	MIX,        // f(a,b) = b
	MULTIPLY,   // a * b
	ADD,        // a + b
	SUBTRACT,   // a - b
	SCREEN,     // 1 - (1-a)(1-b)
	OVERLAY,    // a < 0.5 ? 2ab : 1 - 2(1-a)(1-b)
	SOFT_LIGHT,
	DIFFERENCE, // abs(a - b)
	DARKEN,     // min(a, b)
	LIGHTEN,    // max(a, b)
}

enum LayerMaskSource : uint
{
	NONE, // no mask object on the layer — visible everywhere (mask = 1.0)
	TEXTURE,
	VERTEX_COLOR,
}

// Channel of the mask texture / vertex color the layer weight is read from.
// Ordinal doubles as the component index (R=0 .. A=3).
enum LayerMaskChannel : uint
{
	R,
	G,
	B,
	A,
}

// Where a layer is visible. `texture` is valid when source == TEXTURE;
// `attribute` names the vertex color attribute when source == VERTEX_COLOR
// (empty string means the glTF default, COLOR_0).
struct LayerMask
{
	LayerMaskSource source;
	LayerMaskChannel channel;
	TextureInfo texture;
	String attribute;
	bool invert;
}

// Bump parameters for a height texture (Blender Bump node Strength/Distance).
struct LayerBump
{
	float strength;
	float distance;
}

struct LayerSubsurface
{
	float weight;
	Vec3 radius;
}

// One extension layer. PBR fields mirror the core material's shape and
// defaults; per-layer alpha rides in baseColorFactor.a.
struct MaterialLayer
{
	String name;

	Vec4 baseColorFactor;
	float metallicFactor;
	float roughnessFactor;
	TextureInfo baseColorTexture;
	TextureInfo metallicRoughnessTexture;

	TextureInfo normalTexture;
	TextureInfo heightTexture;
	LayerBump bump;

	Vec3 emissiveFactor;
	TextureInfo emissiveTexture;

	LayerSubsurface subsurface;

	LayerMask mask;
	LayerBlendMode blend_mode;
	float opacity;
	bool enabled;
}

// Per-material extension data, attached to Material as `layers_ext`.
// `present` is false on materials without the extension (all other fields are
// then zero). `heightTexture`/`bump` carry the *base* material's height data
// (extension `base` object); `layers` holds layers 1..N blended over the base.
struct MaterialLayers
{
	bool present;
	TextureInfo heightTexture;
	LayerBump bump;
	List{MaterialLayer} layers;
}

fn bool Material.has_layers(&self)
{
	return self.layers_ext.present && self.layers_ext.layers.len() > 0;
}

// Parse the extension from a material's JSON. `material_json` is the whole
// material object; does nothing when the extension is absent.
fn void MaterialLayers.from_json(&self, Object* material_json, Gltf* data, Allocator allocator)
{
	@when_extended(material_json, MATERIALS_LAYERS_EXTENSION ; Object* ext)
	{
		self.present = true;
		self.heightTexture = default_layer_texture();
		self.bump = { .strength = 1.0, .distance = 1.0 };
		self.layers.init(allocator);

		// Base-material extras: height/bump that core glTF has no slot for.
		Object*? base = ext.get("base");
		if (try base)
		{
			self.heightTexture = layer_texture(base.get("heightTexture"), data) ?? default_layer_texture();
			self.bump = layer_bump(base.get("bump")) ?? DEFAULT_LAYER_BUMP;
		}

		Object*? layers = ext.get("layers");
		if (try layers)
		{
			foreach (layer_json : layers.array)
			{
				self.layers.push(parse_layer(layer_json, data));
			}
		}
	};
}

fn void MaterialLayers.free(self)
{
	foreach (layer : self.layers)
	{
		layer.name.free(mem);
		layer.mask.attribute.free(mem);
	}
	self.layers.free();
}

// ---------------------------------------------------------------------------
// Parsing internals
// ---------------------------------------------------------------------------

fn MaterialLayer parse_layer(Object* json, Gltf* data) @private
{
	MaterialLayer layer = {
		.baseColorFactor = { 1.0, 1.0, 1.0, 1.0 },
		.metallicFactor = 1.0,
		.roughnessFactor = 1.0,
		.baseColorTexture = default_layer_texture(),
		.metallicRoughnessTexture = default_layer_texture(),
		.normalTexture = default_layer_texture(),
		.heightTexture = default_layer_texture(),
		.bump = { .strength = 1.0, .distance = 1.0 },
		.emissiveFactor = { 0.0, 0.0, 0.0 },
		.emissiveTexture = default_layer_texture(),
		.subsurface = { .weight = 0.0, .radius = { 1.0, 0.2, 0.1 } },
		.blend_mode = MIX,
		.opacity = 1.0,
		.enabled = true,
	};

	String? name = json.get_string("name");
	if (try name) layer.name = name.copy(mem);

	Object*? pbr = json.get("pbrMetallicRoughness");
	if (try pbr)
	{
		Object*? baseColorFactor = pbr.get("baseColorFactor");
		if (try baseColorFactor)
		{
			layer.baseColorFactor = {
				(float)@num(baseColorFactor.get_at(0)),
				(float)@num(baseColorFactor.get_at(1)),
				(float)@num(baseColorFactor.get_at(2)),
				(float)@num(baseColorFactor.get_at(3))
			};
		}
		layer.metallicFactor = (float)pbr.get_float("metallicFactor") ?? 1.0;
		layer.roughnessFactor = (float)pbr.get_float("roughnessFactor") ?? 1.0;
		layer.baseColorTexture = layer_texture(pbr.get("baseColorTexture"), data) ?? default_layer_texture();
		layer.metallicRoughnessTexture = layer_texture(pbr.get("metallicRoughnessTexture"), data) ?? default_layer_texture();
	}

	layer.normalTexture = layer_texture(json.get("normalTexture"), data) ?? default_layer_texture();
	layer.heightTexture = layer_texture(json.get("heightTexture"), data) ?? default_layer_texture();
	layer.bump = layer_bump(json.get("bump")) ?? DEFAULT_LAYER_BUMP;

	Object*? emissiveFactor = json.get("emissiveFactor");
	if (try emissiveFactor)
	{
		layer.emissiveFactor = {
			(float)@num(emissiveFactor.get_at(0)),
			(float)@num(emissiveFactor.get_at(1)),
			(float)@num(emissiveFactor.get_at(2))
		};
	}
	layer.emissiveTexture = layer_texture(json.get("emissiveTexture"), data) ?? default_layer_texture();

	Object*? subsurface = json.get("subsurface");
	if (try subsurface)
	{
		layer.subsurface.weight = (float)subsurface.get_float("weight") ?? 0.0;
		Object*? radius = subsurface.get("radius");
		if (try radius)
		{
			layer.subsurface.radius = {
				(float)@num(radius.get_at(0)),
				(float)@num(radius.get_at(1)),
				(float)@num(radius.get_at(2))
			};
		}
	}

	layer.mask = parse_layer_mask(json.get("mask"), data) ?? default_layer_mask();
	layer.blend_mode = blend_mode_from_string(json.get_string("blendMode") ?? "MIX");
	layer.opacity = (float)json.get_float("opacity") ?? 1.0;
	layer.enabled = json.get_bool("enabled") ?? true;

	return layer;
}

fn LayerMask parse_layer_mask(Object* json, Gltf* data) @private
{
	LayerMask mask = default_layer_mask();

	switch (json.get_string("source") ?? "")
	{
		case "TEXTURE":
			mask.source = TEXTURE;
			mask.texture = layer_texture(json.get("texture"), data) ?? default_layer_texture();
		case "VERTEX_COLOR":
			mask.source = VERTEX_COLOR;
			String? attribute = json.get_string("attribute");
			if (try attribute) mask.attribute = attribute.copy(mem);
	}

	switch (json.get_string("channel") ?? "R")
	{
		case "G": mask.channel = G;
		case "B": mask.channel = B;
		case "A": mask.channel = A;
		default:  mask.channel = R;
	}

	mask.invert = json.get_bool("invert") ?? false;
	return mask;
}

// textureInfo -> TextureInfo with KHR_texture_transform applied and the
// texture index resolved to image source + sampler, mirroring what the core
// loader does for the base material's textures.
fn TextureInfo layer_texture(Object* json, Gltf* data) @private
{
	TextureInfo info;
	info = info.from_json(json);
	if (info.source > -1)
	{
		Texture texture = data.textures[info.source];
		info.source = texture.source;
		info.sampler = texture.sampler;
	}
	return info;
}

fn TextureInfo default_layer_texture() @private
{
	return { .source = -1, .sampler = -1, .rotation = 0, .offset = { 0, 0 }, .scale = { 1.0, 1.0 } };
}

fn LayerMask default_layer_mask() @private
{
	return { .source = NONE, .channel = R, .texture = default_layer_texture(), .invert = false };
}

// Public because `add_material_layers` takes it as a default argument, and a
// default argument spelled with a private symbol is a signature the caller
// cannot write out.
const LayerBump DEFAULT_LAYER_BUMP = { .strength = 1.0, .distance = 1.0 };

fn LayerBump layer_bump(Object* json) @private
{
	return {
		.strength = (float)json.get_float("strength") ?? 1.0,
		.distance = (float)json.get_float("distance") ?? 1.0,
	};
}

fn LayerBlendMode blend_mode_from_string(String name) @private
{
	switch (name)
	{
		case "MULTIPLY":   return MULTIPLY;
		case "ADD":        return ADD;
		case "SUBTRACT":   return SUBTRACT;
		case "SCREEN":     return SCREEN;
		case "OVERLAY":    return OVERLAY;
		case "SOFT_LIGHT": return SOFT_LIGHT;
		case "DIFFERENCE": return DIFFERENCE;
		case "DARKEN":     return DARKEN;
		case "LIGHTEN":    return LIGHTEN;
		default:           return MIX; // includes "MIX" and unrecognized modes
	}
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------
//
// The inverse of everything above, and it does not reuse the structs above.
// `writer.c3`'s header gives the general argument — "writing is deliberately
// not a round-trip of the read structs" — and here there is a specific one:
// `layer_texture` resolves a `textureInfo`'s `index` through the textures array
// to the *image* it names, so a parsed `TextureInfo.source` is an image index
// while the one that has to be written is a texture index. The two are
// different numbers with the same name, and a shared struct would make handing
// a parsed layer back to the builder compile, run, and reference the wrong
// picture. Separate types make it a type error instead.
//
// What is shared is the enums — `LayerBlendMode`, `LayerMaskSource`,
// `LayerMaskChannel` — and `LayerBump`/`LayerSubsurface`, which are plain
// values with no indices in them. One authority for what the ordinals mean is
// the whole point of them.

// A layer's texture slots are `WriteTextureRef`s — `writer.c3`'s, not this
// file's. A `textureInfo` is core glTF, and the core material's `normalTexture`
// needs the same type; it lives there so that the core writer does not have to
// import a type from a vendor extension to state one.

struct WriteLayerMask
{
	LayerMaskSource source;
	LayerMaskChannel channel;
	// Read when source == TEXTURE.
	WriteTextureRef texture;
	// Read when source == VERTEX_COLOR. Empty means the glTF default, COLOR_0 —
	// and is then left out of the file, because that is how the parser spells it.
	String attribute;
	bool invert;
}

<*
 One layer of the stack, as the writer states it.

 Field for field what `MaterialLayer` parses, with `WriteTextureRef` in place
 of `TextureInfo`. Build one with `material_layer()` rather than by declaring
 it: a zero-filled value of this struct is a black, fully transparent layer at
 zero opacity that is switched off — every default inverted, and the file that
 comes out of it looks like a bug in the blender rather than in the caller.
*>
struct WriteMaterialLayer
{
	String name;

	Vec4 baseColorFactor;
	float metallicFactor;
	float roughnessFactor;
	WriteTextureRef baseColorTexture;
	WriteTextureRef metallicRoughnessTexture;

	WriteTextureRef normalTexture;
	WriteTextureRef heightTexture;
	LayerBump bump;

	Vec3 emissiveFactor;
	WriteTextureRef emissiveTexture;

	LayerSubsurface subsurface;

	WriteLayerMask mask;
	LayerBlendMode blend_mode;
	float opacity;
	bool enabled;
}

// One material's stack: the base material's height data, and the layers over
// it. Held by the builder and referenced from WriteMaterial.layers.
struct WriteMaterialLayers
{
	WriteTextureRef heightTexture;
	LayerBump bump;
	List{WriteMaterialLayer} layers;
}

<*
 A layer with every field at the value the parser reads back for its absence.

 The one supported way to make a `WriteMaterialLayer`. Set what differs and
 leave the rest, and the emitter writes only what you set — so a layer that
 states nothing round-trips to a layer that states nothing rather than to a
 document full of explicit defaults that happen to agree.
*>
fn WriteMaterialLayer material_layer(String name = "")
{
	return {
		.name = name,
		.baseColorFactor = { 1.0, 1.0, 1.0, 1.0 },
		.metallicFactor = 1.0,
		.roughnessFactor = 1.0,
		.baseColorTexture = NO_TEXTURE_REF,
		.metallicRoughnessTexture = NO_TEXTURE_REF,
		.normalTexture = NO_TEXTURE_REF,
		.heightTexture = NO_TEXTURE_REF,
		.bump = DEFAULT_LAYER_BUMP,
		.emissiveFactor = { 0.0, 0.0, 0.0 },
		.emissiveTexture = NO_TEXTURE_REF,
		.subsurface = { .weight = 0.0, .radius = { 1.0, 0.2, 0.1 } },
		.mask = {
			.source = NONE,
			.channel = R,
			.texture = NO_TEXTURE_REF,
			.attribute = "",
			.invert = false,
		},
		.blend_mode = MIX,
		.opacity = 1.0,
		.enabled = true,
	};
}

<*
 Give a material a layer stack, and open it for `add_layer`.

 Two steps rather than one, which is `add_mesh`/`add_primitive`'s shape and
 `add_animation`/`add_sampler`'s: the layers are a list of a length the caller
 discovers as it goes, and a single call taking a slice would make every caller
 materialise one.

 Calling this twice on one material replaces the first stack rather than giving
 the material two, matching `add_collider` and `add_instancing`.

 @param material : `Index returned by add_material.`
 @param height : `The base material's height map — core glTF has no slot for one, which is why the extension carries it.`
 @param bump : `Strength and distance for that height map. Blender's Bump node.`
 @return `The stack index, to pass to add_layer.`
*>
fn uint GltfBuilder.add_material_layers(
	&self, uint material,
	WriteTextureRef height = NO_TEXTURE_REF, LayerBump bump = DEFAULT_LAYER_BUMP
)
{
	WriteMaterial* target = self.materials.get_ref(material);
	if (target.layers >= 0)
	{
		WriteMaterialLayers* existing = self.material_layers.get_ref((uint)target.layers);
		foreach (layer : existing.layers) free_write_layer(self.allocator, layer);
		existing.layers.clear();
		existing.heightTexture = height;
		existing.bump = bump;
		return (uint)target.layers;
	}

	WriteMaterialLayers fresh;
	fresh.heightTexture = height;
	fresh.bump = bump;
	fresh.layers.init(self.allocator);
	self.material_layers.push(fresh);
	target.layers = (int)self.material_layers.len() - 1;
	return (uint)target.layers;
}

<*
 Append one layer to a stack. Order is the blend order: each layer is composited
 over everything below it, the base material included.

 @param stack : `Index returned by add_material_layers.`
*>
fn void GltfBuilder.add_layer(&self, uint stack, WriteMaterialLayer layer)
{
	WriteMaterialLayer copy = layer;
	copy.name = layer.name.copy(self.allocator);
	copy.mask.attribute = layer.mask.attribute.copy(self.allocator);
	self.material_layers.get_ref(stack).layers.push(copy);
}

fn void free_write_layer(Allocator allocator, WriteMaterialLayer layer) @private
{
	layer.name.free(allocator);
	layer.mask.attribute.free(allocator);
}

// Called by GltfBuilder.free. The two owned strings per layer are the same two
// MaterialLayers.free gives back on the parsing side.
fn void GltfBuilder.free_material_layers(&self)
{
	foreach (stack : self.material_layers)
	{
		foreach (layer : stack.layers) free_write_layer(self.allocator, layer);
		stack.layers.free();
	}
	self.material_layers.free();
}

// Whether any layer's textureInfo carries a KHR_texture_transform. Called by
// `GltfBuilder.any_texture_transform`, which asks the core materials itself —
// this is the half that has to know what a layer holds.
fn bool GltfBuilder.any_layer_texture_transform(&self)
{
	foreach (stack : self.material_layers)
	{
		if (stack.heightTexture.is_transformed()) return true;
		foreach (layer : stack.layers)
		{
			if (layer.baseColorTexture.is_transformed()) return true;
			if (layer.metallicRoughnessTexture.is_transformed()) return true;
			if (layer.normalTexture.is_transformed()) return true;
			if (layer.heightTexture.is_transformed()) return true;
			if (layer.emissiveTexture.is_transformed()) return true;
			if (layer.mask.texture.is_transformed()) return true;
		}
	}
	return false;
}

// The inverse of blend_mode_from_string. MIX is the parser's fallback for an
// absent or unrecognised mode, so it is never written.
fn String LayerBlendMode.gltf_name(self)
{
	switch (self)
	{
		case MIX:        return "MIX";
		case MULTIPLY:   return "MULTIPLY";
		case ADD:        return "ADD";
		case SUBTRACT:   return "SUBTRACT";
		case SCREEN:     return "SCREEN";
		case OVERLAY:    return "OVERLAY";
		case SOFT_LIGHT: return "SOFT_LIGHT";
		case DIFFERENCE: return "DIFFERENCE";
		case DARKEN:     return "DARKEN";
		case LIGHTEN:    return "LIGHTEN";
	}
}

fn String LayerMaskSource.gltf_name(self)
{
	switch (self)
	{
		case NONE:         return "NONE";
		case TEXTURE:      return "TEXTURE";
		case VERTEX_COLOR: return "VERTEX_COLOR";
	}
}

fn String LayerMaskChannel.gltf_name(self)
{
	switch (self)
	{
		case R: return "R";
		case G: return "G";
		case B: return "B";
		case A: return "A";
	}
}

<*
 The `CUSTOM_materials_layers` object for one material, into the JSON chunk.

 **A field at its default is left out**, which is the rule the material loop
 around this already follows for `alphaMode` and `doubleSided` and the reason it
 gives there: two documents that mean the same thing should compare equal.
 Every omission here is one `parse_layer` reads back as the value that was not
 written, so nothing is lost by leaving it out — the physics writer's comment
 about writing more explicitly is the other side of that same test, and applies
 where the parser's default and the spec's disagree. They do not here.

 Called with the material's own `extensions` object already open.
*>
fn void append_material_layers_json(DString* out, WriteMaterialLayers* stack) @private
{
	append_json_string(out, MATERIALS_LAYERS_EXTENSION);
	out.append_string(`:{`);

	bool wrote = false;

	// The `base` object exists for what core glTF has no slot for, so a stack
	// carrying neither a height map nor a non-default bump writes no `base` at
	// all rather than an empty one.
	bool has_bump = stack.bump.strength != 1.0 || stack.bump.distance != 1.0;
	if (stack.heightTexture.texture >= 0 || has_bump)
	{
		out.append_string(`"base":{`);
		bool base_wrote = false;
		if (stack.heightTexture.texture >= 0)
		{
			out.append_string(`"heightTexture":`);
			append_texture_ref_json(out, stack.heightTexture);
			base_wrote = true;
		}
		if (has_bump)
		{
			if (base_wrote) out.append_char(',');
			append_layer_bump_json(out, stack.bump);
		}
		out.append_char('}');
		wrote = true;
	}

	if (stack.layers.len() > 0)
	{
		if (wrote) out.append_char(',');
		out.append_string(`"layers":[`);
		foreach (i, layer : stack.layers)
		{
			if (i > 0) out.append_char(',');
			append_layer_json(out, layer);
		}
		out.append_char(']');
	}

	out.append_char('}');
}

fn void append_layer_json(DString* out, WriteMaterialLayer layer) @private
{
	out.append_char('{');
	bool wrote = false;

	if (layer.name.len > 0)
	{
		out.append_string(`"name":`);
		append_json_string(out, layer.name);
		wrote = true;
	}

	// The PBR half goes in its own object exactly as the core material's does,
	// and the object is written only when something inside it is not the default
	// — an empty `pbrMetallicRoughness` would read back identically and compare
	// differently.
	bool base_color = layer.baseColorFactor.x != 1.0 || layer.baseColorFactor.y != 1.0
		|| layer.baseColorFactor.z != 1.0 || layer.baseColorFactor.w != 1.0;
	bool pbr = base_color || layer.metallicFactor != 1.0 || layer.roughnessFactor != 1.0
		|| layer.baseColorTexture.texture >= 0 || layer.metallicRoughnessTexture.texture >= 0;
	if (pbr)
	{
		if (wrote) out.append_char(',');
		out.append_string(`"pbrMetallicRoughness":{`);
		bool pbr_wrote = false;
		if (base_color)
		{
			out.append_string(`"baseColorFactor":`);
			float[4] values = {
				layer.baseColorFactor.x, layer.baseColorFactor.y,
				layer.baseColorFactor.z, layer.baseColorFactor.w
			};
			append_json_floats(out, values[..]);
			pbr_wrote = true;
		}
		if (layer.metallicFactor != 1.0)
		{
			if (pbr_wrote) out.append_char(',');
			out.append_string(`"metallicFactor":`);
			append_json_float(out, layer.metallicFactor);
			pbr_wrote = true;
		}
		if (layer.roughnessFactor != 1.0)
		{
			if (pbr_wrote) out.append_char(',');
			out.append_string(`"roughnessFactor":`);
			append_json_float(out, layer.roughnessFactor);
			pbr_wrote = true;
		}
		if (layer.baseColorTexture.texture >= 0)
		{
			if (pbr_wrote) out.append_char(',');
			out.append_string(`"baseColorTexture":`);
			append_texture_ref_json(out, layer.baseColorTexture);
			pbr_wrote = true;
		}
		if (layer.metallicRoughnessTexture.texture >= 0)
		{
			if (pbr_wrote) out.append_char(',');
			out.append_string(`"metallicRoughnessTexture":`);
			append_texture_ref_json(out, layer.metallicRoughnessTexture);
		}
		out.append_char('}');
		wrote = true;
	}

	if (layer.normalTexture.texture >= 0)
	{
		if (wrote) out.append_char(',');
		out.append_string(`"normalTexture":`);
		append_texture_ref_json(out, layer.normalTexture);
		wrote = true;
	}
	if (layer.heightTexture.texture >= 0)
	{
		if (wrote) out.append_char(',');
		out.append_string(`"heightTexture":`);
		append_texture_ref_json(out, layer.heightTexture);
		wrote = true;
	}
	if (layer.bump.strength != 1.0 || layer.bump.distance != 1.0)
	{
		if (wrote) out.append_char(',');
		append_layer_bump_json(out, layer.bump);
		wrote = true;
	}

	if (layer.emissiveFactor.x != 0 || layer.emissiveFactor.y != 0 || layer.emissiveFactor.z != 0)
	{
		if (wrote) out.append_char(',');
		out.append_string(`"emissiveFactor":`);
		float[3] values = { layer.emissiveFactor.x, layer.emissiveFactor.y, layer.emissiveFactor.z };
		append_json_floats(out, values[..]);
		wrote = true;
	}
	if (layer.emissiveTexture.texture >= 0)
	{
		if (wrote) out.append_char(',');
		out.append_string(`"emissiveTexture":`);
		append_texture_ref_json(out, layer.emissiveTexture);
		wrote = true;
	}

	// The radius is only read when the object is there, and the object is only
	// written when the weight is non-zero — a radius on a layer with no
	// subsurface at all changes nothing and would be a difference between two
	// files that render the same.
	if (layer.subsurface.weight != 0)
	{
		if (wrote) out.append_char(',');
		out.append_string(`"subsurface":{"weight":`);
		append_json_float(out, layer.subsurface.weight);
		if (layer.subsurface.radius.x != 1.0 || layer.subsurface.radius.y != 0.2
			|| layer.subsurface.radius.z != 0.1)
		{
			out.append_string(`,"radius":`);
			float[3] values = {
				layer.subsurface.radius.x, layer.subsurface.radius.y, layer.subsurface.radius.z
			};
			append_json_floats(out, values[..]);
		}
		out.append_char('}');
		wrote = true;
	}

	// **A mask object is written for a channel alone.** `parse_layer_mask` reads
	// `channel` whatever the source is, and a VERTEX_COLOR layer reading G is the
	// difference between a layer that draws and one that vanishes — so the test
	// is not "is there a source" but "is there anything in here to say".
	bool has_mask = layer.mask.source != LayerMaskSource.NONE
		|| layer.mask.channel != LayerMaskChannel.R || layer.mask.invert;
	if (has_mask)
	{
		if (wrote) out.append_char(',');
		out.append_string(`"mask":{`);
		bool mask_wrote = false;
		if (layer.mask.source != LayerMaskSource.NONE)
		{
			out.append_string(`"source":`);
			append_json_string(out, layer.mask.source.gltf_name());
			mask_wrote = true;

			if (layer.mask.source == LayerMaskSource.TEXTURE && layer.mask.texture.texture >= 0)
			{
				out.append_string(`,"texture":`);
				append_texture_ref_json(out, layer.mask.texture);
			}
			if (layer.mask.source == LayerMaskSource.VERTEX_COLOR && layer.mask.attribute.len > 0)
			{
				out.append_string(`,"attribute":`);
				append_json_string(out, layer.mask.attribute);
			}
		}
		if (layer.mask.channel != LayerMaskChannel.R)
		{
			if (mask_wrote) out.append_char(',');
			out.append_string(`"channel":`);
			append_json_string(out, layer.mask.channel.gltf_name());
			mask_wrote = true;
		}
		if (layer.mask.invert)
		{
			if (mask_wrote) out.append_char(',');
			out.append_string(`"invert":true`);
		}
		out.append_char('}');
		wrote = true;
	}

	if (layer.blend_mode != LayerBlendMode.MIX)
	{
		if (wrote) out.append_char(',');
		out.append_string(`"blendMode":`);
		append_json_string(out, layer.blend_mode.gltf_name());
		wrote = true;
	}
	if (layer.opacity != 1.0)
	{
		if (wrote) out.append_char(',');
		out.append_string(`"opacity":`);
		append_json_float(out, layer.opacity);
		wrote = true;
	}
	if (!layer.enabled)
	{
		if (wrote) out.append_char(',');
		out.append_string(`"enabled":false`);
	}

	out.append_char('}');
}

fn void append_layer_bump_json(DString* out, LayerBump bump) @private
{
	out.append_string(`"bump":{"strength":`);
	append_json_float(out, bump.strength);
	out.append_string(`,"distance":`);
	append_json_float(out, bump.distance);
	out.append_char('}');
}
