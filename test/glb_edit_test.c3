// Editing a glTF in place: the container split, and the JSON member splice.
//
// The claim these exist to hold up is "everything you did not edit survives
// exactly", so the central check is a byte comparison against files this library
// did not write — `truck.glb` with its images and animations, `duck.gltf` with a
// base64 buffer inline. A round trip that reformats is a round trip that has
// silently rewritten somebody's asset.
module gltf_glb_edit_test @test;

import std::io;
import std::io::file;
import std::core;
import std::core::dstring;
import std::core::mem;
import std::core::mem::allocator;
import gltf;

const String TRUCK = "test/truck.glb";
const String DUCK = "test/duck.gltf";

macro bool @same_bytes(char[] a, char[] b)
{
	if (a.len != b.len) return false;
	foreach (i, c : a)
	{
		if (c != b[i]) return false;
	}
	return true;
}

<*
 A .glb split and written straight back is the same file, bit for bit.

 The strongest form of the promise, and the only one worth making: not "it still
 loads", not "the meshes are the same", but that the bytes did not move. Anything
 weaker leaves room for a reformat nobody notices until a file goes somewhere
 strict.
*>
fn void test_a_binary_round_trip_changes_nothing()
{
	char[] before = file::load(mem, TRUCK)!!;
	defer free(before);

	GlbParts parts = gltf::split_glb(mem, TRUCK)!!;
	defer parts.free(mem);

	assert(parts.binary, "a .glb reads as binary");
	assert(parts.rest.len > 0, "and its buffer chunk comes back whole");

	String out = "test/out_truck_copy.glb";
	gltf::write_glb(out, parts)!!;
	defer (void)file::delete(out);

	char[] after = file::load(mem, out)!!;
	defer free(after);

	assert(@same_bytes(before, after), "the file is unchanged");
}

// The text form has no container to rebuild, so the bytes have even less excuse
// to move.
fn void test_a_text_round_trip_changes_nothing()
{
	char[] before = file::load(mem, DUCK)!!;
	defer free(before);

	GlbParts parts = gltf::split_glb(mem, DUCK)!!;
	defer parts.free(mem);

	assert(!parts.binary, "a .gltf reads as text");
	assert(parts.rest.len == 0, "with nothing after the JSON");

	String out = "test/out_duck_copy.gltf";
	gltf::write_glb(out, parts)!!;
	defer (void)file::delete(out);

	char[] after = file::load(mem, out)!!;
	defer free(after);

	assert(@same_bytes(before, after), "the file is unchanged");
}

<*
 Stamping metadata onto a real file leaves its binary chunk alone.

 The whole reason for editing text rather than re-encoding: `truck.glb` carries
 442 kilobytes of vertices, images and animation samplers, and adding forty bytes
 of `extras` must not touch one of them.
*>
fn void test_patching_a_real_file_keeps_its_buffer()
{
	GlbParts parts = gltf::split_glb(mem, TRUCK)!!;
	defer parts.free(mem);

	char[] original_bin = (char[])alloc::clone_slice(mem, parts.rest);
	defer free(original_bin);

	gltf::JsonStep[2] where = { { .key = gltf::GLTF_EXTRAS }, { .key = "tool" } };
	gltf::JsonEdit[1] edits = { { .path = where[..], .value = "crig" } };
	String stamped = gltf::patch_gltf_text(mem, (String)parts.json, edits[..])!!;

	// Handed over rather than aliased: the old text is released here and the new
	// text becomes the part set's, so `parts.free` is the only release either
	// needs. A `defer stamped.free` beside this would be the second one.
	free(parts.json);
	parts.json = (char[])stamped;

	String out = "test/out_truck_stamped.glb";
	gltf::write_glb(out, parts)!!;
	defer (void)file::delete(out);

	GlbParts back = gltf::split_glb(mem, out)!!;
	defer back.free(mem);

	assert(@same_bytes(original_bin, back.rest), "every byte after the JSON is where it was");

	// And the file is still a glTF to a reader that knows nothing about the edit.
	GltfStream stream = gltf::open(out)!!;
	defer stream.close();
	assert(stream.gltf.extras.get("tool")!! == "crig");
	assert(stream.gltf.meshes.len() > 0, "the meshes survived");
	assert(stream.gltf.images.len() > 0, "and so did the images");
}

<*
 Stamping one tool's metadata leaves another tool's alone.

 `extras` is shared: Blender writes custom properties there, exporters leave
 notes. A tool that replaces the whole object to add its own key deletes theirs,
 and nothing reports it — the file still loads, it has just quietly lost
 somebody's data.
*>
fn void test_an_extra_does_not_clobber_its_neighbours()
{
	String text = `{"extras":{"blender":"3.6"},"scene":0}`;

	gltf::JsonStep[2] mine = { { .key = gltf::GLTF_EXTRAS }, { .key = "crig" } };
	gltf::JsonEdit[1] edits = { { .path = mine[..], .value = `{"version":6}` } };

	String out = gltf::patch_gltf_text(mem, text, edits[..])!!;
	defer out.free(mem);

	gltf::JsonStep[2] theirs = { { .key = gltf::GLTF_EXTRAS }, { .key = "blender" } };
	assert(gltf::read_gltf_member(out, theirs[..]) == `"3.6"`, "got %s", gltf::read_gltf_member(out, theirs[..]));
	assert(gltf::read_gltf_member(out, mine[..]) == `"{\"version\":6}"`, "got %s", gltf::read_gltf_member(out, mine[..]));
}

// The one-call form over a real file, with the buffer still intact after it.
fn void test_patching_a_file_in_place()
{
	char[] source = file::load(mem, TRUCK)!!;
	defer free(source);

	String path = "test/out_truck_patched.glb";
	file::save(path, source)!!;
	defer (void)file::delete(path);

	gltf::patch_extra(mem, path, "crig", `{"version":6,"reach":{"hips":0.25}}`)!!;

	GlbParts before = gltf::split_glb(mem, TRUCK)!!;
	defer before.free(mem);
	GlbParts after = gltf::split_glb(mem, path)!!;
	defer after.free(mem);

	assert(@same_bytes(before.rest, after.rest), "the buffer chunk is untouched");

	// Read back through the ordinary parser, which is how a consumer gets it: the
	// extras map is string-valued, so a structured payload rides as its own text.
	GltfStream stream = gltf::open(path)!!;
	defer stream.close();
	assert(stream.gltf.extras.get("crig")!! == `{"version":6,"reach":{"hips":0.25}}`);
	assert(stream.gltf.meshes.len() > 0, "and it is still a glTF");
}

<*
 Numbers come back as the numbers they went in as.

 The check that says why the text is spliced rather than reprinted: `%g` gives six
 significant digits, so a node translation reprinted through it is wrong in the
 fourth decimal place and wrong everywhere in the model.
*>
fn void test_a_double_survives_being_written()
{
	double[4] awkward = { 0.352910727, 1.0 / 3.0, 1.0e-8, 123456789.123456789 };

	foreach (value : awkward)
	{
		DString out = dstring::new(mem);
		defer out.free();
		gltf::write_json_double(&out, value);

		double back = out.str_view().to_double()!!;
		assert(back == value, "%s did not round-trip", out.str_view());
	}

	// Readable where it can be: a value that needs no digits does not get
	// seventeen of them.
	DString half = dstring::new(mem);
	defer half.free();
	gltf::write_json_double(&half, 0.5);
	assert(half.str_view() == "0.5", "got %s", half.str_view());

	// And nothing that cannot be JSON.
	DString bad = dstring::new(mem);
	defer bad.free();
	gltf::write_json_double(&bad, (double)(0.0 / 0.0));
	assert(bad.str_view() == "null", "got %s", bad.str_view());
}

// The escapes JSON names, and the control characters it does not.
fn void test_a_string_is_escaped()
{
	DString out = dstring::new(mem);
	defer out.free();

	gltf::escape_json_string(&out, "Glass \"front\"\\back\n\x01 é");
	assert(out.str_view() == `"Glass \"front\"\\back\n\u0001 é"`, "got %s", out.str_view());
}

<*
 A key of the same name nested inside something else is not the root's.

 `extras` occurs on nodes, on meshes, on primitives; `name` occurs a thousand
 times. A scanner that matched the first one it saw would edit whichever happened
 to come first in the file, which is a different member on every asset.
*>
fn void test_a_nested_key_of_the_same_name_is_not_matched()
{
	String text = `{"nodes":[{"extras":{"deep":"no"}}],"scene":0}`;

	gltf::JsonStep[2] root = { { .key = gltf::GLTF_EXTRAS }, { .key = "top" } };
	gltf::JsonEdit[1] edits = { { .path = root[..], .value = "yes" } };

	String out = gltf::patch_gltf_text(mem, text, edits[..])!!;
	defer out.free(mem);

	assert(out == `{"extras":{"top":"yes"},"nodes":[{"extras":{"deep":"no"}}],"scene":0}`, "got %s", out);

	// And the nested one is still exactly where it was.
	gltf::JsonStep[3] nested = { { .key = "nodes" }, { .at = 0 }, { .key = "extras" } };
	assert(gltf::read_gltf_member(out, nested[..]) == `{"deep":"no"}`, "got %s", gltf::read_gltf_member(out, nested[..]));
}

<*
 Braces and brackets inside a string close nothing.

 Texture URIs, material names and copyright strings all carry punctuation, and a
 scanner that counted depth without knowing where the strings are would lose its
 place partway through the file and edit at an offset that means nothing.
*>
fn void test_punctuation_inside_a_string_is_not_structure()
{
	String text = `{"images":[{"uri":"a}b],c\"d"}],"scene":"7"}`;

	gltf::JsonStep[1] scene = { { .key = "scene" } };
	assert(gltf::read_gltf_member(text, scene[..]) == `"7"`, "got %s", gltf::read_gltf_member(text, scene[..]));

	gltf::JsonStep[3] uri = { { .key = "images" }, { .at = 0 }, { .key = "uri" } };
	assert(gltf::read_gltf_member(text, uri[..]) == `"a}b],c\"d"`, "got %s", gltf::read_gltf_member(text, uri[..]));
}
