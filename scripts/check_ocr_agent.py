#!/usr/bin/env python3
"""Exercise the packaged OCR Agent with real local Vision and controlled HTTP responses."""
import argparse
import copy
import json
import plistlib
import subprocess
import threading
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def prepared(gold):
    page = copy.deepcopy(gold)
    for block in page["blocks"]:
        del block["id"]
        block["alignment"] = "left"
        block["runs"] = []
        for cell in block["cells"]:
            cell["runs"] = []
    return page


def normalized(value):
    return "".join(c for c in unicodedata.normalize("NFC", value) if not c.isspace())


def compare_native(project, gold):
    actual = project["pages"][0]
    a_blocks = sorted(actual["blocks"], key=lambda b: b["order"])
    g_blocks = gold["blocks"]
    types = [b["kind"] for b in a_blocks] == [b["kind"] for b in g_blocks]
    text = types and all(normalized(a["rawText"]) == normalized(g["text"]) for a, g in zip(a_blocks, g_blocks))
    def cells(block, native):
        return sorted((
            c["row"], c["column"], c["rowSpan" if native else "row_span"],
            c["columnSpan" if native else "column_span"], normalized(c["rawText" if native else "text"]),
        ) for c in block["cells"])
    links = types and all(
        a.get("noteID") == g["note_id"] and a.get("noteReferences", []) == g["note_refs"]
        for a, g in zip(a_blocks, g_blocks)
    )
    columns = types and [b.get("ocrColumn") for b in a_blocks] == [b["column"] for b in g_blocks]
    grid = types and all(cells(a, True) == cells(g, False) for a, g in zip(a_blocks, g_blocks))
    label = actual["printedLabel"] == gold["printed_page_label"]
    continuation = actual["ocrStructure"]["endsMidParagraph"] == gold["ends_mid_paragraph"]
    return dict(block_order=types and columns and text, exact_raw_text=text, footnote_links=links,
                grid_and_cells=grid, page_label=label, continuation=continuation)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--route", choices=("responses", "chat"), default="responses")
    args = parser.parse_args()
    app, root = args.app.resolve(), args.root.resolve()
    root.mkdir(parents=True, exist_ok=False)
    fixture = Path(__file__).resolve().parents[1] / "samples"
    gold = json.loads((fixture / "ocr-agent-gold.json").read_text(encoding="utf-8"))
    complete = prepared(gold)
    first = {**complete, "blocks": [b for b in complete["blocks"] if b["kind"] != "footnote"]}
    marker = "验收策略识别码 AX27"
    skill = root / "acceptance-SKILL.md"
    template = (app / "Contents/Resources/OCR/SKILL.md").read_text(encoding="utf-8")
    skill.write_text(template + "\n" + marker + "\n", encoding="utf-8")
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size < 20_000_000:
                self.send_error(400)
                return
            payload = json.loads(self.rfile.read(size))
            if args.route == "responses":
                expected_path = "/v1/responses"
                content = payload["input"][0]["content"]
                images = [p["image_url"] for p in content if p["type"] == "input_image"]
                instructions = payload["instructions"]
                schema_ok = payload["text"]["format"]["strict"] is True and payload["store"] is False
            else:
                expected_path = "/v1/chat/completions"
                content = payload["messages"][1]["content"]
                images = [p["image_url"]["url"] for p in content if p["type"] == "image_url"]
                instructions = payload["messages"][0]["content"]
                schema_ok = "additionalProperties" in instructions
            requests.append({
                "correct_route": self.path == expected_path, "images": len(images), "skill_loaded": marker in instructions,
                "jpeg_data": bool(images) and all(url.startswith("data:image/jpeg;base64,") for url in images),
                "schema_configured": schema_ok, "no_credential": not self.headers.get("Authorization"),
            })
            index = len(requests)
            if index > 2:
                self.send_error(409)
                return
            text = json.dumps(first if index == 1 else complete, ensure_ascii=False)
            if args.route == "responses":
                envelope = {
                    "status": "completed", "model": "fixture-vision",
                    "output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}],
                    "usage": {"input_tokens": 100, "output_tokens": 30},
                }
            else:
                envelope = {
                    "model": "fixture-vision", "choices": [{"finish_reason": "stop", "message": {"content": text}}],
                    "usage": {"prompt_tokens": 100, "completion_tokens": 30},
                }
            raw = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("x-request-id", f"fixture-{index}")
            self.end_headers()
            self.wfile.write(raw)

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        base = f"http://127.0.0.1:{server.server_port}/v1"
        if args.route == "responses":
            base += "/responses"
        command = [
            str(app / "Contents/MacOS" / info["CFBundleExecutable"]), "--qa",
            "--data-root", str(root / "projects"), "--ui-check", str(root / "results"), "--agent-check",
            "--agent-fixture", str(fixture / "ocr-agent-page.png"), "--agent-url", base, "--agent-skill", str(skill),
        ]
        timed_out = False
        try:
            with (root / "launch.log").open("wb") as log:
                process = subprocess.Popen(command, stdout=log, stderr=log)
                try:
                    process.wait(timeout=55)
                except subprocess.TimeoutExpired:
                    timed_out = True
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        finally:
            server.shutdown()
            thread.join()
    output = root / "results/ui-results.json"
    if not output.exists():
        raise SystemExit(f"The app did not write a result. Inspect {root / 'launch.log'}.")
    report = json.loads(output.read_text())
    report["requests"] = requests
    report["route"] = args.route
    report["http_verified"] = (
        len(requests) == 2 and requests[0]["images"] == 1 and 1 < requests[1]["images"] <= 5
        and all(all(value for name, value in r.items() if name != "images") for r in requests)
    )
    documents = list((root / "projects").glob("*.shiyebook/document.json"))
    if report["passed"] and len(documents) == 1:
        report["gold_comparison"] = compare_native(json.loads(documents[0].read_text()), gold)
    report["passed"] = (
        report["passed"] and report["http_verified"] and bool(report.get("gold_comparison"))
        and all(report["gold_comparison"].values()) and process.returncode == 0 and not timed_out
    )
    (root / "agent-results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
