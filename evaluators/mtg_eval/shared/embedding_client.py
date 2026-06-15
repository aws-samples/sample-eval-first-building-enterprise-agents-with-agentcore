"""Embedding client for vector search."""

import boto3
import numpy as np


class EmbeddingClient:
    """Amazon Titan Embeddings via Bedrock（带重试机制）。"""

    def __init__(self, model_id: str = "amazon.titan-embed-text-v2:0", region: str = "us-west-2"):
        self.model_id = model_id
        self._client = boto3.client("bedrock-runtime", region_name=region)

    def embed(self, text: str) -> list[float]:
        import json
        import time as _time

        max_retries = 3
        for attempt in range(max_retries):
            try:
                resp = self._client.invoke_model(
                    modelId=self.model_id,
                    body=json.dumps({"inputText": text}),
                )
                return json.loads(resp["body"].read())["embedding"]
            except Exception as e:
                err_code = getattr(e, "response", {}).get("Error", {}).get("Code", "")
                if err_code in ("ThrottlingException", "TooManyRequestsException", "ServiceUnavailableException"):
                    if attempt == max_retries - 1:
                        raise
                    _time.sleep(2 ** attempt + 1)
                else:
                    raise

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        return [self.embed(t) for t in texts]
