shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

// World-space FOV shadow overlay.
//
// Rendered as a second pass (material_overlay) on top of every cullable
// surface. Each fragment classifies its own world XZ against the player's
// view sector and draws a black, semi-transparent layer over fragments
// that fall outside the cone — visually "casting shadow" on them while
// leaving in-sector fragments untouched.
//
// A single ShaderMaterial holding this shader is shared across every
// rendered mesh in the world (see scripts/vision_shadow.gd). The script
// sets the uniforms once per frame from the player's pose, so all
// meshes — ground, roads, buildings, zombies — pick up the new sector
// in lockstep.
//
// player_pos    — head position. Only XZ is used; Y kept for reach.
// facing        — XZ unit vector the player is looking along.
// half_angle    — half-FOV in radians.
// view_distance — sector radius in world units.
// angle_band    — radians of soft transition either side of the angular
//                 boundary. Wider = softer edge.
// dist_band     — world-unit soft transition band on the far edge.
// shadow_alpha  — peak alpha of the shadow overlay (0..1). Lower values
//                 mean out-of-vision surfaces stay more visible.

uniform vec3 player_pos = vec3(0.0);
uniform vec2 facing = vec2(0.0, 1.0);
uniform float half_angle : hint_range(0.0, 3.14159) = 1.27;
uniform float view_distance : hint_range(0.0, 200.0) = 25.0;
uniform float angle_band : hint_range(0.0, 1.0) = 0.18;
uniform float dist_band : hint_range(0.0, 20.0) = 4.0;
uniform float shadow_alpha : hint_range(0.0, 1.0) = 0.85;

// World-space surface position for this fragment, captured before the
// engine applies its view/projection transforms. Lets the fragment
// stage classify the surface against the player's sector directly,
// independent of camera or render-path quirks.
varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Slight outward bias so the overlay never z-fights with the host
	// surface, even on thin rooftop trim and door panels.
	VERTEX += NORMAL * 0.001;
}

void fragment() {
	vec2 delta = world_pos.xz - player_pos.xz;
	float dist = length(delta);

	// Fragments coincident with the player are always considered "in".
	// Avoids a divide-by-zero when normalising the direction.
	float inside;
	if (dist < 0.0001) {
		inside = 1.0;
	} else {
		vec2 dir = delta / dist;
		float cos_ang = clamp(dot(dir, facing), -1.0, 1.0);
		float ang = acos(cos_ang);

		// Smoothstep returns 1 well inside the sector, 0 well outside,
		// with the soft band providing the temporal/angular feathering.
		float ang_in = 1.0 - smoothstep(
			half_angle - angle_band,
			half_angle + angle_band,
			ang);
		float dist_in = 1.0 - smoothstep(
			view_distance - dist_band,
			view_distance + dist_band,
			dist);
		inside = ang_in * dist_in;
	}

	// Shadow grows where the fragment is outside the sector.
	float shadow = (1.0 - inside) * shadow_alpha;
	ALBEDO = vec3(0.0);
	ALPHA = shadow;
}
