shader_type canvas_item;

// FOV fog-of-war overlay.
// fov_polygon holds N_VERTS screen-pixel positions that form a closed pie-slice
// (center vertex first, then ARC_SEG+1 arc vertices going around).
// Pixels inside the polygon are transparent; outside are darkened.

const int N_VERTS = 34;  // 1 center + 33 arc points (32 arc segments)

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
	if (point_in_polygon(FRAGCOORD.xy)) {
		COLOR = vec4(0.0, 0.0, 0.0, 0.0);
	} else {
		COLOR = vec4(0.0, 0.0, 0.0, fog_alpha);
	}
}
