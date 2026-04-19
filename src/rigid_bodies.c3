module gltf;

import std::collections::object;
import std::io;
import std::math;
import std::math::vector;
import std::collections::list;
import std::encoding::json;

enum ShapeType : inline uint
{
	BOX,
	CAPSULE,
	CYLINDER,
	SPHERE,
}

enum MagFilter : inline uint
{
	NEAREST,
	LINEAR,
}

enum DriveType : inline uint
{
	ANGULAR,
	LINEAR
}

enum DriveMode : inline uint
{
	FORCE,
	ACCELERATION
}

enum PhysicsCombine : inline uint
{
	AVERAGE,
	MINIMUM,
	MAXIMUM,
	MULTIPLY
}

struct Shape
{
	Vec3 size;
	float height;
	float radius_bottom;
	float radius_top;
	float radius;
	ShapeType type;
}

struct Limit
{
	Vec3 axes;
	float min;
	float max;
	float stiffness;
	float damping;
}

struct Drive
{
	DriveType type;
	DriveMode drive;
	uint axis;
	float max_force;
	float position_target;
	float velocity_target;
	float stiffness;
	float damping;
}

struct PhysicsJoint
{
	List{Limit} angular_limits;
	List{Limit} linear_limits;
	List{Drive} drives;
}

struct PhysicsMaterial
{
	float static_friction;
	float dynamic_friction;
	float restitution;
	PhysicsCombine friction_combine;
	PhysicsCombine restitution_combine;
}

struct CollisionFilter
{
	List{String} systems;
	List{String} not_colliding;
	List{String} colliding_with;
}

struct Motion
{
	bool is_kinematic;
	float mass;
	float gravity_factor;
	float linear_dampening;
	float angular_dampening;

	Vec3 mass_center;
	Vec3 inertia_diagonal;
	Quaternionf inertia_orientation;
	Vec3 linear_velocity;
	Vec3 angular_velocity;
}

struct Collider
{
	bool convex_hull;
	bool is_trigger;
	int shape;
	int node;
	int material;
	int collision_filter;
	int mesh;
	int base_node;
	List{uint} nodes; // For compound triggers
}

fn bool Collider.has_mesh(self) => self.mesh != -1;
fn bool Collider.has_shape(self) => self.shape != -1;
fn bool Collider.has_node(self) => self.node != -1;
fn bool Collider.has_material(self) => self.material != -1;
fn bool Collider.has_filter(self) => self.collision_filter != -1;
fn bool Collider.is_implicit(self) => self.shape != -1;
fn bool Collider.is_mesh_collider(self) => self.shape == -1 && self.mesh != -1;

fn Collider Collider.from_json(self, Object* json, bool is_trigger = false, Allocator allocator = mem)
{
	self.nodes.init(allocator);

	Object*? geometry = json.get("geometry");
	Object*? nodes = json.get("nodes");

	self.shape = -1;
	self.node = -1;
	self.convex_hull = false;
	self.mesh = -1;
	self.base_node = -1;
	self.is_trigger = is_trigger;

	if (try geometry)
	{
		self.convex_hull = geometry.get_bool("convexHull") ?? false;
		self.shape = geometry.get_int("shape") ?? -1;
		self.node = geometry.get_int("node") ?? -1;
	}

	self.material = json.get_int("physicsMaterial") ?? -1;
	self.collision_filter = json.get_int("collisionFilter") ?? -1;

	// Parse compound trigger nodes
	if (try nodes)
	{
		foreach (node : nodes.array) self.nodes.push((uint)node.f);
	}

	return self;
}

fn void Collider.free(&self)
{
	self.nodes.free();
}

fn Motion Motion.from_json(self, Object* json)
{
	Object*? center_mass = json.get("centerOfMass");
	Object*? inertia_diagonal = json.get("inertiaDiagonal");
	Object*? inertia_orientation = json.get("inertiaOrientation");
	Object*? linear_velocity = json.get("linearVelocity");
	Object*? angular_velocity = json.get("angularVelocity");

	if (try center_mass)
	{
		foreach (usz i, mass : center_mass.array)
		{
			self.mass_center[i] = (float)mass.f;
		}
	}

	if (try inertia_diagonal)
	{
		foreach (usz i, inertia : inertia_diagonal.array)
		{
			self.inertia_diagonal[i] = (float)inertia.f;
		}
	}

	if (try inertia_orientation)
	{
		foreach (usz i, inertia : inertia_orientation.array)
		{
			self.inertia_orientation.v[i] = (float)inertia.f;
		}
	}

	if (try linear_velocity)
	{
		foreach (usz i, velocity : linear_velocity.array)
		{
			self.linear_velocity[i] = (float)velocity.f;
		}
	}

	if (try angular_velocity)
	{
		foreach (usz i, velocity : angular_velocity.array)
		{
			self.angular_velocity[i] = (float)velocity.f;
		}
	}

	self.is_kinematic = json.get_bool("isKinematic") ?? false;
	self.mass = (float)json.get_float("mass") ?? 0;
	self.gravity_factor = (float)json.get_float("gravityFactor") ?? 1;
	self.linear_dampening = (float)json.get_float("linearDamping") ?? 0.9;
	self.angular_dampening = (float)json.get_float("angularDamping") ?? 0.9;
	return self;
}

fn CollisionFilter CollisionFilter.from_json(self, Object* json, Allocator allocator = mem)
{
	self.systems.init(allocator);
	self.not_colliding.init(allocator);
	self.colliding_with.init(allocator);

	Object*? systems = json.get("collisionSystems");
	Object*? collide_with = json.get("collideWithSystems");
	Object*? not_colliding = json.get("notCollideWithSystems");

	if (try systems)
	{
		foreach (system : systems.array) self.systems.push(system.s);
	}

	if (try collide_with)
	{
		foreach (system : collide_with.array) self.colliding_with.push(system.s);
	}

	if (try not_colliding)
	{
		foreach (system : not_colliding.array) self.not_colliding.push(system.s);
	}

	return self;
}

fn void CollisionFilter.free(&self)
{
	self.systems.free();
	self.not_colliding.free();
	self.colliding_with.free();
}

fn Shape Shape.from_json(self, Object* json)
{
	String? type = json.get_string("type");

	if (try type)
	{
		switch (type)
		{
			case "box":
				{
					Object*? box = json.get("box");
					Object*? size = box.get("size");
					self = {
						.type = BOX,
						.size = @ok(
							size
						) ? {
							(float)size.get_at(0).f!!,
							(float)size.get_at(1).f!!,
							(float)size.get_at(2).f!!
						} : { 0, 0, 0 }
					};
				}
			case "sphere":
				{
					Object*? body = json.get("sphere");
					float radius = (float)body.get_float("radius") ?? 0;
					self = { .type = SPHERE, .radius = radius };
				}
			case "cylinder":
				{
					Object*? body = json.get("cylinder");
					float height = (float)body.get_float("height") ?? 0;
					float radius_bottom = (float)body.get_float("radiusBottom") ?? 0;
					float radius_top = (float)body.get_float("radiusTop") ?? 0;

					self = {
						.type = CYLINDER,
						.height = height,
						.radius_bottom = radius_bottom,
						.radius_top = radius_top
					};
				}
			case "capsule":
				{
					Object*? body = json.get("capsule");
					float height = (float)body.get_float("height") ?? 0;
					float radius_bottom = (float)body.get_float("radiusBottom") ?? 0;
					float radius_top = (float)body.get_float("radiusTop") ?? 0;

					self = {
						.type = CAPSULE,
						.height = height,
						.radius_bottom = radius_bottom,
						.radius_top = radius_top
					};
				}
		}
	}

	return self;
}

fn Aabb Shape.aabb(self)
{
	switch (self.type)
	{
		case BOX:
			Vec3 half = self.size * 0.5;
			return { .min = -half, .max = half };
		case SPHERE:
			return {
				.min = { -self.radius, -self.radius, -self.radius },
				.max = { self.radius, self.radius, self.radius }
			};
		case CAPSULE:
			float max_r = math::max(self.radius_bottom, self.radius_top);
			float half_h = self.height * 0.5;
			return {
				.min = { -max_r, -half_h - max_r, -max_r },
				.max = { max_r, half_h + max_r, max_r }
			};
		case CYLINDER:
			float max_r = math::max(self.radius_bottom, self.radius_top);
			float half_h = self.height * 0.5;
			return {
				.min = { -max_r, -half_h, -max_r },
				.max = { max_r, half_h, max_r }
			};
	}
}

fn PhysicsJoint PhysicsJoint.from_json(self, Object* json, Allocator allocator = mem)
{
	self.angular_limits.init(allocator);
	self.linear_limits.init(allocator);
	self.drives.init(allocator);

	Object*? limits = json.get("limits");
	Object*? drives = json.get("drives");

	if (try limits)
	{
		foreach (limit : limits.array)
		{
			Object*? linear_axes = limit.get("linearAxes");
			Object*? angular_axes = limit.get("angularAxes");

			float min = (float)limit.get_float("min") ?? 0;
			float max = (float)limit.get_float("max") ?? 0;

			float stiffness = (float)limit.get_float("stiffness") ?? 0;
			float damping = (float)limit.get_float("damping") ?? 0;

			if (try linear_axes)
			{
				foreach (axis : linear_axes.array)
				{
					Limit joint_limit = {
						.axes = { 0, 0, 0 },
						.min = min,
						.max = max,
						.stiffness = stiffness,
						.damping = damping
					};

					switch (axis.f)
					{
						case 0:
							joint_limit.axes.x = 1;
						case 1:
							joint_limit.axes.y = 1;
						case 2:
							joint_limit.axes.z = 1;
					}

					self.linear_limits.push(joint_limit);
				}
			}

			if (try angular_axes)
			{
				foreach (axis : angular_axes.array)
				{
					Limit joint_limit = {
						.axes = { 0, 0, 0 },
						.min = min,
						.max = max,
						.stiffness = stiffness,
						.damping = damping
					};

					switch (axis.f)
					{
						case 0:
							joint_limit.axes.x = 1;
						case 1:
							joint_limit.axes.y = 1;
						case 2:
							joint_limit.axes.z = 1;
					}

					self.angular_limits.push(joint_limit);
				}
			}
		}
	}

	if (try drives)
	{
		foreach (drive : drives.array)
		{
			Drive joint_drive;

			joint_drive.axis = (uint)drive.get_int("axis") ?? 0;
			joint_drive.position_target = (float)drive.get_float("positionTarget") ?? 0;
			joint_drive.velocity_target = (float)drive.get_float("velocityTarget") ?? 0;
			joint_drive.stiffness = (float)drive.get_float("stiffness") ?? 0;
			joint_drive.damping = (float)drive.get_float("damping") ?? 0;

			String? type = drive.get_string("type");
			String? mode = drive.get_string("mode");

			self.drives.push(joint_drive);
		}
	}
	return self;
}

fn void PhysicsJoint.free(&self)
{
	self.linear_limits.free();
	self.angular_limits.free();
	self.drives.free();
}

fn PhysicsMaterial PhysicsMaterial.from_json(self, Object* json)
{
	self.static_friction = (float)json.get_float("staticFriction") ?? 0;
	self.dynamic_friction = (float)json.get_float("dynamicFriction") ?? 0;
	self.restitution = (float)json.get_float("restitution") ?? 0;

	String friction_combine = json.get_string("frictionCombine") ?? "multiply";
	String restitution_combine = json.get_string("restitutionCombine") ?? "maximum";

	switch (friction_combine)
	{
		case "average":
			self.friction_combine = AVERAGE;
		case "minimum":
			self.friction_combine = MINIMUM;
		case "maximum":
			self.friction_combine = MAXIMUM;
		case "multiply":
			self.friction_combine = MULTIPLY;
		default:
			self.friction_combine = MULTIPLY;
	}

	switch (restitution_combine)
	{
		case "average":
			self.restitution_combine = AVERAGE;
		case "minimum":
			self.restitution_combine = MINIMUM;
		case "maximum":
			self.restitution_combine = MAXIMUM;
		case "multiply":
			self.restitution_combine = MULTIPLY;
		default:
			self.restitution_combine = MAXIMUM;
	}

	return self;
}

// Walk up parent chain to find the rigid body that owns this node's collider.
// Returns null if no ancestor has motion (static collider).
fn Node* Node.find_rigid_body(&self)
{
	Node* node = self;
	while (node != null)
	{
		if (node.has_motion()) return node;
		node = node.parent;
	}
	return null;
}

// Returns true if the node has a collider but no ancestor has motion.
fn bool Gltf.is_static_collider(&self, uint node_index)
{
	Node* node = &self.nodes[node_index];
	if (!node.has_collider()) return false;
	return node.find_rigid_body() == null;
}

struct WorldShape
{
	ShapeType type;
	Vec3 position;
	Quaternionf rotation;
	Vec3 size;
	float radius;
	float height;
	float radius_bottom;
	float radius_top;
}

// Get a collider's implicit shape transformed to world space.
fn WorldShape Gltf.collider_world_shape(&self, uint node_index)
{
	Node node = self.nodes[node_index];
	Collider collider = self.colliders[(uint)node.collider];
	Shape shape = self.shapes[(uint)collider.shape];

	Vec3 pos = node.world_position();
	Quaternionf rot = node.world_rotation();
	Vec3 scl = node.world_scale();

	WorldShape ws = {
		.type = shape.type,
		.position = pos,
		.rotation = rot,
	};

	switch (shape.type)
	{
		case BOX:
			ws.size = {
				shape.size[0] * scl[0],
				shape.size[1] * scl[1],
				shape.size[2] * scl[2]
			};
		case SPHERE:
			ws.radius = shape.radius * math::max(scl[0], math::max(scl[1], scl[2]));
		case CAPSULE:
			float xz_scale = math::max(scl[0], scl[2]);
			ws.height = shape.height * scl[1];
			ws.radius_bottom = shape.radius_bottom * xz_scale;
			ws.radius_top = shape.radius_top * xz_scale;
		case CYLINDER:
			float xz_scale = math::max(scl[0], scl[2]);
			ws.height = shape.height * scl[1];
			ws.radius_bottom = shape.radius_bottom * xz_scale;
			ws.radius_top = shape.radius_top * xz_scale;
	}

	return ws;
}

// Get world-space AABB for a collider node.
fn Aabb Gltf.collider_aabb(&self, uint node_index)
{
	Node node = self.nodes[node_index];
	Collider collider = self.colliders[(uint)node.collider];

	if (collider.is_implicit())
	{
		Shape shape = self.shapes[(uint)collider.shape];
		return shape.aabb().transform(node.global_matrix());
	}

	if (collider.has_mesh())
	{
		return self.node_world_aabb(node);
	}

	return { };
}

// Iterate all colliders belonging to a single rigid body (compound shapes).
// Walks descendants of body_node_index; skips nodes with their own motion (independent bodies).
macro void Gltf.@each_collider_for_body(Gltf self, uint body_node_index; @callback(Collider collider, uint collider_index, Node node, uint node_index))
{
	uint[256] stack;
	usz stack_top = 0;

	// Check the body node itself
	Node body_node = self.nodes[body_node_index];
	if (body_node.has_collider())
	{
		@callback(self.colliders[(uint)body_node.collider], (uint)body_node.collider, body_node, body_node_index);
	}

	// Push children
	usz child_count = body_node.children.len();
	for (usz i = child_count; i > 0; i--)
	{
		stack[stack_top++] = body_node.children[i - 1];
	}

	while (stack_top > 0)
	{
		uint node_index = stack[--stack_top];
		Node node = self.nodes[node_index];

		// Skip nodes with their own motion (independent rigid bodies)
		if (node.has_motion()) continue;

		if (node.has_collider())
		{
			@callback(self.colliders[(uint)node.collider], (uint)node.collider, node, node_index);
		}

		usz cc = node.children.len();
		for (usz i = cc; i > 0; i--)
		{
			stack[stack_top++] = node.children[i - 1];
		}
	}
}

fn Vec3 decompose_joint(Node body, Node joint)
{
	return (body.global_matrix().inverse()!! * joint.global_matrix() * (Vec4) { 0, 0, 0, 1 }).xyz * body.scale;
}
