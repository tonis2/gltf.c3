module gltf;

import std::collections::object;
import std::io;
import std::math;
import std::collections::list;
import std::encoding::json;
import std::collections::map;

macro void Gltf.@run_animation_channels(&self, double frame_time, gltf::Animation animation; @callback(uint node_index, AnimationProperty path, Vec4f animation_value)) {
    foreach (channel : animation.channels) {
        AnimationSampler sampler = animation.samplers[channel.sampler];
        Accessor time_accessor = self.accessors[sampler.input];
        Accessor value_accessor = self.accessors[sampler.output];

        float max_frame_time = time_accessor.max[0];
        float min_frame_time = time_accessor.min[0];
        
        for TIMES: (ulong j; j < time_accessor.count; j++) {
            float current_time = self.@cast_buffer(time_accessor, j, float);

            if (current_time > frame_time && frame_time < max_frame_time && current_time > min_frame_time) {
                Vec4f current_value = self.@cast_buffer(value_accessor, j, Vec4f);

                if (sampler.interpolation == STEP) {
                    @callback(channel.target.node, channel.target.path, current_value);
                }

                if (sampler.interpolation == LINEAR) {
                    AnimationValue prev_value = {
                        .time = self.@cast_buffer(time_accessor, j - 1, float),
                        .value = self.@cast_buffer(value_accessor, j - 1, Vec4f),
                    };
                    
                    Vec4f new_value;
                    float interpolation_value = (float)(frame_time - prev_value.time) / (float)(current_time - prev_value.time);
                    
                    switch (channel.target.path) {
                        case TRANSLATION: new_value.xyz = prev_value.value.xyz.lerp(current_value.xyz, interpolation_value).xyz;
                        case ROTATION: new_value = (Quaternionf){.v = prev_value.value}.slerp({.v = current_value}, interpolation_value).v;
                        case SCALE: new_value.xyz = prev_value.value.xyz.lerp(current_value.xyz, interpolation_value).xyz;
                        default: {}
                    }
          
                    @callback(channel.target.node, channel.target.path, new_value);
                }

                break TIMES;
            }
        }
    }
}

macro void Gltf.@build_skin_matrixes(&self, gltf::Skin skin; @callback(uint joint, Matrix4f matrix)) {
    Accessor skin_accessor = self.accessors[skin.inverseBindAccessor];
    foreach (uint index, joint: skin.joints) {
        gltf::Node joint_node = self.nodes[joint];
        Matrix4f inverse_matrix = self.@cast_buffer(skin_accessor, index, Matrix4f).transpose();
        Matrix4f matrix = joint_node.global_matrix().mul(inverse_matrix).transpose();
        @callback(joint, matrix);
    }
}



fn Skin? Gltf.find_skin(Gltf* self, String name) {
    foreach (data : self.skins) {
        if (data.name == name) {
            return data;
        }
    }
    return KEY_NOT_FOUND?;
}

fn Animation? Gltf.find_animation(Gltf* self, String name) {
    foreach (data : self.animations) {
        if (data.name == name) {
            return data;
        }
    }
    return KEY_NOT_FOUND?;
}

fn uint? Gltf.find_animation_index(Gltf* self, String name) {
    foreach (uint index, data : self.animations) {
        if (data.name == name) return index;
    }
    return KEY_NOT_FOUND?;
}

fn List{uint} Gltf.find_skin_animations(Gltf self, uint skin_index) {
    gltf::Skin skin = self.skins[skin_index];
  
    List{uint} results;
    foreach ANIMATIONS: (uint index, animation : self.animations) {
        foreach (joint_index: skin.joints) {
            gltf::Node joint_node = self.nodes[joint_index];

            foreach (channel: animation.channels) {
                uint node_index = channel.target.node;
                Node channel_node = self.nodes[node_index];

                if (channel_node.name == joint_node.name) {
                    results.push(index);
                    continue ANIMATIONS;
                }
            }
        }
    }

    return results;
}

macro bool Animation.equals(self, Animation b) @operator(==) => self.name == b.name;


macro Gltf.@cast_buffer(&self, #target, usz index, #type) {
    Accessor accessor;
    $if $typeof(#target).nameof == "Accessor": {
        accessor = #target;
    }
    $else {
        accessor = self.accessors[#target]!;
    }       
    $endif
    
    BufferView bufferView = self.bufferViews[accessor.view];
    Buffer buffer = self.buffers[bufferView.buffer];
    usz index_offset = bufferView.byteStride > 0 ? bufferView.byteStride : accessor.stride();
    usz start_offset = accessor.offset + bufferView.offset;
    return bitcast(*(char[#type.sizeof]*)buffer.data[(start_offset + (index * index_offset))..], #type);
}

fn void* Gltf.get_data_array(&self, Accessor accessor) {
    // Accessor accessor = self.accessors[accessor_index];
    BufferView bufferView = self.bufferViews[accessor.view];
    Buffer buffer = self.buffers[bufferView.buffer];
    usz start_offset = accessor.offset + bufferView.offset;
    return buffer.data[start_offset..(start_offset + bufferView.byteLength)];
}

fn usz Gltf.get_offset(&self, ulong attribute) {
    Accessor accessor = self.accessors[attribute];
    BufferView bufferView = self.bufferViews[accessor.view];
    return accessor.offset + bufferView.offset;
}

fn BufferView Gltf.get_view(&self, ulong attribute) {
    Accessor accessor = self.accessors[attribute];
    BufferView bufferView = self.bufferViews[accessor.view];
    return bufferView;
}

fn char* Gltf.get_data(&self, BufferView view) {
    Buffer buffer = self.buffers[view.buffer];
    return buffer.data[view.offset..];
}

// fn int Vec3f.hash(&self) => ((int)self.x * 73856093) ^ ((int)self.y * 19349663) ^ ((int)self.z * 83492791);

macro void? Gltf.@get_positions(Gltf* self, Mesh mesh, #type; @callback(position, index)) {
    List{Vec3f} positions;
    List{ushort} indices;

    defer {
        positions.free();
        indices.free();
    }

    foreach (uint prim_index, primitive: mesh.primitives) {
        Accessor index_accessor = self.accessors[primitive.attributes["indices"]!!];
        Accessor pos_accessor = self.accessors[primitive.attributes["POSITION"]!!];

        for (usz i = 0; i < pos_accessor.count; i++) {
            Vec3f position = self.@cast_buffer(pos_accessor, i, Vec3f);
            positions.push(position);
        }

        for (usz i = 0; i < index_accessor.count; i++) {
            ushort index = self.@cast_buffer(index_accessor, i, ushort);
            indices.push(index);
        }

        $if #type.kindof == ARRAY:
            for (usz i = 0; i < indices.len(); i += #type.len) {
                $typefrom(#type.typeid) value;
                for (usz j = 0; j < #type.len; j++) {
                    usz index = indices[i + j];
                    value[j] = positions[index];
                };
                @callback(value, indices);
            };
        $else
            foreach (i, index: indices) @callback(positions[index], i);
        $endif
    }
}

fn void Gltf.debug_buffer(Gltf* self, Accessor accessor) {
    BufferView bufferView = self.bufferViews[accessor.view];
    Buffer buffer = self.buffers[bufferView.buffer];

    for (uint i = 0; i < accessor.count ; i += 1) {
        char[] data = buffer.data[(accessor.offset + bufferView.offset + (usz)(i * accessor.stride()))..];

        switch (accessor.type) {
           case AccessorType.SCALAR:
                ushort value = bitcast(*(char[ushort.sizeof]*)data, ushort);
                io::printfn("Parsed scalar %d", value);
           case AccessorType.VEC2:
                Vec2f vec =  bitcast(*(char[Vec2f.sizeof]*)data, Vec2f);
                io::printfn("Parsed Vec2 %f %f", vec.x, vec.y);
           case AccessorType.VEC3:
                Vec3f vec =  bitcast(*(char[Vec3f.sizeof]*)data, Vec3f);
                io::printfn("Parsed Vec3 %f %f %f", vec.x, vec.y, vec.z);
           case AccessorType.VEC4:
                Vec4f vec =  bitcast(*(char[Vec4f.sizeof]*)data, Vec4f);
                io::printfn("Parsed Vec4 %f %f %f %f", vec.x, vec.y, vec.z, vec.w);
           default: {}
        }
    }

    io::printf(" \n _______ \n");
}