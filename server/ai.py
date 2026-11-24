"""Claude calls: carb estimate from a meal photo, dose adjusted for how similar meals went, and the weekly summary.

Uses the Claude Agent SDK, which runs Claude Code under the hood and therefore uses the
Claude subscription you're logged into with `claude` (no API key). Tools are disabled:
these are single question-and-answer calls.
"""
"""AI calls: carb estimate from a meal photo, dose adjusted for how similar meals went, and the weekly summary.

The provider is set under "ai" in ~/.config/freestyle-bar/config.json:

  {"ai": {"provider": "claude"}}    Claude Agent SDK on the subscription you're logged into with `claude`
                                    (no API key); the default when claude-agent-sdk is installed
  {"ai": {"provider": "gemini", "apiKey": "..."}}
                                    Google Gemini API (key from aistudio.google.com, or GEMINI_API_KEY);
                                    model defaults to gemini-flash-latest, then gemini-3.6-flash and
                                    gemini-flash-lite-latest while the newer ones are overloaded
  {"ai": {"provider": "openai", "baseUrl": "...", "model": "...", "apiKey": "..."}}
                                    any OpenAI-compatible chat API: Groq, Ollama, OpenRouter, Workers AI, OpenAI
                                    (key optional for a local Ollama; OPENAI_API_KEY also works)
  {"ai": {"provider": "none"}}      AI features off

Optional for every provider: "model" (or a list of models, tried in order while the API is busy), and "timeout" in seconds (default 180; raise it for a slow local model).
Gemini and OpenAI-compatible providers are called with urllib, so they need no extra packages.
"""
import asyncio
import json
import os
import time
import urllib.error
import urllib.request

# Gemini tries the next model when one stays overloaded (503s are common on the free tier).
MODELS = {"claude": "claude-sonnet-5-5", "gemini": ["gemini-flash-latest", "gemini-3.6-flash", "gemini-flash-lite-latest"]}
NAMES = {"claude": "Claude", "gemini": "Gemini"}

try:
    import claude_agent_sdk
except ImportError:
    claude_agent_sdk = None

settings = {"provider": "claude" if claude_agent_sdk else "none"}


def configure(cfg):
    """Picks the provider from the "ai" section of config.json (see the module docstring)."""
    global settings
    s = dict(cfg or {})
    s.setdefault("provider", "claude" if claude_agent_sdk else "none")
    s["provider"] = s["provider"].lower()
    if s["provider"] not in ("claude", "gemini", "openai", "none"):
        raise ValueError(f'unknown "ai" provider {s["provider"]!r} (claude, gemini, openai or none)')
    if s["provider"] == "openai" and not s.get("model"):
        raise ValueError('"ai" provider openai needs a "model"')
    settings = s


def _key():
    env = {"gemini": "GEMINI_API_KEY", "openai": "OPENAI_API_KEY"}.get(settings["provider"])
    return settings.get("apiKey") or (os.environ.get(env) if env else None)


def available():
    p = settings["provider"]
    if p == "claude":
        return claude_agent_sdk is not None
    if p == "gemini":
        return bool(_key())
    return p == "openai"


def unavailable_reason():
    p = settings["provider"]
    if p == "claude":
        return "Install claude-agent-sdk on the server to use Claude, or set another provider under \"ai\" in config.json."
    if p == "gemini":
        return 'Add a Gemini API key ("apiKey" under "ai" in config.json, or GEMINI_API_KEY).'
    return 'AI is off: set a provider under "ai" in config.json.'


def describe():
    """For the log: which provider and model the AI features use."""
    p = settings["provider"]
    if p == "none":
        return "off"
    return f"{p} ({', '.join(_models())})" + ("" if available() else ", not available: " + unavailable_reason())


def _parse_json(text):
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1].rsplit("```", 1)[0]
    return json.loads(text)


def _models():
    m = settings.get("model") or MODELS.get(settings["provider"])
    return [m] if isinstance(m, str) else list(m)


class Busy(RuntimeError):
    """The API kept answering 429 or 5xx."""


def _post(url, body, headers):
    """POSTs JSON, retrying a few times when the API is busy (429 or 5xx, common on free tiers)."""
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"content-type": "application/json", **headers})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=float(settings.get("timeout", 180))) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            busy = e.code == 429 or e.code >= 500
            if busy and attempt < 2:
                time.sleep(2 * 3 ** attempt)  # 2, 6 s
                continue
            detail = e.read().decode(errors="replace")
            try:
                detail = json.loads(detail)["error"]["message"]
            except (ValueError, KeyError, TypeError):
                detail = detail[:300]
            raise (Busy if busy else RuntimeError)(
                f"{NAMES.get(settings['provider'], 'AI')} request failed ({e.code}): {detail}") from None


def _each_model(call):
    """call(model) for each configured model in turn, moving on only while the API is busy."""
    models = _models()
    for i, model in enumerate(models):
        try:
            return call(model)
        except Busy:
            if i == len(models) - 1:
                raise


def complete(system, content, schema=None, effort="medium"):
    """One question and answer. content is a list of {"type": "text", "text"} and
    {"type": "image", "data": base64, "mediaType"} parts. Returns the parsed JSON when schema is
    given, the text otherwise."""
    p = settings["provider"]
    if not available():
        raise RuntimeError(unavailable_reason())
    return {"claude": _claude, "gemini": _gemini, "openai": _openai}[p](system, content, schema, effort)


# --- Claude (Agent SDK, subscription login) ------------------------------------

def _claude(system, content, schema, effort):
    sdk = claude_agent_sdk
    options = sdk.ClaudeAgentOptions(
        model=_models()[0],
        system_prompt=system,
        tools=[],                 # no file, shell or web access
        setting_sources=[],       # ignore user/project CLAUDE.md and settings
        max_turns=2,
        effort=effort,
        output_format={"type": "json_schema", "schema": schema} if schema else None,
        cwd=os.path.expanduser("~/Library/Application Support/freestyle-bar"),
        env={"ANTHROPIC_API_KEY": ""},  # never fall back to an API key; use the subscription login
    )
    parts = [{"type": "image", "source": {"type": "base64", "media_type": c["mediaType"], "data": c["data"]}}
             if c["type"] == "image" else c for c in content]

    async def ask():
        async def messages():
            yield {"type": "user", "message": {"role": "user", "content": parts}}

        text, result = [], None
        async for msg in sdk.query(prompt=messages(), options=options):
            if isinstance(msg, sdk.AssistantMessage):
                text += [b.text for b in msg.content if isinstance(b, sdk.TextBlock)]
            elif isinstance(msg, sdk.ResultMessage):
                result = msg
        if result is None or result.is_error:
            detail = (result.errors or [result.result]) if result else ["no result"]
            raise RuntimeError(f"Claude request failed: {detail}")
        return result, "".join(text).strip()

    # The HTTP server is threaded, so each call gets its own event loop.
    result, text = asyncio.run(ask())
    if schema:
        return result.structured_output if result.structured_output is not None else _parse_json(text)
    return text or (result.result or "").strip()


# --- Gemini API ----------------------------------------------------------------

def _gemini(system, content, schema, effort):
    parts = [{"inlineData": {"mimeType": c["mediaType"], "data": c["data"]}} if c["type"] == "image"
             else {"text": c["text"]} for c in content]
    config = {"responseMimeType": "application/json", "responseJsonSchema": schema} if schema else {}
    body = {"systemInstruction": {"parts": [{"text": system}]},
            "contents": [{"role": "user", "parts": parts}], "generationConfig": config}
    r = _each_model(lambda model: _post(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent", body, {"x-goog-api-key": _key()}))
    cand = (r.get("candidates") or [{}])[0]
    text = "".join(p.get("text", "") for p in cand.get("content", {}).get("parts", []) if not p.get("thought"))
    if not text:
        reason = cand.get("finishReason") or r.get("promptFeedback", {}).get("blockReason") or "empty reply"
        raise RuntimeError(f"Gemini returned no answer ({reason})")
    return _parse_json(text) if schema else text.strip()


# --- OpenAI-compatible chat APIs (Groq, Ollama, OpenRouter, Workers AI, OpenAI) --

def _openai(system, content, schema, effort):
    base = (settings.get("baseUrl") or "https://api.openai.com/v1").rstrip("/")
    parts = [{"type": "image_url", "image_url": {"url": f"data:{c['mediaType']};base64,{c['data']}"}}
             if c["type"] == "image" else c for c in content]
    body = {"messages": [{"role": "system", "content": system}, {"role": "user", "content": parts}]}
    if schema:
        body["response_format"] = {"type": "json_schema",
                                   "json_schema": {"name": "answer", "schema": schema, "strict": True}}
    key = _key()
    r = _each_model(lambda model: _post(base + "/chat/completions", {"model": model, **body},
                                        {"authorization": f"Bearer {key}"} if key else {}))
    text = (r.get("choices") or [{}])[0].get("message", {}).get("content") or ""
    if not text:
        raise RuntimeError("AI returned no answer")
    return _parse_json(text) if schema else text.strip()


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


MEAL_PROMPT = """Estimate the carbohydrates in this meal for someone with diabetes who logs meals to understand their glucose response.

List the main items you can identify with an estimated carb amount in grams for the portion shown, and the total.
Use the description from the person if given; it overrides what the photo suggests.
"description" is a short dish name (2-5 words) in English, e.g. "Bibimbap with fried egg".
Set confidence to low when the portion size or ingredients are hard to judge.
Use "note" for one short caveat when useful (e.g. "Sauce may add 10-15 g"), otherwise null."""


def estimate_meal(photo_b64=None, media_type="image/jpeg", text=None):
    content = []
    if photo_b64:
        content.append({"type": "image", "mediaType": media_type, "data": photo_b64})
    content.append({"type": "text", "text": MEAL_PROMPT + (f"\n\nThe person's description: {text}" if text else "")})
    return complete("You estimate meal carbohydrates from photos and descriptions.", content, MEAL_SCHEMA)


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
    return complete(DOSE_SYSTEM, content, DOSE_SCHEMA)


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
    return complete(SUMMARY_SYSTEM, content, effort="high")
