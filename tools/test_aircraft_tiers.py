"""Offline regression checks for catalog coverage, classification and tier parity.
Run: python3 -m unittest discover -s tools -p 'test_aircraft_tiers.py'
"""
import json
import runpy
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GEN = runpy.run_path(str(ROOT / 'tools/generate-aircraft-types.py'))
CAT = json.loads((ROOT / 'ios/Tailspot/Tailspot/AircraftTypes.json').read_text())


class AircraftTierTests(unittest.TestCase):
    def test_all_override_targets_exist_and_match_projection(self):
        for code, tier in GEN['RARITY_OVERRIDES'].items():
            with self.subTest(code=code):
                self.assertIn(code, CAT)
                self.assertEqual(CAT[code]['rarity'], tier)
        for group in ['MIL', 'BIZ', 'REGIONAL']:
            self.assertFalse(GEN[group] - CAT.keys(), group)

    def test_prefix_boundaries_do_not_turn_light_aircraft_into_airliners(self):
        light = {'AircraftDescription': 'LandPlane', 'EngineType': 'Piston', 'WTC': 'L'}
        for code in 'A31 A33 A35 AT5P AT5T DH80 DH82 DH83 DH84 DH85 DH87 DH88 DH89 SF31 SF35 SF36'.split():
            with self.subTest(code=code):
                self.assertEqual(GEN['aircraft_type'](code, light), 'ga')
                self.assertEqual(CAT[code]['type'], 'ga')
        for code, category in [('DH8D', 'regional'), ('AT76', 'regional'), ('SF34', 'regional'), ('A333', 'wide'), ('A35K', 'wide'), ('A319', 'narrow')]:
            with self.subTest(code=code):
                self.assertEqual(GEN['aircraft_type'](code, {}), category)

    def test_regeneration_preserves_role_and_tier_exceptions(self):
        for code in GEN['MIL']:
            with self.subTest(code=code):
                self.assertEqual(GEN['aircraft_type'](code, {}), 'mil')
                self.assertEqual(CAT[code]['type'], 'mil')
                self.assertEqual(GEN['aircraft_rarity'](code, {}, 'mil'), CAT[code]['rarity'])
        # Military rotorcraft must win before the civil-rotorcraft fallback.
        self.assertEqual(GEN['aircraft_type']('UH1Y', {'AircraftDescription': 'Helicopter'}), 'mil')
        self.assertEqual(GEN['aircraft_type']('R44', {'AircraftDescription': 'Helicopter'}), 'ga')

    def test_approved_landmarks_and_working_aircraft(self):
        groups = {
            'legendary': 'A337 BLCF B74S VF35 B21 WB57 W135 SGUP SLCH X59 STAR PRTS R721',
            'epic': 'C46 DC6 DHC7 RJ70 E390',
            'rare': 'A306 P180 C408 FA7X',
            'uncommon': 'BE10 BE9L BE9T P46T M600 M700 C425 C441 AC90 AC95 WW24',
            'common': 'A320 B738 C172 PA46 A339 B734 C919',
        }
        for tier, codes in groups.items():
            for code in codes.split():
                with self.subTest(code=code):
                    self.assertEqual(CAT[code]['rarity'], tier)
        self.assertEqual(CAT['SGCD']['rarity'], 'legendary')
        self.assertEqual(CAT['F104']['rarity'], 'epic')
        self.assertEqual(CAT['B721']['rarity'], 'legendary')
        self.assertEqual(CAT['B722']['rarity'], 'epic')
        self.assertEqual(CAT['R722']['rarity'], 'epic')

    def test_catalog_shape_and_preserved_unknown_floor(self):
        # A floor, not an exact count: a DOC 8643 refresh may add or drop
        # designators legitimately; a near-empty catalog is the real failure.
        self.assertGreater(len(CAT), 2500)
        for code, entry in CAT.items():
            with self.subTest(code=code):
                self.assertIn(entry['rarity'], GEN['RARITY_POINTS'])
                self.assertIn(entry['type'], {'ga', 'biz', 'mil', 'narrow', 'wide', 'regional'})
        self.assertEqual(GEN['aircraft_rarity']('ZZZZ', {}, 'ga'), 'common')
        self.assertEqual(GEN['RARITY_POINTS'], {'common': 10, 'uncommon': 20, 'rare': 50, 'epic': 100, 'legendary': 500})

    def test_ga_presence_tier_rules(self):
        tier = GEN['ga_presence_tier']
        caught, fleet = GEN['CAUGHT_AIRFRAMES'], GEN['US_FLEET']
        # Everyday catches stay Common whatever the fleet says.
        for code in 'C172 P28A SR22 C182'.split():
            with self.subTest(code=code):
                self.assertGreater(caught[code], GEN['GA_COMMON_MIN_CAUGHT'])
                self.assertEqual(tier(code), 'common')
        # Thinly caught classics are a find, even with a big US fleet.
        for code in 'PA24 C180 PA30 BE55 DHC2'.split():
            with self.subTest(code=code):
                self.assertLessEqual(caught[code], GEN['GA_COMMON_MIN_CAUGHT'])
                self.assertEqual(tier(code), 'uncommon')
        # Never caught: tiered by US fleet; no evidence at all stays Common.
        never = [c for c in CAT if c not in caught and CAT[c]['type'] == 'ga']
        by_fleet = {f: next(c for c in never if lo <= fleet.get(c, 0) < hi)
                    for f, lo, hi in [('epic', 1, 10), ('rare', 10, 100), ('uncommon', 100, 1000)]}
        for expected, code in by_fleet.items():
            with self.subTest(code=code):
                self.assertEqual(tier(code), expected)
        self.assertEqual(tier('ZZZZ'), 'common')

    def test_uncurated_ga_rows_match_presence_tier(self):
        # Projection parity: every uncurated fixed-wing GA row carries the
        # evidence tier. Helicopters keep their own 'uncommon' default.
        for code, entry in CAT.items():
            if entry['type'] != 'ga' or code in GEN['RARITY_OVERRIDES']:
                continue
            with self.subTest(code=code):
                self.assertIn(entry['rarity'], {GEN['ga_presence_tier'](code), 'uncommon'})


if __name__ == '__main__':
    unittest.main()
