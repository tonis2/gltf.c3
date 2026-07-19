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
// Everything for the extension lives in this file. The core loader touches it
// in exactly three places, each marked with a "CUSTOM_materials_layers" comment:
//   - struct Material carries a `MaterialLayers layers_ext` field
//   - parse_metadata's material loop calls MaterialLayers.from_json
//   - Gltf.free calls MaterialLayers.free
// ============================================================================
module gltf;

import std::collections::object;
import std::collections::list;
import std::core::mem;
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
				(float)baseColorFactor.get_at(0).f,
				(float)baseColorFactor.get_at(1).f,
				(float)baseColorFactor.get_at(2).f,
				(float)baseColorFactor.get_at(3).f
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
			(float)emissiveFactor.get_at(0).f,
			(float)emissiveFactor.get_at(1).f,
			(float)emissiveFactor.get_at(2).f
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
				(float)radius.get_at(0).f,
				(float)radius.get_at(1).f,
				(float)radius.get_at(2).f
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

const LayerBump DEFAULT_LAYER_BUMP @private = { .strength = 1.0, .distance = 1.0 };

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
