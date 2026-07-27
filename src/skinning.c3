<*
 Building a rigged asset: skeleton, skin weights and inverse bind matrices.

 glTF stores skinning in two halves that have to agree. The mesh carries
 `JOINTS_n` and `WEIGHTS_n` vertex attributes — four influences per set,
 naming a joint by its position in the skin's `joints` array and how strongly
 it pulls. The skin carries that joints array, listing nodes in the scene
 graph, plus one inverse bind matrix per joint: the transform that takes a
 vertex from model space into that joint's local space, so that posing the
 joint moves the vertex with it.

 The awkward part is the vertex attributes. A rigging model predicts a weight
 for every bone at every vertex, but glTF wants at most a handful of
 influences, and they have to sum to one or the mesh shrinks toward the origin
 wherever they do not. `sparsify_weights` handles that reduction — see there
 for what happens to the discarded tail.

     `SkinBinding binding = gltf::sparsify_weights(mem, dense, vertices, bones.len);`
     `defer binding.free(mem);`

 For the common case — a mesh, a skeleton and a dense weight matrix — go
 through write_skinned_glb and skip the assembly entirely.
*>
module gltf;

import std::io;
import std::core::mem;
import std::core::mem::allocator;
import std::math;
import std::math::matrix;
import std::math::vector;
import std::collections::list;

faultdef WEIGHT_SIZE_MISMATCH, TOO_MANY_INFLUENCES;

// glTF spells influences in groups of four, one JOINTS_n/WEIGHTS_n pair per
// group. Four sets is 16 influences per vertex, past anything a real rig uses.
const uint MAX_INFLUENCE_SETS @private = 4;

const String[4] JOINT_ATTRIBUTES @private = { "JOINTS_0", "JOINTS_1", "JOINTS_2", "JOINTS_3" };
const String[4] WEIGHT_ATTRIBUTES @private = { "WEIGHTS_0", "WEIGHTS_1", "WEIGHTS_2", "WEIGHTS_3" };

<*
 One joint of a skeleton at bind pose.

 The position is in model space, the same space as the mesh vertices, because
 that is what a rigging model predicts and what an inverse bind matrix is
 derived from. Converting it to the parent-relative translation glTF stores is
 add_skeleton's job.
*>
struct Bone
{
	String name;
	int parent;
	Vec3 position;
}

<*
 Per-vertex skin influences, already reduced to what glTF can store: `slots`
 joint indices and `slots` weights for each vertex, laid out vertex-major.
*>
struct SkinBinding
{
	ushort[] joints;
	float[] weights;
	uint slots;
	usz vertices;
}

fn void SkinBinding.free(&self, Allocator allocator)
{
	if (self.joints.len > 0) alloc::free(allocator, self.joints);
	if (self.weights.len > 0) alloc::free(allocator, self.weights);
}

<*
 Reduce a dense per-bone weight matrix to the few strongest influences per
 vertex.

 A vertex keeps its `max_influences` largest weights and drops the rest, then
 the survivors are rescaled to sum to one. Renormalising matters: glTF skinning
 blends by weight without normalising, so a vertex whose weights sum to 0.8
 lands at 80% of the way from the origin — the mesh visibly deflates. Dropping
 a long tail of near-zero weights is what makes that happen, so the rescale is
 not optional.

 A vertex with no positive weight anywhere is pinned to joint 0 with weight 1
 rather than left at zero, for the same reason: all-zero weights would collapse
 it to the origin. An unrigged vertex riding the root is wrong in a way that is
 easy to see and easy to fix; a vertex at the origin looks like a torn mesh.

 @param dense : `vertices * bones weights, vertex-major.`
 @param max_influences : `Kept per vertex, rounded up to a multiple of 4.`
 @return? WEIGHT_SIZE_MISMATCH : `dense is not exactly vertices * bones long.`
 @return? TOO_MANY_INFLUENCES : `More than 16 influences requested.`
*>
fn SkinBinding? sparsify_weights(Allocator allocator, float[] dense, usz vertices, usz bones, uint max_influences = 4)
{
	if (dense.len != vertices * bones) return WEIGHT_SIZE_MISMATCH~;
	if (max_influences == 0 || max_influences > MAX_INFLUENCE_SETS * 4) return TOO_MANY_INFLUENCES~;

	uint slots = ((max_influences + 3) / 4) * 4;

	SkinBinding binding;
	binding.slots = slots;
	binding.vertices = vertices;
	binding.joints = alloc::new_array(allocator, ushort, (sz)(vertices * slots));
	binding.weights = alloc::new_array(allocator, float, (sz)(vertices * slots));

	for (usz v = 0; v < vertices; v++)
	{
		float[] row = dense[v * bones : bones];
		usz base = v * slots;

		// Selection rather than a sort: only the top few of what can be
		// hundreds of bones are wanted, and the row is left untouched.
		// Bounded by max_influences, not by slots — the slack up to the full
		// set of four stays zeroed.
		float total = 0;
		for (uint slot = 0; slot < max_influences && slot < bones; slot++)
		{
			usz best = bones;
			float best_weight = 0;

			for (usz b = 0; b < bones; b++)
			{
				if (row[b] <= best_weight) continue;

				bool taken = false;
				for (uint s = 0; s < slot; s++)
				{
					if (binding.joints[base + s] == (ushort)b && binding.weights[base + s] > 0) { taken = true; break; }
				}
				if (taken) continue;

				best = b;
				best_weight = row[b];
			}

			if (best == bones) break;
			binding.joints[base + slot] = (ushort)best;
			binding.weights[base + slot] = best_weight;
			total += best_weight;
		}

		if (total > 0)
		{
			for (uint slot = 0; slot < slots; slot++) binding.weights[base + slot] /= total;
		}
		else
		{
			binding.joints[base] = 0;
			binding.weights[base] = 1.0;
		}
	}

	return binding;
}

<*
 The transform taking a vertex from model space into each joint's local space,
 which is what glTF stores per joint: the inverse of the joint's world
 transform at bind pose.

 A joint whose transform cannot be inverted — a zero scale collapses it — gets
 identity, leaving its vertices in model space rather than sending them to
 infinity.
*>
fn Matrix4f[] inverse_bind_matrices(Allocator allocator, Matrix4f[] joint_world)
{
	Matrix4f[] out = alloc::new_array(allocator, Matrix4f, joint_world.len);
	foreach (i, world : joint_world)
	{
		Matrix4f source = world;
		out[i] = source.inverse() ?? matrix::IDENTITY4;
	}
	return out;
}

<*
 Add a skeleton as nodes and return the accessor holding its inverse bind
 matrices, with the joint node indices written into `joints`.

 Bind pose is translation only, which is what a rigging model that predicts
 joint positions gives you. Each node's translation is its bone's offset from
 its parent, so the world position comes back out as the chain composes, and
 the inverse bind matrix is the inverse of that world position.

 @param bones : `Parent indices must be a valid bone index or -1; any order.`
 @param joints : `Receives one node index per bone, in bone order — the order JOINTS_n indexes.`
 @param roots : `Receives the node indices of bones with no parent.`
*>
fn uint GltfBuilder.add_skeleton(&self, Bone[] bones, List{uint}* joints, List{uint}* roots)
{
	foreach (bone : bones)
	{
		Vec3 local = bone.position;
		if (bone.parent >= 0) local = bone.position - bones[bone.parent].position;
		joints.push(self.add_node(bone.name, translation: local));
	}

	foreach (i, bone : bones)
	{
		if (bone.parent >= 0)
		{
			self.add_child(joints.get((sz)bone.parent), joints.get((sz)i));
		}
		else
		{
			roots.push(joints.get((sz)i));
		}
	}

	@pool()
	{
		Matrix4f[] world = alloc::new_array(tmem, Matrix4f, bones.len);
		foreach (i, bone : bones)
		{
			world[i] = matrix::IDENTITY4;
			world[i].m[12] = bone.position.x;
			world[i].m[13] = bone.position.y;
			world[i].m[14] = bone.position.z;
		}
		return self.add_matrices(inverse_bind_matrices(tmem, world));
	};
}

<*
 Add the JOINTS_n and WEIGHTS_n accessors for a binding and append the
 attributes naming them to `out`, ready to pass to add_primitive.
*>
fn void GltfBuilder.add_skin_binding(&self, SkinBinding binding, List{WriteAttribute}* out)
{
	uint sets = binding.slots / 4;

	for (uint set = 0; set < sets; set++)
	{
		@pool()
		{
			// One set is every vertex's slice of four for this group, gathered
			// out of the interleaved rows.
			ushort[] joints = alloc::new_array(tmem, ushort, (sz)(binding.vertices * 4));
			float[] weights = alloc::new_array(tmem, float, (sz)(binding.vertices * 4));

			for (usz v = 0; v < binding.vertices; v++)
			{
				usz source = v * (usz)binding.slots + (usz)set * 4;
				for (uint i = 0; i < 4; i++)
				{
					joints[v * 4 + i] = binding.joints[source + i];
					weights[v * 4 + i] = binding.weights[source + i];
				}
			}

			out.push({ .name = JOINT_ATTRIBUTES[set], .accessor = self.add_joints(joints) });
			out.push({ .name = WEIGHT_ATTRIBUTES[set], .accessor = self.add_weights(weights) });
		};
	}
}

<*
 A mesh, a skeleton and a weight for every bone at every vertex — the shape a
 rigging model's output arrives in.
*>
struct SkinnedMesh
{
	String name;
	Vec3[] positions;
	Vec3[] normals;
	uint[] indices;
	Bone[] bones;
	float[] weights;
	uint max_influences;
}

<*
 Write a rigged .glb: mesh, skeleton, skin weights and inverse bind matrices.

 The skinned mesh node and the skeleton roots go into the scene side by side.
 A skinned mesh ignores its own node transform in glTF — it is posed entirely
 by its joints — so parenting it under the skeleton would only be misleading.

 @param mesh : `normals may be empty; max_influences of 0 means the default of 4.`
 @return? WEIGHT_SIZE_MISMATCH : `weights is not positions.len * bones.len long.`
 @return? TOO_MANY_INFLUENCES : `More than 16 influences requested.`
 @return? WRITE_FAILED : `The file could not be opened, written or flushed.`
*>
fn void? write_skinned_glb(String path, SkinnedMesh mesh, Allocator allocator = mem)
{
	uint influences = mesh.max_influences == 0 ? 4 : mesh.max_influences;

	SkinBinding binding = sparsify_weights(allocator, mesh.weights, mesh.positions.len, mesh.bones.len, influences)!;
	defer binding.free(allocator);

	GltfBuilder out = builder(allocator);
	defer out.free();

	List{WriteAttribute} attributes;
	attributes.init(allocator);
	defer attributes.free();

	attributes.push({ .name = "POSITION", .accessor = out.add_positions(mesh.positions) });
	if (mesh.normals.len > 0)
	{
		attributes.push({ .name = "NORMAL", .accessor = out.add_vec3(mesh.normals) });
	}
	out.add_skin_binding(binding, &attributes);

	int indices = mesh.indices.len > 0 ? (int)out.add_indices(mesh.indices) : -1;

	String name = mesh.name.len > 0 ? mesh.name : "Mesh";
	uint mesh_index = out.add_mesh(name);
	out.add_primitive(mesh_index, attributes.array_view(), indices: indices);

	List{uint} joints;
	joints.init(allocator);
	defer joints.free();

	List{uint} skeleton_roots;
	skeleton_roots.init(allocator);
	defer skeleton_roots.free();

	uint inverse_bind = out.add_skeleton(mesh.bones, &joints, &skeleton_roots);

	// glTF names a skeleton root only when there is a single common one.
	int skeleton = skeleton_roots.len() == 1 ? (int)skeleton_roots.get(0) : -1;
	uint skin = out.add_skin(name, joints.array_view(), inverse_bind: (int)inverse_bind, skeleton: skeleton);

	out.add_root(out.add_node(name, mesh: (int)mesh_index, skin: (int)skin));
	foreach (root : skeleton_roots) out.add_root(root);

	return out.save_glb(path);
}
