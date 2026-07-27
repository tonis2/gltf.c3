module gltf_writer_test @test;

import std::io;
import std::io::file;
import std::core;
import std::math;
import std::math::matrix;
import std::math::vector;
import std::collections::list;
import gltf;

// Every test writes a file and reads it back with this library's own parser:
// the writer is only correct if what it produces is something the reader
// already knew how to handle.

const float EPSILON = 0.0001;

// A macro, not a function: every fn in an @test module is collected as a test.
macro bool near(float a, float b) => math::abs(a - b) < EPSILON;

fn void test_write_triangle() {
    Vec3[3] positions = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } };
    Vec3[3] normals = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
    uint[3] indices = { 0, 1, 2 };

    GltfBuilder builder = gltf::builder();
    defer builder.free();

    WriteAttribute[2] attributes = {
        { .name = "POSITION", .accessor = builder.add_positions(positions[..]) },
        { .name = "NORMAL", .accessor = builder.add_vec3(normals[..]) },
    };

    uint mesh = builder.add_mesh("Triangle");
    builder.add_primitive(mesh, attributes[..], indices: (int)builder.add_indices(indices[..]));
    builder.add_root(builder.add_node("Triangle", mesh: (int)mesh));

    builder.save_glb("test/out_triangle.glb")!!;
    defer (void)file::delete("test/out_triangle.glb");

    GltfStream stream = gltf::open("test/out_triangle.glb")!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    assert(stream.gltf.meshes.len() == 1);
    assert(stream.gltf.meshes[0].name == "Triangle");
    assert(stream.gltf.nodes.len() == 1);
    assert(stream.gltf.scenes[0].nodes.len() == 1);

    Primitive primitive = stream.gltf.meshes[0].primitives[0];
    Accessor position_accessor = stream.gltf.accessors[primitive.attributes["POSITION"]!!];
    assert(position_accessor.count == 3);
    assert(position_accessor.type == AccessorType.VEC3);

    // Positions survive the trip bit for bit — they go through the binary
    // chunk, not through the JSON.
    for (uint i = 0; i < 3; i++) {
        Vec3 read = stream.@cast_buffer(position_accessor, i, Vec3);
        assert(read.x == positions[i].x && read.y == positions[i].y && read.z == positions[i].z);
    }

    // Bounds are required on POSITION, and must actually bound the data.
    assert(near(position_accessor.min[0], 0) && near(position_accessor.min[1], 0));
    assert(near(position_accessor.max[0], 1) && near(position_accessor.max[1], 1));

    Accessor index_accessor = stream.gltf.accessors[primitive.attributes["indices"]!!];
    assert(index_accessor.count == 3);
    assert(index_accessor.data_type == DataType.USHORT);
    for (uint i = 0; i < 3; i++) {
        assert(stream.@cast_buffer(index_accessor, i, ushort) == (ushort)indices[i]);
    }
}

fn void test_glb_container() {
    Vec3[3] positions = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } };

    GltfBuilder builder = gltf::builder();
    defer builder.free();

    WriteAttribute[1] attributes = { { .name = "POSITION", .accessor = builder.add_positions(positions[..]) } };
    uint mesh = builder.add_mesh("T");
    builder.add_primitive(mesh, attributes[..]);
    builder.add_root(builder.add_node("T", mesh: (int)mesh));

    char[] data = builder.to_glb(mem)!!;
    defer free(data);

    assert(data[0] == 'g' && data[1] == 'l' && data[2] == 'T' && data[3] == 'F');

    uint version = (uint)data[4] | ((uint)data[5] << 8) | ((uint)data[6] << 16) | ((uint)data[7] << 24);
    uint total = (uint)data[8] | ((uint)data[9] << 8) | ((uint)data[10] << 16) | ((uint)data[11] << 24);
    assert(version == 2);
    assert(total == data.len);

    // Chunks are 4-byte aligned, which is what makes the binary readable in
    // place rather than needing a copy.
    uint json_length = (uint)data[12] | ((uint)data[13] << 8) | ((uint)data[14] << 16) | ((uint)data[15] << 24);
    assert(json_length % 4 == 0);
    assert(data[16] == 'J' && data[17] == 'S' && data[18] == 'O' && data[19] == 'N');

    sz bin_header = 20 + (sz)json_length;
    assert(data[bin_header + 4] == 'B' && data[bin_header + 5] == 'I' && data[bin_header + 6] == 'N');
}

fn void test_write_gltf_embedded() {
    Vec3[3] positions = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } };

    GltfBuilder builder = gltf::builder();
    defer builder.free();

    WriteAttribute[1] attributes = { { .name = "POSITION", .accessor = builder.add_positions(positions[..]) } };
    uint mesh = builder.add_mesh("T");
    builder.add_primitive(mesh, attributes[..]);
    builder.add_root(builder.add_node("T", mesh: (int)mesh));

    builder.save_gltf("test/out_embedded.gltf")!!;
    defer (void)file::delete("test/out_embedded.gltf");

    GltfStream stream = gltf::open("test/out_embedded.gltf")!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    Accessor accessor = stream.gltf.accessors[stream.gltf.meshes[0].primitives[0].attributes["POSITION"]!!];
    assert(accessor.count == 3);
    Vec3 read = stream.@cast_buffer(accessor, 1, Vec3);
    assert(read.x == 1.0 && read.y == 0.0);
}

// Float precision is the one thing the JSON path can lose: bounds are written
// as text. 9 significant digits round-trips a float exactly.
fn void test_float_precision() {
    Vec3[2] positions = { { 0.123456789, -1234.56789, 0.000001234 }, { 3.14159265, 2.71828182, 1.41421356 } };

    GltfBuilder builder = gltf::builder();
    defer builder.free();

    WriteAttribute[1] attributes = { { .name = "POSITION", .accessor = builder.add_positions(positions[..]) } };
    uint mesh = builder.add_mesh("P");
    builder.add_primitive(mesh, attributes[..]);
    builder.add_root(builder.add_node("P", mesh: (int)mesh));

    builder.save_glb("test/out_precision.glb")!!;
    defer (void)file::delete("test/out_precision.glb");

    GltfStream stream = gltf::open("test/out_precision.glb")!!;
    defer stream.close();

    Accessor accessor = stream.gltf.accessors[stream.gltf.meshes[0].primitives[0].attributes["POSITION"]!!];
    assert(accessor.min[0] == positions[0].x);
    assert(accessor.min[1] == positions[0].y);
    assert(accessor.max[0] == positions[1].x);
}

// --- Skinning ---

fn void test_sparsify_picks_strongest() {
    // One vertex, five bones. The two strongest are bone 3 (0.5) and bone 1
    // (0.3); the rest is a tail that gets dropped.
    float[5] dense = { 0.05, 0.3, 0.1, 0.5, 0.05 };

    SkinBinding binding = gltf::sparsify_weights(mem, dense[..], 1, 5, 2)!!;
    defer binding.free(mem);

    assert(binding.slots == 4); // rounded up to a full glTF set
    assert(binding.joints[0] == 3);
    assert(binding.joints[1] == 1);

    // The kept weights are rescaled to sum to 1 — 0.5 and 0.3 become 0.625
    // and 0.375 — because glTF blends by weight without normalising, and a
    // sum of 0.8 would pull the vertex 20% toward the origin.
    assert(near(binding.weights[0], 0.625));
    assert(near(binding.weights[1], 0.375));
    assert(near(binding.weights[0] + binding.weights[1], 1.0));
    assert(binding.weights[2] == 0 && binding.weights[3] == 0);
}

fn void test_sparsify_normalizes_every_vertex() {
    float[9] dense = {
        1.0, 0.0, 0.0,
        0.2, 0.2, 0.2,
        0.9, 0.05, 0.05,
    };

    SkinBinding binding = gltf::sparsify_weights(mem, dense[..], 3, 3, 4)!!;
    defer binding.free(mem);

    for (usz v = 0; v < 3; v++) {
        float total = 0;
        for (uint i = 0; i < 4; i++) total += binding.weights[v * 4 + i];
        assert(near(total, 1.0));
    }
}

// A vertex no bone reaches would otherwise get all-zero weights and collapse
// to the origin, which reads as a torn mesh. It is pinned to joint 0 instead.
fn void test_sparsify_unweighted_vertex() {
    float[3] dense = { 0.0, 0.0, 0.0 };

    SkinBinding binding = gltf::sparsify_weights(mem, dense[..], 1, 3, 4)!!;
    defer binding.free(mem);

    assert(binding.joints[0] == 0);
    assert(binding.weights[0] == 1.0);
}

fn void test_sparsify_rejects_bad_size() {
    float[5] dense = { 0, 0, 0, 0, 0 };
    // 2 vertices by 3 bones needs 6 weights, not 5.
    assert(@catch(gltf::sparsify_weights(mem, dense[..], 2, 3, 4)) == gltf::WEIGHT_SIZE_MISMATCH);
}

fn void test_inverse_bind_matrices() {
    Matrix4f translated = matrix::IDENTITY4;
    translated.m[12] = 2.0;
    translated.m[13] = 3.0;
    translated.m[14] = 4.0;

    Matrix4f[1] world = { translated };
    Matrix4f[] inverse = gltf::inverse_bind_matrices(mem, world[..]);
    defer free(inverse);

    // Inverting a pure translation negates it.
    assert(near(inverse[0].m[12], -2.0));
    assert(near(inverse[0].m[13], -3.0));
    assert(near(inverse[0].m[14], -4.0));
}

fn void test_write_skinned_glb() {
    // A quad, and a two-bone chain running up the Y axis through it.
    Vec3[4] positions = { { -1, 0, 0 }, { 1, 0, 0 }, { -1, 2, 0 }, { 1, 2, 0 } };
    Vec3[4] normals = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
    uint[6] indices = { 0, 1, 2, 1, 3, 2 };

    Bone[2] bones = {
        { .name = "root", .parent = -1, .position = { 0, 0, 0 } },
        { .name = "tip", .parent = 0, .position = { 0, 2, 0 } },
    };

    // The bottom two vertices belong to the root, the top two to the tip.
    float[8] weights = {
        1.0, 0.0,
        1.0, 0.0,
        0.0, 1.0,
        0.0, 1.0,
    };

    SkinnedMesh mesh = {
        .name = "Quad",
        .positions = positions[..],
        .normals = normals[..],
        .indices = indices[..],
        .bones = bones[..],
        .weights = weights[..],
    };

    gltf::write_skinned_glb("test/out_skinned.glb", mesh)!!;
    defer (void)file::delete("test/out_skinned.glb");

    GltfStream stream = gltf::open("test/out_skinned.glb")!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    assert(stream.gltf.skins.len() == 1);
    Skin skin = stream.gltf.skins[0];
    assert(skin.joints.len() == 2);

    // The skeleton is a chain: the root joint owns the tip.
    Node root_joint = stream.gltf.nodes[skin.joints[0]];
    assert(root_joint.name == "root");
    assert(root_joint.children.len() == 1);
    assert(root_joint.children[0] == skin.joints[1]);

    // Joint translations are parent-relative, so the tip sits 2 above the root
    // rather than repeating its model-space position.
    Node tip_joint = stream.gltf.nodes[skin.joints[1]];
    assert(tip_joint.name == "tip");
    assert(near(tip_joint.translation.y, 2.0));

    // The mesh node carries the skin, and some node must, or nothing deforms.
    bool found_skinned_node = false;
    foreach (node : stream.gltf.nodes) {
        if (node.has_skin() && node.has_mesh()) found_skinned_node = true;
    }
    assert(found_skinned_node);

    Primitive primitive = stream.gltf.meshes[0].primitives[0];
    assert(primitive.attributes.has_key("JOINTS_0"));
    assert(primitive.attributes.has_key("WEIGHTS_0"));

    Accessor joints_accessor = stream.gltf.accessors[primitive.attributes["JOINTS_0"]!!];
    Accessor weights_accessor = stream.gltf.accessors[primitive.attributes["WEIGHTS_0"]!!];
    assert(joints_accessor.count == 4);
    assert(weights_accessor.count == 4);
    assert(joints_accessor.type == AccessorType.VEC4);
    assert(joints_accessor.data_type == DataType.CHAR); // two bones fit in a byte

    // Bottom vertices ride the root, top vertices ride the tip, each fully.
    char[4] bottom = stream.@cast_buffer(joints_accessor, 0, char[4]);
    Vec4 bottom_weights = stream.@cast_buffer(weights_accessor, 0, Vec4);
    assert(bottom[0] == 0);
    assert(near(bottom_weights.x, 1.0));

    char[4] top = stream.@cast_buffer(joints_accessor, 2, char[4]);
    Vec4 top_weights = stream.@cast_buffer(weights_accessor, 2, Vec4);
    assert(top[0] == 1);
    assert(near(top_weights.x, 1.0));

    // Inverse bind matrices undo each joint's bind-pose world transform.
    Accessor bind_accessor = stream.gltf.accessors[skin.inverseBindAccessor];
    assert(bind_accessor.count == 2);
    assert(bind_accessor.type == AccessorType.MAT4);

    Matrix4f tip_bind = stream.@cast_buffer(bind_accessor, 1, Matrix4f);
    assert(near(tip_bind.m[13], -2.0));
}
