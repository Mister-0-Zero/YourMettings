"""Reconstruct and verify the configured GGUF tokenizer without external assets.

Only the known qwen35 byte-level BPE is supported. Unsupported metadata, malformed
vocabularies or failed calibration return None: callers must retain a safe fallback.
The caller must already own the GPU slot before requesting calibration.
"""
import hashlib
import json
from threading import Lock

import httpx
from tokenizers import AddedToken, Regex, Tokenizer, models, pre_tokenizers

# Qwen/Qwen3.5-27B tokenizer_config.json, revision feea018b31f89dc0950e61da42577a7a4ab09169.
QWEN35_PATTERN = r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?[\p{L}\p{M}]+|\p{N}| ?[^\s\p{L}\p{M}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"
CALIBRATION_PROBES = (
    "План встречи: Анна решила перенести выпуск на 23.10.2026. Цена 12345,67 ₽.\n"
    "def check(x):\n    return x + 42  # код\n🙂 🚀 e\u0301 ё\nКонец.",
    "Начало\n\nSELECT id FROM tasks WHERE due_date='2026-11-03';\r\n"
    "Иван: не решение, а предложение; исправление 17 → 19. 007 3.14159\t👩‍💻 А\u0301 can't won't\n",
)
_VALIDATED = {}
_CACHE_LOCK = Lock()


class ModelTokenCounter:
    method = "validated_gguf_qwen35"

    def __init__(self, tokenizer, digest):
        self.tokenizer = tokenizer
        self.digest = digest

    def __call__(self, text):
        return len(self.tokenizer.encode(text, add_special_tokens=False).ids)


def tokenizer_from_model_info(info):
    if not isinstance(info, dict) or info.get("tokenizer.ggml.model") != "gpt2" or info.get("tokenizer.ggml.pre") != "qwen35":
        raise ValueError("Unsupported tokenizer")
    tokens, merges, types = (info.get("tokenizer.ggml." + key) for key in ("tokens", "merges", "token_type"))
    if (not isinstance(tokens, list) or not tokens or any(not isinstance(t, str) or not t for t in tokens)
            or len(set(tokens)) != len(tokens) or not isinstance(merges, list) or not merges
            or not isinstance(types, list) or len(types) != len(tokens)
            or any(type(t) is not int or t not in range(1, 7) for t in types)
            or info.get("tokenizer.ggml.add_bos_token") is not False):
        raise ValueError("Invalid tokenizer metadata")
    pairs = []
    vocab = {token: index for index, token in enumerate(tokens)}
    for merge in merges:
        if not isinstance(merge, str):
            raise ValueError("Invalid merge")
        pair = merge.split(" ")
        if len(pair) != 2 or any(part not in vocab for part in pair) or "".join(pair) not in vocab:
            raise ValueError("Invalid merge vocabulary")
        pairs.append(tuple(pair))
    tokenizer = Tokenizer(models.BPE(vocab=vocab, merges=pairs))
    tokenizer.pre_tokenizer = pre_tokenizers.Sequence([
        pre_tokenizers.Split(Regex(QWEN35_PATTERN), behavior="isolated"),
        pre_tokenizers.ByteLevel(add_prefix_space=False, use_regex=False),
    ])
    tokenizer.add_special_tokens([AddedToken(token, special=True, normalized=False)
                                  for token, token_type in zip(tokens, types) if token_type in (3, 4)])
    return tokenizer


def validated_token_counter(client, model, *, digest=None, on_progress=None):
    """Return a calibrated counter or None. Never trust an unverified estimate.

    A digest from /api/ps lets subsequent jobs reuse calibration without reloading
    the vocabulary. Otherwise hash /api/show metadata before looking in the cache.
    HTTP/protocol errors here degrade to byte budgeting, not extra capacity.
    """
    base_key = (str(client.base_url), model)
    if not isinstance(digest, str) or not digest:
        digest = None
    if digest:
        with _CACHE_LOCK:
            cached = _VALIDATED.get((*base_key, digest))
        if cached:
            return cached
    try:
        if on_progress:
            on_progress("tokenizer")
        response = client.post("/api/show", json={"model": model, "verbose": True})
        response.raise_for_status()
        body = response.json()
        info = body.get("model_info")
        fingerprint = digest or hashlib.sha256(json.dumps(info, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()
        key = (*base_key, fingerprint)
        with _CACHE_LOCK:
            cached = _VALIDATED.get(key)
        if cached:
            return cached
        counter = ModelTokenCounter(tokenizer_from_model_info(info), fingerprint)
        for probe in CALIBRATION_PROBES:
            if on_progress:
                on_progress("tokenizer_calibration")
            response = client.post("/api/generate", json={"model": model, "prompt": probe,
                "raw": True, "think": False, "stream": False, "options": {"num_predict": 1}})
            response.raise_for_status()
            result = response.json()
            if result.get("done") is not True or type(result.get("prompt_eval_count")) is not int or result["prompt_eval_count"] != counter(probe):
                return None
        with _CACHE_LOCK:
            # Bound process memory when configured models are repeatedly replaced.
            if len(_VALIDATED) >= 4:
                _VALIDATED.pop(next(iter(_VALIDATED)))
            _VALIDATED[key] = counter
        return counter
    except (httpx.HTTPError, ValueError, TypeError, KeyError, AttributeError):
        return None
