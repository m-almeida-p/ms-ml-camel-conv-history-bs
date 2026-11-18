#!/usr/bin/env python3
"""Checks recorded responses of conv-history-api against the reference OpenAPI (docs/contract/).

    contract-check.py <openapi.yml> <directory of recorded responses>

Each recorded response is a JSON file written by scripts/test-api.sh:
    {"method": "GET", "path": "/v1/conversations?idYapeAccount=a", "status": 200, "headers_raw": "...", "body_raw": "..."}

What is checked, for every recording:
  - the path is one of the contract's, and the status is one it declares for that path (plus 503, see EXTRA_STATUSES);
  - the content type: application/json for a 200, application/problem+json for an error;
  - the body against the contract's schema for that status, STRICTER than the OpenAPI itself: the OpenAPI lists no
    required fields and allows extra ones, so here every documented field is required (except OPTIONAL_FIELDS) and no
    other field is allowed;
  - a problem: its status repeats the HTTP status, a 4xx has the contract's type, an about:blank has the status phrase;
  - the Link header: only on a 200 of a list, as <target>; rel="prev"|"next", the target being the same route.
"""
import http
import json
import re
import sys
from pathlib import Path

import jsonschema
import yaml

OPTIONAL_FIELDS = {("handler.messageMetadata", "flow")}   # absent outside any flow, says the contract
EXTRA_STATUSES = {503}   # Foundry or the token broker down: not in the OpenAPI, which lists 500 only (documented in the spec, C4)
PROBLEM_TYPES = {400: {"tag:yape.com.pe,2026:conversation-history:invalid-request", "tag:yape.com.pe,2026:conversation-history:invalid-cursor"},
                 404: {"tag:yape.com.pe,2026:conversation-history:conversation-not-found"}}
LINK = re.compile(r'^<(?P<target>[^>]+)>; rel="(?P<rel>prev|next)"$')


def strict_definitions(definitions):
    out = json.loads(json.dumps(definitions))
    for name, definition in out.items():
        props = definition.get("properties")
        if props is not None:
            definition["additionalProperties"] = False
            definition["required"] = [p for p in props if (name, p) not in OPTIONAL_FIELDS]
    return out


def template_of(path, templates):
    path = path.split("?", 1)[0]
    for template in templates:
        if re.fullmatch(re.sub(r"\{[^}]+\}", "[^/]+", template), path):
            return template
    return None


def parse_headers(raw):
    headers = {}
    for line in raw.replace("\r", "").split("\n"):
        if ":" in line and not line.startswith("HTTP/"):
            name, value = line.split(":", 1)
            headers[name.strip().lower()] = value.strip()
    return headers


def check(case, spec, definitions):
    problems = []
    status = case["status"]
    template = template_of(case["path"], spec["paths"])
    if template is None:
        return [f"{case['path']} is not a path of the contract"]
    declared = spec["paths"][template]["get"]["responses"]
    if str(status) not in declared and not (status in EXTRA_STATUSES and template != "/health"):
        return [f"status {status} is not declared for {template} (declared: {', '.join(declared)})"]
    headers = parse_headers(case["headers_raw"])
    ctype = headers.get("content-type", "").split(";")[0].strip()
    want = "application/json" if status == 200 or template == "/health" else "application/problem+json"
    if ctype != want:
        problems.append(f"content type is [{ctype}], the contract says [{want}]")
    try:
        body = json.loads(case["body_raw"])
    except ValueError:
        return problems + ["the body is not JSON"]

    if str(status) in declared and "schema" in declared[str(status)]:
        ref = declared[str(status)]["schema"]["$ref"]
    else:
        ref = "#/definitions/handler.problemResponse"     # a status the contract does not declare: a problem
    for error in jsonschema.Draft4Validator({"definitions": definitions, "$ref": ref}).iter_errors(body):
        problems.append(f"body {'/'.join(str(p) for p in error.absolute_path) or '(root)'}: {error.message}")

    if want == "application/problem+json" and isinstance(body, dict):
        if body.get("status") != status:
            problems.append(f"problem status {body.get('status')} is not the HTTP status {status}")
        if status in PROBLEM_TYPES and body.get("type") not in PROBLEM_TYPES[status]:
            problems.append(f"problem type [{body.get('type')}] is not one of the contract's for {status}")
        if body.get("type") == "about:blank" and body.get("title") != http.HTTPStatus(status).phrase:
            problems.append(f"an about:blank problem is titled with the status phrase [{http.HTTPStatus(status).phrase}], not [{body.get('title')}]")
    link = headers.get("link")
    if link is not None:
        m = LINK.match(link)
        if status != 200 or template == "/health":
            problems.append("a Link header only belongs on a 200 of a list")
        elif not m:
            problems.append(f"the Link header [{link}] is not <target>; rel=\"prev\"|\"next\"")
        elif not m.group("target").startswith(template.split("{")[0].rstrip("/")):
            problems.append(f"the Link target [{m.group('target')}] is not this route")
    return problems


def main():
    spec_path, directory = sys.argv[1], Path(sys.argv[2])
    spec = yaml.safe_load(open(spec_path, encoding="utf-8"))
    definitions = strict_definitions(spec["definitions"])
    failed = 0
    cases = sorted(directory.glob("*.json"))
    for file in cases:
        case = json.load(open(file, encoding="utf-8"))
        problems = check(case, spec, definitions)
        label = f"{file.stem}: {case['method']} {case['path'][:70]} -> {case['status']}"
        if problems:
            failed += 1
            print(f"  FAIL  {label}")
            for p in problems:
                print(f"          {p}")
        else:
            print(f"  ok    {label}")
    print(f"\n{len(cases)} recorded responses, {failed} off the contract")
    sys.exit(1 if failed or not cases else 0)


if __name__ == "__main__":
    main()
