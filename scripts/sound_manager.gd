extends Node

## Procedural sound-effects engine (autoload singleton).
##
## In keeping with the project's "everything is generated in code, no external
## art assets" philosophy, this manager synthesises every sound effect at
## startup as raw 16-bit PCM `AudioStreamWAV` buffers — there are no .wav/.ogg
## files in the repo. Each effect is built from oscillators, exponential
## envelopes and one-pole-filtered white noise (see the `_make_*` builders).
##
## Playback uses Godot's built-in audio engine:
##   • `play_2d`  — non-positional `AudioStreamPlayer`, used for the LOCAL
##     player's own footsteps / gunfire so they're always crisp regardless of
##     the isometric camera distance (~22 units from the player).
##   • `play_on`  — positional `AudioStreamPlayer3D` parented to a moving node
##     (zombies, remote players) so the sound tracks the source and attenuates
##     with distance. The active Camera3D is the audio listener by default.
##   • `play_at`  — positional one-shot at a fixed world position, detached
##     from any node (used for a zombie death, where the node is freed
##     immediately).
##
## A small concurrency cap keeps a large horde from spawning hundreds of
## simultaneous voices.

const MIX_RATE := 22050
const MAX_CONCURRENT := 28

# name -> AudioStreamWAV
var _cache: Dictionary = {}
# Number of transient 3D voices currently alive (for the concurrency cap).
var _active_3d := 0

func _ready() -> void:
	_generate_library()

# ------------------------------------------------------------------
# Public playback API
# ------------------------------------------------------------------

## Non-positional one-shot — full clarity, no spatial attenuation. Used for the
## local player's own actions.
func play_2d(sound: String, pitch: float = 1.0, volume_db: float = 0.0) -> void:
	var stream: AudioStream = _cache.get(sound)
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.pitch_scale = pitch
	p.volume_db = volume_db
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()

## Positional one-shot parented to `node` (which must be in the scene tree) so
## the voice follows the source as it moves.
func play_on(node: Node, sound: String, pitch: float = 1.0, volume_db: float = 0.0) -> void:
	if node == null or not is_instance_valid(node):
		return
	var stream: AudioStream = _cache.get(sound)
	if stream == null or _active_3d >= MAX_CONCURRENT:
		return
	var p := _make_3d_player(stream, pitch, volume_db)
	node.add_child(p)
	_active_3d += 1
	p.finished.connect(func() -> void:
		_active_3d -= 1
		p.queue_free())
	p.play()

## Positional one-shot at a fixed world position, detached from any source node
## (the node may be freed the same frame, e.g. a dying zombie).
func play_at(sound: String, world_pos: Vector3, pitch: float = 1.0, volume_db: float = 0.0) -> void:
	var stream: AudioStream = _cache.get(sound)
	if stream == null or _active_3d >= MAX_CONCURRENT:
		return
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_tree().root
	var p := _make_3d_player(stream, pitch, volume_db)
	parent.add_child(p)
	p.global_position = world_pos
	_active_3d += 1
	p.finished.connect(func() -> void:
		_active_3d -= 1
		p.queue_free())
	p.play()

func _make_3d_player(stream: AudioStream, pitch: float, volume_db: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.pitch_scale = pitch
	p.volume_db = volume_db
	# unit_size = distance (world units) at which the voice plays at full
	# volume; beyond it the default inverse-distance model rolls off. Tuned so
	# a source is clearly audible across the ~22-unit isometric camera gap but
	# fades out for distant zombies.
	p.unit_size = 14.0
	p.max_distance = 80.0
	return p

# ------------------------------------------------------------------
# Sound library — synthesised once at startup.
# ------------------------------------------------------------------

func _generate_library() -> void:
	# Footsteps (pitch/volume varied per step at play time).
	_cache["footstep"] = _make_footstep()
	# Gunfire — one timbre per weapon class.
	_cache["gun_pistol"]  = _make_gunshot(0.20, 110.0, 0.70, 42.0, 13.0)
	_cache["gun_smg"]     = _make_gunshot(0.11, 135.0, 0.62, 60.0, 20.0)
	_cache["gun_ak47"]    = _make_gunshot(0.17, 95.0,  0.78, 34.0, 13.0)
	_cache["gun_shotgun"] = _make_gunshot(0.38, 70.0,  0.95, 16.0, 8.5)
	_cache["gun_grenade"] = _make_gunshot(0.34, 55.0,  0.55, 14.0, 7.0)
	_cache["dry_fire"]    = _make_dry_fire()
	_cache["reload"]      = _make_reload()
	# Melee.
	_cache["swing_bat"]   = _make_swing(0.26, 0.95)
	_cache["swing_fist"]  = _make_swing(0.17, 0.6)
	_cache["melee_hit"]   = _make_melee_hit()
	# Zombie vocals.
	_cache["zombie_groan"]  = _make_groan(92.0, 0.95, 0.28)
	_cache["zombie_attack"] = _make_zombie_attack()
	_cache["zombie_death"]  = _make_zombie_death()

# ------------------------------------------------------------------
# Synthesis helpers
# ------------------------------------------------------------------

## Pack a [-1, 1] float buffer into a mono 16-bit PCM AudioStreamWAV.
func _to_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		var v := clampf(samples[i], -1.0, 1.0)
		bytes.encode_s16(i * 2, int(v * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
	wav.data = bytes
	return wav

## Peak-normalise a buffer to `peak` (in-place), so hand-tuned per-sample gains
## don't clip and every effect lands at a predictable loudness.
func _normalize(s: PackedFloat32Array, peak: float) -> void:
	var m := 0.0
	for v in s:
		m = max(m, absf(v))
	if m < 1e-5:
		return
	var g := peak / m
	for i in s.size():
		s[i] *= g

## Gunshot: a sharp noise "crack" (fast exponential decay) layered over a
## lower-frequency body sine ("thump") with a slower decay. Heavier weapons use
## a lower body frequency and slower decays for a boomier report.
func _make_gunshot(dur: float, body_hz: float, noise_amt: float,
		crack_decay: float, body_decay: float) -> AudioStreamWAV:
	var n := int(dur * MIX_RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / MIX_RATE
		var crack := exp(-t * crack_decay)
		var body_env := exp(-t * body_decay)
		var noise := randf() * 2.0 - 1.0
		# One-pole low-pass adds a darker layer beneath the bright noise.
		lp += 0.45 * (noise - lp)
		var body := sin(TAU * body_hz * t) * body_env
		s[i] = (noise * 0.6 + lp * 0.4) * noise_amt * crack + body * 0.7
	_normalize(s, 0.95)
	return _to_wav(s)

## Footstep: a soft low thump plus heavily low-passed noise (a scuff), both
## under a quick decay envelope. Pitch/volume are randomised at play time so
## repeated steps don't sound mechanically identical.
func _make_footstep() -> AudioStreamWAV:
	var dur := 0.13
	var n := int(dur * MIX_RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / MIX_RATE
		var env := exp(-t * 28.0)
		var noise := randf() * 2.0 - 1.0
		lp += 0.25 * (noise - lp)
		var thump := sin(TAU * 65.0 * t) * exp(-t * 22.0)
		s[i] = (lp * 0.7 + thump * 0.85) * env
	_normalize(s, 0.75)
	return _to_wav(s)

## Dry-fire click — a tiny noise tick with a high metallic ping.
func _make_dry_fire() -> AudioStreamWAV:
	var dur := 0.05
	var n := int(dur * MIX_RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / MIX_RATE
		var env := exp(-t * 120.0)
		s[i] = ((randf() * 2.0 - 1.0) * 0.5 + sin(TAU * 1800.0 * t) * 0.5) * env
	_normalize(s, 0.6)
	return _to_wav(s)

## Reload — two short mechanical clicks (mag out / mag in) spaced apart.
func _make_reload() -> AudioStreamWAV:
	var dur := 0.45
	var n := int(dur * MIX_RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var t2 := 0.22
	for i in n:
		var t := float(i) / MIX_RATE
		var e1 := exp(-t * 45.0)
		var c1 := ((randf() * 2.0 - 1.0) * 0.5 + sin(TAU * 1200.0 * t) * 0.5) * e1
		var c2 := 0.0
		if t >= t2:
			var td := t - t2
			var e2 := exp(-td * 45.0)
			c2 = ((randf() * 2.0 - 1.0) * 0.5 + sin(TAU * 800.0 * td) * 0.5) * e2
		s[i] = c1 * 0.5 + c2 * 0.6
	_normalize(s, 0.6)
	return _to_wav(s)

## Melee swing whoosh — low-passed noise under a smooth "hump" envelope, the
## filter opening up at the peak so it brightens mid-swing.
func _make_swing(dur: float, peak: float) -> AudioStreamWAV:
	var n := int(dur * MIX_RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var frac := float(i) / float(n)
		var env: float = pow(sin(PI * frac), 1.3)
		var noise := randf() * 2.0 - 1.0
		var a: float = lerpf(0.05, 0.5, env)
		lp += a * (noise - lp)
		s[i] = lp * env
	_normalize(s, peak)
	return _to_wav(s)

## Melee impact — a blunt thud: low thump plus a short filtered noise crunch.
func _make_melee_hit() -> AudioStreamWAV:
	var dur := 0.14
	var n := int(dur * MIX_RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / MIX_RATE
		var env := exp(-t * 30.0)
		var noise := randf() * 2.0 - 1.0
		lp += 0.4 * (noise - lp)
		var thump := sin(TAU * 90.0 * t) * exp(-t * 25.0)
		s[i] = (lp * 0.6 + thump * 0.9) * env
	_normalize(s, 0.85)
	return _to_wav(s)

## Zombie groan — a low harmonic tone (fundamental + a couple of harmonics)
## with a slow vibrato and a raspy noise layer, under a smooth swell envelope.
func _make_groan(base_hz: float, dur: float, rasp_amt: float) -> AudioStreamWAV:
	var n := int(dur * MIX_RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var lpn := 0.0
	for i in n:
		var t := float(i) / MIX_RATE
		var env := sin(PI * clampf(t / dur, 0.0, 1.0))
		var vib := 1.0 + 0.05 * sin(TAU * 5.5 * t)
		var f := base_hz * vib
		var tone := sin(TAU * f * t) + 0.5 * sin(TAU * 2.0 * f * t) + 0.28 * sin(TAU * 3.0 * f * t)
		tone /= 1.78
		var noise := randf() * 2.0 - 1.0
		lpn += 0.15 * (noise - lpn)
		s[i] = (tone * 0.8 + lpn * rasp_amt) * env
	_normalize(s, 0.85)
	return _to_wav(s)

## Zombie attack snarl — like a groan but shorter, rising in pitch, with a
## faster attack and more rasp for an aggressive lunge.
func _make_zombie_attack() -> AudioStreamWAV:
	var dur := 0.5
	var n := int(dur * MIX_RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var phase := 0.0
	var lpn := 0.0
	for i in n:
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var env := exp(-t * 5.0) * minf(1.0, t / 0.02)
		var f: float = lerpf(120.0, 185.0, frac)
		phase += TAU * f / MIX_RATE
		var tone := sin(phase) + 0.5 * sin(2.0 * phase) + 0.3 * sin(3.0 * phase)
		tone /= 1.8
		var noise := randf() * 2.0 - 1.0
		lpn += 0.3 * (noise - lpn)
		s[i] = (tone * 0.7 + lpn * 0.5) * env
	_normalize(s, 0.9)
	return _to_wav(s)

## Zombie death — a groan whose pitch slides downward as an increasing gurgle
## of noise takes over, fading out.
func _make_zombie_death() -> AudioStreamWAV:
	var dur := 1.1
	var n := int(dur * MIX_RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var phase := 0.0
	var lpn := 0.0
	for i in n:
		var t := float(i) / MIX_RATE
		var frac := t / dur
		var env := exp(-t * 1.7) * minf(1.0, t / 0.03)
		var f: float = lerpf(120.0, 52.0, frac)
		phase += TAU * f / MIX_RATE
		var tone := sin(phase) + 0.45 * sin(2.0 * phase) + 0.25 * sin(3.0 * phase)
		tone /= 1.7
		var noise := randf() * 2.0 - 1.0
		lpn += 0.2 * (noise - lpn)
		var gurgle: float = lpn * lerpf(0.1, 0.55, frac)
		s[i] = (tone * 0.75 + gurgle) * env
	_normalize(s, 0.88)
	return _to_wav(s)
