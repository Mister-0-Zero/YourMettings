import json

import httpx
import pytest

from app.integrations.ollama import LLMError, OllamaGenerator
from app.services import long_generation as lg


def response(facts, **extra):
    return httpx.Response(200, json={"done": True, "message": {"content": json.dumps({"facts": facts})}, **extra})


def adapter(handler):
    return OllamaGenerator("http://local", "chosen:tag", 1, httpx.MockTransport(lambda request: httpx.Response(200, json={}) if request.url.path == "/api/show" else handler(request)))


def test_fake_passes_whole_input_and_options():
    class Fake:
        def generate(self, text, *, options):
            assert text == "begin middle end"
            assert options == {"detail_level": "brief"}
            return "markdown"
    updates = []
    markdown, metadata = lg.generate_long(Fake(), "begin middle end", options={"detail_level": "brief"}, on_progress=updates.append)
    assert markdown == "markdown"
    assert metadata["strategy"] == "passthrough"
    assert updates[0]["stage"] == "direct"


@pytest.mark.parametrize("text", ["x" * 200001, "a " * 15001, "界" * 140000], ids=["characters", "words", "utf8-bytes"])
def test_input_limits(text):
    with pytest.raises(lg.LongInputError) as error:
        lg.validate_long_input(text)
    assert error.value.code == "source_too_large"


def test_input_limits_inclusive():
    lg.validate_long_input("x" * 200000)
    lg.validate_long_input("a " * 15000)
    lg.validate_long_input("界" * 133333)


def test_short_source_uses_original_generation_without_context_overrides():
    calls = []
    def handler(request):
        calls.append(request.url.path)
        if request.url.path == "/api/ps":
            return httpx.Response(200, json={"models": [{"name": "chosen:tag", "context_length": 32768}]})
        body = json.loads(request.content)
        assert body["model"] == "chosen:tag"
        assert body["options"] == {"temperature": .2, "num_predict": 12288}
        assert json.loads(body["messages"][1]["content"])["transcript"] == "whole source"
        return httpx.Response(200, json={"done": True, "message": {"content": "summary"}})
    result, metadata = lg.generate_long(adapter(handler), "whole source")
    assert result == "summary"
    assert metadata["strategy"] == "direct"
    assert calls == ["/api/ps", "/api/chat"]


def test_unloaded_configured_model_is_warmed_and_read_again():
    ps_calls = 0
    def handler(request):
        nonlocal ps_calls
        if request.url.path == "/api/ps":
            ps_calls += 1
            models = [{"name": "another:tag", "context_length": 999999}]
            if ps_calls == 2:
                models.append({"model": "chosen:tag", "context_length": 32768})
            return httpx.Response(200, json={"models": models})
        body = json.loads(request.content)
        assert body["model"] == "chosen:tag"
        if request.url.path == "/api/generate":
            assert body == {"model": "chosen:tag", "prompt": "", "stream": False}
            return httpx.Response(200, json={"done": True})
        return httpx.Response(200, json={"done": True, "message": {"content": "summary"}})
    _, metadata = lg.generate_long(adapter(handler), "source")
    assert ps_calls == 2
    assert metadata["context_length"] == 32768


def test_partition_preserves_exact_unicode_and_whitespace():
    text = "Начало\n" + "a\t界\"\\\n" * 6000 + "Конец"
    chunks = lg._partition_source(text, 16096)
    assert len(chunks) > 2
    assert "".join(chunks) == text
    assert all(lg._cost(lg.FACT_PROMPT, lg._json({"source_segment": chunk}), lg.FACT_SCHEMA) <= 16096 for chunk in chunks)


def test_all_source_segments_reach_map_and_facts_reach_final():
    source = "BEGIN " + "x" * 35000 + " MIDDLE " + "y" * 35000 + " END"
    segments, facts, stages = [], [], []
    def handler(request):
        if request.url.path == "/api/ps":
            return httpx.Response(200, json={"models": [{"name": "chosen:tag", "context_length": 20096}]})
        body = json.loads(request.content)
        assert not ({"num_ctx", "num_gpu"} & body["options"].keys())
        data = json.loads(body["messages"][1]["content"])
        if "source_segment" in data:
            assert body["options"] == {"temperature": .2, "num_predict": 8192}
            assert body["think"] is False
            assert lg._cost(body["messages"][0]["content"], body["messages"][1]["content"], body["format"]) <= 20096
            segments.append(data["source_segment"])
            fact = "fact " + str(len(segments))
            facts.append(fact)
            return response([fact])
        assert json.loads(data["transcript"])["facts"] == facts
        return httpx.Response(200, json={"done": True, "message": {"content": "final"}})
    result, metadata = lg.generate_long(adapter(handler), source, on_progress=lambda value: stages.append(value["stage"]))
    assert result == "final"
    assert "".join(segments) == source
    assert metadata["chunk_count"] == len(segments) > 2
    assert stages.count("map") == len(segments)
    assert stages[-1] == "final"


@pytest.mark.parametrize("bad", [
    {"done": False, "message": {"content": '{"facts": ["partial"]}'}},
    {"done": True, "message": {"content": "garbage"}},
    {"done": True, "message": {"content": '{"facts": [1]}'}},
    {"done": True, "message": {"content": '{"facts": ["partial"]}'}, "done_reason": "length"},
])
def test_bad_map_does_not_generate_final(bad):
    def handler(request):
        if request.url.path == "/api/ps":
            return httpx.Response(200, json={"models": [{"name": "chosen:tag", "context_length": 20096}]})
        data = json.loads(json.loads(request.content)["messages"][1]["content"])
        assert "source_segment" in data
        return httpx.Response(200, json=bad)
    with pytest.raises(LLMError) as error:
        lg.generate_long(adapter(handler), "x" * 30000)
    assert error.value.code == ("context_limit_exceeded" if bad.get("done_reason") == "length" else "llm_invalid_response")


def test_reduction_includes_every_fact_in_order():
    mapped, merged, final_facts = [], [], []
    def handler(request):
        if request.url.path == "/api/ps":
            return httpx.Response(200, json={"models": [{"name": "chosen:tag", "context_length": 20096}]})
        data = json.loads(json.loads(request.content)["messages"][1]["content"])
        if "source_segment" in data:
            fact = f"fact-{len(mapped)} " + "z" * 2200
            mapped.append(fact)
            return response([fact])
        if "facts" in data:
            merged.extend(data["facts"])
            return response([fact.split()[0] for fact in data["facts"]])
        final_facts.extend(json.loads(data["transcript"])["facts"])
        return httpx.Response(200, json={"done": True, "message": {"content": "final"}})
    _, metadata = lg.generate_long(adapter(handler), "x" * 50000)
    assert merged == mapped
    assert final_facts == [fact.split()[0] for fact in mapped]
    assert metadata["reduction_rounds"] == 1


def test_nonshrinking_reduction_fails():
    def handler(request):
        if request.url.path == "/api/ps":
            return httpx.Response(200, json={"models": [{"name": "chosen:tag", "context_length": 20096}]})
        data = json.loads(json.loads(request.content)["messages"][1]["content"])
        if "source_segment" in data:
            return response(["z" * 2200])
        assert "facts" in data
        return response(data["facts"])
    with pytest.raises(LLMError, match="context_limit_exceeded"):
        lg.generate_long(adapter(handler), "x" * 50000)


def test_template_and_instructions_budgeted_before_generation():
    def handler(request):
        assert request.url.path == "/api/ps"
        return httpx.Response(200, json={"models": [{"name": "chosen:tag", "context_length": 20096}]})
    with pytest.raises(LLMError, match="context_limit_exceeded"):
        lg.generate_long(adapter(handler), "source", options={"additional_instructions": "z" * 20096})


def test_callback_can_cancel_before_map():
    def handler(request):
        assert request.url.path == "/api/ps"
        return httpx.Response(200, json={"models": [{"name": "chosen:tag", "context_length": 20096}]})
    def callback(metadata):
        if metadata["stage"] == "map":
            raise RuntimeError("cancelled")
    with pytest.raises(RuntimeError, match="cancelled"):
        lg.generate_long(adapter(handler), "x" * 50000, on_progress=callback)


def test_real_template_schema_prompt_and_snapshot_are_budgeted():
    template = {"structure_mode": "strict", "sections": [{"id": "section-id", "type": "section",
        "title": "Итоги", "instruction": "Сохрани решения", "required": True}]}
    options = {"template_snapshot": template, "additional_instructions": "Учитывай сроки"}
    source = "Разговор"
    cost = lg._final_cost(source, options)
    assert cost > lg._final_cost(source, {})
    def handler(request):
        if request.url.path == "/api/ps":
            return httpx.Response(200, json={"models": [{"name": "chosen:tag", "context_length": cost}]})
        body = json.loads(request.content)
        assert body["format"] == lg.output_schema(template)
        assert json.loads(body["messages"][1]["content"])["template"] == template
        assert lg._cost(body["messages"][0]["content"], body["messages"][1]["content"], body["format"]) == cost
        return httpx.Response(200, json={"done": True, "message": {"content": '{"sections":{"section-id":"Решено"}}'}})
    result, metadata = lg.generate_long(adapter(handler), source, options=options)
    assert "Решено" in result
    assert metadata["strategy"] == "direct"
    options["template_snapshot"]["sections"][0]["instruction"] = "z" * cost
    with pytest.raises(LLMError, match="context_limit_exceeded"):
        lg.generate_long(adapter(handler), source, options=options)


@pytest.mark.parametrize("failure,code", [("timeout", "llm_timeout"), ("http", "llm_unavailable"), ("json", "llm_invalid_response")])
def test_context_discovery_errors_are_explicit(failure, code):
    def handler(request):
        if failure == "timeout":
            raise httpx.ReadTimeout("timeout", request=request)
        if failure == "http":
            return httpx.Response(503)
        return httpx.Response(200, text="invalid")
    with pytest.raises(LLMError) as error:
        lg.generate_long(adapter(handler), "source")
    assert error.value.code == code


def test_missing_context_never_uses_another_models_capacity():
    def handler(request):
        if request.url.path == "/api/generate":
            return httpx.Response(200, json={"done": True})
        return httpx.Response(200, json={"models": [{"name": "another", "context_length": 999999}]})
    with pytest.raises(LLMError, match="context_limit_exceeded"):
        lg.generate_long(adapter(handler), "source")


def test_single_fact_too_large_for_reducer_fails_without_dropping_it():
    with pytest.raises(LLMError, match="context_limit_exceeded"):
        lg._fact_groups(["first", "z" * 20000, "last"], 20096)


@pytest.mark.parametrize("source_size,strategy", [(20000, "direct"), (100000, "hierarchical")])
def test_validated_counter_propagates_through_budgets_and_bounds_final(monkeypatch, source_size, strategy):
    class Counter:
        method = "validated_test_counter"
        digest = "test-digest"

        def __call__(self, text):
            return (len(text.encode("utf-8")) + 3) // 4
    counter = Counter()
    monkeypatch.setattr(lg, "validated_token_counter", lambda *args, **kwargs: counter)
    source, mapped, final = "x" * source_size, [], []
    options = {"detail_level": "normal"}
    def handler(request):
        if request.url.path == "/api/ps":
            return httpx.Response(200, json={"models": [{"name": "chosen:tag", "context_length": 32768}]})
        body = json.loads(request.content)
        system, user = [message["content"] for message in body["messages"]]
        assert lg._cost(system, user, body.get("format"), counter) <= 32768
        data = json.loads(user)
        if "source_segment" in data:
            mapped.append(data["source_segment"])
            return response([f"fact-{len(mapped)}"])
        assert body["options"] == {"temperature": .2, "num_predict": 12288}
        final.append(data["transcript"])
        return httpx.Response(200, json={"done": True, "message": {"content": "final"}})
    _, metadata = lg.generate_long(adapter(handler), source, options=options)
    assert metadata["strategy"] == strategy
    assert metadata["token_budget_method"] == counter.method
    assert metadata["reserved_output_tokens"] == 12288
    assert metadata["final_request_cost_tokens"] <= 32768
    assert "_output_limit_tokens" not in options
    if strategy == "hierarchical":
        assert "".join(mapped) == source
        assert json.loads(final[0])["facts"] == [f"fact-{index + 1}" for index in range(len(mapped))]
    else:
        assert final == [source]



def test_empty_fact_segments_are_valid_and_all_source_is_still_processed():
    segments = []
    def handler(request):
        if request.url.path == "/api/ps":
            return httpx.Response(200, json={"models": [{"name": "chosen:tag", "context_length": 20096}]})
        if request.url.path == "/api/show":
            return httpx.Response(200, json={})
        data = json.loads(json.loads(request.content)["messages"][1]["content"])
        if "source_segment" in data:
            segments.append(data["source_segment"])
            return response([])
        assert json.loads(data["transcript"]) == {"facts": []}
        return httpx.Response(200, json={"done": True, "message": {"content": "Не указано"}})
    source = "Привет, коллеги. " * 2000
    result, metadata = lg.generate_long(adapter(handler), source)
    assert result == "Не указано" and "".join(segments) == source
    assert metadata["map_calls"] == len(segments)
