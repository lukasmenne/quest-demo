#!/usr/bin/env python3
"""UserPromptSubmit hook: append each submitted prompt to docs/prompts.txt.

Reads the hook payload as JSON on stdin. Never fails the prompt submission --
any error is swallowed so a logging problem can't block the session.
"""
import json
import os
import sys
from datetime import datetime

# <project>/.claude/hooks/log-prompt.py -> <project>
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOG_PATH = os.path.join(PROJECT_DIR, "docs", "prompts.txt")


def main() -> None:
    prompt = json.load(sys.stdin).get("prompt", "")
    if not prompt.strip():
        return

    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    stamp = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(f"--- {stamp} ---\n{prompt}\n\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
