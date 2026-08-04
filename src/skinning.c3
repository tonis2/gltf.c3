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

 `direction` points from this joint to where the bone ends — head to tail, in
 the same model space. glTF has no tail: a joint is a node, and the only thing
 a consumer can read a bone's direction from is the node's own orientation. So
 leaving this zero writes an unrotated node, and every importer then has to
 invent a direction. Blender's takes the bone's *length* from the distance to
 its child but its *direction* from the node's axes, which turns a skeleton
 written from positions alone into a fan of parallel sticks however sensible
 the joints are.

 Zero is still the right value when a caller genuinely has only positions;
 it just means the file does not say which way the bones face.
*>
struct Bone
{
	String name;
	int parent;
	Vec3 position;
	Vec3 direction;
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

 A bone's world transform is its position and, where `Bone.direction` says so,
 the rotation that puts its local -Z along the bone. Each node then carries
 that expressed inside its parent's frame, so the chain composes back to the
 world transform and the inverse bind matrix is its inverse. Skinning is
 untouched by the rotation — at bind pose every joint's world transform still
 cancels against its own inverse bind matrix — but a posed joint now rotates
 about the bone rather than about the world axes, which is what a rig is for.

 @param bones : `Parent indices must be a valid bone index or -1; any order.`
 @param joints : `Receives one node index per bone, in bone order — the order JOINTS_n indexes.`
 @param roots : `Receives the node indices of bones with no parent.`
*>
fn uint GltfBuilder.add_skeleton(&self, Bone[] bones, List{uint}* joints, List{uint}* roots)
{
	@pool()
	{
		// Every bone's world rotation first: a child expresses itself inside
		// its parent's frame, and bones may arrive in any order.
		Quaternionf[] rotation = bone_rotations(tmem, bones);

		foreach (i, bone : bones)
		{
			Vec3 local = bone.position;
			Quaternionf local_rotation = rotation[i];
			if (bone.parent >= 0)
			{
				Quaternionf into_parent = rotation[bone.parent].conjugate();
				local = into_parent * (bone.position - bones[bone.parent].position);
				local_rotation = into_parent * rotation[i];
			}
			joints.push(self.add_node(bone.name, translation: local, rotation: local_rotation));
		}

		// The child a bone points at is named first. glTF puts no meaning on
		// the order, but a consumer that has to guess a bone's length takes
		// the distance to the first child — Blender does — while taking its
		// direction from the node. Leave the order alone and those two
		// disagree wherever a bone aims past its first-listed child, and the
		// tail stops short of the joint it was aimed at.
		foreach (i, bone : bones)
		{
			if (bone.parent >= 0 && points_at(bones, bone.parent, (usz)i))
			{
				self.add_child(joints.get((sz)bone.parent), joints.get((sz)i));
			}
		}
		foreach (i, bone : bones)
		{
			if (bone.parent < 0)
			{
				roots.push(joints.get((sz)i));
			}
			else if (!points_at(bones, bone.parent, (usz)i))
			{
				self.add_child(joints.get((sz)bone.parent), joints.get((sz)i));
			}
		}

		Matrix4f[] world = alloc::new_array(tmem, Matrix4f, bones.len);
		foreach (i, bone : bones)
		{
			world[i] = rotation[i].to_matrix();
			world[i].m[12] = bone.position.x;
			world[i].m[13] = bone.position.y;
			world[i].m[14] = bone.position.z;
		}
		return self.add_matrices(inverse_bind_matrices(tmem, world));
	};
}

<*
 Whether `parent`'s bone ends exactly on `child`'s joint.

 Tolerance is relative to the bone's own length, so it means the same thing on
 a model measured in metres and one measured in centimetres.
*>
fn bool points_at(Bone[] bones, int parent, usz child) @private
{
	Vec3 direction = bones[parent].direction;
	float length_sq = direction.length_sq();
	if (length_sq < 1.0e-18f) return false;

	Vec3 gap = bones[child].position - (bones[parent].position + direction);
	return gap.length_sq() <= 1.0e-8f * length_sq;
}

<*
 Every bone's world rotation: the one taking its local -Z onto its direction.

 	`Quaternionf[] rest = gltf::bone_rotations(mem, bones);`

 The frame `add_skeleton` writes its nodes in, exposed because a caller writing
 animation channels against those nodes has to convert into it. A pose expressed
 as a rotation about the joint in world axes becomes this node's local rotation
 as `rotation[parent]^-1 * pose * rotation[joint]`, and its local translation as
 `rotation[parent]^-1` applied to the offset from the parent — which at rest is
 exactly what `add_skeleton` writes, since a rest pose is the identity.

 Indexed by bone, in the order `bones` arrives, which is the order
 `add_skeleton` fills its `joints` list in.

 The caller owns the returned array.
*>
fn Quaternionf[] bone_rotations(Allocator allocator, Bone[] bones)
{
	Quaternionf[] rotation = alloc::new_array(allocator, Quaternionf, bones.len);
	foreach (i, bone : bones) rotation[i] = bone_rotation(bone.direction);
	return rotation;
}

<*
 The rotation taking a bone's local -Z onto `direction`, the shortest way
 round.

 -Z, not +Y, and the difference is not arbitrary. glTF never says which local
 axis a joint's bone runs along, so the convention is whatever the tools agree
 on, and what they agree on comes from Blender: a Blender bone points along its
 own +Y, and the Blender-to-glTF axis change maps +Y onto -Z. Exporting a
 skeleton out of Blender and reading the joint nodes back confirms it — every
 bone's direction is exactly the node's -Z. Aiming +Y instead writes rotations
 that are perfectly valid, survive a round trip, and point every bone a quarter
 turn away from where it belongs.

 Which way the bone rolls about its own length is not determined by a
 direction, so the shortest arc picks it: it is the one rotation of that pair
 with no twist in it, and it is stable — a bone whose direction barely changes
 gets a quaternion that barely changes with it.

 A zero direction means the caller has only a position, and leaves the node
 unrotated.
*>
fn Quaternionf bone_rotation(Vec3 direction) @private
{
	float length = direction.length();
	if (length < 1.0e-9f) return { 0, 0, 0, 1 };

	Vec3 to = direction * (1.0f / length);

	// cross({0,0,-1}, to) is (to.y, -to.x, 0), and 1 + dot({0,0,-1}, to) is the
	// half-angle term the shortest arc wants.
	float w = 1.0f - to.z;
	if (w < 1.0e-6f)
	{
		// Straight along +Z: antiparallel, so every half turn about an axis
		// across the bone is equally short. Take the one about X.
		return { 1, 0, 0, 0 };
	}

	float[<4>] q = { to.y, -to.x, 0, w };
	return { .v = q * (1.0f / (float)math::sqrt((double)(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w))) };
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
