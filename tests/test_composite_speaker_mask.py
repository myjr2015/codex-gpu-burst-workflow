import importlib.util
import unittest
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "scripts" / "composite_speaker_on_background.py"


def load_module():
    spec = importlib.util.spec_from_file_location("composite_speaker_on_background", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CompositeSpeakerMaskTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()
        cls.speaker = cls.make_synthetic_speaker()
        cls.mask = cls.module.build_speaker_mask(cls.speaker)
        cls.mask_arr = np.array(cls.mask)
        ys, xs = np.where(cls.mask_arr > 128)
        cls.bbox = (xs.min(), ys.min(), xs.max(), ys.max())

    @staticmethod
    def make_synthetic_speaker():
        image = Image.new("RGBA", (640, 960), (255, 255, 255, 255))
        pixels = image.load()
        for y in range(120, 900):
            for x in range(185, 455):
                cx = (x - 320) / 135
                cy = (y - 500) / 390
                if cx * cx + cy * cy < 1.0:
                    pixels[x, y] = (82, 55, 135, 255)
        for y in range(80, 235):
            for x in range(250, 390):
                cx = (x - 320) / 70
                cy = (y - 158) / 78
                if cx * cx + cy * cy < 1.0:
                    pixels[x, y] = (229, 178, 144, 255)
        for y in range(775, 940):
            for x in range(220, 420):
                if 0 <= (x - 220) < 80 or 120 <= (x - 220) < 200:
                    pixels[x, y] = (45, 42, 48, 255)
        return image

    def coverage(self, rel_box):
        x1, y1, x2, y2 = self.bbox
        rx1, ry1, rx2, ry2 = rel_box
        ax1 = int(x1 + (x2 - x1) * rx1)
        ax2 = int(x1 + (x2 - x1) * rx2)
        ay1 = int(y1 + (y2 - y1) * ry1)
        ay2 = int(y1 + (y2 - y1) * ry2)
        roi = self.mask_arr[ay1:ay2, ax1:ax2]
        return float((roi > 128).mean())

    def test_background_corner_stays_empty(self):
        roi = self.mask_arr[:120, :120]
        self.assertLess(float((roi > 128).mean()), 0.01)

    def test_dress_center_is_preserved(self):
        self.assertGreater(self.coverage((0.31, 0.22, 0.62, 0.62)), 0.98)

    def test_left_cardigan_is_not_hollowed_out(self):
        self.assertGreater(self.coverage((0.08, 0.40, 0.20, 0.82)), 0.90)

    def test_right_cardigan_is_not_hollowed_out(self):
        self.assertGreater(self.coverage((0.72, 0.34, 0.96, 0.82)), 0.90)

    def test_shoes_are_not_removed(self):
        self.assertGreater(self.coverage((0.35, 0.84, 0.67, 0.99)), 0.55)


if __name__ == "__main__":
    unittest.main()
