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

macro bool is_set(Vec3 value) => value.x != 0 || value.y != 0 || value.z != 0;

macro usz count_of(String haystack, String needle) {
    usz found = 0;
    usz at = 0;
    while (at + needle.len <= haystack.len) {
        if (haystack[at:needle.len] == needle) {
            found++;
            at += needle.len;
            continue;
        }
        at++;
    }
    return found;
}

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

// A bone's direction has to survive the round trip, and it has to survive it
// without disturbing the bind pose. Those pull against each other: the moment a
// joint node carries a rotation, its children's translations are expressed in a
// rotated frame and its inverse bind matrix stops being a pure translation.
fn void test_skeleton_carries_bone_direction() {
    Vec3[3] positions = { { -1, 0, 0 }, { 1, 0, 0 }, { 0, 2, 0 } };
    uint[3] indices = { 0, 1, 2 };

    // A chain that turns two corners, so no two bones share a direction and a
    // frame mistake has nothing to cancel against.
    Bone[3] bones = {
        { .name = "root", .parent = -1, .position = { 0, 0, 0 }, .direction = { 0, 2, 0 } },
        { .name = "mid",  .parent =  0, .position = { 0, 2, 0 }, .direction = { 3, 0, 0 } },
        { .name = "tip",  .parent =  1, .position = { 3, 2, 0 }, .direction = { 0, 0, 1 } },
    };

    float[9] weights = { 1, 0, 0,  1, 0, 0,  0, 1, 0 };

    SkinnedMesh mesh = {
        .name = "Bent",
        .positions = positions[..],
        .indices = indices[..],
        .bones = bones[..],
        .weights = weights[..],
    };

    gltf::write_skinned_glb("test/out_oriented.glb", mesh)!!;
    defer (void)file::delete("test/out_oriented.glb");

    GltfStream stream = gltf::open("test/out_oriented.glb")!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    Skin skin = stream.gltf.skins[0];
    assert(skin.joints.len() == 3);

    // Compose the chain by hand. World, not local: a child's rotation is stored
    // relative to its parent's, so reading a local one back would only prove
    // the writer agrees with itself.
    Matrix4f[3] world;
    world[0] = stream.gltf.nodes[skin.joints[0]].local_matrix();
    world[1] = world[0].mul(stream.gltf.nodes[skin.joints[1]].local_matrix());
    world[2] = world[1].mul(stream.gltf.nodes[skin.joints[2]].local_matrix());

    Vec3[3] axis = { { 0, 1, 0 }, { 1, 0, 0 }, { 0, 0, 1 } };
    Vec3[3] origin = { { 0, 0, 0 }, { 0, 2, 0 }, { 3, 2, 0 } };

    for (usz i = 0; i < 3; i++) {
        // A bone runs along its node's -Z; column 2 of a column-major matrix is
        // where local +Z ended up, so the bone is its negation.
        assert(near(-world[i].m[8], axis[i].x), "joint %d bone axis x", i);
        assert(near(-world[i].m[9], axis[i].y), "joint %d bone axis y", i);
        assert(near(-world[i].m[10], axis[i].z), "joint %d bone axis z", i);

        assert(near(world[i].m[12], origin[i].x), "joint %d position x", i);
        assert(near(world[i].m[13], origin[i].y), "joint %d position y", i);
        assert(near(world[i].m[14], origin[i].z), "joint %d position z", i);
    }

    // And the bind pose still cancels: world(joint) * inverseBind == identity,
    // which is what keeps the mesh undeformed until something is actually posed.
    Accessor bind = stream.gltf.accessors[skin.inverseBindAccessor];
    assert(bind.count == 3);

    for (usz i = 0; i < 3; i++) {
        Matrix4f inverse = stream.@cast_buffer(bind, (sz)i, Matrix4f);
        Matrix4f product = world[i].mul(inverse);
        for (usz e = 0; e < 16; e++) {
            float want = (e % 5 == 0) ? 1.0f : 0.0f;
            assert(near(product.m[e], want), "joint %d bind pose element %d", i, e);
        }
    }
}

// The old behaviour has to stay reachable: a caller with nothing but joint
// positions leaves direction zero and gets unrotated nodes, which is honest —
// the file then says nothing about which way the bones face rather than
// claiming they all face +Y.
fn void test_skeleton_without_direction_is_unrotated() {
    Vec3[3] positions = { { -1, 0, 0 }, { 1, 0, 0 }, { 0, 2, 0 } };
    uint[3] indices = { 0, 1, 2 };
    Bone[2] bones = {
        { .name = "root", .parent = -1, .position = { 0, 0, 0 } },
        { .name = "tip",  .parent =  0, .position = { 0, 2, 0 } },
    };
    float[6] weights = { 1, 0,  1, 0,  0, 1 };

    SkinnedMesh mesh = {
        .name = "Plain",
        .positions = positions[..],
        .indices = indices[..],
        .bones = bones[..],
        .weights = weights[..],
    };

    gltf::write_skinned_glb("test/out_plain.glb", mesh)!!;
    defer (void)file::delete("test/out_plain.glb");

    GltfStream stream = gltf::open("test/out_plain.glb")!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    Skin skin = stream.gltf.skins[0];
    foreach (joint : skin.joints) {
        Quaternionf rotation = stream.gltf.nodes[joint].rotation;
        assert(near(rotation.v[0], 0.0) && near(rotation.v[1], 0.0)
            && near(rotation.v[2], 0.0) && near(rotation.v[3], 1.0),
            "an undirected bone should leave its node unrotated");
    }

    // Parent-relative translation, exactly as before.
    assert(near(stream.gltf.nodes[skin.joints[1]].translation.y, 2.0));
}

// --- Animation ---

fn void test_write_animation() {
    // A two-joint chain: the root turns, the child slides and pulses.
    GltfBuilder builder = gltf::builder();
    defer builder.free();

    uint root = builder.add_node("root");
    uint child = builder.add_node("child", translation: { 0, 1, 0 });
    builder.add_child(root, child);
    builder.add_root(root);

    float[3] times = { 0.5, 1.5, 2.0 };
    Quaternionf[3] turns = { { 0, 0, 0, 1 }, { 0, 0.7071, 0, 0.7071 }, { 0, 0, 0, 1 } };
    Vec3[3] slides = { { 0, 1, 0 }, { 0, 2, 0 }, { 0, 1, 0 } };
    Vec3[3] pulses = { { 1, 1, 1 }, { 2, 2, 2 }, { 1, 1, 1 } };

    uint input = builder.add_times(times[..]);
    uint clip = builder.add_animation("Wave");
    builder.add_channel(clip, builder.add_sampler(clip, input, builder.add_rotations(turns[..])), root, ROTATION);
    builder.add_channel(clip, builder.add_sampler(clip, input, builder.add_vectors(slides[..])), child, TRANSLATION);
    builder.add_channel(clip, builder.add_sampler(clip, input, builder.add_vectors(pulses[..]), STEP), child, SCALE);

    builder.save_glb("test/out_animation.glb")!!;
    defer (void)file::delete("test/out_animation.glb");

    GltfStream stream = gltf::open("test/out_animation.glb")!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    assert(stream.gltf.animations.len() == 1);
    Animation clip_back = stream.gltf.animations[0];
    assert(clip_back.name == "Wave");
    assert(clip_back.samplers.len() == 3);
    assert(clip_back.channels.len() == 3);

    // The duration the parser reports is read off the input accessor's bounds,
    // so a sampler input written without min/max reads back as 0..0 and every
    // clip in the file claims to be instantaneous.
    assert(near(clip_back.min_time, 0.5) && near(clip_back.max_time, 2.0));

    assert(clip_back.channels[0].target.node == root);
    assert(clip_back.channels[0].target.path == AnimationProperty.ROTATION);
    assert(clip_back.channels[1].target.node == child);
    assert(clip_back.channels[1].target.path == AnimationProperty.TRANSLATION);
    assert(clip_back.channels[2].target.path == AnimationProperty.SCALE);

    // LINEAR is the glTF default and is left out; STEP has to be written. Both
    // spellings are checked here because the omission and the parser's default
    // have to agree or every clip silently changes shape.
    assert(clip_back.samplers[0].interpolation == Interpolation.LINEAR);
    assert(clip_back.samplers[2].interpolation == Interpolation.STEP);

    // One run of key times shared by all three curves, which is the whole point
    // of samplers being separate from channels.
    assert(clip_back.samplers[0].input == clip_back.samplers[1].input);
    assert(clip_back.samplers[1].input == clip_back.samplers[2].input);

    Accessor rotations = stream.gltf.accessors[clip_back.samplers[0].output];
    assert(rotations.count == 3 && rotations.type == AccessorType.VEC4);
    for (uint i = 0; i < 3; i++) {
        Vec4 read = stream.@cast_buffer(rotations, i, Vec4);
        assert(near(read.x, turns[i].v[0]) && near(read.y, turns[i].v[1])
            && near(read.z, turns[i].v[2]) && near(read.w, turns[i].v[3]));
    }

    Accessor translations = stream.gltf.accessors[clip_back.samplers[1].output];
    assert(translations.count == 3 && translations.type == AccessorType.VEC3);
    for (uint i = 0; i < 3; i++) {
        Vec3 read = stream.@cast_buffer(translations, i, Vec3);
        assert(near(read.y, slides[i].y));
    }
}

fn void test_animation_views_have_no_target() {
    // glTF reserves bufferView.target for vertex and index data; a view without
    // one is how a reader is told it holds animation or skin data instead.
    // Nothing here is vertex data, so nothing may carry a target.
    GltfBuilder builder = gltf::builder();
    defer builder.free();

    uint node = builder.add_node("joint");
    builder.add_root(node);

    float[2] times = { 0, 1 };
    Quaternionf[2] turns = { { 0, 0, 0, 1 }, { 0, 0, 0, 1 } };
    Vec3[2] slides = { { 0, 0, 0 }, { 0, 1, 0 } };

    uint input = builder.add_times(times[..]);
    uint clip = builder.add_animation("Move");
    builder.add_channel(clip, builder.add_sampler(clip, input, builder.add_rotations(turns[..])), node, ROTATION);
    builder.add_channel(clip, builder.add_sampler(clip, input, builder.add_vectors(slides[..])), node, TRANSLATION);

    DString json = builder.to_json(mem);
    defer json.free();

    // Checked in the text: Targets has no "absent" value, so a parsed
    // BufferView cannot tell the two apart and only the JSON can answer.
    //
    // Matched with the value attached, because a channel's target is also
    // spelled "target" and is an object — the two bufferView targets are 34962
    // and 34963, so a digit is enough to tell them apart.
    assert(!json.str_view().contains(`"target":3`),
        "animation sampler data must not tag its bufferView with a target");
}

// --- Extras ---

fn void test_write_extras() {
    GltfBuilder builder = gltf::builder();
    defer builder.free();

    builder.add_root(builder.add_node("root"));
    builder.set_extra("plan", "biped");
    builder.set_extra("tags", "biped, humanoid");
    builder.set_extra("version", "1");

    // Last write wins, so metadata can be assembled in pieces.
    builder.set_extra("plan", "quadruped");

    // A value typed by a human, not an exporter: it has to survive as itself
    // rather than ending the JSON string early.
    builder.set_extra("name", `The "Big" Pack`);

    // Checked in the text rather than through the parser: a JSON object with
    // the same key twice collapses on the way back in, so a builder that
    // appended instead of replacing reads back correctly here while writing a
    // file whose first "plan" some other parser takes instead.
    DString json = builder.to_json(mem);
    defer json.free();
    assert(count_of(json.str_view(), `"plan":`) == 1, "a replaced key must be written once");

    builder.save_glb("test/out_extras.glb")!!;
    defer (void)file::delete("test/out_extras.glb");

    GltfStream stream = gltf::open("test/out_extras.glb")!!;
    defer stream.close();

    assert(stream.gltf.extras.len() == 4, "one entry per key, not per set_extra call");
    assert(stream.gltf.extras["plan"]!! == "quadruped");
    assert(stream.gltf.extras["tags"]!! == "biped, humanoid");
    assert(stream.gltf.extras["version"]!! == "1");
    assert(stream.gltf.extras["name"]!! == `The "Big" Pack`);
}

fn void test_no_extras_writes_no_object() {
    // A document that says nothing about itself must not carry an empty extras
    // object: read_pack-style callers treat its presence as a claim.
    GltfBuilder builder = gltf::builder();
    defer builder.free();

    builder.add_root(builder.add_node("root"));

    DString json = builder.to_json(mem);
    defer json.free();

    assert(!json.str_view().contains(`"extras"`));
}

// --- Physics ---

fn void test_write_physics() {
    GltfBuilder builder = gltf::builder();
    defer builder.free();

    // Two shapes, so the index a collider names has to be the right one rather
    // than the only one.
    uint sphere = builder.add_shape({ .type = SPHERE, .radius = 0.4 });
    uint capsule = builder.add_shape({
        .type = CAPSULE,
        .height = 1.2,
        .radius_bottom = 0.25,
        .radius_top = 0.3,
    });

    // AVERAGE is the zero value of PhysicsCombine and the parser's default is
    // MULTIPLY, so a material that does not write its combine rules out loud
    // reads back as a different material.
    uint material = builder.add_physics_material({
        .static_friction = 0.6,
        .dynamic_friction = 0.4,
        .restitution = 0.2,
        .friction_combine = AVERAGE,
        .restitution_combine = MINIMUM,
    });

    CollisionFilter filter;
    filter.systems.init(mem);
    filter.colliding_with.init(mem);
    filter.not_colliding.init(mem);
    defer filter.free();
    filter.systems.push("limbs");
    filter.colliding_with.push("ground");
    filter.colliding_with.push("props");
    filter.not_colliding.push("limbs");
    uint filter_index = builder.add_collision_filter(filter);

    PhysicsJoint settings;
    settings.angular_limits.init(mem);
    settings.linear_limits.init(mem);
    settings.drives.init(mem);
    defer settings.free();
    settings.angular_limits.push({ .axes = { 0, 1, 1 }, .min = -0.4, .max = 0.4 });
    uint joint_settings = builder.add_physics_joint_settings(settings);

    uint pelvis = builder.add_node("pelvis");
    uint thigh = builder.add_node("thigh", translation: { 0, -0.5, 0 });
    uint sensor = builder.add_node("sensor", translation: { 0, -1.2, 0 });
    builder.add_child(pelvis, thigh);
    builder.add_child(pelvis, sensor);
    builder.add_root(pelvis);

    builder.add_motion(pelvis, {
        .mass = 12.5,
        .gravity_factor = 0.8,
        .linear_dampening = 0.05,
        .angular_dampening = 0.1,
        .mass_center = { 0, 0.1, 0 },
        .inertia_diagonal = { 0.3, 0.2, 0.3 },
        .inertia_orientation = { 0, 0, 0, 1 },
        .angular_velocity = { 1, 0, 0 },
    });

    builder.add_collider(thigh, {
        .shape = (int)capsule,
        .node = -1,
        .material = (int)material,
        .collision_filter = (int)filter_index,
        .mesh = -1,
        .base_node = -1,
    });

    // The same object under a different key: a trigger reports overlaps rather
    // than resisting them, and the parser tells the two apart by the key alone.
    builder.add_collider(sensor, {
        .shape = (int)sphere,
        .node = -1,
        .material = -1,
        .collision_filter = -1,
        .mesh = -1,
        .base_node = -1,
        .is_trigger = true,
    });

    builder.add_node_joint(thigh, pelvis, joint_settings, enable_collision: true);

    // Named once each, however many objects use them.
    DString json = builder.to_json(mem);
    defer json.free();
    assert(count_of(json.str_view(), `"extensionsUsed"`) == 1);
    assert(json.str_view().contains(`"extensionsUsed":["KHR_implicit_shapes","KHR_physics_rigid_bodies"]`),
        "both extensions have to be declared, and each only once");

    builder.save_glb("test/out_physics.glb")!!;
    defer (void)file::delete("test/out_physics.glb");

    GltfStream stream = gltf::open("test/out_physics.glb")!!;
    defer stream.close();

    assert(stream.gltf.shapes.len() == 2);
    Shape capsule_back = stream.gltf.shapes[capsule];
    assert(capsule_back.type == ShapeType.CAPSULE);
    assert(near(capsule_back.height, 1.2));
    assert(near(capsule_back.radius_bottom, 0.25));
    assert(near(capsule_back.radius_top, 0.3));
    assert(stream.gltf.shapes[sphere].type == ShapeType.SPHERE);
    assert(near(stream.gltf.shapes[sphere].radius, 0.4));

    assert(stream.gltf.physics_materials.len() == 1);
    PhysicsMaterial material_back = stream.gltf.physics_materials[material];
    assert(near(material_back.static_friction, 0.6));
    assert(near(material_back.dynamic_friction, 0.4));
    assert(near(material_back.restitution, 0.2));
    assert(material_back.friction_combine == PhysicsCombine.AVERAGE);
    assert(material_back.restitution_combine == PhysicsCombine.MINIMUM);

    assert(stream.gltf.collision_filters.len() == 1);
    CollisionFilter filter_back = stream.gltf.collision_filters[filter_index];
    assert(filter_back.systems.len() == 1 && filter_back.systems[0] == "limbs");
    assert(filter_back.colliding_with.len() == 2);
    assert(filter_back.colliding_with[0] == "ground" && filter_back.colliding_with[1] == "props");
    assert(filter_back.not_colliding.len() == 1 && filter_back.not_colliding[0] == "limbs");

    Node pelvis_back = stream.gltf.nodes[pelvis];
    assert(pelvis_back.has_motion());
    Motion motion_back = stream.gltf.motions[(uint)pelvis_back.motion];
    assert(near(motion_back.mass, 12.5));
    assert(near(motion_back.gravity_factor, 0.8));
    assert(near(motion_back.linear_dampening, 0.05));
    assert(near(motion_back.angular_dampening, 0.1));
    assert(!motion_back.is_kinematic);
    assert(near(motion_back.mass_center.y, 0.1));
    assert(near(motion_back.inertia_diagonal.x, 0.3) && near(motion_back.inertia_diagonal.y, 0.2));
    assert(near(motion_back.inertia_orientation.v[3], 1.0));
    assert(near(motion_back.angular_velocity.x, 1.0));
    assert(!is_set(motion_back.linear_velocity), "a velocity nobody set must not arrive as one");

    Node thigh_back = stream.gltf.nodes[thigh];
    assert(thigh_back.has_collider());
    Collider collider_back = stream.gltf.colliders[(uint)thigh_back.collider];
    assert(collider_back.shape == (int)capsule);
    assert(collider_back.material == (int)material);
    assert(collider_back.collision_filter == (int)filter_index);
    assert(!collider_back.is_trigger);
    assert(!collider_back.convex_hull);
    assert(collider_back.base_node == (int)thigh);

    Node sensor_back = stream.gltf.nodes[sensor];
    assert(sensor_back.has_collider());
    Collider trigger_back = stream.gltf.colliders[(uint)sensor_back.collider];
    assert(trigger_back.is_trigger, "a trigger written under 'collider' would resist instead of report");
    assert(trigger_back.shape == (int)sphere);
    assert(!trigger_back.has_material() && !trigger_back.has_filter());

    // The joint hangs on one of the two bodies and names the other.
    assert(thigh_back.has_joint());
    assert(thigh_back.joint == (int)joint_settings);
    assert(thigh_back.connected_node == (int)pelvis);
    assert(thigh_back.enable_collision);
    assert(!pelvis_back.has_joint(), "the joint is written once, not from both ends");
}

// A limit over two axes is a cone, and the two things that could quietly turn
// it into a pair of hinges are the writer splitting the mask and the parser
// splitting the array.
fn void test_joint_limits_and_drives() {
    GltfBuilder builder = gltf::builder();
    defer builder.free();

    PhysicsJoint settings;
    settings.angular_limits.init(mem);
    settings.linear_limits.init(mem);
    settings.drives.init(mem);
    defer settings.free();

    // Locked: the bodies stay coincident. Both bounds are zero, which is the
    // case an "omit what is zero" writer loses — an absent bound reads as free.
    settings.linear_limits.push({ .axes = { 1, 1, 1 }, .min = 0, .max = 0 });
    settings.angular_limits.push({ .axes = { 0, 1, 1 }, .min = -0.4, .max = 0.4, .stiffness = 90, .damping = 4 });
    settings.drives.push({
        .type = ANGULAR,
        .drive = FORCE,
        .axis = 1,
        .position_target = 0.35,
        .velocity_target = 0.1,
        .max_force = 25,
        .stiffness = 120,
        .damping = 8,
    });

    uint joint_settings = builder.add_physics_joint_settings(settings);
    uint anchor = builder.add_node("anchor");
    uint swing = builder.add_node("swing");
    builder.add_child(anchor, swing);
    builder.add_root(anchor);
    builder.add_node_joint(swing, anchor, joint_settings);

    // Checked in the text as well: one array holding both axes is what makes it
    // a cone, and a parser that merges two entries back into one mask would
    // hide a writer that split them.
    DString json = builder.to_json(mem);
    defer json.free();
    assert(json.str_view().contains(`"angularAxes":[1,2]`), "the cone's axes belong to one limit");
    assert(count_of(json.str_view(), `"angularAxes"`) == 1);
    assert(json.str_view().contains(`"linearAxes":[0,1,2],"min":0,"max":0`), "a locked axis has to say so");

    builder.save_glb("test/out_joint.glb")!!;
    defer (void)file::delete("test/out_joint.glb");

    GltfStream stream = gltf::open("test/out_joint.glb")!!;
    defer stream.close();

    assert(stream.gltf.physics_joints.len() == 1);
    PhysicsJoint back = stream.gltf.physics_joints[joint_settings];

    assert(back.angular_limits.len() == 1, "two angular axes are one cone, not two hinges");
    Limit cone = back.angular_limits[0];
    assert(cone.axes.x == 0 && cone.axes.y == 1 && cone.axes.z == 1);
    assert(near(cone.min, -0.4) && near(cone.max, 0.4));
    assert(near(cone.stiffness, 90) && near(cone.damping, 4));

    assert(back.linear_limits.len() == 1);
    Limit locked = back.linear_limits[0];
    assert(locked.axes.x == 1 && locked.axes.y == 1 && locked.axes.z == 1);
    assert(locked.min == 0 && locked.max == 0);
    assert(locked.stiffness == 0 && locked.damping == 0);

    assert(back.drives.len() == 1);
    Drive drive = back.drives[0];
    assert(drive.type == DriveType.ANGULAR);
    assert(drive.drive == DriveMode.FORCE);
    assert(drive.axis == 1);
    assert(near(drive.position_target, 0.35));
    assert(near(drive.velocity_target, 0.1));
    assert(near(drive.max_force, 25));
    assert(near(drive.stiffness, 120));
    assert(near(drive.damping, 8));
}

// The parser fills an absent mass with 1 and absent damping with 0.9, so a body
// that really is massless and undamped only survives if those are written.
fn void test_motion_zero_survives_parser_defaults() {
    GltfBuilder builder = gltf::builder();
    defer builder.free();

    uint node = builder.add_node("ghost");
    builder.add_root(node);

    Motion still;
    still.is_kinematic = true;
    builder.add_motion(node, still);

    builder.save_glb("test/out_motion.glb")!!;
    defer (void)file::delete("test/out_motion.glb");

    GltfStream stream = gltf::open("test/out_motion.glb")!!;
    defer stream.close();

    Motion back = stream.gltf.motions[(uint)stream.gltf.nodes[node].motion];
    assert(back.is_kinematic);
    assert(back.mass == 0);
    assert(back.gravity_factor == 0);
    assert(back.linear_dampening == 0);
    assert(back.angular_dampening == 0);
    assert(!is_set(back.mass_center) && !is_set(back.inertia_diagonal));
    assert(!is_set(back.linear_velocity) && !is_set(back.angular_velocity));
}
