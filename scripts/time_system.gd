extends Node

## Game clock — the day / hour counter that drives Survival mode.
##
## Time is a single monotonically increasing float (`total_hours`) so it
## replicates as one number and can't drift out of order. Day 1 starts at
## 08:00, a full in-game day takes REAL_SECONDS_PER_DAY seconds of wall clock.
##
## The host owns the clock and pushes `total_hours` inside the survival state
## packet (see survival_mode.gd / main.gd). Clients call `net_set_hours()` and
## keep ticking locally between packets, so the corner clock stays smooth even
## at a 1 Hz sync rate.

signal day_changed(day: int)

## Wall-clock seconds per in-game day. 2 minutes/day puts the day-15 finale
## about half an hour into a session — long enough to matter, short enough to
## finish in one sitting.
const REAL_SECONDS_PER_DAY := 120.0
const HOURS_PER_DAY := 24.0
const START_HOUR := 8.0

## Hour at which night falls / lifts (used for lighting + the HUD clock tint).
const DUSK_HOUR := 19.0
const DAWN_HOUR := 6.0

var total_hours: float = START_HOUR
var running: bool = true

var _last_day: int = 1

## Advance the clock. Only the authority (host / single-player) should call this.
func advance(delta: float) -> void:
	if not running:
		return
	total_hours += delta * (HOURS_PER_DAY / REAL_SECONDS_PER_DAY)
	_check_day_rollover()

## Client-side: adopt the host's clock. Small corrections are eased in so the
## displayed minutes never jump backwards on a late packet; big gaps snap.
func net_set_hours(value: float) -> void:
	if absf(value - total_hours) > 0.5:
		total_hours = value
	else:
		total_hours = lerpf(total_hours, value, 0.25)
	_check_day_rollover()

func _check_day_rollover() -> void:
	var d := day()
	if d != _last_day:
		_last_day = d
		day_changed.emit(d)

## 1-based day counter — the number the HUD shows.
func day() -> int:
	return int(floor(total_hours / HOURS_PER_DAY)) + 1

func hour() -> int:
	return int(fmod(total_hours, HOURS_PER_DAY))

func minute() -> int:
	return int(fmod(total_hours, 1.0) * 60.0)

## Fractional hour-of-day, e.g. 13.5 for 13:30. Used for sun placement.
func hour_of_day() -> float:
	return fmod(total_hours, HOURS_PER_DAY)

func is_night() -> bool:
	var h := hour_of_day()
	return h >= DUSK_HOUR or h < DAWN_HOUR

## Whole in-game days from now until the start of `target_day`. 0 once that
## day has arrived.
func days_until(target_day: int) -> int:
	return maxi(target_day - day(), 0)

## "Day 3  ·  14:20" — the corner-clock string.
func clock_text() -> String:
	return "Day %d  ·  %02d:%02d" % [day(), hour(), minute()]
