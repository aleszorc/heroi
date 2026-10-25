# Audio sources

All files are processed (trimmed, mono, peak-normalized, resampled) with ffmpeg from the
sources below. Every source is CC0 / public domain — no attribution required, commercial
use allowed. Synthesized files were generated from scratch with ffmpeg.

## The Free Firearm Sound Library (CC0)
https://opengameart.org/content/the-free-firearm-sound-library

- `shot_ak_1..3.wav` — AK-47 single shots (C_28P)
- `shot_ak_4.wav` — AR-15 single shot (D_32P)
- `burst_mg_1.wav`, `burst_mg_2.wav` — AK-47 long bursts (C_27P, C_36P)
- `shot_sniper_1.wav` — Tikka T3 .30-06 (W_29P)
- `shot_sniper_2.wav` — Savage 10 .300 BLK (T_27P)
- `shot_cannon.wav` — Mosin Nagant 7.62x54 (M_21P) pitched down 0.68x (autocannon)

## Freesound.org (all CC0)
- `shot_gun125.wav` — "Cannon explosion sound 4" by SamsterBirdies, freesound.org/s/621003
- `rpg_launch.wav` — "M142 HIMARS Rocket Launch 8" by qubodup, freesound.org/s/854476
- `expl_big.wav` — "Explosive 1 v1" by qubodup, freesound.org/s/182432
  (the source holds three successive bangs; trimmed to the final one so an impact booms once)
- `expl_far.wav` — "small explosion in city far away" by Garuda1982, freesound.org/s/613560
- `arty_out.wav` — "K-55 Artillery" by qubodup, freesound.org/s/184365
- `distant_battle.wav` — "Distant Cannon Fire (simulated)" by stomachache, freesound.org/s/565794
- `collapse.wav` — "Crashing Collapse of Wood Building" by craigsmith, freesound.org/s/487142
- `whistle_1..4.wav` — "Incoming mortar 1-4" by Zagge28, freesound.org/s/241837 241838 241839 241840
  (trimmed to the incoming rush only — the recordings' own impact explosion is cut so the
  game's blast sound is the single boom; front-padded to a uniform 0.9 s)
- `engine_loop.mp3` — "Driving Tank Engine" by qubodup, freesound.org/s/187676
- `drone_fpv_loop.mp3` — "Tiny Hawk 2 short flight" by Sadiquecat, freesound.org/s/677833
- `drone_recon_loop.mp3` — "Dji Mavic Mini 2 hover" by Sadiquecat, freesound.org/s/683298
- `drone_heavy_loop.mp3` — "Big Slow Heavy Drone Hovering Idle Loop" by qubodup, freesound.org/s/854382
- `ambience_field.mp3` — "Open field winds summer ambience" by nickmaysoundmusic, freesound.org/s/523374

## Synthesized with ffmpeg (original work, CC0)
- `crack.wav` — supersonic bullet snap (filtered noise impulse)
- `ui_tick.wav` — UI tick (1.3 kHz sine blip)
