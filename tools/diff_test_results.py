#!/usr/bin/env python3
"""Compare two pytest JUnit XML results and report regressions, fixes, and new tests.

Usage:
    python tools/diff_test_results.py <baseline.xml> <latest.xml>
"""

import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

BASELINE_COMMIT = "18406e77ee"
LATEST_COMMIT = "c6d5d89ea7"


def parse_xml(path: str) -> dict:
  """Parse JUnit XML, return {test_id: status}.

  Status is one of: 'pass', 'fail', 'error', 'skip'.
  Test ID is '{classname}::{name}' as produced by pytest.
  """
  tree = ET.parse(path)
  root = tree.getroot()
  results = {}
  for tc in root.findall('.//testcase'):
    classname = tc.get('classname', '')
    name = tc.get('name', '')
    test_id = f"{classname}::{name}" if classname else name
    if tc.find('failure') is not None:
      status = 'fail'
    elif tc.find('error') is not None:
      status = 'error'
    elif tc.find('skipped') is not None:
      status = 'skip'
    else:
      status = 'pass'
    results[test_id] = status
  return results


def compare(baseline: dict, latest: dict) -> dict:
  """Categorize each test ID by how its status changed between runs."""
  all_ids = set(baseline) | set(latest)
  categories = defaultdict(list)
  for tid in sorted(all_ids):
    b = baseline.get(tid)
    l = latest.get(tid)
    if b is None:
      categories['new'].append((tid, l))
    elif l is None:
      categories['removed'].append((tid, b))
    elif b == 'pass' and l in ('fail', 'error'):
      categories['regressed'].append(tid)
    elif b in ('fail', 'error') and l == 'pass':
      categories['fixed'].append(tid)
    elif b == 'pass' and l == 'pass':
      categories['stable_pass'].append(tid)
    elif b in ('fail', 'error') and l in ('fail', 'error'):
      categories['stable_fail'].append(tid)
    else:
      # skip in either run — treat as neutral
      categories['stable_pass'].append(tid)
  return dict(categories)


def print_report(categories: dict) -> None:
  """Print markdown-formatted comparison report to stdout."""
  def count(cat):
    return len(categories.get(cat, []))

  print(f"## Test Comparison: baseline ({BASELINE_COMMIT}) → latest ({LATEST_COMMIT})")
  print()
  print("### Summary")
  print("| Category        | Count |")
  print("|-----------------|-------|")
  rows = [
    ('regressed',   'Regressed       '),
    ('fixed',       'Fixed           '),
    ('new',         'New (latest)    '),
    ('removed',     'Removed         '),
    ('stable_pass', 'Stable pass     '),
    ('stable_fail', 'Stable fail     '),
  ]
  for cat, label in rows:
    print(f"| {label} | {count(cat):5} |")

  if categories.get('regressed'):
    print()
    print("### Regressions (passed → failed)")
    for tid in categories['regressed']:
      print(f"- {tid}")

  if categories.get('fixed'):
    print()
    print("### Fixed (failed → passed)")
    for tid in categories['fixed']:
      print(f"- {tid}")

  if categories.get('new'):
    print()
    print("### New tests in latest")
    for tid, status in categories['new']:
      icon = "PASS" if status == 'pass' else "FAIL"
      print(f"- {icon} {tid}")

  if categories.get('removed'):
    print()
    print("### Removed tests (only in baseline)")
    for tid, status in categories['removed']:
      print(f"- {tid}")

  if categories.get('stable_fail'):
    print()
    print("### Pre-existing failures (failed in both)")
    for tid in categories['stable_fail']:
      print(f"- {tid}")


def main():
  if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <baseline.xml> <latest.xml>", file=sys.stderr)
    sys.exit(1)

  baseline_path, latest_path = sys.argv[1], sys.argv[2]

  try:
    baseline = parse_xml(baseline_path)
  except FileNotFoundError:
    print(f"ERROR: baseline XML not found: {baseline_path}", file=sys.stderr)
    sys.exit(2)
  except ET.ParseError as e:
    print(f"ERROR: baseline XML parse error: {e}", file=sys.stderr)
    sys.exit(2)

  try:
    latest = parse_xml(latest_path)
  except FileNotFoundError:
    print(f"ERROR: latest XML not found: {latest_path}", file=sys.stderr)
    sys.exit(2)
  except ET.ParseError as e:
    print(f"ERROR: latest XML parse error: {e}", file=sys.stderr)
    sys.exit(2)

  categories = compare(baseline, latest)
  print_report(categories)

  # Exit 1 if there are regressions so CI can catch them
  if categories.get('regressed'):
    sys.exit(1)


if __name__ == '__main__':
  main()
