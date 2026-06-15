"""Shared LLM client abstraction for Bedrock and OpenAI."""

import json
import os
from dataclasses import dataclass
from typing import Optional

import boto3
from botocore.config import Config


@dataclass
class LLMResponse:
    text: str
    input_tokens: int = 0
    output_tokens: int = 0
    model: str = ""


class LLMClient:
    """统一的 LLM 客户端，支持 Amazon Bedrock。"""

    def __init__(self, model_id: str = "us.amazon.nova-2-lite-v1:0", region: str = "us-west-2"):
        self.model_id = model_id
        self.region = region
        self._client = boto3.client(
            "bedrock-runtime",
            region_name=region,
            config=Config(read_timeout=60, connect_timeout=10, retries={"max_attempts": 3, "mode": "adaptive"}),
        )
        self.total_input_tokens = 0
        self.total_output_tokens = 0
        self.total_calls = 0

    def invoke(
        self,
        prompt: str,
        system: str = "",
        temperature: float = 0.0,
        max_tokens: int = 4096,
    ) -> LLMResponse:
        import time as _time

        messages = [{"role": "user", "content": [{"text": prompt}]}]
        kwargs = {
            "modelId": self.model_id,
            "messages": messages,
            "inferenceConfig": {"temperature": temperature, "maxTokens": max_tokens},
        }
        if system:
            kwargs["system"] = [{"text": system}]

        max_retries = 3
        for attempt in range(max_retries):
            try:
                resp = self._client.converse(**kwargs)
                break
            except (
                self._client.exceptions.ThrottlingException,
                self._client.exceptions.ServiceUnavailableException,
            ) as e:
                if attempt == max_retries - 1:
                    raise
                wait = 2 ** attempt + 1
                _time.sleep(wait)
            except Exception as e:
                err_code = getattr(e, "response", {}).get("Error", {}).get("Code", "")
                if err_code in ("ThrottlingException", "TooManyRequestsException", "ServiceUnavailableException"):
                    if attempt == max_retries - 1:
                        raise
                    wait = 2 ** attempt + 1
                    _time.sleep(wait)
                else:
                    raise

        text = resp["output"]["message"]["content"][0]["text"]
        usage = resp.get("usage", {})
        input_tok = usage.get("inputTokens", 0)
        output_tok = usage.get("outputTokens", 0)

        self.total_input_tokens += input_tok
        self.total_output_tokens += output_tok
        self.total_calls += 1

        return LLMResponse(
            text=text,
            input_tokens=input_tok,
            output_tokens=output_tok,
            model=self.model_id,
        )

    def invoke_batch(self, prompts: list[str], system: str = "", **kwargs) -> list[LLMResponse]:
        return [self.invoke(p, system=system, **kwargs) for p in prompts]

    def get_usage_summary(self) -> dict:
        """Return cumulative token usage stats."""
        return {
            "total_calls": self.total_calls,
            "total_input_tokens": self.total_input_tokens,
            "total_output_tokens": self.total_output_tokens,
            "total_tokens": self.total_input_tokens + self.total_output_tokens,
        }
