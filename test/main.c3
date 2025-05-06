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


fn void test_glb() {

    Gltf gltf_data = gltf::loadFile("test/truck.glb")!!;
    defer gltf_data.free();

    assert(gltf_data.textures.len() == 2);
    assert(gltf_data.materials.len() == 4);

    VertexList vertices;
    defer vertices.free();

    IndexList indices;
    defer indices.free();
    
    foreach (mesh : gltf_data.meshes) {
        foreach (index, primitive: mesh.primitives) {
            Accessor pos_accessor = gltf_data.accessors[primitive.attributes["POSITION"]!!];
            Accessor tex_accessor = gltf_data.accessors[primitive.attributes["TEXCOORD_0"]!!];
            Accessor normal_accessor = gltf_data.accessors[primitive.attributes["NORMAL"]!!];
            Accessor index_accessor = gltf_data.accessors[primitive.attributes["indices"]!!];

            for (uint i = 0; i < pos_accessor.count ; i += 1) {
                vertices.push({
                    gltf_data.@cast_buffer(pos_accessor, i, Vec3f),
                    gltf_data.@cast_buffer(tex_accessor, i, Vec2f),
                    gltf_data.@cast_buffer(normal_accessor, i, Vec3f)
                });
            }

             indices.push(gltf_data.@cast_buffer(index_accessor, 1, ushort));
        }
    }

  
    assert(vertices.len() == 3995);
    assert(indices.len() == 4);
    assert(math::round_to_decimals(((float[<3>]))vertices[0].pos, 4)  == math::round_to_decimals((float[<3>]) {-0.044543, 1.018000, 0.166238}, 4));
    assert(math::round_to_decimals(((float[<2>]))vertices[0].tex, 4)  == math::round_to_decimals((float[<2>]) {0.711914, 0.120246}, 4));
    assert(math::round_to_decimals(((float[<3>]))vertices[0].normal, 4)  == math::round_to_decimals((float[<3>]) {-0.000004, 1.000000, -0.000000}, 4));
}