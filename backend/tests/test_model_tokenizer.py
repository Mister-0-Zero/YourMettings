import json

import httpx
import pytest
from tokenizers.pre_tokenizers import ByteLevel

from app.services import model_tokenizer as mt


def model_info():
    tokens = sorted(ByteLevel.alphabet()) + ["ab", "<|im_start|>"]
    return {"tokenizer.ggml.model": "gpt2", "tokenizer.ggml.pre": "qwen35",
        "tokenizer.ggml.tokens": tokens, "tokenizer.ggml.merges": ["a b"],
        "tokenizer.ggml.token_type": [1] * (len(tokens) - 1) + [3],
        "tokenizer.ggml.add_bos_token": False}


@pytest.fixture(autouse=True)
def clear_cache():
    mt._VALIDATED.clear()
    yield
    mt._VALIDATED.clear()


def test_bytelevel_unicode_combining_chars_numbers_and_special_ids():
    info = model_info()
    tokenizer = mt.tokenizer_from_model_info(info)
    assert tokenizer.encode("ab", add_special_tokens=False).ids == [info["tokenizer.ggml.tokens"].index("ab")]
    assert tokenizer.encode("<|im_start|>", add_special_tokens=False).ids == [len(info["tokenizer.ggml.tokens"]) - 1]
    source = "Русский текст e\u0301 👩‍💻\n12345"
    ids = tokenizer.encode(source, add_special_tokens=False).ids
    assert len(ids) == len(source.encode("utf-8"))  # This tiny mock vocabulary only merges 'ab'.


def test_digits_are_split_before_bpe_merging():
    info = model_info()
    info["tokenizer.ggml.tokens"].append("12")
    info["tokenizer.ggml.token_type"].append(1)
    info["tokenizer.ggml.merges"].append("1 2")
    tokenizer = mt.tokenizer_from_model_info(info)
    assert len(tokenizer.encode("12", add_special_tokens=False).ids) == 2


@pytest.mark.parametrize("change", [
    {"tokenizer.ggml.pre": "unknown"}, {"tokenizer.ggml.model": "llama"},
    {"tokenizer.ggml.add_bos_token": True}, {"tokenizer.ggml.tokens": ["a", "a"]},
    {"tokenizer.ggml.merges": ["a missing"]}, {"tokenizer.ggml.token_type": []},
])
def test_unsupported_or_inconsistent_metadata_rejected(change):
    info = model_info()
    info.update(change)
    with pytest.raises(ValueError):
        mt.tokenizer_from_model_info(info)


def test_exact_calibration_and_digest_cache_without_context_overrides():
    info, calls, stages = model_info(), [], []
    tokenizer = mt.tokenizer_from_model_info(info)
    def handler(request):
        calls.append(request.url.path)
        body = json.loads(request.content)
        assert body["model"] == "configured:tag"
        if request.url.path == "/api/show":
            assert body["verbose"] is True
            return httpx.Response(200, json={"model_info": info})
        assert body["raw"] is True and body["think"] is False and body["stream"] is False
        assert body["options"] == {"num_predict": 1}
        count = len(tokenizer.encode(body["prompt"], add_special_tokens=False).ids)
        return httpx.Response(200, json={"done": True, "prompt_eval_count": count})
    with httpx.Client(base_url="http://local", transport=httpx.MockTransport(handler)) as client:
        counter = mt.validated_token_counter(client, "configured:tag", digest="digest1", on_progress=stages.append)
        assert counter("ab") == 1
        assert mt.validated_token_counter(client, "configured:tag", digest="digest1") is counter
        assert len(calls) == 3
        assert stages == ["tokenizer", "tokenizer_calibration", "tokenizer_calibration"]
        assert mt.validated_token_counter(client, "configured:tag", digest="digest2") is not counter
        assert len(calls) == 6


def test_mismatch_never_unlocks_larger_budget():
    calls = []
    def handler(request):
        calls.append(request.url.path)
        return httpx.Response(200, json={"model_info": model_info()} if request.url.path == "/api/show"
                              else {"done": True, "prompt_eval_count": 1})
    with httpx.Client(base_url="http://local", transport=httpx.MockTransport(handler)) as client:
        assert mt.validated_token_counter(client, "tag", digest="changed") is None
    assert len(calls) == 2
    assert mt._VALIDATED == {}


@pytest.mark.parametrize("failure", ["unsupported", "http", "json", "timeout"])
def test_failure_uses_safe_fallback(failure):
    def handler(request):
        if failure == "timeout":
            raise httpx.ReadTimeout("timeout", request=request)
        if failure == "http":
            return httpx.Response(503)
        if failure == "json":
            return httpx.Response(200, text="not json")
        return httpx.Response(200, json={"model_info": {"tokenizer.ggml.pre": "other"}})
    with httpx.Client(base_url="http://local", transport=httpx.MockTransport(handler)) as client:
        assert mt.validated_token_counter(client, "tag") is None


def test_callback_cancellation_is_not_swallowed():
    def callback(stage):
        raise RuntimeError("cancelled")
    with httpx.Client(base_url="http://local", transport=httpx.MockTransport(lambda _: httpx.Response(200))) as client:
        with pytest.raises(RuntimeError, match="cancelled"):
            mt.validated_token_counter(client, "tag", on_progress=callback)
