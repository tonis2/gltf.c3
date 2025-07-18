module gltf;

import std::collections::object;
import std::io;
import std::math;
import std::collections::list;
import std::encoding::json;

enum ShapeType {
    BOX,
    CAPSULE,
    CYLINDER,
    SPHERE,
}

enum MagFilter {
    NEAREST,
    LINEAR,
}

enum DriveType {
    ANGULAR,
    LINEAR
}

enum DriveMode {
    FORCE,
    ACCELERATION
}

enum PhysicsCombine {
    AVERAGE,
    MINIMUM,
    MAXIMUM,
    MULTIPLY
}

struct Shape {
    Vec3f size;
    float height;
    float radius_bottom;
    float radius_top;
    float radius;
    ShapeType type;
}

struct Limit {
    Vec3f linear_axes;
    Vec3f angular_axes;
    float min;
    float max;
    float stiffness;
    float damping;
}

struct Drive {
    DriveType type;
    DriveMode drive;
    uint axis;
    float max_force;
    float position_target;
    float velocity_target;
    float stiffness;
    float damping;
}

struct PhysicsJoint {
    List{Limit} limits;
    List{Drive} drives;
}

struct PhysicsMaterial {
    float static_friction;
    float dynamic_friction;
    float restitution;
    PhysicsCombine friction_combine;
    PhysicsCombine restitution_combine;
}

struct CollisionFilter {
   List{String} systems;
   List{String} not_colliding;
   List{String} colliding_with;
}

struct Motion {
    bool is_kinematic;
    float mass;
    float gravity_factor;
    Vec3f mass_center;
    Vec3f inertia_diagonal;
    Vec4f inertia_orientation;
    Vec3f linear_velocity;
    Vec3f angular_velocity;
}

struct Collider {
    bool convex_hull;
    int shape;
    int node;
    int material;
    int collision_filter;
}

fn bool Collider.has_shape(self) => self.shape > -1;
fn bool Collider.has_node(self) => self.node > -1;
fn bool Collider.has_material(self) => self.material > -1;
fn bool Collider.has_filter(self) => self.collision_filter > -1;

fn Collider Collider.from_json(self, Object* json) {
    Object*? geometry = json.get("geometry");

    if (try geometry) {
        self.convex_hull = geometry.get_bool("convexHull") ?? false;
        self.shape = geometry.get_int("shape") ?? -1;
        self.node = geometry.get_int("node") ?? -1;
    }
 
    self.material = json.get_int("physicsMaterial") ?? -1;
    self.collision_filter = json.get_int("collisionFilter") ?? -1;

    return self;
}

fn Motion Motion.from_json(self, Object* json) {
    Object*? center_mass = json.get("centerOfMass");
    Object*? inertia_diagonal = json.get("inertiaDiagonal");
    Object*? inertia_orientation = json.get("inertiaOrientation");
    Object*? linear_velocity = json.get("linearVelocity");
    Object*? angular_velocity = json.get("linearVelocity");

    if (try center_mass) {
        foreach (usz i, mass: center_mass.array) {
            self.mass_center[i] = (float)mass.f;
        }
    }

    if (try inertia_diagonal) {
        foreach (usz i, inertia: inertia_diagonal.array) {
            self.inertia_diagonal[i] = (float)inertia.f;
        }
    }

    if (try inertia_orientation) {
        foreach (usz i, inertia: inertia_orientation.array) {
            self.inertia_orientation[i] = (float)inertia.f;
        }
    }

    if (try linear_velocity) {
        foreach (usz i, velocity: linear_velocity.array) {
            self.linear_velocity[i] = (float)velocity.f;
        }
    }

    if (try angular_velocity) {
        foreach (usz i, velocity: angular_velocity.array) {
            self.angular_velocity[i] = (float)velocity.f;
        }
    }

    self.mass = (float)json.get_float("mass") ?? 0;
    self.gravity_factor = (float)json.get_float("gravityFactor") ?? 0;

    return self;
}

fn CollisionFilter CollisionFilter.from_json(self, Object* json) {
    Object*? systems = json.get("collisionSystems");
    Object*? collide_with = json.get("collideWithSystems");
    Object*? not_colliding = json.get("notCollideWithSystems");

    if (try systems) {
        foreach (system: systems.array) self.systems.push(system.s);
    }

    if (try collide_with) {
        foreach (system: collide_with.array) self.colliding_with.push(system.s);
    }

    if (try not_colliding) {
        foreach (system: not_colliding.array) self.not_colliding.push(system.s);
    }

    return self;
}

fn void CollisionFilter.free(&self) {
    self.systems.free();
    self.not_colliding.free();
    self.colliding_with.free();
}

fn Shape Shape.from_json(self, Object* json) {
    String? type = json.get_string("type");

    if (try type) {
        switch (type) {
            case "box": {
                Object*? box = json.get("box");
                Object*? size = box.get("size");
                self = {
                    .type = BOX,
                    .size = @ok(size) ? { (float)size.get_at(0).f!!, (float)size.get_at(1).f!!, (float)size.get_at(2).f!!} : {0,0,0}
                };
            }
            case "sphere": {
                Object*? body = json.get("sphere");
                float radius = (float)body.get_float("radius") ?? 0;
                self = {
                    .type = SPHERE,
                    .radius = radius
                };
            }
            case "cylinder": {
                Object*? body = json.get("cylinder");
                float height = (float)body.get_float("height") ?? 0;
                float radius_bottom = (float)body.get_float("radiusBottom") ?? 0;
                float radius_top = (float)body.get_float("radiusTop") ?? 0;

                self = {
                    .type = CYLINDER,
                    .height = height,
                    .radius_bottom  = radius_bottom,
                    .radius_top = radius_top
                };
            }
            case "capsule": {
                Object*? body = json.get("capsule");
                float height = (float)body.get_float("height") ?? 0;
                float radius_bottom = (float)body.get_float("radiusBottom") ?? 0;
                float radius_top = (float)body.get_float("radiusTop") ?? 0;

                self = {
                    .type = CAPSULE,
                    .height = height,
                    .radius_bottom  = radius_bottom,
                    .radius_top = radius_top
                };
            }
        }
    }

    return self;
}

fn PhysicsJoint PhysicsJoint.from_json(self, Object* json) {
    Object*? limits = json.get("limits");
    Object*? drives = json.get("drives");

    if (try limits) {
        foreach (limit: limits.array) {
            Limit joint_limit;

            joint_limit.min = (float)limit.get_float("min") ?? 0;
            joint_limit.max = (float)limit.get_float("max") ?? 0;

            Object*? linear_axes = limit.get("linearAxes");
            Object*? angular_axes = limit.get("angularAxes");

            if (try linear_axes) {
                foreach (usz i, axis: linear_axes.array) {
                    joint_limit.linear_axes[i] = (float)axis.f;
                }
            }

            if (try angular_axes) {
                foreach (usz i, axis: angular_axes.array) {
                    joint_limit.angular_axes[i] = (float)axis.f;
                }
            }

            self.limits.push(joint_limit);
        }
    }

    if (try drives) {
        foreach (drive: drives.array) {
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

fn void PhysicsJoint.free(&self) {
    self.limits.free();
    self.drives.free();
}

fn PhysicsMaterial PhysicsMaterial.from_json(self, Object* json) {
    self.static_friction = (float)json.get_float("staticFriction") ?? 0;
    self.dynamic_friction = (float)json.get_float("dynamicFriction") ?? 0;
    self.restitution = (float)json.get_float("restitution") ?? 0;
    
    String? friction_combine = json.get_string("frictionCombine");
    String? restitution_combine = json.get_string("restitutionCombine");

    if (try friction_combine) {
        switch (friction_combine) {
            case "average": self.friction_combine = AVERAGE;
            case "minimum": self.friction_combine = MINIMUM;
            case "maximum": self.friction_combine = MAXIMUM;
            case "multiply": self.friction_combine = MULTIPLY;
        }
    }

    if (try restitution_combine) {
        switch (restitution_combine) {
            case "average": self.restitution_combine = AVERAGE;
            case "minimum": self.restitution_combine = MINIMUM;
            case "maximum": self.restitution_combine = MAXIMUM;
            case "multiply": self.restitution_combine = MULTIPLY;
        }
    }

    return self;
}

macro void? Gltf.@get_compound_shape(Gltf self, uint node_index; @callback(Vec3f position)) {
    Node node = self.nodes[node_index];

    foreach (i: node.children) {
        Node collision_node = self.nodes[i];
        if (collision_node.collider != null && collision_node.collider.node > -1) {
            Node mesh_node = self.nodes[collision_node.collider.node];
            Mesh collision_mesh = self.meshes[mesh_node.mesh];
         
            self.@get_positions(collision_mesh, Vec3f; Vec3f position) {
                @callback(position);
            }!;
        }
    }
}