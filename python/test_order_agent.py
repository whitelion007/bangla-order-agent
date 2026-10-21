"""Run: python -m unittest -v  (from the python/ folder). Standard library only."""
import json
import tempfile
import unittest
from pathlib import Path

import order_agent as oa

ROOT = Path(__file__).resolve().parent.parent
CATALOG = oa.load_catalog(ROOT / "catalog.json")


class RulesEngine(unittest.TestCase):
    def test_bangla_digits_qty_size(self):
        o = oa.extract_rules("কালো পাঞ্জাবি ২টা চাই, সাইজ L। নাম: রাকিব, ঠিকানা: মিরপুর ১০, ঢাকা। ফোন ০১৭০০-০০০০০১", CATALOG)
        self.assertEqual(o.phone, "01700000001")
        self.assertEqual((o.items[0].qty, o.items[0].size), (2, "L"))

    def test_phone_formats(self):
        for text in ("phone: +880 1900 000112", "phone 01900-000-112", "8801900000112"):
            self.assertEqual(oa.extract_rules(text, CATALOG).phone, "01900000112", text)

    def test_number_words(self):
        self.assertEqual(oa.extract_rules("শাড়ি তিনটা লাগবে", CATALOG).items[0].qty, 3)
        self.assertEqual(oa.extract_rules("panjabi duita lagbe", CATALOG).items[0].qty, 2)

    def test_totals_and_status(self):
        r = oa.complete_order(oa.extract_rules("পাঞ্জাবি ২টা। নাম: রাকিব, ঠিকানা: মিরপুর, ঢাকা। ফোন 01700000001", CATALOG), CATALOG)
        self.assertEqual((r["status"], r["total"]), ("ready", 2970))
        r2 = oa.complete_order(oa.extract_rules("দুইটা টি-শার্ট দেন। ঠিকানা: খুলনা", CATALOG), CATALOG)
        self.assertEqual((r2["missing"], r2["delivery"]), (["customer_name", "phone"], 130))

    def test_inquiry_has_no_total(self):
        self.assertEqual(oa.complete_order(oa.extract_rules("পাঞ্জাবির দাম কত?", CATALOG), CATALOG)["total"], 0)


class Pipeline(unittest.TestCase):
    def test_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = oa.run_pipeline(ROOT / "samples" / "messages.jsonl", ROOT / "catalog.json", tmp, engine="rules")
            second = oa.run_pipeline(ROOT / "samples" / "messages.jsonl", ROOT / "catalog.json", tmp, engine="rules")
            self.assertEqual((len(first), len(second)), (7, 0))


class Accuracy(unittest.TestCase):
    """Labelled set from tests/worker-bot-cases.jsonl. The rules were tuned on it, so this guards regressions."""

    def test_field_accuracy(self):
        cases = [json.loads(l) for l in (ROOT / "tests" / "worker-bot-cases.jsonl").read_text(encoding="utf-8").splitlines() if l.strip()]
        norm = lambda v: oa.normalize(v or "").strip()
        scores = {k: 0 for k in ("intent", "customer_name", "phone", "address", "products")}
        for c in cases:
            e, g = c["expected"], oa.extract_rules(c["text"], CATALOG)
            scores["intent"] += e["intent"] == g.intent
            scores["customer_name"] += norm(e["customer_name"]) == norm(g.customer_name)
            scores["phone"] += (e["phone"] or "") == (g.phone or "")
            scores["address"] += norm(e["address"]) == norm(g.address)
            scores["products"] += sorted({i["product_id"] for i in e["items"]}) == sorted({i.product_id for i in g.items})
        print("\n  " + "  ".join(f"{k}={v}/{len(cases)}" for k, v in scores.items()))
        for k, v in scores.items():
            self.assertGreaterEqual(v, 28, k)


if __name__ == "__main__":
    unittest.main()
