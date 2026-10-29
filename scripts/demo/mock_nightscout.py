#!/usr/bin/env python3
"""A pretend Nightscout site with invented data, for screenshots and demos.

    python3 scripts/demo/mock_nightscout.py [port]     (default 8099)

Serves the Nightscout API the app reads: glucose for the last 26 hours (a
believable day with three meals), boluses, carbs, temp basals, a Loop status
with IOB / COB and a prediction, pump details and a therapy profile. Nothing
here is anyone's real data. Times are always relative to "now".
"""
import json
import math
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
MIN = 60 * 1000


def iso(ms):
    return datetime.fromtimestamp(ms / 1000, timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')


def local_hour(ms):
    return datetime.fromtimestamp(ms / 1000).hour + datetime.fromtimestamp(ms / 1000).minute / 60


# Fixed "now" when the server starts, so every screen shows the same day.
ANCHOR = int(time.time() * 1000)

# Meals as (hours before now, carbs g, bolus U): the last one 3.5 h ago, so
# the current reading is calm and in range whatever time this runs.
MEALS = [(3.5, 70, 6.8), (6.5, 15, 0.0), (9.5, 60, 6.0), (14.0, 45, 4.5),
         (27.5, 70, 6.8), (33.5, 60, 6.0), (38.0, 45, 4.5)]


def hours_ago(ms):
    return (ANCHOR - ms) / 3600000


def glucose_at(ms):
    """mg/dL at a moment: a calm night, meal bumps, a little wobble."""
    v = 114 + 5 * math.sin(ms / (97 * MIN)) + 3 * math.sin(ms / (23 * MIN))
    for ago, carbs, _ in MEALS:
        d = ago - hours_ago(ms)  # hours since that meal
        if 0 <= d < 4:
            v += carbs * 1.1 * (d / 0.8) * math.exp(1 - d / 0.8) * (0.8 if carbs < 30 else 1)
    a = hours_ago(ms)
    if 19.5 < a < 21.5:  # a gentle overnight dip
        v -= 22 * math.sin((a - 19.5) / 2 * math.pi)
    return max(55, min(260, v))


def direction(delta):
    if delta > 15: return 'DoubleUp'
    if delta > 8: return 'SingleUp'
    if delta > 3: return 'FortyFiveUp'
    if delta < -15: return 'DoubleDown'
    if delta < -8: return 'SingleDown'
    if delta < -3: return 'FortyFiveDown'
    return 'Flat'


def now_ms():
    return int(time.time() * 1000)


def entries(since_ms, count):
    n = max(ANCHOR, now_ms())
    last = n - 2 * MIN - (n % (5 * MIN))
    out = []
    t = last
    while t >= since_ms and len(out) < count:
        v = glucose_at(t)
        out.append({'_id': f'e{t}', 'type': 'sgv', 'sgv': round(v), 'date': t, 'dateString': iso(t),
                    'direction': direction(v - glucose_at(t - 5 * MIN)), 'device': 'demo-cgm'})
        t -= 5 * MIN
    return out


def treatments(since_ms):
    n = ANCHOR
    out = []
    day = 24 * 60 * MIN
    for ago, carbs, bolus in MEALS:
        t = n - int(ago * 60) * MIN
        if t < since_ms:
            continue
        out.append({'_id': f'c{t}', 'eventType': 'Carb Correction', 'carbs': carbs, 'created_at': iso(t), 'enteredBy': 'Loop'})
        if bolus:
            out.append({'_id': f'b{t}', 'eventType': 'Correction Bolus', 'insulin': bolus, 'created_at': iso(t + MIN), 'enteredBy': 'Loop'})
            for k in (1, 2):  # small automatic boluses after the meal
                ts = t + k * 25 * MIN
                out.append({'_id': f's{ts}', 'eventType': 'Correction Bolus', 'insulin': 0.35, 'automatic': True,
                            'created_at': iso(ts), 'enteredBy': 'Loop'})
    # temp basals every 30 min over the period
    t = since_ms - (since_ms % (30 * MIN))
    while t <= n:
        v = glucose_at(t)
        rate = 0.0 if v < 85 else (1.6 if v > 170 else (1.1 if v > 140 else 0.85))
        out.append({'_id': f't{t}', 'eventType': 'Temp Basal', 'absolute': rate, 'rate': rate, 'duration': 30,
                    'created_at': iso(t), 'enteredBy': 'Loop'})
        t += 30 * MIN
    # site, sensor and insulin changes for the "ages"
    for name, days_ago in (('Site Change', 1.6), ('Sensor Start', 6.2), ('Insulin Change', 1.6)):
        t = n - int(days_ago * day)
        out.append({'_id': f'x{name}', 'eventType': name, 'created_at': iso(t), 'enteredBy': 'Loop'})
    out.sort(key=lambda d: d['created_at'], reverse=True)
    return out


def devicestatus():
    n = now_ms()
    loop_t = n - 3 * MIN
    start = n - 2 * MIN - (n % (5 * MIN))
    v = glucose_at(start)
    pred = [round(v + (glucose_at(start + i * 5 * MIN) - v) * 0.6) for i in range(37)]
    return [{
        '_id': f'd{loop_t}', 'created_at': iso(loop_t), 'device': 'loop://iPhone',
        'loop': {'timestamp': iso(loop_t), 'name': 'Loop', 'version': '3.14.9',
                 'iob': {'iob': 1.42, 'timestamp': iso(loop_t)}, 'cob': {'cob': 18, 'timestamp': iso(loop_t)},
                 'predicted': {'startDate': iso(start), 'values': pred},
                 'enacted': {'rate': 0.95, 'duration': 30, 'timestamp': iso(loop_t), 'received': True},
                 'recommendedBolus': 0.0},
        'pump': {'clock': iso(loop_t), 'reservoir': 112.4, 'battery': {'percent': 76},
                 'reservoir_display_override': '', 'manufacturer': 'Insulet', 'model': 'Dash'},
        'uploader': {'battery': 81},
        'override': {'active': False, 'timestamp': iso(loop_t)},
    }]


def profile():
    t = now_ms() - 30 * 24 * 60 * MIN
    def sched(pairs):
        return [{'time': f'{h:02d}:00', 'timeAsSeconds': h * 3600, 'value': v} for h, v in pairs]
    return [{
        '_id': 'p1', 'defaultProfile': 'Default', 'startDate': iso(t), 'created_at': iso(t), 'units': 'mg/dl',
        'store': {'Default': {
            'dia': 6, 'units': 'mg/dl', 'timezone': 'America/Toronto',
            'basal': sched([(0, 0.75), (4, 0.9), (9, 0.85), (16, 0.95), (21, 0.8)]),
            'carbratio': sched([(0, 11), (11, 12), (17, 10)]),
            'sens': sched([(0, 55), (7, 50), (20, 55)]),
            'target_low': sched([(0, 100)]), 'target_high': sched([(0, 115)]),
        }},
        # What Loop uploads about itself: needed by the Plus remote screen.
        'loopSettings': {
            'deviceToken': 'demo-device-token', 'bundleIdentifier': 'com.example.loopkit.Loop',
            'dosingEnabled': True, 'maximumBolus': 6, 'maximumBasalRatePerHour': 3,
            'overridePresets': [
                {'name': 'Running', 'symbol': '🏃', 'duration': 3600, 'insulinNeedsScaleFactor': 0.6,
                 'targetRange': [140, 160]},
                {'name': 'Pre-meal', 'symbol': '🍽️', 'duration': 3600, 'insulinNeedsScaleFactor': 1.0,
                 'targetRange': [80, 90]},
                {'name': 'Sick day', 'symbol': '🤒', 'duration': 0, 'insulinNeedsScaleFactor': 1.2,
                 'targetRange': [110, 130]},
            ],
        },
    }]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', '*')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send({'ok': True})

    def do_POST(self):
        self._send([])

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        path = u.path.replace('.json', '')
        count = int((q.get('count') or ['10'])[0])
        since = None
        for k in ('find[date][$gte]', 'find[created_at][$gte]', 'find[dateString][$gte]'):
            if k in q:
                raw = q[k][0]
                since = int(raw) if raw.isdigit() else int(datetime.fromisoformat(raw.replace('Z', '+00:00')).timestamp() * 1000)
        if path in ('/api/v1/status', '/api/v1/verifyauth'):
            return self._send({'status': 'ok', 'name': 'nightscout', 'version': '15.0.0',
                               'settings': {'units': 'mmol', 'customTitle': 'Demo'},
                               'apiEnabled': True, 'careportalEnabled': True,
                               'message': {'canRead': True, 'canWrite': True, 'isAdmin': False, 'message': 'OK'}})
        if path in ('/api/v1/entries/sgv', '/api/v1/entries'):
            return self._send(entries(since or now_ms() - 60 * MIN, count))
        if path == '/api/v1/treatments':
            ev = (q.get('find[eventType]') or [None])[0]
            items = treatments(since or now_ms() - 24 * 60 * MIN)
            if ev:
                items = [t for t in items if t['eventType'] == ev]
            return self._send(items[:count])
        if path == '/api/v1/devicestatus':
            return self._send(devicestatus())
        if path in ('/api/v1/profile', '/api/v1/profiles'):
            return self._send(profile())
        if path == '/api/v1/food':
            return self._send(FOODS)
        return self._send({'status': 404, 'message': 'Not found'}, 404)


# Demo food list (made-up products, no real brands).
FOODS = [
    {'_id': 'f1', 'type': 'food', 'name': 'Scrambled eggs', 'category': 'Eggs', 'portion': 2, 'unit': 'piece',
     'carbs': 1.0, 'energy': 180, 'protein': 12, 'fat': 14, 'gluten': 'free', 'glutenWhy': ['Set by hand'],
     'meals': ['breakfast'], 'favorite': True, 'source': 'manual'},
    {'_id': 'f2', 'type': 'food', 'name': 'Bacon', 'category': 'Meat', 'portion': 30, 'unit': 'g', 'carbs': 0.4,
     'energy': 160, 'protein': 11, 'fat': 12, 'gluten': 'free', 'meals': ['breakfast', 'lunch', 'snack'], 'favorite': True,
     'source': 'barcode', 'barcode': '0000000000017', 'per100': {'carbs': 1.3, 'energy': 533, 'protein': 37, 'fat': 40}},
    {'_id': 'f3', 'type': 'food', 'name': 'Dragon fruit', 'category': 'Fruit', 'portion': 100, 'unit': 'g', 'carbs': 13,
     'energy': 60, 'fiber': 3, 'gluten': 'free', 'meals': ['breakfast', 'snack'], 'favorite': True, 'source': 'manual'},
    {'_id': 'f4', 'type': 'food', 'name': 'Corn tortilla chips', 'brand': 'Sample Foods', 'category': 'Snacks', 'portion': 28,
     'unit': 'g', 'portionText': '28 g (about 12 chips)', 'carbs': 18, 'energy': 140, 'fat': 7, 'gluten': 'free',
     'glutenWhy': ['Labelled gluten-free, no gluten ingredient listed'], 'ingredients': 'Corn, vegetable oil, salt',
     'meals': ['snack'], 'favorite': True, 'source': 'barcode', 'barcode': '0000000000024',
     'per100': {'carbs': 64, 'energy': 500, 'fat': 25}},
    {'_id': 'f5', 'type': 'food', 'name': 'Granola bar', 'brand': 'Sample Foods', 'category': 'Snacks', 'portion': 35,
     'unit': 'g', 'carbs': 24, 'energy': 150, 'gluten': 'unsure', 'glutenWhy': ['Contains oats without a gluten-free label'],
     'ingredients': 'Whole grain oats, honey, almonds', 'meals': ['snack'], 'favorite': False, 'source': 'barcode'},
    {'_id': 'f6', 'type': 'food', 'name': 'Wheat bread', 'category': 'Bread', 'portion': 1, 'unit': 'slice', 'carbs': 15,
     'energy': 80, 'gluten': 'contains', 'glutenWhy': ['Ingredients: wheat'], 'meals': ['breakfast', 'lunch'],
     'favorite': False, 'source': 'barcode'},
    {'_id': 'f7', 'type': 'food', 'name': 'Banana muffins', 'category': 'Baking', 'portion': 60, 'unit': 'g',
     'portionText': '1 muffin', 'carbs': 25, 'energy': 180, 'protein': 3, 'fat': 7, 'gluten': 'free',
     'glutenWhy': ['All ingredients are gluten-free'], 'meals': ['breakfast', 'snack'], 'favorite': True, 'source': 'recipe',
     'recipe': {'servings': 12, 'servingText': '1 muffin', 'cookMinutes': 20, 'prepMinutes': 15,
                'ingredients': [{'name': 'gluten-free flour blend', 'amount': '2 cups', 'carbs': 160, 'gluten': 'free'},
                                {'name': 'ripe bananas', 'amount': '3', 'carbs': 81, 'gluten': 'free'},
                                {'name': 'eggs', 'amount': '2', 'carbs': 1, 'gluten': 'free'},
                                {'name': 'maple syrup', 'amount': '1/3 cup', 'carbs': 54, 'gluten': 'free'}],
                'steps': ['Heat the oven to 180 °C and line a 12-cup muffin pan.', 'Mash the bananas, then whisk in the eggs and syrup.',
                          'Fold in the flour until just mixed.', 'Fill the cups and bake 20 minutes.']}},
    {'_id': 'f8', 'type': 'food', 'name': 'Rice, cooked', 'category': 'Grains', 'portion': 150, 'unit': 'g', 'carbs': 42,
     'energy': 195, 'gluten': 'free', 'meals': ['lunch', 'supper'], 'favorite': False, 'source': 'manual'},
]


if __name__ == '__main__':
    print(f'Demo Nightscout on http://127.0.0.1:{PORT}')
    ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
