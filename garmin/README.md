# Jeremy Ethier Push / Pull / Legs → Garmin Connect

`ppl_workouts.py` creates the three workouts as Garmin **strength** workouts (sets, reps,
rest timers, exercise names the watch recognises) and can schedule today's session and
send it to your watch.

Garmin has no public API for personal accounts, so this uses the community
[`garminconnect`](https://github.com/cyberjunky/python-garminconnect) library, which logs in
with your normal Garmin Connect email and password (MFA supported) and stores a token in
`~/.garminconnect`.

## Run it (on a Mac/PC)

```bash
pip install "garminconnect[workout]"
python garmin/ppl_workouts.py --day legs --schedule today --push-to-device
```

Then sync your watch with the Garmin Connect app. Start a **Strength** activity, open the
menu, choose **Training → Workouts → PPL Legs (Jeremy Ethier)**. The watch will walk you
through every set with the rest timer running automatically.

Other options:

```bash
python garmin/ppl_workouts.py --day all        # push + pull + legs templates
python garmin/ppl_workouts.py --day legs --dry-run   # show the JSON only
```

## The Legs day

| # | Exercise | Sets × reps | Rest |
|---|---|---|---|
| 1 | Barbell back squat | 3 × 6-8 | 3 min |
| 2 | Barbell hip thrust | 3 × 8-10 | 2 min |
| 3 | Bulgarian split squat (dumbbells) | 3 × 8-10 per leg | 2 min |
| 4 | Leg extension (slow 3 s lowering) | 3 × 10-15 | 90 s |
| 5 | Lying leg curl | 3 × 10-15 | 90 s |
| 6 | Standing calf raise (pause at bottom) | 3 × 10-15 | 60 s |
| 7 | Seated calf raise | 3 × 10-15 | 60 s |

Push and Pull are in the same file. The lists are reconstructed from Jeremy Ethier's
Built With Science PPL series; Legs is complete, Push and Pull may differ slightly from the
latest version of his programme, so adjust the `WORKOUTS` table if you follow a newer PDF.

## Entering it by hand on the phone instead

Garmin Connect app → **Training & Planning → Workouts → Create a Workout → Strength**, then add
each exercise above as a block with "Sets 3", "Reps N", "Rest N s". Save → **⋯ → Send to Device**.
