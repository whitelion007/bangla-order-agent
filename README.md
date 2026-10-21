# Bangla F-commerce Order Agent

Turns messy Facebook-shop messages in **Bangla, Banglish and English** into clean orders, prices them from your catalog, and drafts a Bangla reply. It runs offline on any Windows PC, and can optionally use Claude for harder messages.

```
"৩টা টি-শার্ট আর ১টা পাঞ্জাবি। নাম: সাকিব, ফোন: +8801900000003, ঠিকানা: উত্তরা সেক্টর ৭, ঢাকা"
        ↓
status=ready | সাকিব | 01900000003 | টি-শার্ট x3; পাঞ্জাবি x1 | ৳2800 + ৳70 delivery = ৳2870
reply: "ধন্যবাদ সাকিব! আপনার অর্ডার: … মোট ৳2870 (ক্যাশ অন ডেলিভারি)। নিশ্চিত করতে 'হ্যাঁ' লিখুন।"
```

## What it handles

- **Mixed scripts:** Bangla, Banglish ("panjabi duita lagbe") and English.
- **Numbers in any form:** Bangla digits (০১৭…) and number words (দুইটা, tinta, ekta).
- **Messy phone numbers:** phones written as `01700-000001`, `+880 1900 000112`, `017-0000-0110` or `8801700000116`, normalised to `01XXXXXXXXX`.
- **Multi-item orders:** sizes are tracked per item ("সাইজ L", "XL size", "(M)").
- **Intent:** sorts each message into **order**, **inquiry** ("দাম কত?") or **other**. Inquiries get a price list; incomplete orders get a reply asking only for what is missing.
- **Delivery:** charge set by area (inside or outside Dhaka) from `catalog.json`.
- **Safe re-runs:** idempotent processing keyed on message id. Each run adds a JSON-lines log and appends to `orders.csv` (UTF-8, opens in Excel with Bangla intact).
- **Pricing is never taken from the AI:** totals always come from the catalog.

## Run it

```powershell
.\run-demo.ps1                 # offline rules engine, no key needed
.\tests\Run-Tests.ps1          # 13 unit checks + accuracy report on 30 labelled messages
```

Optional Claude mode, for free-form messages the rules can't parse:

```powershell
$env:ANTHROPIC_API_KEY = '<your key>'
.\run-demo.ps1 -Engine Claude      # or -Engine Auto: Claude when a key is set, rules otherwise
```

How Claude mode works:

- It calls the Anthropic Messages API with a JSON-schema structured output.
- Network, 429 and 5xx errors are retried with backoff (honouring `retry-after`).
- If the call still fails, that message falls back to the rules engine and the log says why.

## Python edition

`python/order_agent.py` is the same agent in Python 3.10+. It gives the same results on the sample inbox. The Claude engine uses the official `anthropic` SDK (`messages.parse` with a Pydantic model; the SDK's built-in retries).

```bash
cd python
python order_agent.py --force                 # rules engine, standard library only
python -m unittest -v                         # 7 tests incl. accuracy on the labelled set
pip install -r requirements.txt               # only for --engine claude (needs ANTHROPIC_API_KEY)
python order_agent.py --engine claude --force
```

## Results (rules engine, `tests\worker-bot-cases.jsonl`)

| Field | Correct |
|---|---|
| intent, name, phone, address, products | 30 / 30 each |
| quantity, size | 29 / 30 each |

The one miss, w21 (`"tshirt tinta, M M L"`), splits one product across sizes. That is the kind of message Claude mode is for.

The rules were tuned on this same set, so expect lower accuracy on new messages. Add real (anonymised) messages to the test file before relying on the numbers.

## Files

| File | Purpose |
|---|---|
| `OrderAgent.psm1` | Extraction (rules + Claude), validation, pricing, reply drafting, pipeline |
| `catalog.json` | Products, aliases, prices, delivery zones |
| `samples/messages.jsonl` | Demo inbox |
| `tests/Run-Tests.ps1`, `tests/worker-bot-cases.jsonl` | Unit checks and labelled evaluation set (all data fictional) |

## Extending for a real shop

1. Put the shop's products and aliases in `catalog.json`.
2. Feed messages in from a Facebook Page export, or from a webhook that writes JSONL.
3. Send `orders.csv` to Google Sheets, or to the courier booking sheet.
4. Keep a human approving replies until accuracy on real messages is known.

---
Built with Windows PowerShell 5.1. No external modules.
