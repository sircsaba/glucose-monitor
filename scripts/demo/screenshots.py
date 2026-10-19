#!/usr/bin/env python3
"""Store / website screenshots of the web build, with the demo data.

    python3 scripts/demo/screenshots.py OUT_DIR APP_URL PLUS_URL NS_URL

APP_URL serves build/web (Monitor Glucose), PLUS_URL a build with
--dart-define=PLUS=true, NS_URL the demo server (mock_nightscout.py).
Writes PNGs for iPhone (1290x2796), Android (1080x2160) and web (2880x1800),
and labels-*.txt with the accessibility labels seen on each screen, to help
when a tap needs adjusting.
"""
import asyncio
import json
import os
import sys

from playwright.async_api import async_playwright

OUT, APP, PLUS, NS = sys.argv[1:5]

SETTINGS = {
    'v': {
        'nsUrl': NS,
        'nsToken': 'demo-token',
        'apiSecret': False,
        'mmol': True,
        'patientName': '',
        'time24': True,
        'quietOn': False,
    }
}

DEVICES = {
    'iphone': dict(viewport={'width': 430, 'height': 932}, device_scale_factor=3, is_mobile=True, has_touch=True),
    'android': dict(viewport={'width': 360, 'height': 720}, device_scale_factor=3, is_mobile=True, has_touch=True),
    'web': dict(viewport={'width': 1440, 'height': 900}, device_scale_factor=2),
}


async def labels(page):
    return await page.evaluate("""() => [...document.querySelectorAll('flt-semantics, [role]')]
        .map(e => (e.getAttribute('aria-label') || e.textContent || '').trim())
        .filter(t => t && t.length < 120)""")


async def open_app(ctx, url):
    page = await ctx.new_page()
    await page.goto(url, wait_until='load')
    await page.wait_for_selector('flt-semantics-placeholder, flutter-view', state='attached', timeout=60000)
    await page.wait_for_timeout(2500)
    # Turn on Flutter's accessibility tree, so screens can be opened by name.
    await page.evaluate("""() => { const p = document.querySelector('flt-semantics-placeholder');
        if (p) p.click(); }""")
    await page.wait_for_timeout(5000)  # data loaded, graph drawn
    return page


async def tap(page, name):
    """Tap the first element whose accessible name contains [name]."""
    found = await page.evaluate("""(name) => {
        const all = [...document.querySelectorAll('flt-semantics, [role]')];
        const hit = all.find(e => ((e.getAttribute('aria-label') || '') + ' ' + (e.textContent || '')).includes(name)
                                  && e.getBoundingClientRect().width > 0);
        if (!hit) return null;
        const r = hit.getBoundingClientRect();
        return [r.x + r.width / 2, r.y + r.height / 2];
    }""", name)
    if not found:
        print(f'  ! not found: {name}')
        return False
    await page.mouse.click(found[0], found[1])
    await page.wait_for_timeout(2500)
    return True


async def shot(page, dev, name):
    os.makedirs(f'{OUT}/{dev}', exist_ok=True)
    await page.screenshot(path=f'{OUT}/{dev}/{name}.png')
    with open(f'{OUT}/labels-{dev}-{name}.txt', 'w') as f:
        f.write('\n'.join(dict.fromkeys(await labels(page))))
    print(f'  {dev}/{name}.png')


# (name, url, steps): each step is a label to tap, in order.
PHONE_GM = [
    ('1-live', 'app', []),
    ('2-night', 'app', ['Night view']),
    ('3-reports', 'app', ['Reports']),
    ('4-alarms', 'app', ['Alarms']),
    ('5-zones', 'app', ['Settings', 'BG zones']),
    ('6-settings', 'app', ['Settings']),
]
PHONE_PLUS = [
    ('1-live', 'plus', []),
    ('2-treat', 'plus', ['Treat']),
    ('3-remote', 'plus', ['Treat', 'Remote control']),
    ('4-night', 'plus', ['Night view']),
]
WEB = [
    ('1-live', 'app', []),
    ('2-reports', 'app', ['Reports']),
    ('3-treat', 'app', ['Treat']),
    ('4-night', 'app', ['Night view']),
]


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        jobs = [('iphone', 'gm', PHONE_GM), ('android', 'gm', PHONE_GM),
                ('iphone', 'plus', PHONE_PLUS), ('android', 'plus', PHONE_PLUS), ('web', 'web', WEB)]
        for dev, group, shots in jobs:
            for name, which, steps in shots:
                ctx = await browser.new_context(timezone_id='America/Toronto', locale='en-CA', **DEVICES[dev])
                # shared_preferences on the web keeps each value JSON-encoded in
                # localStorage under "flutter.<key>"; the settings are one JSON string.
                stored = json.dumps(json.dumps(SETTINGS))
                await ctx.add_init_script(
                    "try { localStorage.setItem('flutter.settings', " + json.dumps(stored) + "); } catch (e) {}")
                page = await open_app(ctx, APP if which == 'app' else PLUS)
                for s in steps:
                    await tap(page, s)
                await shot(page, f'{group}-{dev}' if group != 'web' else 'web', name)
                await ctx.close()
        await browser.close()


asyncio.run(main())
