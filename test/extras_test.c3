// glTF `extras`: the root object's, and a node's.
module gltf_extras_test @test;

import std::io;
import std::io::file;
import std::core;
import gltf;

// A file with extras in both places, and one non-string value in each that has
// to be dropped rather than stored as something meaningless.
const String WITH_EXTRAS = `
{
  "asset": { "version": "2.0" },
  "extras": { "plan": "biped", "tags": "biped, swimming", "count": 3 },
  "scene": 0,
  "scenes": [ { "nodes": [0] } ],
  "nodes": [ { "name": "root", "extras": { "note": "on the node", "n": 1 } } ]
}
`;

// The same file with nothing declared. Opening it has to work, and the map has
// to come back empty rather than absent — every reader indexes it either way.
const String NO_EXTRAS = `
{
  "asset": { "version": "2.0" },
  "scene": 0,
  "scenes": [ { "nodes": [0] } ],
  "nodes": [ { "name": "root" } ]
}
`;

// A macro, not a function: every fn in an @test module is collected as a test.
macro void @write_fixture(String path, String json)
{
	file::save(path, (char[])json)!!;
}

fn void test_root_extras_round_trip()
{
	String path = "test/out_extras.gltf";
	@write_fixture(path, WITH_EXTRAS);
	defer (void)file::delete(path);

	GltfStream stream = gltf::open(path)!!;
	defer stream.close();

	// The root's own extras — what a pack's metadata rides on.
	assert(stream.gltf.extras.get("plan")!! == "biped");
	assert(stream.gltf.extras.get("tags")!! == "biped, swimming");

	// Anything that is not a string is dropped, so a reader never has to ask
	// what a number would have been spelled as.
	assert(@ok(stream.gltf.extras.get("count")) == false);
	assert(stream.gltf.extras.len() == 2);

	// A node's extras still work, and are a separate map from the root's.
	assert(stream.gltf.nodes[0].extras.get("note")!! == "on the node");
	assert(stream.gltf.nodes[0].extras.len() == 1);
	assert(@ok(stream.gltf.extras.get("note")) == false);
}

<*
 The keys and values outlive the JSON they were parsed from.

 They are read out of a tree that `parse_gltf` frees before it returns, so a map
 holding the original slices would compare and print released memory — which
 reads correctly often enough to pass a test written without this in mind. The
 second read is what makes the check mean something: it forces the allocator to
 hand back the parse tree's pages before the first file's strings are touched.
*>
fn void test_extras_survive_the_parse_tree()
{
	String first = "test/out_extras_a.gltf";
	String second = "test/out_extras_b.gltf";
	@write_fixture(first, WITH_EXTRAS);
	@write_fixture(second, WITH_EXTRAS);
	defer (void)file::delete(first);
	defer (void)file::delete(second);

	GltfStream a = gltf::open(first)!!;
	defer a.close();

	GltfStream b = gltf::open(second)!!;
	b.close();

	assert(a.gltf.extras.get("plan")!! == "biped");
	assert(a.gltf.nodes[0].extras.get("note")!! == "on the node");
}

fn void test_a_file_without_extras_still_opens()
{
	String path = "test/out_no_extras.gltf";
	@write_fixture(path, NO_EXTRAS);
	defer (void)file::delete(path);

	GltfStream stream = gltf::open(path)!!;
	defer stream.close();

	assert(stream.gltf.extras.len() == 0);
	assert(stream.gltf.nodes[0].extras.len() == 0);
	assert(stream.gltf.nodes[0].name == "root");
}
