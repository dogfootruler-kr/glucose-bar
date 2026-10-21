"""Claude calls: carb estimate from a meal photo, dose adjusted for how similar meals went, and the weekly summary.

Uses the Claude Agent SDK, which runs Claude Code under the hood and therefore uses the
Claude subscription you're logged into with `claude` (no API key). Tools are disabled:
these are single question-and-answer calls.
"""
import asyncio
import json
import os

from claude_agent_sdk import AssistantMessage, ClaudeAgentOptions, ResultMessage, TextBlock, query

MODEL = "claude-sonnet-5-5"

MEAL_SCHEMA = {
    "type": "object",
    "properties": {
        "description": {"type": "string"},
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"name": {"type": "string"}, "carbs": {"type": "number"}},
                "required": ["name", "carbs"],
                "additionalProperties": False,
            },
        },
        "carbs": {"type": "number"},
        "confidence": {"type": "string", "enum": ["low", "medium", "high"]},
        "note": {"type": ["string", "null"]},
    },
    "required": ["description", "items", "carbs", "confidence", "note"],
    "additionalProperties": False,
}


def _options(system_prompt, effort, output_format=None):
    env = {"ANTHROPIC_API_KEY": ""}  # never fall back to an API key; use the subscription login
    return ClaudeAgentOptions(
        model=MODEL,
        system_prompt=system_prompt,
        tools=[],                 # no file, shell or web access
        setting_sources=[],       # ignore user/project CLAUDE.md and settings
        max_turns=2,
        effort=effort,
        output_format=output_format,
        cwd=os.path.expanduser("~/Library/Application Support/freestyle-bar"),
        env=env,
    )


async def _ask(content, options):
    async def messages():
        yield {"type": "user", "message": {"role": "user", "content": content}}

    text, result = [], None
    async for msg in query(prompt=messages(), options=options):
        if isinstance(msg, AssistantMessage):
            text += [b.text for b in msg.content if isinstance(b, TextBlock)]
        elif isinstance(msg, ResultMessage):
            result = msg
    if result is None or result.is_error:
        detail = (result.errors or [result.result]) if result else ["no result"]
        raise RuntimeError(f"Claude request failed: {detail}")
    return result, "".join(text).strip()


def _run(coro):
    # The HTTP server is threaded, so each call gets its own event loop.
    return asyncio.run(coro)


def available():
    return True


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
    options = _options("You estimate meal carbohydrates from photos and descriptions.", "medium",
                       {"type": "json_schema", "schema": MEAL_SCHEMA})
    result, text_out = _run(_ask(content, options))
    if result.structured_output is not None:
        return result.structured_output
    return json.loads(text_out)


DOSE_SCHEMA = {
    "type": "object",
    "properties": {
        "matches": {"type": "array", "items": {"type": "integer"}},
        "units": {"type": "number"},
        "reason": {"type": "string"},
    },
    "required": ["matches", "units", "reason"],
    "additionalProperties": False,
}

DOSE_SYSTEM = """You adjust a rapid-insulin suggestion for one person with diabetes, using how the same food went for them before.

You get the meal they're about to eat, the suggestion worked out by a formula from their carb ratio, current glucose,
trend and active insulin, and their past meals: what they wrote, the dish name from a photo estimate, carbs,
the rapid insulin taken with it ("insulin", "minutesFromMeal"), insulin needed later ("laterUnits"), what the
formula would suggest for those carbs today ("formulaToday"), the verdict on the dose (ok / tooLittle / tooMuch /
none = no insulin logged) with its reason, and the glucose peak.

1. Find the past meals that are the same food, however they were written: "half chicken (200g)" and "200g chicken"
   match; a different dish that shares one ingredient doesn't. Put their ids in "matches".
2. If none match, return the formula's units unchanged.
3. Otherwise see whether the same food has consistently needed more or less insulin per gram of carbs than the
   formula assumes (insulin plus laterUnits for "tooLittle", less for "tooMuch", compared with formulaToday), and move
   the carb part of the dose by that much. The correction, trend and active insulin are already right for now; don't
   redo them. One meal is weak evidence: move only part of the way. Meals affected by exercise say little about the food.
4. "units": the adjusted total, a multiple of 0.5, between half and one and a half times the formula's units.
5. "reason": one short sentence naming the past meals and what happened, e.g. "The last 3 times you had roast chicken
   with rice, 5 u ran high and you needed about 1.5 u more later." If nothing matched, say so in a few words."""


def adjust_dose(meal, suggestion, past):
    content = [{"type": "text", "text": "Meal now:\n" + json.dumps(meal) + "\n\nFormula suggestion:\n"
                + json.dumps(suggestion) + "\n\nPast meals (local times):\n" + json.dumps(past, indent=0)}]
    result, text = _run(_ask(content, _options(DOSE_SYSTEM, "medium", {"type": "json_schema", "schema": DOSE_SCHEMA})))
    return result.structured_output if result.structured_output is not None else json.loads(text)


SUMMARY_SYSTEM = """You write a short weekly glucose recap for one person with diabetes, from their CGM data.
They read it on their Mac. Be warm, direct and specific; use their numbers.

Write Markdown, at most about 250 words:
- A one-line headline about the week (with time in range, compared with the previous week when available).
- "Patterns": 3 to 5 bullets naming concrete patterns: times of day, weekdays, recurring lows or highs, overnight trends.
- "Meals": 1 or 2 bullets on which logged meals were easiest and hardest on their glucose, if any were logged.
  foodScore reflects the first 90 minutes (mostly the food); doseVerdict says whether the rapid insulin brought
  glucose back (ok / tooLittle / tooMuch). When a meal's foodScore is good but the dose was off, say the food
  itself looked fine and the dose was the issue, rather than blaming the food. Scores and dose verdicts already
  allow for exercise around the meal ("exercise", "exerciseLoweredGlucoseBy"), so don't credit the food for a
  drop the exercise explains.
- "Exercise": 1 or 2 bullets if any was logged: how glucose responded (glucoseChange; dropAfterCarbsAndInsulin is
  the part the exercise itself accounts for, expectedDrop the usual for that kind of session) and any lows in the
  12 hours after (lowAfter, and lowEpisodes marked afterExercise). Skip this section if none was logged.
- "Worth trying": one practical, non-medical suggestion tied to a pattern (e.g. a walk after the meal that spikes most).

Never suggest insulin doses, timing or changes to medication; if insulin data looks relevant, suggest discussing it with their care team.
Delayed lows after exercise are worth raising with their care team.
If data is sparse, say so briefly rather than inventing patterns. Reply with the recap only: no preamble, no sign-off."""


def weekly_summary(digest):
    content = [{"type": "text", "text": "This week's data (glucose in mg/dL, local times):\n\n" + json.dumps(digest, indent=1)}]
    result, text = _run(_ask(content, _options(SUMMARY_SYSTEM, "high")))
    return text or (result.result or "").strip()
