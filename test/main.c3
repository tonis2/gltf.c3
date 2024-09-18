module gltf_test @test;

import std::io;
import std::core;
import std::math;
import gltf;
import std::collections::list;

def VertexList = List(<Vertex>);
def IndexList = List(<ushort>);

struct Vertex {
    Vec3f pos;
    Vec2f tex;
    Vec3f normal;
}

fn void! test_glb() {

    Gltf gltf_data = gltf::loadFile("test/truck.glb")!!;
    defer gltf_data.free();

    VertexList vertices;
    defer vertices.free();

    IndexList indices;
    indices.free();

    foreach (mesh : gltf_data.meshes) {
        foreach (index, primitive: mesh.primitives) {
            Accessor pos_accessor = gltf_data.accessors[primitive.attributes["POSITION"]!!];
            Accessor tex_accessor = gltf_data.accessors[primitive.attributes["TEXCOORD_0"]!!];
            Accessor normal_accessor = gltf_data.accessors[primitive.attributes["NORMAL"]!!];
            Accessor index_accessor = gltf_data.accessors[primitive.attributes["indices"]!!];

            for (uint i = 0; i < pos_accessor.count ; i += 1) {
                vertices.push(Vertex {
                    gltf_data.@castBuffer(pos_accessor, i, Vec3f),
                    gltf_data.@castBuffer(tex_accessor, i, Vec2f),
                    gltf_data.@castBuffer(normal_accessor, i, Vec3f)
                });
            }

            //  indices.push(gltf_data.@castBuffer(index_accessor, 1, ushort));
        }
    }
    
    assert(vertices.len() == 3995);
}