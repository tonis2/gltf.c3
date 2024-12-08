# gltf.c3
GLTF parser for C3


### Functional features

* GLTF files
* GLB files
* Morph Animations
* Skin animations


### Extensions
* KHR_lights_punctual
* KHR_texture_transform
* KHR_animation_pointer



### How to use

Open and parse gltf file

```c
Gltf gltf_data = gltf::loadFile("examples/gltf/assets/boxes.glb")!;
defer gltf_data.free();
```


Loop over meshes and load vertices / indices
```c
    VertexData vertices;
    defer vertices.free();
    
    IndexData indices;
    defer indices.free();

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

             indices.push(gltf_data.@castBuffer(index_accessor, 1, ushort));
        }
    }
```

Load textures

```c
// Create texture-images from gltf buffer
foreach (gltf_texture : gltf_data.textures) {
    Format image_format = vk::FORMAT_R8G8B8A8_UNORM;
    TextureData texture;

    gltf::Image image = gltf_data.images[gltf_texture.source];
    gltf::Sampler gltf_sampler = gltf_data.samplers[gltf_texture.sampler];
    gltf::BufferView buffer_view = gltf_data.bufferViews[image.bufferView];
    gltf::Buffer buffer = gltf_data.buffers[buffer_view.buffer];

    stb::Image! image_data = stb::loadFromBuffer(buffer.data[buffer_view.offset..], buffer_view.byteLength, stb::Channel.STBI_RGB_ALPHA);

    if (catch err = image_data) {
        io::printfn("Failed loading image from buffer");
        return;
    }
}
```
