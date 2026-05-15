"""
Paperless-NGX seed script — run via:
kubectl exec -n media deployment/paperless -i -- python /usr/src/paperless/src/manage.py shell < seed.py
"""
from documents.models import Tag, DocumentType, Correspondent

DOCUMENT_TYPES = [
    {"name": "Receipt",       "match": "receipt thank you for your purchase order confirmation",     "matching_algorithm": 1},
    {"name": "Invoice",       "match": "invoice amount due please remit bill to",                     "matching_algorithm": 1},
    {"name": "Statement",     "match": "statement account summary account balance transactions",       "matching_algorithm": 1},
    {"name": "Resume",        "match": "resume curriculum vitae cover letter work experience",         "matching_algorithm": 1},
    {"name": "Tax Document",  "match": "T4 T1 notice of assessment CRA tax return RRSP",              "matching_algorithm": 1},
    {"name": "Medical",       "match": "prescription patient physician clinic hospital diagnosis",     "matching_algorithm": 1},
    {"name": "Insurance",     "match": "policy number premium insured coverage deductible",            "matching_algorithm": 1},
    {"name": "Contract",      "match": "agreement contract terms and conditions hereby agree",         "matching_algorithm": 1},
    {"name": "Government",    "match": "Government of Canada Province of Ontario Ministry",            "matching_algorithm": 1},
    {"name": "Utilities",     "match": "hydro electricity natural gas utility bell rogers telus",      "matching_algorithm": 1},
    {"name": "Bank",          "match": "account statement transaction deposit withdrawal balance",      "matching_algorithm": 1},
    {"name": "Pay Stub",      "match": "pay stub earnings deductions net pay gross pay",              "matching_algorithm": 1},
]

TAGS = [
    {"name": "inbox",        "match": "",                                                              "matching_algorithm": 0, "is_inbox_tag": True,  "color": "#e74c3c"},
    {"name": "needs-action", "match": "",                                                              "matching_algorithm": 0, "is_inbox_tag": False, "color": "#e67e22"},
    {"name": "financial",    "match": "invoice receipt statement tax payment",                         "matching_algorithm": 1, "is_inbox_tag": False, "color": "#2ecc71"},
    {"name": "personal",     "match": "",                                                              "matching_algorithm": 0, "is_inbox_tag": False, "color": "#3498db"},
    {"name": "work",         "match": "",                                                              "matching_algorithm": 0, "is_inbox_tag": False, "color": "#9b59b6"},
    {"name": "tax",          "match": "T4 T1 CRA notice of assessment tax return RRSP",               "matching_algorithm": 1, "is_inbox_tag": False, "color": "#1abc9c"},
    {"name": "medical",      "match": "prescription patient physician clinic hospital",                "matching_algorithm": 1, "is_inbox_tag": False, "color": "#e74c3c"},
    {"name": "government",   "match": "Government of Canada Province of Ontario Ministry",             "matching_algorithm": 1, "is_inbox_tag": False, "color": "#34495e"},
    {"name": "contract",     "match": "agreement contract terms and conditions",                       "matching_algorithm": 1, "is_inbox_tag": False, "color": "#f39c12"},
    {"name": "receipt",      "match": "receipt thank you for your purchase",                          "matching_algorithm": 1, "is_inbox_tag": False, "color": "#8e44ad"},
    {"name": "insurance",    "match": "policy number premium insured coverage deductible",             "matching_algorithm": 1, "is_inbox_tag": False, "color": "#16a085"},
    {"name": "utilities",    "match": "hydro electricity natural gas utility",                         "matching_algorithm": 1, "is_inbox_tag": False, "color": "#27ae60"},
]

CORRESPONDENTS = [
    {"name": "CRA",           "match": "Canada Revenue Agency CRA",               "matching_algorithm": 1},
    {"name": "ServiceOntario","match": "ServiceOntario Service Ontario",           "matching_algorithm": 1},
    {"name": "Bell",          "match": "Bell Canada",                              "matching_algorithm": 3},
    {"name": "Rogers",        "match": "Rogers Communications",                    "matching_algorithm": 1},
    {"name": "Telus",         "match": "TELUS",                                    "matching_algorithm": 3},
    {"name": "Hydro One",     "match": "Hydro One",                               "matching_algorithm": 3},
    {"name": "Enbridge",      "match": "Enbridge",                                "matching_algorithm": 3},
    {"name": "Amazon",        "match": "Amazon.ca Amazon.com",                    "matching_algorithm": 1},
]

print("Seeding document types...")
for dt in DOCUMENT_TYPES:
    obj, created = DocumentType.objects.get_or_create(
        name=dt["name"],
        defaults={"match": dt["match"], "matching_algorithm": dt["matching_algorithm"], "is_insensitive": True},
    )
    print(f"  {'created' if created else 'exists '} → {dt['name']}")

print("Seeding tags...")
for t in TAGS:
    obj, created = Tag.objects.get_or_create(
        name=t["name"],
        defaults={
            "match": t["match"],
            "matching_algorithm": t["matching_algorithm"],
            "is_insensitive": True,
            "is_inbox_tag": t.get("is_inbox_tag", False),
            "color": t.get("color", "#a6cee3"),
        },
    )
    print(f"  {'created' if created else 'exists '} → {t['name']}")

print("Seeding correspondents...")
for c in CORRESPONDENTS:
    obj, created = Correspondent.objects.get_or_create(
        name=c["name"],
        defaults={"match": c["match"], "matching_algorithm": c["matching_algorithm"], "is_insensitive": True},
    )
    print(f"  {'created' if created else 'exists '} → {c['name']}")

print("\nDone.")
