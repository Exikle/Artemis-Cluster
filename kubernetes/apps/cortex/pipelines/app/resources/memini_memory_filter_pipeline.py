"""
title: Long Term Memory Filter (memini)
author: Artemis-Cluster
version: 3.0
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
        search_limit: int = 5
        memini_base_url: str = "http://memini.cortex.svc.cluster.local:8080"
        memini_namespace: str = "Artemis-Cluster"
        memini_api_key: str = ""

    def __init__(self):
        self.type = "filter"
        self.name = "Memory Filter"
        self.user_messages: List[str] = []
        self._lock = threading.Lock()
        self.thread = None
        self.valves = self.Valves(
            pipelines=["*"],
            memini_api_key=os.environ.get("MEMINI_API_KEY", ""),
        )

    def _headers(self):
        h = {
            "Content-Type": "application/json",
            "X-Memini-Namespace": self.valves.memini_namespace,
        }
        if self.valves.memini_api_key:
            h["Authorization"] = f"Bearer {self.valves.memini_api_key}"
        return h

    def _search_memory(self, query: str) -> List[str]:
        url = f"{self.valves.memini_base_url}/v1/search"
        payload = json.dumps({"query": query, "limit": self.valves.search_limit}).encode()
        try:
            req = urllib.request.Request(url, data=payload, headers=self._headers(), method="POST")
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read())
                return [
                    r.get("memory", {}).get("content", "")
                    for r in data.get("results", [])
                    if r.get("memory", {}).get("content")
                ]
        except Exception:
            return []

    def _save_memory(self, text: str) -> None:
        url = f"{self.valves.memini_base_url}/v1/memories"
        payload = json.dumps({"content": text, "tier": "episodic"}).encode()
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
            with self._lock:
                self.user_messages.append(user_msg)
                if len(self.user_messages) >= self.valves.store_cycles:
                    text = " ".join(self.user_messages)
                    self.user_messages = []
                    if self.thread is None or not self.thread.is_alive():
                        self.thread = threading.Thread(
                            target=self._save_memory, args=(text,), daemon=True
                        )
                        self.thread.start()

            recent_context = " ".join(
                m["content"] for m in messages[-4:] if m.get("role") == "user"
            )
            memories = self._search_memory(recent_context or user_msg)
            if len(messages) <= 2:
                profile_memories = self._search_memory(
                    "user personal profile name location preferences"
                )
                seen = set(memories)
                memories += [m for m in profile_memories if m not in seen]

            if memories:
                memory_text = "\n".join(f"- {m}" for m in memories)
                system_content = (
                    f"Long-term memory context (from memini):\n{memory_text}\n\n"
                    "Use this context if relevant to the current question."
                )
                if messages and messages[0].get("role") == "system":
                    messages[0]["content"] += f"\n\n{system_content}"
                else:
                    messages.insert(0, {"role": "system", "content": system_content})
                body["messages"] = messages

        return body

    async def outlet(self, body: dict, user: Optional[dict] = None) -> dict:
        return body
