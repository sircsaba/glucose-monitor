#!/usr/bin/env python3
"""Builds assets/cnf.json from the Canadian Nutrient File (Health Canada, 2015,
Open Government Licence - Canada): every food with its English and French name,
the nutrients a nutrition label needs (per 100 g) and its household measures in
grams. Used to work out the nutrition of recipes on the phone, without AI.

  python3 scripts/build_cnf.py <folder with the CNF CSV files> assets/cnf.json
"""
import csv
import io
import json
import sys

src, out = sys.argv[1], sys.argv[2]


def rows(name):
    with open(f'{src}/{name}', encoding='latin-1', newline='') as f:
        return list(csv.DictReader(io.StringIO(f.read())))


# Nutrients by tag name (stable across releases), in the order kept per food.
TAGS = ['ENERC_KCAL', 'CHOCDF', 'PROCNT', 'FAT', 'FIBTG', 'SUGAR', 'NA', 'FASAT', 'FATRN', 'CHOLE', 'K', 'CA', 'FE']
KEYS = ['energy', 'carbs', 'protein', 'fat', 'fiber', 'sugars', 'sodium', 'satFat', 'transFat', 'cholesterol', 'potassium', 'calcium', 'iron']

tag_of = {}
for r in rows('NUTRIENT NAME.csv'):
    t = (r.get('Tagname') or '').strip()
    if t in TAGS:
        tag_of[r['NutrientID'].strip()] = TAGS.index(t)
missing = [t for t in TAGS if t not in {TAGS[i] for i in tag_of.values()}]
if missing:
    print('warning: nutrients not found:', missing)

groups = {r['FoodGroupID'].strip(): (r['FoodGroupName'].strip(), r['FoodGroupNameF'].strip().replace('\n', ' ')) for r in rows('FOOD GROUP.csv')}

foods = {}
for r in rows('FOOD NAME.csv'):
    fid = r['FoodID'].strip()
    foods[fid] = {
        'en': r['FoodDescription'].strip(),
        'fr': r['FoodDescriptionF'].strip(),
        'g': int(r['FoodGroupID'].strip() or 0),
        'n': [None] * len(TAGS),
        'm': [],
    }

for r in rows('NUTRIENT AMOUNT.csv'):
    i = tag_of.get(r['NutrientID'].strip())
    f = foods.get(r['FoodID'].strip())
    if i is None or f is None:
        continue
    try:
        f['n'][i] = round(float(r['NutrientValue']), 3)
    except ValueError:
        pass

measures = {}
mlist = []
for r in rows('MEASURE NAME.csv'):
    measures[r['MeasureID'].strip()] = len(mlist)
    mlist.append([r['MeasureDescription'].strip(), (r.get('MeasureDescriptionF') or '').strip()])

for r in rows('CONVERSION FACTOR.csv'):
    f = foods.get(r['FoodID'].strip())
    mi = measures.get(r['MeasureID'].strip())
    if f is None or mi is None:
        continue
    try:
        grams = round(float(r['ConversionFactorValue']) * 100, 1)  # factor x 100 g
    except ValueError:
        continue
    if grams > 0:
        f['m'].append([mi, grams])

used = sorted({m for f in foods.values() for m, _ in f['m']})
remap = {m: i for i, m in enumerate(used)}
data = {
    'source': 'Canadian Nutrient File 2015, Health Canada. Open Government Licence - Canada.',
    'keys': KEYS,
    'groups': {k: list(v) for k, v in groups.items()},
    'measures': [mlist[m] for m in used],
    # [id, English, French, group, [nutrients per 100 g], [[measure, grams], ...]]
    'foods': [[int(fid), f['en'], f['fr'], f['g'], f['n'], [[remap[m], g] for m, g in f['m']]]
              for fid, f in sorted(foods.items(), key=lambda x: int(x[0])) if f['n'][1] is not None],
}
with open(out, 'w', encoding='utf-8') as fo:
    json.dump(data, fo, ensure_ascii=False, separators=(',', ':'))
print(f"{len(data['foods'])} foods, {len(data['measures'])} measures ->", out)
