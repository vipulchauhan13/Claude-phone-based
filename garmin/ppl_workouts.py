#!/usr/bin/env python3
"""Create Jeremy Ethier's Push / Pull / Legs workouts in Garmin Connect.

Usage (run on your own computer, not from a phone):

    pip install "garminconnect[workout]"
    python ppl_workouts.py --day legs --schedule today --push-to-device
    python ppl_workouts.py --day all                 # create all three templates
    python ppl_workouts.py --day legs --dry-run      # print the JSON, touch nothing

Credentials: pass --email, or set GARMIN_EMAIL / GARMIN_PASSWORD, or type them at the
prompt. After the first login a token is cached in ~/.garminconnect so you are not asked
again (and MFA, if enabled on your account, is only needed once).

The workouts land in Garmin Connect > Training & Planning > Workouts. With
--schedule they also appear on today's calendar, and with --push-to-device they are
sent straight to your last-used watch on its next sync.

Rep targets use the TOP of each rep range; the range itself is in the step notes.
Edit the WORKOUTS table below to change anything.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path

TOKEN_STORE = Path("~/.garminconnect").expanduser()


@dataclass(frozen=True)
class Exercise:
    """One exercise block: `sets` x `reps` with `rest` seconds between sets."""

    names: tuple[str, ...]  # Garmin catalog display names, first match wins
    category: str  # Garmin category used if no name matches
    sets: int
    reps: int
    rest: int
    rep_range: str
    per_side: bool = False  # True = do `reps` on each leg/arm inside every set


# Jeremy Ethier's science-based Push/Pull/Legs (Built With Science, PPL video series).
# Legs is the day from "The Best Science-Based Leg Workout for Growth".
WORKOUTS: dict[str, list[Exercise]] = {
    "legs": [
        Exercise(("Barbell Back Squat",), "SQUAT", 3, 8, 180, "6-8"),
        Exercise(("Barbell Hip Thrust with Bench",), "HIP_RAISE", 3, 10, 120, "8-10"),
        Exercise(("Dumbbell Bulgarian Split Squat",), "LUNGE", 3, 10, 120, "8-10 per leg", per_side=True),
        Exercise(("Leg Extensions",), "CRUNCH", 3, 15, 90, "10-15, slow 3 s lowering"),
        Exercise(("Lying Leg Curl", "Leg Curl"), "LEG_CURL", 3, 15, 90, "10-15"),
        Exercise(("Standing Calf Raise",), "CALF_RAISE", 3, 15, 60, "10-15, pause at bottom"),
        Exercise(("Seated Calf Raise",), "CALF_RAISE", 3, 15, 60, "10-15"),
    ],
    "push": [
        Exercise(("Incline Barbell Bench Press",), "BENCH_PRESS", 3, 8, 180, "6-8"),
        Exercise(("Standing Dumbbell Shoulder Press", "Dumbbell Shoulder Press"), "SHOULDER_PRESS", 3, 15, 120, "10-15"),
        Exercise(("Paused Dumbbell Bench Press", "Dumbbell Bench Press"), "BENCH_PRESS", 3, 12, 120, "8-12, 1 s pause at chest"),
        Exercise(("One-arm Cable Lateral Raise", "Cable Lateral Raise"), "LATERAL_RAISE", 3, 15, 60, "10-15 per arm, lean away", per_side=True),
        Exercise(("Cable Overhead Triceps Extension", "Rope Overhead Triceps Extension"), "TRICEPS_EXTENSION", 3, 15, 60, "10-15"),
        Exercise(("Rope Press-down", "Triceps Press-down"), "TRICEPS_EXTENSION", 3, 15, 60, "10-15"),
    ],
    "pull": [
        Exercise(("Weighted Pull-up", "Pull-up"), "PULL_UP", 3, 8, 180, "6-8 (or lat pulldown)"),
        Exercise(("Barbell Row", "Chest-supported Row"), "ROW", 3, 10, 120, "8-10"),
        Exercise(("Reverse-grip Lat Pull-down", "Underhand-grip Lat Pull-down", "Lat Pull-down", "Lat Pulldown"), "PULL_UP", 3, 12, 90, "10-12"),
        Exercise(("Face Pull",), "ROW", 3, 15, 60, "10-15, pull to forehead"),
        Exercise(("Incline Dumbbell Biceps Curl", "Incline Dumbbell Curl"), "CURL", 3, 12, 60, "8-12"),
        Exercise(("Dumbbell Hammer Curl",), "CURL", 3, 12, 60, "10-12"),
    ],
}

WORKOUT_TITLES = {
    "legs": "PPL Legs (Jeremy Ethier)",
    "push": "PPL Push (Jeremy Ethier)",
    "pull": "PPL Pull (Jeremy Ethier)",
}

SECONDS_PER_REP = 4  # rough, only used for the estimated duration shown in Garmin


def resolve_exercise(exercise: Exercise):
    """Map display names onto Garmin's (category, exerciseName) pair."""
    from garminconnect import exercises

    for name in exercise.names:
        entry = exercises.resolve(name)
        if entry:
            return entry["category"], entry["exercise"], name
    # Fuzzy: any catalog entry containing the first name's key words.
    for name in exercise.names:
        hits = exercises.find(name)
        if hits:
            return hits[0]["category"], hits[0]["exercise"], hits[0]["name"]
    print(f"  ! '{exercise.names[0]}' is not in Garmin's catalog, using category {exercise.category} only", file=sys.stderr)
    return exercise.category, "", exercise.names[0]


def build_workout(day: str):
    from garminconnect.workout import (
        StrengthWorkout,
        WorkoutSegment,
        create_repeat_group,
        create_strength_exercise_step,
        create_strength_rest_step,
    )

    steps = []
    order = 1
    duration = 0
    for exercise in WORKOUTS[day]:
        category, name, label = resolve_exercise(exercise)
        inner = []
        sides = 2 if exercise.per_side else 1
        for _ in range(sides):
            order += 1
            step = create_strength_exercise_step(category, order, exercise.reps, exercise_name=name)
            step.description = f"{label}: {exercise.rep_range}"
            inner.append(step)
        order += 1
        inner.append(create_strength_rest_step(exercise.rest, order))
        group_order = order - len(inner)
        steps.append(create_repeat_group(exercise.sets, inner, group_order))
        order += 1
        duration += exercise.sets * (sides * exercise.reps * SECONDS_PER_REP + exercise.rest)

    return StrengthWorkout(
        workoutName=WORKOUT_TITLES[day],
        estimatedDurationInSecs=duration,
        description="Science-based Push/Pull/Legs by Jeremy Ethier (Built With Science). "
        "Rep targets are the top of each range; see step notes.",
        workoutSegments=[
            WorkoutSegment(
                segmentOrder=1,
                sportType={"sportTypeId": 5, "sportTypeKey": "strength_training", "displayOrder": 5},
                workoutSteps=steps,
            )
        ],
    )


def login(email: str | None):
    from garminconnect import Garmin

    email = email or os.environ.get("GARMIN_EMAIL")
    password = os.environ.get("GARMIN_PASSWORD")

    if TOKEN_STORE.exists():
        api = Garmin()
        try:
            api.login(str(TOKEN_STORE))
            return api
        except Exception as error:  # expired or revoked token: fall through to a fresh login
            print(f"Cached Garmin login no longer valid ({error}); logging in again.")

    email = email or input("Garmin Connect email: ")
    password = password or getpass.getpass("Garmin Connect password: ")
    api = Garmin(email, password, prompt_mfa=lambda: input("Garmin MFA code: "))
    api.login()
    api.garth.dump(str(TOKEN_STORE))
    return api


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--day", choices=[*WORKOUTS, "all"], default="legs")
    parser.add_argument("--email", help="Garmin Connect email (or set GARMIN_EMAIL)")
    parser.add_argument("--schedule", metavar="DATE", help="'today' or YYYY-MM-DD: put the workout on the Garmin calendar")
    parser.add_argument("--push-to-device", action="store_true", help="send the workout to your last-used watch")
    parser.add_argument("--dry-run", action="store_true", help="print the workout JSON and exit without logging in")
    args = parser.parse_args()

    try:
        import garminconnect  # noqa: F401
        import pydantic  # noqa: F401
    except ImportError:
        print('Missing dependency. Run:  pip install "garminconnect[workout]"', file=sys.stderr)
        return 1

    days = list(WORKOUTS) if args.day == "all" else [args.day]
    workouts = {day: build_workout(day) for day in days}

    if args.dry_run:
        for day, workout in workouts.items():
            print(json.dumps(workout.to_dict(), indent=2))
        return 0

    api = login(args.email)
    schedule_date = None
    if args.schedule:
        schedule_date = date.today().isoformat() if args.schedule == "today" else args.schedule

    for day, workout in workouts.items():
        created = api.upload_strength_workout(workout)
        workout_id = created["workoutId"]
        print(f"Created '{workout.workoutName}' (id {workout_id})")

        if schedule_date and (args.day != "all" or day == "legs"):
            api.schedule_workout(workout_id, schedule_date)
            print(f"  scheduled for {schedule_date}")
        if args.push_to_device and (args.day != "all" or day == "legs"):
            result = api.push_workout_to_device(workout_id)
            print(f"  sent to device: {result}")

    print("\nOn the watch: Strength > (hold/menu) > Training > Workouts, or sync Garmin Connect first.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
