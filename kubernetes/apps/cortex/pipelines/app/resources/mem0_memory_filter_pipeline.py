"""
title: Long Term Memory Filter (mem0 REST API)
author: Artemis-Cluster
version: 1.0
requirements: pydantic
"""

import json
import os
import threading
import urllib.request
import urllib.error
from typing import List, Optional

from pydantic import BaseModel


class Pipeline:
    class Valves(BaseModel):
        pipelines: List[str] = []
        priority: int = 0
        store_cycles: int = 1
        mem0_user_id: str = "exikle"
        mem0_base_url: str = "http://mem0.cortex.svc.cluster.local:8765"
        mem0_api_key: str = ""

    def __init__(self):
        self.type = "filter"
        self.name = "Memory Filter"
        self.user_messages: List[str] = []
        self.thread = None
        self.valves = self.Valves(
            pipelines=["*"],
            mem0_api_key=os.environ.get("MEM0_API_KEY", ""),
        )

    def _headers(self):
        h = {"Content-Type": "application/json"}
        if self.valves.mem0_api_key:
            h["Authorization"] = f"Token {self.valves.mem0_api_key}"
        return h

    def _search_memory(self, query: str) -> List[str]:
        url = f"{self.valves.mem0_base_url}/api/v1/memories/filter"
        payload = json.dumps(
            {"user_id": self.valves.mem0_user_id, "search_query": query, "size": 5}
        ).encode()
        try:
            req = urllib.request.Request(url, data=payload, headers=self._headers(), method="POST")
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())
                results = data.get("results", data) if isinstance(data, dict) else data
                return [r.get("memory", "") for r in results if r.get("memory")]
        except Exception:
            return []

    def _add_memory(self, text: str) -> None:
        url = f"{self.valves.mem0_base_url}/api/v1/memories/"
        payload = json.dumps(
            {"user_id": self.valves.mem0_user_id, "text": text}
        ).encode()
        try:
            req = urllib.request.Request(url, data=payload, headers=self._headers(), method="POST")
            urllib.request.urlopen(req, timeout=5).close()
        except Exception:
            pass

    async def inlet(self, body: dict, user: Optional[dict] = None) -> dict:
        messages = body.get("messages", [])
        user_msg = next(
            (m["content"] for m in reversed(messages) if m.get("role") == "user"), ""
        )

        if user_msg:
            self.user_messages.append(user_msg)
            if len(self.user_messages) >= self.valves.store_cycles:
                text = " ".join(self.user_messages)
                self.user_messages = []
                if self.thread is None or not self.thread.is_alive():
                    self.thread = threading.Thread(
                        target=self._add_memory, args=(text,), daemon=True
                    )
                    self.thread.start()

            memories = self._search_memory(user_msg)
            if memories:
                memory_text = "\n".join(f"- {m}" for m in memories)
                system_content = (
                    f"Long-term memory context (from mem0):\n{memory_text}\n\n"
                    "Use this context if relevant to the current question."
                )
                system_msg = {"role": "system", "content": system_content}
                if messages and messages[0].get("role") == "system":
                    messages[0]["content"] += f"\n\n{system_content}"
                else:
                    messages.insert(0, system_msg)
                body["messages"] = messages

        return body

    async def outlet(self, body: dict, user: Optional[dict] = None) -> dict:
        return body
