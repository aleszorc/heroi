class_name Scenarios
extends RefCounted
## Curated scenario presets for the start menu: fixed kind+seed combos, each seed
## vetted by playing the battle out headless (autostart, passive player) and picking
## contested results over stomps. Names and places are fictional per the GDD tone
## rules. The briefing is the menu blurb and dresses the deployment screen.

## Entry schema: {name, kind, seed, briefing}. "treeline" ignores the seed (the
## hand-built mission keeps its own briefing); generated kinds rebuild the same
## map and waves from kind+seed every time.
const ALL := [
	{
		"name": "Treeline 7",
		"kind": "treeline",
		"seed": 0,
		"briefing": "The classic stand: a shell-torn posadka, a ruined farm and the crossroads behind them. Hold two of the three positions against four mechanized waves for ten minutes.",
	},
	{
		"name": "Tykhyi Brid",
		"kind": "defend",
		"seed": 314,
		"briefing": "A quiet ford that stopped being quiet. The assault builds all the way to the final whistle — hold at least two of the three positions until time runs out, whatever it costs.",
	},
	{
		"name": "Stari Kopani",
		"kind": "defend",
		"seed": 777,
		"briefing": "Old diggings, fresh trenches, and nearly a hundred men coming through them with armour. The line will not hold everywhere — pick what you can afford to lose and make every wave pay.",
	},
	{
		"name": "Vovche Pole",
		"kind": "assault",
		"seed": 123,
		"briefing": "The brigade needs the hamlet on Wolf Field. The defenders have a tank and they shoot first — kill the armour early, then take two of the three positions before their counterattack lands.",
	},
	{
		"name": "Zhuravlyne",
		"kind": "assault",
		"seed": 500,
		"briefing": "The crane-marsh village is held by defenders who do not wait to be attacked. Standing still here is dying slowly — keep moving treeline to treeline and crack two positions in time.",
	},
	{
		"name": "Mlynove",
		"kind": "meeting",
		"seed": 500,
		"briefing": "Both sides want the mill ground and neither holds it yet. Their lead column reaches the silo in the second minute — win the race, then survive owning the prize.",
	},
	{
		"name": "Kachyne",
		"kind": "meeting",
		"seed": 17,
		"briefing": "Duck-pond country, three crossroads, and enemy columns arriving all battle long. Hold the majority of the positions when time runs out against a force twice your size.",
	},
]
