#!/usr/bin/env python3
"""Score the same detection vectors in the before/after probe reports and
print a comparison table (used to append the re-measurement section to
FINDINGS.md)."""
import json
import sys

RES = '/tmp/kestrel-research/results'
before = json.load(open(f'{RES}/probe_report.json'))
after = json.load(open(f'{RES}/probe_report_after.json'))


def props(d):
    return d['props']['interesting'], d['props']['emu_signatures']


def score(d):
    """Return dict vector -> (leak: bool, detail). Mirrors FINDINGS.md numbering."""
    s = {}
    b = d['build']
    interesting, emu_sigs = props(d)
    gles = d['gles']
    files = d['files']
    sensors = d['sensors']
    batt = d['battery']

    s['1 model/product'] = (b['MODEL'].lower().startswith('sdk') or 'emulator' in b['MODEL'].lower(), b['MODEL'])
    s['2 device'] = (b['DEVICE'] in ('emu64a', 'generic', 'sdk_gphone64_arm64'), b['DEVICE'])
    s['3 hardware'] = (b['HARDWARE'] in ('ranchu', 'goldfish', 'qemu'), b['HARDWARE'])
    s['4 board'] = ('goldfish' in b['BOARD'] or 'ranchu' in b['BOARD'], b['BOARD'])
    s['5 fingerprint'] = ('sdk_gphone' in b['FINGERPRINT'] or 'generic/' in b['FINGERPRINT'] or 'emu' in b['FINGERPRINT'].split('/')[1] if '/' in b['FINGERPRINT'] else False, b['FINGERPRINT'][:80])
    s['8 ro.kernel.qemu'] = (interesting.get('ro.kernel.qemu', '0') == '1', interesting.get('ro.kernel.qemu', 'absent'))
    s['9 qemu boot props'] = (len(emu_sigs) > 0, f'{len(emu_sigs)} emu-signature props')
    s['10 ro.hardware prop'] = (interesting.get('ro.hardware', '') in ('ranchu', 'goldfish', 'qemu'), interesting.get('ro.hardware', 'absent'))
    s['11 characteristics'] = (interesting.get('ro.build.characteristics', '') == 'emulator', interesting.get('ro.build.characteristics', 'absent'))
    s['12 build flavor'] = ('gphone' in interesting.get('ro.build.flavor', '') or 'emulator' in interesting.get('ro.build.flavor', ''), interesting.get('ro.build.flavor', 'absent')[:50])
    r = gles.get('renderer', '')
    s['15 gl renderer'] = (any(t in r.lower() for t in ('emulator', 'translator', 'swiftshader', 'goldfish')), r[:70])
    v = gles.get('vendor', '')
    s['14 gl vendor'] = (any(t in v.lower() for t in ('google', 'emulator', 'translator')), v)
    s['17 goldfish_battery'] = (files.get('/sys/module/goldfish_battery', False), 'present' if files.get('/sys/module/goldfish_battery') else 'absent')
    names = ' '.join(sensors.get('list', []))
    s['20 sensor names'] = ('Goldfish' in names, f"{sensors.get('count', 0)} sensors, goldfish-named={'Goldfish' in names}")
    s['21 battery constants'] = (batt.get('temperature_deci_c') == 250 and batt.get('status') == 'full', f"status={batt.get('status')} temp={batt.get('temperature_deci_c')}")
    return s


sb, sa = score(before), score(after)
print(f"{'vector':<26} {'BEFORE':<8} {'AFTER':<8} detail(after)")
closed = 0
for k in sb:
    lb, _ = sb[k]
    la, da = sa[k]
    if lb and not la:
        closed += 1
    print(f"{k:<26} {'LEAK' if lb else 'clean':<8} {'LEAK' if la else 'clean':<8} {da}")
lb_total = sum(1 for k in sb if sb[k][0])
la_total = sum(1 for k in sa if sa[k][0])
print(f"\nleak count: {lb_total} -> {la_total} (closed {closed} of {len(sb)} tracked vectors)")
