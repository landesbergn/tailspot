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
        self.assertEqual(len(CAT), 2613)
        for code, entry in CAT.items():
            with self.subTest(code=code):
                self.assertIn(entry['rarity'], GEN['RARITY_POINTS'])
                self.assertIn(entry['type'], {'ga', 'biz', 'mil', 'narrow', 'wide', 'regional'})
        self.assertEqual(GEN['aircraft_rarity']('ZZZZ', {}, 'ga'), 'common')
        self.assertEqual(GEN['RARITY_POINTS'], {'common': 10, 'uncommon': 20, 'rare': 50, 'epic': 100, 'legendary': 500})


if __name__ == '__main__':
    unittest.main()
