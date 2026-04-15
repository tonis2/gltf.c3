# gltf.c3

A glTF 2.0 parser for C3 with support for both `.gltf` and `.glb` files.

### Features

* GLTF and GLB file loading
* Lazy buffer loading with reference counting
* Morph animations (blend shapes)
* Skin animations (skeletal)
* Bounding box (AABB) computation
* Scene graph traversal

### Extensions

* KHR_lights_punctual
* KHR_texture_transform
* KHR_animation_pointer
* EXT_mesh_gpu_instancing
* KHR_physics_rigid_bodies

### Installation

Add `gltf` as a dependency in your `project.json`:

```json
{
    "dependencies": ["gltf"]
}
```

## Getting started

### Opening a file

`gltf::open` parses the file and returns a `GltfStream`. All metadata (meshes, nodes, materials, animations) is available immediately — binary buffer data is loaded separately on demand.

```c
import gltf;

GltfStream stream = gltf::open("assets/model.glb")!;
defer stream.close();

// Metadata is ready — no buffer loading needed
io::printfn("Meshes: %d", stream.gltf.meshes.len());
io::printfn("Nodes: %d", stream.gltf.nodes.len());
io::printfn("Materials: %d", stream.gltf.materials.len());
```

### Loading buffers

Before reading vertex or animation data, load the relevant buffers. You can load everything at once or only what you need:

```c
// Load all buffers
stream.load_all_buffers()!;

// Or load selectively
stream.load_mesh_buffers(0)!;          // buffers for mesh index 0
stream.load_mesh_by_name("Helmet")!;   // buffers for a mesh by name
stream.load_scene(0)!;                 // all buffers used in a scene
stream.load_animation_buffers(0)!;     // buffers for animation index 0

// Unload when done — uses reference counting
stream.unload_all_buffers();
```

### Reading vertex data

Use `@cast_buffer` to read individual values from an accessor, or use the `@each_*` iteration macros:

```c
stream.load_all_buffers()!;

foreach (mesh : stream.gltf.meshes) {
    foreach (primitive : mesh.primitives) {
        // Iterate positions
        stream.@each_position(primitive; Vec3 pos, usz i) {
            // use pos...
        };

        // Iterate normals
        stream.@each_normal(primitive; Vec3 normal, usz i) {
            // use normal...
        };

        // Iterate UVs
        stream.@each_texcoord(primitive, 0; Vec2 uv, usz i) {
            // use uv...
        };

        // Iterate indices
        stream.@each_index_as_ushort(primitive; ushort idx, usz i) {
            // use idx...
        };
    }
}
```

Or read attributes manually with `@cast_buffer`:

```c
Accessor pos_accessor = stream.gltf.accessors[primitive.attributes["POSITION"]!!];
Accessor tex_accessor = stream.gltf.accessors[primitive.attributes["TEXCOORD_0"]!!];
Accessor normal_accessor = stream.gltf.accessors[primitive.attributes["NORMAL"]!!];

for (uint i = 0; i < pos_accessor.count; i++) {
    Vec3 position = stream.@cast_buffer(pos_accessor, i, Vec3);
    Vec2 uv = stream.@cast_buffer(tex_accessor, i, Vec2);
    Vec3 normal = stream.@cast_buffer(normal_accessor, i, Vec3);
}
```

### Finding things by name

```c
Mesh helmet = stream.gltf.find_mesh("Helmet")!;
Node root = stream.gltf.find_node("RootNode")!;
Animation walk = stream.gltf.find_animation("Walk")!;
```

### Scene traversal

Iterate over all nodes or meshes in a scene:

```c
// Visit every node in scene 0
stream.@each_node_in_scene(0; Node node, uint node_index) {
    io::printfn("Node: %s", node.name);
};

// Visit only nodes that have meshes
stream.@each_mesh_in_scene(0; Mesh mesh, uint mesh_index, Node node, uint node_index) {
    io::printfn("Mesh: %s on node: %s", mesh.name, node.name);
};

// Visit lights
stream.@each_light_in_scene(0; Light light, uint light_index, Node node) {
    io::printfn("Light type: %s", light.type);
};
```

### Bounding boxes

AABB computation works from accessor metadata — no buffer loading required:

```c
Mesh mesh = stream.gltf.meshes[0];
Aabb box = stream.gltf.mesh_aabb(mesh);
Vec3 size = box.size();
Vec3 center = box.center();

// World-space AABB for a node (applies node transforms)
Node node = stream.gltf.nodes[0];
Aabb world_box = stream.gltf.node_world_aabb(node);
```

### Materials

```c
foreach (mat : stream.gltf.materials) {
    Vec4 color = mat.baseColorFactor;
    float metallic = mat.metallicFactor;
    float roughness = mat.roughnessFactor;

    if (mat.has_base_color_texture()) { /* ... */ }
    if (mat.has_normal_map()) { /* ... */ }
    if (mat.is_transparent()) { /* ... */ }
}
```

### Animations

```c
Animation anim = stream.gltf.animations[0];
float duration = anim.duration();

// Loop or clamp time
double t = anim.loop_time(elapsed_time);
double t_clamped = anim.clamp_time(elapsed_time);
```

### Loading images

```c
stream.load_all_buffers()!;
stream.load_all_images()!;

foreach (uint i, image : stream.gltf.images) {
    char[] data = stream.get_image_data(i)!;
    // decode with stb_image or similar...
}

// Or load images for a specific material
stream.load_material_images(0)!;
```

### Node transforms

```c
Node node = stream.gltf.nodes[0];

Vec3 pos = node.world_position();
Vec3 scale = node.world_scale();
Matrix4f local = node.local_matrix();
Matrix4f global = node.global_matrix();
```

### Vertex layout introspection

Get a description of the vertex attributes for a primitive:

```c
Mesh mesh = stream.gltf.meshes[0];
VertexLayout layout = stream.gltf.primitive_layout(mesh.primitives[0]);

for (uint i = 0; i < layout.attribute_count; i++) {
    VertexAttribute attr = layout.attributes[i];
    io::printfn("Attribute: %s, type: %s, offset: %d", attr.name, attr.type, attr.offset);
}
```
