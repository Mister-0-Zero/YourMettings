import json

import httpx
import pytest

from app.integrations.ollama import LLMError, OllamaGenerator


def test_ollama_sends_fixed_prompt_and_uses_configured_tag():
    def handler(request):
        body = json.loads(request.content)
        assert body["model"] == "configured:tag"
        assert body["stream"] is False
        assert body["messages"][0]["role"] == "system"
        assert body["messages"][1] == {"role": "user", "content": "meeting"}
        return httpx.Response(200, json={"done": True, "message": {"content": " Summary "}})
    adapter = OllamaGenerator("http://local", "configured:tag", 1, httpx.MockTransport(handler))
    assert adapter.generate("meeting") == "Summary"


@pytest.mark.parametrize("response,code", [
    (httpx.Response(500), "llm_unavailable"),
    (httpx.Response(200, json={"done": True, "message": {"content": " "}}), "llm_invalid_response"),
    (httpx.Response(200, json={"done": False, "message": {"content": "partial"}}), "llm_invalid_response"),
    (httpx.Response(200, text="not json"), "llm_invalid_response"),
])
def test_adapter_errors(response, code):
    adapter = OllamaGenerator("http://local", "tag", 1, httpx.MockTransport(lambda r: response))
    with pytest.raises(LLMError) as error:
        adapter.generate("meeting")
    assert error.value.code == code


def test_adapter_timeout():
    def handler(request):
        raise httpx.ReadTimeout("timeout", request=request)
    adapter = OllamaGenerator("http://local", "tag", 1, httpx.MockTransport(handler))
    with pytest.raises(LLMError) as error:
        adapter.generate("meeting")
    assert error.value.code == "llm_timeout"
