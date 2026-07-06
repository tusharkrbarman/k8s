import logging
import os
import time
from typing import Any

import httpx
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field


logger = logging.getLogger(__name__)

OVMS_URL = os.getenv(
    "OVMS_URL",
    "http://ovms-llm-gpu-service:8000/v3/chat/completions",
)
MODEL_NAME = os.getenv(
    "MODEL_NAME",
    "OpenVINO/Phi-3.5-mini-instruct-int4-ov",
)
API_KEY = os.getenv("API_KEY")
API_KEY_FILE = os.getenv("API_KEY_FILE")
REQUEST_TIMEOUT_SECONDS = float(os.getenv("REQUEST_TIMEOUT_SECONDS", "60"))

app = FastAPI(title="Kubernetes OpenVINO LLM Gateway")


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=2000)
    max_tokens: int = Field(default=32, ge=1, le=256)


class ChatResponse(BaseModel):
    answer: str
    model: str
    latency_seconds: float
    usage: dict[str, Any] | None = None


def get_configured_api_key() -> str | None:
    if API_KEY:
        return API_KEY

    if API_KEY_FILE:
        try:
            with open(API_KEY_FILE, encoding="utf-8") as secret_file:
                return secret_file.read().strip()
        except OSError as exc:
            logger.error("failed_to_read_api_key_file path=%s error=%s", API_KEY_FILE, exc)
            return None

    return None


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/chat", response_model=ChatResponse)
async def chat(
    request: ChatRequest,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> ChatResponse:
    configured_api_key = get_configured_api_key()
    if not configured_api_key:
        raise HTTPException(status_code=500, detail="Gateway API key is not configured")

    if x_api_key != configured_api_key:
        raise HTTPException(status_code=401, detail="Invalid API key")

    payload = {
        "model": MODEL_NAME,
        "messages": [{"role": "user", "content": request.message}],
        "max_tokens": request.max_tokens,
    }

    started = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
            response = await client.post(OVMS_URL, json=payload)
            response.raise_for_status()
    except httpx.HTTPStatusError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"OVMS returned HTTP {exc.response.status_code}: {exc.response.text}",
        ) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"OVMS request failed: {exc}") from exc

    elapsed = round(time.perf_counter() - started, 3)
    body = response.json()
    logger.info(
        "chat_completion model=%s latency_seconds=%s prompt_tokens=%s completion_tokens=%s total_tokens=%s",
        body.get("model", MODEL_NAME),
        elapsed,
        body.get("usage", {}).get("prompt_tokens"),
        body.get("usage", {}).get("completion_tokens"),
        body.get("usage", {}).get("total_tokens"),
    )
    answer = (
        body.get("choices", [{}])[0]
        .get("message", {})
        .get("content", "")
    )

    return ChatResponse(
        answer=answer,
        model=body.get("model", MODEL_NAME),
        latency_seconds=elapsed,
        usage=body.get("usage"),
    )
