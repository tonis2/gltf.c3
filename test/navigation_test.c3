// CUSTOM_physics_navigation root metadata parsing.
module gltf_navigation_test @test;

import std::io::file;
import std::math::vector;
import gltf;

const String BASE = `
{
  "asset": { "version": "2.0" },
  "scene": 0,
  "scenes": [ { "nodes": [] } ]
}
`;

const String VALID = `
{
  "asset": { "version": "2.0" },
  "extensionsUsed": [ "CUSTOM_physics_navigation" ],
  "extensions": {
    "CUSTOM_physics_navigation": {
      "version": 1,
      "profiles": [ {
        "name": "mage",
        "cellSize": 0.25,
        "agentRadius": 0.3,
        "agentHeight": 1.66,
        "stepHeight": 0.42,
        "slopeLimit": 54,
        "origin": [ -8, 1.5, 3 ],
        "dimensions": [ 32, 8, 24 ],
        "cells": 0,
        "components": 2,
        "largestComponent": 3,
        "solidCells": 91,
        "floorCells": 47,
        "sourceHash": "sha256:0123456789abcdef"
      } ]
    }
  },
  "accessors": [ {
    "bufferView": 0,
    "componentType": 5125,
    "count": 4,
    "type": "SCALAR"
  } ],
  "bufferViews": [ { "buffer": 0, "byteLength": 16 } ],
  "buffers": [ { "byteLength": 16 } ],
  "scene": 0,
  "scenes": [ { "nodes": [] } ]
}
`;

// A profile is metadata the loader hands on for validation, not something it
// judges: only an entry that is not an object at all is dropped.
const String LENIENT = `
{
  "asset": { "version": "2.0" },
  "extensionsUsed": [ "CUSTOM_physics_navigation" ],
  "extensions": {
    "CUSTOM_physics_navigation": {
      "version": 1,
      "profiles": [ 7, { "name": "missing-fields" } ]
    }
  },
  "scene": 0,
  "scenes": [ { "nodes": [] } ]
}
`;

const String FUTURE_VERSION = `
{
  "asset": { "version": "2.0" },
  "extensionsUsed": [ "CUSTOM_physics_navigation" ],
  "extensions": {
    "CUSTOM_physics_navigation": {
      "version": 2,
      "profiles": [ { "name": "mage", "sourceHash": "sha256:00" } ]
    }
  },
  "scene": 0,
  "scenes": [ { "nodes": [] } ]
}
`;

macro void @fixture(String path, String contents)
{
	file::save(path, (char[])contents)!!;
}

fn void test_navigation_extension_absent_is_an_empty_list()
{
	String path = "test/out_navigation_absent.gltf";
	@fixture(path, BASE);
	defer (void)file::delete(path);
	GltfStream stream = gltf::open(path)!!;
	defer stream.close();
	assert(stream.gltf.navigation_profiles.len() == 0);
}

fn void test_navigation_profile_metadata_and_accessor_survive_parsing()
{
	String path = "test/out_navigation_valid.gltf";
	@fixture(path, VALID);
	defer (void)file::delete(path);
	GltfStream stream = gltf::open(path)!!;
	defer stream.close();

	assert(stream.gltf.navigation_profiles.len() == 1);
	NavigationProfile profile = stream.gltf.navigation_profiles[0];
	assert(profile.name == "mage");
	assert(profile.cell_size == 0.25f);
	assert(profile.agent_radius == 0.3f);
	assert(profile.agent_height == 1.66f);
	assert(profile.step_height == 0.42f);
	assert(profile.slope_limit == 54.0f);
	assert(profile.origin == (Vec3) { -8, 1.5, 3 });
	assert(profile.dimensions == (uint[3]) { 32, 8, 24 });
	assert(profile.cells == 0);
	assert(profile.components == 2 && profile.largest_component == 3);
	assert(profile.solid_cells == 91 && profile.floor_cells == 47);
	assert(profile.source_hash == "sha256:0123456789abcdef");
	assert(stream.gltf.accessors[profile.cells].type == AccessorType.SCALAR);
	assert(stream.gltf.accessors[profile.cells].data_type == DataType.UINT);
}

fn void test_a_profile_that_is_not_an_object_is_skipped()
{
	String path = "test/out_navigation_lenient.gltf";
	@fixture(path, LENIENT);
	defer (void)file::delete(path);
	GltfStream stream = gltf::open(path)!!;
	defer stream.close();

	assert(stream.gltf.navigation_profiles.len() == 1);
	NavigationProfile profile = stream.gltf.navigation_profiles[0];
	assert(profile.name == "missing-fields");
	assert(profile.source_hash == "");
	assert(profile.cell_size == 0.0f && profile.agent_height == 0.0f);
	assert(profile.dimensions == (uint[3]) { 0, 0, 0 });
	assert(profile.cells == 0 && profile.components == 0);
}

fn void test_an_unknown_version_carries_no_profiles()
{
	String path = "test/out_navigation_version.gltf";
	@fixture(path, FUTURE_VERSION);
	defer (void)file::delete(path);
	GltfStream stream = gltf::open(path)!!;
	defer stream.close();
	assert(stream.gltf.navigation_profiles.len() == 0);
}
