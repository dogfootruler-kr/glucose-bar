"""Claude calls: carb estimate from a meal photo, and the weekly summary.

The API key comes from ANTHROPIC_API_KEY or the macOS Keychain (service "freestyle-bar-anthropic").
"""
import json
import os
import subprocess
from typing import List, Literal, Optional

import anthropic
from pydantic import BaseModel

MODEL = "claude-opus-5-5"
FALLBACK = {"betas": ["server-side-fallback-2026-07-01"], "fallbacks": "default"}


class MealItem(BaseModel):
    name: str
    carbs: float


class MealEstimate(BaseModel):
    description: str
    items: List[MealItem]
    carbs: float
    confidence: Literal["low", "medium", "high"]
    note: Optional[str]


class AIUnavailable(Exception):
    pass


_client = None


def client():
    global _client
    if _client:
        return _client
    key = os.environ.get("ANTHROPIC_API_KEY") or subprocess.run(
        ["security", "find-generic-password", "-s", "freestyle-bar-anthropic", "-w"],
        capture_output=True, text=True,
    ).stdout.strip()
    if not key:
        raise AIUnavailable("No Anthropic API key. Add one to the Keychain (service freestyle-bar-anthropic).")
    _client = anthropic.Anthropic(api_key=key, timeout=120)
    return _client


def available():
    try:
        client()
        return True
    except AIUnavailable:
        return False


def _check(response):
    if response.stop_reason == "refusal":
        raise RuntimeError("Claude declined this request.")
    if response.stop_reason == "max_tokens":
        raise RuntimeError("Claude's answer was cut off.")


MEAL_PROMPT = """Estimate the carbohydrates in this meal for someone with diabetes who logs meals to understand their glucose response.

List the main items you can identify with an estimated carb amount in grams for the portion shown, and the total.
Use the description from the person if given; it overrides what the photo suggests.
"description" is a short dish name (2-5 words) in English, e.g. "Bibimbap with fried egg".
Set confidence to low when the portion size or ingredients are hard to judge.
Use "note" for one short caveat when useful (e.g. "Sauce may add 10-15 g"), otherwise null."""


def estimate_meal(photo_b64=None, media_type="image/jpeg", text=None):
    content = []
    if photo_b64:
        content.append({"type": "image", "source": {"type": "base64", "media_type": media_type, "data": photo_b64}})
    content.append({"type": "text", "text": MEAL_PROMPT + (f"\n\nThe person's description: {text}" if text else "")})
    response = client().beta.messages.parse(
        model=MODEL,
        max_tokens=8000,
        output_config={"effort": "medium"},
        messages=[{"role": "user", "content": content}],
        output_format=MealEstimate,
        **FALLBACK,
    )
    _check(response)
    return response.parsed_output.model_dump()


SUMMARY_SYSTEM = """You write a short weekly glucose recap for one person with diabetes, from their CGM data.
They read it on their Mac. Be warm, direct and specific; use their numbers.

Write Markdown, at most about 220 words:
- A one-line headline about the week (with time in range, compared with the previous week when available).
- "Patterns": 3 to 5 bullets naming concrete patterns: times of day, weekdays, recurring lows or highs, overnight trends.
- "Meals": 1 or 2 bullets on which logged meals were easiest and hardest on their glucose, if any were logged.
- "Worth trying": one practical, non-medical suggestion tied to a pattern (e.g. a walk after the meal that spikes most).

Never suggest insulin doses, timing or changes to medication; if insulin data looks relevant, suggest discussing it with their care team.
If data is sparse, say so briefly rather than inventing patterns. No preamble, no sign-off."""


def weekly_summary(digest):
    response = client().beta.messages.create(
        model=MODEL,
        max_tokens=16000,
        output_config={"effort": "high"},
        system=SUMMARY_SYSTEM,
        messages=[{"role": "user", "content": "This week's data (glucose in mg/dL, local times):\n\n" + json.dumps(digest, indent=1)}],
        **FALLBACK,
    )
    _check(response)
    return "".join(b.text for b in response.content if b.type == "text").strip()
