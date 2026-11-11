#!/usr/bin/env python3
"""Prepare explicit human gold records and score CER without dropping unknowns."""
import argparse
import json
import unicodedata
from pathlib import Path


def normalize(text):
    return "".join(c for c in unicodedata.normalize("NFC", text) if not c.isspace())


def distance(a, b):
    row = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(row[j] + 1, current[-1] + 1, row[j - 1] + (ca != cb)))
        row = current
    return row[-1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=["template", "score"])
    p.add_argument("input", type=Path)
    p.add_argument("output", type=Path)
    args = p.parse_args()
    data = json.loads(args.input.read_text(encoding="utf-8"))
    if args.mode == "template":
        rows = []
        for page in data["pages"]:
            for block in page["blocks"]:
                if block["kind"] == "figure":
                    continue
                units = block["cells"] if block["kind"] == "table" and not block["retainImage"] else [block]
                for unit in units:
                    raw = "" if block["retainImage"] else unit["rawText"]
                    rows.append(dict(page_id=page["id"], source_page=page["sourcePage"], unit_id=unit["id"],
                                     candidate_raw=raw, candidate_final="" if block["retainImage"] else unit.get("reviewedText", unit["rawText"]),
                                     gold_text=None, verified_by_human=False, special_occurrences=0,
                                     confirmed_special_errors=None, special_types=[], notes=""))
        output = dict(source_document_id=data["id"], reference_type="pending_independent_human", coverage_verified_by_human=False, records=rows)
    else:
        records = data["records"]
        verified = [r for r in records if r.get("verified_by_human") is True and isinstance(r.get("gold_text"), str)]
        gold_count = sum(len(normalize(r["gold_text"])) for r in verified)
        raw_errors = sum(distance(normalize(r["gold_text"]), normalize(r.get("candidate_raw") or "")) for r in verified)
        final_errors = sum(distance(normalize(r["gold_text"]), normalize(r.get("candidate_final") or "")) for r in verified)
        special_count = sum(max(0, int(r.get("special_occurrences", 0))) for r in verified)
        special_records = [r for r in verified if r.get("special_occurrences", 0) > 0]
        special_complete = all(isinstance(r.get("confirmed_special_errors"), int) and r["confirmed_special_errors"] >= 0 for r in special_records)
        special_errors = sum(r["confirmed_special_errors"] for r in special_records) if special_complete else None
        output = dict(verified_units=len(verified), unverified_units=len(records) - len(verified), gold_characters=gold_count,
                      raw_character_errors=raw_errors, raw_CER=raw_errors / gold_count if gold_count else None,
                      final_character_errors=final_errors, final_CER=final_errors / gold_count if gold_count else None,
                      special_occurrences=special_count, special_errors=special_errors,
                      size_gate=gold_count >= 5000 and special_count >= 200,
                      accepted=False,
                      note="Only independently human-verified records enter CER. Unverified units remain explicitly unvalidated. Missing candidate text counts as deletions; only whitespace and NFC equivalence are normalized.")
        output["accepted"] = (data.get("coverage_verified_by_human") is True and output["size_gate"] and len(verified) == len(records)
                              and output["raw_CER"] <= 0.02 and special_errors == 0)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
