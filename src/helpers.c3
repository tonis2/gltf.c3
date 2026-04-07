module gltf;

import std::collections::object;
import std::io;
import std::math;
import std::collections::list;
import std::encoding::json;
import std::collections::map;

fn Skin? Gltf.find_skin(Gltf* self, String name)
{
	foreach (data : self.skins)
	{
		if (data.name == name)
		{
			return data;
		}
	}
	return KEY_NOT_FOUND~;
}

fn Animation? Gltf.find_animation(Gltf* self, String name)
{
	foreach (data : self.animations)
	{
		if (data.name == name)
		{
			return data;
		}
	}
	return KEY_NOT_FOUND~;
}

fn uint? Gltf.find_animation_index(Gltf* self, String name)
{
	foreach (uint index, data : self.animations)
	{
		if (data.name == name) return index;
	}
	return KEY_NOT_FOUND~;
}

fn List {uint} Gltf.find_skin_animations(Gltf self, uint skin_index, Allocator allocator = mem)
{
	gltf::Skin skin = self.skins[skin_index];

	List {uint} results;
	results.init(allocator);
	foreach ANIMATIONS: (uint index, animation : self.animations)
	{
		foreach (joint_index : skin.joints)
		{
			gltf::Node joint_node = self.nodes[joint_index];

			foreach (channel : animation.channels)
			{
				uint node_index = channel.target.node;
				Node channel_node = self.nodes[node_index];

				if (channel_node.name == joint_node.name)
				{
					results.push(index);
					continue ANIMATIONS;
				}
			}
		}
	}

	return results;
}

macro bool Animation.equals(self, Animation b) @operator(==) => self.name == b.name;

fn usz Gltf.get_offset(&self, ulong attribute)
{
	Accessor accessor = self.accessors[(usz)attribute];
	BufferView bufferView = self.bufferViews[accessor.view];
	return accessor.offset + bufferView.offset;
}

fn BufferView Gltf.get_view(&self, ulong attribute)
{
	Accessor accessor = self.accessors[(usz)attribute];
	BufferView bufferView = self.bufferViews[accessor.view];
	return bufferView;
}
