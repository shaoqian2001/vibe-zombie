shader_type canvas_item;

// FOV fog-of-war overlay.
// fov_polygon holds N_VERTS vertices in UV [0,1] space (top-left = 0,0).
// Using UV instead of FRAGCOORD avoids mismatches between physical window
// pixels and the logical viewport coords returned by unproject_position()
// under Godot's canvas_items stretch mode.
//
// The polygon is a lens / vesica shape: two circular arcs meeting at an apex
// (the character's head) and a far tip (view_distance ahead). Each arc is
// sampled with ARC_SEGMENTS + 1 points, so the total vertex count is
// 2 * (ARC_SEGMENTS + 1). Apex and tip are duplicated once each, which the
// point-in-polygon ray-cast tolerates (zero-length edges are no-ops).

const int N_VERTS = 34;  // 2 arcs * (16 segments + 1) points per arc

uniform vec2 fov_polygon[N_VERTS];
uniform float fog_alpha : hint_range(0.0, 1.0) = 0.88;

bool point_in_polygon(vec2 p) {
	bool inside = false;
	int j = N_VERTS - 1;
	for (int i = 0; i < N_VERTS; i++) {
		vec2 vi = fov_polygon[i];
		vec2 vj = fov_polygon[j];
		if ((vi.y > p.y) != (vj.y > p.y)) {
			float ix = (vj.x - vi.x) * (p.y - vi.y) / (vj.y - vi.y) + vi.x;
			if (p.x < ix) {
				inside = !inside;
			}
		}
		j = i;
	}
	return inside;
}

void fragment() {
	if (point_in_polygon(UV)) {
		COLOR = vec4(0.0, 0.0, 0.0, 0.0);
	} else {
		COLOR = vec4(0.0, 0.0, 0.0, fog_alpha);
	}
}
