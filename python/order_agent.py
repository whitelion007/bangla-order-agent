"""Bangla F-commerce Order Agent (Python edition).

Turns Bangla / Banglish / English customer messages into structured orders, prices them from
catalog.json and drafts a Bangla reply. Two engines:

* rules  - offline, no dependencies beyond the standard library
* claude - Anthropic Messages API with structured output (pip install anthropic); falls back to rules

Usage:
    python order_agent.py --input ../samples/messages.jsonl --out ../out
    python order_agent.py --engine claude ...   # needs ANTHROPIC_API_KEY
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
BN_NUMBER_WORDS = {"এক": 1, "দুই": 2, "তিন": 3, "চার": 4, "পাঁচ": 5}
LATIN_NUMBER_WORDS = {"ekta": 1, "ekti": 1, "one": 1, "duita": 2, "duto": 2, "two": 2, "tinta": 3,
                      "three": 3, "charta": 4, "four": 4, "pachta": 5, "five": 5}
UNITS = r"(?:টা|টি|পিস|pcs|pc|pieces|piece|ta|ti)"
SIZES = r"XXL|XL|L|M|S"
WORD = r"[^\s\d]+"          # Python's re has no \p{L}; a "word" here is any run without spaces or digits
BANGLA = r"ঀ-৿"
FIELD_NAMES_BN = {"customer_name": "নাম", "phone": "ফোন নম্বর", "address": "ঠিকানা", "items": "কোন পণ্য কয়টা"}
CONTACT_LABEL = re.compile(r"নাম\s*[:：]|nam\s*[:：]|name\s*[:：]|ফোন|phone|ঠিকানা|address", re.I)
STOP = r"[।\n]|ফোন|phone|mobile|নাম\s*[:：]|nam\s*[:：]|name\s*[:：]|ঠিকানা\s*[:：]|address\s*[:：]"


@dataclass
class Item:
    product_id: str
    qty: int | None = 1
    size: str | None = None


@dataclass
class Order:
    intent: str = "other"
    customer_name: str | None = None
    phone: str | None = None
    address: str | None = None
    items: list[Item] = field(default_factory=list)


def normalize(text: str) -> str:
    """Unify nukta forms, Bangla digits and number words so one set of patterns works."""
    if not text:
        return ""
    t = unicodedata.normalize("NFC", text)
    t = t.replace("ড়", "ড়").replace("ঢ়", "ঢ়").replace("য়", "য়")
    t = t.translate(BN_DIGITS)
    for word, n in BN_NUMBER_WORDS.items():
        t = re.sub(rf"(?<![{BANGLA}]){word}(টা|টি)?(?![{BANGLA}])", lambda m, n=n: f"{n}{m.group(1) or 'টা'}", t)
    for word, n in LATIN_NUMBER_WORDS.items():
        t = re.sub(rf"(?i)\b{word}\b", f"{n}ta", t)
    return t


def load_catalog(path: str | Path) -> dict:
    catalog = json.loads(Path(path).read_text(encoding="utf-8"))
    for p in catalog["products"]:
        p["aliases"] = [normalize(a) for a in p["aliases"]]
    return catalog


def find_phone(text: str) -> str | None:
    """01XXXXXXXXX, +880/880 prefixes and digits split by spaces or dashes."""
    for m in re.finditer(r"(?<!\d)(?:\+?880)?[\s-]*0?1(?:[\s-]?\d){9}(?!\d)", text):
        digits = re.sub(r"\D", "", m.group())
        if len(digits) < 10:
            continue
        local = "0" + digits[-10:]
        if re.fullmatch(r"01[3-9]\d{8}", local):
            return local
    return None


def labeled_value(text: str, labels: list[str], stop: str) -> str | None:
    label = "|".join(re.escape(x) for x in labels)
    m = re.search(rf"(?i)(?:{label})\s*[:：]\s*(.+?)(?=\s*(?:{stop})|$)", text)
    if not m:
        return None
    value = m.group(1).strip(" ,.।")
    return value or None


def find_size(segment: str, labelled_only: bool = False) -> str | None:
    patterns = [rf"(?i)(?:সাইজ|size)\s*[:：]?\s*({SIZES})(?![A-Za-z])",
                rf"(?i)(?<![A-Za-z])({SIZES})\s*(?:সাইজ|size)",
                rf"\(\s*({SIZES})\s*\)"]
    if not labelled_only:
        patterns.append(rf"(?<![A-Za-z])({SIZES})(?![A-Za-z])")
    for p in patterns:
        m = re.search(p, segment)
        if m:
            return m.group(1).upper()
    return None


def find_items(text: str, catalog: dict) -> list[Item]:
    found = []
    for p in catalog["products"]:
        for alias in p["aliases"]:
            m = re.search(re.escape(alias), text, re.I)
            if m:
                found.append((m.start(), p["id"], alias))
                break
    found.sort()
    label = CONTACT_LABEL.search(text)
    items = []
    for i, (pos, pid, alias) in enumerate(found):
        a = re.escape(alias)
        end = found[i + 1][0] if i + 1 < len(found) else len(text)
        if label and pos < label.start() < end:
            end = label.start()
        segment = text[pos:end]
        qty = 1
        before = re.search(rf"(?i)(\d{{1,3}})\s*{UNITS}\s+(?:{WORD}\s+){{0,2}}?{a}", text)
        after = re.match(rf"(?i){a}\S*\s*(?:{WORD}\s*)?(\d{{1,3}})\s*{UNITS}(?![^\W\d_])", segment)
        bare = re.search(rf"(?i)(?<![\d-])(\d{{1,2}})\s+{a}", text)
        if before and before.start() >= pos - 40:
            qty = int(before.group(1))
        elif after:
            qty = int(after.group(1))
        elif bare:
            qty = int(bare.group(1))
        items.append(Item(pid, qty, find_size(segment)))
    if len(items) == 1 and not items[0].size:
        items[0].size = find_size(text, labelled_only=True)
    return items


def extract_rules(text: str, catalog: dict) -> Order:
    t = normalize(text)
    phone = find_phone(t)
    name = labeled_value(t, ["নাম", "name", "nam"], STOP + "|,")
    address = labeled_value(t, ["ঠিকানা", "address"], STOP)
    items = find_items(t, catalog)
    is_question = re.search(r"(?i)\?|দাম|কত|price|koto|how much|available|ache|আছে", t) is not None
    intent = "order" if items else "other"
    if is_question and not phone and not address:
        intent = "inquiry"
    return Order(intent, name, phone, address, items)


def extract_claude(text: str, catalog: dict, model: str = "claude-opus-5-5") -> Order:
    """Structured-output extraction with the official SDK. Raises on any failure; the caller falls back."""
    from typing import Literal, Optional

    import anthropic
    from pydantic import BaseModel

    product_ids = tuple(p["id"] for p in catalog["products"])

    class ItemOut(BaseModel):
        product_id: Literal[product_ids]  # type: ignore[valid-type]
        qty: int
        size: Optional[Literal["S", "M", "L", "XL", "XXL"]]

    class OrderOut(BaseModel):
        intent: Literal["order", "inquiry", "other"]
        customer_name: Optional[str]
        phone: Optional[str]
        address: Optional[str]
        items: list[ItemOut]

    products = "\n".join(f"- {p['id']}: {p['name_bn']} (aliases: {', '.join(p['aliases'])})" for p in catalog["products"])
    system = (
        "You extract orders for a Bangladeshi Facebook shop from customer messages written in Bangla, Banglish or English.\n"
        f"Products:\n{products}\n"
        "Use null for any field the customer did not give. Write the phone as 11 ASCII digits starting with 01. "
        "Copy name and address as written. intent is 'inquiry' for price or availability questions without order "
        "details, 'order' when the customer wants to buy, otherwise 'other'. Never invent data."
    )
    client = anthropic.Anthropic(max_retries=3)  # SDK retries 408/409/429/5xx and connection errors with backoff
    response = client.messages.parse(
        model=model,
        max_tokens=4000,
        system=system,
        output_config={"effort": "low"},
        messages=[{"role": "user", "content": text}],
        output_format=OrderOut,
    )
    if response.stop_reason != "end_turn" or response.parsed_output is None:
        raise RuntimeError(f"Claude stopped with {response.stop_reason!r}")
    o = response.parsed_output
    return Order(o.intent, o.customer_name, o.phone, o.address, [Item(i.product_id, i.qty, i.size) for i in o.items])


def complete_order(order: Order, catalog: dict) -> dict:
    """Validate fields, price from the catalog (never from the model) and decide the status."""
    missing = []
    if order.intent == "order":
        missing = [f for f in ("customer_name", "phone", "address") if not getattr(order, f)]
        if not order.items:
            missing.append("items")
    if order.phone and not re.fullmatch(r"01[3-9]\d{8}", order.phone):
        missing.append("phone")
        order.phone = None
    prices = {p["id"]: p for p in catalog["products"]}
    subtotal, lines = 0, []
    for it in order.items:
        p = prices.get(it.product_id)
        if not p or not it.qty or it.qty < 1 or order.intent != "order":
            continue
        subtotal += p["price"] * it.qty
        lines.append(f"{p['name_bn']} x{it.qty}" + (f" ({it.size})" if it.size else ""))
    delivery = 0
    if subtotal and order.address:
        d = catalog["delivery"]
        inside = any(k.lower() in order.address.lower() for k in d["dhaka_keywords"])
        delivery = d["inside_dhaka"] if inside else d["outside_dhaka"]
    status = order.intent
    if order.intent == "order":
        status = "needs_info" if missing else "ready"
    return {"status": status, "customer_name": order.customer_name, "phone": order.phone, "address": order.address,
            "items": "; ".join(lines), "subtotal": subtotal, "delivery": delivery, "total": subtotal + delivery,
            "missing": list(dict.fromkeys(missing))}


def bangla_reply(result: dict, catalog: dict) -> str:
    if result["status"] == "ready":
        return (f"ধন্যবাদ {result['customer_name']}! আপনার অর্ডার: {result['items']}। পণ্যের দাম ৳{result['subtotal']} + "
                f"ডেলিভারি ৳{result['delivery']} = মোট ৳{result['total']} (ক্যাশ অন ডেলিভারি)। নিশ্চিত করতে 'হ্যাঁ' লিখুন।")
    if result["status"] == "needs_info":
        need = ", ".join(FIELD_NAMES_BN[f] for f in result["missing"])
        return f"ধন্যবাদ! অর্ডারটি নিশ্চিত করতে আপনার {need} পাঠাবেন কি?"
    if result["status"] == "inquiry":
        prices = ", ".join(f"{p['name_bn']} ৳{p['price']}" for p in catalog["products"])
        return f"জি, আমাদের দাম: {prices}। অর্ডার করতে নাম, ফোন নম্বর আর ঠিকানা পাঠান।"
    return f"আসসালামু আলাইকুম! {catalog['shop_name']}-এ স্বাগতম। কোন পণ্যটি দেখতে চান জানালে সাহায্য করব।"


def run_pipeline(input_path: str, catalog_path: str, out_dir: str, engine: str = "auto",
                 model: str = "claude-opus-5-5", force: bool = False) -> list[dict]:
    """Process a JSONL inbox once: idempotent per message id, one JSON log line per message."""
    catalog = load_catalog(catalog_path)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    state_path, log_path, csv_path = out / "state.json", out / "run.log.jsonl", out / "orders.csv"
    done = set() if force or not state_path.exists() else set(json.loads(state_path.read_text(encoding="utf-8")))
    use_claude = engine == "claude" or (engine == "auto" and os.environ.get("ANTHROPIC_API_KEY"))
    rows = []
    for line in Path(input_path).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        msg = json.loads(line)
        if msg["id"] in done:
            continue
        used, note, order = "rules", "", None
        if use_claude:
            try:
                order, used = extract_claude(msg["text"], catalog, model), "claude"
            except Exception as e:  # any API, network or validation failure -> rules engine
                note = f"claude failed, used rules: {type(e).__name__}: {e}"
        if order is None:
            order = extract_rules(msg["text"], catalog)
        result = complete_order(order, catalog)
        rows.append({"message_id": msg["id"], **{k: v for k, v in result.items() if k != "missing"},
                     "missing": ",".join(result["missing"]), "engine": used, "reply_bn": bangla_reply(result, catalog)})
        done.add(msg["id"])
        with log_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps({"at": datetime.now().isoformat(), "id": msg["id"], "status": result["status"],
                                "engine": used, "note": note}, ensure_ascii=False) + "\n")
    if rows:
        new_file = not csv_path.exists()
        with csv_path.open("a", encoding="utf-8-sig" if new_file else "utf-8", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0]))
            if new_file:
                writer.writeheader()
            writer.writerows(rows)
    state_path.write_text(json.dumps(sorted(done)), encoding="utf-8")
    return rows


def main() -> None:
    here = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", default=str(here / "samples" / "messages.jsonl"))
    ap.add_argument("--catalog", default=str(here / "catalog.json"))
    ap.add_argument("--out", default=str(here / "out"))
    ap.add_argument("--engine", choices=["auto", "rules", "claude"], default="rules")
    ap.add_argument("--model", default="claude-opus-5-5")
    ap.add_argument("--force", action="store_true", help="reprocess messages already handled")
    args = ap.parse_args()
    for r in run_pipeline(args.input, args.catalog, args.out, args.engine, args.model, args.force):
        print(f"[{r['message_id']}] {r['status']:<10} {r['items'] or '-':<30} ৳{r['total']:<6} {r['reply_bn']}")


if __name__ == "__main__":
    main()
