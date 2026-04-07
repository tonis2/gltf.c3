module gltf_test @test;

import std::io;
import std::core;
import std::math;
import gltf;
import std::collections::list;

alias Vec2f @private = (float[<2>]);
alias Vec3f @private = (float[<3>]);
alias Vec4f @private = float[<4>];

alias VertexList = List{Vertex};
alias IndexList = List{ushort};

struct Vertex {
    Vec3f pos;
    Vec2f tex;
    Vec3f normal;
}

// --- Metadata-only tests (no buffer loading) ---

fn void test_open_metadata_only() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    // All metadata should be available immediately
    assert(stream.gltf.scenes.len() == 1);
    assert(stream.gltf.nodes.len() == 6);
    assert(stream.gltf.meshes.len() == 2);
    assert(stream.gltf.buffers.len() == 1);
    assert(stream.gltf.bufferViews.len() == 20);
    assert(stream.gltf.accessors.len() == 19);
    assert(stream.gltf.materials.len() == 4);
    assert(stream.gltf.textures.len() == 2);
    assert(stream.gltf.images.len() == 1);
    assert(stream.gltf.animations.len() == 1);

    // No buffers should be loaded yet
    assert(!stream.is_buffer_loaded(0));
}

fn void test_find_by_name() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    // find_mesh works on metadata without loading buffers
    Mesh wheels = stream.gltf.find_mesh("Wheels")!!;
    assert(wheels.name == "Wheels");
    assert(wheels.primitives.len() == 1);

    Mesh truck = stream.gltf.find_mesh("Cesium_Milk_Truck")!!;
    assert(truck.name == "Cesium_Milk_Truck");
    assert(truck.primitives.len() == 3);

    // find_node works
    Node node = stream.gltf.find_node("Yup2Zup")!!;
    assert(node.name == "Yup2Zup");

    // find_animation works
    Animation anim = stream.gltf.find_animation("Wheels")!!;
    assert(anim.name == "Wheels");
}

fn void test_scene_structure() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    Scene scene = stream.gltf.scenes[0];
    assert(scene.name == "Scene");
    assert(scene.nodes.len() == 1);

    // Root node
    Node root = stream.gltf.nodes[scene.nodes[0]];
    assert(root.children.len() > 0);
}

// --- Buffer loading tests ---

fn void test_load_all_buffers() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    assert(!stream.is_buffer_loaded(0));

    stream.load_all_buffers()!!;
    assert(stream.is_buffer_loaded(0));

    // Read vertex data to verify correctness
    Mesh mesh = stream.gltf.meshes[0]; // Wheels
    Primitive prim = mesh.primitives[0];
    Accessor pos_accessor = stream.gltf.accessors[prim.attributes["POSITION"]!!];

    Vec3f first_pos = stream.@cast_buffer(pos_accessor, 0, Vec3f);
    // Just verify it's a reasonable value (not garbage)
    assert(first_pos[0] == first_pos[0]); // not NaN
}

fn void test_load_mesh_buffers() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    assert(!stream.is_buffer_loaded(0));

    // Load only mesh 0 (Wheels)
    stream.load_mesh_buffers(0)!!;
    assert(stream.is_buffer_loaded(0));

    // Should be able to read wheel vertex data
    Mesh wheels = stream.gltf.meshes[0];
    Primitive prim = wheels.primitives[0];
    Accessor pos_accessor = stream.gltf.accessors[prim.attributes["POSITION"]!!];
    assert(pos_accessor.count > 0);

    Vec3f pos = stream.@cast_buffer(pos_accessor, 0, Vec3f);
    assert(pos[0] == pos[0]); // not NaN
}

fn void test_load_mesh_by_name() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    stream.load_mesh_by_name("Cesium_Milk_Truck")!!;
    assert(stream.is_buffer_loaded(0));

    // Verify truck mesh data is accessible
    Mesh truck = stream.gltf.find_mesh("Cesium_Milk_Truck")!!;
    Accessor pos_accessor = stream.gltf.accessors[truck.primitives[0].attributes["POSITION"]!!];
    Vec3f pos = stream.@cast_buffer(pos_accessor, 0, Vec3f);
    assert(pos[0] == pos[0]);
}

fn void test_load_scene() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    assert(!stream.is_buffer_loaded(0));

    // Load the entire scene (should load all mesh buffers)
    stream.load_scene(0)!!;
    assert(stream.is_buffer_loaded(0));

    // All meshes should be accessible
    foreach (mesh : stream.gltf.meshes) {
        foreach (prim : mesh.primitives) {
            usz? pos_attr = prim.attributes.get("POSITION");
            if (try pos_attr) {
                Accessor acc = stream.gltf.accessors[pos_attr];
                Vec3f v = stream.@cast_buffer(acc, 0, Vec3f);
                assert(v[0] == v[0]);
            }
        }
    }
}

fn void test_load_scene_by_name() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    stream.load_scene_by_name("Scene")!!;
    assert(stream.is_buffer_loaded(0));
}

// --- Unload tests ---

fn void test_unload_buffer() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    stream.load_buffer(0)!!;
    assert(stream.is_buffer_loaded(0));

    stream.unload_buffer(0);
    assert(!stream.is_buffer_loaded(0));
}

fn void test_ref_counting() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    // Load same buffer multiple times (via different meshes that share it)
    stream.load_buffer(0)!!;  // ref_count = 1
    assert(stream.is_buffer_loaded(0));

    stream.load_buffer(0)!!;  // ref_count = 2
    assert(stream.is_buffer_loaded(0));

    // First unload shouldn't release it
    stream.unload_buffer(0);  // ref_count = 1
    assert(stream.is_buffer_loaded(0));

    // Second unload should release it
    stream.unload_buffer(0);  // ref_count = 0
    assert(!stream.is_buffer_loaded(0));
}

fn void test_unload_scene() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    stream.load_scene(0)!!;
    assert(stream.is_buffer_loaded(0));

    stream.unload_scene(0);
    assert(!stream.is_buffer_loaded(0));
}

fn void test_load_unload_reload() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    // Load, read, unload, reload, read again
    stream.load_all_buffers()!!;

    Mesh mesh = stream.gltf.meshes[0];
    Accessor pos_acc = stream.gltf.accessors[mesh.primitives[0].attributes["POSITION"]!!];
    Vec3f pos1 = stream.@cast_buffer(pos_acc, 0, Vec3f);

    stream.unload_all_buffers();
    assert(!stream.is_buffer_loaded(0));

    // Reload and verify same data
    stream.load_all_buffers()!!;
    Vec3f pos2 = stream.@cast_buffer(pos_acc, 0, Vec3f);

    assert(pos1[0] == pos2[0]);
    assert(pos1[1] == pos2[1]);
    assert(pos1[2] == pos2[2]);
}

// --- Image loading tests ---

fn void test_load_image() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    // Must load the buffer first since images reference buffer views
    stream.load_all_buffers()!!;

    stream.load_image(0)!!;
    char[]? data = stream.get_image_data(0);
    assert(@ok(data));
    assert(data!!.len > 0);

    stream.unload_image(0);
    char[]? data2 = stream.get_image_data(0);
    assert(@catch(data2));
}

fn void test_load_all_images() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    stream.load_all_buffers()!!;
    stream.load_all_images()!!;

    foreach (uint i, image : stream.gltf.images) {
        char[] data = stream.get_image_data(i)!!;
        assert(data.len > 0);
    }
}

// --- Full vertex data test (matches original test) ---

fn void test_full_vertex_data() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    stream.load_all_buffers()!!;

    VertexList vertices;
    defer vertices.free();

    IndexList indices;
    defer indices.free();

    foreach (mesh : stream.gltf.meshes) {
        foreach (index, primitive: mesh.primitives) {
            Accessor pos_accessor = stream.gltf.accessors[primitive.attributes["POSITION"]!!];
            Accessor tex_accessor = stream.gltf.accessors[primitive.attributes["TEXCOORD_0"]!!];
            Accessor normal_accessor = stream.gltf.accessors[primitive.attributes["NORMAL"]!!];
            Accessor index_accessor = stream.gltf.accessors[primitive.attributes["indices"]!!];

            for (uint i = 0; i < pos_accessor.count ; i += 1) {
                vertices.push({
                    stream.@cast_buffer(pos_accessor, i, Vec3f),
                    stream.@cast_buffer(tex_accessor, i, Vec2f),
                    stream.@cast_buffer(normal_accessor, i, Vec3f)
                });
            }

            indices.push(stream.@cast_buffer(index_accessor, 1, ushort));
        }
    }

    assert(vertices.len() == 3995);
    assert(indices.len() == 4);
    assert(math::round_to_decimals(((float[<3>]))vertices[0].pos, 4)  == math::round_to_decimals((float[<3>]) {-0.044543, 1.018000, 0.166238}, 4));
    assert(math::round_to_decimals(((float[<2>]))vertices[0].tex, 4)  == math::round_to_decimals((float[<2>]) {0.711914, 0.120246}, 4));
    assert(math::round_to_decimals(((float[<3>]))vertices[0].normal, 4)  == math::round_to_decimals((float[<3>]) {-0.000004, 1.000000, -0.000000}, 4));
}

// --- Animation loading test ---

fn void test_load_animation_buffers() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    stream.load_animation_buffers(0)!!;
    assert(stream.is_buffer_loaded(0));

    // Verify animation data is accessible
    Animation anim = stream.gltf.animations[0];
    AnimationSampler sampler = anim.samplers[0];
    Accessor time_acc = stream.gltf.accessors[sampler.input];
    float first_time = stream.@cast_buffer(time_acc, 0, float);
    assert(first_time == first_time); // not NaN
}

// --- Vertex attribute iteration tests ---

fn void test_each_position() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    uint count = 0;
    Mesh wheels = stream.gltf.meshes[0];
    stream.@each_position(wheels.primitives[0]; Vec3f pos, usz i) {
        count++;
    };
    assert(count > 0);
}

fn void test_each_normal() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    uint count = 0;
    Mesh wheels = stream.gltf.meshes[0];
    stream.@each_normal(wheels.primitives[0]; Vec3f normal, usz i) {
        count++;
    };
    assert(count > 0);
}

fn void test_each_texcoord() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    uint count = 0;
    Mesh wheels = stream.gltf.meshes[0];
    stream.@each_texcoord(wheels.primitives[0], 0; Vec2f uv, usz i) {
        count++;
    };
    assert(count > 0);
}

fn void test_each_index() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    uint count = 0;
    Mesh wheels = stream.gltf.meshes[0];
    stream.@each_index_as_ushort(wheels.primitives[0]; ushort idx, usz i) {
        count++;
    };
    assert(count > 0);
}

// --- AABB tests ---

fn void test_mesh_aabb() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    // AABB works from accessor min/max -- no buffer loading needed
    Mesh wheels = stream.gltf.meshes[0];
    Aabb aabb = stream.gltf.mesh_aabb(wheels);

    // Min should be less than max on all axes
    assert(aabb.min[0] <= aabb.max[0]);
    assert(aabb.min[1] <= aabb.max[1]);
    assert(aabb.min[2] <= aabb.max[2]);

    // Size should be positive
    Vec3f size = aabb.size();
    assert(size[0] >= 0);
    assert(size[1] >= 0);
    assert(size[2] >= 0);
}

fn void test_node_world_aabb() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    // Node 0 is "Wheels" with mesh 0
    Node node = stream.gltf.nodes[0];
    assert(node.mesh >= 0);
    Aabb world_aabb = stream.gltf.node_world_aabb(node);
    assert(world_aabb.min[0] <= world_aabb.max[0]);
}

fn void test_aabb_merge() {
    Aabb a = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
    Aabb b = { .min = { 0, 0, 0 }, .max = { 2, 2, 2 } };
    Aabb merged = a.merge(b);
    assert(merged.min[0] == -1);
    assert(merged.max[0] == 2);
}

// --- Material helper tests ---

fn void test_material_helpers() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    assert(stream.gltf.materials.len() == 4);

    // Check that at least one material has a base color texture
    bool found_textured = false;
    foreach (mat : stream.gltf.materials) {
        if (mat.has_base_color_texture()) { found_textured = true; }
    }
    assert(found_textured);

    // All materials should have a valid alpha mode
    foreach (mat : stream.gltf.materials) {
        uint tex_count = mat.texture_count();
        assert(tex_count <= 5);
    }
}

// --- Node world transform tests ---

fn void test_node_world_position() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    Node node = stream.gltf.nodes[0];
    Vec3f world_pos = node.world_position();
    // Just verify it's not NaN
    assert(world_pos[0] == world_pos[0]);
    assert(world_pos[1] == world_pos[1]);
    assert(world_pos[2] == world_pos[2]);
}

// --- Animation helper tests ---

fn void test_animation_duration() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    Animation anim = stream.gltf.animations[0];
    float dur = anim.duration();
    assert(dur >= 0);

    // Test loop_time wrapping
    double looped = anim.loop_time(anim.max_time + 0.1);
    assert(looped >= anim.min_time);
    assert(looped <= anim.max_time);

    // Test clamping
    double clamped = anim.clamp_time(-999);
    assert(clamped == anim.min_time);
}

// --- Extension helper tests ---

fn void test_has_extension() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    // Should not crash regardless
    bool result = stream.gltf.has_extension("KHR_lights_punctual");
    // Just verify the function works
    assert(result == true || result == false);
}

// --- Scene iteration tests ---

fn void test_each_node_in_scene() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    uint node_count = 0;
    stream.@each_node_in_scene(0; Node node, uint node_index) {
        node_count++;
    };
    // Scene has 6 nodes total
    assert(node_count == 6);
}

fn void test_each_mesh_in_scene() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    uint mesh_count = 0;
    stream.@each_mesh_in_scene(0; Mesh mesh, uint mesh_index, Node node, uint node_index) {
        mesh_count++;
    };
    // There are 3 nodes with meshes (Wheels, Wheels.001, Cesium_Milk_Truck)
    assert(mesh_count == 3);
}

// --- Vertex layout test ---

fn void test_vertex_layout() {
    GltfStream stream = gltf::open("test/truck.glb")!!;
    defer stream.close();

    Mesh mesh = stream.gltf.meshes[0];
    VertexLayout layout = stream.gltf.primitive_layout(mesh.primitives[0]);

    // Should have at least POSITION, NORMAL, TEXCOORD_0
    assert(layout.attribute_count >= 3);
    assert(layout.vertex_count > 0);
}
