# gltf.c3
GLTF parser for C3


### Features

* GLTF files
* GLB files
* External binaries

Still working on getting skinning / animations working.


### How to use

Open and parse gltf file

```c
File! file = file::open("examples/gltf/assets/boxes.glb", "r");
defer try file.close()!!;

if (catch err = file) {
    io::printfn("Failed to load the gltf file");
    return;
}

Gltf! gltf_data = gltf::parse(&file);
defer try gltf_data.free();

if (catch err = gltf_data) {
    io::printfn("%s", err);
    return;
}
```


Loop over meshes and load vertices / indices
```c
    VertexData vertices;
    defer vertices.free();
    
    IndexData indices;
    defer indices.free();

   foreach (mesh : gltf_data.meshes) {
        foreach (index, primitive: mesh.primitives) {
            Accessor pos_accessor = gltf_data.accessors[primitive.position];
            Accessor tex_accessor = gltf_data.accessors[primitive.tex_cord];
            Accessor normal_accessor = gltf_data.accessors[primitive.normal];
            Accessor index_accessor = gltf_data.accessors[primitive.indices];

            for (uint i = 0; i < pos_accessor.count ; i += 1) {
                vertices.push(Vertex {
                    gltf_data.@cast_buffer(pos_accessor, i * pos_accessor.componentSize(), Vec3f),
                    gltf_data.@cast_buffer(tex_accessor, i * tex_accessor.componentSize(), Vec2f),
                    gltf_data.@cast_buffer(normal_accessor, i * normal_accessor.componentSize(), Vec3f)
                });
            }

            for (uint i = 0; i < index_accessor.count ; i += 1) {
                indices.push(gltf_data.@cast_buffer(index_accessor, i * index_accessor.componentSize(), ushort));
            }
        }
    }
```
