import importlib

import pytest
import respx
from fastapi.testclient import TestClient
from httpx import Response


def load_app(monkeypatch, tmp_path, api_key=None, api_key_file=None):
    monkeypatch.setenv("OVMS_URL", "http://ovms.test/v3/chat/completions")
    monkeypatch.setenv("MODEL_NAME", "test-model")
    if api_key is not None:
        monkeypatch.setenv("API_KEY", api_key)
    else:
        monkeypatch.delenv("API_KEY", raising=False)

    if api_key_file is not None:
        secret_file = tmp_path / "api-key"
        secret_file.write_text(api_key_file, encoding="utf-8")
        monkeypatch.setenv("API_KEY_FILE", str(secret_file))
    else:
        monkeypatch.delenv("API_KEY_FILE", raising=False)

    import app.main

    importlib.reload(app.main)
    return TestClient(app.main.app)


@respx.mock
def test_chat_accepts_env_api_key(monkeypatch, tmp_path):
    client = load_app(monkeypatch, tmp_path, api_key="env-secret")
    respx.post("http://ovms.test/v3/chat/completions").mock(
        return_value=Response(
            200,
            json={
                "model": "test-model",
                "choices": [{"message": {"content": "hello"}}],
                "usage": {"prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4},
            },
        )
    )

    response = client.post(
        "/chat",
        headers={"X-API-Key": "env-secret"},
        json={"message": "hi", "max_tokens": 8},
    )

    assert response.status_code == 200
    assert response.json()["answer"] == "hello"
    assert response.json()["usage"]["total_tokens"] == 4


@respx.mock
def test_chat_accepts_file_api_key(monkeypatch, tmp_path):
    client = load_app(monkeypatch, tmp_path, api_key_file="file-secret\n")
    respx.post("http://ovms.test/v3/chat/completions").mock(
        return_value=Response(
            200,
            json={
                "model": "test-model",
                "choices": [{"message": {"content": "from file"}}],
                "usage": {"prompt_tokens": 2, "completion_tokens": 2, "total_tokens": 4},
            },
        )
    )

    response = client.post(
        "/chat",
        headers={"X-API-Key": "file-secret"},
        json={"message": "hi", "max_tokens": 8},
    )

    assert response.status_code == 200
    assert response.json()["answer"] == "from file"


def test_chat_rejects_invalid_key(monkeypatch, tmp_path):
    client = load_app(monkeypatch, tmp_path, api_key="correct")

    response = client.post(
        "/chat",
        headers={"X-API-Key": "wrong"},
        json={"message": "hi", "max_tokens": 8},
    )

    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid API key"


def test_chat_requires_configured_key(monkeypatch, tmp_path):
    client = load_app(monkeypatch, tmp_path)

    response = client.post(
        "/chat",
        headers={"X-API-Key": "anything"},
        json={"message": "hi", "max_tokens": 8},
    )

    assert response.status_code == 500
    assert response.json()["detail"] == "Gateway API key is not configured"
